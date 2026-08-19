-- Macro series are a CONTROL TABLE, served in the unit they claim, and a redeploy must not
-- re-enable one an operator switched off.
--
-- WHY THIS IS A TEST. Three things here fail silently:
--   1. A FRACTION served as a PERCENT. OECD returns inflation as 0.0239 for 2.39%. This pipeline
--      has already rendered NVIDIA at a 46% dividend yield from exactly this confusion — wrong by
--      two orders of magnitude and entirely plausible-looking.
--   2. A yield curve flattened. It is (date, maturity) -> rate, not (date) -> rate; without the
--      `dimension` key every maturity would collide on the primary key and the curve would be
--      whichever maturity was written last.
--   3. A disabled series coming back. Migrations re-run on EVERY deploy, so an `on conflict do
--      update` that touches `enabled` silently reverses an operator's decision to switch off a
--      series that started failing.

\set ON_ERROR_STOP on

begin;

-- 1. THE SEED IS A CONTROL TABLE, and only carries series measured to return rows.
do $$
declare n integer; bad integer;
begin
  select count(*) into n from market.macro_indicator;
  if n < 8 then raise exception 'expected the macro catalogue to be seeded, got % rows', n; end if;

  -- econdb indicator DATA returns 204 for every symbol (measured 2026-08-19); its catalogue is
  -- free but the series are not. Seeding one would put a permanently empty panel on a page.
  select count(*) into bad from market.macro_indicator where provider = 'econdb';
  if bad <> 0 then
    raise exception
      '% series are seeded against econdb — its indicator DATA answers 204 without a key, so those panels can never fill', bad;
  end if;
end $$;

-- 2. A FRACTION IS SERVED AS A PERCENT, and a value that is already a percent is left alone.
insert into market.macro_observation (indicator_code, as_of, dimension, value) values
  ('us-cpi', current_date, '', 0.0239),      -- OECD sends a fraction
  ('us-gdp-real', current_date, '', 21500)   -- an index level, not a fraction
on conflict (indicator_code, as_of, dimension) do update set value = excluded.value;

do $$
declare v numeric;
begin
  select value into v from market.macro_current where code = 'us-cpi';
  if v is distinct from 2.3900 then
    raise exception
      'us-cpi serves % (expected 2.3900) — OECD sends 0.0239 for 2.39%%, and serving the raw fraction understates inflation a hundredfold while looking like a plausible number', v;
  end if;
  select value into v from market.macro_current where code = 'us-gdp-real';
  if v is distinct from 21500 then
    raise exception 'us-gdp-real serves % (expected 21500) — an index level must NOT be multiplied by 100', v;
  end if;
end $$;

-- 3. A YIELD CURVE KEEPS ITS MATURITIES. Without `dimension` in the primary key these eleven rows
--    would collapse to one and the "curve" would be a single number.
insert into market.macro_observation (indicator_code, as_of, dimension, value) values
  ('us-yield-curve', current_date, 'month_1', 0.0379),
  ('us-yield-curve', current_date, 'year_2',  0.0361),
  ('us-yield-curve', current_date, 'year_10', 0.0422),
  ('us-yield-curve', current_date, 'year_30', 0.0455)
on conflict (indicator_code, as_of, dimension) do update set value = excluded.value;

do $$
declare n integer; ten numeric;
begin
  select count(*) into n from market.macro_observation
   where indicator_code = 'us-yield-curve' and as_of = current_date;
  if n <> 4 then
    raise exception
      'the yield curve stored % points (expected 4) — a term structure is (date, maturity), and without maturity in the key every point overwrites the last', n;
  end if;
  select value into ten from market.macro_current
   where code = 'us-yield-curve' and dimension = 'year_10';
  if ten is distinct from 4.2200 then
    raise exception '10y serves % (expected 4.2200)', ten;
  end if;
end $$;

-- 4. THE LATEST VALUE WINS, per dimension. A serving view that did not pick would return every
--    historical observation and the page would render an arbitrary one.
insert into market.macro_observation (indicator_code, as_of, dimension, value) values
  ('us-cpi', current_date - 40, '', 0.0310)
on conflict (indicator_code, as_of, dimension) do update set value = excluded.value;

do $$
declare n integer; v numeric;
begin
  select count(*), max(value) into n, v from market.macro_current where code = 'us-cpi';
  if n <> 1 then raise exception 'macro_current returned % rows for one series (expected 1)', n; end if;
  if v is distinct from 2.3900 then
    raise exception 'macro_current served the OLDER observation (%) — it must be the latest', v;
  end if;
end $$;

-- 5. A DISABLED SERIES STAYS DISABLED AND IS NOT SERVED. This is the one a redeploy would undo:
--    migrations re-run every deploy, so `on conflict do update` must not touch `enabled`.
update market.macro_indicator set enabled = false where code = 'us-cpi';
do $$
declare n integer;
begin
  select count(*) into n from market.macro_current where code = 'us-cpi';
  if n <> 0 then raise exception 'a disabled series is still being served'; end if;
end $$;

-- …AND IT SURVIVES A REDEPLOY. This is the assertion that actually matters, and it needs the REAL
-- migration re-applied over the disabled state — asserting only that `enabled = false` hides the
-- series proves nothing about whether the next deploy turns it back on. Migrations re-run in full
-- on EVERY deploy, so an `on conflict do update` that touches `enabled` silently reverses an
-- operator switching off a series that started failing. Same pattern as
-- `securities-are-typed-from-the-filing.sql`: seed the production shape, then \i the real file.
\i stack/supabase/migrations/82-macro-is-a-catalogue-not-a-hardcoded-list.sql

do $$
declare on_again boolean;
begin
  select enabled into on_again from market.macro_indicator where code = 'us-cpi';
  if on_again then
    raise exception
      'a redeploy RE-ENABLED a series an operator had switched off — `on conflict do update` must not touch `enabled`, or disabling a broken series lasts until the next deploy and no further';
  end if;
end $$;

-- 6. ANON CAN READ, AND CANNOT WRITE. The app reads with the public anon key; a public key that
--    can write observations is a public key that can rewrite the inflation rate.
do $$
begin
  if not has_table_privilege('anon', 'market.macro_current', 'select') then
    raise exception 'anon cannot read macro_current — the app reads with the anon key';
  end if;
  if has_table_privilege('anon', 'market.macro_observation', 'insert') then
    raise exception 'anon can INSERT observations — the anon key is public and is in runtime-config.js';
  end if;
  if not has_table_privilege('service_role', 'market.macro_observation', 'insert') then
    raise exception 'service_role cannot write observations, so the resource could never fill them';
  end if;
end $$;

rollback;
