-- A METRIC MUST COME OUT RIGHT WHICHEVER PROVIDER WROTE THE FILING.
--
-- `security_statement.data` holds two incompatible vocabularies (sec and yfinance share 4 of 40
-- income-statement field names, measured). `derive_security_metrics` therefore never names a
-- provider field — it joins `metric_source_field` on the statement's own `source_code`. This file
-- drives BOTH providers through it and asserts the same metric comes out.
--
-- The fixture is built so the two paths CANNOT be confused for one another: the same company has
-- one SEC period and one yfinance period, with different field names AND a different capex sign.
-- If the derivation hardcoded either provider's spelling, exactly one of the two would vanish —
-- silently, because a missing field is simply no row and the chart is merely shorter.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('sec','SEC',250) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZM','Testland','ZM',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009001', 'T90 Both Providers', 'equity', 'ZM')
on conflict (security_id) do nothing;

-- ── the SEC period: SEC spellings, capex POSITIVE (a purchase), currency present ─────────────
insert into market.security_statement (security_id, statement, period_ending, period_type, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009001', 'income', date '2025-12-31', 'FY', 'USD',
   '{"total_revenue": 1000, "total_pretax_income": 300, "net_income": 200}'::jsonb, 'sec'),
  ('00000000-0000-0000-0000-000000009001', 'cash',   date '2025-12-31', 'FY', 'USD',
   '{"net_cash_from_operating_activities": 500, "purchase_of_plant_property_and_equipment": 120}'::jsonb, 'sec'),
  ('00000000-0000-0000-0000-000000009001', 'balance',date '2025-12-31', 'FY', 'USD',
   '{"long_term_debt": 700, "short_term_debt": 50}'::jsonb, 'sec')
on conflict do nothing;

-- ── the yfinance period: yfinance spellings, capex NEGATIVE (an outflow), NO currency ────────
insert into market.security_statement (security_id, statement, period_ending, period_type, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009001', 'income', date '2024-12-31', 'annual', null,
   '{"total_revenue": 900, "total_pre_tax_income": 250, "net_income": 180}'::jsonb, 'yfinance'),
  ('00000000-0000-0000-0000-000000009001', 'cash',   date '2024-12-31', 'annual', null,
   '{"operating_cash_flow": 400, "capital_expenditure": -100, "free_cash_flow": 275}'::jsonb, 'yfinance')
on conflict do nothing;

-- ── a THIRD period that actually exercises the sign ──────────────────────────────────────────
-- yfinance spellings, capex NEGATIVE, and deliberately NO reported free_cash_flow — so the
-- derivation must compute it from a negative capex. Without this period the `abs()` is untested:
-- the SEC period's capex is positive (so abs() changes nothing) and the yfinance period above
-- REPORTS free cash flow (so the derivation skips it). Both existing rows agree under either rule,
-- and a mutation deleting `abs()` passed clean until this was added.
insert into market.security_statement (security_id, statement, period_ending, period_type, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009001', 'cash',   date '2023-12-31', 'annual', null,
   '{"operating_cash_flow": 400, "capital_expenditure": -100}'::jsonb, 'yfinance')
on conflict do nothing;

select market.derive_security_metrics(null);

do $$
declare v numeric; c text; sc text; n integer;
begin
  -- 1. THE SEC PERIOD MAPPED. Its spelling is `total_pretax_income`.
  select value into v from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='pretax_income' and as_of=date '2025-12-31';
  if v is distinct from 300 then
    raise exception 'the SEC period did not map pretax_income (got %) — sec spells it total_pretax_income and yfinance total_pre_tax_income, one character apart', coalesce(v::text,'<null>');
  end if;

  -- 2. THE YFINANCE PERIOD MAPPED TOO, from a DIFFERENT field name into the SAME metric.
  select value into v from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='pretax_income' and as_of=date '2024-12-31';
  if v is distinct from 250 then
    raise exception 'the yfinance period did not map pretax_income (got %) — hardcoding either provider''s spelling makes exactly one of the two vanish, silently', coalesce(v::text,'<null>');
  end if;

  -- 3. period_type IS NORMALISED. SEC says 'FY', yfinance says 'annual'; a chart that groups by
  --    this would otherwise split one company's history into two series.
  select count(*) into n from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001' and period_type <> 'annual';
  if n <> 0 then
    raise exception '% metric rows carry a period_type other than annual — SEC''s FY and yfinance''s annual are the same thing and must not split one history into two series', n;
  end if;

  -- 4. CAPEX SIGN. yfinance sends it NEGATIVE and SEC POSITIVE, so free cash flow must use abs():
  --    subtracting a negative ADDS the capex and reports FCF ABOVE operating cash flow.
  select value, source_code into v, sc from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='free_cash_flow' and as_of=date '2025-12-31';
  if v is distinct from 380 then
    raise exception 'derived free cash flow for the SEC period is % (expected 500 - 120 = 380) — the capex sign differs by provider and an unsigned subtraction reports FCF above operating cash flow', coalesce(v::text,'<null>');
  end if;
  if sc is distinct from 'derived' then
    raise exception 'a computed free cash flow claims source %, so nothing can tell it from a reported one — yfinance REPORTS this metric and SEC does not, which is why the row must say which it is', coalesce(sc,'<null>');
  end if;

  -- 4b. THE NEGATIVE-CAPEX PATH, which is the one `abs()` exists for. 400 - abs(-100) = 300;
  --     without abs() it is 400 - (-100) = 500, i.e. free cash flow ABOVE operating cash flow,
  --     which is impossible and looks merely optimistic.
  select value into v from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='free_cash_flow' and as_of=date '2023-12-31';
  if v is distinct from 300 then
    raise exception 'derived free cash flow from a NEGATIVE capex is % (expected 400 - abs(-100) = 300) — subtracting a negative adds the capex and reports free cash flow above operating cash flow', coalesce(v::text,'<null>');
  end if;

  -- 5. A PROVIDER'S OWN FIGURE IS NOT OVERWRITTEN. yfinance reports free_cash_flow = 275, which is
  --    NOT 400 - 100; the provider's number is authoritative and the derivation must leave it.
  select value, source_code into v, sc from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='free_cash_flow' and as_of=date '2024-12-31';
  if v is distinct from 275 or sc is distinct from 'yfinance' then
    raise exception 'the yfinance-reported free cash flow became % from % — a reported figure must survive the derivation, or re-running it silently replaces the provider''s answer with arithmetic', coalesce(v::text,'<null>'), coalesce(sc,'<null>');
  end if;

  -- 6. TOTAL DEBT IS SUMMED, because neither provider reports it.
  select value into v from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='total_debt' and as_of=date '2025-12-31';
  if v is distinct from 750 then
    raise exception 'total_debt is % (expected 700 + 50) — SEC reports the two halves separately and no total', coalesce(v::text,'<null>');
  end if;

  -- 7. CURRENCY IS THE FILING'S, AND NULL WHERE THE PROVIDER DID NOT SAY. Substituting the QUOTE
  --    currency is how Alibaba's CNY revenue rendered as "$1.02T".
  select currency_code into c from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='revenue' and as_of=date '2025-12-31';
  if c is distinct from 'USD' then
    raise exception 'the SEC period lost its reporting currency (got %)', coalesce(c,'<null>');
  end if;
  select currency_code into c from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='revenue' and as_of=date '2024-12-31';
  if c is not null then
    raise exception 'the yfinance period invented a currency (%) — yfinance does not report one, and an unlabelled figure is correct where a guessed one is not', c;
  end if;

  -- 8. IDEMPOTENT. It re-derives everything on every run, so a second pass must not change a value
  --    or flip a source — that is what makes "re-running it is free" true rather than hopeful.
  perform market.derive_security_metrics(null);
  select value, source_code into v, sc from market.security_metric
   where security_id='00000000-0000-0000-0000-000000009001'
     and metric_code='free_cash_flow' and as_of=date '2024-12-31';
  if v is distinct from 275 or sc is distinct from 'yfinance' then
    raise exception 'a second derivation changed the yfinance free cash flow to % from % — the run is not idempotent', coalesce(v::text,'<null>'), coalesce(sc,'<null>');
  end if;
end $$;

rollback;

\echo 'ok: a metric derives correctly from whichever provider wrote the filing'
