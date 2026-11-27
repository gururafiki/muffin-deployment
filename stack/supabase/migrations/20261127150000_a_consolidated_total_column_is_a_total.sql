-- A note's 連結合計 column is the line's total, never a segment (Phase 6c step 5d).
--
-- Tokio Marine's FY2026 profit table heads its last column 連結合計 ("consolidated total"); the
-- total rule knew 連結 and 合計 alone. Read as a member, the column pushed the line's sum to
-- ¥1,081,201 m, within 0.05% of an unrelated operating cash-flow subtotal (¥1,080,955 m), and that
-- sum was stored as the company's profit split, a total among its members (measured 2026-11-27,
-- the lane's first live read). muffin-ingest also bounds a match by the table's own rounding.
--
-- The parser version goes to 2 so the reports read under version 1 (three, all from the first
-- live run) are read again.

delete from market.segment_note_rule
 where regulator = 'edinet' and rule = 'label' and role = 'total'
   and pattern = '^\(?(連結|合計|総計|計)\)?$|計上額$|^報告セグメント計$';

insert into market.segment_note_rule (regulator, rule, pattern, role, priority, note)
values ('edinet', 'label', '^\(?(連結|連結合計|連結計|合計|総計|計)\)?$|計上額$|^報告セグメント計$',
        'total', 110, '連結合計 and 連結計 are the consolidated column (Tokio Marine, 2026-11-27)')
on conflict (regulator, rule, pattern) do nothing;

update market.segment_parser set version = 2 where regulator = 'edinet' and version < 2;
