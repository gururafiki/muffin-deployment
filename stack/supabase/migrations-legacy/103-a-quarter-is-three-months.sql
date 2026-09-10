-- A QUARTER IS THREE MONTHS, NOT YEAR-TO-DATE.
--
-- `security-xbrl` classified a fact as quarterly from its `fp` label and bounded the duration on
-- ONE side only (`days > 200` rejected). XBRL's Q2 and Q3 duration facts are frequently
-- YEAR-TO-DATE — six and nine months — and still carry `fp: "Q2"`, so the nine-month figure was
-- dropped and **the six-month one was kept**.
--
-- Measured in production 2026-08-21:
--
--   AAPL revenue, period_type 'quarter', 2026-03-28   254,940,000,000
--   AAPL revenue, period_type 'quarter', 2025-03-29   219,659,000,000
--   AAPL revenue, period_type 'annual',  2025-09-27   416,161,000,000
--
-- 61% and 53% of a full year inside a single quarter. The quarterly chart spiked every Q2, a TTM
-- built on it would have been badly wrong, and nothing in any row count or resource response
-- showed it — `security-xbrl` reported success throughout.
--
-- The resolver now bounds a quarter on both sides (80..100 days) and an annual period above as
-- well as below (300..400), so a multi-year cumulative cannot enter either. A YTD fact is simply
-- SKIPPED: the discrete quarter is derivable as `YTD(n) - YTD(n-1)` within a fiscal year, but that
-- is a separate change with its own failure modes, and a missing quarter is honest where a
-- six-month figure labelled a quarter is not.
--
-- ── THE ROWS ALREADY WRITTEN ────────────────────────────────────────────────────────────────
--
-- Deleting them is enough: `pending_xbrl` is keyed on when a filer was last ASKED, so clearing
-- `xbrl_fetched_at` re-queues every filer and the corrected resolver rewrites the series. Only
-- `sec-xbrl` quarters are affected — the statement-derived path never produced quarters at all
-- (yfinance returns annual periods; measured, median gap 365 days).
--
-- BEHIND `one_shot`, because a repair is not idempotent the way a schema statement is: migrations
-- re-run on every deploy, and a delete-and-refetch that fires every time would throw away good
-- data and re-spend the provider budget for ever.

do $$
declare v_deleted integer;
begin
  if exists (select 1 from market.one_shot where key = 'drop-ytd-contaminated-quarters') then
    return;
  end if;

  delete from market.security_metric
   where source_code = 'sec-xbrl'
     and period_type = 'quarter';
  get diagnostics v_deleted = row_count;

  -- Derived rows computed FROM those quarters go too — free cash flow and total debt inherit the
  -- contamination and would otherwise survive as arithmetic over deleted inputs.
  delete from market.security_metric
   where source_code = 'derived'
     and period_type = 'quarter';

  -- Re-queue every filer. `pending_xbrl` asks "who has not been read in 30 days", so this is what
  -- makes the corrected resolver run rather than the backlog reporting itself current.
  update market.security set xbrl_fetched_at = null where cik is not null;

  insert into market.one_shot (key, reason)
  values ('drop-ytd-contaminated-quarters',
          format('deleted %s sec-xbrl quarterly rows contaminated with year-to-date figures; AAPL 2026-03-28 read 254,940M against a full year of 416,161M', v_deleted));
end $$;

notify pgrst, 'reload schema';
