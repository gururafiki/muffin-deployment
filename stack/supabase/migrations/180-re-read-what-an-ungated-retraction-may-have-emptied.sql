-- RE-READ WHAT AN UNGATED RETRACTION MAY HAVE EMPTIED.
--
-- The per-accession retraction shipped in #306 ran UNCONDITIONALLY after the parse attempt, so a
-- filing whose instance could not be FETCHED — an index lookup returning nothing, a null fetch, or
-- our own size gate refusing the document — had its stored segment rows deleted as if the filing
-- had said nothing. `facts.length === 0` has four causes and only one of them is the filing
-- speaking. Gated in the same change as this migration.
--
-- MEASURED over the ~3.5 hours it was live (#306's migration ran 2026-09-05 16:55 UTC):
--   281 filings took the empty path in the first 3 hours (275 noInstance, 6 tooLarge)
--   security_segment fell 191,098 -> 191,007 — 91 rows net LOST while the drain was ADDING
--
-- WHY A REPAIR IS NEEDED AT ALL, rather than letting the drain fix it. A filing is stamped
-- `segments_parsed_at` whether or not it yielded segments — deliberately, because "this filing
-- discloses none" is a permanent fact about an immutable document. So a filing emptied by the bug
-- is ALSO stamped, and the drain will never return to it. The rows are gone until something
-- re-queues them.
--
-- SCOPE: filings stamped since the bug shipped that currently hold NO segment rows — 534 of the
-- 986 stamped in that window. Most are legitimately empty (a 10-Q with no segment note), and
-- re-reading those simply confirms it; the cost is a few hundred fetches against a backlog already
-- measured in tens of thousands. It is not possible to tell retrospectively which of the 534 were
-- emptied and which were always empty, so the honest scope is all of them. Clearing the stamp is
-- exactly what a re-queue is, and the re-read now runs under the gate, so it either restores the
-- rows or records the same emptiness honestly.
--
-- NOT a parser version bump: that re-queues all ~213,500 filings to repair at most a few hundred,
-- and one is already draining.

\set ON_ERROR_STOP on

do $$
declare requeued bigint;
begin
  if exists (select 1 from market.one_shot where key = 'requeue-after-ungated-retraction') then
    return;
  end if;

  with cleared as (
    update market.security_filing f
       set segments_parsed_at = null, segments_parser_version = null
     where f.segments_parsed_at >= timestamptz '2026-09-05 16:55+00'
       and not exists (
         select 1 from market.security_segment s
          where s.security_id = f.security_id
            and s.accession_number = f.accession_number)
    returning 1
  )
  select count(*) into requeued from cleared;

  raise notice 're-queued % filing(s) that an ungated retraction may have emptied', requeued;
  insert into market.one_shot (key) values ('requeue-after-ungated-retraction');
end $$;

notify pgrst, 'reload schema';
