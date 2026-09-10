-- AN ANALYST ACTION IS AN EVENT; THE CONSENSUS WE ALREADY HAVE IS A LEVEL.
--
-- `market.security_estimate` has held consensus price targets since migration 110 — `target_high`,
-- `target_low`, `target_consensus`, `target_median`, `recommendation`, `number_of_analysts`, from
-- `equity/estimates/consensus` (yfinance) — and it is GLOBAL. Measured 2026-09-07: 26,676 rows over
-- **9,009 securities**, US 2,652, CN 1,244, JP 927, IN 567, KR 340, HK 333, AU 289, GB 254. So this
-- table is NOT filling a gap in price targets, and anyone who says otherwise has not looked.
--
-- What it adds is a different GRAIN: the individual analyst actions behind that level, which a
-- daily aggregate cannot express — who moved, when, and in which direction.
--
--   2026-09-01  Rosenblatt               Reiterated  300 -> 303    Neutral
--   2026-08-17  Rothschild & Co Redburn  Upgrade            400    Neutral -> Buy
--   2026-08-10  Jefferies                Downgrade          263.66 Hold -> Underperform
--
-- ── THE FIELD NAMES ARE THE OPPOSITE OF WHAT THEY SUGGEST ─────────────────────────────────────
-- Measured over 160 rows across eight symbols: both fields present 90 times, **`adj_price_target`
-- alone 55 times, `price_target` alone ZERO times**, neither 15 — and where both appear they
-- **always differ** (48 of 48), which rules out `adj` meaning split-adjusted. `Initiated` rows carry
-- only `adj_price_target`, which is what settles it: `adj_price_target` is the NEW target and
-- `price_target` is the PREVIOUS one.
--
-- Storing `price_target` as "the price target" would therefore persist the SUPERSEDED number and be
-- null 40% of the time, while looking entirely reasonable — this schema's signature failure. The
-- columns are named `target_from` / `target_to` so the mistake cannot be made silently, and
-- `logic-check.ts` pins which provider field feeds which, the way it pins `surprise_percent`'s
-- `* 100`.
--
-- ── IT IS A US-LISTINGS-ONLY FEATURE AND NOTHING IN ITS NAME SAYS SO ──────────────────────────
-- Probed with symbols expected to FAIL rather than mega-caps. `SAP.DE`, `005930.KS`, `BHP.AX`,
-- `7203.T`, `SHEL.L`, `NESN.SW` all return **400** — finviz has no quote page for them — and so do
-- the OTC foreign-ordinary lines OpenFIGI's US lookup hands back: `ASMLF`, `BUDFF`, `TSMWF`,
-- `SAPGF`. Every genuine US line works, including ADRs (`TSM`, `NVO`) and mid-caps (`EXC` $46bn,
-- `ESS` $19bn).
--
-- So the scope is A US LISTING IN `market.listing`, never the shape of the symbol and never the
-- company's country — migration 123's rule. Verified that this filter already does the work:
-- ASMLF, BUDFF, SAPGF and TSMWF all have `has_us_listing = false` while AAPL, MSFT and the TSM
-- **ADR** have true. That is the difference between this backlog and `pending_eps_history`, where
-- 621 of 1,015 rows were OTC lines burning a 25-a-day quota.
--
-- Addressable population **3,277 US-listed equities**. The endpoint BATCHES and has no quota, so at
-- 40 symbols a call the whole population is ~82 requests and there is no reason to bound it by fund
-- weight the way the quota-bound resources are.

\set ON_ERROR_STOP on

create table if not exists market.security_price_target (
  security_id     uuid not null references market.security (security_id) on delete cascade,
  -- The PROVIDER's date, never the fetch date. A fetch-dated row would mint one per run and call it
  -- history, which is why `security_share_stats` keys on the provider's `date` too.
  published_date  date not null,
  analyst_company text not null,
  -- FROM and TO, not `price_target`/`adj_price_target` — see the header. `target_from` is null on an
  -- Initiated or Resumed action, where there is no previous target, and that is a fact rather than
  -- a gap.
  target_from     numeric,
  target_to       numeric,
  -- Closed vocabulary, measured: Reiterated 82, Downgrade 28, Upgrade 24, Initiated 22, Resumed 4.
  status          text,
  -- Stored RAW. It is a transition (`Hold -> Underperform`) 52 times in 160 and a bare rating 108
  -- times, so splitting it into from/to columns would leave both null two thirds of the time for no
  -- gain over the string a reader can display directly.
  rating_change   text,
  source_code     text not null references market.data_source (code),
  fetched_at      timestamptz not null default now(),
  -- (date, firm) is unique within a symbol's 20 rows — measured, 20 distinct and 0 duplicates — so
  -- re-fetching the rolling window is idempotent instead of duplicating it every run.
  primary key (security_id, published_date, analyst_company)
);

comment on table market.security_price_target is
  'Individual analyst actions from `equity/estimates/price_target?provider=finviz` — who re-rated, when, and in which direction. Distinct in GRAIN from market.security_estimate, which holds the daily consensus LEVEL and covers the universe globally; this is the US-listed event stream behind it. `target_to` is the provider''s `adj_price_target` (the NEW target) and `target_from` its `price_target` (the PREVIOUS one), which is the opposite of what those names suggest.';

create index if not exists security_price_target_recent_idx
  on market.security_price_target (security_id, published_date desc);

grant select on market.security_price_target to anon, authenticated, service_role;
grant insert, update, delete on market.security_price_target to service_role;

alter table market.security_price_target enable row level security;
drop policy if exists security_price_target_read on market.security_price_target;
create policy security_price_target_read on market.security_price_target for select using (true);

-- A CURSOR, NOT A NEGATIVE CACHE, and deliberately not named `%_missing_at`. Analysts re-rate
-- constantly, so "no action this week" is never a permanent fact about a company — the same
-- reasoning as `insider_fetched_at` in migration 116.
alter table market.security add column if not exists price_targets_fetched_at timestamptz;

comment on column market.security.price_targets_fetched_at is
  'When analyst price-target actions were last fetched. A CURSOR, not a negative cache: an absence of ratings this week says nothing permanent about the company, so this is deliberately not a `%_missing_at` column.';

drop view if exists market.pending_price_targets;
create view market.pending_price_targets as
select
  s.security_id,
  t.value as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  -- THE VENUE, NOT THE SYMBOL'S SHAPE. This is what excludes both the suffixed foreign lines and
  -- the OTC foreign ordinaries (ASMLF, BUDFF, TSMWF, SAPGF), all of which finviz answers with 400.
  and exists (
    select 1 from market.listing l
     where l.security_id = s.security_id and l.exch_code = 'US')
  and (s.price_targets_fetched_at is null
       or s.price_targets_fetched_at < now() - interval '7 days')
group by s.security_id, t.value
order by best_weight desc;

comment on view market.pending_price_targets is
  'US-listed equities whose analyst actions have not been read in the last week, ordered by fund weight. A rolling cursor rather than a drain: analysts keep re-rating, so this never empties and is not meant to. Scoped on a US LISTING because finviz 400s on every suffixed symbol and on every OTC foreign-ordinary line.';

grant select on market.pending_price_targets to service_role;

-- A RESOURCE NOTHING SCHEDULES CANNOT FAIL. `exchange-listings` was deployed, reachable and absent
-- from the cron for weeks, which is why the scheduling guard exists and why this row is here rather
-- than in a follow-up.
insert into market.cron_resource (position, resource) values
  (460, 'security-price-targets')
on conflict (position) do update set resource = excluded.resource;

notify pgrst, 'reload schema';
