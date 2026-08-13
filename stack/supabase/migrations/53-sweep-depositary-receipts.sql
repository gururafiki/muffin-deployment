-- The exchange sweep must enumerate ADRs too — IDEMPOTENT.
--
-- `listExchange` asks OpenFIGI `/v3/filter` for `securityType2: 'Common Stock'`, which is not
-- optional (unfiltered, "Samsung Electronics" returns 8,725 hits, nearly all options). But an ADR
-- is a DIFFERENT type, so a filter that names only common stock loses every one of them.
--
-- Measured 2026-08-13, which is how this was found: Alex asked why the universe has no `BABA`.
--
--   BABA -> securityType2: 'Depositary Receipt', securityType: 'ADR'
--
-- The 15,000-row US sweep contains `BABB`, `BABAF` and `BABYF` and not `BABA`. The same is true of
-- every major foreign company's US listing — TSM, NVO, SAP's ADR — which is precisely the
-- population a person expects to find and cannot.
--
-- The cursor is per EXCHANGE, so it needs to know which type it is part-way through, or a venue
-- would restart at common stock forever and never reach receipts. `security_type` is that, and it
-- defaults to the type already swept so existing rows do not re-enumerate what they have done.

alter table market.exchange_cursor
  add column if not exists security_type text not null default 'Common Stock';

comment on column market.exchange_cursor.security_type is
  'Which OpenFIGI securityType2 this venue is currently enumerating. A venue is finished when it has completed every type in market.exchange_sweep_type, not merely the first.';

-- The types to sweep, as DATA rather than a literal in the function — adding "Preferred Stock" or
-- "REIT" later should be a row, the same way adding a fund is.
create table if not exists market.exchange_sweep_type (
  security_type text primary key,
  sort_order    integer not null,
  notes         text
);

insert into market.exchange_sweep_type (security_type, sort_order, notes) values
  ('Common Stock',       1, 'The bulk of any venue.'),
  ('Depositary Receipt', 2, 'ADRs/GDRs. BABA, TSM, NVO and every other foreign company''s US line lives here, and a Common-Stock-only sweep loses all of them.')
on conflict (security_type) do update set sort_order = excluded.sort_order, notes = excluded.notes;

-- Writable, because it is a CONTROL SURFACE like `tracked_fund`: adding "Preferred Stock" or
-- "REIT" to the sweep should be a row in Studio, not a deploy. `every-table-is-reachable.sql`
-- caught the select-only grant — the fourth new table it has caught that way.
grant select, insert, update, delete on market.exchange_sweep_type to service_role;
grant select on market.exchange_sweep_type to anon, authenticated;

-- Existing venues have finished Common Stock, so point them at the next type rather than making
-- them re-enumerate 59,324 rows they already hold. `next_cursor` is cleared because a cursor is
-- only meaningful within one type's enumeration.
--
-- ONE-SHOT. Migrations re-run on every deploy, and this is a data repair: left unguarded it would
-- yank every venue back to 'Depositary Receipt' on each deploy, including ones that had finished
-- receipts and moved on — the sweep would then never complete anything.
do $$
begin
  if exists (select 1 from market.one_shot where key = '53-point-swept-venues-at-receipts') then
    return;
  end if;

  update market.exchange_cursor
     set security_type = 'Depositary Receipt', next_cursor = null
   where security_type = 'Common Stock'
     and next_cursor is null
     and last_run_at is not null;

  insert into market.one_shot (key, reason) values
    ('53-point-swept-venues-at-receipts',
     'Venues that had finished Common Stock were moved to Depositary Receipt once, rather than re-enumerating rows already held.');
end $$;

notify pgrst, 'reload schema';
