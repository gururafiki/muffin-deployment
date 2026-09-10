do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_segment_detail';
  if k = 'm' then execute 'drop materialized view if exists market.security_segment_detail cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_segment_detail cascade';
  end if;
end $$;
create view market.security_segment_detail as
WITH newest AS (
         SELECT g.security_id,
            g.parent_axis,
            g.parent_member,
            g.axis,
            max(g.period_ending) AS period_ending
           FROM market.security_segment_latest g
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NOT NULL
          GROUP BY g.security_id, g.parent_axis, g.parent_member, g.axis
        ), latest AS (
         SELECT DISTINCT ON (g.security_id, g.parent_member, g.axis, g.member_code, g.metric_code) g.security_id,
            g.parent_axis,
            g.parent_member,
            g.axis,
            g.member_code,
            g.metric_code,
            g.value,
            g.currency_code,
            g.period_ending
           FROM market.security_segment_latest g
             JOIN newest n ON n.security_id = g.security_id AND NOT n.parent_axis IS DISTINCT FROM g.parent_axis AND n.parent_member = g.parent_member AND n.axis = g.axis AND n.period_ending = g.period_ending
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NOT NULL
          ORDER BY g.security_id, g.parent_member, g.axis, g.member_code, g.metric_code, g.period_ending DESC
        ), pivoted AS (
         SELECT l.security_id,
            l.parent_axis,
            l.parent_member,
            l.axis,
            l.member_code,
            max(l.currency_code) AS currency_code,
            max(l.period_ending) AS period_ending,
            max(l.value) FILTER (WHERE l.metric_code = 'revenue'::text) AS revenue,
            max(l.value) FILTER (WHERE l.metric_code = 'operating_income'::text) AS operating_income
           FROM latest l
          GROUP BY l.security_id, l.parent_axis, l.parent_member, l.axis, l.member_code
        )
 SELECT p.security_id,
    p.parent_axis,
    p.parent_member,
    p.axis,
    p.member_code,
    c.code AS concept_code,
    c.name AS concept_name,
    p.revenue,
    p.operating_income,
    round(100::numeric * p.revenue / NULLIF(sum(p.revenue) OVER (PARTITION BY p.security_id, p.parent_member, p.axis), 0::numeric), 2) AS share_of_parent_pct,
    p.currency_code,
    p.period_ending
   FROM pivoted p
     LEFT JOIN LATERAL ( SELECT al_1.concept_code
           FROM market.segment_alias al_1
          WHERE al_1.member_code = p.member_code AND (al_1.security_id = p.security_id OR al_1.security_id IS NULL)
          ORDER BY (al_1.security_id IS NOT NULL) DESC
         LIMIT 1) al ON true
     LEFT JOIN market.segment_concept c ON c.code = al.concept_code;
