-- ONE FISCAL PERIOD IS SERVED ONCE, AND A FILING'S KIND COMES FROM ITS FORM. Phase 5 step 2a, second
-- half, of the umbrella's docs/specs/2026-10-24-sec-family.md. Lands before step 2b, which lets two
-- providers hold one period.
--
-- 1. `security_statement_current` PICKS. Under today's key it never had to: one row per (security,
--    statement, period end, period type). From 2b a SEC row and a Yahoo row can hold one period,
--    and they rarely share a date (SEC dates a 52/53-week quarter by its last day, Yahoo by the
--    month end), so the period is identified by its FISCAL LABEL where it has one and by its end
--    date where it does not. The row served is the highest-priority source's, then the newest.
--    The DISTINCT ON key LEADS WITH THE SYMBOL, so the app's `symbol=eq.` filter is pushed below
--    it, as in `security_metric_series` (tests/a-one-symbol-statements-read-reads-one-security.sql
--    counts the rows the read touches). `fiscal_year` and `fiscal_period` are appended.
--    Until a security is labelled, two providers' rows for one period at different dates are both
--    served. Both lanes label every row of a security in the same step that writes it.
--
-- 2. `security_metric_series` KEEPS A FISCAL PERIOD IN ONE CLUSTER. Rows within 7 days already
--    cluster as one period; a row carrying the same fiscal label as the row before it now joins its
--    cluster however far apart the dates are. Labels are appended.
--
-- 3. `security_recent_filings` TAKES `kind` FROM `market.filing_form` (migration 20261025100300)
--    instead of a CASE that named eight forms. Measured 2026-10-24, that moves 1,357 filings out of
--    "event": 1,345 40-F and 10 10-KT become annual, 2 10-QT interim. Every other kind is unchanged.
--    Filings are matched against SEC's forms, as the CASE did: which regulator a filing reports to
--    is not yet a column (the open question in the spec's As built).
--
-- Columns are unchanged or appended, so `create or replace` keeps every grant.
--
-- Guard: stack/supabase/tests/one-fiscal-period-is-served-once.sql.

create or replace view market.security_statement_current as
select distinct on (sym.symbol, st.security_id, st.statement, st.period_type,
                    coalesce(st.fiscal_year::text || st.fiscal_period, st.period_ending::text))
       sym.symbol,
       st.security_id,
       st.statement,
       st.period_ending,
       st.period_type,
       st.currency,
       st.data,
       st.source_code,
       st.as_of,
       st.derived_at,
       s.currency_code,
       coalesce(s.provider_country_iso2, s.country_iso2) as country_iso2,
       case
         when st.currency is not null then st.currency
         when s.currency_code is null then null::text
         when s.currency_code <> 'USD'::text then s.currency_code
         when coalesce(s.provider_country_iso2, s.country_iso2) = 'US'::text then s.currency_code
         else null::text
       end as reporting_currency,
       st.fiscal_year,
       st.fiscal_period
  from market.security_statement st
  join market.symbol_security sym on sym.security_id = st.security_id
  join market.security s on s.security_id = st.security_id
  join market.data_source ds on ds.code = st.source_code
 order by sym.symbol, st.security_id, st.statement, st.period_type,
          coalesce(st.fiscal_year::text || st.fiscal_period, st.period_ending::text),
          ds.priority desc, st.as_of desc;

create or replace view market.security_metric_series as
with gapped as (
  select sm.security_id,
         sym.symbol,
         sm.metric_code,
         sm.period_type,
         sm.as_of,
         sm.value,
         sm.currency_code,
         sm.source_code,
         ds.priority,
         sm.fiscal_year,
         sm.fiscal_period,
         case
           when (sm.as_of - lag(sm.as_of) over p) <= 7 then 0
           -- The same fiscal period, dated far apart by two providers or a recast.
           when sm.fiscal_period is not null
            and sm.fiscal_year = lag(sm.fiscal_year) over p
            and sm.fiscal_period = lag(sm.fiscal_period) over p then 0
           else 1
         end as starts_cluster
    from market.security_metric sm
    join market.data_source ds on ds.code = sm.source_code
    join market.symbol_security sym on sym.security_id = sm.security_id
  window p as (partition by sym.symbol, sm.security_id, sm.period_type order by sm.as_of)
), clustered as (
  select g.security_id,
         g.symbol,
         g.metric_code,
         g.period_type,
         g.as_of,
         g.value,
         g.currency_code,
         g.source_code,
         g.priority,
         g.fiscal_year,
         g.fiscal_period,
         sum(g.starts_cluster) over (partition by g.symbol, g.security_id, g.period_type order by g.as_of) as period_group,
         count(*) over (partition by g.symbol, g.security_id, g.period_type, g.priority, g.as_of) as rows_on_date
    from gapped g
), anchored as (
  select c.security_id,
         c.symbol,
         c.metric_code,
         c.period_type,
         c.as_of,
         c.value,
         c.currency_code,
         c.source_code,
         c.priority,
         c.fiscal_year,
         c.fiscal_period,
         c.period_group,
         first_value(c.as_of) over (partition by c.symbol, c.security_id, c.period_type, c.period_group
                                    order by c.priority desc, c.rows_on_date desc, c.as_of desc) as period_as_of
    from clustered c
)
select distinct on (a.symbol, a.security_id, a.metric_code, a.period_type, a.period_group)
       a.symbol,
       a.security_id,
       a.metric_code,
       m.name as metric_name,
       m.category,
       m.unit,
       m.is_derived,
       a.period_type,
       a.period_as_of as as_of,
       a.value,
       coalesce(a.currency_code, s.reporting_currency) as currency_code,
       a.source_code,
       a.fiscal_year,
       a.fiscal_period
  from anchored a
  join market.metric m on m.code = a.metric_code
  join market.security s on s.security_id = a.security_id
 order by a.symbol, a.security_id, a.metric_code, a.period_type, a.period_group, a.priority desc,
          (a.as_of = a.period_as_of) desc, a.as_of desc;

create or replace view market.security_recent_filings as
select f.security_id,
       f.accession_number,
       f.filing_date,
       f.report_date,
       f.report_type,
       f.report_url,
       f.filing_detail_url,
       case
         when ff.kind = 'accounts' and ff.is_annual then 'annual'::text
         when ff.kind = 'accounts' then 'interim'::text
         else 'event'::text
       end as kind
  from market.security_filing f
  left join market.filing_form ff on ff.source_code = 'sec' and ff.form_code = f.report_type;
