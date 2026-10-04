-- The ledger's dead symbols become observations, so the price lane does not re-learn them.
--
-- Stage 3a of the umbrella's docs/specs/2026-09-26-finishing-the-universe-family.md retires the
-- `ingest` ledger. muffin-ingest's price lane now records "the provider rejected this symbol when
-- asked alone, with a control symbol answering in the same run" as a `miss` in
-- `market.identifier_probe`, keyed (security_id, scheme, provider) = (…, 'symbol', 'yfinance'). Its
-- askable population skips a miss younger than 30 days, and only while `asked_with` is still the
-- security's symbol, so a corrected symbol is asked again with no step to remember.
--
-- The ledger holds 274 such conclusions (measured 2026-10-04), all unexpired, due 2026-10-20 to
-- 11-03. Without this file the first night after the roll would ask all of them again, one real
-- request each (the vendor is asked once per symbol however a batch is built), to re-derive what
-- is already written down. Same reasoning as 20260911220000, which carried the edge's
-- `prices_missing_at` into the ledger.
--
-- WHAT IS CARRIED, AND WHAT IS NOT:
-- * `status = 'absent'` only. A `backoff` row is a throttle or transport outcome, never a statement
--   about the symbol, and carrying it as a miss is the shape of the 1,369-security incident.
-- * Only an UNEXPIRED mark (`next_due_at > now()`). An expired one has served its thirty days and
--   the security is due to be asked again.
-- * `observed_at = next_due_at - 30 days`, never `now()`. The lane skips a miss for 30 days from
--   `observed_at`, so this makes each mark expire exactly when the ledger said it would, rather
--   than restarting its sentence at the migration that moved it.
-- * A row with no `asked_with` is not carried: the lane matches a miss on the symbol it was asked
--   with, so such a miss would be ignored anyway, and a null would read as a recorded answer.
-- * ON CONFLICT DO NOTHING: an observation the new lane has already made is newer than the
--   ledger's, and must win.
--
-- ONE-SHOT, because it is a data repair and migrations re-run on every deploy. Re-running it after
-- the lane has re-asked and answered for a symbol would re-mark it dead, which is the "clearing a
-- negative cache on every deploy" failure turned inside out. And GUARDED on the ledger existing,
-- because a later migration drops the `ingest` schema and this file must still apply after that.

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'ledger-absences-to-probes-2026-10-04') then
    raise notice 'ledger-absences-to-probes: already applied';
    return;
  end if;

  if to_regclass('ingest.task') is null then
    insert into market.one_shot (key, reason) values (
      'ledger-absences-to-probes-2026-10-04', 'no ingest.task on this database, nothing to carry');
    raise notice 'ledger-absences-to-probes: no ledger here';
    return;
  end if;

  insert into market.identifier_probe
         (security_id, scheme, provider, asked_with, value, outcome, observed_at)
  select t.security_id, 'symbol', 'yfinance', t.asked_with, null, 'miss',
         t.next_due_at - interval '30 days'
    from ingest.task t
   where t.facet = 'prices'
     and t.status = 'absent'
     and t.next_due_at > now()
     and t.security_id is not null
     and t.asked_with is not null
  on conflict (security_id, scheme, provider) do nothing;
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'ledger-absences-to-probes-2026-10-04',
    format('carried %s unexpired prices absences from ingest.task into identifier_probe', n));
  raise notice 'ledger-absences-to-probes: carried % marks', n;
end $$;
