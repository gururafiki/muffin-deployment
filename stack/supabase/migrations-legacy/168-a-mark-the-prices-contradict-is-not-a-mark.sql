-- A NEGATIVE CACHE THAT THE PRICE TABLE CONTRADICTS IS NOT EVIDENCE — clear it, ONCE.
--
-- `performance_missing_at` records "we asked the provider for this security's returns and it had
-- none". 27 securities carry that mark while `security_price` holds bars for them from the last
-- seven days whose closes MOVE — so the returns are computable from data this pipeline already
-- has, and the mark is excluding a security that can plainly be answered.
--
-- WHY THAT MATTERS BEYOND THE FLAG. The mark does not merely stop a refetch: `security-performance`
-- retracts a period only for symbols a run ANSWERS, so a marked security keeps whatever returns
-- were last written and serves them indefinitely while its price moves daily. Migration 055 and
-- the 2026-08-14 incident are the same shape at 2,548 securities; this is the residue.
--
-- MEASURED 2026-09-04 before writing this. 437 securities carry the mark; 27 are contradicted, and
-- they span SIXTEEN countries — TH 10, US 2, TW 2, and one each in PT, CA, KR, GB, DE, GR, AT, FI,
-- AU, PL, CN, NO, IL. That spread is the reason this is a repair rather than a provider-coverage
-- question: the 437 as a whole ARE coverage-shaped (TW 115, PH 42, AE 36 — the Philippines and the
-- UAE sit outside keyless yfinance and earn their marks honestly), while the contradicted 27 are a
-- thin tail across every market, which is what a marking bug looks like. 15 of the 27 were marked
-- on 2026-08-11, in the window of the known mass-marking incident.
--
-- ONE SHOT, NOT A RECURRING CLEAR. Running this on every deploy would defeat the negative cache
-- outright — the exact failure migration 055's header warns about, reintroduced as its own fix. A
-- security the provider genuinely cannot serve must keep its mark and stop being re-asked.
--
-- THE RECURRENCE IS NOT FIXED HERE and that is deliberate: 11 of the 27 were marked between
-- 2026-08-28 and 09-03, so something is still marking securities it should not. Finding it means
-- reading `security-performance`'s isolation path against a live throttle, which is its own piece
-- of work — recorded in todos.md. This clears the evidence that is already known to be wrong.
do $$
declare n integer;
begin
  if exists (select 1 from market.one_shot where key = 'clear-contradicted-performance-marks') then
    return;
  end if;

  with contradicted as (
    select s.security_id
      from market.security s
     where s.performance_missing_at is not null
       -- MOVING bars, not merely bars. A money-market line has a bar every day and one distinct
       -- close for ever, so it legitimately yields no return and earns its mark — migration 055's
       -- header predicted exactly this, and 15 of 29 rows were that shape when the guard was
       -- first written. Holding bars is not evidence; holding bars that MOVE is.
       and (select count(distinct p.close) from market.security_price p
             where p.security_id = s.security_id
               and p.date > current_date - 30) > 1
       and exists (select 1 from market.security_price p
                    where p.security_id = s.security_id
                      and p.date > current_date - 7)
  )
  update market.security s
     set performance_missing_at = null
    from contradicted c
   where s.security_id = c.security_id;
  get diagnostics n = row_count;

  insert into market.one_shot (key) values ('clear-contradicted-performance-marks');
  raise notice '  168: cleared % contradicted performance marks', n;
end $$;
