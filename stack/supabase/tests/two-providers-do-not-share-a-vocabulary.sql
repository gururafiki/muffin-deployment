-- THE TWO STATEMENT PROVIDERS DO NOT SHARE A VOCABULARY, so a metric's field name is DATA.
--
-- WHY THIS IS A TEST. Measured on the deployed openbb-api 2026-08-20, AAPL annual: `sec` and
-- `yfinance` income statements share **4 of 40** field names, and one of the four is
-- `period_ending`, which is not data. Pre-tax income is `total_pretax_income` on one and
-- `total_pre_tax_income` on the other — one character.
--
-- Migration 88 made SEC the preferred provider, so `security_statement.data` now genuinely holds
-- two vocabularies. Anything reading `data->>'free_cash_flow'` returns null for every SEC period
-- and raises no error: the chart is simply empty for the securities with the BEST data. That is
-- the failure this file exists to make loud.

\set ON_ERROR_STOP on

begin;

do $$
declare n integer; r record;
begin
  -- 1. EVERY REPORTED METRIC IS REACHABLE FROM EVERY PROVIDER THAT WRITES STATEMENTS. A metric
  --    with no row for `sec` is a metric that silently disappears for the better half of the data.
  for r in
    select m.code, s.code as source
      from market.metric m
      cross join (values ('sec'), ('yfinance')) as s(code)
     where not m.is_derived
       and not exists (
         select 1 from market.metric_source_field f
          where f.metric_code = m.code and f.source_code = s.code)
  loop
    raise exception
      'metric % has no field mapping for % — after migration 88 that provider writes the better half of the statements, and a missing mapping reads as an empty chart, not as an error', r.code, r.source;
  end loop;

  -- 2. A DERIVED METRIC IS DERIVED BECAUSE A PROVIDER LACKS IT, not because nobody wrote the row.
  --    free_cash_flow is reported by yfinance and absent from SEC; total_debt by neither.
  select count(*) into n from market.metric_source_field
   where metric_code = 'free_cash_flow' and source_code = 'sec';
  if n <> 0 then
    raise exception
      'free_cash_flow claims a sec field — SEC reports no free cash flow line (measured), so for a SEC period it must be operating cash flow minus capital expenditure';
  end if;
  if not (select is_derived from market.metric where code = 'free_cash_flow') then
    raise exception 'free_cash_flow is not marked derived, so a reader cannot tell an arithmetic number from a reported one';
  end if;

  -- 3. NO TWO METRICS CLAIM THE SAME PROVIDER FIELD. A copy-paste in a 47-row seed is invisible:
  --    both metrics simply carry the same series and look plausible.
  select count(*) into n from (
    select source_code, statement, field
      from market.metric_source_field
     group by source_code, statement, field having count(*) > 1) x;
  if n <> 0 then
    raise exception '% provider fields are claimed by more than one metric — two metrics would carry the identical series and neither would look wrong', n;
  end if;

  -- 4. THE SPELLINGS GENUINELY DIFFER, which is the fact the whole table exists for. If a future
  --    edit "tidied" them into one shared name, the mapping table would look redundant and the
  --    next person would delete it.
  select count(*) into n from market.metric_source_field a
    join market.metric_source_field b
      on b.metric_code = a.metric_code and b.source_code = 'yfinance'
   where a.source_code = 'sec' and a.field <> b.field;
  if n < 10 then
    raise exception
      'only % metrics spell differently across the two providers — measured, 36 of 40 income fields differ, so this table is not redundant and must not be collapsed to one name', n;
  end if;

  -- 4b. AND THE HEADLINE CASE SPECIFICALLY. The count above cannot see a SINGLE spelling being
  --     "tidied" into agreement, which is the realistic regression: pre-tax income is
  --     `total_pretax_income` on sec and `total_pre_tax_income` on yfinance — one character — so
  --     it looks like a typo to anyone reading the seed, and correcting it silently empties the
  --     series for whichever provider was changed.
  if (select f.field from market.metric_source_field f
       where f.metric_code = 'pretax_income' and f.source_code = 'sec')
     = (select f.field from market.metric_source_field f
         where f.metric_code = 'pretax_income' and f.source_code = 'yfinance') then
    raise exception
      'pretax_income now spells the same for both providers — measured, sec says total_pretax_income and yfinance total_pre_tax_income; making them agree means one of them is wrong and returns null for every period of that provider';
  end if;

  -- 5. MONEY CARRIES ITS CURRENCY. The column must exist and be nullable: a share count and a
  --    ratio have no currency, and defaulting money to dollars is how Alibaba's CNY revenue
  --    rendered as "$1.02T".
  select count(*) into n from pg_attribute
   where attrelid = 'market.security_metric'::regclass
     and attname = 'currency_code' and not attisdropped and not attnotnull;
  if n <> 1 then
    raise exception 'security_metric.currency_code must exist and be nullable (found % matching columns)', n;
  end if;

  -- 6. period_type IS IN THE PRIMARY KEY. One period end carries an annual figure AND a TTM
  --    figure; with period_type outside the key one silently overwrites the other on upsert.
  select count(*) into n
    from pg_index i
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = 'market.security_metric'::regclass and i.indisprimary
     and a.attname = 'period_type';
  if n <> 1 then
    raise exception
      'period_type is not part of security_metric''s primary key — an annual and a TTM figure for one period end are different facts, and one would overwrite the other with no error';
  end if;
end $$;

rollback;

\echo 'ok: a metric is a row, and so is the provider spelling for it'
