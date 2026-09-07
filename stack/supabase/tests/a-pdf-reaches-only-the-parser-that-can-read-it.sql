-- A PDF MUST REACH THE PARSER THAT CAN READ IT, AND NO OTHER.
--
-- This file used to assert that a CNINFO PDF was invisible to EVERY parse backlog, because
-- migration 183 had concluded no Chinese filing could be parsed at all. Migration 195 reverses
-- that: the reports are TEXT PDFs, the CSRC mandates the breakdown table, and `security-cn-segments`
-- reads it. The protection the file exists for is unchanged and is now sharper — a PDF must never
-- reach an XBRL backlog, where the resource would spend a shared, rate-limited provider budget on
-- a document it cannot read and would keep doing it for ever, because a filing is only stamped
-- after a successful parse.
--
-- FOUR ASSERTIONS, because each is one edit from being wrong on its own:
--   1. the PDF is in none of the three XBRL queues;
--   2. the same security's real SEC filing still queues — or (1) proves nothing;
--   3. the PDF IS in the China queue, so the row is not merely orphaned;
--   4. the SUMMARY is in NO queue, including China's — it omits the mandated table entirely, and
--      four of the first eight companies were stored as one.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. A Chinese PDF row sits beside a US XBRL row for
-- the SAME security, so a backlog that merely counted the security would pick it up; only one that
-- discriminates on the FILING passes.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('CN','Chinaland','CN',false), ('ZW','Testland','ZW',false)
on conflict (iso2) do nothing;
insert into market.currency (code) values ('CNY') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000018701','T187 Both Kinds Inc','equity','CN', 1870001)
on conflict do nothing;

-- The PDF link, exactly as `cn-filings` writes it.
insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code, is_xbrl, report_url) values
  ('00000000-0000-0000-0000-000000018701','https://static.cninfo.com.cn/finalpage/x.PDF',
   '年度报告', date '2026-04-30','cninfo', false, 'https://static.cninfo.com.cn/finalpage/x.PDF')
on conflict do nothing;

-- And a REAL SEC filing for the same security, so a backlog that keys on the security rather than
-- the filing cannot pass by accident.
insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code, is_xbrl) values
  ('00000000-0000-0000-0000-000000018701','0001870001-26-000001','10-K',
   date '2026-02-01','sec-segments', true)
on conflict do nothing;

-- The SUMMARY, which CNINFO files under the same category and which contains no breakdown table.
insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code, is_xbrl, report_url) values
  ('00000000-0000-0000-0000-000000018701','https://static.cninfo.com.cn/finalpage/x-summary.PDF',
   '年度报告摘要', date '2026-04-30','cninfo', false, 'https://static.cninfo.com.cn/finalpage/x-summary.PDF')
on conflict do nothing;

do $$
declare
  n_pdf_queued int;
  n_real_queued int;
  n_cn_queued int;
  n_summary_queued int;
begin
  -- 1. The PDF must not be in ANY segment backlog.
  select count(*) into n_pdf_queued from (
    select accession_number from market.pending_segments
    union all select accession_number from market.pending_kr_segments
    union all select accession_number from market.pending_in_segments
  ) q where q.accession_number = 'https://static.cninfo.com.cn/finalpage/x.PDF';
  if n_pdf_queued <> 0 then
    raise exception 'a CNINFO PDF reached a parse backlog % time(s) — the segment resources would spend their provider budget on documents they cannot read', n_pdf_queued;
  end if;

  -- 2. THE CONTROL. The same security's real filing must still queue, or the test would pass for
  --    the trivial reason that nothing queues at all.
  select count(*) into n_real_queued from market.pending_segments
   where accession_number = '0001870001-26-000001';
  if n_real_queued = 0 then
    raise exception 'the control SEC filing did not queue either — this test proves nothing about the PDF';
  end if;

  -- 3. AND IT MUST REACH THE ONE QUEUE THAT CAN READ IT. Without this the test passes for a
  --    security whose filing is simply orphaned — invisible to everything, including China's own
  --    parser, which is a different defect wearing the same green tick.
  select count(*) into n_cn_queued from market.pending_cn_segments
   where accession_number = 'https://static.cninfo.com.cn/finalpage/x.PDF';
  if n_cn_queued <> 1 then
    raise exception 'the CNINFO annual report is not in pending_cn_segments (% rows) — a PDF nothing parses is the coverage gap this was built to close', n_cn_queued;
  end if;

  -- 4. THE SUMMARY IS IN NO QUEUE AT ALL, China's included. It is a real document and a useful
  --    link, and it omits the mandated table entirely — four of the first eight companies were
  --    stored as one, so a parser fed a summary records the company as disclosing nothing.
  select count(*) into n_summary_queued from (
    select accession_number from market.pending_segments
    union all select accession_number from market.pending_kr_segments
    union all select accession_number from market.pending_in_segments
    union all select accession_number from market.pending_cn_segments
  ) q where q.accession_number = 'https://static.cninfo.com.cn/finalpage/x-summary.PDF';
  if n_summary_queued <> 0 then
    raise exception 'the annual report SUMMARY reached a parse backlog % time(s) — it carries no breakdown table, so parsing it records the company as disclosing nothing', n_summary_queued;
  end if;
end $$;

rollback;
