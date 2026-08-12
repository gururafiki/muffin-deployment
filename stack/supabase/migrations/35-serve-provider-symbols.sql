-- Serve the symbol a security is actually addressable by — IDEMPOTENT.
--
-- THE GAP. The serving views take `symbol` from `security_identifier` where `kind_code = 'ticker'`
-- only. A security whose sole address is a local provider symbol (`005930.KS`) therefore has NO
-- symbol in the view, and `sector/[sectorId].tsx` sets `disabled: !s.symbol` — so the row cannot be
-- opened at all.
--
-- Measured 2026-08-11: 3,821 of 7,940 constituent rows carry a symbol, while 8,521 securities have
-- a yfinance provider symbol; of a 900-row sample of those, 40% have no `ticker` identifier. So
-- roughly 3,400 securities have prices, returns and fundamentals, and are unreachable in the app.
--
-- `coalesce(ticker, provider_symbol)` is the same precedence `pending_industry` and
-- `pending_fundamentals` already use, so this makes the serving side agree with the ingest side
-- rather than inventing a rule.
--
-- SHIPPING THIS ALONE WOULD BE WORSE THAN NOT SHIPPING IT: the rows would become tappable and open
-- a page that queries `security_identifier.kind_code = 'ticker'` and finds nothing — 3,400 dead
-- rows turned into 3,400 blank pages. Hence the two `*_current` views below, which the app reads
-- BY SYMBOL, and the matching muffin-ui change.

-- DROP DEPENDENTS FIRST, IN REVERSE ORDER. Migrations re-run on every deploy, so the second pass
-- meets a `security_symbol` that four other views already build on and fails with
-- `cannot drop view market.security_symbol because other objects depend on it`. Not `cascade`:
-- that would silently take out whatever else happens to depend on it, including views another
-- migration owns — the failure mode this file is meant to avoid, not cause.
drop view if exists market.security_fundamentals_current;
drop view if exists market.security_statement_current;
drop view if exists market.sector_constituents;
-- `instrument_current` (migration 40) is built on `security_current`, so it must go first or this
-- drop fails with "cannot drop view ... because other objects depend on it" on every re-run after
-- 40 has landed. `if exists` keeps it a no-op on a fresh database.
drop view if exists market.instrument_current;
drop view if exists market.security_current;
drop view if exists market.security_symbol;

-- ── the addressable symbol, in one place ─────────────────────────────────────
create view market.security_symbol as
select
  s.security_id,
  coalesce(t.value, ps.symbol) as symbol
from market.security s
left join lateral (
  select i.value
  from market.security_identifier i
  where i.security_id = s.security_id and i.kind_code = 'ticker'
  order by i.value
  limit 1
) t on true
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
where coalesce(t.value, ps.symbol) is not null;

comment on view market.security_symbol is
  'One addressable symbol per security: the ticker identifier if there is one, else the yfinance provider symbol. Same precedence as the ingest backlogs.';

-- ── the two views the stock page reads, keyed BY SYMBOL ──────────────────────
-- The app used a PostgREST embed through `security_identifier` and filtered on `kind_code`, which
-- is both the source of the gap and more round-trip shaped than it needs to be. A view that already
-- carries the symbol keeps the client read to one filter on one relation — the same reason
-- `sector_constituents` exists at all.
create view market.security_fundamentals_current as
select
  sym.symbol,
  f.*,
  s.currency_code
from market.security_fundamentals f
join market.security_symbol sym on sym.security_id = f.security_id
join market.security s          on s.security_id = f.security_id;

create view market.security_statement_current as
select
  sym.symbol,
  st.*,
  -- The statement endpoints carry NO currency field, so `security_statement.currency` is null for
  -- every row (`reported_currency` was a wrong guess in migration 29). The security's own currency
  -- is the honest label; exposed alongside rather than instead, so a provider that starts sending a
  -- real per-statement currency still wins at the point of use.
  s.currency_code
from market.security_statement st
join market.security_symbol sym on sym.security_id = st.security_id
join market.security s          on s.security_id = st.security_id;

-- ── the constituent list and the security record now agree with the ingest ───
create view market.sector_constituents as
select distinct on (tn.code, s.security_id)
  tn.code        as sector_id,
  s.security_id,
  s.name,
  sym.symbol,
  s.country_iso2,
  ind.name       as industry,
  h.weight,
  h.fund_symbol,
  s.market_cap,
  s.currency_code,
  h.market_value,
  h.as_of
from market.security_taxonomy st
join market.taxonomy_node tn
  on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
join market.data_source ds   on ds.code = st.source_code
join market.security s       on s.security_id = st.security_id
left join market.security_symbol sym on sym.security_id = s.security_id
left join lateral (
  select n.name
  from market.security_taxonomy st2
  join market.taxonomy_node n
    on n.node_id = st2.node_id and n.taxonomy_id = 'muffin' and n.level = 2
   and n.parent_id = tn.node_id
  where st2.security_id = s.security_id
  limit 1
) ind on true
left join lateral (
  select h.weight, h.market_value, h.as_of, fi.value as fund_symbol
  from market.fund_holding_current h
  join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf on tf.symbol = fi.value and tf.represents_code = tn.code
  where h.security_id = s.security_id
  limit 1
) h on true
order by tn.code, s.security_id, ds.priority desc, st.as_of desc;

create view market.security_current as
select
  s.security_id,
  s.name,
  s.security_type_code,
  s.country_iso2,
  s.currency_code,
  s.is_tradeable,
  s.market_cap,
  sym.symbol,
  isin.value as isin,
  i.name     as issuer_name,
  -- The DISPLAY name, so the stock page does not have to turn `KR` into `South Korea` itself.
  -- `market.countries` is the same table the globe reads, so the two cannot disagree.
  c.name     as country_name,
  (select tn.code
     from market.security_taxonomy st
     join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
     join market.data_source ds   on ds.code = st.source_code
    where st.security_id = s.security_id
    order by ds.priority desc, st.as_of desc
    limit 1) as sector_id,
  (select n.name
     from market.security_taxonomy st2
     join market.taxonomy_node n on n.node_id = st2.node_id and n.taxonomy_id = 'muffin' and n.level = 2
     join market.data_source ds2  on ds2.code = st2.source_code
    where st2.security_id = s.security_id
    order by ds2.priority desc, st2.as_of desc
    limit 1) as industry
from market.security s
left join market.security_symbol sym      on sym.security_id = s.security_id
left join market.security_identifier isin on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.issuer i                 on i.issuer_id = s.issuer_id
left join market.countries c              on c.iso2 = s.country_iso2;

grant select on
  market.security_symbol,
  market.security_fundamentals_current,
  market.security_statement_current,
  market.sector_constituents,
  market.security_current
to anon, authenticated, service_role;

notify pgrst, 'reload schema';
