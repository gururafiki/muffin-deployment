-- FILINGS HOLDING A NON-POSITIVE REVENUE SPLIT ARE READ AGAIN (umbrella docs/deferred/
-- 2026-10-04-the-historical-segment-backlog-is-rising.md, closed by this change).
--
-- The segment partitioner placed two kinds of revenue split that are not splits of a company:
--
--   * a split RECONCILED TO A TOTAL OF ZERO OR LESS. A filing can tag a contra or adjustment line
--     with a revenue concept and a negative value, and the members' sum matched it: Radiant
--     Logistics against -103,000, Univest's 337 m split against -9.2 m.
--   * an INHERITED split totalling zero or less. A bucket inherits its partition from the bucket
--     placing the most members (so segment assets and profit can be placed at all), and a revenue
--     bucket that inherits it can sum to nothing.
--
-- Measured 2026-11-21 over the raw table (revenue, partition > 0): 7,334 groups against a target
-- <= 0, 2,982 summing to less than 0 and 8,098 to exactly 0 (all-zero members, which no split of a
-- company holds), in 6,593 filings: SEC 6,550, DART 37, NSE 6, CNINFO 0. About a third are
-- cross-tab cells, which the parser groups under their parent and judges by the same rules.
-- muffin-ingest#185 refuses both: a revenue target must be positive, and an inherited revenue split
-- totalling zero or less is unplaced (partition 0). Segment operating income is untouched, because
-- it legitimately reconciles to a loss.
--
-- So the filings that hold one are put behind the parser, as the re-queues of 2026-11-15 and
-- 11-16 did: parser version 0, `segments_parsed_at` kept, so each lane's `every_…_was_read` check
-- reports a re-read in progress. Stage 2 then retracts the filing's rows by accession and writes
-- what the parser now produces. Most SEC instances were parsed by the edge and are not in Dagster
-- raw, so their re-read fetches them again (~6,500 documents, paced by the `sec` pool).
--
-- A group is what the parser judges: one filing's revenue split for one axis, parent, period and
-- partition. Grouping more coarsely would hide a non-positive partition behind a positive one
-- beside it (the guard's fixture holds exactly that).
--
-- ORDER: the parser rolls first. A re-queue spent while the old parser could still run re-reads
-- each filing into the same split (the 2026-09-07 CNINFO re-walk, recorded in CLAUDE.md).

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'segments-requeue-non-positive-2026-11-21') then
    raise notice 'segments-requeue-non-positive: already applied';
    return;
  end if;

  with bad as (
    select distinct g.security_id, g.accession_number
      from market.security_segment g
     where g.metric_code = 'revenue'
       and g.partition_id > 0
       and g.accession_number is not null
     group by g.security_id, g.accession_number, g.axis, g.parent_key, g.period_type,
              g.period_start, g.period_ending, g.partition_id
    having sum(g.value) <= 0 or min(g.reconciled_to) <= 0
  )
  update market.security_filing f
     set segments_parser_version = 0
    from bad
   where f.security_id = bad.security_id
     and f.accession_number = bad.accession_number
     and coalesce(f.segments_parser_version, 0) <> 0;  -- read, and not already behind the parser
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'segments-requeue-non-positive-2026-11-21',
    format('re-queued %s filings holding a revenue split that totals, or is reconciled to, zero or less', n));
  raise notice 'segments-requeue-non-positive: re-queued % rows', n;
end $$;
