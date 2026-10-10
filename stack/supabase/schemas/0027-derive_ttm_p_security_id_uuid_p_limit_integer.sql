CREATE OR REPLACE FUNCTION market.derive_ttm(p_security_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 400)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare v_written integer := 0;
begin
  -- THE PAGE, CHOSEN ONCE, so the marker below records exactly the securities evaluated. One named
  -- security, or up to `p_limit` from the backlog. The backlog is an anti-join over the marker, so
  -- successive pages advance whether or not a page produced a TTM.
  create temporary table _ttm_page on commit drop as
  select p.security_id from market.pending_ttm p
   where p_security_id is null
   limit p_limit;
  if p_security_id is not null then
    insert into _ttm_page (security_id) values (p_security_id);
  end if;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select
    q.security_id, q.metric_code, 'ttm', q.as_of, q.ttm_value, q.currency_code, 'derived', now()
  from (
    select
      m.security_id,
      m.metric_code,
      m.as_of,
      m.currency_code,
      sum(m.value)   over w as ttm_value,
      count(*)       over w as quarters,
      min(m.as_of)   over w as window_start
    from market.security_metric m
    join market.metric mt on mt.code = m.metric_code and mt.is_flow
    where m.period_type = 'quarter'
      and m.security_id in (select security_id from _ttm_page)
    window w as (
      partition by m.security_id, m.metric_code
      order by m.as_of
      rows between 3 preceding and current row
    )
  ) q
  -- EXACTLY FOUR QUARTERS, INSIDE 370 DAYS. Four rows spanning two years sum to a number that
  -- looks like a TTM and is not; a missing quarter must read as no TTM, not as a smaller year.
  where q.quarters = 4
    and q.as_of - q.window_start <= 370
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);

  get diagnostics v_written = row_count;

  -- EVALUATED, WHATEVER IT FOUND. A security whose quarters cannot form a TTM leaves the backlog here
  -- and returns only when a newer quarter arrives.
  insert into market.ttm_derivation (security_id, derived_at)
  select security_id, now() from _ttm_page
  on conflict (security_id) do update set derived_at = excluded.derived_at;

  drop table _ttm_page;
  return v_written;
end;
$function$;
