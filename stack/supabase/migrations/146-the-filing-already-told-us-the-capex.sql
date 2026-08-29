-- SEGMENT CAPEX WAS ALREADY IN A RESPONSE WE FETCH, PARSE AND THROW AWAY.
--
-- Seventh instance of this pipeline's most-repeated lesson. `security-segments` downloads each
-- filing's XBRL instance and reads only two concepts from it. Measured 2026-08-29 on Amazon's
-- 10-Q, the facts carrying a SEGMENT dimension in that same document are:
--
--     RevenueFromContractWithCustomerExcludingAssessedTax   48   <- stored
--     SegmentExpenditureAdditionToLongLivedAssets           20   <- discarded
--     CostsAndExpenses                                      12   <- discarded
--     OperatingIncomeLoss                                   12   <- stored
--     Depreciation                                          12   <- discarded
--     Assets                                                 6   <- discarded
--
-- Capex per segment is the one worth taking first and it costs NOTHING: no new request, no new
-- provider, no new backlog — the bytes are already on the wire. It is also the number that makes
-- the current cycle legible: AWS's capital expenditure is what the whole AI build-out argument is
-- about, and no free provider sells it.
--
-- WHY NOT THE OTHER FOUR, YET.
--   * `Assets` is an INSTANT fact (a balance-sheet stock, not a flow) and `security_segment.
--     period_type` admits only `annual` and `quarter`. Segment assets — and with them return on
--     segment assets — need that column widened, which is a schema change rather than a row.
--   * `Depreciation` and `CostsAndExpenses` would give segment EBITDA and gross margin, and both
--     are DURATIONS so they would work today — but each new metric in `xbrl_concept` is also read
--     by `security-xbrl` for the whole universe, and `security_metric` already holds 3.29M rows.
--     That is a deliberate decision about table growth, not an oversight.
--
-- `capital_expenditure` needs neither of those: the metric already exists and this adds only the
-- SEGMENT spelling of it.

-- PRIORITY 60, BELOW THE CASH-FLOW SPELLING (100), AND THAT MATTERS BEYOND SEGMENTS.
-- `xbrl_concept` is shared with `security-xbrl`, which reads UNDIMENSIONED facts, so this row also
-- becomes a fallback for consolidated capex. That is a gap-filler and not a change: a filer
-- reporting `PaymentsToAcquirePropertyPlantAndEquipment` keeps it, because resolution is per PERIOD
-- by priority and 100 beats 60. A filer that reports only the segment-expenditure concept gains a
-- capex series it did not have.
insert into market.xbrl_concept (metric_code, concept, priority, unit, taxonomy) values
  ('capital_expenditure', 'SegmentExpenditureAdditionToLongLivedAssets', 60, 'USD', 'us-gaap')
on conflict (metric_code, concept) do update
  set priority = excluded.priority, unit = excluded.unit, taxonomy = excluded.taxonomy;

comment on table market.security_segment is
  'Revenue, operating income and capital expenditure per disclosed business line, parsed from the filing''s XBRL instance. AGGREGATE WITHIN ONE partition_id ONLY: an axis can carry several overlapping splits that each sum to the consolidated total (Amazon discloses three), so summing an axis doubles the company''s revenue and summing the table triples it. partition_id 0 is a subtotal and must never be summed.';

notify pgrst, 'reload schema';
