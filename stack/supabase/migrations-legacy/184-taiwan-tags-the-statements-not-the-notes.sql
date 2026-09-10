-- TAIWAN — NOT VIABLE, AND IT IS THE THIRD JURISDICTION TO FAIL THE SAME WAY.
--
-- Spiked 2026-09-06 with the usual protocol. Subject: MediaTek (2454), the largest Taiwanese
-- holding at 7.55% fund weight that currently reports `capability = 'none'` — deliberately not
-- TSMC, which is already reachable through its SEC 20-F and so could not test anything.
--
-- TWSE MOPS publishes real INLINE XBRL and is reachable without a handshake:
-- `mopsov.twse.com.tw/server-java/t164sb01?step=1&CO_ID=2454&SYEAR=2024&SSEASON=4&REPORT_ID=C`
-- returns 1.24 MB carrying 4,542 `ix:` tags and 3,891 contextRefs — this is not a PDF wall like
-- CNINFO, it is structured data.
--
-- But it carries exactly TWO dimensions, `ifrs-full:ComponentsOfEquityAxis` (320 facts) and a
-- doubtful-accounts movement axis (10). **No segment axis of any kind**, and 部門 — "segment" —
-- appears ZERO times in the whole document. `REPORT_ID` A and B return 98 bytes, so C is the
-- financial-statement report and there is nothing else on that route.
--
-- THE SIGNATURE IS NOW FAMILIAR AND IS THE POINT. ESEF, EDINET and now Taiwan all publish
-- perfectly good XBRL of the PRIMARY STATEMENTS and leave the IFRS 8 segment note outside it —
-- block-tagged text, or simply absent. "Publishes XBRL" and "publishes DIMENSIONED XBRL" are
-- different claims, and only the second is worth anything here. Four of the six jurisdictions
-- measured have now failed on exactly that distinction; SEC, DART and NSE are the exceptions.
--
-- WHAT WAS NOT TESTED, stated so it is not mistaken for a closed question: only the `t164sb01`
-- iXBRL route. MOPS also serves full annual reports as PDF and may expose a separate notes
-- package. Neither would change the answer for a parser that needs dimensions, but if Taiwan is
-- ever revisited that is where to look.

\set ON_ERROR_STOP on

insert into market.disclosure_source (code, name, identifier_label, enabled, priority, note) values
  ('mops', 'TWSE MOPS (Taiwan)', 'co_id', false, 55,
   'Measured NOT viable 2026-09-06: MediaTek (2454) FY2024 via t164sb01 is genuine inline XBRL — 1.24 MB, 4,542 ix: tags, 3,891 contextRefs — but carries only ifrs-full:ComponentsOfEquityAxis and a doubtful-accounts axis. No segment axis, and 部門 appears zero times. Same signature as ESEF and EDINET: the primary statements are tagged and the IFRS 8 note is not. Only the t164sb01 route was tested.')
on conflict (code) do update set
  name = excluded.name, identifier_label = excluded.identifier_label,
  priority = excluded.priority, note = excluded.note;
-- `enabled` stays out of the DO UPDATE so an operator's choice survives a redeploy.

notify pgrst, 'reload schema';
