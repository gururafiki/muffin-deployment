-- A BACKLOG THAT NO LONGER EXISTS LEAVES THE DRAIN VIEW THE DAY IT STOPS BEING SAMPLED.
--
-- `market.backlog_drain` fits a slope over the last seven days of `backlog_sample`. A `pending_*`
-- view dropped when its resource retires is no longer sampled, so its last samples stay in the
-- window, the slope over them is zero, and the view calls it FLAT for up to a week. Measured
-- 2026-10-31: `muffin-backlog-flat` had fired since 10-29 02:00 on `pending_fundamentals` (103,
-- dropped by #461, last sampled 10-24 21:04) and `pending_corporate_actions` (1,035, dropped by
-- #464, last sampled 10-25 19:04). Phase 5 step 9 retires four more edge backlogs, and each would
-- fire it again for a week on a queue nothing is meant to drain.
--
-- A backlog is reported only while it is still sampled: its newest sample is under a day old.
-- `sample_backlogs` writes every backlog sixteen times a day, so a day is ample. A sampler that stops
-- altogether is the rule "An observability sample has stopped arriving", which reads the samples'
-- own age.
--
-- Same columns in the same order, so the view keeps its grants.
--
-- Guard: stack/supabase/tests/a-flat-backlog-is-named-as-such.sql (the RETIRED case).

create or replace view market.backlog_drain as
WITH obs AS (
         SELECT backlog_sample.backlog,
            backlog_sample.sampled_at,
            backlog_sample.depth
           FROM market.backlog_sample
          WHERE backlog_sample.sampled_at > (now() - '7 days'::interval) AND backlog_sample.error IS NULL AND backlog_sample.depth IS NOT NULL
        ), fit AS (
         SELECT obs.backlog,
            count(*) AS samples,
            regr_slope(obs.depth::double precision, (EXTRACT(epoch FROM obs.sampled_at) / 86400.0)::double precision) AS per_day
           FROM obs
          GROUP BY obs.backlog
        ), latest AS (
         SELECT DISTINCT ON (obs.backlog) obs.backlog,
            obs.depth,
            obs.sampled_at
           FROM obs
          ORDER BY obs.backlog, obs.sampled_at DESC
        ), cache AS (
         SELECT p.backlog,
            regr_slope(u.value::double precision, (EXTRACT(epoch FROM u.sampled_at) / 86400.0)::double precision) AS cache_per_day
           FROM market.backlog_negative_cache p
             JOIN market.universe_sample u ON u.metric = ('missing.security.'::text || p.missing_column) AND u.sampled_at > (now() - '7 days'::interval)
          WHERE p.missing_column IS NOT NULL
          GROUP BY p.backlog
        )
 SELECT l.backlog,
    l.depth,
    l.sampled_at AS measured_at,
    f.samples,
    round(f.per_day::numeric, 1) AS per_day,
    round(COALESCE(c.cache_per_day, 0::double precision)::numeric, 1) AS cache_per_day,
        CASE
            WHEN f.per_day < '-0.01'::numeric::double precision AND l.depth > 0 THEN round((l.depth::double precision / (- f.per_day))::numeric, 1)
            ELSE NULL::numeric
        END AS days_to_empty,
        CASE
            WHEN f.samples < 6 THEN 'insufficient_history'::text
            WHEN l.depth = 0 THEN 'empty'::text
            WHEN f.per_day < '-0.01'::numeric::double precision AND COALESCE(c.cache_per_day, 0::double precision) > (0.5::double precision * (- f.per_day)) THEN 'draining_by_marking'::text
            WHEN f.per_day < '-0.01'::numeric::double precision THEN 'draining'::text
            WHEN f.per_day > 0.01::double precision THEN 'growing'::text
            ELSE 'FLAT'::text
        END AS state
   FROM latest l
     JOIN fit f USING (backlog)
     LEFT JOIN cache c USING (backlog)
  WHERE l.sampled_at > (now() - '1 day'::interval)
  ORDER BY (
        CASE
            WHEN f.samples < 6 THEN 3
            WHEN f.per_day < '-0.01'::numeric::double precision AND COALESCE(c.cache_per_day, 0::double precision) > (0.5::double precision * (- f.per_day)) THEN 0
            WHEN l.depth > 0 AND f.per_day >= '-0.01'::numeric::double precision THEN 1
            ELSE 2
        END), l.depth DESC;
