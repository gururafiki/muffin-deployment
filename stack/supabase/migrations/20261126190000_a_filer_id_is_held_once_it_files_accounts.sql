-- A filer id counts as `held` only once its regulator has an annual accounts filing for the security
-- (Phase 6c step 2b, docs/specs/2026-11-26-more-segment-sources.md).
--
-- WHY. `security_disclosure.capability` read `held` for every security with a filer id, so a CIK was
-- taken to mean "SEC can serve this company's segments". Measured 2026-11-26: among the 300 largest
-- SEC "filers" with no split, 171 hold a CIK and file no 10-K, 20-F or 40-F (SK hynix, CATL,
-- Inditex, Air Liquide: ADR programmes and exempt issuers). SEC can never give them segments, and
-- labelling them `held: sec` hid them from the regulator that can (DART, CNINFO), and from the gap.
--
-- THE RULE IS ONE FOR EVERY REGULATOR, through `filing_form` (`is_annual and carries_segments`), whose
-- rows name each regulator's annual accounts form: SEC 10-K, 10-KT, 20-F, 20-F/A, 40-F; DART
-- 사업보고서; NSE Annual; CNINFO 年度报告. `filing_form.source_code` is the REGULATOR, which is why the
-- join goes through it: `security_filing.source_code` names the writer (`sec-submissions`).
--
-- MEASURED ON PRODUCTION, rolled back, 2026-11-26 (30,631 securities, all equities among the moved):
--   held sec   -> none              336
--   held nse   -> resolvable nse     52   (NSE lists no annual result for them)
--   held sec   -> resolvable cninfo  32   (Chinese companies with a CIK and no SEC accounts)
--   held dart  -> resolvable dart     5
--   held sec   -> resolvable dart     1
-- A filer whose filing list has not been walked yet reads `resolvable` until it is, which is the
-- truth: nothing is held to read. One security read 7 ms -> 158 ms; the whole view 152 ms.
--
-- `create or replace`: the columns are unchanged, so the view keeps its grants.

create or replace view market.security_disclosure as
WITH enabled_source AS MATERIALIZED (
         SELECT disclosure_source.code,
            disclosure_source.priority
           FROM market.disclosure_source
          WHERE disclosure_source.enabled
        ), held AS MATERIALIZED (
         SELECT DISTINCT ON (f.security_id) f.security_id,
            f.source_code,
            f.filer_id
           FROM market.security_filer f
             JOIN enabled_source d ON d.code = f.source_code
          WHERE (EXISTS ( SELECT 1
                   FROM market.security_filing sf
                     JOIN market.filing_form ff ON ff.source_code = f.source_code AND ff.form_code = sf.report_type
                  WHERE sf.security_id = f.security_id AND ff.is_annual AND ff.carries_segments))
          ORDER BY f.security_id, d.priority DESC, f.source_code
        ), by_country AS MATERIALIZED (
         SELECT DISTINCT ON (c.country_iso2) c.country_iso2,
            c.source_code
           FROM market.disclosure_coverage c
             JOIN enabled_source d ON d.code = c.source_code
          ORDER BY c.country_iso2, d.priority DESC, c.source_code
        )
 SELECT s.security_id,
    COALESCE(h.source_code, bc.source_code) AS segment_source,
    h.source_code IS NOT NULL AS filer_id_held,
        CASE
            WHEN h.source_code IS NOT NULL THEN 'held'::text
            WHEN bc.source_code IS NOT NULL THEN 'resolvable'::text
            ELSE 'none'::text
        END AS capability,
    h.filer_id
   FROM market.security s
     LEFT JOIN held h ON h.security_id = s.security_id
     LEFT JOIN by_country bc ON bc.country_iso2 = COALESCE(s.provider_country_iso2, s.country_iso2);
