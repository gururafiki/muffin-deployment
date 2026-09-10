-- An industry must belong to the sector it is served under — IDEMPOTENT.
--
-- `security_current` picked the industry with two scalar subqueries carrying `n.level = 2` and NO
-- constraint on whose child the node is; `sector_constituents` has always required
-- `n.parent_id = tn.node_id`. So the two disagreed about the same company.
--
-- `create or replace`, NOT drop-and-create: the column list and ORDER are load-bearing, because
-- four migrations define this view and each re-imposes its shape on every deploy. Only the two
-- subquery bodies change.

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
    -- THE INDUSTRY MUST BELONG TO THE SECTOR THIS SAME VIEW IS SERVING. Without it, these two
    -- subqueries take the highest-priority level-2 node the security carries REGARDLESS of whose
    -- child it is, while `sector_constituents` has always required `n.parent_id = tn.node_id` — so
    -- the stock page and the sector page disagree about the same company. Measured: Uber, Paychex
    -- and ADP are `industrials` served a `Software - Application` industry, as are LDOS, FIS, BALL,
    -- AMCR and EXO.AS.
    --
    -- Not cosmetic — `security_facets.industry_code` is built from this view, so the mismatched
    -- pairs surface on the coverage dashboard as INDUSTRY BUCKETS THAT DO NOT EXIST:
    -- `industrials--software-application`, `financials--software-infrastructure`,
    -- `materials--packaging-containers`. Nine securities filed under three industries no taxonomy
    -- contains.
    --
    -- The sector pick is repeated rather than factored into a CTE because `create or replace view`
    -- cannot reorder or rename columns, and FOUR migrations (013, 026, 035, 056) define this view
    -- and each re-imposes its own column list every deploy. Restructuring would need a DROP, and
    -- this view has dependents.
    and n.parent_id = (
      select tn.node_id
        from market.security_taxonomy st_sec
        join market.taxonomy_node tn on tn.node_id = st_sec.node_id
                                    and tn.taxonomy_id = 'muffin' and tn.level = 1
        join market.data_source ds_sec on ds_sec.code = st_sec.source_code
       where st_sec.security_id = s.security_id
       order by ds_sec.priority desc, st_sec.as_of desc
       limit 1)
     join market.data_source ds2  on ds2.code = st2.source_code
    where st2.security_id = s.security_id
    order by ds2.priority desc, st2.as_of desc
    limit 1) as industry,
  -- MUST SIT HERE, matching migration 35's column ORDER exactly. `create or replace view` can only
  -- APPEND: it cannot rename, reorder or drop. Adding `industry_code` to 35 and not to 56 makes
  -- this statement try to DROP it, and putting it after the two country columns makes 35's
  -- definition try to rename them. Both fail the deploy on the FIRST pass, which is at least loud.
  (select n.code
     from market.security_taxonomy st2
     join market.taxonomy_node n on n.node_id = st2.node_id and n.taxonomy_id = 'muffin' and n.level = 2
    -- THE INDUSTRY MUST BELONG TO THE SECTOR THIS SAME VIEW IS SERVING. Without it, these two
    -- subqueries take the highest-priority level-2 node the security carries REGARDLESS of whose
    -- child it is, while `sector_constituents` has always required `n.parent_id = tn.node_id` — so
    -- the stock page and the sector page disagree about the same company. Measured: Uber, Paychex
    -- and ADP are `industrials` served a `Software - Application` industry, as are LDOS, FIS, BALL,
    -- AMCR and EXO.AS.
    --
    -- Not cosmetic — `security_facets.industry_code` is built from this view, so the mismatched
    -- pairs surface on the coverage dashboard as INDUSTRY BUCKETS THAT DO NOT EXIST:
    -- `industrials--software-application`, `financials--software-infrastructure`,
    -- `materials--packaging-containers`. Nine securities filed under three industries no taxonomy
    -- contains.
    --
    -- The sector pick is repeated rather than factored into a CTE because `create or replace view`
    -- cannot reorder or rename columns, and FOUR migrations (013, 026, 035, 056) define this view
    -- and each re-imposes its own column list every deploy. Restructuring would need a DROP, and
    -- this view has dependents.
    and n.parent_id = (
      select tn.node_id
        from market.security_taxonomy st_sec
        join market.taxonomy_node tn on tn.node_id = st_sec.node_id
                                    and tn.taxonomy_id = 'muffin' and tn.level = 1
        join market.data_source ds_sec on ds_sec.code = st_sec.source_code
       where st_sec.security_id = s.security_id
       order by ds_sec.priority desc, st_sec.as_of desc
       limit 1)
     join market.data_source ds2  on ds2.code = st2.source_code
    where st2.security_id = s.security_id
    order by ds2.priority desc, st2.as_of desc
    limit 1) as industry_code,
  -- Appended, so nothing that reads this view by position breaks.
  s.country_iso2          as filed_country_iso2,
  s.provider_country_iso2 as provider_country_iso2
from market.security s
left join market.security_symbol sym      on sym.security_id = s.security_id
left join market.security_identifier isin on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.issuer i                 on i.issuer_id = s.issuer_id
-- Joined on the EFFECTIVE country, or the display name would disagree with the code beside it.
left join market.countries c              on c.iso2 = coalesce(s.provider_country_iso2, s.country_iso2);

notify pgrst, 'reload schema';
