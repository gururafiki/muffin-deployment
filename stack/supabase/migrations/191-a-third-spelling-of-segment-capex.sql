-- AMAZON TAGS ITS SEGMENT CAPEX WITH A SPELLING WE DO NOT MAP, AND ITS CAPEX SERIES STARTS LATE.
--
-- Measured 2026-09-06 by enumerating every concept on a segment axis in Amazon's FY2022 10-K
-- instance (`amzn-20221231_htm.xml`, 2.46 MB, 98 dimensioned segment contexts):
--
--     us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax   51   (mapped)
--     us-gaap:PropertyPlantAndEquipmentAdditions                    21   <- NOT MAPPED
--     us-gaap:OperatingIncomeLoss / Assets / Depreciation            9   (mapped)
--
-- `PropertyPlantAndEquipmentAdditions` carries per-segment additions to PP&E — $23,682,000,000 for
-- one segment in FY2022, on `StatementBusinessSegmentsAxis` qualified by
-- `ConsolidationItemsAxis = OperatingSegmentsMember`. That is capital expenditure, tagged the way
-- an accrual disclosure states it rather than the way the cash flow statement does.
--
-- SEC's `frames` API puts it at **223 filers** for CY2022. Modest, and it is the difference
-- between having a segment capex series and not having one for each of them.
--
-- PRIORITY 70 — ABOVE THE SEGMENT-EXPENDITURE SPELLING (60), BELOW THE CASH-FLOW ONE (100), and
-- migration 146 explains why that ordering matters beyond segments. `xbrl_concept` is shared with
-- `security-xbrl`, which reads UNDIMENSIONED facts, so this row also becomes a fallback for
-- consolidated capex. It cannot change an existing series: resolution is per PERIOD by priority,
-- and a filer reporting `PaymentsToAcquirePropertyPlantAndEquipment` (4,415 filers) keeps it. A
-- filer that reports only the additions concept gains a capex series it did not have.
--
-- NO PARSER VERSION BUMP, DELIBERATELY, AND THAT IS THE WHOLE POINT OF THE TIMING.
-- A bump re-queues every filing, and the corpus is ALREADY mid-drain at version 20 — measured
-- today, 3,101 filings of 210,751 have been re-read. So the 204,000 still queued will pick this
-- spelling up on the pass they are already going to make, and only the 3,101 already done miss it
-- until the next genuine bump. Bumping instead would restart a drain that has ~36 days to run and
-- buy nothing: it would re-read those 3,101 sooner at the cost of re-reading everything else
-- again. A version bump is for a change in how we READ a document, not for widening what we look
-- for while the read is still in progress.
--
-- MEASURED AND DELIBERATELY NOT ADDED, so the next reader does not re-derive it:
--
--   * `us-gaap:CostsAndExpenses` (1,404 filers, 9 facts on Amazon's segment axes) is TOTAL
--     operating cost, not cost of goods sold — North America $318,727,000,000 against North
--     America revenue of about the same, because revenue less this is operating income. Mapping it
--     to `cost_of_revenue` would put a different measurement under an existing name, which is the
--     failure this schema keeps recording. It would justify its own metric, not this one.
--   * `us-gaap:NoncurrentAssets` (722 filers) is long-lived assets by geography, which ASC 280
--     requires beside revenue — Amazon reports US $180,000,000,000 and non-US $61,300,000,000 as
--     INSTANTS on `StatementGeographicalAxis`. It is a NEW metric: a new code, a pivoted column in
--     `security_segment_current`, a column on the spine matview and a UI that reads it. Worth
--     doing, and not as a rider on a one-row change.
--   * `us-gaap:Goodwill` (3,347 filers) is likewise real and likewise a new metric.

insert into market.xbrl_concept (metric_code, concept, priority, unit, taxonomy) values
  ('capital_expenditure', 'PropertyPlantAndEquipmentAdditions', 70, 'USD', 'us-gaap')
on conflict (metric_code, concept) do update
  set priority = excluded.priority, unit = excluded.unit, taxonomy = excluded.taxonomy;

notify pgrst, 'reload schema';
