-- A PROGRESSIVE THROTTLE MARKED THAILAND AGAIN, ONE DAY AFTER THE FIRST REPAIR.
--
-- Migration 171 cleared exactly this on 2026-09-04 and the resource was gated so it could not
-- recur. It recurred on 2026-09-05: ten more Thai securities — Siam City Cement, Thai Union,
-- Carabao, Central Retail, TMBThanachart and five more — marked in a single run, each holding
-- recent bars that MOVE. `market.data_defect.contradicted_negative_cache` had been reporting
-- 10 then 12 for two days, which is what surfaced it.
--
-- WHY THE FIRST GATE WAS NOT ENOUGH. The control probe was gated on `isolatedAnswered === 0` —
-- "if not one isolated call answered, ask a control symbol". yfinance throttles PROGRESSIVELY: it
-- answers some symbols and silently omits others from a 200. So some isolated calls succeed, the
-- counter is non-zero, the probe never runs, and the refused symbols are marked as permanently
-- unanswerable. Confirmed in one measurement: `SCCC-R.BK` and `CCET-R.BK` each answered 25 bars,
-- and minutes later returned nothing — as did AAPL, which is the throttle made visible.
--
-- Two surface theories were checked and died first, as they did yesterday: the Thai symbols carry
-- Bloomberg board suffixes (`SCCC-R.BK`, `TIPH/F.BK`), and both the suffixed and plain spellings
-- answer identically, so it is not a spelling problem; and the series are not thin.
--
-- The recurrence is prevented in the RESOURCE — the probe now runs on any run that would mark —
-- and `logic-check` pins the stronger expression while failing on the weaker one it replaces.
-- This file only clears what the old gate let through.
--
-- ONE-SHOT, because migrations re-run on every deploy and this is a data repair. A recurring
-- "clear any mark with bars" rule is what migration 055's header forbids: a money-market line has
-- a bar every day and one distinct close for ever, so it legitimately yields no return and earns
-- its mark honestly. THE PREDICATE IS THEREFORE THE SAME ONE THE DEFECT VIEW ASSERTS — bars that
-- MOVE, not bars — so this clears exactly the rows that view calls contradicted, and nothing else.

\set ON_ERROR_STOP on

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'clear-progressive-throttle-marks-0905') then
    raise notice '  --  progressive-throttle marks already cleared, skipping';
    return;
  end if;

  update market.security s
     set performance_missing_at = null
   where s.performance_missing_at is not null
     -- More than one distinct close in 30 days: the price MOVED, so a return is computable and
     -- the mark says it is not. A single distinct close is an honest mark and is left alone.
     and (select count(distinct p.close) from market.security_price p
           where p.security_id = s.security_id and p.date > current_date - 30) > 1
     -- And the series is live, not a delisted line whose last bars happen to differ.
     and exists (select 1 from market.security_price p
                  where p.security_id = s.security_id and p.date > current_date - 7);
  get diagnostics n = row_count;

  insert into market.one_shot (key) values ('clear-progressive-throttle-marks-0905');
  raise notice '  --  cleared % marks the prices contradict', n;
end $$;

notify pgrst, 'reload schema';
