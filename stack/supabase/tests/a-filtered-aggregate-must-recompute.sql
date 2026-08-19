-- A filtered aggregate must RECOMPUTE, count what it covered, and refuse to answer a question it
-- was not asked.
--
-- WHY THIS IS A TEST. The whole point of `aggregate_performance` is that the number changes when
-- the filter changes. Every failure mode here is silent — a wrong weighted mean is still a
-- plausible percentage, and the two that would actually ship are:
--
--   * a client doing this itself gets 1,000 rows from PostgREST and averages them into a confident
--     wrong answer with no error (PGRST_DB_MAX_ROWS)
--   * an INNER join to `performance` makes `weight_covered` identically 1.0, so the coverage guard
--     reads as protection while being incapable of warning about anything
--
-- The fixture uses numbers chosen so every expected value is hand-computable and stated inline.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.currency (code) values ('USD') on conflict do nothing;
insert into market.fx_rate (currency_code, as_of, usd_per_unit, source_code)
  values ('USD', current_date, 1, 'yfinance') on conflict (currency_code, as_of) do nothing;
insert into market.countries (iso2, name, flag, market, drillable) values
  ('ZG','Gridland','ZG','developed',false),
  ('ZH','Hedgeland','ZH','emerging',false)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values ('ZG','ZG','.ZG')
  on conflict (exch_code) do nothing;
insert into market.classification_schemes (id, name, sort_order) values ('msci','MSCI',1)
  on conflict (id) do nothing;
insert into market.classification_groups (scheme_id, lens, id, name, sort_order) values
  ('msci','tier','developed','Developed',1), ('msci','tier','emerging','Emerging',2)
on conflict (scheme_id, lens, id) do nothing;
insert into market.classification_members (scheme_id, lens, iso2, group_id) values
  ('msci','tier','ZG','developed'), ('msci','tier','ZH','emerging')
on conflict (scheme_id, lens, iso2) do nothing;

-- Four securities. Caps and returns are round numbers so every expectation below is arithmetic
-- anyone can check by hand.
--
--   id    country  tier        sector       cap    1y change   total return
--   A     ZG       developed   financials   $30bn    +10%         +12%
--   B     ZG       developed   financials   $10bn    +20%         (none)
--   C     ZH       emerging    financials   $20bn    -5%          -5%
--   D     ZG       developed   financials   $40bn    (NO PRICE)   (none)
do $$
declare
  ids uuid[] := array['00000000-0000-0000-0000-000000008001','00000000-0000-0000-0000-000000008002',
                      '00000000-0000-0000-0000-000000008003','00000000-0000-0000-0000-000000008004']::uuid[];
  iso text[]  := array['ZG','ZG','ZH','ZG'];
  cap numeric[] := array[30e9, 10e9, 20e9, 40e9];
  sym text[] := array['AAA','BBB','CCC','DDD'];
  i integer;
begin
  for i in 1..4 loop
    insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap)
      values (ids[i], 'T80 ' || sym[i], 'equity', iso[i], 'USD', cap[i])
      on conflict (security_id) do nothing;
    insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code)
      values (ids[i], 'ZG', sym[i], sym[i], true, 'yfinance') on conflict do nothing;
    insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
      select ids[i], node_id, 'yfinance', now() from market.taxonomy_node
       where taxonomy_id = 'muffin' and level = 1 and code = 'financials'
      on conflict do nothing;
  end loop;
end $$;

insert into market.performance (scope, scope_id, period, change_pct, total_return_pct, as_of, stale_after, source) values
  ('instrument','AAA','1y',  10.0,  12.0, now(), now() + interval '1 day','yfinance'),
  ('instrument','BBB','1y',  20.0,  null, now(), now() + interval '1 day','yfinance'),
  ('instrument','CCC','1y',  -5.0,  -5.0, now(), now() + interval '1 day','yfinance')
  -- DDD deliberately has NO performance row.
on conflict (scope, scope_id, period) do update
  set change_pct = excluded.change_pct, total_return_pct = excluded.total_return_pct;

-- THE SPINE IS A SNAPSHOT (migration 80). Fixtures inserted in this transaction are not in it
-- until it is rebuilt, so every assertion below would read an empty view and "pass" or fail for
-- the wrong reason. The NON-concurrent form is used deliberately: `refresh ... concurrently`
-- cannot run inside a transaction block, and a test that cannot roll back is not a test.
refresh materialized view market.security_facets;

-- 1. THE UNFILTERED NUMBER, cap-weighted over the three priced names.
--    (30*10 + 10*20 + 20*-5) / 60 = (300 + 200 - 100)/60 = 400/60 = 6.6667
--    Equal-weighted: (10 + 20 - 5)/3 = 8.3333 — DIFFERENT, which is why both are returned.
do $$
declare r record;
begin
  select * into r from market.aggregate_performance(p_period => '1y', p_group_by => 'sector_id')
   where bucket = 'financials';
  if r.change_pct is distinct from 6.6667 then
    raise exception 'cap-weighted mean is % (expected 6.6667 = (30*10+10*20+20*-5)/60)', coalesce(r.change_pct::text,'<null>');
  end if;
  if r.change_pct_equal is distinct from 8.3333 then
    raise exception 'equal-weighted mean is % (expected 8.3333)', coalesce(r.change_pct_equal::text,'<null>');
  end if;
  -- THE UNPRICED SECURITY IS COUNTED IN THE BUCKET BUT NOT IN THE MEAN.
  if r.constituents <> 3 then raise exception 'constituents is % (expected 3 priced)', r.constituents; end if;
  if r.bucket_securities <> 4 then
    raise exception 'bucket_securities is % (expected 4) — a security with no performance row still belongs to the bucket', r.bucket_securities;
  end if;
end $$;

-- 2. WEIGHT_COVERED MUST FALL BELOW 1. DDD is $40bn of the $100bn bucket and has no return, so the
--    headline describes 60% of the bucket by value. An INNER join to `performance` would make this
--    exactly 1.0000 for every bucket forever — a guard that cannot fail.
do $$
declare wc numeric;
begin
  select weight_covered into wc from market.aggregate_performance(p_period => '1y', p_group_by => 'sector_id')
   where bucket = 'financials';
  if wc is distinct from 0.6000 then
    raise exception
      'weight_covered is % (expected 0.6000 = 60bn priced of 100bn) — if this is 1.0000 the denominator is only priced securities and the coverage guard can never warn about anything', coalesce(wc::text,'<null>');
  end if;
end $$;

-- 3. THE NUMBER RECOMPUTES UNDER A FILTER. This is the entire feature. Filtering to the developed
--    tier drops CCC: (30*10 + 10*20)/40 = 500/40 = 12.5 — a different number from 6.6667, produced
--    by the same call with one more argument.
do $$
declare c numeric; k integer;
begin
  select change_pct, constituents into c, k
    from market.aggregate_performance(p_period => '1y', p_group_by => 'sector_id',
                                      p_msci_tier => array['developed'])
   where bucket = 'financials';
  if c is distinct from 12.5000 then
    raise exception 'filtered cap-weighted mean is % (expected 12.5000 = (30*10+10*20)/40)', coalesce(c::text,'<null>');
  end if;
  if k <> 2 then raise exception 'filtered constituents is % (expected 2)', k; end if;
end $$;

-- 4. GROUPING BY A DIFFERENT FACET re-buckets the same securities without a second endpoint.
do $$
declare dev numeric; eme numeric; n integer;
begin
  select count(*) into n from market.aggregate_performance(p_period => '1y', p_group_by => 'msci_tier');
  if n <> 2 then raise exception 'expected 2 tier buckets, got %', n; end if;
  select change_pct into dev from market.aggregate_performance(p_period => '1y', p_group_by => 'msci_tier')
   where bucket = 'developed';
  select change_pct into eme from market.aggregate_performance(p_period => '1y', p_group_by => 'msci_tier')
   where bucket = 'emerging';
  if dev is distinct from 12.5000 then raise exception 'developed bucket is % (expected 12.5000)', dev; end if;
  if eme is distinct from -5.0000 then raise exception 'emerging bucket is % (expected -5.0000)', eme; end if;
end $$;

-- 5. A NULL TOTAL RETURN IS EXCLUDED FROM ITS MEAN, NOT COALESCED TO change_pct.
--    Only AAA (+12, $30bn) and CCC (-5, $20bn) have one: (30*12 + 20*-5)/50 = 260/50 = 5.2
--    If BBB's null had been folded in as its +20 change, the answer would be
--    (30*12 + 10*20 + 20*-5)/60 = 460/60 = 7.6667.
do $$
declare tr numeric; trk integer;
begin
  select total_return_pct, total_return_constituents into tr, trk
    from market.aggregate_performance(p_period => '1y', p_group_by => 'sector_id')
   where bucket = 'financials';
  if trk <> 2 then raise exception 'total_return_constituents is % (expected 2)', trk; end if;
  if tr is distinct from 5.2000 then
    raise exception
      'total_return_pct is % (expected 5.2000) — a NULL total return was folded into the mean instead of excluded (coalescing to change_pct would give 7.6667)', coalesce(tr::text,'<null>');
  end if;
end $$;

-- 6. AN UNRECOGNISED group_by RETURNS NOTHING. The dangerous alternative is an `else` that buckets
--    the whole universe under one label — a typo would then render as a real, single-bucket answer.
do $$
declare n integer;
begin
  select count(*) into n from market.aggregate_performance(p_period => '1y', p_group_by => 'sctor_id');
  if n <> 0 then
    raise exception 'a misspelled group_by returned % buckets — it must return nothing, not group the universe into one row', n;
  end if;
end $$;

-- 7. NULL AND AN EMPTY ARRAY ARE DIFFERENT QUESTIONS. Null means "no opinion"; an empty array means
--    "match nothing". A UI clearing its last chip must not flip from an empty result to the world.
do $$
declare n_null integer; n_empty integer;
begin
  select count(*) into n_null  from market.aggregate_performance(p_period => '1y', p_group_by => 'sector_id',
                                                                 p_country => null);
  select count(*) into n_empty from market.aggregate_performance(p_period => '1y', p_group_by => 'sector_id',
                                                                 p_country => array[]::text[]);
  if n_null = 0 then raise exception 'a null filter must mean "no opinion", got no buckets'; end if;
  if n_empty <> 0 then
    raise exception 'an EMPTY filter array returned % buckets — empty means "match nothing", and conflating it with null makes a cleared filter show the whole universe', n_empty;
  end if;
end $$;

-- 8. A PERIOD WITH NO DATA yields no rows rather than a bucket of nulls that renders as 0.0%.
do $$
declare n integer;
begin
  select count(*) into n from market.aggregate_performance(p_period => '99y', p_group_by => 'sector_id')
   where change_pct is not null;
  if n <> 0 then raise exception 'a period with no performance rows produced % numeric buckets', n; end if;
end $$;

-- 9. ANON CAN CALL IT. The whole feature is for the app, which reads with the anon key. A function
--    that only service_role can execute is the same defect as migration 42's ungranted table.
do $$
declare ok boolean;
begin
  select has_function_privilege('anon', p.oid, 'execute') into ok
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'market' and p.proname = 'aggregate_performance';
  if not coalesce(ok, false) then
    raise exception 'anon cannot execute aggregate_performance — the app reads with the anon key';
  end if;
end $$;

rollback;
