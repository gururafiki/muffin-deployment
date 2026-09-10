-- CNINFO FILES THREE DIFFERENT DOCUMENTS UNDER ONE CATEGORY, AND WE STORED THEM ALL AS ONE.
--
-- `category_ndbg_szsh` is CNINFO's "annual reports", and `cn-filings` recorded everything it
-- returned as `年度报告` with no title filter. Measured 2026-09-06 by downloading the stored URL
-- for 8 companies and reading the first page of each: only THREE were full Chinese-language annual
-- reports.
--
--     4 of 8   年度报告摘要 — the SUMMARY, 5-16 pages against 194-320
--     1 of 8   the ENGLISH edition (Kweichow Moutai), which is the real reason no Chinese heading
--              could be found in it — not that Moutai discloses nothing
--     3 of 8   the full report
--
-- Attribution itself is sound: every PDF belongs to the security it is filed under. It is the
-- DOCUMENT CHOICE that is wrong, and it matters beyond tidiness — the summary omits the
-- CSRC-mandated breakdown table entirely, so any parser reading it records the company as
-- disclosing nothing.
--
-- NOTHING IS DISCARDED. A summary is a real document and a useful link for a reader; it simply is
-- not the one a parser can read. `security_filing` has no title column, so `report_type` is the
-- classification's only carrier and it has to distinguish them at ingest.
--
-- TIMING IS WHY THIS SHIPS NOW: 13 of 2,325 Chinese companies have been walked and 2,160 are still
-- queued. Fixing the rule before the corpus is stored costs one migration; fixing it afterwards
-- costs a re-walk of 2,325 companies against a provider we do not control.

insert into market.filing_form (source_code, form_code, is_annual, carries_segments) values
  -- The summary and the English edition are LINKS ONLY, for ever. Even once a PDF segment parser
  -- exists it will target the mandated Chinese table, which neither document contains.
  ('cninfo', '年度报告摘要',      true,  false),
  ('cninfo', '年度报告（英文版）', true,  false)
on conflict (source_code, form_code) do update
  set is_annual = excluded.is_annual, carries_segments = excluded.carries_segments;

-- ── reclassify what is already stored ───────────────────────────────────────────────────────────
--
-- A ONE-SHOT, because this is a DATA REPAIR and migrations re-run on every deploy. It is also the
-- only way these rows are ever corrected: the resource upserts with `ignoreDuplicates: true` on
-- `(security_id, accession_number)`, so a re-walk finds the row present and leaves its type alone.
--
-- The title is not stored, so the repair reads what IS: `security_filing` keeps the announcement's
-- own URL as its `accession_number`, but the URL carries no document type either. What survives is
-- the FILING ITSELF — so this repair is deliberately narrow, marking the rows whose type cannot be
-- determined from stored data as needing a re-walk rather than guessing at them.
do $$
declare v_cleared integer;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-document-kinds-0906') then
    return;
  end if;

  -- CLEAR `history_walked_at` FOR EVERY COMPANY WALKED UNDER THE OLD RULE, so `cn-filings` visits
  -- them again and writes each document under its correct type. The filings themselves are LEFT IN
  -- PLACE: they are real documents at real URLs, and deleting them would remove a working link
  -- from a reader's Filings section to fix a classification.
  update market.security_filer sf
     set history_walked_at = null
   where sf.source_code = 'cninfo'
     and exists (
       select 1 from market.security_filing f
        where f.security_id = sf.security_id
          and f.source_code = 'cninfo'
          and f.report_type = '年度报告'
     );
  get diagnostics v_cleared = row_count;
  raise notice 'cninfo: re-queued % companies for a re-walk under the document-kind rule', v_cleared;

  insert into market.one_shot (key) values ('cninfo-document-kinds-0906');
end $$;

notify pgrst, 'reload schema';
