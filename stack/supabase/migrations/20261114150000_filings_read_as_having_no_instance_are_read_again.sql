-- FILINGS READ AS HAVING NO INSTANCE ARE READ AGAIN (decided by the user 2026-11-14).
--
-- The edge picked a filing's XBRL instance with `-\d{8}(_htm)?\.xml$`, which rejects every name a
-- filing agent gives it (`scco-20260930x10q_htm.xml`, `form10-q_htm.xml`,
-- `desp20260930_10q_htm.xml`), so such a filing was recorded as having no instance and marked read
-- for good. muffin-ingest#176 widens the rule (the edge's first, then the one `*_htm.xml` SEC
-- extracted) and makes ownership explicit: a row is replaced only by a filing filed no earlier than
-- the one holding it. Measured 2026-11-14, read-only:
--   * the Dagster lane's first wave read 10 of 29 filings as having no instance; 7 of the 11 read
--     with the wider rule carry segments (Southern Copper's 10-Q: 158 facts over three axes);
--   * since 2019-06-15, 64.7% of agent-filed filings have no segment rows against 24.2% self-filed.
--
-- WHAT IS RE-QUEUED: every SEC accounts filing with XBRL, read since inline XBRL began, holding no
-- segment row for its security. That includes filings that DID disclose segments but whose every
-- period a newer filing has since restated; reading them again writes nothing a newer filing holds
-- (`kept_by_newer`), so they cost requests and no correctness. Measured in a rolled-back
-- transaction: 35,540 rows (35,288 filings), 6.1 s.
--
-- AS "BEHIND THE PARSER", NOT "NEVER READ": `segments_parser_version = 0` makes each one due
-- (`coalesce(version, 0) < max(version)`) while `segments_parsed_at` stays, so
-- `every_sec_filing_was_read` reports them as a re-read in progress (WARN) rather than as filings the
-- lane keeps failing on (ERROR). The due sensor refuses a queue over 2,000 filings, so nothing reads
-- them until an operator backfill of the `sec_segments` job, paced by the `sec` pool.
--
-- Runs once: post-baseline migrations are applied by version, and the key below makes a re-apply a
-- no-op as well.

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'segments-requeue-no-instance-2026-11-14') then
    raise notice 'segments-requeue-no-instance: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
    from market.security s
   where s.security_id = f.security_id
     and s.cik is not null
     and s.security_type_code = 'equity'
     and f.is_xbrl
     and f.report_type in (select form_code from market.filing_form
                            where source_code = 'sec' and carries_segments)
     and f.segments_parsed_at is not null
     and f.filing_date >= date '2019-06-15'
     and not exists (select 1 from market.security_segment g
                      where g.security_id = f.security_id
                        and g.accession_number = f.accession_number);
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'segments-requeue-no-instance-2026-11-14',
    format('re-queued %s SEC filings read with no segment rows since 2019-06-15', n));
  raise notice 'segments-requeue-no-instance: re-queued % rows', n;
end $$;
