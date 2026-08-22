-- A MARKET CAP IN THE COMPANY'S OWN CURRENCY IS NOT A SIZE.
--
-- `security.market_cap` is denominated in each security's own currency, so ranking peers on it
-- directly puts a ¥3,000,000,000,000 company beside a $3,000,000,000 one and calls them the same
-- size — wrong by two orders of magnitude and entirely plausible-looking, which is why migration 73
-- exists. This test makes the raw column and the converted one DISAGREE about who the nearest peer
-- is, so a view reading `market_cap` rather than `market_cap_usd` picks the wrong company.
--
-- It also pins the distance measure. A $40bn gap means one thing between two $50bn companies and
-- nothing between two $2tn ones, so closeness is a LOG RATIO, not a subtraction.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.currency (code, name) values ('USD','US Dollar'), ('JPY','Yen')
  on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Peerland','ZW',false)
  on conflict (iso2) do nothing;

-- A rate that makes the two currencies differ by ~100x, so the two rankings cannot agree.
insert into market.fx_rate (currency_code, as_of, usd_per_unit, source_code) values
  ('USD', current_date, 1,      'yfinance'),
  ('JPY', current_date, 0.0067, 'yfinance')
on conflict (currency_code, as_of) do update set usd_per_unit = excluded.usd_per_unit;

-- SUBJECT: a $10bn US company.
-- TRUE PEER: a $12bn US company — nearest in real size.
-- IMPOSTOR: a Japanese company at ¥1,500,000,000,000, which is ~$10.05bn — nearly identical in
--   DOLLARS, but its RAW number (1.5e12) is 150x the subject's, so a view ranking on the raw
--   column would place it furthest away rather than nearest.
insert into market.security
  (security_id, name, security_type_code, country_iso2, currency_code, market_cap) values
  ('00000000-0000-0000-0000-000000011901','T119 Subject','equity','ZW','USD', 10000000000),
  ('00000000-0000-0000-0000-000000011902','T119 True peer','equity','ZW','USD', 12000000000),
  ('00000000-0000-0000-0000-000000011903','T119 Yen twin','equity','ZW','JPY', 1500000000000),
  ('00000000-0000-0000-0000-000000011904','T119 Giant','equity','ZW','USD', 900000000000)
on conflict (security_id) do nothing;

-- ALL FOUR IN ONE SECTOR, so sector never decides the answer and size is the only variable.
-- `security_current.sector_id` reads a LEVEL-1 node of the `muffin` taxonomy via
-- `security_taxonomy`, so the fixture has to build that chain — without it the view returns nothing
-- and the test would pass having measured nothing, which the guard below is there to catch.
insert into market.taxonomy (taxonomy_id, name) values ('muffin','Muffin sectors')
  on conflict (taxonomy_id) do nothing;
-- The muffin sectors are SEEDED by migration, so the fixture reuses an existing level-1 node
-- rather than inserting one — (taxonomy_id, code) is unique and 'industrials' is already there.
insert into market.security_taxonomy (security_id, node_id, source_code)
select s.security_id, n.node_id, 'yfinance'
  from (values ('00000000-0000-0000-0000-000000011901'::uuid),
               ('00000000-0000-0000-0000-000000011902'::uuid),
               ('00000000-0000-0000-0000-000000011903'::uuid),
               ('00000000-0000-0000-0000-000000011904'::uuid)) as s(security_id)
  cross join lateral (
    select node_id from market.taxonomy_node
     where taxonomy_id = 'muffin' and level = 1 order by code limit 1
  ) n
on conflict do nothing;

do $$
declare nearest text; d_twin numeric; d_giant numeric; n integer;
begin
  -- The sector comes from `security_current`; if this fixture cannot give the securities one, the
  -- view returns nothing and the test would pass vacuously. Assert that it does not.
  select count(*) into n from market.security_peers
   where security_id = '00000000-0000-0000-0000-000000011901';
  if n = 0 then
    raise exception 'the fixture produced no peers at all — the test would pass without measuring anything';
  end if;

  -- 1. THE YEN TWIN IS RECOGNISED AS THE SAME SIZE. ~$10.05bn against the subject's $10bn, so its
  --    log distance must be tiny. On the RAW column it is 150x away and would rank last.
  select size_distance into d_twin from market.security_peers
   where security_id = '00000000-0000-0000-0000-000000011901'
     and peer_id = '00000000-0000-0000-0000-000000011903';
  if d_twin is null or d_twin > 0.05 then
    raise exception 'the yen company scores a distance of % — converted it is $10.05bn against a $10bn subject, so this view is ranking on the RAW cap and calling a same-size company a stranger', coalesce(d_twin::text,'<null>');
  end if;

  -- 2. AND THE GIANT IS FAR. $900bn against $10bn is ~1.95 decades.
  select size_distance into d_giant from market.security_peers
   where security_id = '00000000-0000-0000-0000-000000011901'
     and peer_id = '00000000-0000-0000-0000-000000011904';
  if d_giant is null or d_giant < 1.5 then
    raise exception 'a $900bn company scores % against a $10bn subject — expected ~1.95 decades', coalesce(d_giant::text,'<null>');
  end if;

  -- 3. THE NEAREST PEER IS THE YEN TWIN, not the $12bn US company: 10.05 is closer to 10 than 12
  --    is. A view ranking on the raw column would name the $12bn one, so the two answers differ.
  select peer_name into nearest from market.security_peers
   where security_id = '00000000-0000-0000-0000-000000011901'
   order by size_distance limit 1;
  if nearest is distinct from 'T119 Yen twin' then
    raise exception 'the nearest peer is %, expected the yen twin — the fixture is built so the raw and converted rankings DISAGREE', coalesce(nearest,'<none>');
  end if;

  -- 4. A SECURITY IS NEVER ITS OWN PEER.
  select count(*) into n from market.security_peers
   where security_id = '00000000-0000-0000-0000-000000011901'
     and peer_id = '00000000-0000-0000-0000-000000011901';
  if n <> 0 then raise exception 'a security is listed as its own peer'; end if;
end $$;

rollback;

\echo 'ok: a peer must be comparable in one currency'
