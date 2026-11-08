do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_segment_latest';
  if k = 'm' then execute 'drop materialized view if exists market.security_segment_latest cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_segment_latest cascade';
  end if;
end $$;
create view market.security_segment_latest as
WITH ranked AS (
         SELECT g.security_id,
            g.axis,
            g.member_code,
            g.metric_code,
            g.period_type,
            g.period_ending,
            g.period_start,
            g.value,
            g.currency_code,
            g.partition_id,
            g.accession_number,
            g.source_code,
            g.as_of,
            g.reconciled_to,
            g.parent_axis,
            g.parent_member,
            g.parent_key,
            f.filing_date,
            dense_rank() OVER (PARTITION BY g.security_id, g.axis, g.metric_code, g.period_type, g.period_ending ORDER BY f.filing_date DESC NULLS LAST, g.accession_number DESC) AS filing_rank
           FROM market.security_segment g
             LEFT JOIN market.security_filing f ON f.security_id = g.security_id AND f.accession_number = g.accession_number
        )
 SELECT security_id,
    axis,
    member_code,
    parent_axis,
    parent_member,
    metric_code,
    period_type,
    period_ending,
    period_start,
    value,
    currency_code,
    partition_id,
    reconciled_to,
    accession_number,
    filing_date,
    source_code,
    as_of
   FROM ranked
  WHERE filing_rank = 1;
