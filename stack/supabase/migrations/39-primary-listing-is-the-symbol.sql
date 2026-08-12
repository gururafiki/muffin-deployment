-- A security is named by its PRIMARY LISTING — IDEMPOTENT.
--
-- THE DEFECT. The display symbol was `coalesce(ticker, provider_symbol)` — ticker FIRST. The
-- `ticker` identifier comes from OpenFIGI's *US* lookup, which for a foreign company is a thin
-- over-the-counter foreign-ordinary line; the provider symbol is the actual local listing. So the
-- app named securities after the line nobody trades, while pricing them off the line they do:
--
--   displayed    actually priced
--   SAABF   ->   SAAB-B.ST     (Saab, Stockholm)
--   HXGBF   ->   HEXA-B.ST     (Hexagon, Stockholm)
--   SCAFF   ->   SHA0.DE       (Schaeffler, XETRA)
--   SAPGF   ->   SAP.DE        (SAP)
--
-- Measured 2026-08-12: **365 of 900 sampled non-US securities (41%)** carry both and were displayed
-- under the OTC one. The prices were never wrong — `pending_performance` deliberately FETCHES on
-- `coalesce(provider_symbol, ticker)` — but the label was, and `HXGBF` is not a name a reader can
-- look up.
--
-- The convention predates this change (migration 22) and was mirrored into `security_symbol` on
-- 2026-08-12 precisely BECAUSE the two agreed; matching was right, the shared choice was not.
--
-- THE FIX is not another coalesce. `market.listing.is_primary` records which line is the real quote
-- PER SECURITY, rather than a rule saying "local always wins" — which would be wrong for a company
-- whose ADR genuinely is the primary market.
--
-- `create or replace` rather than drop-and-recreate: the column list is unchanged, so the four
-- views built on top of these (sector_constituents, security_current, and the two *_current views)
-- pick up the new definition without being touched. Dropping would have required restating all of
-- them here, which is how definitions drift between migrations.

create or replace view market.security_symbol as
select
  s.security_id,
  coalesce(
    -- 1. The primary listing, when one is recorded. This is the answer.
    (select l.provider_symbol from market.listing l
      where l.security_id = s.security_id and l.is_primary limit 1),
    -- 2. Otherwise the local line, which is what the price provider is asked for anyway.
    ps.symbol,
    -- 3. Otherwise the US/OTC ticker. LAST, not first — that ordering is the whole point.
    t.value
  ) as symbol
from market.security s
left join lateral (
  select i.value from market.security_identifier i
  where i.security_id = s.security_id and i.kind_code = 'ticker'
  order by i.value limit 1
) t on true
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
where coalesce(
  (select l.provider_symbol from market.listing l where l.security_id = s.security_id and l.is_primary limit 1),
  ps.symbol, t.value) is not null;

comment on view market.security_symbol is
  'The one symbol a security is known by: its PRIMARY LISTING first, then the local line, then the US/OTC ticker. The OTC line is last deliberately — it is what OpenFIGI returns for a US lookup and is usually the least traded of the three.';

-- ── the performance backlog writes under the same name ───────────────────────
-- Otherwise the next run re-creates rows under the OLD display symbol and the re-key below undoes
-- itself. `fetch_symbol` is unchanged: what we ASK the provider for was always right.
create or replace view market.pending_performance as
select
  s.security_id,
  coalesce(sym.symbol, ps.symbol, t.value)   as symbol,
  coalesce(ps.symbol, t.value)               as fetch_symbol,
  coalesce(max(h.weight), 0)                 as best_weight
from market.security s
left join market.security_symbol sym on sym.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.performance p
  on p.scope = 'instrument'
 and p.scope_id = coalesce(sym.symbol, ps.symbol, t.value)
 and p.stale_after > now()
left join market.fund_holding_current h
  on h.security_id = s.security_id
where p.scope_id is null
  and coalesce(ps.symbol, t.value) is not null
  and (s.performance_missing_at is null or s.performance_missing_at < now() - interval '30 days')
group by s.security_id, sym.symbol, ps.symbol, t.value
order by best_weight desc;

-- ── re-key what is already stored ───────────────────────────────────────────
-- `performance.scope_id` holds the OLD display symbol, so without this every existing row is
-- orphaned: the UI would look up HEXA-B.ST and find rows filed under HXGBF, showing no number for
-- securities that have one.
--
-- Moved rather than deleted. Deleting would have been simpler and would have left ~3,000
-- securities with no return until the backlog refetched them — days, at the current drain rate,
-- for data we already hold.
-- Wrapped in an explicit transaction: psql autocommits each statement, so `on commit drop` would
-- destroy the table the moment it was created (it did — `relation "_rekey" does not exist`). It
-- also makes the move atomic, which matters because the delete below depends on the update above
-- having happened.
begin;

create temporary table _rekey as
select p.scope_id as old_symbol, sym.symbol as new_symbol
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
join market.performance p
  on p.scope = 'instrument' and p.scope_id = t.value
where sym.symbol is distinct from t.value
group by p.scope_id, sym.symbol;

-- Only where the destination is free. A collision means the security already has rows under its
-- new name, so the old ones are stale duplicates rather than data to preserve.
update market.performance p
   set scope_id = r.new_symbol
  from _rekey r
 where p.scope = 'instrument'
   and p.scope_id = r.old_symbol
   and not exists (
     select 1 from market.performance q
      where q.scope = 'instrument' and q.scope_id = r.new_symbol and q.period = p.period
   );

delete from market.performance p
 using _rekey r
 where p.scope = 'instrument' and p.scope_id = r.old_symbol;

drop table _rekey;

commit;

notify pgrst, 'reload schema';
