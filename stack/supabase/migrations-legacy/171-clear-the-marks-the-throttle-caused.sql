-- CLEAR THE MARKS THE THROTTLE CAUSED — the second and, this time, the LAST one-shot.
--
-- Migration 168 cleared 27 contradicted `performance_missing_at` marks and said the recurrence was
-- unproven. It recurred within four hours: ten more, all Thai, all written in a SINGLE run at
-- 2026-09-04T22:35, each holding daily bars back to 2006-2007 and zero performance rows.
--
-- THE DIFFERENCE BETWEEN THIS AND 168 IS THAT THE CAUSE IS NOW FIXED. 168 was a repair with the
-- cause unknown, which is why it came back; this one follows the fix in the same release, so the
-- population it clears cannot be re-created by the same route.
--
-- The cause, for the record: `security-performance` isolates a missed symbol by asking about it
-- ALONE and treats an empty answer as evidence about that symbol. Its own comment asserted that
-- "a throttle makes every isolation throw, so a throttled run marks NOTHING" — and that is false
-- for yfinance, which signals a throttle with an empty 200. Nothing throws, nothing answers, and
-- every isolated symbol looks individually dead. Seventh instance of that shape in this codebase.
-- Both surface explanations were measured and died: 34 of 40 `-R.BK` NVDR symbols carry performance
-- perfectly well, and the series are nineteen years deep rather than young. Marking is now gated on
-- a control probe, exactly as `fetchWithIsolation` gates its own dead set.
--
-- MOVING bars, not merely bars — a money-market line has a bar every day and one distinct close for
-- ever, so it legitimately yields no return and earns its mark honestly (migration 055's header
-- predicted exactly this, and 15 of 29 rows were that shape when the guard was first written).
do $$
declare n integer;
begin
  if exists (select 1 from market.one_shot where key = 'clear-throttle-caused-performance-marks') then
    return;
  end if;

  with contradicted as (
    select s.security_id
      from market.security s
     where s.performance_missing_at is not null
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

  insert into market.one_shot (key) values ('clear-throttle-caused-performance-marks');
  raise notice '  171: cleared % marks the throttle caused', n;
end $$;
