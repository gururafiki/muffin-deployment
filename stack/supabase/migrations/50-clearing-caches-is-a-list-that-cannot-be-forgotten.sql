-- A new symbol must invalidate EVERY symbol-keyed negative cache — IDEMPOTENT.
--
-- `security-yahoo-symbols` already knew this and cleared five flags by hand:
--
--     industry_missing_at, profile_missing_at, performance_missing_at,
--     fundamentals_missing_at, statements_missing_at
--
-- `prices_missing_at` arrived later (migration 42) and was never added to that list. So a security
-- whose symbol the resolver CORRECTED stayed locked out of `pending_prices` for 30 days — the
-- provider had been asked under the wrong name, got nothing, and the flag recording that answer
-- outlived the name that produced it. Measured 2026-08-13: **4,801 of 12,348 equities** carry
-- `prices_missing_at`, against 4,617 that actually have a recent bar.
--
-- This is the FIFTH time a `*_missing_at` column has been got wrong (see CLAUDE.md: `figi_missing_at`,
-- `profile_missing_at`, `local_symbol_missing_at`, `performance_missing_at`). Adding the sixth
-- column to a hand-written list in TypeScript is a fix for today only — the next resource that adds
-- a seventh will miss it exactly the same way, and NOTHING WILL ERROR: the security simply goes
-- quiet for 30 days.
--
-- So the list moves next to the columns, and becomes enforceable. `clear_symbol_caches` names the
-- symbol-keyed flags; `symbol_cache_classification` names all nine and says which side each is on.
-- The test `negative-caches-are-classified.sql` fails when a `%_missing_at` column exists that the
-- classification does not mention, so a new one cannot be silently forgotten OR silently swept in.
--
-- WHY NOT "CLEAR EVERYTHING MATCHING `%_missing_at`". Three of the nine are NOT keyed on the symbol
-- and clearing them would re-ask a rate-limited provider for an answer we already have:
--   figi_missing_at         OpenFIGI was asked for the ISIN. A new symbol says nothing about that.
--   local_symbol_missing_at keyed on ISIN/FIGI, same reason.
--   yahoo_symbol_missing_at the resolver's OWN flag — clearing it here would be a loop.

create or replace function market.clear_symbol_caches(p_security_id uuid)
returns void
language sql
security definer
set search_path = market, pg_temp
as $$
  update market.security set
    industry_missing_at     = null,
    profile_missing_at      = null,
    performance_missing_at  = null,
    fundamentals_missing_at = null,
    statements_missing_at   = null,
    prices_missing_at       = null   -- the one the hand-written list forgot
  where security_id = p_security_id;
$$;

comment on function market.clear_symbol_caches(uuid) is
  'Clear every negative cache that recorded a fetch made UNDER A SYMBOL. Called when the symbol changes: those flags recorded an answer to the wrong question. Deliberately does not touch figi/local_symbol/yahoo_symbol, which are keyed on the ISIN rather than the symbol.';

-- The enforceable half. Every `%_missing_at` column on `market.security` must appear here, on one
-- side or the other, with a reason. A column absent from this view is a column nobody decided about.
drop view if exists market.symbol_cache_classification;
create view market.symbol_cache_classification as
select * from (values
  ('industry_missing_at',     true,  'yfinance profile fetched by symbol'),
  ('profile_missing_at',      true,  'yfinance profile fetched by symbol'),
  ('performance_missing_at',  true,  'historical bars fetched by symbol'),
  ('fundamentals_missing_at', true,  'metrics fetched by symbol'),
  ('statements_missing_at',   true,  'statements fetched by symbol'),
  ('prices_missing_at',       true,  'daily bars fetched by symbol'),
  ('figi_missing_at',         false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at', false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at', false, 'the resolver''s own flag — clearing it here would loop')
) as t(column_name, symbol_keyed, reason);

comment on view market.symbol_cache_classification is
  'Which negative caches a new symbol invalidates, and why. Enforced by tests/negative-caches-are-classified.sql: a `%_missing_at` column missing from here fails CI.';

grant execute on function market.clear_symbol_caches(uuid) to service_role;
grant select on market.symbol_cache_classification to service_role;

-- ── one-shot repairs, in a migration set that re-runs in full ───────────────────────────────────
--
-- Every migration here is applied on EVERY deploy, which is what makes the schema self-healing. For
-- a data REPAIR that is the wrong behaviour, and for this particular repair it is actively harmful:
-- clearing `prices_missing_at` on every deploy would permanently defeat the negative cache, so the
-- securities yfinance genuinely has nothing for would be re-fetched forever — the exact failure the
-- flag exists to prevent, reintroduced by the fix for it.
--
-- Schema statements are idempotent by construction (`create or replace`, `add column if not
-- exists`). Data repairs are not, and there was nowhere to record that one had already run. Hence a
-- ledger: it makes "run this once" expressible, and the reason is stored beside the key so a future
-- reader can tell a deliberate one-shot from a forgotten guard.
create table if not exists market.one_shot (
  key         text primary key,
  applied_at  timestamptz not null default now(),
  reason      text
);
comment on table market.one_shot is
  'Data repairs that must run ONCE, in a migration set that is re-applied on every deploy. Schema changes do not belong here — they are idempotent already.';

-- Grants, because a new table is UNREACHABLE without them and the migration job runs as superuser
-- so it cannot notice. `security_price` shipped without these and the resource could not write a
-- single row; `tests/every-table-is-reachable.sql` exists for that and caught this one too.
grant select, insert on market.one_shot to service_role;
alter table market.one_shot enable row level security;
-- No policy: `one_shot` is an operational ledger, not app data. RLS with no policy denies every
-- role that does not BYPASSRLS, which is the same shape `refresh_log` uses.

do $$
begin
  if exists (select 1 from market.one_shot where key = '50-clear-stale-prices-cache') then
    return;
  end if;

  -- The 4,801 already locked out. They were flagged under a name the resolver has since corrected
  -- (or is about to), so the flag is not evidence about the CURRENT symbol. Cleared only where a
  -- symbol exists at all — a security with no symbol was never asked under a wrong name, it was
  -- never asked, and it belongs to the resolver's backlog rather than the price fetcher's.
  update market.security s
     set prices_missing_at = null
   where s.prices_missing_at is not null
     and exists (select 1 from market.security_symbol y where y.security_id = s.security_id);

  insert into market.one_shot (key, reason) values
    ('50-clear-stale-prices-cache',
     'prices_missing_at was set under symbols the resolver has since corrected; the resolver never cleared it because the hand-written clear list predated the column.');
end $$;

notify pgrst, 'reload schema';
