-- INDIA FILES DIMENSIONED XBRL — AND IT NEEDS NORMALISING BEFORE THE PARSER CAN READ IT.
--
-- Measured 2026-09-06 on THREE filers (Reliance, HDFC Bank, Infosys), because a convention inferred
-- from one instance is a coincidence. All three agree, and all three reconcile to the rupee:
--
--   Reliance   annual 11,094,900,000,000   quarter 2,916,250,000,000
--   HDFC Bank  annual  6,012,753,600,000   quarter 1,774,357,500,000
--   Infosys    annual  1,536,700,000,000   quarter   379,230,000,000
--
-- Korea needed NO parser change: DART's member codes ARE the segment names and its contexts carry
-- honest dates. India breaks both assumptions, so `functions/market-refresh/in.ts` rewrites the
-- instance into ordinary XBRL and `segmentFactsFrom` reads it UNCHANGED. The normalisation is
-- deliberately outside the parser — that function carries every partition, subtotal, residual,
-- qualifier and cross-tab rule in this system, and a filer-specific special case inside it would be
-- a liability for every other jurisdiction.
--
-- The three things it fixes, each of which would produce a confident wrong number rather than an
-- error, are documented at length in `in.ts`. In brief: members are ANONYMOUS POSITIONAL SLOTS
-- whose names live in a sibling `DescriptionOfReportableSegment` fact; the PERIOD IS NOT IN THE
-- DATES (both the quarter and the year column carry the same 90-day context, so the parser would
-- union them — 14,011,150,000,000 against a true 11,094,900,000,000 for Reliance, a 26%
-- overstatement); and every company files TWICE, standalone and consolidated.

\set ON_ERROR_STOP on

-- ── the source and its form ─────────────────────────────────────────────────────────────────────
-- `security_filing.source_code` is a foreign key, so this row must exist BEFORE a resource writes
-- one — migration 088's lesson, where an unseeded source killed the resource on its first real run
-- and no migration test could catch it.
insert into market.data_source (code, name, priority) values
  ('nse', 'NSE (India) — corporate financial results', 240)
on conflict (code) do update set name = excluded.name;

-- NSE labels these `Annual`. `carries_segments` puts the form in a segment backlog at all;
-- `is_annual` sorts it ahead of quarterlies within a company, which breadth-first ordering needs.
-- Keyed on `disclosure_source`, NOT `data_source` — both tables have an `sec` row and they are
-- different things.
insert into market.filing_form (source_code, form_code, is_annual, carries_segments) values
  ('nse', 'Annual', true, true)
on conflict (source_code, form_code) do update
  set is_annual = excluded.is_annual, carries_segments = excluded.carries_segments;

insert into market.disclosure_coverage (source_code, country_iso2) values ('nse', 'IN')
on conflict do nothing;

-- DELIBERATELY NOT ENABLED YET. `disclosure_source.enabled` says a jurisdiction is SERVED, and
-- nothing serves India until `in-filings` and `security-in-segments` exist — a source with no
-- resource advertises work nothing can do, which is why `enabled` defaults false in the first
-- place. The flip belongs in the migration that lands those resources, one line, once.

-- ── the axes India uses ─────────────────────────────────────────────────────────────────────────
-- A SEPARATE AXIS PER METRIC FAMILY, which is unlike every other taxonomy here: us-gaap and
-- ifrs-full hang many metrics off one segment axis, while the SEBI taxonomy splits them. Assets
-- carries HALF the members of the others (5 vs 10 at Reliance, 7 vs 14 at HDFC, 8 vs 16 at Infosys)
-- because it is an INSTANT — one column, not a quarter and a year.
insert into market.segment_axis (taxonomy, axis, kind, priority) values
  ('in-bse-fin', 'in-bse-fin:ReportableSegmentsAxis',             'business', 90),
  ('in-bse-fin', 'in-bse-fin:ReportableSegmentAssetsAxis',        'business', 89),
  ('in-bse-fin', 'in-bse-fin:ReportableSegmentLiabilitiesAxis',   'business', 88),
  ('in-bse-fin', 'in-bse-fin:ReportableSegmentsFinanceCostsAxis', 'business', 87)
on conflict (taxonomy, axis) do update set kind = excluded.kind, priority = excluded.priority;

-- ── the concepts on them ────────────────────────────────────────────────────────────────────────
-- COUNTED IN THE MEASURED WIRE RESPONSES, not transcribed from a taxonomy document — and the check
-- earned its keep. The plausible-looking `SegmentResult` does not exist in this taxonomy; the
-- element is `SegmentProfitLossBeforeTaxAndFinanceCosts`. Seeding the guess would have matched
-- nothing and left operating income silently empty for all of India, with no error anywhere.
--
--   concept                                    Reliance  HDFC  Infosys
--   SegmentRevenue                                   10    14       16
--   SegmentProfitLossBeforeTaxAndFinanceCosts        10    14       16
--   SegmentAssets                                     5     7        8   (an INSTANT — one column)
--   SegmentLiabilities                                5     7        8   (no metric for it yet)
insert into market.xbrl_concept (metric_code, concept, priority) values
  ('revenue',          'SegmentRevenue',                            100),
  ('operating_income', 'SegmentProfitLossBeforeTaxAndFinanceCosts',  90),
  ('total_assets',     'SegmentAssets',                              90)
on conflict (metric_code, concept) do update set priority = excluded.priority;

-- ── the backlog ─────────────────────────────────────────────────────────────────────────────────
drop view if exists market.pending_in_segments;
create view market.pending_in_segments as
select security_id, accession_number, report_type, filing_date, filer_id, best_weight, round
from (
  select
    f.security_id, f.accession_number, f.report_type, f.filing_date,
    sf.filer_id,
    coalesce(max(h.weight), 0) as best_weight,
    -- BREADTH-FIRST. Ordering by fund weight alone is depth-first, because weight belongs to the
    -- SECURITY: migration 156 measured 440 filings parsed across just 14 companies that way.
    row_number() over (
      partition by f.security_id
      order by
        coalesce((select ff.is_annual from market.filing_form ff
                   where ff.source_code = 'nse' and ff.form_code = f.report_type limit 1), false) desc,
        f.filing_date desc,
        f.accession_number
    ) as round
  from market.security_filing f
  join market.security_filer sf
    on sf.security_id = f.security_id and sf.source_code = 'nse'
  left join market.fund_holding_current h on h.security_id = f.security_id
  where
    f.source_code = 'nse'
    -- The vocabulary is keyed on the REGULATOR, and it appears here AND in the sort above; a form
    -- list carried in two clauses drifts, which is what migration 163 left behind.
    and exists (
      select 1 from market.filing_form ff
       where ff.source_code = 'nse' and ff.form_code = f.report_type and ff.carries_segments
    )
    and (
      f.segments_parsed_at is null
      or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
    )
  group by f.security_id, f.accession_number, f.report_type, f.filing_date, sf.filer_id
) ranked
order by round, best_weight desc, accession_number;

comment on view market.pending_in_segments is
  'Indian filings whose XBRL has not been read. Separate from pending_segments and pending_kr_segments because the three are fetched completely differently — SEC by CIK and accession, DART by receipt number returning a ZIP, NSE by symbol behind a cookie handshake — while sharing security_filing, its segments_parsed_at cursor and the segment_parser.version re-queue. Breadth-first, so every Indian company gets its latest annual before any gets a second year.';

grant select on market.pending_in_segments to service_role;

notify pgrst, 'reload schema';
