-- YAHOO HAS EXACTLY ONE BAR FOR `GELUSD=X`, SO GEL COULD NEVER LEAVE THE BACKLOG.
--
-- Measured 2026-08-21 after fixing the paged probe: the FX history backlog drained 8 -> 4 -> 1 and
-- then stuck on the Georgian lari, which appeared in `historyFor` on every run — the upsert
-- SUCCEEDS, it just writes a single recent bar, so "has a rate older than 90 days" stays false and
-- the currency is re-fetched eight times a day for ever.
--
-- Nothing is wrong and nothing errors. It is pure waste against a free API, and it is the exact
-- pattern this schema already carries four columns for (`figi_missing_at`, `profile_missing_at`,
-- `local_symbol_missing_at`, `performance_missing_at`): A NEGATIVE RESULT IS A RESULT, AND A
-- BACKLOG DEFINED AS "wants X and does not have X" RE-ASKS FOR EVER FOR THE THINGS THAT CAN NEVER
-- HAVE X. Fifth instance.
--
-- 30 days rather than never: a pair Yahoo does not carry today may be quoted next quarter, and the
-- cost of asking again monthly is one request.

alter table market.currency add column if not exists history_missing_at timestamptz;

comment on column market.currency.history_missing_at is
  'Set when the provider was asked for ten years of weekly rates and returned no usable history — Yahoo carries a single bar for some minor pairs. Re-asked after 30 days: a pair not quoted today may be quoted next quarter.';

drop view if exists market.pending_fx_history;
create view market.pending_fx_history as
select c.code as currency_code
from market.currency c
where c.code <> 'USD'
  and (c.history_missing_at is null or c.history_missing_at < now() - interval '30 days')
  -- ANTI-JOIN OVER THE ENTITY, not a filter over rows: "has no rate older than 90 days" is a fact
  -- about the CURRENCY, and a `where` on `fx_rate` would let today's spot row satisfy it.
  and not exists (
    select 1 from market.fx_rate r
     where r.currency_code = c.code
       and r.as_of < (current_date - 90)
  );

comment on view market.pending_fx_history is
  'Currencies with no exchange rate older than 90 days and no recent record of the provider having none — i.e. spot-only and worth asking about. A VIEW rather than a client-side probe because the probe read rows and PGRST_DB_MAX_ROWS silently capped it at 1,000.';

grant select on market.pending_fx_history to service_role;

notify pgrst, 'reload schema';
