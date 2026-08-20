-- One country + one category = ONE enabled series, and a disabled one stays disabled.
--
-- WHY THIS IS A TEST. Migration 83 drove all 42 candidate FRED ids before seeding, and still
-- shipped three defects, because "does it return rows" is not the whole question:
--
--   * ten CPI series returned rows to a 2025-01-01 probe and NOTHING to the resource's 400-day
--     window — the family stopped publishing at 2025-04-01, so "latest 2.311289" was April 2025
--     read as current;
--   * `us-unemployment-fred` answered with data ELEVEN MONTHS old beside a current OECD series;
--   * and both would have rendered on the same country panel, two rows labelled the same thing,
--     disagreeing, with no way to tell which to believe.
--
-- The duplicate is the part a test can hold. Staleness is visible in the UI (the panel prints the
-- age); two contradictory rows are not.

\set ON_ERROR_STOP on

begin;

-- 1. NO COUNTRY+CATEGORY HAS TWO ENABLED SERIES, for the categories where a second one is a
--    contradiction rather than a different instrument. `rates` is excluded on purpose: a 10-year
--    yield, EFFR, SOFR and the yield curve are four instruments, not four answers.
do $$
declare bad text;
begin
  select string_agg(t.dup, '; ') into bad from (
    select country_iso2 || ' ' || category || ': ' || string_agg(code, ', ' order by code) as dup
      from market.macro_indicator
     where enabled and country_iso2 is not null
       and category in ('inflation','labour','growth')
     group by country_iso2, category
    having count(*) > 1
  ) t;
  if bad is not null then
    raise exception
      'a country+category has more than one enabled series (%) — both render on the same panel, labelled the same thing, and a reader has no way to tell which to believe', bad;
  end if;
end $$;

-- 2. THE CPI FAMILY THAT STOPPED PUBLISHING IS DISABLED. Re-enabling it puts a permanently empty
--    row on ten country pages.
do $$
declare n integer;
begin
  select count(*) into n from market.macro_indicator
   where enabled and provider = 'fred' and params->>'symbol' like 'CPALTT01%';
  if n <> 0 then
    raise exception
      '% FRED CPALTT01 series are enabled — that family last published 2025-04-01, outside the resource''s 400-day window, so each is a permanently empty panel row', n;
  end if;
end $$;

-- 3. A DISABLED SERIES SURVIVES THE SEED RE-RUNNING. Migrations re-apply on EVERY deploy, so an
--    `on conflict do update` that touched `enabled` would silently re-enable all of them next
--    deploy. Proven by re-applying the real seed over the disabled state.
\i stack/supabase/migrations/082-macro-is-a-catalogue-not-a-hardcoded-list.sql
\i stack/supabase/migrations/083-fred-fills-the-gap-econdb-left.sql

do $$
declare n integer;
begin
  select count(*) into n from market.macro_indicator
   where enabled and provider = 'fred' and params->>'symbol' like 'CPALTT01%';
  if n <> 0 then
    raise exception
      'the seed RE-ENABLED % disabled series — `on conflict do update` must never touch `enabled`, or every deploy undoes an operator''s decision', n;
  end if;
end $$;

-- 3b. THE DUPLICATE RULE ACTUALLY FIRES. Statements 1 and 2 of migration 85 already cover every
--     duplicate in today's data, which makes statement 3 a no-op against it — an untested
--     generalisation is decoration. So: introduce a NEW duplicate and re-run the migration.
insert into market.macro_indicator
  (code, name, category, route, provider, params, country_iso2, frequency, unit, value_is_fraction, sort_order)
values ('es-cpi-fred-probe', 'Spain inflation (probe)', 'inflation', '/api/v1/economy/fred_series',
        'fred', '{"symbol":"PROBE"}'::jsonb, 'ES', 'monthly', 'percent', false, 99)
on conflict (code) do update set enabled = true;
-- An enabled NON-fred series for the same country+category is what the rule keys on.
insert into market.macro_indicator
  (code, name, category, route, provider, params, country_iso2, frequency, unit, value_is_fraction, sort_order)
values ('es-cpi-probe', 'Spain inflation (oecd probe)', 'inflation', '/api/v1/economy/cpi',
        'oecd', '{}'::jsonb, 'ES', 'monthly', 'percent', true, 98)
on conflict (code) do update set enabled = true;

\i stack/supabase/migrations/085-a-series-that-returns-rows-can-still-be-a-year-stale.sql

do $$
declare still_on boolean;
begin
  select enabled into still_on from market.macro_indicator where code = 'es-cpi-fred-probe';
  if still_on then
    raise exception
      'the duplicate RULE did not fire — a fred series survived alongside an enabled non-fred series for the same country and category, which is the shape a future seed will reintroduce';
  end if;
  select enabled into still_on from market.macro_indicator where code = 'es-cpi-probe';
  if not still_on then
    raise exception 'the rule disabled the PREFERRED provider instead of the duplicate';
  end if;
end $$;

-- 4. THE SERIES THAT GENUINELY ADD COVERAGE ARE STILL ON. Disabling by rule must not take the
--    10-year yields and the non-US unemployment with it — those have no OECD equivalent and are
--    the reason FRED was added at all.
do $$
declare yields integer; labour integer;
begin
  select count(*) into yields from market.macro_indicator
   where enabled and provider = 'fred' and params->>'symbol' like 'IRLTLT01%';
  -- ALL of them, named individually where it matters: a threshold of 10 passed even when the US
  -- yield was wrongly disabled, because 12 others survived.
  if yields < 13 then
    raise exception 'only % of 13 FRED 10y-yield series remain enabled — the rule disabled more than duplicates', yields;
  end if;
  if not (select enabled from market.macro_indicator where code = 'us-10y-yield-fred') then
    raise exception
      'us-10y-yield-fred was disabled — a 10y yield, EFFR, SOFR and the yield curve are four INSTRUMENTS, not four answers to one question, so `rates` must not be swept by the duplicate rule';
  end if;
  select count(*) into labour from market.macro_indicator
   where enabled and provider = 'fred' and category = 'labour';
  if labour < 8 then
    raise exception 'only % FRED unemployment series remain enabled — non-US labour has no OECD equivalent', labour;
  end if;
end $$;

rollback;
