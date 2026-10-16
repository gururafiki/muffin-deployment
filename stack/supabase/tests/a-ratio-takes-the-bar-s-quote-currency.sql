-- A RATIO TAKES ITS QUOTE CURRENCY FROM THE BAR IT DIVIDES, AND A BAR WITH NO LABEL HAS NO PRICE
-- RATIO.
--
-- WHY THIS IS A TEST. `security.currency_code` holds the currency of a line a US fund holds or a
-- metrics response's reporting currency, not the currency of the line the price lane prices. Read as
-- the quote currency it produced numbers in a believable range that were wrong by the unit or the
-- exchange rate: ALG.KW at a P/E of 12,305 (fils read as dinars), Lenovo at 222.6 (HKD read as USD).
-- Each bar now carries the currency Yahoo states for its own line (muffin-ingest#104).
--
-- THE TWO RULES DISAGREE ON EVERY ROW BELOW, which is what lets this fail when the old one returns:
--   * a London line in pence whose security says GBP: the bar's GBX converts at 100 pence to the
--     pound and gives P/E 10; the security's GBP takes the pence as pounds and gives 1,000;
--   * an unlabelled bar whose security says USD: the bar gives no P/E; the security gives 10.
-- Both grains are asserted, because the daily and weekly arms each name the quote currency.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-xbrl','SEC XBRL',275) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.currency (code, name) values ('GBP','Pound sterling') on conflict (code) do nothing;
insert into market.currency (code, name) values ('GBX','Pound sterling, in pence') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('XQ','Quoteland','XQ',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000043001', 'T430 Pence',      'equity', 'XQ', 'GBP'),
  ('00000000-0000-0000-0000-000000043002', 'T430 Unlabelled', 'equity', 'XQ', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T430P', '00000000-0000-0000-0000-000000043001', 'sec-xbrl'),
  ('ticker', 'T430U', '00000000-0000-0000-0000-000000043002', 'sec-xbrl')
on conflict (kind_code, value) do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000043001','eps_diluted','ttm',date '2025-01-01', 0.5,'GBP','sec-xbrl'),
  ('00000000-0000-0000-0000-000000043002','eps_diluted','ttm',date '2025-01-01', 4,  'USD','sec-xbrl')
on conflict do nothing;

-- A pound is 100 pence, so the pence rate is a hundredth of the pound's, as the FX lane derives it.
insert into market.fx_rate (currency_code, as_of, usd_per_unit, source_code) values
  ('GBP', date '2025-01-01', 1.25,   'yfinance'),
  ('GBX', date '2025-01-01', 0.0125, 'yfinance'),
  ('USD', date '2025-01-01', 1,      'yfinance')
on conflict (currency_code, as_of) do update set usd_per_unit = excluded.usd_per_unit;

-- One bar older than the daily arm's 400 days, so only the WEEKLY arm has it, and one ten days old,
-- which both arms have. Each is alone in its week.
insert into market.price_bar (security_id, trade_date, close, source_code, currency_code) values
  ('00000000-0000-0000-0000-000000043001', date '2025-03-03',      500, 'yfinance', 'GBX'),
  ('00000000-0000-0000-0000-000000043001', current_date - 10,      500, 'yfinance', 'GBX'),
  ('00000000-0000-0000-0000-000000043002', date '2025-03-03',       40, 'yfinance', null),
  ('00000000-0000-0000-0000-000000043002', current_date - 10,       40, 'yfinance', null)
on conflict (security_id, trade_date) do nothing;

refresh materialized view market.symbol_security;

do $$
declare v numeric; q text; c boolean; n integer;
begin
  -- 1. PENCE OVER POUNDS, CONVERTED, ON BOTH GRAINS: 500 / (0.5 x 100) = 10. The security's GBP
  --    would read 500 / 0.5 = 1,000.
  for q, v, c in
    select grain || ' ' || date, pe_ratio, fx_converted from market.security_ratio_series
     where symbol = 'T430P'
  loop
    if v is distinct from 10 then
      raise exception 'the pence line''s P/E on % is %, expected 10 (500 pence / 0.50 GBP x 100). 1000 means the security''s GBP was read as the quote currency',
        q, coalesce(v::text, '<null>');
    end if;
    if c is not true then
      raise exception 'fx_converted is % on % — GBX against GBP is a conversion', c, q;
    end if;
  end loop;

  select count(*) into n from market.security_ratio_series where symbol = 'T430P';
  if n <> 3 then
    raise exception 'the pence line has % rows, expected 3: the old bar weekly, the recent bar daily and weekly', n;
  end if;
  select count(*) into n from market.security_ratio_series
   where symbol = 'T430P' and quote_currency = 'GBX';
  if n <> 3 then
    raise exception 'only % of the pence line''s 3 rows name GBX as the quote currency', n;
  end if;

  -- 2. NO LABEL, NO PRICE RATIO, ON BOTH GRAINS. The security's USD would give 40 / 4 = 10.
  select count(*) into n from market.security_ratio_series
   where symbol = 'T430U' and (pe_ratio is not null or currency_comparable);
  if n <> 0 then
    raise exception '% of the unlabelled line''s rows carry a P/E or call themselves comparable — a bar with no label must not borrow the security''s currency', n;
  end if;
  select count(*) into n from market.security_ratio_series
   where symbol = 'T430U' and grain = 'daily';
  if n <> 1 then
    raise exception 'the unlabelled line has % daily rows, expected 1: the gap is a missing ratio, not a missing bar', n;
  end if;

  raise notice '  ok  a ratio takes its quote currency from the bar, on both grains, and an unlabelled bar has no price ratio';
end $$;

rollback;

\echo 'ok: a ratio takes its quote currency from the bar'
