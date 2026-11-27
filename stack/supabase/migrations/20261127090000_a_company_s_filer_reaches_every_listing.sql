-- A company's regulator filer reaches every equity listing of that company (Phase 6c step 3,
-- decision 1 of docs/specs/2026-11-26-more-segment-sources.md).
--
-- WHY. A regulator's lane writes a company's segments onto the securities mapped to its filer id,
-- and each registry maps only the listing it can recognise: SEC the CIK holder, DART the common
-- share's code, CNINFO the A-share. Every other listing of the same company had nothing.
-- Measured 2026-11-26 on production, read-only: same-issuer equities that hold no filer with an
-- annual accounts filing, beside a sibling that does, by regulator: cninfo 83 (50 over $2 bn),
-- sec 43 (31), dart 13 (9), nse 4 (1). Every large link was read by eye and is the same company:
-- ICBC, CCB, ABC and Bank of China's H-share lines, CATL; Samsung and Hyundai preferred shares;
-- Petrobras, Itau, Vale, Ambev and Bradesco's local lines; UMC's Taiwan line; SBI's London line.
-- No issuer's held filers disagree (two filer ids for one issuer); such an issuer is refused.
--
-- `security_filer.via` RECORDS WHO CLAIMED A ROW. `registry` is a regulator's own mapping (the CIK
-- trigger, the NSE symbol map, the CNINFO and DART assets); `issuer_sibling` is this extension.
-- A registry ALWAYS wins: the extension inserts `on conflict do nothing`, and every registry writer
-- sets `via = 'registry'` when it claims a row (the SQL two here; the assets in muffin-ingest).
--
-- A SIBLING ROW CARRIES SEGMENTS ONLY. Statements, the fiscal calendar, SIC and Form 4 follow
-- `security.cik`, which the extension never sets: an SEC filer's local line (PETR4.SA) gets its
-- segments, not a second copy of the company's SEC statements.
--
-- THE SEC TRIGGER MUST KEEP A SIBLING ROW. It fires on any `UPDATE OF cik`, and for a null CIK it
-- deleted the security's SEC filer row: every write naming the column (the CIK map sets it for
-- thousands of rows) would have retracted the extension's rows.
--
-- `copy_filer_history` gives a filer holder with none of its filer's history (a sibling just linked,
-- an H-share line CNINFO's HK list just mapped) that history, copied from the holder that read it: re-reading would mean fetching SEC's history again (the edge read it and raw does
-- not hold it) and China's pruned PDFs. Its column lists come from `pg_attribute`, so a column added
-- to either table later is copied too.

alter table market.security_filer add column if not exists via text not null default 'registry';
alter table market.security_filer drop constraint if exists security_filer_via_check;
alter table market.security_filer add constraint security_filer_via_check
  check (via in ('registry', 'issuer_sibling'));
comment on column market.security_filer.via is
  'Who claimed the row: `registry` (a regulator''s own mapping) or `issuer_sibling` '
  '(`extend_filers_to_issuer_siblings`, another listing of the same issuer). A registry always '
  'wins. A sibling row carries segments only; statements follow `security.cik`.';

create or replace function market.sync_sec_filer()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'market', 'pg_catalog'
as $function$
begin
  if new.cik is not null then
    insert into market.security_filer (security_id, source_code, filer_id, via)
         values (new.security_id, 'sec', new.cik::text, 'registry')
    on conflict (security_id, source_code) do update
       set filer_id = excluded.filer_id, via = 'registry';
  else
    -- A CLEARED CIK MUST RETRACT. Leaving the row would keep the security reading `held` against a
    -- registration we no longer believe in, and an upsert cannot retract. Only the CIK's OWN row:
    -- a sibling row was never claimed by the CIK.
    delete from market.security_filer
     where security_id = new.security_id and source_code = 'sec' and via = 'registry';
  end if;
  return new;
end $function$;

create or replace function market.apply_nse_symbol_map(p_map jsonb)
 returns integer
 language plpgsql
as $function$
declare
  v_updated integer := 0;
begin
  if p_map is null or jsonb_typeof(p_map) <> 'object' then
    raise exception 'apply_nse_symbol_map expects a json object of isin -> nse symbol';
  end if;

  with pairs as (
    select upper(key) as isin, (value #>> '{}') as symbol
      from jsonb_each(p_map)
     -- A non-string value is a malformed entry, not a listing. Rejecting it here keeps one bad row
     -- from aborting the statement, which applies in a single transaction.
     where jsonb_typeof(value) = 'string'
       and length(value #>> '{}') > 0
  ),
  resolved as (
    select i.security_id, min(p.symbol) as symbol, count(distinct p.symbol) as rivals
      from market.security_identifier i
      join pairs p on p.isin = upper(i.value)
      join market.security s on s.security_id = i.security_id
     where i.kind_code = 'isin'
       -- SCOPED TO INDIA. An ISIN is globally unique, so this cannot currently mis-hit — but NSE
       -- lists only Indian companies, and a filer id is per (security, regulator): writing one for
       -- a security in another jurisdiction would advertise a filing route that does not exist.
       and s.country_iso2 = 'IN'
     group by i.security_id
  )
  insert into market.security_filer (security_id, source_code, filer_id, as_of, via)
  select r.security_id, 'nse', r.symbol, now(), 'registry'
    from resolved r
   -- Two symbols for one ISIN is not a tie to break with min(); NSE's list has none today, which
   -- is exactly when this costs nothing to assert.
   where r.rivals = 1
  on conflict (security_id, source_code) do update
    set filer_id = excluded.filer_id,
        as_of    = excluded.as_of,
        via      = 'registry'
    -- IDEMPOTENT. Without this every run rewrites every row, and `history_walked_at` lives on this
    -- table — an unnecessary update is WAL for nothing on a resource that runs on a TTL. A sibling
    -- row is claimed by the registry even when its filer id already agrees.
    where (market.security_filer.filer_id, market.security_filer.via)
          is distinct from (excluded.filer_id, 'registry');

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$function$;

create or replace function market.issuer_registry_filers()
 returns table (issuer_id uuid, security_id uuid, source_code text, filer_id text)
 language sql
 stable
 set search_path to 'market', 'pg_catalog'
as $function$
  -- The REGISTRY filers of equities that hold an annual accounts filing from that regulator. A
  -- sibling row is never one: once its history is copied it holds accounts itself, and counting it
  -- would make a company's own copy its source.
  select s.issuer_id, f.security_id, f.source_code, f.filer_id
    from market.security_filer f
    join market.disclosure_source d on d.code = f.source_code and d.enabled
    join market.security s on s.security_id = f.security_id
   where f.via = 'registry' and s.issuer_id is not null and s.security_type_code = 'equity'
     and exists (select 1
                   from market.security_filing sf
                   join market.filing_form ff
                     on ff.source_code = f.source_code and ff.form_code = sf.report_type
                  where sf.security_id = f.security_id and ff.is_annual and ff.carries_segments)
$function$;

create or replace function market.issuer_sibling_links()
 returns table (security_id uuid, source_code text, filer_id text)
 language sql
 stable
 set search_path to 'market', 'pg_catalog'
as $function$
  with held as materialized (select * from market.issuer_registry_filers()),
  by_issuer as materialized (
    select h.issuer_id, min(h.source_code) source_code, min(h.filer_id) filer_id
      from held h
     group by h.issuer_id
    -- ONE FILER PER ISSUER, or the issuer is refused: two filer ids is a question, not a choice.
    having count(distinct (h.source_code, h.filer_id)) = 1
  )
  select s.security_id, i.source_code, i.filer_id
    from by_issuer i
    join market.security s on s.issuer_id = i.issuer_id
   where s.security_type_code = 'equity'
     -- HOLES ONLY: a listing holding its own registry filer with accounts is served already.
     and not exists (select 1 from held h where h.security_id = s.security_id)
$function$;

create or replace function market.extend_filers_to_issuer_siblings()
 returns table (inserted integer, retracted integer, refused integer)
 language plpgsql
 set search_path to 'market', 'pg_catalog'
as $function$
declare
  v_inserted integer;
  v_retracted integer;
  v_refused integer;
begin
  -- A LINK THE RULE NO LONGER WANTS IS RETRACTED, and so is what it brought: the filings and
  -- segments of the accessions the filer's registry listings hold.
  with wanted as materialized (select * from market.issuer_sibling_links()),
  gone as (
    delete from market.security_filer f
     where f.via = 'issuer_sibling'
       and not exists (select 1 from wanted w
                        where w.security_id = f.security_id and w.source_code = f.source_code
                          and w.filer_id = f.filer_id)
    returning f.security_id, f.source_code, f.filer_id
  ), brought as materialized (
    select distinct g.security_id, sf.accession_number
      from gone g
      join market.security_filer r
        on r.source_code = g.source_code and r.filer_id = g.filer_id and r.via = 'registry'
      join market.security_filing sf on sf.security_id = r.security_id
  ), segments_gone as (
    delete from market.security_segment x
     using brought b
     where x.security_id = b.security_id and x.accession_number = b.accession_number
    returning 1
  ), filings_gone as (
    delete from market.security_filing x
     using brought b
     where x.security_id = b.security_id and x.accession_number = b.accession_number
    returning 1
  )
  select (select count(*) from gone) into v_retracted;

  insert into market.security_filer (security_id, source_code, filer_id, via)
  select w.security_id, w.source_code, w.filer_id, 'issuer_sibling'
    from market.issuer_sibling_links() w
  on conflict (security_id, source_code) do nothing;
  get diagnostics v_inserted = row_count;

  select count(*) into v_refused
    from (select h.issuer_id from market.issuer_registry_filers() h
           group by h.issuer_id
          having count(distinct (h.source_code, h.filer_id)) > 1) x;

  return query select v_inserted, v_retracted, v_refused;
end $function$;

comment on function market.extend_filers_to_issuer_siblings() is
  'Maps each equity with no registry filer holding accounts onto the one registry filer its issuer '
  'holds (`via = issuer_sibling`), refuses an issuer holding two, and retracts links the rule no '
  'longer wants with the filings and segments they brought. Run by `security_filer_siblings`.';

create or replace function market.copy_filer_history(p_security_id uuid, p_source text)
 returns table (filings integer, segments integer)
 language plpgsql
 set search_path to 'market', 'pg_catalog'
as $function$
declare
  v_filer text;
  v_from uuid;
  v_version smallint;
  v_filings integer := 0;
  v_segments integer := 0;
  v_cols text;
  v_select text;
begin
  select f.filer_id into v_filer
    from market.security_filer f
   where f.security_id = p_security_id and f.source_code = p_source;
  select p.version into v_version from market.segment_parser p where p.regulator = p_source;
  if v_filer is null or v_version is null then
    return query select 0, 0;
    return;
  end if;

  -- THE SIBLING THAT HAS READ THE MOST, so a share class mapped yesterday is never the source.
  select r.security_id into v_from
    from market.security_filer r
   where r.source_code = p_source and r.filer_id = v_filer and r.security_id <> p_security_id
   order by (select count(*) from market.security_filing sf
              where sf.security_id = r.security_id
                and sf.segments_parser_version >= v_version) desc,
            r.security_id
   limit 1;
  if v_from is null then
    return query select 0, 0;
    return;
  end if;

  select string_agg(quote_ident(a.attname), ', ' order by a.attnum),
         string_agg(case when a.attname = 'security_id' then '$1' else 'x.' || quote_ident(a.attname) end,
                    ', ' order by a.attnum)
    into v_cols, v_select
    from pg_attribute a
   where a.attrelid = 'market.security_filing'::regclass and a.attnum > 0
     and not a.attisdropped and a.attgenerated = '';
  execute format('insert into market.security_filing (%s) select %s from market.security_filing x '
                 'where x.security_id = $2 on conflict (security_id, accession_number) do nothing',
                 v_cols, v_select)
    using p_security_id, v_from;
  get diagnostics v_filings = row_count;

  -- ONLY WHAT THE SOURCE READ AT THE CURRENT VERSION: a filing behind the parser is copied unread
  -- above (its own markers), and its segments arrive when the lane reads it for both listings.
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum),
         string_agg(case when a.attname = 'security_id' then '$1' else 'x.' || quote_ident(a.attname) end,
                    ', ' order by a.attnum)
    into v_cols, v_select
    from pg_attribute a
   where a.attrelid = 'market.security_segment'::regclass and a.attnum > 0
     and not a.attisdropped and a.attgenerated = '';
  execute format('insert into market.security_segment (%s) select %s from market.security_segment x '
                 'where x.security_id = $2 and exists (select 1 from market.security_filing f '
                 'where f.security_id = $2 and f.accession_number = x.accession_number '
                 'and f.segments_parser_version >= $3) on conflict do nothing',
                 v_cols, v_select)
    using p_security_id, v_from, v_version;
  get diagnostics v_segments = row_count;

  return query select v_filings, v_segments;
end $function$;

comment on function market.copy_filer_history(uuid, text) is
  'Copies a filer holder''s history (filings, and the segments of filings read at the current parser '
  'version) from the other holder of that filer that has read the most. Idempotent.';

create or replace function market.filer_holders_to_copy()
 returns table (security_id uuid, source_code text)
 language sql
 stable
 set search_path to 'market', 'pg_catalog'
as $function$
  -- A HOLDER WITH NONE OF ITS FILER'S HISTORY, beside another holder that has some: a sibling just
  -- linked, an H-share line CNINFO's HK list just mapped, a share class a registry just mapped. Once
  -- copied it holds the history and drops out, so the copy runs once per holder.
  select f.security_id, f.source_code
    from market.security_filer f
    join market.disclosure_source d on d.code = f.source_code and d.enabled
   where exists (select 1
                   from market.security_filer o
                   join market.security_filing osf on osf.security_id = o.security_id
                  where o.source_code = f.source_code and o.filer_id = f.filer_id
                    and o.security_id <> f.security_id)
     and not exists (select 1
                       from market.security_filing sf
                       join market.security_filer o
                         on o.source_code = f.source_code and o.filer_id = f.filer_id
                        and o.security_id <> f.security_id
                       join market.security_filing osf
                         on osf.security_id = o.security_id
                        and osf.accession_number = sf.accession_number
                      where sf.security_id = f.security_id)
$function$;

comment on function market.filer_holders_to_copy() is
  'Filer holders holding none of the filings another holder of the same filer holds: what '
  '`security_filer_siblings` passes to `copy_filer_history`.';

revoke all on function market.issuer_registry_filers() from public, anon, authenticated;
revoke all on function market.issuer_sibling_links() from public, anon, authenticated;
revoke all on function market.extend_filers_to_issuer_siblings() from public, anon, authenticated;
revoke all on function market.copy_filer_history(uuid, text) from public, anon, authenticated;
revoke all on function market.filer_holders_to_copy() from public, anon, authenticated;
grant execute on function market.issuer_registry_filers() to ingest_rw, service_role;
grant execute on function market.issuer_sibling_links() to ingest_rw, service_role;
grant execute on function market.extend_filers_to_issuer_siblings() to ingest_rw, service_role;
grant execute on function market.copy_filer_history(uuid, text) to ingest_rw, service_role;
grant execute on function market.filer_holders_to_copy() to ingest_rw, service_role;
