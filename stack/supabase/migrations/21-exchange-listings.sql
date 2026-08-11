-- Every listed common stock per exchange — IDEMPOTENT.
--
-- The universe is currently exactly what the tracked funds hold: a company no ETF owns does not
-- exist to the app, so it cannot be searched for or analysed. OpenFIGI's `/v3/filter` enumerates a
-- whole venue (measured 2026-08-11: London 4,346, Tokyo 3,948, NSE 3,222, KOSPI 2,803, Xetra 1,206,
-- Warsaw 805 common stocks), which turns that from a hard boundary into a lookup.
--
-- THE JOIN KEY IS FIGI, NOT ISIN. The filter endpoint does not return ISINs — only tickers, names
-- and FIGIs — so a listing is tied to a security through `security_identifier(kind='figi')`, which
-- `/v3/mapping` already returns for every symbol we resolve. That is why `security-local-symbols`
-- now stores it: without the FIGI, this table could never be joined to anything.

create table if not exists market.exchange_listing (
  -- The FIGI of the LISTING (venue-specific), which is what the directory is keyed on.
  figi            text primary key,
  -- The composite FIGI groups a company's listings across venues within a country. Two lines of
  -- the same company share it, which is what makes "is this the same security" answerable.
  composite_figi  text,
  exch_code       text not null,
  ticker          text not null,
  name            text,
  security_type   text,
  -- The country whose venue this is, so a listing can be offered on the right country page.
  country_iso2    text references market.countries (iso2),
  -- yfinance-addressable form, e.g. `005930.KS`, built from the exchange's suffix.
  provider_symbol text,
  first_seen_at   timestamptz not null default now(),
  last_seen_at    timestamptz not null default now()
);
create index if not exists exchange_listing_exch_idx      on market.exchange_listing (exch_code);
create index if not exists exchange_listing_composite_idx on market.exchange_listing (composite_figi);
create index if not exists exchange_listing_ticker_idx    on market.exchange_listing (ticker);
create index if not exists exchange_listing_country_idx   on market.exchange_listing (country_iso2);

-- Which venues to pull, and where each got to. A cursor, because a venue is thousands of rows at
-- 100 per request and will not fit one worker — the same slice-per-run shape as every other
-- backlog here.
create table if not exists market.exchange_cursor (
  exch_code    text primary key,
  country_iso2 text references market.countries (iso2),
  suffix       text,
  enabled      boolean not null default true,
  next_cursor  text,
  last_run_at  timestamptz,
  listings     integer not null default 0
);

-- Seeded from the venues the app already addresses, so this covers exactly the countries it can
-- price. Adding one is a row, like every other control surface here.
insert into market.exchange_cursor (exch_code, country_iso2, suffix) values
  ('US','US',''),    ('KS','KR','.KS'), ('KQ','KR','.KQ'), ('JT','JP','.T'),
  ('GY','DE','.DE'), ('LN','GB','.L'),  ('FP','FR','.PA'), ('SW','CH','.SW'),
  ('NA','NL','.AS'), ('IM','IT','.MI'), ('SM','ES','.MC'), ('SS','SE','.ST'),
  ('NO','NO','.OL'), ('DC','DK','.CO'), ('FH','FI','.HE'), ('BB','BE','.BR'),
  ('AV','AT','.VI'), ('PL','PT','.LS'), ('PW','PL','.WA'), ('GA','GR','.AT'),
  ('TI','TR','.IS'), ('IT','IL','.TA'), ('SJ','ZA','.JO'), ('AB','SA','.SR'),
  ('HK','HK','.HK'), ('TT','TW','.TW'), ('IS','IN','.NS'), ('SP','SG','.SI'),
  ('TB','TH','.BK'), ('IJ','ID','.JK'), ('MK','MY','.KL'), ('PM','PH','.PS'),
  ('AT','AU','.AX'), ('NZ','NZ','.NZ'), ('CT','CA','.TO'), ('BZ','BR','.SA'),
  ('MM','MX','.MX'), ('CI','CL','.SN')
on conflict (exch_code) do nothing;

alter table market.exchange_listing enable row level security;
alter table market.exchange_cursor  enable row level security;
do $$ begin
  create policy exchange_listing_public_read on market.exchange_listing for select to public using (true);
exception when duplicate_object then null; end $$;
grant select on market.exchange_listing to anon, authenticated, service_role;
grant select, insert, update, delete on market.exchange_listing to service_role;
-- The cursor is operational, not reference data: RLS on with no policy denies everyone but
-- service_role, the same treatment ingest_log gets.
grant select, insert, update, delete on market.exchange_cursor to service_role;

notify pgrst, 'reload schema';
