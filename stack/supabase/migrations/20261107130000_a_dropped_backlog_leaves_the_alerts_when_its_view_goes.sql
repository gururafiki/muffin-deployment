-- A DROPPED BACKLOG LEAVES THE ALERTS WHEN ITS VIEW GOES, NOT A DAY LATER.
--
-- Migration 20261031100000 made `backlog_drain` drop a backlog whose newest sample is over a day
-- old, because a `pending_*` view dropped with its resource is no longer sampled. That left the
-- first day. Measured 2026-11-07 06:27 UTC, four hours after Phase 5 step 9 dropped five views
-- (#494, #495):
--   - `muffin-backlog-flat` fired on `pending_eps_history` (309, FLAT, last sampled 02:04), which
--     #495 had just stopped excluding by name. It would have fired until ~02:05 on 11-08.
--   - `muffin-backlog-stalled`, which reads 24 hours of `backlog_sample` directly and has no
--     staleness rule at all, fired on `pending_price_targets` (2,865, spread 0, 20 samples). It
--     needs 8 samples in its window, so it would have fired until ~19:05.
--
-- The sampler's list is `backlogs_to_sample()`: every view or materialized view in `market` named
-- `pending_%`. So "still sampled" means "its view exists", and that is known the moment the view is
-- dropped. Both readers now ask it. The day-old bound stays: a sampler that stops while the views
-- exist is the rule "An observability sample has stopped arriving".
--
-- Same columns in the same order, so the view keeps its grants.
--
-- Guard: stack/supabase/tests/a-flat-backlog-is-named-as-such.sql (the DROPPED case).

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
  WHERE l.sampled_at > (now() - '1 day'::interval) AND to_regclass(format('market.%I', l.backlog)) IS NOT NULL
  ORDER BY (
        CASE
            WHEN f.samples < 6 THEN 3
            WHEN f.per_day < '-0.01'::numeric::double precision AND COALESCE(c.cache_per_day, 0::double precision) > (0.5::double precision * (- f.per_day)) THEN 0
            WHEN l.depth > 0 AND f.per_day >= '-0.01'::numeric::double precision THEN 1
            ELSE 2
        END), l.depth DESC;
