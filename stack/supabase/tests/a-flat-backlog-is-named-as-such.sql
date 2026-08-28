-- THE DRAIN VIEW MUST TELL THE THREE CASES APART, AND THE HARD ONE IS THE THIRD.
--
-- `market.backlog_drain` exists because two live stalls were found BY EYE on 2026-08-28 —
-- `security-statements` returning `written: 240, remaining: 8668` byte-identical on five
-- consecutive runs. The depth was in `backlog_sample` the whole time; nothing computed a rate, so
-- the dashboard drew a flat line and no alert could fire on "flat".
--
-- A view that merely reports depth would pass a naive test. The fixture therefore makes the three
-- states DISAGREE — the same discipline that caught the free-cash-flow `abs()` and the peer
-- ranking: if the candidate rules all produce the same answer, the guard proves nothing.

\set ON_ERROR_STOP on

begin;

-- Seven days of hourly-ish samples, one backlog per state.
--   DRAINER  falls 1000 -> 300           and its negative cache is FLAT  -> draining
--   STUCK    sits at 5000 throughout                                     -> FLAT
--   MARKER   falls 1000 -> 300 and its negative cache RISES to match     -> draining_by_marking
--   NEWBIE   has three samples only                                      -> insufficient_history
insert into market.backlog_negative_cache (backlog, missing_column) values
  ('pending_zz_drainer', 'zz_drainer_missing_at'),
  ('pending_zz_marker',  'zz_marker_missing_at')
on conflict (backlog) do update set missing_column = excluded.missing_column;

do $$
declare i int; ts timestamptz;
begin
  for i in 0..47 loop
    ts := now() - interval '7 days' + (i * interval '3.5 hours');
    insert into market.backlog_sample (sampled_at, backlog, depth) values
      (ts, 'pending_zz_drainer', 1000 - (i * 700 / 47)),
      (ts, 'pending_zz_stuck',   5000),
      (ts, 'pending_zz_marker',  1000 - (i * 700 / 47)),
      -- A GROWER, because the FLAT case cannot prove the ETA rule: a perfectly constant depth has
      -- a slope of exactly zero, so `depth / nullif(abs(slope),0)` is null under the correct rule
      -- AND under a broken one. Measured by mutation — the assertion passed clean until this row
      -- existed. A growing backlog makes the two disagree: the correct rule yields NULL, a rule
      -- that merely divides yields a confident forecast for a queue moving the wrong way.
      (ts, 'pending_zz_grower',  300 + (i * 700 / 47))
    on conflict do nothing;

    -- The drainer's cache does not move; the marker's rises in step with its fall, which is what
    -- makes the two indistinguishable by depth alone.
    insert into market.universe_sample (sampled_at, metric, value) values
      (ts, 'missing.security.zz_drainer_missing_at', 50),
      (ts, 'missing.security.zz_marker_missing_at',  50 + (i * 700 / 47))
    on conflict do nothing;
  end loop;

  -- Three samples is not a trend.
  for i in 0..2 loop
    insert into market.backlog_sample (sampled_at, backlog, depth)
      values (now() - interval '7 days' + (i * interval '3.5 hours'), 'pending_zz_newbie', 900)
    on conflict do nothing;
  end loop;
end $$;

do $$
declare st text; d numeric; e numeric;
begin
  select state into st from market.backlog_drain where backlog = 'pending_zz_drainer';
  if st is distinct from 'draining' then
    raise exception 'a backlog falling 1000 -> 300 with a flat negative cache was called %, not draining', st;
  end if;

  -- ...and it must carry an ETA, or the view reports a rate nobody can act on.
  select days_to_empty into e from market.backlog_drain where backlog = 'pending_zz_drainer';
  if e is null or e <= 0 then
    raise exception 'a draining backlog has no days_to_empty (%) — the rate is computed and then thrown away', e;
  end if;

  select state into st from market.backlog_drain where backlog = 'pending_zz_stuck';
  if st is distinct from 'FLAT' then
    raise exception 'a backlog sitting at 5000 for seven days was called %, not FLAT — this is the '
                    'stall signature that has cost this pipeline seven incidents', st;
  end if;

  -- ...and a backlog moving the WRONG WAY must not be given an ETA at all.
  select state into st from market.backlog_drain where backlog = 'pending_zz_grower';
  if st is distinct from 'growing' then
    raise exception 'a backlog rising 300 -> 1000 was called %, not growing', st;
  end if;
  select days_to_empty into e from market.backlog_drain where backlog = 'pending_zz_grower';
  if e is not null then
    raise exception 'a GROWING backlog was given days_to_empty = % — that is a forecast for a queue '
                    'moving away from empty, and it reads as reassurance', e;
  end if;
  -- The FLAT one likewise, though note this alone cannot prove the rule: a perfectly constant
  -- depth has a zero slope, so both the correct and the broken expression return null.
  select days_to_empty into e from market.backlog_drain where backlog = 'pending_zz_stuck';
  if e is not null then
    raise exception 'a FLAT backlog was given days_to_empty = % — a stalled queue has no ETA', e;
  end if;

  -- THE ONE THAT MATTERS. Identical depth curve to the drainer; only the cache distinguishes them.
  select state into st from market.backlog_drain where backlog = 'pending_zz_marker';
  if st is distinct from 'draining_by_marking' then
    raise exception 'a backlog draining while its negative cache grows in step was called %, not '
                    'draining_by_marking — its depth curve is IDENTICAL to the healthy drainer, so '
                    'depth alone cannot tell them apart. This is the 2026-08-13 signature: ~8,300 '
                    'securities marked unanswerable while every count read as progress', st;
  end if;

  select state into st from market.backlog_drain where backlog = 'pending_zz_newbie';
  if st is distinct from 'insufficient_history' then
    raise exception 'a backlog with three samples was called % — a fresh deployment would report '
                    'confident nonsense for its first days', st;
  end if;

  raise notice '  ok  draining, FLAT, draining_by_marking and insufficient_history are distinguished';
end $$;

-- AND THE LOCAL-SYMBOL BACKLOG LISTS ONLY WORK THAT CAN BE DONE.
-- It returned 281 securities while the resource reported `no addressable securities pending` on
-- every run: all 281 were in countries with no `market.exchange` row (Cayman 118, Bermuda 56,
-- Luxembourg 20). The rule lived in TypeScript and not in the view.
insert into market.countries (iso2, name, flag, drillable) values
  ('ZQ','Offshoria','ZQ',false), ('ZR','Realland','ZR',false)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values ('ZRX','ZR','.ZR')
on conflict (exch_code) do nothing;
insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.identifier_kind (code, name) values ('isin','ISIN') on conflict do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-00000000e001','No Venue Co','equity','ZQ'),
  ('00000000-0000-0000-0000-00000000e002','Has Venue Co','equity','ZR')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id) values
  ('isin','ZQ0000000001','00000000-0000-0000-0000-00000000e001'),
  ('isin','ZR0000000001','00000000-0000-0000-0000-00000000e002')
on conflict (kind_code, value) do nothing;

do $$
declare n int;
begin
  select count(*) into n from market.pending_local_symbol
   where security_id = '00000000-0000-0000-0000-00000000e001';
  if n <> 0 then
    raise exception 'a security in a country with NO exchange is queued for local-symbol '
                    'resolution (% rows) — the resource cannot address it, so the backlog reports '
                    'work nobody can do, for ever', n;
  end if;
  select count(*) into n from market.pending_local_symbol
   where security_id = '00000000-0000-0000-0000-00000000e002';
  if n <> 1 then
    raise exception 'a security in a country WITH an exchange is not queued (% rows) — the venue '
                    'filter has emptied the backlog rather than scoping it', n;
  end if;
  raise notice '  ok  pending_local_symbol lists only securities with a venue to resolve against';
end $$;

rollback;
