do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'backlog_drain';
  if k = 'm' then execute 'drop materialized view if exists market.backlog_drain cascade';
  elsif k = 'v' then execute 'drop view if exists market.backlog_drain cascade';
  end if;
end $$;
create view market.backlog_drain as
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
  ORDER BY (
        CASE
            WHEN f.samples < 6 THEN 3
            WHEN f.per_day < '-0.01'::numeric::double precision AND COALESCE(c.cache_per_day, 0::double precision) > (0.5::double precision * (- f.per_day)) THEN 0
            WHEN l.depth > 0 AND f.per_day >= '-0.01'::numeric::double precision THEN 1
            ELSE 2
        END), l.depth DESC;
