-- A PDF LINK MUST BE INVISIBLE TO EVERY PARSE BACKLOG.
--
-- `cn-filings` writes `security_filing` rows for 2,311 Chinese equities so a reader can open the
-- annual report. Every one is a PDF and none can be parsed. If such a row reached
-- `pending_segments` — or the Korean or Indian queue — the segment resources would spend a shared,
-- rate-limited provider budget fetching documents they cannot read, and would keep doing it for
-- ever, because a filing is only stamped after a successful parse.
--
-- TWO INDEPENDENT DEFENCES, and the test asserts both, because either alone is one edit from being
-- wrong: the row carries `is_xbrl = false`, and its form is not marked `carries_segments`.
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

do $$
declare
  n_pdf_queued int;
  n_real_queued int;
  form_parsable boolean;
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

  -- 3. The second defence, asserted independently: the form itself is not parsable.
  select ff.carries_segments into form_parsable
    from market.filing_form ff where ff.source_code = 'cninfo' and ff.form_code = '年度报告';
  if form_parsable is not false then
    raise exception 'the CNINFO annual report form is marked carries_segments — one edit from feeding PDFs to a parser';
  end if;
end $$;

rollback;
