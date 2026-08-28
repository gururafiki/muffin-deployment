-- A RECURRENCE IS WHAT THE GUARD IS FOR, AND THE FIRST READ FOUND ONE.
--
-- Migration 055 cleared 2,548 contradicted `performance_missing_at` marks on 2026-08-14 and said,
-- correctly, that "recurrence is prevented in the resource, not here". The first production read of
-- `market.data_defect` (migration 134) found **29 more**, marked 08-14, 08-15 and 08-23 — i.e.
-- after that repair. Nothing had been watching, because `refresh_log` keeps one row per resource and
-- market-verify kept a pass/fail bit; a defect that returns is exactly what a nightly bit cannot
-- show and an hourly sample can.
--
-- ── 15 OF THE 29 ARE NOT DEFECTS, AND 055 PREDICTED THEM ──────────────────────────────────────
--
-- Its header warned that a recurring "has bars, clear the mark" rule would be WRONG, because a
-- money-market line has a bar every day and ONE distinct close forever: it legitimately yields no
-- return and earns its mark honestly. Measured here: 15 of the 29 have exactly one distinct close
-- over 30 days — Cementir Holding, OUE REIT, RHI Magnesita, China Galaxy, Guotai Haitong, State
-- Street Global Advisors. Their marks are correct and are LEFT ALONE. Migration 134's predicate now
-- requires the price to MOVE, so the guard no longer reports them at all.
--
-- ── THE OTHER 14 ARE REAL ─────────────────────────────────────────────────────────────────────
--
-- Siam City Cement, Carabao Group, Bangkok Commercial Asset Management, AEON Thana Sinsap, IES
-- Holdings: ordinary operating companies whose prices move daily, marked as yielding no return
-- while `security-prices` was writing them bars off THE SAME endpoint. A mark excludes a security
-- from `pending_performance` for 30 days AND freezes whatever periods it last wrote, because the
-- retraction only runs for symbols a run answers — so these serve stale returns until cleared.
--
-- ONE-SHOT, for the same reason 055 was: this is a repair of specific rows, not a policy. The
-- policy lives in `security-performance`'s per-symbol isolation. If the count comes back, the
-- resource is still wrong and the guard will say so — which is the point of having it.
do $$
declare cleared bigint;
begin
  if exists (select 1 from market.one_shot where key = '135-clear-moving-price-performance-marks') then
    raise notice '  --  135: already applied, skipping';
    return;
  end if;

  with contradicted as (
    select s.security_id
      from market.security s
     where s.performance_missing_at is not null
       -- The SAME test migration 134's guard uses. Written twice would drift; it is asserted
       -- identical by tests/a-defect-view-must-actually-detect.sql.
       and (select count(distinct p.close) from market.security_price p
             where p.security_id = s.security_id and p.date > current_date - 30) > 1
       and exists (select 1 from market.security_price p
                    where p.security_id = s.security_id and p.date > current_date - 7)
  )
  update market.security s
     set performance_missing_at = null
    from contradicted c
   where c.security_id = s.security_id;
  get diagnostics cleared = row_count;

  raise notice '  --  135: cleared % contradicted performance marks (moving price only)', cleared;

  insert into market.one_shot (key, reason) values
    ('135-clear-moving-price-performance-marks',
     'Recurrence of the 055 defect found by market.data_defect on its first read: marks on securities whose price moves daily. The 15 flat-price marks were left alone deliberately.');
end $$;
