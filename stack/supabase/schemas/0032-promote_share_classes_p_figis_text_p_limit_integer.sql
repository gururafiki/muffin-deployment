CREATE OR REPLACE FUNCTION market.promote_share_classes(p_figis text[], p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'market', 'pg_catalog'
AS $function$
declare
  v_policy  market.promotion_policy;
  v_limit   integer;
  v_done    integer;
  v_venues  jsonb;
begin
  select * into v_policy from market.promotion_policy where id;
  if v_policy.id is null then
    return jsonb_build_object('promoted', 0, 'reason', 'no promotion policy');
  end if;
  if v_policy.paused then
    return jsonb_build_object('promoted', 0, 'reason', 'paused');
  end if;
  v_limit := greatest(0, least(coalesce(p_limit, 0), v_policy.wave_size));
  if v_limit = 0 then
    return jsonb_build_object('promoted', 0, 'reason', 'no capacity', 'asked', p_limit);
  end if;

  -- THE LINES HANDED IN ARE STILL CHECKED AGAINST THE CANDIDATES, so a class promoted since the
  -- caller chose them, or a line the directory has stopped returning, is skipped rather than
  -- minted twice. THEIR ORDER IS THE WAVE'S: the caller asked the provider in candidate order, and
  -- a line it could not verify is simply absent from the array.
  --
  -- ONE STATEMENT, NO TEMP TABLE. A temp table belongs to whichever role created it, so a second
  -- wave in one session, as another role, cannot drop it (measured in the guard: "must be owner of
  -- table wave"). Data-modifying CTEs run to completion whether or not the outer query reads them,
  -- and the foreign keys are checked at the end of the statement, when every security exists.
  --
  -- ONE CANDIDATE PER PRICE SYMBOL: `security_provider_symbol` is unique on (provider, symbol), and
  -- two rows of one statement claiming one symbol would fail the whole wave.
  with wave as materialized (
    select gen_random_uuid() as security_id, c.*
      from (select distinct on (upper(coalesce(pc.provider_symbol, pc.figi)))
                   pc.*, array_position(p_figis, pc.figi) as position
              from market.promotion_candidate pc
             where pc.figi = any (p_figis)
             order by upper(coalesce(pc.provider_symbol, pc.figi)),
                      array_position(p_figis, pc.figi)) c
     order by c.position
     limit v_limit
  ),
  securities as (
    insert into market.security (security_id, name, security_type_code, country_iso2, is_tradeable)
    select w.security_id, w.name, 'equity', w.country_iso2, true from wave w
    returning security_id
  ),
  identifiers as (
    insert into market.security_identifier (kind_code, value, security_id, source_code)
    select 'share_class_figi', w.share_class_figi, w.security_id, 'openfigi' from wave w
    union all
    select 'figi', coalesce(w.composite_figi, w.figi), w.security_id, 'openfigi' from wave w
    union all
    select 'ticker', upper(w.ticker), w.security_id, 'openfigi' from wave w where w.ticker is not null
    on conflict (kind_code, value) do nothing
    returning 1
  ),
  symbols as (
    insert into market.security_provider_symbol (security_id, provider_code, symbol)
    select w.security_id, 'yfinance', w.provider_symbol from wave w where w.provider_symbol is not null
    on conflict (security_id, provider_code) do nothing
    returning 1
  )
  select (select count(*) from securities),
         coalesce((select jsonb_object_agg(exch_code, n)
                     from (select exch_code, count(*) as n from wave group by exch_code) x), '{}')
    into v_done, v_venues;

  return jsonb_build_object(
    'promoted', v_done,
    'handed', coalesce(cardinality(p_figis), 0),
    'asked', p_limit,
    'wave_size', v_policy.wave_size,
    'by_venue', v_venues,
    'candidates_left', (select count(*) from market.promotion_candidate));
end;
$function$;
