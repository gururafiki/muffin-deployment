-- THE LEDGER'S MISSING HALF, AND A PRIVILEGE BOUNDARY THAT WAS OPEN THE MOMENT IT SHIPPED.
--
-- Migration 206 gave the ledger a claim, a completion, a refusal to guess, a reaper and a budget —
-- and nothing that PUTS A ROW IN THE QUEUE. `ingest.facet.population_sql` is the column that says
-- who owes a facet, and no function executed it, so the ledger could be read, leased and completed
-- while being permanently empty. This adds `sync_population`.
--
-- Writing it surfaced the boundary problem. `mark_absent` is SECURITY DEFINER — it runs as
-- `postgres` — and it does `execute f.retract_sql`, where `retract_sql` is a COLUMN of
-- `ingest.facet`. 206 granted `ingest_rw` "insert, update, delete on all tables in schema ingest",
-- which includes that table. So the ingestion worker could write any statement it liked into a
-- control column and have `mark_absent` run it as a superuser. `sync_population` would have made
-- that worse by adding a second such column.
--
-- The same grant makes the ledger's headline invariant a convention rather than a rule.
-- `mark_absent` REFUSES to record an absence without an attempt proving the subject was asked alone
-- and a control answered — the rule that once cost 1,369 ordinary securities a month in the
-- backlog. But a role holding `update` on `ingest.task` can simply set `status = 'absent'` itself,
-- and the refusal never runs. A guard that the guarded party can walk around is documentation.
--
-- The fix is one idea: A FACET IS A CONTROL TABLE, EDITED BY A MIGRATION OR AN OPERATOR, NEVER BY
-- THE WORKER — exactly like `market.tracked_fund` and `market.cron_resource`. Once the worker
-- cannot write it, executing its SQL as definer is no more trusted than executing this file, and
-- every queue mutation is forced through the functions that carry the invariants.
--
-- The revoke is DERIVED, not a list of three table names. A list is the shape that rots: the next
-- control table added to this schema would silently arrive writable, which is the same failure as
-- `clear_symbol_caches` carrying a hand-written column list that a tenth column never joined.
-- Everything in `ingest` is read-only to the worker except `attempt`, which it must append to —
-- that append is precisely what makes a killed run leave a record.

-- ---------------------------------------------------------------------------------------------
-- 1. Fill the queue.
-- ---------------------------------------------------------------------------------------------

-- `population_sql` MUST return exactly four columns, in this order:
--
--     subject      text     the ledger key: a security_id, or `security_id:accession`, or 'global'
--     security_id  uuid     nullable, for a global subject
--     priority     numeric  fund weight, or whatever makes the important work go first
--     entity_rank  numeric  the order of THIS subject within ITS OWN entity — annuals before
--                           quarterlies, newest first. Ignored where an entity owns one subject.
--
-- Four columns always, including the ones a security-grain facet does not care about, because an
-- optional column in a contract executed by `execute` fails at runtime in production rather than
-- in CI. The shape is asserted below before anything is inserted.
--
-- `round` IS COMPUTED HERE AND STORED, AND THAT IS THE WHOLE POINT OF THE FUNCTION.
-- `pending_segments` ordered by a property of the SECURITY, so every filing of a company shared a
-- sort key and one filer's entire history drained before the next company was touched — 440
-- filings belonging to 14 securities, with `written` reading as throughput throughout. The fix was
-- a per-entity `row_number()`, and the fix for THAT was that a window function computed over the
-- OUTSTANDING rows renumbers as the queue drains: parse a company's round 1 and its old round 2
-- becomes round 1 on the very next query, handing it the head again. Measured mid-drain, 106
-- securities of 3,967 had had any filing re-read while 3,861 had had none.
--
-- A stored round cannot renumber. It is assigned once, from the count of what this entity ALREADY
-- has plus the position of the new rows among themselves, and nothing recomputes it afterwards.
create or replace function ingest.sync_population(p_facet text)
returns int
language plpgsql security definer set search_path = ingest, market, pg_catalog, pg_temp as $$
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
end $$;

-- Put a provider to sleep when it says it is refusing us. Separate from `spend` because a throttle
-- is not a quota: the budget may be untouched and the provider still unwilling, and a run that
-- cannot tell those apart marks securities absent during an outage.
create or replace function ingest.cool_down(p_provider text, p_for interval default null)
returns timestamptz
language plpgsql security definer set search_path = ingest, pg_catalog, pg_temp as $$
declare b ingest.provider_budget%rowtype; until timestamptz;
begin
  select * into b from ingest.provider_budget where provider_code = p_provider for update;
  if not found then raise exception 'unknown provider %', p_provider; end if;
  until := now() + coalesce(p_for, b.cooldown);
  -- NEVER SHORTEN AN EXISTING COOLDOWN. Two runs meeting the same throttle would otherwise have the
  -- second one's shorter nap overwrite the first one's, and the pause a provider asked for is a
  -- floor, not a suggestion.
  until := greatest(until, coalesce(b.cooldown_until, until));
  update ingest.provider_budget set cooldown_until = until where provider_code = p_provider;
  return until;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Close the boundary.
-- ---------------------------------------------------------------------------------------------

-- `create or replace function` PRESERVES THE EXISTING ACL, and `grant` in a re-run migration can
-- only ever ADD a privilege — so these two are dropped and recreated by the block below rather
-- than trusted to inherit anything. Postgres also grants EXECUTE to PUBLIC by default, which makes
-- an explicit grant decorative until that is revoked; measured on `aggregate_performance`, where
-- every role could already execute a function whose grant read as the thing permitting it.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'ingest' and p.proname in ('sync_population', 'cool_down')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to ingest_rw', f.sig);
  end loop;
end $$;

-- MUTATION: the revoke block and the default-privilege narrowing are removed.

comment on function ingest.sync_population(text) is
  'Enqueue the subjects a facet owes that are not already in the ledger, assigning a stored round '
  'so the queue is breadth-first across entities and cannot renumber as it drains.';
comment on function ingest.cool_down(text, interval) is
  'Pause a provider that is refusing us. Never shortens a cooldown already in force.';
