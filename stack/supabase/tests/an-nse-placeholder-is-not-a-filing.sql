-- The NSE placeholder clean-up (migration 20261116120000) deletes the `.../corporate/xbrl/-` rows the
-- edge filed as filings, and touches nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database deletes nothing, so applying the
-- migration set proves nothing about it. The fixture holds one row of each kind the rule must tell
-- apart:
--   * the placeholder, filed for two companies: deleted for both;
--   * a real `.xml` result of the same company: kept;
--   * a link that merely ends in `-` but is not the placeholder: kept (the match is exact);
--   * the placeholder filed by another lane, for a company of its own (a filing's key is the
--     security and the accession): kept, so the source rule is load-bearing;
--   * the placeholder owning a segment row (none does in production): kept, so the guard against
--     deleting a filing something names is exercised.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('nse','NSE',100)
  on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('t-other-lane','Another lane',10)
  on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order)
  values ('revenue', 'Revenue', 'income', 'currency', true, false, 1) on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-0000000006a1', 'N6A1 Reliance', 'equity'),
  ('00000000-0000-0000-0000-0000000006a2', 'N6A2 Axis', 'equity'),
  ('00000000-0000-0000-0000-0000000006a3', 'N6A3 Owned', 'equity'),
  ('00000000-0000-0000-0000-0000000006a4', 'N6A4 Other lane', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, report_type, segments_parsed_at,
   segments_parser_version)
values
  ('00000000-0000-0000-0000-0000000006a1', 'https://nsearchives.nseindia.com/corporate/xbrl/-',
   'nse', 'Annual', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-0000000006a2', 'https://nsearchives.nseindia.com/corporate/xbrl/-',
   'nse', 'Annual', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-0000000006a1',
   'https://nsearchives.nseindia.com/corporate/xbrl/INDAS_1.xml', 'nse', 'Annual',
   timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-0000000006a1', 'https://nsearchives.nseindia.com/corporate/x-',
   'nse', 'Annual', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-0000000006a4', 'https://nsearchives.nseindia.com/corporate/xbrl/-',
   't-other-lane', 'Annual', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-0000000006a3', 'https://nsearchives.nseindia.com/corporate/xbrl/-',
   'nse', 'Annual', timestamptz '2026-10-01', 20);

insert into market.security_segment
  (security_id, accession_number, axis, member_code, metric_code, period_type, period_start,
   period_ending, value, source_code, partition_id)
values
  ('00000000-0000-0000-0000-0000000006a3', 'https://nsearchives.nseindia.com/corporate/xbrl/-',
   'in-bse-fin:ReportableSegmentsAxis', 'nse:RetailMember', 'revenue', 'annual', '2023-04-01',
   '2024-03-31', 1, 'nse', 1);

delete from market.one_shot where key = 'nse-placeholder-filings-2026-11-16';

\i stack/supabase/migrations/20261116120000_the_india_filing_walker_leaves_the_edge.sql

do $$
declare
  got text;
  want text := concat_ws(' | ',
    '6a1 https://nsearchives.nseindia.com/corporate/x- nse',
    '6a1 https://nsearchives.nseindia.com/corporate/xbrl/INDAS_1.xml nse',
    '6a3 https://nsearchives.nseindia.com/corporate/xbrl/- nse',
    '6a4 https://nsearchives.nseindia.com/corporate/xbrl/- t-other-lane');
begin
  select string_agg(concat_ws(' ', right(security_id::text, 3), accession_number, source_code),
                    ' | ' order by security_id, accession_number)
    into got
    from market.security_filing
   where security_id::text like '00000000-0000-0000-0000-0000000006a_';

  if got is distinct from want then
    raise exception E'the NSE placeholder clean-up touched the wrong rows\n got: %\nwant: %',
      got, want;
  end if;
  if not exists (select 1 from market.one_shot where key = 'nse-placeholder-filings-2026-11-16'
                   and reason like 'deleted 2 %') then
    raise exception 'the clean-up must record the rows it deleted in market.one_shot';
  end if;
  raise notice 'ok  only the placeholders nothing names are deleted';
end $$;

-- ONE-SHOT: a placeholder filed again after the clean-up is left to the contract step.
insert into market.security_filing (security_id, accession_number, source_code, report_type)
values ('00000000-0000-0000-0000-0000000006a1', 'https://nsearchives.nseindia.com/corporate/xbrl/-',
        'nse', 'Annual');

\i stack/supabase/migrations/20261116120000_the_india_filing_walker_leaves_the_edge.sql

do $$
begin
  if not exists (select 1 from market.security_filing
                  where security_id = '00000000-0000-0000-0000-0000000006a1'
                    and accession_number = 'https://nsearchives.nseindia.com/corporate/xbrl/-') then
    raise exception 'the clean-up ran twice; its key in market.one_shot is what stops that';
  end if;
  raise notice 'ok  the clean-up is one-shot';
end $$;

rollback;
