-- COMPLETENESS FOR ONE SECURITY, which `coverage_current` structurally cannot answer.
--
-- `coverage_current` computes exactly the right thing and computes it for the WHOLE UNIVERSE: its
-- `base` CTE is declared `as materialized` on purpose, because it is referenced once per dimension
-- and PostgreSQL 12+ would otherwise inline and re-run it ten times. That hint is also a wall — a
-- filter on one `security_id` cannot be pushed through it, so asking "what is missing for THIS
-- company" would pay the entire 743 ms aggregate on every stock page.
--
-- Refactoring `coverage_current` to serve both was considered and rejected for now: it is a tuned
-- view read by Grafana and sampled twice daily, its cost profile cannot be measured until it is
-- deployed, and the unpivot it would have to materialise is 27,629 securities x 23 facets rather
-- than 27,629 rows. Changing a plan I cannot measure, at the end of the change that also rewrote
-- the segment views, is not a trade worth making.
--
-- So the presence rules exist twice, and the honest mitigation is that DRIFT IS DETECTABLE rather
-- than merely deprecated: `tests/completeness-agrees-with-coverage.sql` asserts this view and
-- `coverage_current` report the same totals, so the two cannot disagree silently. That is the same
-- bargain migration 137 struck for suffix->venue, which lives in both SQL and TypeScript and is
-- asserted on both sides.
--
-- WHAT IS SHARED RATHER THAN COPIED: the facet list's APPLICABILITY (`segment_capable`, from
-- `security_disclosure.capability`) and `required_facet`, the control table that says what a
-- security type owes. Those are the editorial decisions; the presence expressions are mechanical.
--
-- `exists`, not `select distinct ... left join`. Both are correct and mean the same thing; the
-- anti-join form is what makes a single-security filter an index lookup instead of a scan of
-- `security_price`, `security_statement` and `security_segment_spine`.
drop view if exists market.security_facet_status;
create view market.security_facet_status as
with b as (
  select
    f.security_id,
    f.security_type_code,
    f.symbol,
    (f.symbol        is not null) as has_symbol,
    (f.sector_id     is not null) as has_sector,
    (f.industry_code is not null) as has_industry,
    -- "Priced" is a bar in the last 30 days, not a bar ever: a security whose newest close is two
    -- years old is not covered in any useful sense.
    exists (select 1 from market.security_price p
             where p.security_id = f.security_id and p.date > current_date - 30)    as has_price,
    -- ON SYMBOL. `performance` is keyed `scope_id` holding a symbol, not a security_id — joining
    -- it the obvious way reports 0% for the entire universe (migration 164's trap 1).
    exists (select 1 from market.performance pf
             where pf.scope = 'instrument' and pf.scope_id = f.symbol)              as has_performance,
    exists (select 1 from market.security_profile x     where x.security_id = f.security_id) as has_profile,
    exists (select 1 from market.security_fundamentals x where x.security_id = f.security_id) as has_fundamentals,
    exists (select 1 from market.security_statement x   where x.security_id = f.security_id) as has_statements,
    exists (select 1 from market.security_metric x      where x.security_id = f.security_id) as has_metrics,
    (s.price_history_from is not null) as has_price_history,
    (s.daily_history_from is not null) as has_daily_history,
    exists (select 1 from market.news_security x        where x.security_id = f.security_id) as has_news,
    exists (select 1 from market.security_officer x     where x.security_id = f.security_id) as has_leadership,
    exists (select 1 from market.insider_trade x        where x.security_id = f.security_id) as has_insider,
    exists (select 1 from market.security_filing x      where x.security_id = f.security_id) as has_filings,
    exists (select 1 from market.security_corporate_action x
             where x.security_id = f.security_id and x.kind = 'dividend')           as has_dividends,
    exists (select 1 from market.security_share_stats x where x.security_id = f.security_id) as has_share_stats,
    exists (select 1 from market.security_estimate x    where x.security_id = f.security_id) as has_estimates,
    exists (select 1 from market.security_statement x
             where x.security_id = f.security_id and x.period_type = 'quarter')     as has_quarters,
    (s.sic is not null) as has_sic,
    -- CAPABILITY, NOT COUNTRY. A segment facet is applicable only where some regulator can serve
    -- the security — charging a Cayman shell for a business line it can never have is the
    -- ETF/`price` miscalibration that made 74 funds read 0%.
    (sd.capability = 'held') as segment_capable,
    -- FROM THE SPINE, not the fact table: one row per (security, axis, member) rather than per
    -- filing x period x metric, and it counts a READABLE breakdown rather than a row somewhere.
    exists (select 1 from market.security_segment_spine x
             where x.security_id = f.security_id)                                   as has_segments,
    exists (select 1 from market.security_segment_spine x
             where x.security_id = f.security_id and x.kind = 'geography')          as has_segment_geography,
    exists (select 1 from market.security_taxonomy x
             where x.security_id = f.security_id
               and x.source_code in ('segment-revenue', 'segment-profit'))          as has_weighted_industry
  from market.security_facets f
  left join market.security s            on s.security_id  = f.security_id
  left join market.security_disclosure sd on sd.security_id = f.security_id
)
select
  b.security_id,
  b.security_type_code,
  x.facet,
  x.present,
  x.applicable,
  -- REQUIRED IS A CONTROL TABLE, NOT A LIST HERE. What a security type owes is editorial and
  -- editable in Studio; a bond arrives from an N-PORT filing and that is all it will ever be, so
  -- one flat definition would report 55% of the universe permanently broken.
  coalesce(rf.required, false) as required
from b
cross join lateral (values
  ('symbol',            b.has_symbol,            true),
  ('sector',            b.has_sector,            true),
  ('industry',          b.has_industry,          true),
  ('price',             b.has_price,             true),
  ('performance',       b.has_performance,       true),
  ('profile',           b.has_profile,           true),
  ('fundamentals',      b.has_fundamentals,      true),
  ('statements',        b.has_statements,        true),
  ('metrics',           b.has_metrics,           true),
  ('price_history',     b.has_price_history,     true),
  ('daily_history',     b.has_daily_history,     true),
  ('news',              b.has_news,              true),
  ('leadership',        b.has_leadership,        true),
  ('insider',           b.has_insider,           true),
  ('filings',           b.has_filings,           true),
  ('dividends',         b.has_dividends,         true),
  ('share_stats',       b.has_share_stats,       true),
  ('estimates',         b.has_estimates,         true),
  ('quarters',          b.has_quarters,          true),
  ('sic',               b.has_sic,               b.segment_capable),
  ('segments',          b.has_segments,          b.segment_capable),
  ('segment_geography', b.has_segment_geography, b.segment_capable),
  ('weighted_industry', b.has_weighted_industry, b.segment_capable)
) as x(facet, present, applicable)
left join market.required_facet rf
       on rf.security_type_code = b.security_type_code and rf.facet = x.facet;

comment on view market.security_facet_status is
  'What one security has and what it owes, one row per facet. `coverage_current` answers the same question for the whole universe and cannot be filtered to one security — its `base` CTE is `as materialized`, which is load-bearing for the aggregate and a wall for a per-security read. The presence rules therefore exist twice and `tests/completeness-agrees-with-coverage.sql` asserts the two agree, so drift is detectable rather than merely deprecated. `applicable` is false where no regulator can serve the security; `required` comes from the `required_facet` control table, so what a type owes stays editable.';

grant select on market.security_facet_status to anon, authenticated, service_role;

notify pgrst, 'reload schema';
