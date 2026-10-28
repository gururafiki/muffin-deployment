-- COMPANY FACTS READ THEIR OWN CONCEPTS, AND A FILING NAMES ITS REGULATOR.
-- Migrations 20261028100000 and 20261028100100 (Phase 5 step 4).
--
-- Four ways to get this wrong, each asserted:
--   1. an addition that repeats an `xbrl_concept` row, so a concept is ranked twice;
--   2. a metric the reader can produce with no `sec-xbrl` row in `metric_source_field`, so its
--      statement lines are never derived into metrics;
--   3. a `sec-xbrl` row whose statement is not the one its category places it in, or whose field is
--      not the metric code the reader writes;
--   4. the worker able to rewrite its own vocabulary.
-- Plus a floor: the US balance lines this exists for are there.

begin;

do $$
declare
  n bigint;
  missing text;
begin
  -- 1.
  select count(*) into n
    from market.xbrl_fact_concept f
    join market.xbrl_concept c using (metric_code, taxonomy, concept);
  if n > 0 then
    raise exception 'xbrl_fact_concept repeats % xbrl_concept row(s): one concept ranked twice', n;
  end if;

  -- The floor: what the table exists for.
  select string_agg(want, ', ') into missing
    from unnest(array['total_assets:us-gaap:Assets', 'total_liabilities:us-gaap:Liabilities',
                      'gross_profit:us-gaap:GrossProfit', 'goodwill:ifrs-full:Goodwill']) want
   where not exists (select 1 from market.xbrl_fact_concept f
                      where f.metric_code || ':' || f.taxonomy || ':' || f.concept = want);
  if missing is not null then
    raise exception 'xbrl_fact_concept lacks %', missing;
  end if;

  -- 2.
  select string_agg(metric_code, ', ' order by metric_code) into missing
    from (select metric_code from market.xbrl_concept
          union select metric_code from market.xbrl_fact_concept) produced
   where not exists (select 1 from market.metric_source_field s
                      where s.metric_code = produced.metric_code and s.source_code = 'sec-xbrl');
  if missing is not null then
    raise exception 'no sec-xbrl metric_source_field row for %: those lines would never be derived',
      missing;
  end if;

  -- 3.
  select string_agg(s.metric_code || ' in ' || s.statement || ' as ' || s.field, ', ') into missing
    from market.metric_source_field s
    join market.metric m on m.code = s.metric_code
   where s.source_code = 'sec-xbrl'
     and (s.field <> s.metric_code
          or s.statement is distinct from case m.category
                                            when 'income_statement' then 'income'
                                            when 'balance_sheet' then 'balance'
                                            when 'cash_flow' then 'cash'
                                            when 'share' then 'income'
                                          end);
  if missing is not null then
    raise exception 'sec-xbrl lines placed where the reader does not write them: %', missing;
  end if;
  -- The share counts are the case a category map gets wrong: they belong beside EPS.
  if (select statement from market.metric_source_field
       where metric_code = 'shares_diluted' and source_code = 'sec-xbrl') is distinct from 'income' then
    raise exception 'sec-xbrl shares_diluted is not read from the income statement';
  end if;

  -- 4.
  if has_table_privilege('ingest_rw', 'market.xbrl_fact_concept', 'INSERT')
     or has_table_privilege('ingest_rw', 'market.xbrl_fact_concept', 'UPDATE')
     or has_table_privilege('ingest_rw', 'market.xbrl_fact_concept', 'DELETE') then
    raise exception 'ingest_rw can rewrite xbrl_fact_concept, the vocabulary it reads';
  end if;
  if not has_table_privilege('ingest_rw', 'market.xbrl_fact_concept', 'SELECT') then
    raise exception 'ingest_rw cannot read xbrl_fact_concept';
  end if;

  -- The regulator column, and that it refuses a regulator that does not exist.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'market.security_filing'::regclass and contype = 'f'
                    and pg_get_constraintdef(oid) like '%(disclosure_source_code)%disclosure_source(code)%') then
    raise exception 'security_filing.disclosure_source_code does not reference disclosure_source';
  end if;
end $$;

rollback;
