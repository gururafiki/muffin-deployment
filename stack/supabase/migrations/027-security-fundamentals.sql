-- Fundamentals for the securities someone actually opens — IDEMPOTENT.
--
-- Source: KEYLESS yfinance, via the OpenBB already deployed.
--
-- I first concluded no provider could serve these, having probed only the ones we hold keys for:
-- FMP free gates PER SYMBOL (402 on BHP/SAP/NEE), Tiingo free is "limited to the DOW 30", and
-- Alpha Vantage covers US listings only at 25 calls a day. All true, and all beside the point —
-- `equity/fundamental/metrics?provider=yfinance` answers for every one of them, INCLUDING the
-- non-US local listings (`005930.KS`, `7203.T`, `KGH.WA`) that Alpha Vantage returns empty for.
-- 30-35 fields each, no key, no daily cap.
--
-- So this is not limited to what someone opens; it can be a backlog like every other enrichment.
--
-- `raw` is kept because the provider returns ~35 fields and pinning a column per metric would mean
-- a migration every time one more turns out to matter.

create table if not exists market.security_fundamentals (
  security_id     uuid primary key references market.security (security_id) on delete cascade,
  source_code     text not null references market.data_source (code),
  as_of           timestamptz not null default now(),
  pe_ratio          numeric,
  forward_pe        numeric,
  peg_ratio         numeric,
  price_to_book     numeric,
  profit_margin     numeric,
  gross_margin      numeric,
  operating_margin  numeric,
  return_on_equity  numeric,
  revenue_growth    numeric,
  debt_to_equity    numeric,
  dividend_yield    numeric,
  beta              numeric,
  enterprise_value  numeric,
  raw               jsonb
);



alter table market.security_fundamentals enable row level security;
do $$ begin
  create policy security_fundamentals_public_read
    on market.security_fundamentals for select to public using (true);
exception when duplicate_object then null; end $$;
grant select on market.security_fundamentals to anon, authenticated, service_role;
grant select, insert, update, delete on market.security_fundamentals to service_role;

notify pgrst, 'reload schema';
