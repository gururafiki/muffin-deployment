-- A major customer's revenue is not a company total: `ifrs-full:MajorCustomersAxis` stops being a
-- qualifier, and the DART reports it misread are read again (one-shot).
--
-- MEASURED 2026-11-26. Migration 155 (legacy) declared `MajorCustomersAxis` a "harmless" qualifier
-- so that facts carrying it would not be disqualified as unknown. It is not harmless. A qualifier
-- narrows a fact without changing what it measures, so a `Revenue` fact under
-- `MajorCustomersAxis = GroupOfCustomersMember`, the revenue from one customer group, read as the
-- company's total. HL Mando's FY2025 geography split sums to 9.45 T won, its revenue, and was
-- stored with `reconciled_to` 1,017,521,239,000: that figure is its largest customer group's.
-- Re-parsing the held DART instances with the axis removed from the vocabulary, against today's:
--   - the 30 held filings among those whose stored split misses its target: reconciling splits
--     97 -> 125 (29 gained, 1 lost);
--   - 66 random held DART filings: 225 -> 237 (13 gained, 1 lost);
--   - 134 SEC IFRS filings: 320 -> 320, no change.
-- The one split lost, Cosmecca's 2024 Canada + Europe, had matched the same kind of customer
-- figure. Removing `TimingOfTransferOfGoodsOrServicesAxis` as well gained more and lost real
-- splits (CJ Freshway's food distribution, 3.06 T won), so that axis stays a qualifier.
--
-- AN UNKNOWN AXIS DISQUALIFIES THE FACT, as a member and as a total. That is the right reading of
-- a customer's revenue: it is neither.
--
-- THE RE-QUEUE TAKES EVERY DART FILING HOLDING A REVENUE ROW (882). The parser stores every fact,
-- placed or not, so a filing with no revenue row cannot change, and a filing with one can gain a
-- placed split as well as lose a wrong target. Most were read by the edge, so their archives are
-- not in raw and stage 1 fetches them again (http-cache keeps DART for 90 days).
--
-- ORDER: drain stage 1 alone on the `dart` pool after this deploys, so the re-fetch does not ride
-- the floor's runs, which hold `sql` with it.

delete from market.segment_axis where axis = 'ifrs-full:MajorCustomersAxis';

do $$
declare
  n int;
begin
  if exists (select 1 from market.one_shot where key = 'dart-major-customers-2026-11-26') then
    raise notice 'dart-major-customers: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
   where coalesce(f.segments_parser_version, 0) <> 0
     and exists (
       select 1
         from market.security_segment g
        where g.security_id = f.security_id
          and g.accession_number = f.accession_number
          and g.source_code = 'dart'
          and g.metric_code = 'revenue');
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason)
  values ('dart-major-customers-2026-11-26',
          format('re-queued %s DART reports holding a revenue row', n));
end $$;
