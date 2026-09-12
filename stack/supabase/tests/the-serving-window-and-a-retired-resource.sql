-- TWO RULES THE D2 CUTOVER NEEDED AND DID NOT HAVE, both found by verifying the cutover.
--
-- Neither failure is visible as an error. The first is a chart that takes twelve round trips
-- instead of one; the second is ten false alarms on the morning after a deliberate retirement.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Windowland','ZW',false)
  on conflict (iso2) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009601', 'T96 Windowed', 'equity', 'ZW')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T96WIN', '00000000-0000-0000-0000-000000009601', 'yfinance')
on conflict (kind_code, value) do nothing;

-- THREE BARS THAT MAKE THE CANDIDATE RULES DISAGREE. An unbounded daily arm returns all three; a
-- bounded one returns the two inside the window. The ANCIENT bar is what separates them, and it
-- must fall in a DIFFERENT ISO WEEK from the others or the weekly assertion below cannot tell
-- "weekly is unbounded" from "weekly happens to carry the recent bars too".
insert into market.price_bar (security_id, trade_date, close, source_code) values
  ('00000000-0000-0000-0000-000000009601', current_date - 2,    10, 'yfinance'),
  ('00000000-0000-0000-0000-000000009601', current_date - 30,   20, 'yfinance'),
  ('00000000-0000-0000-0000-000000009601', current_date - 3000, 30, 'yfinance')
on conflict (security_id, trade_date) do update set close = excluded.close;

refresh materialized view market.symbol_security;

do $$
declare n_daily int; n_weekly int; has_ancient boolean;
begin
  select count(*) into n_daily
    from market.price_series where symbol = 'T96WIN' and grain = 'daily';
  select count(*) into n_weekly
    from market.price_series where symbol = 'T96WIN' and grain = 'weekly';
  select exists (select 1 from market.price_series
                  where symbol = 'T96WIN' and grain = 'daily' and date < current_date - 400)
    into has_ancient;

  -- 1. THE DAILY ARM IS BOUNDED. Measured on the live database the morning after the cutover,
  --    AAPL went 275 rows -> 11,528 when this arm moved onto `price_bar`; the app pages at 1000
  --    and therefore made twelve round trips to draw at most 365 days.
  if has_ancient then
    raise exception 'the daily series carries a bar older than the serving window — it grows without bound and the app pages through all of it';
  end if;
  if n_daily <> 2 then
    raise exception 'expected the 2 bars inside the window, got %', n_daily;
  end if;

  -- 2. AND THE WEEKLY ARM IS NOT. It is what a 3Y/5Y chart reads, and it is what the 13
  --    securities of 11,716 whose last bar predates the window keep. Bounding both is the
  --    plausible over-correction, and without this assertion it passes clean.
  if n_weekly <> 3 then
    raise exception 'the weekly series lost history — expected 3 distinct weeks, got %', n_weekly;
  end if;
end $$;

-- ── `scheduled` MUST MEAN ENABLED, NOT MERELY PRESENT ────────────────────────────────────────
--
-- The fixture needs BOTH rows. With only the disabled one, "exists" and "exists and enabled"
-- both yield an empty `scheduled` set for it and the mutation passes clean; the enabled row is
-- what makes the two rules disagree.
-- `position` is NOT NULL with no default: it is the rotation slot, and a control table that
-- orders its own work cannot have an unordered row.
insert into market.cron_resource (resource, enabled, position) values
  ('t96-retired', false, 9601), ('t96-live', true, 9602)
on conflict (resource) do update set enabled = excluded.enabled;

insert into market.refresh_run (resource, started_at, finished_at, ok, skipped) values
  ('t96-retired', now() - interval '40 days', now() - interval '40 days', true, false),
  ('t96-retired', now() - interval '20 days', now() - interval '20 days', true, false),
  ('t96-live',    now() - interval '20 days', now() - interval '20 days', true, false);

do $$
declare retired_scheduled boolean; live_scheduled boolean;
begin
  select scheduled into retired_scheduled from market.resource_health where resource = 't96-retired';
  select scheduled into live_scheduled    from market.resource_health where resource = 't96-live';

  -- A RETIRED RESOURCE IS NOT LATE. The D2 cutover disables its ten rows rather than deleting
  -- them, so `exists` stays true and the stalled alert would have named all ten within twelve
  -- hours of a retirement that was deliberate.
  if retired_scheduled is not false then
    raise exception 'a disabled resource still reads as scheduled — the stalled-resource alert will fire on every retirement';
  end if;

  -- AND A LIVE ONE STILL IS, or the fix silences the alert entirely, which is worse than the
  -- false positives it was written to stop.
  if live_scheduled is not true then
    raise exception 'an enabled resource reads as unscheduled — the alert can no longer fire at all';
  end if;
end $$;

rollback;
