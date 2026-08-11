-- A country's OWN sector returns — IDEMPOTENT.
--
-- A country page has been showing `scope = 'sector'`, which is finviz's `equity/compare/groups`
-- and US-LISTED ONLY. So /country/south-korea displayed US sector returns under a heading that
-- read as Korea's — which is why none of them matched EWY's +121.9%. The label was corrected; the
-- number never was, because there was nothing to replace it with.
--
-- There is now. Every input exists: a security has a country, a sector (level 1), a weight in its
-- country's ETF, and a return. The aggregate is a WEIGHTED MEAN of its constituents' returns,
-- which is what a sector index is.
--
-- WEIGHTED BY THE COUNTRY FUND'S OWN WEIGHT, not equally. An equal-weighted mean of Korea's
-- technology names would put a small-cap on par with Samsung and produce a number no index would
-- recognise.
--
-- `constituents` is exposed deliberately: a mean over 3 of 40 names is not wrong so much as
-- unrepresentative, and only the caller can decide whether to show it. It is reported rather than
-- hidden behind a threshold chosen here.

create or replace view market.country_sector_performance as
with constituent as (
  -- One sector per security, by source priority — the same rule the other serving views use, and
  -- applied BEFORE aggregating so a security classified twice cannot be counted twice.
  select distinct on (s.security_id)
    s.security_id,
    s.country_iso2,
    tn.code as sector_id,
    t.value as symbol,
    h.weight
  from market.security s
  join market.security_taxonomy st on st.security_id = s.security_id
  join market.taxonomy_node tn
    on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
  join market.data_source ds on ds.code = st.source_code
  -- The security's weight in ITS OWN country's fund. Without the represents_code match a Korean
  -- name would pick up whatever weight any tracked fund happened to give it.
  join market.security_identifier t
    on t.security_id = s.security_id and t.kind_code = 'ticker'
  join market.fund_holding_current h on h.security_id = s.security_id
  join market.security_identifier fi
    on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf
    on tf.symbol = fi.value and tf.kind = 'country' and tf.represents_code = s.country_iso2
  where s.country_iso2 is not null
    and s.security_type_code = 'equity'
    and h.weight > 0
  order by s.security_id, ds.priority desc, st.as_of desc
)
select
  c.country_iso2,
  c.sector_id,
  p.period,
  -- Weighted mean. `nullif` rather than a guard: a sector whose constituents all have zero weight
  -- has no defensible number, and NULL says that where 0 would not.
  round(sum(c.weight * p.change_pct) / nullif(sum(c.weight), 0), 4) as change_pct,
  count(*) as constituents,
  round(sum(c.weight), 4) as weight_covered,
  max(p.as_of) as as_of
from constituent c
join market.performance p
  on p.scope = 'instrument' and p.scope_id = c.symbol
group by c.country_iso2, c.sector_id, p.period;

grant select on market.country_sector_performance to anon, authenticated, service_role;

notify pgrst, 'reload schema';
