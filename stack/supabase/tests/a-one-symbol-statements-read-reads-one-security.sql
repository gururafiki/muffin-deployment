-- A ONE-SYMBOL STATEMENTS READ READS ONE SECURITY'S STATEMENTS, NOT EVERY SECURITY'S SYMBOL.
--
-- WHY THIS IS A TEST. The stock page reads `security_statement_current` one symbol at a time. While
-- the view joined `security_symbol`, which computes each security's symbol with LATERAL subqueries,
-- the symbol filter could not narrow the read: on 2026-10-18 an AAPL read scanned 85,597 income
-- statements and resolved 27,977 securities (407 ms on the server, up to 0.85 s as anon), and the
-- cost grew with every statement the company lane wrote. On a fixture this size every plan finishes
-- in milliseconds, so a timing proves nothing; the number of rows the read touches does not depend on
-- the table's size, so that is asserted instead (migration 20261018210000).
--
-- WHAT MAKES THE TWO VIEWS DISAGREE. 300 other securities each hold a ticker and two income
-- statements, and the read asks about one security holding two. The target's id sorts LAST, so a
-- plan walking securities or statements in id order cannot stop early and look narrow. Rows are
-- summed over EVERY relation the plan scans, not only `security_statement`: through
-- `security_symbol` a plan can either scan every statement or compute every security's symbol and
-- probe the statements afterwards, and the second touches few statements while touching every
-- identifier. Either way it touches hundreds of rows; a read narrowed by the symbol touches a handful.
--
-- Seq scans are off because on a fixture this small one can be the cheapest plan, and it reads every
-- row even when the filter could have reached the index. The test is about where the filter can go.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec','SEC EDGAR',200) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('XS','Statementland','XS',false)
  on conflict (iso2) do nothing;

-- The target, with the largest id in the fixture.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('ffffffff-ffff-ffff-ffff-fffffff21001', 'T210 Target', 'equity', 'XS')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T210T', 'ffffffff-ffff-ffff-ffff-fffffff21001', 'sec')
on conflict (kind_code, value) do nothing;

-- 300 others, each with a ticker and two income statements.
insert into market.security (security_id, name, security_type_code, country_iso2)
select ('00000000-0000-0000-0000-' || lpad(to_hex(210000 + g), 12, '0'))::uuid,
       'T210 Other ' || g, 'equity', 'XS'
  from generate_series(1, 300) g
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code)
select 'ticker', 'T210O' || g, ('00000000-0000-0000-0000-' || lpad(to_hex(210000 + g), 12, '0'))::uuid,
       'sec'
  from generate_series(1, 300) g
on conflict (kind_code, value) do nothing;
insert into market.security_statement
  (security_id, statement, period_ending, period_type, data, source_code, currency, as_of)
select ('00000000-0000-0000-0000-' || lpad(to_hex(210000 + g), 12, '0'))::uuid,
       'income', d, 'annual', '{}'::jsonb, 'sec', null, now()
  from generate_series(1, 300) g,
       (values (date '2024-12-31'), (date '2025-12-31')) p (d)
on conflict do nothing;

insert into market.security_statement
  (security_id, statement, period_ending, period_type, data, source_code, currency, as_of) values
  ('ffffffff-ffff-ffff-ffff-fffffff21001', 'income', date '2024-12-31', 'annual', '{"revenue": 1}'::jsonb, 'sec', null, now()),
  ('ffffffff-ffff-ffff-ffff-fffffff21001', 'income', date '2025-12-31', 'annual', '{"revenue": 2}'::jsonb, 'sec', null, now())
on conflict do nothing;

refresh materialized view market.symbol_security;
analyze market.security, market.security_identifier, market.security_statement, market.symbol_security;

set local max_parallel_workers_per_gather = 0;
set local enable_seqscan = off;

do $$
declare p jsonb; touched numeric; statements numeric; n integer;
begin
  -- 0. THE READ ANSWERS, so the measurement below is of a read that did its work.
  select count(*) into n from market.security_statement_current
   where symbol = 'T210T' and statement = 'income';
  if n <> 2 then
    raise exception 'the target has % income statements in the view, expected 2 — the fixture no longer exercises the read', n;
  end if;

  -- The app's own read (muffin-ui use-statements.ts).
  execute format(
    'explain (analyze, format json) select period_ending, reporting_currency, data
       from market.security_statement_current
      where statement = %L and symbol = %L order by period_ending desc limit 4',
    'income', 'T210T') into p;

  select coalesce(sum((node->>'Actual Rows')::numeric * (node->>'Actual Loops')::numeric), 0)
    into touched
    from jsonb_path_query(p, 'strict $.**') node
   where jsonb_typeof(node) = 'object' and node ? 'Relation Name';
  select coalesce(sum((node->>'Actual Rows')::numeric * (node->>'Actual Loops')::numeric), 0)
    into statements
    from jsonb_path_query(p, 'strict $.**') node
   where jsonb_typeof(node) = 'object' and node->>'Relation Name' = 'security_statement';

  -- 1. THE MEASUREMENT SEES THE TARGET'S OWN TWO STATEMENTS. Zero would mean the plan no longer
  --    names the table this way, and every later read would pass whatever the view did.
  if statements < 2 then
    raise exception 'the read touched % statement rows, fewer than the target''s own 2 — the plan walk no longer finds the scans of security_statement', statements;
  end if;

  -- 2. AND ONLY A HANDFUL OF ROWS IN ALL. Hundreds means the read resolves every security's symbol,
  --    or scans every statement, before it can filter.
  if touched > 30 then
    raise exception 'a one-symbol statements read touched % rows across its relations, where the symbol holds 2 statements of 602. The symbol filter is not reaching an index: in production this read grows with every statement written and anon times out', touched;
  end if;
  raise notice '  ok  a one-symbol statements read touches % rows (% of them statements)', touched, statements;
end $$;

rollback;

\echo 'ok: a one-symbol statements read reads one security'
