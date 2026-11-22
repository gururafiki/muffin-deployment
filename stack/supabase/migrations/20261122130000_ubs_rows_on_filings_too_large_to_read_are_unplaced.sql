-- UBS'S ROWS ON TWO FILINGS TOO LARGE TO READ ARE UNPLACED (umbrella docs/deferred/
-- 2026-10-04-the-historical-segment-backlog-is-rising.md, step 6; the user's decision of
-- 2026-11-22).
--
-- The edge parsed UBS's 20-Fs filed in 2020 and 2021 on 2026-08-30, two days before its own 32 MB
-- gate existed. The Dagster lane refuses both as too large (`sec_edgar.fetch_instance`), so no
-- current read can ever rewrite or retract what the edge wrote. And what it wrote is not a split of
-- the company: eight rows of one member, UBS's Corporate Center (`ubs:SegmentCCMember`,
-- `ubs:SegmentGFMember`), placed at partition 1 on its own, with revenue of -68 m, -617 m and
-- -378 m against consolidated revenue of ~30 bn. Two of them are served as UBS's FY2017 and FY2018
-- revenue split.
--
-- Measured 2026-11-22: these are the only rows on any of the 60 SEC filings over the gate. The
-- current parser refuses a revenue split totalling zero or less (muffin-ingest#185) and leaves
-- unplaced rows without a target (0 of 35,719 SEC rows at partition 0 written in the three days to
-- 11-22 carry one). So the rows move to partition 0 with no target: what a read by today's parser
-- would leave, and nothing is deleted.
--
-- The 12 other non-positive splits of 11-21 (Supernus 10, Navient 2) sit on filings made under a
-- predecessor CIK. muffin-ingest#194 reads those under the filer's CIK, and their re-read rewrites
-- them, so they are not touched here.

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'ubs-too-large-rows-unplaced-2026-11-22') then
    raise notice 'ubs-too-large-rows-unplaced: already applied';
    return;
  end if;

  update market.security_segment g
     set partition_id = 0,
         reconciled_to = null
    from market.security s
   where s.security_id = g.security_id
     and s.cik = 1610520
     and g.source_code = 'sec-segments'
     and g.accession_number in ('0001610520-20-000041', '0001610520-21-000035')
     and g.partition_id > 0;
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'ubs-too-large-rows-unplaced-2026-11-22',
    format('unplaced %s UBS rows on two 20-Fs over the 32 MB gate, which no current read can rewrite', n));
  raise notice 'ubs-too-large-rows-unplaced: unplaced % rows', n;
end $$;
