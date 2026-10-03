CREATE OR REPLACE FUNCTION market.derive_classifications()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'public'
AS $function$
declare n integer;
begin
  -- Sector, from the sector SPDRs' current holdings.
  insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
  select h.security_id, tn.node_id, 'sec-nport', h.as_of
  from market.fund_holding_current h
  join market.security_identifier fi
    on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf
    on tf.symbol = fi.value and tf.kind = 'sector' and tf.represents_code is not null
  join market.taxonomy_node tn
    on tn.taxonomy_id = 'muffin' and tn.code = tf.represents_code
  -- A fund holds itself, cash and futures; none of those is a constituent of its own sector.
  join market.security s on s.security_id = h.security_id and s.security_type_code = 'equity'
  where h.security_id <> h.fund_id
  on conflict (security_id, node_id, source_code) do update set as_of = excluded.as_of;
  get diagnostics n = row_count;

  -- Country, from the country ETFs. Written to market.security.country_iso2 only where the filing
  -- did NOT already say — the filing's own invCountry is the better source when present.
  update market.security s
     set country_iso2 = tf.represents_code
  from market.fund_holding_current h
  join market.security_identifier fi
    on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf
    on tf.symbol = fi.value and tf.kind = 'country' and tf.represents_code is not null
  where s.security_id = h.security_id
    and s.country_iso2 is null
    and h.security_id <> h.fund_id;

  return n;
end $function$;
