-- AN INCORPORATION JURISDICTION IS NOT A COUNTRY A USER LOOKS UNDER.
--
-- N-PORT reports where a security is INCORPORATED, so Alibaba is filed under `KY` — the Cayman
-- Islands, where it has no operations, no listing and no market page. 180 equities sit in
-- venue-less jurisdictions this way (119 KY, 56 BM, 5 VG). deployment#119 fixed the SYMBOL for
-- them, by letting `pickHomeListing` fall back when a country names no venue; it did not fix the
-- COUNTRY, so Alibaba is still absent from China and present only in the "Other" bucket.
--
-- `equity/profile` already answers this, in a response we ALREADY FETCH for sector, industry and
-- market cap: `hq_country` is the operating headquarters. It was being read for the 35-row curated
-- overlay (`market.instruments.country`) and discarded for the 27,627-row real universe. Same
-- shape as market cap, which was called blocked on a paid provider while riding along on this
-- exact response.
--
-- BOTH FACTS ARE KEPT, because both are true and they answer different questions:
--
--   filed_country_iso2      where it is incorporated   — from the filing, authoritative, KY
--   provider_country_iso2   where it operates          — from yfinance, CN
--   country_iso2            what the app should show   — the operating one, falling back to filed
--
-- `country_iso2` keeps its name and position so every consumer picks the fix up without being
-- touched; `create or replace view` permits changing an expression, only not renaming, reordering
-- or dropping. The filed value moves to a new appended column rather than being lost — it is what
-- the SEC actually said, and a later question about domicile has to be answerable.
--
-- THE NAME IS RESOLVED, NOT ASSUMED. `hq_country` is an English NAME ("Taiwan", "United Kingdom"),
-- not an ISO code, so it is matched case-insensitively against `market.countries.name` — the same
-- 222-row table the globe reads, so the two cannot disagree. Measured against every value the
-- overlay actually holds (Australia, Denmark, Germany, Switzerland, Taiwan, United Kingdom,
-- United States): all seven match, and the table already uses the common spellings a provider
-- emits ("south korea", "hong kong", "vietnam", "czech republic") rather than ISO's formal ones.
--
-- `country_alias` exists for the residue. It is seeded with only what is justified by the
-- reference table's own contents — `countries` calls RU "Russian Federation", which no provider
-- says — and is otherwise EMPTY on purpose: the resource counts and reports every name it could
-- not resolve, so the rest of this table gets filled from measurement rather than from a guess
-- about a provider's vocabulary. Authoring reference data from memory is what silently dropped
-- Taiwan once already.

alter table market.security
  add column if not exists provider_country_iso2 text references market.countries(iso2);

comment on column market.security.provider_country_iso2 is
  'Operating HQ country from equity/profile.hq_country, resolved to ISO-2. Kept BESIDE the filed country_iso2 (incorporation, from N-PORT) rather than overwriting it — Alibaba is incorporated in KY and operates in CN, and both are true.';

create table if not exists market.country_alias (
  provider_name text primary key,
  iso2          text not null references market.countries(iso2)
);

comment on table market.country_alias is
  'Provider country spellings that do not match market.countries.name. Deliberately near-empty: security-profiles reports the names it could not resolve, and rows are added from that measurement rather than guessed.';

-- The one alias the reference table itself justifies: it holds the formal ISO name where a provider
-- emits the common one.
insert into market.country_alias (provider_name, iso2) values ('russia', 'RU')
on conflict (provider_name) do nothing;

alter table market.country_alias enable row level security;
drop policy if exists country_alias_read on market.country_alias;
create policy country_alias_read on market.country_alias for select using (true);
grant select on market.country_alias to anon, authenticated, service_role;
grant insert, update, delete on market.country_alias to service_role;

-- ── the serving views now answer with the operating country ──────────────────
-- Column names, types and ORDER are unchanged up to the appended pair, which is what
-- `create or replace` requires. Only the expression behind `country_iso2` changes.
create or replace view market.security_current as
select
  s.security_id,
  s.name,
  s.security_type_code,
  coalesce(s.provider_country_iso2, s.country_iso2) as country_iso2,
  s.currency_code,
  s.is_tradeable,
  s.market_cap,
  sym.symbol,
  isin.value as isin,
  i.name     as issuer_name,
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
    limit 1) as industry,
  -- Appended, so nothing that reads this view by position breaks.
  s.country_iso2          as filed_country_iso2,
  s.provider_country_iso2 as provider_country_iso2
from market.security s
left join market.security_symbol sym      on sym.security_id = s.security_id
left join market.security_identifier isin on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.issuer i                 on i.issuer_id = s.issuer_id
-- Joined on the EFFECTIVE country, or the display name would disagree with the code beside it.
left join market.countries c              on c.iso2 = coalesce(s.provider_country_iso2, s.country_iso2);

create or replace view market.sector_constituents as
select distinct on (tn.code, s.security_id)
  tn.code        as sector_id,
  s.security_id,
  s.name,
  sym.symbol,
  coalesce(s.provider_country_iso2, s.country_iso2) as country_iso2,
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

grant select on market.security_current, market.sector_constituents
to anon, authenticated, service_role;

notify pgrst, 'reload schema';
