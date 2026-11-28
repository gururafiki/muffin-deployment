-- Europe's segment notes are read by rule (migration 20261128100000).
--
-- The vocabulary itself is proven in muffin-ingest, against the mirror these rows were generated
-- from (`tests/unit/esef_rules.py`, nine captured reports, each rule mutation-proven). Here: the
-- rows exist where the lane reads them, nothing is enabled before the lane is live, and coverage
-- names only what the index holds. Label checks use only patterns free of `\b`, which a Postgres
-- regular expression reads as a backspace, not a word boundary: the lane matches with Python.

\set ON_ERROR_STOP on

begin;

do $$
declare
  label text;
begin
  if not exists (select 1 from market.data_source where code = 'xbrl-org') then
    raise exception 'xbrl-org must be a data_source: every ESEF filing and segment row names it';
  end if;
  if (select enabled from market.disclosure_source where code = 'esef') then
    raise exception 'esef must stay disabled until the lane has read a tiny subset live';
  end if;
  if not exists (select 1 from market.segment_parser where regulator = 'esef') then
    raise exception 'esef has no parser version: its queue would compare against NULL';
  end if;
  if not exists (select 1 from market.filing_form
                  where source_code = 'esef' and form_code = 'AFR' and is_annual and carries_segments) then
    raise exception 'the annual financial report must be an annual form that carries segments';
  end if;
  if (select string_agg(kind, ',' order by kind) from market.segment_axis where taxonomy = 'esef')
     is distinct from 'business,geography,product' then
    raise exception 'esef needs one axis of each kind, or security_segment_current drops its rows';
  end if;

  -- The index does not hold Germany or Switzerland: a company there is `none`, never `resolvable`.
  if exists (select 1 from market.disclosure_coverage
              where source_code = 'esef' and country_iso2 in ('DE', 'CH')) then
    raise exception 'esef must not cover a country the index does not hold';
  end if;
  if (select count(*) from market.disclosure_coverage where source_code = 'esef') <> 10 then
    raise exception 'esef covers % countries, not the 10 measured',
      (select count(*) from market.disclosure_coverage where source_code = 'esef');
  end if;

  if (select count(*) from market.segment_note_rule where regulator = 'esef' and rule = 'block') < 1
     or (select count(*) from market.segment_note_rule where regulator = 'esef' and rule = 'heading') < 1
     or (select count(*) from market.segment_note_rule where regulator = 'esef' and rule = 'label') < 1 then
    raise exception 'the reader refuses a vocabulary with no block, heading or label';
  end if;

  foreach label in array array['Ventes hors Groupe', 'Ventas a terceros', 'Intäkter från externa kunder',
                               'Total net sales', 'Revenue and other income from third parties'] loop
    if (select role from market.segment_note_rule
         where regulator = 'esef' and rule = 'label' and role = 'revenue' and label ~ pattern
         limit 1) is distinct from 'revenue' then
      raise exception 'the esef label % must read as revenue', label;
    end if;
  end loop;
  -- LVMH's gross line is no revenue label: it must reach its metric by arithmetic, or not at all.
  if exists (select 1 from market.segment_note_rule
              where regulator = 'esef' and rule = 'label' and role = 'revenue'
                and 'Total des ventes' ~ pattern) then
    raise exception 'Total des ventes (gross of intra-group sales) must not read as revenue';
  end if;
  if not exists (select 1 from market.segment_note_rule
                  where regulator = 'esef' and rule = 'label' and role = 'total' and 'Gruppen' ~ pattern) then
    raise exception 'Gruppen (Atlas Copco''s group column) must read as the total';
  end if;
end $$;

\echo ok: Europe's segment notes are read by rule, and nothing is enabled before the lane is live

rollback;
