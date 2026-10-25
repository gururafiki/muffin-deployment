-- A FILING FORM SAYS WHAT KIND IT IS, AND THE SEGMENT QUEUE DOES NOT GROW BY IT.
--
-- Migration 20261025100300 made `market.filing_form` the SEC forms' control table. Three things
-- must hold for that to be safe while the edge segments handler still reads it:
--   1. `carries_segments` is true on EXACTLY 10-K, 10-Q, 20-F and 40-F, so a seeded amendment or
--      event cannot enter `pending_segments`;
--   2. every SEC report type production holds has a row, so the SEC lane's `kept` set loses nothing
--      the edge stores today (the list is the measured one of 2026-10-24);
--   3. the forms that change a company's XBRL facts are exactly the accounts forms, and a 6-K is
--      accounts that does not (a foreign private issuer's interim, with no XBRL statements);
-- plus: the worker cannot rewrite the table.

\set ON_ERROR_STOP on

begin;

do $$
declare
  got text;
  missing text;
begin
  select string_agg(form_code, ',' order by form_code) into got
    from market.filing_form where source_code = 'sec' and carries_segments;
  if got is distinct from '10-K,10-Q,20-F,40-F' then
    raise exception 'carries_segments must be true on exactly 10-K, 10-Q, 20-F and 40-F, got %', got;
  end if;

  select string_agg(f, ',') into missing
    from unnest(array['10-Q','8-K','10-K','6-K','20-F','8-K/A','40-F','10-K/A','10-Q/A','NT 10-Q',
                      'NT 10-K','6-K/A','20-F/A','8-K12B','NT 20-F','10-KT','8-K12G3','8-K12B/A',
                      'NT 10-K/A','10-QT']) f
   where not exists (select 1 from market.filing_form ff
                      where ff.source_code = 'sec' and ff.form_code = f and ff.kept);
  if missing is not null then
    raise exception 'SEC report types production holds have no kept filing_form row: %', missing;
  end if;

  select string_agg(form_code, ',' order by form_code) into got
    from market.filing_form where source_code = 'sec' and refreshes_facts;
  if got is distinct from '10-K,10-K/A,10-KT,10-KT/A,10-Q,10-Q/A,10-QT,20-F,20-F/A,40-F,40-F/A' then
    raise exception 'refreshes_facts must be the accounts forms that carry XBRL statements, got %', got;
  end if;

  select kind into got from market.filing_form where source_code = 'sec' and form_code = '6-K';
  if got is distinct from 'accounts' then
    raise exception 'a 6-K is a foreign private issuer''s interim report, not %', got;
  end if;

  if exists (select 1 from market.filing_form
              where source_code = 'sec' and is_amendment <> (form_code like '%/A')) then
    raise exception 'is_amendment disagrees with the form code on %',
      (select string_agg(form_code, ',') from market.filing_form
        where source_code = 'sec' and is_amendment <> (form_code like '%/A'));
  end if;

  if has_table_privilege('ingest_rw', 'market.filing_form', 'INSERT')
     or has_table_privilege('ingest_rw', 'market.filing_form', 'UPDATE')
     or has_table_privilege('ingest_rw', 'market.filing_form', 'DELETE') then
    raise exception 'ingest_rw can rewrite market.filing_form, the instructions it reads';
  end if;
end $$;

\echo ok every held SEC form is kept, and only the four accounts forms carry segments

rollback;
