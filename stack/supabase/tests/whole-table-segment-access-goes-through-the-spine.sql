-- WHOLE-TABLE ACCESS TO SEGMENTS GOES THROUGH THE SPINE, NOT THE VIEW.
--
-- `security_segment_current` costs ~2.6 s unfiltered (measured 2026-09-05; ~6 s when migration 158
-- materialised it) and `security_segment_spine` costs 2.8 ms. The spine exists for exactly this.
--
-- `derive_segment_classification` read the VIEW three times in one statement — twice in the CTE
-- chain and once in the retraction `not exists` — which was survivable until the segment backlog
-- began draining on 2026-08-29. It then exceeded the PostgREST role's 8-second timeout and FAILED
-- EVERY DAILY RUN FOR FOUR DAYS while reporting nothing, because a daily resource that dies looks
-- exactly like one that has not run yet. Measured before the fix: > 45,000 ms. After: 102 ms.
--
-- THIS GUARD IS DELIBERATELY BRITTLE — it reads the function's source text. A behavioural test
-- cannot reach it: on a fixture the table is tiny, so BOTH forms complete instantly and the
-- candidate rules agree. What is being protected is a performance property that only exists at
-- production scale, so the only honest offline test is the structural one. Rewording the function
-- fails loudly; reintroducing the view can never pass silently.

\set ON_ERROR_STOP on

begin;

do $$
declare
  src text;
  view_hits int;
  spine_hits int;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'market' and p.proname = 'derive_segment_classification';

  if src is null then
    raise exception 'market.derive_segment_classification() does not exist';
  end if;

  -- Count only FROM/JOIN references, not the prose in the comments, which legitimately names the
  -- view while explaining why it is not read.
  select count(*) into view_hits from regexp_matches(
    src, '(from|join)\s+market\.security_segment_current', 'gi') m;
  select count(*) into spine_hits from regexp_matches(
    src, '(from|join)\s+market\.security_segment_spine', 'gi') m;

  if view_hits > 0 then
    raise exception
      'derive_segment_classification reads security_segment_current % time(s) — that view is ~2.6s unfiltered and this is whole-table access, which is what security_segment_spine exists for. Reading it cost four days of silent daily failures.',
      view_hits;
  end if;

  if spine_hits = 0 then
    raise exception
      'derive_segment_classification reads neither the spine nor the view — the guard has lost its subject and is asserting nothing';
  end if;
end $$;

-- THE CORRELATED SUBQUERY IS THE OTHER HALF. `max(period_ending)` computed per row over
-- security_segment (191,098 rows at the time) is the same answer as one aggregate CTE, proven
-- equivalent on live data (29 rows each, 0 disagreeing) — and it is the difference between a scan
-- per row and a scan.
do $$
declare src text; n int;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'market' and p.proname = 'derive_segment_classification';
  select count(*) into n from regexp_matches(
    src, 'select\s+max\(g2\.period_ending\)', 'gi') m;
  if n > 0 then
    raise exception
      'derive_segment_classification computes max(period_ending) with a correlated subquery % time(s); one `latest` CTE gives the same answer without a scan per row',
      n;
  end if;
end $$;

rollback;
