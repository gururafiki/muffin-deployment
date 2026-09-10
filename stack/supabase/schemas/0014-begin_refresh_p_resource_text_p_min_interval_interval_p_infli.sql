CREATE OR REPLACE FUNCTION market.begin_refresh(p_resource text, p_min_interval interval DEFAULT '00:05:00'::interval, p_inflight_ttl interval DEFAULT '00:02:00'::interval, p_error_backoff interval DEFAULT '00:01:00'::interval)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_temp'
AS $function$
begin
  if not pg_try_advisory_xact_lock(hashtext('market.refresh:' || p_resource)) then
    return false;
  end if;

  -- RECORD THE TTL BEFORE THE SKIP CHECK, NOT AFTER IT — and that ordering is the whole point.
  --
  -- `min_interval` exists so the stalled-resource alert can judge a resource by its OWN schedule: a
  -- 7-day TTL over quarterly filings is correctly quiet for a week, and a flat 12-hour rule flags it
  -- beside resources that have genuinely stopped. But the write started out below, after both early
  -- returns, so a resource that SKIPPED never recorded anything — and the skipping ones are exactly
  -- the ones the TTL is needed for. Measured 2026-09-04, one deploy after shipping it: 18 of 46
  -- resources had a TTL, all of them ones that had actually claimed, and the alert went on flagging
  -- `fund-holdings`, `derive-classifications` and six others against the 12-hour fallback.
  --
  -- A self-defeating fix, in other words: the evidence was collected only where it was not needed.
  -- The TTL is a property of the CALLER's intent, not of whether this particular call won the race,
  -- so it is recorded whenever we are serialised enough to write it safely — which is here, inside
  -- the advisory lock, before any decision about skipping.
  --
  -- `is distinct from` so a steady-state call writes nothing: this runs on every invocation of every
  -- resource, most of which skip.
  update market.refresh_log
     set min_interval = p_min_interval
   where resource = p_resource
     and min_interval is distinct from p_min_interval;

  if exists (
    select 1 from market.refresh_log
     where resource = p_resource
       and (
         -- A successful refresh finished recently enough.
         (ok and finished_at is not null and finished_at > now() - p_min_interval)
         -- …or another refresh is still in flight (and hasn't obviously died).
         or (finished_at is null and started_at > now() - p_inflight_ttl)
         -- …or the LAST attempt failed and is still cooling off. Without this a
         -- persistently broken upstream would be re-hit on every single trigger,
         -- and the trigger is reachable by anyone holding the public anon key.
         or (not ok and finished_at is not null and finished_at > now() - p_error_backoff)
       )
  ) then
    return false;
  end if;

  insert into market.refresh_log (resource, started_at, finished_at, ok, error, min_interval)
       values (p_resource, now(), null, false, null, p_min_interval)
  on conflict (resource) do update
     set started_at = now(), finished_at = null, ok = false, error = null,
         min_interval = excluded.min_interval;

  return true;
end $function$;
