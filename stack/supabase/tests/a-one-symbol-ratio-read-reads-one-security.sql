-- A ONE-SYMBOL RATIO READ READS ONE SECURITY'S METRICS, NOT EVERY SECURITY'S.
--
-- WHY THIS IS A TEST. The stock page reads `security_ratio_series` one symbol at a time. When the
-- view computed its metric spans with `lead()` over all of `security_metric`, the symbol filter
-- could not pass the window, so every P/E chart read 1.57 M metric rows to draw one company's 271
-- bars. Production timed out for users (anon's 3 s ceiling) from 2026-10-16, and nothing in CI could
-- see it: on a fixture this size every plan finishes in milliseconds, so a timing proves nothing.
-- The number of metric rows the read touches does not depend on the table's size, so it is asserted
-- instead (migration 20261017140000).
--
-- WHAT MAKES THE TWO VIEWS DISAGREE. 500 other securities hold 2,000 ratio-metric rows and the read
-- asks about one security holding two. The target's id sorts LAST, so a plan reading the spans in
-- security order cannot stop early and look narrow: a view whose window spans every security reads
-- all 2,002 rows, and one whose window is restricted to the symbol reads two.
--
-- Seq scans are off because on a fixture this small one can be the cheapest plan, and it reads every
-- row even when the symbol filter has reached below the window. The test is about where the filter
-- can go, not about the planner's cost model on 2,000 rows.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-xbrl','SEC XBRL',275) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('XQ','Quoteland','XQ',false)
  on conflict (iso2) do nothing;

-- The target, with the largest id in the fixture.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('ffffffff-ffff-ffff-ffff-fffffff43101', 'T431 Target', 'equity', 'XQ', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T431T', 'ffffffff-ffff-ffff-ffff-fffffff43101', 'sec-xbrl')
on conflict (kind_code, value) do nothing;

-- 500 others, each with a ticker and four ratio-metric rows: a flow (TTM EPS) and a stock (quarterly
-- equity), two periods each.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code)
select ('00000000-0000-0000-0000-' || lpad(to_hex(431000 + g), 12, '0'))::uuid,
       'T431 Other ' || g, 'equity', 'XQ', 'USD'
  from generate_series(1, 500) g
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code)
select 'ticker', 'T431O' || g, ('00000000-0000-0000-0000-' || lpad(to_hex(431000 + g), 12, '0'))::uuid,
       'sec-xbrl'
  from generate_series(1, 500) g
on conflict (kind_code, value) do nothing;
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code)
select ('00000000-0000-0000-0000-' || lpad(to_hex(431000 + g), 12, '0'))::uuid,
       mc, pt, d, 10, 'USD', 'sec-xbrl'
  from generate_series(1, 500) g,
       (values ('eps_diluted', 'ttm'), ('total_equity', 'quarter')) k (mc, pt),
       (values (date '2025-01-01'), (date '2025-07-01')) p (d)
on conflict do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('ffffffff-ffff-ffff-ffff-fffffff43101','eps_diluted','ttm',date '2025-01-01', 4,'USD','sec-xbrl'),
  ('ffffffff-ffff-ffff-ffff-fffffff43101','eps_diluted','ttm',date '2025-07-01', 5,'USD','sec-xbrl')
on conflict do nothing;

insert into market.fx_rate (currency_code, as_of, usd_per_unit, source_code) values
  ('USD', date '2025-01-01', 1, 'yfinance')
on conflict (currency_code, as_of) do update set usd_per_unit = excluded.usd_per_unit;

-- One bar only the weekly arm has, and one both arms have.
insert into market.price_bar (security_id, trade_date, close, source_code, currency_code) values
  ('ffffffff-ffff-ffff-ffff-fffffff43101', date '2025-03-03',  40, 'yfinance', 'USD'),
  ('ffffffff-ffff-ffff-ffff-fffffff43101', current_date - 10,  60, 'yfinance', 'USD')
on conflict (security_id, trade_date) do nothing;

refresh materialized view market.symbol_security;
analyze market.security, market.security_identifier, market.security_metric, market.symbol_security,
        market.price_bar, market.fx_rate;

set local max_parallel_workers_per_gather = 0;
set local enable_seqscan = off;

do $$
declare g text; p jsonb; touched numeric; n integer;
begin
  -- 0. THE READ ANSWERS, so the measurement below is of a read that did its work: 40 / 4 and 60 / 5.
  select count(*) into n from market.security_ratio_series
   where symbol = 'T431T' and pe_ratio is not null;
  if n <> 3 then
    raise exception 'the target has % rows with a P/E, expected 3 (the old bar weekly, the recent bar daily and weekly) — the fixture no longer exercises the read', n;
  end if;

  foreach g in array array['daily', 'weekly'] loop
    execute format(
      'explain (analyze, format json) select * from market.security_ratio_series where symbol = %L and grain = %L',
      'T431T', g) into p;
    select coalesce(sum((node->>'Actual Rows')::numeric * (node->>'Actual Loops')::numeric), 0)
      into touched
      from jsonb_path_query(p, 'strict $.**') node
     where jsonb_typeof(node) = 'object' and node->>'Relation Name' = 'security_metric';

    -- 1. THE MEASUREMENT SEES THE TARGET'S OWN TWO ROWS. Zero would mean the plan no longer names
    --    the table this way, and every later read would pass whatever the view did.
    if touched < 2 then
      raise exception 'the % read touched % metric rows, fewer than the target''s own 2 — the plan walk no longer finds the scans of security_metric', g, touched;
    end if;

    -- 2. AND ONLY THEM. 2,002 means the window spans every security again.
    if touched > 20 then
      raise exception 'a one-symbol % read touched % metric rows, where the symbol holds 2 of 2,002. The symbol filter is not reaching below the spans window: in production this read takes seconds and anon times out', g, touched;
    end if;
    raise notice '  ok  a one-symbol % ratio read touches % metric rows of 2,002', g, touched;
  end loop;
end $$;

rollback;

\echo 'ok: a one-symbol ratio read reads one security'
