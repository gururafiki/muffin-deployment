-- Step 6, first half: promotion moves off the edge function onto the database, and the search
-- reads the new directory.
--
-- WHY NOW. Steps 4-5 built the Dagster lanes that populate `venue_listing` (the raw OpenFIGI
-- directory, beside the old `exchange_listing`) and resolve identifiers. This file re-points the
-- consumer seams onto them: `untracked_listing` becomes a view over `venue_listing` (same columns,
-- so the Markets search changes nothing), and `promote_listing` becomes a Postgres RPC that reads
-- the DIRECTORY — dropping the edge handler's OpenFIGI fallback, which is the half that made the
-- handler large. Promotion from a listing we already hold needs no provider call at all.

-- ── 1. untracked_listing reads the new directory ────────────────────────────────────────────────
--
-- SAME COLUMNS, SAME EXCLUSIONS — the search's `untracked_listing` source keeps its contract
-- while its base becomes the table the discovery sweep writes. Re-pointed because a duplicate view
-- of the same shape would drift, and step 7 drops `exchange_listing`.
create or replace view market.untracked_listing as
select figi,
       composite_figi,
       exch_code,
       ticker,
       name,
       country_iso2,
       provider_symbol
  from market.venue_listing l
 where name is not null
   and not exists (select 1 from market.security_identifier si
                    where si.kind_code = 'figi' and si.value = l.composite_figi)
   and not exists (select 1 from market.security_provider_symbol ps
                    where upper(ps.symbol) = upper(l.provider_symbol))
   and not exists (select 1 from market.security_identifier ti
                    where ti.kind_code = 'ticker' and upper(ti.value) = upper(l.provider_symbol));

-- ── 2. promote_listing: the RPC, without the OpenFIGI fallback ───────────────────────────────────
--
-- SECURITY DEFINER BECAUSE THE CALLER IS A USER, not a service key: the UI's Track button runs as
-- the signed-in admin's JWT, and no `market` table allows a user to insert. Running as the owner
-- gives the function the writer's privilege and makes RLS irrelevant — so the ADMIN GATE MUST live
-- inside, read from `app_metadata.role` (the one place a role cannot be self-assigned; the edge
-- function enforces the same check on the same field, and this file ports it).
--
-- DROPS THE FALLBACK DELIBERATELY: the old handler built a security from `/v3/mapping` when the
-- sweep had not reached the listing. That is the half that made the handler large, and with the
-- discovery sweep now populating `venue_listing` the directory route is the honest one — a listing
-- we have not catalogued cannot be promoted, and a person is watching either way.
create or replace function market.promote_listing(p_figi text)
returns jsonb
language plpgsql
security definer
set search_path = market, public
as $$
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

  return jsonb_build_object(
    'figi', p_figi,
    'promoted', true,
    'securityId', v_security_id,
    'symbol', v_symbol,
    'note', 'sector and returns arrive on the next security-profiles / security-performance run'
  );
end;
$$;

comment on function market.promote_listing(text) is
  'Adopt an untracked venue listing into the universe. Admin-only (the JWT''s app_metadata.role '
  'must be admin), reads venue_listing, creates the security and its figi/ticker identifiers. The '
  'edge handler''s OpenFIGI fallback is deliberately gone: promotion from a listing we already hold '
  'needs no provider call.';

revoke execute on function market.promote_listing(text) from public;
grant execute on function market.promote_listing(text) to anon, authenticated, service_role;
