-- CORRECT WHAT WE ALREADY SERVE BEFORE READING SOMETHING NEW.
--
-- `segment_parser.version` re-queues every filing when it is bumped, so after a bump the queue
-- holds two very different things: filings never read, and filings whose STORED rows are now known
-- to be wrong. They are not equally urgent. A re-read fixes a number on a page today; a first read
-- adds data nobody is being shown yet.
--
-- Measured in production 2026-09-05, which is why this rule exists: of the 352 filings backing a
-- SERVED split, **329 (93%) had been parsed by an older parser**. Almost everything a reader saw
-- was produced by code since fixed, while the queue worked through 213,500 filings at 20 a run —
-- 37 days to drain, with the visible data wrong for most of it.
--
-- BREADTH-FIRST STILL WINS, and the fixture proves the two rules in the right order. Migration
-- 156's property must survive: every company gets its latest annual before any gets a second year.
-- So a round-1 FIRST READ must still outrank a round-2 RE-READ; only within one round does the
-- re-read go first. A fixture where the two never disagree cannot tell the orderings apart.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZY','Orderland','ZY',false)
  on conflict (iso2) do nothing;
insert into market.currency (code) values ('USD') on conflict do nothing;
insert into market.disclosure_source (code, name, identifier_label, priority, enabled)
values ('sec','SEC','CIK',100,true)
on conflict (code) do update set enabled = excluded.enabled;
insert into market.filing_form (source_code, form_code, is_annual, carries_segments)
values ('sec','10-K',true,true)
on conflict (source_code, form_code) do update set carries_segments = excluded.carries_segments;

-- Two companies, so `round` is per-company and the breadth-first assertion has something to say.
insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-0000000d7201','T172 Already Served Inc','equity','ZY','0000777201'),
  ('00000000-0000-0000-0000-0000000d7202','T172 Never Read Inc','equity','ZY','0000777202')
on conflict do nothing;
insert into market.security_filer (security_id, source_code, filer_id) values
  ('00000000-0000-0000-0000-0000000d7201','sec','0000777201'),
  ('00000000-0000-0000-0000-0000000d7202','sec','0000777202')
on conflict do nothing;

-- A: its newest annual was READ by an old parser -> round 1, already_read.
-- B: its newest annual has NEVER been read       -> round 1, not read.
--
-- THE ACCESSIONS ARE CHOSEN SO THE TWO RULES DISAGREE. Both fixtures have weight 0, so the
-- remaining tie-break is `accession_number` ascending — and B's is the LOWER one. Without
-- `already_read desc` the queue therefore heads with B, and with it, A. The first version of this
-- fixture numbered them the other way round: accession order alone produced the same answer, and a
-- mutation deleting the ordering passed clean twice.
-- A also has an older annual, never read         -> round 2, so it must NOT jump the round-1 work.
insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code,
   segments_parsed_at, segments_parser_version) values
  ('00000000-0000-0000-0000-0000000d7201','0000999999-25-000001','10-K','2025-02-01','sec-submissions',
   now() - interval '30 days', 1),
  ('00000000-0000-0000-0000-0000000d7202','0000111111-25-000001','10-K','2025-02-01','sec-submissions',
   null, null),
  ('00000000-0000-0000-0000-0000000d7201','0000999999-24-000001','10-K','2024-02-01','sec-submissions',
   now() - interval '30 days', 1)
on conflict do nothing;

do $$
declare
  first_acc  text;
  second_acc text;
  r_reread   int;
  r_old      int;
begin
  -- 1. THE HEAD IS THE RE-READ. Both are round 1; the one we are already serving from goes first.
  -- NO `order by` HERE, DELIBERATELY. The resource reads this view with a bare `.limit(n)` and
  -- relies on the view's OWN ordering, so a test that supplies its own is testing itself: the
  -- first version of this did exactly that and a mutation deleting the view's ordering passed
  -- clean.
  select accession_number into first_acc
    from market.pending_segments
   where security_id in ('00000000-0000-0000-0000-0000000d7201',
                         '00000000-0000-0000-0000-0000000d7202')
   limit 1;
  if first_acc is distinct from '0000999999-25-000001' then
    raise exception 'the head of the queue should be the filing we already serve from, got % — '
                    'a re-read corrects a page today, a first read only adds data nobody sees yet',
                    coalesce(first_acc, '<none>');
  end if;

  -- 2. AND THE FIRST READ IS STILL SECOND, not starved: it is round 1 too.
  select accession_number into second_acc
    from (select accession_number, row_number() over () as rn
            from market.pending_segments
           where security_id in ('00000000-0000-0000-0000-0000000d7201',
                                 '00000000-0000-0000-0000-0000000d7202')) q
   where rn = 2;
  if second_acc is distinct from '0000111111-25-000001' then
    raise exception 'the never-read round-1 filing must come second, got % — prioritising re-reads '
                    'must reorder a head, never starve new work', coalesce(second_acc,'<none>');
  end if;

  -- 3. BREADTH-FIRST SURVIVES: A's round-2 re-read must NOT outrank B's round-1 first read.
  --    This is the assertion that makes the two orderings disagree — under "re-reads first"
  --    alone, A's 2024 filing (already_read) would jump ahead of B's unread newest annual, and
  --    migration 156's whole property would be gone.
  select round into r_reread from market.pending_segments
   where accession_number = '0000999999-24-000001';
  select round into r_old   from market.pending_segments
   where accession_number = '0000111111-25-000001';
  if r_reread <= r_old then
    raise exception 'a round-2 re-read (round %) is not outranked by a round-1 first read '
                    '(round %) — breadth-first has been lost', r_reread, r_old;
  end if;

  raise notice 'ok  a re-read corrects before a first read adds, and breadth-first still wins';
end $$;

rollback;
