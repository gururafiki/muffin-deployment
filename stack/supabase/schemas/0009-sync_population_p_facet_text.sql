CREATE OR REPLACE FUNCTION ingest.sync_population(p_facet text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  f ingest.facet%rowtype;
  n int;
begin
  select * into f from ingest.facet where facet = p_facet;
  if not found then raise exception 'unknown facet %', p_facet; end if;

  -- SERIALISE PER FACET. Two syncs racing would each see the other's rows as absent and assign the
  -- same round twice; `on conflict do nothing` keeps the table correct but the ordering would not
  -- be. An advisory lock held to the end of the transaction is cheaper than reasoning about it.
  perform pg_advisory_xact_lock(hashtext('ingest.sync_population:' || p_facet));

  -- ONE STATEMENT, NO TEMPORARY TABLE. The first draft materialised the population into a
  -- `create temporary table _pop on commit drop`, which works exactly once per transaction and
  -- then fails with "relation _pop already exists" — and a facet's asset syncs before every claim,
  -- so the second sync in any transaction would have died. Its own behaviour test found it.
  --
  -- The casts in `pop` ARE the shape check: a population query returning the wrong columns fails
  -- here rather than three CTEs later with a message about a type, and the handler names the facet
  -- so an operator knows which control row to look at.
  begin
    execute format($f$
      with pop as (
        select subject::text as subject, security_id::uuid as security_id,
               priority::numeric as priority, entity_rank::numeric as entity_rank
          from (%s) p
      ),
      new as (
        select p.* from pop p
          left join ingest.task t on t.facet = $1 and t.subject = p.subject
         where t.subject is null
      ),
      held as (
        select t.security_id, count(*) as n from ingest.task t where t.facet = $1 group by t.security_id
      ),
      inserted as (
        insert into ingest.task (facet, subject, security_id, priority, round)
        select $1, n.subject, n.security_id, n.priority,
               -- `round` is a smallint. A filer with more than 32,767 outstanding filings would
               -- wrap; clamping parks it at the back of the queue, which is where it belongs.
               least(32767,
                     coalesce(h.n, 0)
                     + row_number() over (partition by n.security_id
                                              order by n.entity_rank, n.subject))::smallint
          from new n
          left join held h on h.security_id is not distinct from n.security_id
        on conflict (facet, subject) do nothing
        returning 1
      )
      select count(*)::int from inserted
    $f$, f.population_sql)
    into n using p_facet;
  exception when others then
    raise exception
      'facet %: population_sql must return (subject, security_id, priority, entity_rank) — %',
      p_facet, sqlerrm;
  end;

  return n;
end $function$;
