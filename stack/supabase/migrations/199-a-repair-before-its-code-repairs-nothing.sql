-- A DATA REPAIR THAT RUNS BEFORE THE CODE IT DEPENDS ON REPAIRS NOTHING, AND CONSUMES ITS OWN KEY.
--
-- Migration 193 taught `cn-filings` to tell CNINFO's three documents apart — the full report, the
-- `年度报告摘要` summary, and the English edition — and re-queued the companies already walked so a
-- re-walk would retype their rows. Both halves were right. The ORDER was not.
--
-- The migration was applied by hand hours before the function carrying `classifyAnnouncement`
-- deployed. `cn-filings` kept running on its cron throughout, walking company after company with
-- the OLD code and stamping `history_walked_at` as it went — so the re-queue was spent on walks
-- that could not classify, and the one-shot key was recorded, which is what makes it unrepeatable.
--
-- Measured 2026-09-07, with the classifier live since 15:15 UTC:
--
--     cninfo filers walked BEFORE 15:15   77   carrying 1,879 filings, all typed `年度报告`
--     cninfo filers walked since          22   correctly split across the three types
--
-- And those 22 are exactly the 22 companies that hold both a full report and a summary. China
-- Yangtze Power files both every year — its FY2025 summary is a 9-page document at
-- `1225262042.PDF`, sitting in `security_filing` as a full annual report — and it was last walked
-- at 2026-09-06 20:21, before any of this.
--
-- THE COST IS NOT COSMETIC. `pending_cn_segments` admits `年度报告` only, so every mis-typed summary
-- is a PDF the parser downloads, scans 90 pages of, and finds no table in — then stamps as
-- disclosing nothing. That is the failure the classification exists to prevent, and 1,879 filings
-- are queued for it.
--
-- SCOPED BY THE DEPLOY, NOT BY THE ROW. There is no column saying which code classified a filing,
-- and the title is not stored — so the honest key is WHEN the filer was walked. Anything walked
-- before the classifier shipped was walked without it.
do $$
declare v_cleared integer;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-rewalk-after-classifier') then
    return;
  end if;

  update market.security_filer sf
     set history_walked_at = null
   where sf.source_code = 'cninfo'
     and sf.history_walked_at is not null
     -- The deploy that carried `classifyAnnouncement` finished at 15:15:22 UTC.
     and sf.history_walked_at < timestamptz '2026-09-07 15:15:00+00';
  get diagnostics v_cleared = row_count;
  raise notice 'cninfo: re-queued % filers walked before the classifier shipped', v_cleared;

  insert into market.one_shot (key) values ('cninfo-rewalk-after-classifier');
end $$;

notify pgrst, 'reload schema';
