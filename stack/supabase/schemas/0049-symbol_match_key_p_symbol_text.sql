CREATE OR REPLACE FUNCTION market.symbol_match_key(p_symbol text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
 SET search_path TO 'pg_catalog'
AS $function$
  -- The key two spellings of ONE line share. Bloomberg and Yahoo disagree on class separators
  -- (`BRK/B` and `BRK-B`, `VESTA*` and `VESTA`), and Yahoo pads a Hong Kong code to four digits.
  -- The venue suffix after the last dot is compared as it is. Compare only within one security's
  -- own lines: this is a matching key, never a spelling to adopt.
  select upper(case when b ~ '^[0-9]+$' then coalesce(nullif(ltrim(b, '0'), ''), '0') else b end)
         || upper(s)
    from (select regexp_replace(coalesce(substring(p_symbol from '^(.*)\.[^.]*$'), p_symbol),
                                '[-/*. ]', '', 'g') as b,
                 coalesce(substring(p_symbol from '(\.[^.]*)$'), '') as s) parts
$function$;
