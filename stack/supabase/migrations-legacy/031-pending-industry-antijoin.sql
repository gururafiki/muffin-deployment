-- `pending_industry` could never be satisfied — IDEMPOTENT.
--
-- THE DEFECT. The backlog asked "has a level-1 sector, has no level-2 industry" and expressed the
-- second half as two joins:
--
--     left join market.security_taxonomy ind_st on ind_st.security_id = s.security_id
--     left join market.taxonomy_node     ind_n  on ind_n.node_id = ind_st.node_id
--                                              and ind_n.taxonomy_id = 'muffin'
--                                              and ind_n.level = 2
--     ...
--     where ind_n.node_id is null
--
-- The FIRST join is unrestricted, so it matches every taxonomy row a security has — including the
-- level-1 sector rows the view already required. Each of those then joins `ind_n` (restricted to
-- level 2) as NULL, and `where ind_n.node_id is null` KEEPS it. A `where` filters rows, not
-- securities, so one qualifying row cannot suppress another. Every security with a sector is
-- therefore in this backlog permanently, whether or not it has an industry.
--
-- MEASURED 2026-08-11, on production:
--   * AMZN was written `consumer-discretionary--internet-retail` at 21:41:39 and was STILL returned
--     by `pending_industry` immediately afterwards.
--   * The view reported 7,911 rows before a run and 7,911 after one that reported
--     `classified: 282, capped: 282` — the count did not move by a single row.
--   * 345 securities have an industry, against 8,412 with a sector. `security-industries` takes the
--     top 300 by fund weight per run, so it has re-fetched the SAME 300 names on every run since
--     migration 23 landed and never reached row 301.
--   * `security.market_cap` was populated for 386 of 10,060 for exactly this reason: the cap rides
--     along on the same `equity/profile` response, so it is frozen wherever the backlog is.
--
-- Every OTHER backlog view null-checks the FIRST left-joined table (`pending_profile` on `st`,
-- `pending_fundamentals` on `f`, `pending_local_symbol` on `ps`, `pending_performance` on `p`),
-- which is why they drain and this one did not. The distinguishing feature is a predicate on a
-- SECOND table reached through an unrestricted first join — worth recognising, because the symptom
-- is a resource that reports success and progress forever while writing the same rows.
--
-- THE FIX is an actual anti-join. `not exists` is evaluated per SECURITY, so a single level-2 row
-- removes it from the backlog no matter how many level-1 rows it also carries.

drop view if exists market.pending_industry;
create view market.pending_industry as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  sec_n.code as sector_id,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_taxonomy sec_st on sec_st.security_id = s.security_id
join market.taxonomy_node sec_n
  on sec_n.node_id = sec_st.node_id and sec_n.taxonomy_id = 'muffin' and sec_n.level = 1
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.fund_holding_current h on h.security_id = s.security_id
where not exists (
        select 1
        from market.security_taxonomy ind_st
        join market.taxonomy_node ind_n
          on ind_n.node_id = ind_st.node_id
         and ind_n.taxonomy_id = 'muffin'
         and ind_n.level = 2
        where ind_st.security_id = s.security_id
      )
  and coalesce(ps.symbol, t.value) is not null
  and (s.industry_missing_at is null or s.industry_missing_at < now() - interval '30 days')
group by s.security_id, coalesce(ps.symbol, t.value), sec_n.code
order by best_weight desc;

comment on view market.pending_industry is
  'Securities with a sector but no sub-industry, heaviest fund weight first. The "no industry" half is a not-exists over the SECURITY: expressing it as a left join plus "is null" filters rows rather than securities, and a security keeps qualifying through its own level-1 rows (see 31-pending-industry-antijoin.sql).';

grant select on market.pending_industry to service_role;

notify pgrst, 'reload schema';
