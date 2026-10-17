-- A PERIOD TWO SOURCES REPORT HAS ONE DATE, SO A QUARTER IS ONE COLUMN.
--
-- WHY. SEC dates a period by its last day and Yahoo by the month end, so for a company on a
-- 52/53-week calendar the same quarter arrives twice, days apart (Apple: 2026-06-27 and
-- 2026-06-30). `security_metric_series` already collapsed the pair, but PER METRIC: each metric
-- kept its own highest-priority row's date. SEC states revenue and operating income for the quarter
-- and Yahoo alone states R&D and gross profit, so revenue sat on 06-27 and R&D on 06-30. The stock
-- page pivots its statement table on the date, so every quarter became two half-empty columns.
--   * MEASURED 2026-10-17. Apple's quarterly tab showed four columns headed 2026, with the figures
--     alternating between them, after the company lane's live subset wrote Yahoo quarters for it.
--     ATROB, WOLF and MMED had looked like that since the edge's Yahoo quarters in 2025.
--   * With the lane scheduled, every 52/53-week filer it visits would join them.
--
-- DECIDED 2026-10-17 (Phase 4 decision 21): align in the view. Dates now cluster across ALL of a
-- period's metrics: the same 7-day rule, partitioned by security and period type instead of by
-- metric. Every metric in a cluster is reported at one date, the highest-priority source's, which
-- is the rule each metric already followed alone. A quarter only Yahoo reports keeps Yahoo's date,
-- and two periods 40 days apart stay two, as before.
--
-- ON A PRIORITY TIE, THE DATE MOST OF THAT SOURCE'S ROWS SIT ON, NOT THE LATER ONE. Measured on
-- production before shipping: SEC states a few opening balances on the day AFTER a fiscal year end
-- when a new standard takes effect (IFRS 9/15/16, 2017-2019). "The later date" would have moved
-- SAP's whole FY2016 to 2017-01-01, Toyota's FY2019 to 2019-04-01 and two Vodafone years likewise:
-- the statement table would head them with the wrong year. The period end is where most rows sit.
-- And a metric stated on both days takes its row AT the period's date, so a restated opening
-- balance is not served as the year-end one. Otherwise each metric's value is its own
-- highest-priority row, the later on a tie, as before.
--
-- PUSHDOWN. Every window still partitions by symbol and security first, so a read for one stock
-- computes over that stock's rows alone. A metric filter no longer passes the windows, which means
-- the date a metric is served at does not depend on which other metrics were asked for. The cost is
-- one security's rows; anon latency is re-measured after the deploy.
--
-- Same columns in the same order, so `create or replace` keeps the grants. Guarded by the second
-- block of tests/one-fiscal-period-is-one-point.sql.

create or replace view market.security_metric_series as
WITH gapped AS (
         SELECT sm.security_id,
            sym.symbol,
            sm.metric_code,
            sm.period_type,
            sm.as_of,
            sm.value,
            sm.currency_code,
            sm.source_code,
            ds.priority,
                CASE
                    WHEN (sm.as_of - lag(sm.as_of) OVER (PARTITION BY sym.symbol, sm.security_id, sm.period_type ORDER BY sm.as_of)) <= 7 THEN 0
                    ELSE 1
                END AS starts_cluster
           FROM market.security_metric sm
             JOIN market.data_source ds ON ds.code = sm.source_code
             JOIN market.symbol_security sym ON sym.security_id = sm.security_id
        ), clustered AS (
         SELECT g.security_id,
            g.symbol,
            g.metric_code,
            g.period_type,
            g.as_of,
            g.value,
            g.currency_code,
            g.source_code,
            g.priority,
            sum(g.starts_cluster) OVER (PARTITION BY g.symbol, g.security_id, g.period_type ORDER BY g.as_of) AS period_group,
            count(*) OVER (PARTITION BY g.symbol, g.security_id, g.period_type, g.priority, g.as_of) AS rows_on_date
           FROM gapped g
        ), anchored AS (
         SELECT c.security_id,
            c.symbol,
            c.metric_code,
            c.period_type,
            c.as_of,
            c.value,
            c.currency_code,
            c.source_code,
            c.priority,
            c.period_group,
            first_value(c.as_of) OVER (PARTITION BY c.symbol, c.security_id, c.period_type, c.period_group ORDER BY c.priority DESC, c.rows_on_date DESC, c.as_of DESC) AS period_as_of
           FROM clustered c
        )
 SELECT DISTINCT ON (a.symbol, a.security_id, a.metric_code, a.period_type, a.period_group) a.symbol,
    a.security_id,
    a.metric_code,
    m.name AS metric_name,
    m.category,
    m.unit,
    m.is_derived,
    a.period_type,
    a.period_as_of AS as_of,
    a.value,
    COALESCE(a.currency_code, s.reporting_currency) AS currency_code,
    a.source_code
   FROM anchored a
     JOIN market.metric m ON m.code = a.metric_code
     JOIN market.security s ON s.security_id = a.security_id
  ORDER BY a.symbol, a.security_id, a.metric_code, a.period_type, a.period_group, a.priority DESC, (a.as_of = a.period_as_of) DESC, a.as_of DESC;
