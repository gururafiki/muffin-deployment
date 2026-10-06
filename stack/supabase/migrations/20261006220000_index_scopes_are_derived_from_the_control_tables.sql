-- THE INDEX SCOPES, DERIVED FROM THE TABLES THAT DEFINE THEM, SO A REBUILT DATABASE HAS THEM TOO.
--
-- WHY. `market.index_scope` is what the Dagster indices lane reads to know what to compute
-- (`muffin_ingest.facets.indices.PROXIED_SCOPES`), and nothing writes it but migration
-- 20260910220000, which seeded it from the OLD `market.performance` table: the scopes the running
-- system had been measuring. Production got its 73 that way. A database built from the repo has no
-- performance rows, so it gets none, and the indices lane then succeeds every night while
-- publishing nothing. That migration's comment says "the assets re-assert them"; they do not —
-- the lane only reads the table.
--
-- WHAT. The same 73, derived from the control tables that define them rather than from what was
-- once measured:
--
--   * a COUNTRY scope for each country with a proxy ETF (`countries.etf_symbol`): 45;
--   * a GROUP scope for each classification group with a proxy ETF whose fund is not retired: 17.
--     The frontier groups are excluded because their fund, FM, is `enabled = false` in
--     `tracked_fund` (no N-PORT since 2024-11-30) — the same test `PROXIED_SCOPES` applies;
--   * a SECTOR scope for each of the 11 sectors (`market.sectors`), whose returns come from finviz.
--
-- Codes, labels and sources follow 20260910220000's rule exactly (a label is the country's name, or
-- otherwise the scope id). Measured on production 2026-10-06: this derivation returns all 73 rows
-- production holds, in all five columns, and no other. So on production it inserts nothing, and a
-- rebuild gets what production has.
--
-- ONCE, AS A MIGRATION. A country or group gaining an ETF later still gets no scope by itself;
-- that was true before this file and is recorded as its own follow-up.

insert into market.index_scope (index_code, scope_kind, label, country_iso2, source_code)
select 'country:' || c.iso2, 'country', c.name, c.iso2, 'yfinance'
  from market.countries c
 where c.etf_symbol is not null
union
select 'group:' || g.scheme_id || ':' || g.id, 'group', g.scheme_id || ':' || g.id, null, 'yfinance'
  from market.classification_groups g
  left join market.tracked_fund tf on tf.symbol = g.etf
 where g.etf is not null
   and coalesce(tf.enabled, true)
union
select 'sector:' || s.id, 'sector', s.id, null, 'finviz'
  from market.sectors s
on conflict (index_code) do nothing;
