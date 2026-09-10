CREATE OR REPLACE FUNCTION market.derive_ttm(p_security_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 400)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare v_written integer := 0;
begin
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
      and (
        p_security_id is not null
          -- BOUNDED BY THE BACKLOG, not by a bare `limit` over the rows. A `limit` on the outer
          -- select would take the same first N rows on every call; this takes N SECURITIES that
          -- are actually out of date, and they leave the set once derived.
          or m.security_id in (select security_id from market.pending_ttm limit p_limit)
      )
      and (p_security_id is null or m.security_id = p_security_id)
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
  return v_written;
end;
$function$;
