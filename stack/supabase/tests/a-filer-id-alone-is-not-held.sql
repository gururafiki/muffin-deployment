-- A FILER ID ALONE IS NOT A CAPABILITY: it is `held` once its regulator has an annual accounts
-- filing for the security (migration 20261126190000).
--
-- WHY. 171 of the 300 largest SEC "filers" with no split hold a CIK and file no 10-K, 20-F or 40-F
-- (measured 2026-11-26). Read as `held: sec`, they were hidden from the regulator that can serve
-- them and from the gap.
--
-- THE FIXTURE MAKES THE RULES DISAGREE. Every security holds a filer id; only what it files differs:
--   A  a CIK and a 10-Q only        -> not held (a quarterly report is not the annual accounts);
--   B  a CIK and a 6-K only, in KR  -> not held by SEC; DART is enabled, so `resolvable` via DART;
--   C  a CIK and a 20-F             -> held by SEC;
--   D  a DART corp code and a 사업보고서 -> held by DART;
--   E  a CIK and a 10-K/A only      -> not held (an amendment carries no segments: `carries_segments`).
-- Under the old rule (any filer id is held) every one reads `held`.
\set ON_ERROR_STOP on
begin;
insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('KR','Korea, Republic of','KR',true), ('KY','Cayman Islands','KY',false), ('US','United States','US',true)
on conflict (iso2) do nothing;
update market.disclosure_source set enabled = true where code in ('sec', 'dart');
insert into market.disclosure_coverage (source_code, country_iso2) values ('dart', 'KR') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-00000002611a','T261 quarterly only','equity','KY', 2611001),
  ('00000000-0000-0000-0000-00000002611b','T261 6-K only',      'equity','KR', 2611002),
  ('00000000-0000-0000-0000-00000002611c','T261 20-F',          'equity','KY', 2611003),
  ('00000000-0000-0000-0000-00000002611d','T261 DART',          'equity','KR', null),
  ('00000000-0000-0000-0000-00000002611e','T261 amendment only','equity','KY', 2611005)
on conflict (security_id) do nothing;
insert into market.security_filer (security_id, source_code, filer_id) values
  ('00000000-0000-0000-0000-00000002611d', 'dart', '02611004')
on conflict do nothing;
insert into market.security_filing (security_id, accession_number, filing_date, report_type, source_code) values
  ('00000000-0000-0000-0000-00000002611a', 'T261-a', '2026-05-01', '10-Q', 'sec-submissions'),
  ('00000000-0000-0000-0000-00000002611b', 'T261-b', '2026-05-01', '6-K', 'sec-submissions'),
  ('00000000-0000-0000-0000-00000002611c', 'T261-c', '2026-04-01', '20-F', 'sec-submissions'),
  ('00000000-0000-0000-0000-00000002611d', 'T261-d', '2026-03-15', '사업보고서', 'dart'),
  ('00000000-0000-0000-0000-00000002611e', 'T261-e', '2026-04-01', '10-K/A', 'sec-submissions')
on conflict do nothing;

do $$
declare
  got text;
  expected constant text[][] := array[
    ['00000000-0000-0000-0000-00000002611a', 'none', '-'],
    ['00000000-0000-0000-0000-00000002611b', 'resolvable', 'dart'],
    ['00000000-0000-0000-0000-00000002611c', 'held', 'sec'],
    ['00000000-0000-0000-0000-00000002611d', 'held', 'dart'],
    ['00000000-0000-0000-0000-00000002611e', 'none', '-']];
  i int;
begin
  for i in 1 .. array_length(expected, 1) loop
    select capability || '/' || coalesce(segment_source, '-') into got
      from market.security_disclosure where security_id = expected[i][1]::uuid;
    if got is distinct from expected[i][2] || '/' || expected[i][3] then
      raise exception 'security % reads % rather than %/%', expected[i][1], got, expected[i][2], expected[i][3];
    end if;
  end loop;
end $$;
rollback;
