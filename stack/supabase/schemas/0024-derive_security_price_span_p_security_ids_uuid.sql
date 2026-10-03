CREATE OR REPLACE FUNCTION market.derive_security_price_span(p_security_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  v_asked   integer;
  v_written integer;
  v_empty   integer;
begin
  -- DISTINCT, because an upsert that meets one key twice fails the whole statement (SQLSTATE
  -- 21000), and a caller assembling ids from several materialisations can repeat one. And only
  -- securities that exist: an id deleted since its partition ran would otherwise fail the foreign
  -- key and take the batch with it.
  with asked as (
    select distinct a.id as security_id
      from unnest(p_security_ids) as a(id)
     where exists (select 1 from market.security s where s.security_id = a.id)
  ),
  -- Two index probes per security, not a scan: the primary key is (security_id, trade_date) in
  -- every yearly partition, so each end is a `limit 1` down that index.
  span as (
    select a.security_id, f.trade_date as first_date, l.trade_date as last_date
      from asked a
      left join lateral (select b.trade_date from market.price_bar b
                          where b.security_id = a.security_id
                          order by b.trade_date limit 1) f on true
      left join lateral (select b.trade_date from market.price_bar b
                          where b.security_id = a.security_id
                          order by b.trade_date desc limit 1) l on true
  ),
  written as (
    insert into market.security_price_span as ps (security_id, first_date, last_date, updated_at)
    select security_id, first_date, last_date, now() from span
    on conflict (security_id) do update
       set first_date = excluded.first_date,
           last_date  = excluded.last_date,
           updated_at = excluded.updated_at
     -- Cheap to re-run: an unchanged span is not rewritten.
     where (ps.first_date, ps.last_date) is distinct from (excluded.first_date, excluded.last_date)
    returning 1
  )
  select (select count(*) from asked),
         (select count(*) from written),
         (select count(*) from span where first_date is null)
    into v_asked, v_written, v_empty;

  return jsonb_build_object('asked', v_asked, 'written', v_written, 'without_bars', v_empty);
end;
$function$;
