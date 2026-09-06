-- TWO SPIKES, OPPOSITE ANSWERS, AND ONLY MEASUREMENT COULD TELL THEM APART.
--
-- Both run 2026-09-06 with the protocol that settled ESEF, EDINET and DART: take the market's
-- largest holding by fund weight, find a machine-readable route, check reachability FROM THE NODE,
-- fetch one annual instance, and count segment axes.
--
-- ── CHINA — NOT VIABLE. The route exists; the FORMAT does not. ──────────────────────────────────
-- Subject: China Yangtze Power (600900), the largest Chinese holding at 5.876% fund weight — a
-- genuine Shanghai A-share rather than an OTC line. CNINFO, the CSRC-designated national disclosure
-- platform, DOES have a working machine-readable search: POST `hisAnnouncement/query` keyed
-- `stock=<code>,<orgId>`, where the orgId comes from POST `topSearch/query` (`600900` ->
-- `gssh0600900`). It answers in ~1 s and is reachable from the node (HTTP 200 in 2.8 s), so unlike
-- DART there is no transport problem at all.
--
-- The blocker is that every filing is a PDF. 2,771 announcements for the subject, and every one
-- sampled carries `adjunctType: PDF` — including all 61 annual reports. The FY2025 annual report
-- begins `%PDF-1.7`. Extracting an IFRS-8 segment table from it is PDF table extraction with
-- Chinese labels, which is the same reliability class as EDINET's escaped-HTML text block and is
-- not what this parser does.
--
-- ── INDIA — VIABLE, and it reconciles exactly. ─────────────────────────────────────────────────
-- Subject: Reliance Industries, the largest Indian holding at 6.23%. NSE publishes XBRL for
-- financial results: `api/corporates-financial-results?index=equities&symbol=<sym>&period=Annual`
-- returns 39 filings for Reliance, each with an `INDAS_*` XBRL URL on nsearchives.nseindia.com.
-- The API needs a browser User-Agent and a cookie handshake against nseindia.com first; the
-- handshake itself answers 403 while still setting the cookie the API then accepts.
--
-- The instance carries FOUR segment axes — `in-bse-fin:ReportableSegmentsAxis` and its
-- FinanceCosts / Liabilities / Assets siblings — and the annual column reconciles EXACTLY:
--
--   Oil to Chemicals (O2C)  5,647,490,000,000
--   Retail                  3,068,480,000,000
--   Digital Services        1,329,380,000,000
--   Others                    805,160,000,000
--   Oil and Gas               244,390,000,000
--                          -------------------
--                          11,094,900,000,000  = the undimensioned total, to the rupee
--
-- TWO THINGS THAT WOULD BREAK A NAIVE PARSE, both structural rather than incidental:
--
--   * THE MEMBERS ARE ANONYMOUS POSITIONAL SLOTS. They are named
--     `OneReportableSegmentRevenue01Member` .. `FourReportableSegmentRevenue05Member`, so the code
--     carries no meaning at all — unlike SEC and DART, where the member IS the name. The name is a
--     SEPARATE dimensioned text fact, `in-bse-fin:DescriptionOfReportableSegment`, on the same
--     context: member 03 of the Four* column resolves to 'Oil to Chemicals (O2C)'. A parser that
--     read only the member code would serve five unnamed segments.
--   * THE `One`/`Four` PREFIX IS THE PERIOD, NOT A SEGMENT. `One*` is the three-month column and
--     `Four*` the twelve-month one. Summing all ten members gives 14,011,150,000,000 against a
--     true 11,094,900,000,000 — a 26% overstatement that looks like an ordinary reconciliation
--     failure rather than two periods added together.
--
-- Enabled = FALSE, as every source starts: a row must never advertise work no resource can do.
-- Implementation is its own phase, exactly as DART was.

\set ON_ERROR_STOP on

insert into market.disclosure_source (code, name, identifier_label, enabled, priority, note) values
  ('cninfo', 'CNINFO (China)', 'org_id', false, 60,
   'Measured NOT viable 2026-09-06: CNINFO has a working machine-readable search and is reachable from the node, but every filing is a PDF — 2,771 announcements for China Yangtze Power (600900), all adjunctType PDF, including all 61 annual reports; the FY2025 report begins %PDF-1.7. The route exists and the format does not.'),
  ('nse', 'NSE (India)', 'symbol', false, 85,
   'Measured VIABLE 2026-09-06: Reliance''s NSE XBRL carries in-bse-fin:ReportableSegmentsAxis (plus FinanceCosts/Liabilities/Assets siblings) and the annual column reconciles EXACTLY to 11,094,900,000,000. Two structural traps: members are anonymous positional slots (OneReportableSegmentRevenue01Member), so the name comes from a sibling in-bse-fin:DescriptionOfReportableSegment fact on the same context; and the One/Four prefix is the PERIOD (3-month vs 12-month), so summing all ten members overstates by 26%. API needs a browser UA and a cookie handshake.')
on conflict (code) do update set
  name = excluded.name, identifier_label = excluded.identifier_label,
  priority = excluded.priority, note = excluded.note;
-- `enabled` is deliberately NOT in the DO UPDATE, so an operator's choice survives a redeploy.

notify pgrst, 'reload schema';
