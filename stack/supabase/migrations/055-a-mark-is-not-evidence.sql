-- A NEGATIVE CACHE SET BY A TALLY IS NOT EVIDENCE — and it froze the data it excluded.
--
-- Measured 2026-08-14. 3,045 securities carried `performance_missing_at`, which excludes them from
-- `pending_performance` for 30 days. 2,548 of them HAD daily price bars written within the previous
-- five days: `security-prices` was being answered for the very securities `security-performance`
-- had recorded as unanswerable. Among them MediaTek (2454.TW), Tapestry (TPR), Ferguson, Royalty
-- Pharma, Edenred, Huaneng Power and ACS — an IBEX 35 constituent. Driving `security-refresh`
-- against TPR and 2454.TW returned all seven periods, a market cap, fundamentals and statements,
-- so the provider was answering and the marks were simply false.
--
-- HOW THEY GOT SET. `security-performance` batches 40 symbols into one call and marked every symbol
-- absent from the response, gated only on "at least one symbol in the batch answered". yfinance
-- throttles PROGRESSIVELY — it answers some symbols and omits others from the same 200, with no
-- error anywhere — so that gate passes during exactly the outage it was meant to catch. 2,297 of
-- these marks were set in a single pass on 08-11. The gate is now per-symbol: a symbol is asked
-- ALONE and only an answer about it on its own can mark it.
--
-- WHY THE MARK ALSO CORRUPTED DATA, which is the part that was invisible. Marking excluded the
-- security from the backlog, so the refresh never revisited it — and the retraction that deletes
-- periods a run stops producing only runs for symbols a run ANSWERS. The old rows therefore
-- survived every later fix. REA.AX, 1803.T, 6674.T and MRP.JO were still serving 1d/1w/1m = 0.00%
-- written on 08-10, four days after their prices had resumed moving daily, because a mark set on
-- 08-12 guaranteed nothing would ever overwrite them. `market-verify` caught the symptom and named
-- the wrong cause: it reported "a delisted instrument is being priced off its final bars" for
-- companies that were trading normally.
--
-- THE TEST USED HERE is the one that settled it: a security with a price bar in the last five days
-- is one the provider answers for, so a `performance_missing_at` on it is contradicted by our own
-- data. Securities with no recent bars keep their mark — those are the ~497 where it is plausible.
--
-- ONE-SHOT, deliberately, and this is the important part. As a recurring rule it would be WRONG:
-- a money-market line like GVMXX has a bar every day and a single distinct close forever, so it
-- legitimately yields no return, earns its mark honestly, and a recurring "has bars, clear the
-- mark" rule would re-ask for it four times a day for ever. This is a repair of a specific
-- incident, not a policy. Recurrence is prevented in the resource, not here.

do $$
declare
  cleared bigint;
begin
  if exists (select 1 from market.one_shot where key = '55-clear-contradicted-performance-marks') then
    return;
  end if;

  with contradicted as (
    select s.security_id
      from market.security s
     where s.performance_missing_at is not null
       and exists (
             select 1
               from market.security_price p
              where p.security_id = s.security_id
                and p.date >= (current_date - interval '5 days')
           )
  )
  update market.security s
     set performance_missing_at = null
    from contradicted c
   where s.security_id = c.security_id;

  get diagnostics cleared = row_count;

  insert into market.one_shot (key, reason) values
    ('55-clear-contradicted-performance-marks',
     format('Cleared %s performance_missing_at marks contradicted by price bars from the last 5 days '
            || '(set by a batch tally during progressive yfinance throttling, 2026-08-11..13).', cleared));
end $$;

notify pgrst, 'reload schema';
