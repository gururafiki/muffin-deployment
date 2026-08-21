-- THE FX HISTORY BACKLOG WAS A PAGE, SO IT STOPPED ADVANCING AFTER 1,000 ROWS.
--
-- Migration 109's resource decided which currencies still needed ten years of rates by SELECTING
-- the rows older than 90 days and building a set from them. `PGRST_DB_MAX_ROWS` is 1,000 and the
-- backfill writes ~520 rows per currency, so after two currencies the probe could no longer see
-- past its own page: currencies that HAD been backfilled looked undone and were re-fetched for
-- ever. Measured in production — three consecutive runs returned the identical
-- `historyFor: ['CAD','EUR','HKD','JPY']` while reporting no failures, which reads as throughput.
--
-- Same shape as `pending_industry` re-fetching its first 300 securities for months, and the reason
-- every other backlog in this schema is a VIEW: the server answers "which entities are not done"
-- without the client paging anything.
--
-- A count would have been enough here (`Prefer: count=exact` + `Range: 0-0` returns the true total
-- without fetching rows) — but only per currency, which is 43 round trips to answer one question.
-- The anti-join is one.

drop view if exists market.pending_fx_history;
create view market.pending_fx_history as
select c.code as currency_code
from market.currency c
where c.code <> 'USD'
  -- ANTI-JOIN OVER THE ENTITY, not a filter over rows: "has no rate older than 90 days" is a fact
  -- about the CURRENCY, and a `where` on `fx_rate` would let today's spot row satisfy it.
  and not exists (
    select 1 from market.fx_rate r
     where r.currency_code = c.code
       and r.as_of < (current_date - 90)
  );

comment on view market.pending_fx_history is
  'Currencies with no exchange rate older than 90 days — i.e. spot-only, needing the ten-year weekly backfill. A VIEW rather than a client-side probe because the probe read rows and PGRST_DB_MAX_ROWS silently capped it at 1,000, so the backlog stopped advancing after two currencies and re-fetched them for ever.';

grant select on market.pending_fx_history to service_role;

notify pgrst, 'reload schema';
