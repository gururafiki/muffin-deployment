-- An OpenFIGI exchange code that covers two markets is told apart by its label, from one control
-- table the worker can read and cannot rewrite. Migration 20261025150000.
--
-- WHY. OpenFIGI files Taiwan's two markets under `TT`, and labels them: `TT (Taiwan Stock
-- Exchange)` is Yahoo's `.TW`, `TT (Taipei Stock Exchange)` (TPEx) is `.TWO`. With `TT` mapped to
-- `.TW` alone, 100 TPEx securities were priced under a spelling Yahoo does not serve. The rule that
-- reads the label lives in muffin-ingest; this asserts the table it reads.

\set ON_ERROR_STOP on

begin;

insert into market.countries (iso2, name, flag, drillable) values ('ZT', 'Twomarket', 'ZT', false)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix, preference, enabled)
values ('T7X', 'ZT', '.ZT', 1, true) on conflict (exch_code) do nothing;

-- 1. Where `TT` exists, the TPEx row does, with Yahoo's suffix.
do $$
begin
  if exists (select 1 from market.exchange where exch_code = 'TT')
     and (select suffix from market.exchange_label
           where exch_code = 'TT' and label = 'Taipei Stock Exchange') is distinct from '.TWO' then
    raise exception 'TT is known but its Taipei label does not map to .TWO';
  end if;
end $$;

-- 2. A row names a venue the model knows, a label as OpenFIGI writes it, and a Yahoo suffix.
do $$
begin
  begin
    insert into market.exchange_label values ('NOPE', 'Somewhere', '.X', 'fixture');
    raise exception 'a label for an unknown venue was accepted';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into market.exchange_label values ('T7X', 'TT (Second Market)', '.ZT', 'fixture');
    raise exception 'a label carrying its own parentheses was accepted: it can never match';
  exception when check_violation then null;
  end;
  begin
    insert into market.exchange_label values ('T7X', 'Second Market', 'ZT', 'fixture');
    raise exception 'a suffix without its dot was accepted';
  exception when check_violation then null;
  end;
  insert into market.exchange_label values ('T7X', 'Second Market', '.ZTO', 'fixture');
  raise notice 'ok  a label row names a known venue, a bare label and a dotted suffix';
end $$;

-- 3. The worker reads it and cannot rewrite it; the app can read it.
do $$
begin
  if not has_table_privilege('ingest_rw', 'market.exchange_label', 'SELECT') then
    raise exception 'ingest_rw cannot read the labels the ladder needs';
  end if;
  if has_table_privilege('ingest_rw', 'market.exchange_label', 'INSERT')
     or has_table_privilege('ingest_rw', 'market.exchange_label', 'UPDATE')
     or has_table_privilege('ingest_rw', 'market.exchange_label', 'DELETE') then
    raise exception 'ingest_rw can rewrite the labels it is instructed by';
  end if;
  if not has_table_privilege('anon', 'market.exchange_label', 'SELECT') then
    raise exception 'anon cannot read the labels';
  end if;
  raise notice 'ok  the worker reads the labels and cannot write them';
end $$;

rollback;
