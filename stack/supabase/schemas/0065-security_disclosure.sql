do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_disclosure';
  if k = 'm' then execute 'drop materialized view if exists market.security_disclosure cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_disclosure cascade';
  end if;
end $$;
create view market.security_disclosure as
WITH enabled_source AS MATERIALIZED (
         SELECT disclosure_source.code,
            disclosure_source.priority
           FROM market.disclosure_source
          WHERE disclosure_source.enabled
        ), held AS MATERIALIZED (
         SELECT DISTINCT ON (f.security_id) f.security_id,
            f.source_code,
            f.filer_id
           FROM market.security_filer f
             JOIN enabled_source d ON d.code = f.source_code
          ORDER BY f.security_id, d.priority DESC, f.source_code
        ), by_country AS MATERIALIZED (
         SELECT DISTINCT ON (c.country_iso2) c.country_iso2,
            c.source_code
           FROM market.disclosure_coverage c
             JOIN enabled_source d ON d.code = c.source_code
          ORDER BY c.country_iso2, d.priority DESC, c.source_code
        )
 SELECT s.security_id,
    COALESCE(h.source_code, bc.source_code) AS segment_source,
    h.source_code IS NOT NULL AS filer_id_held,
        CASE
            WHEN h.source_code IS NOT NULL THEN 'held'::text
            WHEN bc.source_code IS NOT NULL THEN 'resolvable'::text
            ELSE 'none'::text
        END AS capability,
    h.filer_id
   FROM market.security s
     LEFT JOIN held h ON h.security_id = s.security_id
     LEFT JOIN by_country bc ON bc.country_iso2 = COALESCE(s.provider_country_iso2, s.country_iso2);
