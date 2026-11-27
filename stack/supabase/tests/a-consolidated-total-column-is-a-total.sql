-- A note's consolidated-total column is a total label, whatever it is called (migration
-- 20261127150000). THE TEST RUNS THE MIGRATION ITSELF, from the state before it, because a data
-- migration's effect cannot be undone by re-applying a mutated copy on top of it: the state is
-- set back to version 1 inside this transaction and the file is read with \i.

\set ON_ERROR_STOP on

begin;

delete from market.segment_note_rule where regulator = 'edinet' and rule = 'label' and role = 'total';
insert into market.segment_note_rule (regulator, rule, pattern, role, priority)
values ('edinet', 'label', '^\(?(連結|合計|総計|計)\)?$|計上額$|^報告セグメント計$', 'total', 110);
update market.segment_parser set version = 1 where regulator = 'edinet';

\i stack/supabase/migrations/20261127150000_a_consolidated_total_column_is_a_total.sql

do $$
declare
  label text;
begin
  foreach label in array array['連結', '連結合計', '連結計', '合計', '計', '(連結)'] loop
    if not exists (select 1 from market.segment_note_rule
                    where regulator = 'edinet' and rule = 'label' and role = 'total'
                      and label ~ pattern) then
      raise exception 'no EDINET total rule reads % as a total', label;
    end if;
  end loop;
  foreach label in array array['連結子会社', '国内損害保険事業', '合計額の内訳'] loop
    if exists (select 1 from market.segment_note_rule
                where regulator = 'edinet' and rule = 'label' and role = 'total'
                  and label ~ pattern) then
      raise exception 'an EDINET total rule reads the segment-like label % as a total', label;
    end if;
  end loop;
  if (select count(*) from market.segment_note_rule
       where regulator = 'edinet' and rule = 'label' and role = 'total') <> 1 then
    raise exception 'the old total rule was not replaced';
  end if;
  if (select version from market.segment_parser where regulator = 'edinet') < 2 then
    raise exception 'the EDINET parser version was not raised, so version-1 reads stand';
  end if;
end $$;

rollback;
