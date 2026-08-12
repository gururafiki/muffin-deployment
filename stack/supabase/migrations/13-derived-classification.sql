-- Classify securities from FUND MEMBERSHIP, and serve them — IDEMPOTENT.
--
-- THE IDEA. A sector SPDR's holdings *are* that sector's constituents; that is what the fund is.
-- So classification needs no provider, no API key and no per-security lookup: XLK holds it =>
-- it is Information Technology, with the SEC filing as provenance. The same trick gives country
-- membership from the country ETFs. This is what the model meant by "the donut becomes derivable".
--
-- It is also strictly better than asking a provider per security: 9,786 securities would be
-- thousands of calls returning one opinion each, where this is one join returning a fact with an
-- `as_of` date behind it.
--
-- LIMIT, stated plainly: coverage is exactly the union of the tracked funds' holdings. A security
-- no sector SPDR holds gets no sector here. That is honest — and it is why `provider_sector`
-- (yfinance's opinion) still exists beside it rather than being replaced.

-- ═══════════════ 1. A fund declares what it represents ═══════════════
-- Data, not code: a new sector ETF is a row, and its meaning is a column on that row. Without this
-- the mapping XLK -> information-technology would have to live in a function and need a deploy.

alter table market.tracked_fund add column if not exists represents_code text;
comment on column market.tracked_fund.represents_code is
  'What this fund stands for: a market.sectors id when kind=''sector'', an ISO-2 country code when kind=''country''. NULL = the fund contributes holdings but classifies nothing.';

update market.tracked_fund set represents_code = v.code from (values
  ('XLK','information-technology'), ('XLF','financials'),             ('XLV','health-care'),
  ('XLY','consumer-discretionary'), ('XLP','consumer-staples'),       ('XLC','communication-services'),
  ('XLI','industrials'),            ('XLE','energy'),                 ('XLB','materials'),
  ('XLU','utilities'),              ('XLRE','real-estate')
) as v(symbol, code)
where market.tracked_fund.symbol = v.symbol and market.tracked_fund.represents_code is null;

-- Country ETFs already declare their country in market.countries.etf_symbol, so read it from there
-- rather than restating the mapping in a second place where the two could drift apart.
update market.tracked_fund tf set represents_code = c.iso2
from market.countries c
where c.etf_symbol = tf.symbol and tf.kind = 'country' and tf.represents_code is null;

-- ═══════════════ 2. Derive the classification ═══════════════
-- A FUNCTION rather than a trigger: it runs once after an ingest, when the holdings are complete.
-- A trigger would fire per row and re-derive the world 16,000 times.

create or replace function market.derive_classifications() returns integer
language plpgsql security definer set search_path = market, public as $$
declare n integer;
begin
  -- Sector, from the sector SPDRs' current holdings.
  insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
  select h.security_id, tn.node_id, 'sec-nport', h.as_of
  from market.fund_holding_current h
  join market.security_identifier fi
    on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf
    on tf.symbol = fi.value and tf.kind = 'sector' and tf.represents_code is not null
  join market.taxonomy_node tn
    on tn.taxonomy_id = 'muffin' and tn.code = tf.represents_code
  -- A fund holds itself, cash and futures; none of those is a constituent of its own sector.
  join market.security s on s.security_id = h.security_id and s.security_type_code = 'equity'
  where h.security_id <> h.fund_id
  on conflict (security_id, node_id, source_code) do update set as_of = excluded.as_of;
  get diagnostics n = row_count;

  -- Country, from the country ETFs. Written to market.security.country_iso2 only where the filing
  -- did NOT already say — the filing's own invCountry is the better source when present.
  update market.security s
     set country_iso2 = tf.represents_code
  from market.fund_holding_current h
  join market.security_identifier fi
    on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf
    on tf.symbol = fi.value and tf.kind = 'country' and tf.represents_code is not null
  where s.security_id = h.security_id
    and s.country_iso2 is null
    and h.security_id <> h.fund_id;

  return n;
end $$;

-- ═══════════════ 3. Serving views — what the app reads ═══════════════
-- The client must not join five tables on a phone.

-- One row per security with its primary ticker and preferred sector. `data_source.priority` picks
-- between disagreeing sources rather than an arbitrary one winning.
-- DROP before CREATE, same as the two views below it: migration 26 redefines this with
-- `market_cap`, and `create or replace` cannot add a column in the middle or drop one.
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
  t.value    as symbol,
  isin.value as isin,
  i.name     as issuer_name,
  (select tn.code
     from market.security_taxonomy st
     join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin'
     join market.data_source ds   on ds.code = st.source_code
    where st.security_id = s.security_id
    order by ds.priority desc, st.as_of desc
    limit 1) as sector_id
from market.security s
left join market.security_identifier t    on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_identifier isin on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.issuer i                 on i.issuer_id = s.issuer_id;

-- The sector page. `weight` is the security's weight in the sector fund, which is the closest thing
-- to a size ranking available without fundamentals — and it is a fact from a filing, not an estimate.
-- DROP before CREATE: migrations 18 and 23 redefine this with different columns, and every
-- migration re-runs in order on every deploy — so without the drop, whichever runs first keeps
-- trying to impose its column list on the others.
drop view if exists market.sector_constituents;
create view market.sector_constituents as
select
  tn.code        as sector_id,
  s.security_id,
  s.name,
  t.value        as symbol,
  s.country_iso2,
  h.weight,
  h.market_value,
  h.as_of
from market.security_taxonomy st
join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin'
join market.security s       on s.security_id = st.security_id
left join market.security_identifier t on t.security_id = s.security_id and t.kind_code = 'ticker'
left join lateral (
  select h.weight, h.market_value, h.as_of
  from market.fund_holding_current h
  join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf on tf.symbol = fi.value and tf.represents_code = tn.code
  where h.security_id = s.security_id
  limit 1
) h on true;

-- What finally makes the Markets donut real. NOTE the weights are renormalised: a fund's own
-- reported weights do NOT sum to 100 (EWT's filing sums to 110.38), so a donut drawn from the raw
-- numbers would be wrong.
drop view if exists market.fund_sector_weight;
create view market.fund_sector_weight as
select
  fi.value as fund_symbol,
  coalesce(tn.code, 'unclassified') as sector_id,
  sum(h.weight) as weight,
  round(100 * sum(h.weight) / nullif(sum(sum(h.weight)) over (partition by fi.value), 0), 4) as weight_pct,
  max(h.as_of) as as_of
from market.fund_holding_current h
join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
left join market.security_taxonomy st on st.security_id = h.security_id
left join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin'
where h.security_id <> h.fund_id
group by fi.value, coalesce(tn.code, 'unclassified');

create or replace view market.fund_country_weight as
select
  fi.value as fund_symbol,
  coalesce(s.country_iso2, 'XX') as country_iso2,
  sum(h.weight) as weight,
  round(100 * sum(h.weight) / nullif(sum(sum(h.weight)) over (partition by fi.value), 0), 4) as weight_pct,
  max(h.as_of) as as_of
from market.fund_holding_current h
join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
join market.security s on s.security_id = h.security_id
where h.security_id <> h.fund_id
group by fi.value, coalesce(s.country_iso2, 'XX');

-- ═══════════════ 4. Grants ═══════════════
-- Views run as their owner, so RLS on the underlying tables is not what protects these. They expose
-- only reference data, which is public-read by design (09-market-rls.sql), and are read-only to
-- everyone but service_role.

grant select on market.security_current, market.sector_constituents,
                market.fund_sector_weight, market.fund_country_weight
  to anon, authenticated, service_role;

revoke all on function market.derive_classifications() from public;
grant execute on function market.derive_classifications() to service_role;

notify pgrst, 'reload schema';

-- ═══════════════ 5. The ticker backlog, most visible first ═══════════════
-- N-PORT carries almost no tickers, so securities arrive unlinkable and unpriceable. Resolution
-- (OpenFIGI) is rate-limited and therefore INCREMENTAL, which makes the ORDER the important part:
-- resolve what a sector page actually renders before the long tail of an emerging-markets fund.
--
-- `security_type_code = 'equity'` because a bond or a futures position has no ticker to find.

create or replace view market.pending_ticker as
select
  s.security_id,
  isin.value as isin,
  s.name,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier isin
  on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where t.security_id is null
  and s.security_type_code = 'equity'
group by s.security_id, isin.value, s.name
order by best_weight desc;

grant select on market.pending_ticker to service_role;

insert into market.data_source (code, name, priority) values
  ('openfigi', 'OpenFIGI (Bloomberg symbology)', 150)
on conflict (code) do update set name = excluded.name, priority = excluded.priority;

notify pgrst, 'reload schema';
