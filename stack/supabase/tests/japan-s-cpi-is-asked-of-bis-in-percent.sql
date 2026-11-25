-- `jp-cpi` asks BIS, and BIS's percentage is served as it is (migration 20261125130000).
--
-- WHY THIS IS A TEST. OECD states inflation as a FRACTION and `macro_current` multiplies a
-- fraction by 100. BIS states a PERCENT. Left flagged as a fraction, Japan's 2.10% would be served
-- as 209.79%: wrong by two orders of magnitude, the trap this file family already records for
-- OECD's own figures.

\set ON_ERROR_STOP on

begin;

do $$
declare r record;
begin
  select provider, route, params, value_is_fraction, enabled into r
    from market.macro_indicator where code = 'jp-cpi';
  if not found then
    raise exception 'jp-cpi is not catalogued';
  end if;
  if r.provider is distinct from 'bis' or r.route is distinct from '/api/v1/data/WS_LONG_CPI'
     or r.params is distinct from '{"key": "M.JP.771"}'::jsonb then
    raise exception 'jp-cpi asks % % %, not BIS WS_LONG_CPI M.JP.771', r.provider, r.route, r.params;
  end if;
  if r.value_is_fraction then
    raise exception 'jp-cpi is flagged as a fraction: BIS states a percent, served a hundredfold';
  end if;
  if not r.enabled then
    raise exception 'jp-cpi is disabled';
  end if;
end $$;

insert into market.macro_observation (indicator_code, as_of, dimension, value) values
  ('jp-cpi', current_date, '', 2.097902)
on conflict (indicator_code, as_of, dimension) do update set value = excluded.value;

do $$
declare v numeric;
begin
  select value into v from market.macro_current where code = 'jp-cpi';
  -- `macro_current` rounds only what it multiplies; a percent is served as stored.
  if v is distinct from 2.097902 then
    raise exception 'jp-cpi serves % (expected 2.097902): BIS sends 2.097902 for 2.10%%', v;
  end if;
end $$;

\echo ok japan-s-cpi-is-asked-of-bis-in-percent
rollback;
