-- A promotion wave adds each untracked share class once, from its home venue, and never a class
-- whose home the directory cannot tell. Migration 20261025170000 (Phase 3 Stage 4).
--
-- WHY. A share class trades on several venues, and the directory carries no issuer country. The
-- first rule here, "one ENABLED country and no US line", filed Tubacex (Spanish) as British from
-- London's international order book, measured in a rolled-back wave on production 2026-10-26. The
-- fixture gives each rule its own class:
--
--   S1  two lines in one enabled country (T8A pref 1, T8B pref 2)   a candidate, from T8A
--   S2  an enabled line and a US line                               not a candidate
--   S3  lines in two enabled countries                              not a candidate
--   S4  already held as a share class                               not a candidate
--   S5  its only enabled line is absent from the directory          not a candidate
--   S6  only on a venue promotion is not enabled for                not a candidate
--   S7  a depositary receipt                                        not a candidate
--   S8  one line, T8B (pref 2)                                      a candidate
--   S9  its line's symbol is already a tracked security's           not a candidate
--   SG  an enabled line and a line in a country with none enabled   not a candidate (Tubacex)
--   SH  a Bloomberg code for a delisted line (`7785752Z`)           not a candidate
--   SJ  Yahoo found nothing for its line 10 days ago                not a candidate (section 7)
--   SK  Yahoo found nothing for its line 100 days ago               a candidate again
--   SL  Yahoo priced its line 10 days ago                           a candidate
--
-- THE WAVE PROMOTES ONLY WHAT IT IS HANDED, in the order handed: the Dagster lane hands it the
-- lines Yahoo priced, in the order it asked. A fixture where the view's order and the array's
-- agree could not tell the two rules apart, so section 2 hands them reversed.

\set ON_ERROR_STOP on

begin;

insert into market.countries (iso2, name, flag, drillable) values
  ('ZE', 'Homeland', 'ZE', false), ('ZF', 'Otherland', 'ZF', false), ('ZG', 'Elsewhere', 'ZG', false),
  ('US', 'United States', 'US', true)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix, preference, enabled) values
  ('US', 'US', '', 1, true)
on conflict (exch_code) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix, preference, enabled, promotion_tier, promotion_enabled)
values ('T8A', 'ZE', '.ZA', 1, true, 1, true),
       ('T8B', 'ZE', '.ZB', 2, true, 1, true),
       ('T8C', 'ZF', '.ZC', 1, true, 1, true),
       ('T8D', 'ZE', '.ZD', 3, true, 1, false),
       ('T8E', 'ZG', '.ZE', 1, true, 1, false)
on conflict (exch_code) do update set promotion_enabled = excluded.promotion_enabled,
                                      promotion_tier = excluded.promotion_tier,
                                      preference = excluded.preference;
insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.identifier_kind (code, name, is_global_unique) values
  ('share_class_figi', 'OpenFIGI share-class FIGI', true), ('figi', 'FIGI', true), ('ticker', 'Ticker', false)
on conflict do nothing;
insert into market.data_source (code, name, priority) values ('openfigi', 'OpenFIGI', 50), ('yfinance', 'yfinance', 100)
  on conflict (code) do nothing;
update market.promotion_policy set wave_size = 500, paused = false;

insert into market.venue_listing (figi, composite_figi, share_class_figi, exch_code, ticker, name,
                                  security_type, country_iso2, provider_symbol, last_seen_at, absent_since) values
  ('BBGT8S1A', 'BBGT8S1C', 'T8CLS1', 'T8A', 'ONE',  'T8 One',   'Common Stock', 'ZE', 'ONE.ZA',  now(), null),
  ('BBGT8S1B', 'BBGT8S1C', 'T8CLS1', 'T8B', 'ONE',  'T8 One',   'Common Stock', 'ZE', 'ONE.ZB',  now(), null),
  ('BBGT8S2A', 'BBGT8S2C', 'T8CLS2', 'T8A', 'TWO',  'T8 Two',   'Common Stock', 'ZE', 'TWO.ZA',  now(), null),
  ('BBGT8S2U', 'BBGT8S2U', 'T8CLS2', 'US',  'TWOF', 'T8 Two',   'Common Stock', 'US', 'TWOF',    now(), null),
  ('BBGT8S3A', 'BBGT8S3C', 'T8CLS3', 'T8A', 'THR',  'T8 Three', 'Common Stock', 'ZE', 'THR.ZA',  now(), null),
  ('BBGT8S3C', 'BBGT8S3D', 'T8CLS3', 'T8C', 'THR',  'T8 Three', 'Common Stock', 'ZF', 'THR.ZC',  now(), null),
  ('BBGT8S4A', 'BBGT8S4C', 'T8CLS4', 'T8A', 'FOU',  'T8 Four',  'Common Stock', 'ZE', 'FOU.ZA',  now(), null),
  ('BBGT8S5A', 'BBGT8S5C', 'T8CLS5', 'T8A', 'FIV',  'T8 Five',  'Common Stock', 'ZE', 'FIV.ZA',  now(), now()),
  ('BBGT8S6D', 'BBGT8S6C', 'T8CLS6', 'T8D', 'SIX',  'T8 Six',   'Common Stock', 'ZE', 'SIX.ZD',  now(), null),
  ('BBGT8S7A', 'BBGT8S7C', 'T8CLS7', 'T8A', 'SEV',  'T8 Seven', 'Depositary Receipt', 'ZE', 'SEV.ZA', now(), null),
  ('BBGT8S8B', 'BBGT8S8C', 'T8CLS8', 'T8B', 'EIG',  'T8 Eight', 'Common Stock', 'ZE', 'EIG.ZB',  now(), null),
  ('BBGT8S9A', 'BBGT8S9C', 'T8CLS9', 'T8A', 'NIN',  'T8 Nine',  'REIT',         'ZE', 'NIN.ZA',  now(), null),
  ('BBGT8SGA', 'BBGT8SGC', 'T8CLSG', 'T8A', 'GEE',  'T8 Gee',   'Common Stock', 'ZE', 'GEE.ZA',  now(), null),
  ('BBGT8SGE', 'BBGT8SGF', 'T8CLSG', 'T8E', 'GEE',  'T8 Gee',   'Common Stock', 'ZG', 'GEE.ZE',  now(), null),
  ('BBGT8SHA', 'BBGT8SHC', 'T8CLSH', 'T8A', '7785752Z', 'T8 Aitch', 'Common Stock', 'ZE', '7785752Z.ZA', now(), null);

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-0000000008a4', 'T8 Four, held', 'equity', 'ZE'),
  ('00000000-0000-0000-0000-0000000008a9', 'T8 Nine, held by its symbol', 'equity', 'ZE');
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('share_class_figi', 'T8CLS4', '00000000-0000-0000-0000-0000000008a4', 'openfigi');
insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-0000000008a9', 'yfinance', 'NIN.ZA');

-- 1. The candidates are exactly S1 (from T8A) and S8.
do $$
declare got text;
begin
  select string_agg(share_class_figi || '@' || exch_code, ',' order by share_class_figi) into got
    from market.promotion_candidate where share_class_figi like 'T8CLS%';
  if got is distinct from 'T8CLS1@T8A,T8CLS8@T8B' then
    raise exception 'the candidates are %, expected T8CLS1@T8A,T8CLS8@T8B', got;
  end if;
  raise notice 'ok  only a class whose every line is in one enabled country is a candidate, from its best venue';
end $$;

-- 2. A wave of one takes the FIRST line handed, not the view's first: here S8 before S1. A line
--    that is not a candidate (S2's) is skipped. The class is filed under its home and priced there.
do $$
declare r jsonb; sid uuid;
begin
  r := market.promote_share_classes(array['BBGT8S2A', 'BBGT8S8B', 'BBGT8S1A'], 1);
  if (r ->> 'promoted')::int <> 1 then
    raise exception 'a wave of one promoted %', r;
  end if;
  select security_id into sid from market.security_identifier
   where kind_code = 'share_class_figi' and value = 'T8CLS8';
  if sid is null then
    raise exception 'the first candidate handed (S8) was not the one promoted: %', r;
  end if;
  if exists (select 1 from market.security_identifier where kind_code = 'share_class_figi' and value = 'T8CLS2') then
    raise exception 'a line that is not a candidate was promoted because it was handed in';
  end if;
  if (select country_iso2 from market.security where security_id = sid) is distinct from 'ZE' then
    raise exception 'the promoted class is not filed under its home country';
  end if;
  if (select symbol from market.security_provider_symbol where security_id = sid and provider_code = 'yfinance')
     is distinct from 'EIG.ZB' then
    raise exception 'the promoted class is not priced from its own line';
  end if;
  if (select count(*) from market.security_identifier where security_id = sid) <> 3 then
    raise exception 'the promoted class lacks its share-class, composite or ticker identifier';
  end if;
  raise notice 'ok  a wave promotes what it is handed, in the order handed, from the home venue';
end $$;

-- 3. The next wave takes the rest, and never the same class twice; a line it is not handed is not
--    promoted however good a candidate it is.
do $$
declare r jsonb;
begin
  if (market.promote_share_classes(array['BBGT8S8B'], 10) ->> 'promoted')::int <> 0 then
    raise exception 'a class already promoted was promoted again';
  end if;
  if (market.promote_share_classes(array[]::text[], 10) ->> 'promoted')::int <> 0 then
    raise exception 'a wave handed nothing promoted something';
  end if;
  r := market.promote_share_classes(array['BBGT8S1A'], 10);
  if (r ->> 'promoted')::int <> 1
     or not exists (select 1 from market.security_identifier where kind_code = 'share_class_figi' and value = 'T8CLS1') then
    raise exception 'the second wave should promote exactly T8CLS1: %', r;
  end if;
  if (select count(*) from market.security_identifier where kind_code = 'share_class_figi' and value like 'T8CLS%') <> 3 then
    raise exception 'a class was promoted twice, or one that should not have been';
  end if;
  raise notice 'ok  each class is promoted once, and only when handed';
end $$;

-- 4. The policy caps and pauses a wave.
insert into market.venue_listing (figi, composite_figi, share_class_figi, exch_code, ticker, name,
                                  security_type, country_iso2, provider_symbol, last_seen_at) values
  ('BBGT8SAA', 'BBGT8SAC', 'T8CLSA', 'T8A', 'TEN', 'T8 Ten',    'Common Stock', 'ZE', 'TEN.ZA', now()),
  ('BBGT8SBA', 'BBGT8SBC', 'T8CLSB', 'T8A', 'ELE', 'T8 Eleven', 'Common Stock', 'ZE', 'ELE.ZA', now());
do $$
begin
  update market.promotion_policy set paused = true;
  if (market.promote_share_classes(array['BBGT8SAA', 'BBGT8SBA'], 10) ->> 'promoted')::int <> 0 then
    raise exception 'a paused policy promoted';
  end if;
  update market.promotion_policy set paused = false, wave_size = 1;
  if (market.promote_share_classes(array['BBGT8SAA', 'BBGT8SBA'], 10) ->> 'promoted')::int <> 1 then
    raise exception 'the wave size did not cap the wave';
  end if;
  update market.promotion_policy set wave_size = 500;
  if (market.promote_share_classes(array['BBGT8SBA'], 0) ->> 'promoted')::int <> 0 then
    raise exception 'a wave with no capacity promoted';
  end if;
  raise notice 'ok  the policy pauses and caps a wave, and so does the capacity asked';
end $$;

-- 5. Two classes the directory prices with one symbol: the wave takes one, and the other leaves the
--    candidates, since `security_provider_symbol` is unique on (provider, symbol) and two rows of
--    one statement claiming it would fail the whole wave.
insert into market.venue_listing (figi, composite_figi, share_class_figi, exch_code, ticker, name,
                                  security_type, country_iso2, provider_symbol, last_seen_at) values
  ('BBGT8SCA', 'BBGT8SCC', 'T8CLSC', 'T8A', 'DUP', 'T8 Twelve',   'Common Stock', 'ZE', 'DUP.ZA', now()),
  ('BBGT8SDA', 'BBGT8SDC', 'T8CLSD', 'T8A', 'DUP', 'T8 Thirteen', 'Common Stock', 'ZE', 'DUP.ZA', now());
do $$
declare r jsonb;
begin
  r := market.promote_share_classes(array['BBGT8SCA', 'BBGT8SDA'], 10);
  if (r ->> 'promoted')::int <> 1 then
    raise exception 'two classes sharing a symbol should promote exactly one: %', r;
  end if;
  if exists (select 1 from market.promotion_candidate where share_class_figi in ('T8CLSC', 'T8CLSD')) then
    raise exception 'the class whose symbol is now held is still a candidate';
  end if;
  raise notice 'ok  one symbol is promoted once';
end $$;

-- 6. The worker runs a wave as itself, and the public cannot.
insert into market.venue_listing (figi, composite_figi, share_class_figi, exch_code, ticker, name,
                                  security_type, country_iso2, provider_symbol, last_seen_at) values
  ('BBGT8SEA', 'BBGT8SEC', 'T8CLSE', 'T8A', 'FOT', 'T8 Fourteen', 'Common Stock', 'ZE', 'FOT.ZA', now());
set local role ingest_rw;
do $$
begin
  if (market.promote_share_classes(array['BBGT8SEA'], 10) ->> 'promoted')::int <> 1 then
    raise exception 'as ingest_rw, a wave promoted nothing';
  end if;
  raise notice 'ok  the worker can run a wave';
end $$;
reset role;
do $$
begin
  if has_function_privilege('anon', 'market.promote_share_classes(text[], integer)', 'EXECUTE') then
    raise exception 'anon can run a wave';
  end if;
  if has_table_privilege('ingest_rw', 'market.promotion_policy', 'UPDATE') then
    raise exception 'the worker can rewrite its own policy';
  end if;
  raise notice 'ok  only the worker and the service role run a wave';
end $$;

-- 7. A line Yahoo could not price waits 90 days; one it priced, or refused long ago, does not.
insert into market.venue_listing (figi, composite_figi, share_class_figi, exch_code, ticker, name,
                                  security_type, country_iso2, provider_symbol, last_seen_at) values
  ('BBGT8SJA', 'BBGT8SJC', 'T8CLSJ', 'T8A', 'JAY', 'T8 Jay',  'Common Stock', 'ZE', 'JAY.ZA', now()),
  ('BBGT8SKA', 'BBGT8SKC', 'T8CLSK', 'T8A', 'KAY', 'T8 Kay',  'Common Stock', 'ZE', 'KAY.ZA', now()),
  ('BBGT8SLA', 'BBGT8SLC', 'T8CLSL', 'T8A', 'ELL', 'T8 Ell',  'Common Stock', 'ZE', 'ELL.ZA', now());
insert into market.promotion_probe (figi, outcome, symbol, source_code, observed_at) values
  ('BBGT8SJA', 'absent', 'JAY.ZA', 'yfinance', now() - interval '10 days'),
  ('BBGT8SKA', 'absent', 'KAY.ZA', 'yfinance', now() - interval '100 days'),
  ('BBGT8SLA', 'priced', 'ELL.ZA', 'yfinance', now() - interval '10 days');
do $$
declare got text;
begin
  select string_agg(share_class_figi, ',' order by share_class_figi) into got
    from market.promotion_candidate where share_class_figi in ('T8CLSJ', 'T8CLSK', 'T8CLSL');
  if got is distinct from 'T8CLSK,T8CLSL' then
    raise exception 'the candidates among the probed lines are %, expected T8CLSK,T8CLSL', got;
  end if;
  raise notice 'ok  a line Yahoo could not price waits 90 days';
end $$;

rollback;
