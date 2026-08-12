-- Market cap on every security — IDEMPOTENT.
--
-- Recorded for weeks as "blocked: FMP's free tier gates fundamentals per symbol". That is true of
-- DEEP fundamentals (P/E, revenue, margins) and false of market cap: yfinance's `equity/profile`
-- returns it, `market.instruments` has carried real values all along (NVDA $5.27T, AAPL $4.50T),
-- and `security-profiles` reads that very response for the sector and throws the rest away.
--
-- So this costs no new provider, no key and not one extra request — only storing a field already
-- on the wire.

alter table market.security add column if not exists market_cap numeric;
alter table market.security add column if not exists market_cap_at timestamptz;
comment on column market.security.market_cap is
  'From yfinance equity/profile, captured by security-profiles. Reported in the security''s own currency, which is why the column carries no unit conversion.';

create index if not exists security_market_cap_idx on market.security (market_cap desc nulls last);

-- Serve it. The sector page has been ranking by fund weight because market cap was believed
-- unavailable; weight stays the fallback for a security no sector fund holds.
drop view if exists market.sector_constituents;
create view market.sector_constituents as
select distinct on (tn.code, s.security_id)
  tn.code        as sector_id,
  s.security_id,
  s.name,
  t.symbol,
  s.country_iso2,
  ind.name       as industry,
  h.weight,
  h.fund_symbol,
  s.market_cap,
  h.market_value,
  h.as_of
from market.security_taxonomy st
join market.taxonomy_node tn
  on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
join market.data_source ds   on ds.code = st.source_code
join market.security s       on s.security_id = st.security_id
left join lateral (
  select i.value as symbol
  from market.security_identifier i
  where i.security_id = s.security_id and i.kind_code = 'ticker'
  order by i.value
  limit 1
) t on true
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

-- `instrument_current` (migration 40) is built on `security_current`, so it must go first or this
-- drop fails with "cannot drop view ... because other objects depend on it" on every re-run after
-- 40 has landed. `if exists` keeps it a no-op on a fresh database.
drop view if exists market.instrument_current;
drop view if exists market.security_current;
create view market.security_current as
select
  s.security_id,
  s.name,
  s.security_type_code,
  s.country_iso2,
  s.currency_code,
  s.is_tradeable,
  s.market_cap,
  t.value    as symbol,
  isin.value as isin,
  i.name     as issuer_name,
  (select tn.code
     from market.security_taxonomy st
     join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
     join market.data_source ds   on ds.code = st.source_code
    where st.security_id = s.security_id
    order by ds.priority desc, st.as_of desc
    limit 1) as sector_id
from market.security s
left join market.security_identifier t    on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_identifier isin on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.issuer i                 on i.issuer_id = s.issuer_id;

grant select on market.sector_constituents, market.security_current
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
