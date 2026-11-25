do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_segment_alias';
  if k = 'm' then execute 'drop materialized view if exists market.pending_segment_alias cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_segment_alias cascade';
  end if;
end $$;
create view market.pending_segment_alias as
SELECT c.member_code,
    min(c.kind) AS kind,
    count(DISTINCT s.issuer_id) AS issuers,
    count(DISTINCT c.security_id) AS securities,
    max(COALESCE(h.best_weight, 0::numeric)) AS best_weight,
    max(c.revenue_share_pct) AS largest_share_pct,
    max(c.revenue) AS largest_revenue,
    max(c.currency_code) AS a_currency_code,
    min(c.axis) AS an_axis,
    bool_or(c.member_code ~* '(AllOther|CorporateAndOther|OtherSegment|:Other[A-Z]|:OthersMember|Unallocated|Reconcil|Elimination|Intersegment)'::text) AS is_catch_all
   FROM market.security_segment_spine c
     JOIN market.security s ON s.security_id = c.security_id
     LEFT JOIN LATERAL ( SELECT max(fh.weight) AS best_weight
           FROM market.fund_holding_current fh
          WHERE fh.security_id = c.security_id) h ON true
  WHERE c.concept_code IS NULL AND (c.kind = ANY (ARRAY['product'::text, 'business'::text]))
  GROUP BY c.member_code
  ORDER BY (bool_or(c.member_code ~* '(AllOther|CorporateAndOther|OtherSegment|:Other[A-Z]|:OthersMember|Unallocated|Reconcil|Elimination|Intersegment)'::text)), (max(COALESCE(h.best_weight, 0::numeric))) DESC NULLS LAST, (max(c.revenue_share_pct)) DESC NULLS LAST, c.member_code;
