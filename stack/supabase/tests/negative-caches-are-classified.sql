-- Every negative-cache column must be classified, and `clear_symbol_caches` must clear exactly the
-- symbol-keyed ones.
--
-- WHY. `*_missing_at` columns have been got wrong five times (CLAUDE.md keeps the tally:
-- `figi_missing_at`, `profile_missing_at`, `local_symbol_missing_at`, `performance_missing_at`, and
-- then `prices_missing_at` — which `security-yahoo-symbols` never cleared because the column arrived
-- after the hand-written clear list. 4,801 of 12,348 equities sat locked out of `pending_prices`
-- for it.)
--
-- Nothing errors when this is wrong. The security simply goes quiet for 30 days, and the resource
-- reports a healthy `ok: true` while doing it. So the guard has to be structural: a `%_missing_at`
-- column that nobody has decided about fails CI, and so does a classification that has drifted from
-- what the function actually does.
--
-- Run by the `migrations` job in quality.yml AFTER the two application passes.

\set ON_ERROR_STOP on

begin;

-- 1. NO UNCLASSIFIED COLUMN. This is the half that catches the next `prices_missing_at`: adding a
--    backlog resource with a new negative cache now fails here until someone says which side it is
--    on. Naming the column in the error is the point — the original defect was invisible precisely
--    because it had no symptom to search for.
do $$
declare
  missing text;
begin
  select string_agg(c.column_name, ', ' order by c.column_name) into missing
  from information_schema.columns c
  where c.table_schema = 'market'
    and c.table_name   = 'security'
    and c.column_name like '%\_missing\_at'
    and not exists (
      select 1 from market.symbol_cache_classification k where k.column_name = c.column_name
    );

  if missing is not null then
    raise exception
      'negative-cache column(s) not classified: %. Add them to market.symbol_cache_classification (migration 50) — symbol_keyed = true if the fetch that set the flag used the SYMBOL, false if it used the ISIN. If true, clear_symbol_caches must null it too.', missing;
  end if;
  raise notice 'ok  every %%_missing_at column is classified as symbol-keyed or not';
end $$;

-- 2. NO CLASSIFICATION FOR A COLUMN THAT DOES NOT EXIST. The opposite drift: a renamed or dropped
--    column would leave a stale row asserting a guarantee about nothing.
do $$
declare
  stale text;
begin
  select string_agg(k.column_name, ', ' order by k.column_name) into stale
  from market.symbol_cache_classification k
  where not exists (
    select 1 from information_schema.columns c
    where c.table_schema = 'market' and c.table_name = 'security' and c.column_name = k.column_name
  );

  if stale is not null then
    raise exception 'market.symbol_cache_classification names column(s) that do not exist: %', stale;
  end if;
  raise notice 'ok  no classification names a column that does not exist';
end $$;

-- 3. THE FUNCTION MATCHES THE CLASSIFICATION — asserted by BEHAVIOUR, not by reading its source.
--    Set all nine flags on one security, call the function, and check exactly the symbol-keyed ones
--    are null and exactly the others survive. This is what catches a sixth column being classified
--    `true` and then left out of the function body, which is the original bug wearing a new hat.
do $$
declare
  sid uuid := '00000000-0000-0000-0000-000000000050';
  ts  timestamptz := now();
  bad text;
begin
  insert into market.security (security_id, name, security_type_code) values (sid, 'T50 Probe', 'equity');

  execute (
    select 'update market.security set '
        || string_agg(format('%I = %L', column_name, ts), ', ')
        || ' where security_id = ' || quote_literal(sid)
    from market.symbol_cache_classification
  );

  perform market.clear_symbol_caches(sid);

  -- Compare the post-call state, column by column, against what the classification promised.
  execute (
    select 'select string_agg(x.msg, ''; '') from (values '
        || string_agg(
             format('(case when (select %I from market.security where security_id = %L) is %s then null else %L end)',
                    column_name, sid,
                    -- A symbol-keyed flag must be NULL afterwards, so the complaint fires when it
                    -- is NOT null. Writing the expectation here rather than the complaint condition
                    -- inverts the whole check — which is exactly what the first draft did, and the
                    -- test then reported all nine columns wrong against a correct function.
                    case when symbol_keyed then 'null' else 'not null' end,
                    case when symbol_keyed
                         then column_name || ' is symbol-keyed but clear_symbol_caches left it set'
                         else column_name || ' is NOT symbol-keyed but clear_symbol_caches nulled it' end),
             ', ')
        || ') as x(msg)'
    from market.symbol_cache_classification
  ) into bad;

  if bad is not null then
    raise exception 'clear_symbol_caches disagrees with the classification: %', bad;
  end if;
  raise notice 'ok  clear_symbol_caches clears exactly the symbol-keyed caches';
end $$;

rollback;
