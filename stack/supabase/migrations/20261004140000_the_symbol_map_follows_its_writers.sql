-- The symbol map is rebuilt by those who change what it is built from, and `refresh_facets` keeps
-- only the screener's spine. Stage 2d of the umbrella's
-- docs/specs/2026-09-26-finishing-the-universe-family.md.
--
-- WHY. `market.symbol_security` resolves a symbol to a security for every chart. The edge resource
-- `facets-refresh` rebuilt it every ten minutes beside the screener's spine. Its inputs are written
-- by three Dagster assets (symbology adopts a symbol, the N-PORT lane mints a security, the listing
-- derivation moves a primary) and by one RPC outside Dagster, `promote_listing`. So the refresh
-- belongs with them: the Dagster asset `symbol_security` runs it when one of the three
-- materialises, and the Track button runs it inline, so a security tracked by hand resolves at
-- once.
--
-- MEASURED 2026-10-04 on production: 0.31-0.33 s for 12,402 rows, cheap enough for the Track button.
-- The plan's ten-minute floor in Dagster is therefore not built: its only purpose was the Track
-- button, which now needs none. The asset keeps a daily floor against a writer nobody listed.

create or replace function market.refresh_symbol_map()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'market', 'pg_catalog'
as $function$
declare
  v_started timestamptz := clock_timestamp();
begin
  refresh materialized view concurrently market.symbol_security;
  return jsonb_build_object(
    'rows', (select count(*) from market.symbol_security),
    'duration_ms', round(extract(epoch from clock_timestamp() - v_started) * 1000));
end;
$function$;

revoke all on function market.refresh_symbol_map() from public;
grant execute on function market.refresh_symbol_map() to ingest_rw;

CREATE OR REPLACE FUNCTION market.promote_listing(p_figi text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'public'
AS $function$
declare
  v_claims jsonb;
  v_role text;
  v_listing record;
  v_security_id uuid;
  v_symbol text := null;
begin
  -- THE JWT CLAIMS COME FROM PostgREST's GUC, read directly rather than through auth.jwt() so the
  -- function does not depend on the Supabase auth schema (which a migration harness may lack).
  -- `app_metadata.role` is the ONE place a role cannot be self-assigned (user_metadata is writable
  -- through the ordinary auth API); the edge function enforces the same check on the same field.
  v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
  v_role := v_claims #>> '{app_metadata,role}';
  -- WRITTEN POSITIVELY AND COALESCED, the falsy-NULL gate this schema has paid for once: with no
  -- JWT at all, `v_role` is NULL and `NULL <> 'admin'` is NULL, so the obvious negation lets the
  -- gate FAIL OPEN — an unauthenticated caller would promote anything.
  if not coalesce(v_role = 'admin' or (v_claims #> '{app_metadata,roles}' ? 'admin'), false) then
    return jsonb_build_object('promoted', false, 'reason', 'admins only');
  end if;

  if p_figi is null or length(trim(p_figi)) = 0 then
    return jsonb_build_object('promoted', false, 'reason', 'a figi is required');
  end if;

  -- Already ours is a SUCCESS (a no-op), not an error — two people tapping the same row must not
  -- fail for the second one.
  if exists (select 1 from market.security_identifier
              where kind_code = 'figi' and value = p_figi) then
    return jsonb_build_object('figi', p_figi, 'promoted', false, 'reason', 'already tracked');
  end if;

  select * into v_listing from market.venue_listing where figi = p_figi;
  if v_listing.figi is null then
    -- NOT IN THE DIRECTORY, AND THERE IS NO FALLBACK ANY MORE. The discovery sweep must have
    -- reached the listing first; telling the caller honestly beats inventing a security from a
    -- ticker that might mean a different company in a different venue.
    return jsonb_build_object('figi', p_figi, 'promoted', false,
                              'reason', 'unknown figi — the venue sweep has not catalogued it');
  end if;

  -- A LINE THE DIRECTORY STOPPED RETURNING IS NOT OFFERED, so it cannot be tracked by hand either:
  -- minting a security for a delisted company spends a month of provider calls on nothing.
  if v_listing.absent_since is not null then
    return jsonb_build_object('figi', p_figi, 'promoted', false,
                              'reason', 'the venue directory has not returned this listing since '
                                        || to_char(v_listing.absent_since, 'YYYY-MM-DD'));
  end if;

  v_security_id := gen_random_uuid();

  insert into market.security (security_id, name, security_type_code, country_iso2, is_tradeable)
  values (v_security_id, v_listing.name, 'equity', v_listing.country_iso2, true);

  -- FIGI first, because it is what stops this listing being offered as untracked again. A row's
  -- `composite_figi` can be NULL (a listing with no composite), in which case its own FIGI holds —
  -- the edge handler coalesced the same way.
  insert into market.security_identifier (kind_code, value, security_id, source_code)
  values ('figi', coalesce(v_listing.composite_figi, p_figi), v_security_id, 'openfigi'),
         ('ticker', upper(v_listing.ticker), v_security_id, 'openfigi')
  on conflict (kind_code, value) do nothing;

  if v_listing.provider_symbol is not null then
    insert into market.security_provider_symbol (security_id, provider_code, symbol)
    values (v_security_id, 'yfinance', v_listing.provider_symbol)
    on conflict (security_id, provider_code) do nothing;
    v_symbol := v_listing.provider_symbol;
  else
    v_symbol := v_listing.ticker;
  end if;

  -- THE ONE WRITER OF THE SYMBOL MAP'S INPUTS OUTSIDE DAGSTER refreshes it itself, so the security
  -- a person just tracked resolves on its own page at once rather than at the next tick.
  perform market.refresh_symbol_map();

  return jsonb_build_object(
    'figi', p_figi,
    'promoted', true,
    'securityId', v_security_id,
    'symbol', v_symbol,
    'note', 'the sector arrives on the next security-profiles run; prices and returns on the price lane''s history pass'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION market.refresh_facets()
 RETURNS TABLE(rows_refreshed bigint, refreshed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog'
AS $function$
begin
  -- THE SYMBOL MAP IS NOT REFRESHED HERE SINCE 2026-10-04. Its inputs are written by Dagster and by
  -- the Track button, which refresh it through `refresh_symbol_map`; this keeps the screener's spine.
  refresh materialized view concurrently market.security_facets;
  return query
    select count(*)::bigint, max(f.refreshed_at) from market.security_facets f;
end;
$function$;
