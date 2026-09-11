-- Carry the old pipeline's absences into the ledger, so the new one does not re-learn them.
--
-- `security-prices` spent months establishing which symbols yfinance will not serve, and recorded
-- it in `market.security.prices_missing_at`. The new pipeline starts with an empty ledger and none
-- of that knowledge — so on its first full pass it would ask all 570 again, and because the vendor
-- is asked ONCE PER SYMBOL whatever we batch, that is 570 real requests a day until it re-derives
-- what is already written down.
--
-- Step (a) of the design's per-family recipe: "backfill of the old `%_missing_at`/cursor columns
-- into `ingest.task` (absent => status='absent', next_due_at = missing_at + 30d)".
--
-- WHY THIS MAY WRITE `status='absent'` DIRECTLY WHEN `ingest.mark_absent` REFUSES TO.
--
-- That refusal exists because a caller might mark a subject on a run-wide tally — which is how
-- ~8,300 securities were negative-cached in one afternoon. It demands an attempt proving the
-- subject was asked ALONE and a control answered.
--
-- This is not that. The evidence was gathered by `security-prices`, whose `fetchWithIsolation`
-- applies the same rule (ask alone, prove the provider healthy with a control, mark nothing when
-- every symbol fails). The migration carries a conclusion already reached; it does not mint one.
-- Nothing here can mark a subject the old pipeline did not, because the population IS the old
-- column. And the mark keeps its ORIGINAL date — `prices_missing_at + 30 days`, never
-- `now() + 30 days` — so a symbol marked on 2026-08-13 is re-asked on schedule rather than having
-- its sentence restarted by the migration that moved it.
--
-- ONE-SHOT, because it is a data repair and migrations re-run on every deploy. Re-running it would
-- keep resetting `next_due_at` for symbols the new pipeline has since re-asked and answered for,
-- which is the "clearing prices_missing_at on every deploy permanently defeats the negative cache"
-- failure this schema already records.

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'carry-prices-absences-2026-09-11') then
    raise notice 'carry-prices-absences: already applied';
    return;
  end if;

  with carried as (
    update ingest.task t
       set status = 'absent',
           -- THE ORIGINAL SENTENCE, not a fresh one. `absent_ttl` runs thirty days from when the
           -- PROVIDER was asked, and preserving when it expires is the point of carrying it.
           next_due_at = s.prices_missing_at + interval '30 days',
           updated_at = now()
      from market.security s
     where s.security_id = t.security_id
       and t.facet = 'prices'
       and t.status <> 'absent'
       and s.prices_missing_at is not null
       -- Only a mark that has NOT yet expired. An older one has already served its thirty days and
       -- the security is due to be asked again — importing it as absent would re-sentence it.
       and s.prices_missing_at + interval '30 days' > now()
    returning 1
  )
  select count(*) into n from carried;

  insert into market.one_shot (key, reason) values (
    'carry-prices-absences-2026-09-11',
    format('carried %s unexpired prices_missing_at marks into ingest.task', n)
  );
  raise notice 'carry-prices-absences: carried % marks', n;
end $$;
