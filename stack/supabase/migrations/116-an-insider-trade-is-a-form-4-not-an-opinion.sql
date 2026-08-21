-- WHO INSIDE THE COMPANY IS BUYING, AND WHO IS SELLING.
--
-- `equity/ownership/insider_trading?provider=sec` returns Form 4 filings: owner, title, transaction
-- date, type, share count, price and resulting holding. Measured 2026-08-21 — AAPL returns 11 rows
-- with `owner_name`, `owner_title`, `acquisition_or_disposition`, `securities_transacted`,
-- `securities_owned` and `transaction_price`.
--
-- `docs/data-coverage.md` used to file this under "needs a new source, but a free one". It needs no
-- new source at all — the openbb-api this stack already runs serves it. That was corrected; this is
-- the resource.
--
-- ── WHY THIS ONE AND NOT `management` ───────────────────────────────────────────────────────────
--
-- Neither endpoint BATCHES (measured: two symbols return zero rows), so both cost one call per
-- security. The difference is WHOSE budget. `management` is yfinance — the provider every other
-- backlog here is already queued behind, where 12,350 equities at one call each is fifty days of
-- the shared limit. Insider trading is SEC, which documents 10 requests a second and answers in
-- ~0.17s, and is scoped to the 3,516 securities that HAVE a CIK. Same shape, an order of magnitude
-- cheaper, on a provider nothing else is competing for.
--
-- ── AND IT IS A ROLLING FEED, NOT A ONCE-ONLY BACKLOG ───────────────────────────────────────────
--
-- Insiders keep trading. A security is re-asked after 7 days rather than marked done for ever, so
-- `insider_fetched_at` is a CURSOR, not a negative cache — a company with no filings this week will
-- have some next quarter, and marking it permanently absent would be wrong about the future rather
-- than about the data.

insert into market.data_source (code, name, priority) values ('sec-form4', 'SEC Form 4', 240)
on conflict (code) do nothing;

create table if not exists market.insider_trade (
  -- A DETERMINISTIC HASH OF THE FILING'S OWN FACTS. Form 4 has no id in this response, and the
  -- natural tuple (owner, date, type, count, price) is what identifies a transaction — hashing it
  -- makes re-fetching the same filing idempotent instead of duplicating it every run. Two genuinely
  -- identical transactions on one day collapse into one row, which loses nothing: they carry the
  -- same information twice.
  trade_key      text primary key,
  security_id    uuid not null references market.security (security_id) on delete cascade,
  filing_date    date,
  transaction_date date,
  owner_name     text,
  owner_title    text,
  -- 'Acquisition' / 'Disposition' — the direction, and the only field most readers care about.
  direction      text,
  transaction_type text,
  security_type  text,
  shares         numeric,
  shares_owned_after numeric,
  price          numeric,
  source_code    text not null references market.data_source (code),
  as_of          timestamptz not null default now()
);

comment on table market.insider_trade is
  'Form 4 insider transactions from `equity/ownership/insider_trading?provider=sec`. Keyed on a deterministic hash of the filing''s own facts because the response carries no id — re-fetching the same filing is then idempotent rather than duplicating it every run.';

create index if not exists insider_trade_security_idx
  on market.insider_trade (security_id, transaction_date desc);

grant select on market.insider_trade to anon, authenticated, service_role;
grant insert, update, delete on market.insider_trade to service_role;

alter table market.insider_trade enable row level security;
drop policy if exists insider_trade_read on market.insider_trade;
create policy insider_trade_read on market.insider_trade for select using (true);

-- A CURSOR, NOT A NEGATIVE CACHE. Insiders keep trading, so a security with nothing this week will
-- have something next quarter; `insider_fetched_at` records when we last looked, never that there
-- is nothing to find.
alter table market.security add column if not exists insider_fetched_at timestamptz;

comment on column market.security.insider_fetched_at is
  'When Form 4 filings were last fetched for this security. A CURSOR, not a negative cache — deliberately not a `%_missing_at` column, because "no insider trades this week" is never a permanent fact about a company.';

drop view if exists market.pending_insider;
create view market.pending_insider as
select
  s.security_id,
  s.cik,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  -- SEC-only by nature: the endpoint resolves a CIK, and a company that does not file with the SEC
  -- has no Form 4 to return. Scoping here rather than discovering it per call.
  and s.cik is not null
  and (s.insider_fetched_at is null or s.insider_fetched_at < now() - interval '7 days')
group by s.security_id, s.cik
order by best_weight desc;

comment on view market.pending_insider is
  'SEC filers whose Form 4 filings have not been read in the last week, ordered by fund weight. A rolling cursor: insiders keep trading, so this never empties and is not meant to.';

grant select on market.pending_insider to service_role;

-- ── THE SERVING VIEW: A DIRECTION, NOT A LIST ───────────────────────────────────────────────────
--
-- A page showing twenty Form 4 rows tells a reader nothing they can act on. The question insider
-- data answers is "are the people who know most about this company buying or selling", so the view
-- answers THAT: net shares over the last 90 days, and how many distinct people were on each side.
--
-- Counting PEOPLE as well as shares is deliberate. One officer exercising a large option grant can
-- outweigh a dozen colleagues buying, and a net figure alone would report that as selling.
drop view if exists market.security_insider_summary;
create view market.security_insider_summary as
select
  t.security_id,
  count(*) filter (where t.direction = 'Acquisition')  as buys,
  count(*) filter (where t.direction = 'Disposition')  as sells,
  count(distinct t.owner_name) filter (where t.direction = 'Acquisition') as buyers,
  count(distinct t.owner_name) filter (where t.direction = 'Disposition') as sellers,
  coalesce(sum(t.shares) filter (where t.direction = 'Acquisition'), 0)
    - coalesce(sum(t.shares) filter (where t.direction = 'Disposition'), 0) as net_shares,
  max(t.transaction_date) as latest,
  count(*) as trades
from market.insider_trade t
where t.transaction_date >= current_date - 90
group by t.security_id;

comment on view market.security_insider_summary is
  'Insider direction over the last 90 days: net shares, and how many distinct PEOPLE were on each side. The people count is not decoration — one officer exercising a large grant can outweigh a dozen colleagues buying, and a net share figure alone would report that as selling.';

grant select on market.security_insider_summary to anon, authenticated, service_role;

notify pgrst, 'reload schema';
