-- SHARE STATISTICS AND ANALYST ESTIMATES — universal, free, and cheap enough to be uninteresting.
--
-- `data-coverage.md` recorded analyst estimates as "all premium". Measured 2026-08-20 against the
-- deployed openbb-api across a US mega-cap, a German, a Japanese, a Korean and a Brazilian ADR:
-- `equity/estimates/consensus?provider=yfinance` answers for ALL SIX, and
-- `equity/ownership/share_statistics` likewise. Both BATCH — six symbols in 0.33s and 0.48s — so
-- the whole 12,350-security universe is a couple of hundred calls, not a rate-limit problem.
--
-- ── SHORT INTEREST IS HERE, AND IT IS NOT US-ONLY ───────────────────────────────────────────
--
-- The same doc has short interest as "premium or exchange-licensed", and FINRA's route really is
-- US-only (120 rows for a US listing, 0 for a local foreign one — FINRA is a US SRO, so that is
-- the dataset's shape rather than a gap). But `share_statistics` carries `short_interest`,
-- `short_percent_of_float` and `days_to_cover` for every market tried. Two sources, different
-- coverage; this is the one that serves the universe.
--
-- ── UNITS: THESE ARE FRACTIONS, AND THAT HAS COST REAL MONEY HERE ───────────────────────────
--
-- `insider_ownership: 0.01648` is 1.648%, `short_percent_of_float: 0.0097` is 0.97%, and
-- `institution_ownership: 0.66482` is 66.482%. They are stored EXACTLY as the provider sends them
-- — a fraction — and the column comments say so, because this codebase has already rendered NVIDIA
-- at a 46% dividend yield by applying one shared `pct()` to a response whose fields disagreed
-- about their own units. Converting on write would hide the provider's convention; converting in
-- every reader is how the two screens disagree. The rule is: store the fact, name the unit.
--
-- `recommendation_mean` is NOT a fraction and not a percent — it is yfinance's 1..5 scale where
-- LOWER is more bullish (2.11 for AAPL alongside `recommendation: "buy"`). A reader that treats it
-- as a score to maximise inverts every recommendation on the page.

create table if not exists market.security_share_stats (
  security_id            uuid not null references market.security (security_id) on delete cascade,
  -- The PROVIDER's own date, not the fetch date: these track the short-interest reporting cycle
  -- (AAPL's row is dated 2026-07-31 with a `short_interest_prev_date` of 2026-06-30), so keying on
  -- when we happened to ask would mint a new row per run and call it history.
  as_of                  date not null,
  float_shares           numeric,
  outstanding_shares     numeric,
  short_interest         numeric,
  short_percent_of_float numeric,
  days_to_cover          numeric,
  insider_ownership      numeric,
  institution_ownership  numeric,
  institutions_count     integer,
  source_code            text not null references market.data_source (code),
  fetched_at             timestamptz not null default now(),
  primary key (security_id, as_of)
);

comment on table market.security_share_stats is
  'Float, shares outstanding, short interest and ownership, keyed on the PROVIDER''s date so a re-fetch updates a period rather than inventing one. Universal and free — measured across US, German, Japanese, Korean and Brazilian listings.';
comment on column market.security_share_stats.short_percent_of_float is
  'A FRACTION as the provider sends it: 0.0097 is 0.97%. Not converted on write — storing the fact and naming the unit is what stops one reader multiplying by 100 and another not.';
comment on column market.security_share_stats.insider_ownership is
  'A FRACTION: 0.01648 is 1.648%. Same convention as short_percent_of_float and institution_ownership.';
comment on column market.security_share_stats.institution_ownership is
  'A FRACTION: 0.66482 is 66.482%.';

create table if not exists market.security_estimate (
  security_id         uuid not null references market.security (security_id) on delete cascade,
  -- The FETCH date. Unlike share statistics the provider supplies no date of its own, and a
  -- consensus is a running figure rather than a reported period — so this is honestly "what the
  -- consensus was when we asked", one row per day at most.
  as_of               date not null,
  target_high         numeric,
  target_low          numeric,
  target_consensus    numeric,
  target_median       numeric,
  recommendation      text,
  -- yfinance's 1..5 scale, where LOWER IS MORE BULLISH (2.11 for AAPL, alongside "buy"). A reader
  -- that treats it as a score to maximise inverts every recommendation on the page.
  recommendation_mean numeric,
  number_of_analysts  integer,
  -- A PRICE TARGET IS MONEY AND MUST CARRY ITS CURRENCY. The response supplies one; without it a
  -- Korean target of 190,200 would render as "$190,200" — the mistake that made Alibaba's CNY
  -- revenue read as $1.02T.
  currency_code       text references market.currency (code),
  source_code         text not null references market.data_source (code),
  fetched_at          timestamptz not null default now(),
  primary key (security_id, as_of)
);

comment on table market.security_estimate is
  'Analyst consensus and price targets. `data-coverage.md` called these "all premium"; measured 2026-08-20, yfinance answers for every market tried. Keyed on the FETCH date because a consensus is a running figure with no reported period of its own.';
comment on column market.security_estimate.recommendation_mean is
  'yfinance''s 1..5 scale where LOWER IS MORE BULLISH — 2.11 for AAPL beside recommendation "buy". Treating it as a score to maximise inverts every recommendation shown.';

-- ── negative caches ──────────────────────────────────────────────────────────────────────────
-- SYMBOL-KEYED, both: fetched with the priced symbol, so a corrected symbol is a new question and
-- `clear_symbol_caches` must clear them.
alter table market.security add column if not exists share_stats_missing_at timestamptz;
alter table market.security add column if not exists estimates_missing_at   timestamptz;

create or replace function market.clear_symbol_caches(p_security_id uuid)
returns void language sql as $$
  update market.security set
    industry_missing_at         = null,
    profile_missing_at          = null,
    performance_missing_at      = null,
    fundamentals_missing_at     = null,
    statements_missing_at       = null,
    prices_missing_at           = null,
    provider_country_missing_at = null,
    corporate_actions_missing_at = null,
    dividends_missing_at        = null,
    price_history_missing_at    = null,
    share_stats_missing_at      = null,
    estimates_missing_at        = null
  where security_id = p_security_id;
$$;

drop view if exists market.symbol_cache_classification;
create view market.symbol_cache_classification as
select * from (values
  ('industry_missing_at',          true,  'yfinance profile fetched by symbol'),
  ('profile_missing_at',           true,  'yfinance profile fetched by symbol'),
  ('performance_missing_at',       true,  'historical bars fetched by symbol'),
  ('fundamentals_missing_at',      true,  'metrics fetched by symbol'),
  ('statements_missing_at',        true,  'statements fetched by symbol'),
  ('prices_missing_at',            true,  'daily bars fetched by symbol'),
  ('provider_country_missing_at',  true,  'yfinance profile fetched by symbol'),
  ('corporate_actions_missing_at', true,  'Tiingo EOD fetched by the US ticker'),
  ('dividends_missing_at',         true,  'yfinance dividends fetched by the PRICED symbol'),
  ('price_history_missing_at',     true,  'weekly history fetched by the PRICED symbol'),
  ('share_stats_missing_at',       true,  'share statistics fetched by the PRICED symbol'),
  ('estimates_missing_at',         true,  'analyst consensus fetched by the PRICED symbol'),
  ('figi_missing_at',              false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',      false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop'),
  ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'),
  ('xbrl_missing_at',              false, 'company facts are asked for by CIK; a new provider symbol says nothing about the filer')
) as t(column_name, symbol_keyed, reason);

grant select on market.symbol_cache_classification to service_role;

-- ── the backlog ──────────────────────────────────────────────────────────────────────────────
-- ONE BACKLOG FOR BOTH, because one batch of symbols answers both endpoints and splitting them
-- would double the requests to fetch two halves of the same row.
--
-- REFRESHED, not one-off: a consensus moves and short interest is reported twice a month. Keyed on
-- when we last asked rather than on whether rows exist, so a security the provider covers for
-- neither is not re-asked for ever.
drop view if exists market.pending_share_stats;

create view market.pending_share_stats as
select
  s.security_id,
  sym.symbol,
  coalesce(ps.symbol, sym.symbol) as fetch_symbol,
  coalesce(max(h.weight), 0)      as best_weight
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_share_stats st
  on st.security_id = s.security_id and st.fetched_at > now() - interval '7 days'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and st.security_id is null
  and (s.share_stats_missing_at is null
       or s.share_stats_missing_at < now() - interval '30 days')
group by s.security_id, sym.symbol, coalesce(ps.symbol, sym.symbol)
order by best_weight desc, s.security_id;

comment on view market.pending_share_stats is
  'Equities whose share statistics have not been read in 7 days, heaviest fund holding first. Drives BOTH share statistics and analyst estimates — one batch of symbols answers both endpoints, and splitting them would double the requests for two halves of one row.';

grant select on market.pending_share_stats to service_role;

-- ── grants + RLS ─────────────────────────────────────────────────────────────────────────────
grant select on market.security_share_stats, market.security_estimate
  to anon, authenticated, service_role;
grant insert, update, delete on market.security_share_stats, market.security_estimate
  to service_role;

alter table market.security_share_stats enable row level security;
alter table market.security_estimate     enable row level security;
do $$ begin
  create policy share_stats_public_read on market.security_share_stats for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy estimate_public_read on market.security_estimate for select using (true);
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
