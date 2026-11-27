-- A company's regulator filer reaches every equity listing of that company, a registry always
-- wins, and a link the rule stops wanting is retracted with what it brought (migration
-- 20261127090000).
--
-- Issuers and what the rule must do:
--   I1  A (registry sec 111, a 10-K read and a 10-Q unread), A2 (registry sec 111, read less),
--       B (equity, nothing) -> linked and copied FROM A; C (a bond) -> never; N (equity, already
--       linked) -> kept through the trigger
--   I2  D (registry dart d2, accounts), E (registry cninfo c2, accounts) -> REFUSED; F -> nothing
--   I3  G (registry sec 333, a 10-Q only: not accounts) -> nothing to link; H -> nothing
--   I4  J (registry cninfo c4, accounts); K (its own registry sec row, no accounts) -> linked cninfo
--   I5  M (a stale sibling row for sec 111, a copied 10-K and its segment, a filing of its own)
--       -> retracted, with the copied rows and not its own
-- (The rule's "holes only" clause is equivalent under the refusal rule: a listing holding the
-- issuer's one registry filer conflicts with the insert. It is kept as a statement of intent.)

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity'), ('bond','Bond')
  on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('sec-submissions','SEC submissions',100), ('sec-segments','SEC segments',100),
  ('cninfo','CNINFO',100), ('dart','DART',100), ('t-own','Own',100)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  ('revenue', 'Revenue', 'income', 'currency', true, false, 1)
on conflict (code) do nothing;

insert into market.issuer (issuer_id, name) values
  ('00000000-0000-0000-0000-0000000271a1', 'I1'), ('00000000-0000-0000-0000-0000000271a2', 'I2'),
  ('00000000-0000-0000-0000-0000000271a3', 'I3'), ('00000000-0000-0000-0000-0000000271a4', 'I4'),
  ('00000000-0000-0000-0000-0000000271a5', 'I5');

insert into market.security (security_id, name, security_type_code, issuer_id, country_iso2) values
  ('00000000-0000-0000-0000-000000027101', 'A',  'equity', '00000000-0000-0000-0000-0000000271a1', null),
  ('00000000-0000-0000-0000-000000027102', 'A2', 'equity', '00000000-0000-0000-0000-0000000271a1', null),
  ('00000000-0000-0000-0000-000000027103', 'B',  'equity', '00000000-0000-0000-0000-0000000271a1', null),
  ('00000000-0000-0000-0000-000000027104', 'C',  'bond',   '00000000-0000-0000-0000-0000000271a1', null),
  ('00000000-0000-0000-0000-000000027105', 'N',  'equity', '00000000-0000-0000-0000-0000000271a1', null),
  ('00000000-0000-0000-0000-000000027106', 'D',  'equity', '00000000-0000-0000-0000-0000000271a2', null),
  ('00000000-0000-0000-0000-000000027107', 'E',  'equity', '00000000-0000-0000-0000-0000000271a2', null),
  ('00000000-0000-0000-0000-000000027108', 'F',  'equity', '00000000-0000-0000-0000-0000000271a2', null),
  ('00000000-0000-0000-0000-000000027109', 'G',  'equity', '00000000-0000-0000-0000-0000000271a3', null),
  ('00000000-0000-0000-0000-000000027110', 'H',  'equity', '00000000-0000-0000-0000-0000000271a3', null),
  ('00000000-0000-0000-0000-000000027111', 'J',  'equity', '00000000-0000-0000-0000-0000000271a4', null),
  ('00000000-0000-0000-0000-000000027112', 'K',  'equity', '00000000-0000-0000-0000-0000000271a4', null),
  ('00000000-0000-0000-0000-000000027113', 'M',  'equity', '00000000-0000-0000-0000-0000000271a5', null),
  ('00000000-0000-0000-0000-000000027114', 'P',  'equity', null, 'IN');

-- Registry rows. A and A2 hold CIK 111 through the trigger, G CIK 333, K CIK 444.
update market.security set cik = 111 where name in ('A', 'A2') and security_id::text like '%0271%';
update market.security set cik = 333 where security_id = '00000000-0000-0000-0000-000000027109';
update market.security set cik = 444 where security_id = '00000000-0000-0000-0000-000000027112';
insert into market.security_filer (security_id, source_code, filer_id, via) values
  ('00000000-0000-0000-0000-000000027106', 'dart',   'd2',  'registry'),
  ('00000000-0000-0000-0000-000000027107', 'cninfo', 'c2',  'registry'),
  ('00000000-0000-0000-0000-000000027111', 'cninfo', 'c4',  'registry'),
  ('00000000-0000-0000-0000-000000027105', 'sec',    '111', 'issuer_sibling'),
  ('00000000-0000-0000-0000-000000027113', 'sec',    '111', 'issuer_sibling');

insert into market.security_filing
  (security_id, accession_number, filing_date, report_date, report_type, source_code, is_xbrl,
   segments_parsed_at, segments_parser_version) values
  ('00000000-0000-0000-0000-000000027101', 'a-10k', '2025-02-01', '2024-12-31', '10-K', 'sec-submissions', true, now(), 20),
  ('00000000-0000-0000-0000-000000027101', 'a-10q', '2025-05-01', '2025-03-31', '10-Q', 'sec-submissions', true, null, 0),
  ('00000000-0000-0000-0000-000000027102', 'a-10k', '2025-02-01', '2024-12-31', '10-K', 'sec-submissions', true, null, 0),
  ('00000000-0000-0000-0000-000000027106', 'd-ar',  '2025-03-01', '2024-12-31', '사업보고서', 'dart', true, now(), 20),
  ('00000000-0000-0000-0000-000000027107', 'e-ar',  '2025-03-01', '2024-12-31', '年度报告', 'cninfo', false, now(), 20),
  ('00000000-0000-0000-0000-000000027109', 'g-10q', '2025-05-01', '2025-03-31', '10-Q', 'sec-submissions', true, now(), 20),
  ('00000000-0000-0000-0000-000000027111', 'j-ar',  '2025-03-01', '2024-12-31', '年度报告', 'cninfo', false, now(), 20),
  -- M: a copy of A's 10-K (brought by its old link) and a filing of its own
  ('00000000-0000-0000-0000-000000027113', 'a-10k', '2025-02-01', '2024-12-31', '10-K', 'sec-submissions', true, now(), 20),
  ('00000000-0000-0000-0000-000000027113', 'm-own', '2025-02-01', '2024-12-31', 'own', 't-own', false, null, null);

insert into market.security_segment
  (security_id, accession_number, axis, member_code, parent_axis, parent_member, metric_code,
   period_type, period_start, period_ending, value, source_code, partition_id, reconciled_to)
values
  ('00000000-0000-0000-0000-000000027101', 'a-10k', 'ax', 'm:read',   null, null, 'revenue', 'annual', '2024-01-01', '2024-12-31', 70, 'sec-segments', 1, 100),
  ('00000000-0000-0000-0000-000000027101', 'a-10q', 'ax', 'm:unread', null, null, 'revenue', 'quarter', '2025-01-01', '2025-03-31', 20, 'sec-segments', 1, 30),
  ('00000000-0000-0000-0000-000000027113', 'a-10k', 'ax', 'm:read',   null, null, 'revenue', 'annual', '2024-01-01', '2024-12-31', 70, 'sec-segments', 1, 100),
  ('00000000-0000-0000-0000-000000027113', 'm-own', 'ax', 'm:own',    null, null, 'revenue', 'annual', '2024-01-01', '2024-12-31', 5,  't-own', 1, 5);

do $$
declare
  r record;
  c record;
  links text;
begin
  select * into r from market.extend_filers_to_issuer_siblings();
  if (r.inserted, r.retracted, r.refused) is distinct from (2, 1, 1) then
    raise exception 'extend returned inserted %, retracted %, refused % rather than 2, 1, 1',
      r.inserted, r.retracted, r.refused;
  end if;

  select string_agg(s.name || '=' || f.source_code || ':' || f.filer_id, ',' order by s.name) into links
    from market.security_filer f join market.security s using (security_id)
   where f.via = 'issuer_sibling' and s.security_id::text like '%0271%' and s.name <> 'P';
  if links is distinct from 'B=sec:111,K=cninfo:c4,N=sec:111' then
    raise exception 'sibling links are % rather than B=sec:111,K=cninfo:c4,N=sec:111', links;
  end if;

  -- M's link is retracted with what it brought, and nothing of its own.
  if exists (select 1 from market.security_filing where security_id = '00000000-0000-0000-0000-000000027113' and accession_number = 'a-10k')
     or exists (select 1 from market.security_segment where security_id = '00000000-0000-0000-0000-000000027113' and accession_number = 'a-10k') then
    raise exception 'a retracted link left the filing and segments it brought';
  end if;
  if not exists (select 1 from market.security_filing where security_id = '00000000-0000-0000-0000-000000027113' and accession_number = 'm-own')
     or not exists (select 1 from market.security_segment where security_id = '00000000-0000-0000-0000-000000027113' and member_code = 'm:own') then
    raise exception 'a retracted link took the security''s own rows with it';
  end if;

  -- WHO NEEDS A COPY: every holder with none of its filer's history beside a holder with some. G is
  -- its filer's only holder; A2 holds A's accessions already; M lost its link.
  select string_agg(s.name || '=' || h.source_code, ',' order by s.name) into links
    from market.filer_holders_to_copy() h join market.security s using (security_id)
   where s.security_id::text like '%0271%';
  if links is distinct from 'B=sec,K=cninfo,N=sec' then
    raise exception 'holders to copy are % rather than B=sec,K=cninfo,N=sec', links;
  end if;

  -- B's history comes from A (the listing that has read the most), and only what A read.
  select * into c from market.copy_filer_history('00000000-0000-0000-0000-000000027103', 'sec');
  if (c.filings, c.segments) is distinct from (2, 1) then
    raise exception 'copy returned % filings and % segments rather than 2 and 1', c.filings, c.segments;
  end if;
  if not exists (select 1 from market.security_filing
                  where security_id = '00000000-0000-0000-0000-000000027103' and accession_number = 'a-10k'
                    and segments_parser_version = 20 and segments_parsed_at is not null) then
    raise exception 'the copied 10-K did not keep the markers of the listing that read it';
  end if;
  if exists (select 1 from market.security_segment
              where security_id = '00000000-0000-0000-0000-000000027103' and member_code = 'm:unread') then
    raise exception 'segments of a filing behind the parser were copied';
  end if;

  select string_agg(s.name || '=' || h.source_code, ',' order by s.name) into links
    from market.filer_holders_to_copy() h join market.security s using (security_id)
   where s.security_id::text like '%0271%';
  if links is distinct from 'K=cninfo,N=sec' then
    raise exception 'after its copy, holders to copy are % rather than K=cninfo,N=sec', links;
  end if;

  -- Run again: B now holds accounts of its own copy, which must neither retract it nor make it a
  -- source (two filers for I1 would refuse I1).
  select * into r from market.extend_filers_to_issuer_siblings();
  if (r.inserted, r.retracted, r.refused) is distinct from (0, 0, 1) then
    raise exception 'a second run returned inserted %, retracted %, refused % rather than 0, 0, 1',
      r.inserted, r.retracted, r.refused;
  end if;
end $$;

-- THE SEC TRIGGER: a write naming `cik` keeps a sibling row; a CIK claims the row; clearing that
-- CIK retracts the claim.
update market.security set cik = null where security_id = '00000000-0000-0000-0000-000000027105';
do $$ begin
  if not exists (select 1 from market.security_filer where security_id = '00000000-0000-0000-0000-000000027105'
                   and source_code = 'sec' and via = 'issuer_sibling') then
    raise exception 'a write naming a null cik deleted a sibling row';
  end if;
end $$;
update market.security set cik = 999 where security_id = '00000000-0000-0000-0000-000000027105';
do $$ begin
  if not exists (select 1 from market.security_filer where security_id = '00000000-0000-0000-0000-000000027105'
                   and source_code = 'sec' and filer_id = '999' and via = 'registry') then
    raise exception 'a CIK did not claim its row as the registry''s';
  end if;
end $$;
update market.security set cik = null where security_id = '00000000-0000-0000-0000-000000027105';
do $$ begin
  if exists (select 1 from market.security_filer where security_id = '00000000-0000-0000-0000-000000027105'
               and source_code = 'sec') then
    raise exception 'a cleared CIK left its registry row';
  end if;
end $$;

-- THE NSE MAP claims a sibling row, whose filer id it replaces. (Inserted only now: P has no issuer,
-- so an extend run would have retracted it, and this would pass whatever the map did.)
insert into market.security_filer (security_id, source_code, filer_id, via)
values ('00000000-0000-0000-0000-000000027114', 'nse', 'OLD', 'issuer_sibling');
insert into market.security_identifier (kind_code, value, security_id, source_code)
values ('isin', 'INE0271T0001', '00000000-0000-0000-0000-000000027114', 't-own');
select market.apply_nse_symbol_map('{"INE0271T0001": "PTEST"}'::jsonb);
do $$ begin
  if not exists (select 1 from market.security_filer where security_id = '00000000-0000-0000-0000-000000027114'
                   and source_code = 'nse' and filer_id = 'PTEST' and via = 'registry') then
    raise exception 'the NSE map did not claim the row as the registry''s: %',
      (select filer_id || '/' || via from market.security_filer
        where security_id = '00000000-0000-0000-0000-000000027114' and source_code = 'nse');
  end if;
end $$;

-- The worker may run both functions, and nobody else may.
do $$ begin
  if not has_function_privilege('ingest_rw', 'market.extend_filers_to_issuer_siblings()', 'execute')
     or not has_function_privilege('ingest_rw', 'market.copy_filer_history(uuid, text)', 'execute')
     or not has_function_privilege('ingest_rw', 'market.filer_holders_to_copy()', 'execute') then
    raise exception 'ingest_rw cannot run the sibling functions';
  end if;
  if has_function_privilege('anon', 'market.extend_filers_to_issuer_siblings()', 'execute')
     or has_function_privilege('anon', 'market.copy_filer_history(uuid, text)', 'execute') then
    raise exception 'anon can run the sibling functions';
  end if;
end $$;

rollback;
