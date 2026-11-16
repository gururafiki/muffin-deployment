-- THE INDIA FILING WALKER LEAVES THE EDGE (Phase 6 step 6, decided by the user 2026-11-09).
--
-- muffin-ingest's `nse_segments` job (`raw_nse_filings` -> `nse_segment`) now lists each NSE
-- filer's annual results, files them in `market.security_filing` and reads each consolidated
-- result's XBRL instance into `market.security_segment` under the same `nse` source. The filers are
-- the NSE symbols `security_nse_filer` (the registries family) maps by ISIN. Decision 3 is that two
-- writers never run at once, so the edge's walker retires before the Dagster schedules start. Its
-- parser retired on 2026-11-04 (migration 20261104110000), waiting for this lane.
--
-- RETIRES: in-filings
--
-- PORTED AS-IS (decision 2), SO NOTHING IS READ AGAIN. Golden parity on 2026-11-16 re-read every
-- filing with stored rows; see the umbrella's docs/specs/2026-11-09-segments-and-regulators.md,
-- step 6.
--
-- THE 440 PLACEHOLDER "FILINGS" GO. NSE lists a result with no XBRL as
-- `https://nsearchives.nseindia.com/corporate/xbrl/-`, and the edge filed that link as a filing,
-- once per company (the key is security and accession): 440 rows, every one marked read, none ever
-- an instance, none owning a segment row (measured 2026-11-16). The Dagster lane files only `.xml`
-- links, so nothing would ever write or read these again; they are deleted once, recorded in
-- `market.one_shot`. Matched on the exact placeholder, so a real filing whose link is unusual is
-- left alone, and only where no segment row names it.
--
-- NSE ALSO MOVED ITS API to `www.nseindia.in` (a 301 from `.com`, measured 2026-11-16), so the
-- `nse` cache location and the edge's `nse()` origin change with this migration's deploy.

update market.cron_resource set enabled = false where resource = 'in-filings';

do $$
begin
  -- Guarded on the table, not with an exception handler: the migration tests run on plain
  -- Postgres with no pg_cron, where even planning a query that names `cron.job` fails.
  if to_regclass('cron.job') is not null then
    execute $q$select cron.unschedule(jobname) from cron.job where jobname = 'muffin-in-filings'$q$;
  end if;
end $$;

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'nse-placeholder-filings-2026-11-16') then
    raise notice 'nse-placeholder-filings: already applied';
    return;
  end if;

  delete from market.security_filing f
   where f.source_code = 'nse'
     and f.accession_number = 'https://nsearchives.nseindia.com/corporate/xbrl/-'
     and not exists (
           select 1 from market.security_segment g
            where g.security_id = f.security_id and g.accession_number = f.accession_number);
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'nse-placeholder-filings-2026-11-16',
    format('deleted %s NSE placeholder filings (.../corporate/xbrl/-), none ever an instance', n));
  raise notice 'nse-placeholder-filings: deleted % rows', n;
end $$;
