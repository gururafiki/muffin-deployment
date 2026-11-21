-- AMENDED AND TRANSITION REPORTS CARRY SEGMENTS: 10-Q/A, 20-F/A, 10-KT AND 10-QT (decided by the user
-- 2026-11-21, from the measurement in umbrella docs/deferred/2026-11-09-segment-parsing-is-ported-as-
-- is-and-widened-later.md).
--
-- `filing_form.carries_segments` was true on exactly 10-K, 10-Q, 20-F and 40-F, so the SEC segment
-- lane never asked an amendment or a transition report. Measured 2026-11-21, 30 of them fetched and
-- parsed read-only (a filing "carries segments" when the parser places at least one fact):
--
--   form     XBRL never asked  sampled  carry segments
--   10-K/A        1,727           8          0   (cover page or Part III: 6 of 8 under 40 KB)
--   40-F/A           31           2          0
--   10-Q/A        1,537           6          2   (one corrects a sign the original filed wrong)
--   20-F/A          211           4          2   (one is the only XBRL for its year: 55 new keys)
--   10-KT            55           6          4
--   10-QT            19           4          1
--
-- An amendment that carries segments is a full re-filing of the period, and `file_filing` already
-- lets a newer filing keep its rows over an older one, so the amendment takes the period from its
-- original. A transition report's odd-length period is dropped by the parser (only 84-98 and
-- 358-372 days are typed), so what a 10-KT places is its full-year and quarter comparatives.
--
-- The 1,822 newly eligible filings were never read (`segments_parser_version` null), so they are due
-- at once: the SEC lane's sensor, or a backfill over `grid:sec_filer` while more than 2,000 filings
-- are due, reads them. 10-K/A and 40-F/A stay off.

update market.filing_form
   set carries_segments = true
 where source_code = 'sec'
   and form_code in ('10-Q/A', '20-F/A', '10-KT', '10-QT');
