-- EACH REGULATOR HAS ITS OWN SEGMENT PARSER VERSION (Phase 6c decision 4, migration 20261126180000).
--
-- A regulator's segment lane compares each filing's `segments_parser_version` against its own row
-- in `market.segment_parser`. An enabled regulator with no row has no version to compare against,
-- so its queue would be empty or undefined while the lane reports success. Enabling EDINET or ESEF
-- later without adding its row must therefore fail here.
--
-- `market.segment_total_concept` is a control table the worker reads: `ingest_rw` may read it and
-- may not rewrite it.
begin;
do $$
declare
  missing text;
begin
  select string_agg(d.code, ', ' order by d.code) into missing
    from market.disclosure_source d
   where d.enabled
     and not exists (select 1 from market.segment_parser p where p.regulator = d.code);
  if missing is not null then
    raise exception 'enabled regulators with no segment parser version: %', missing;
  end if;

  if (select count(*) from market.segment_parser) < 2 then
    raise exception 'segment_parser holds % row(s): the version is not per regulator',
      (select count(*) from market.segment_parser);
  end if;

  begin
    insert into market.segment_parser (regulator, version) values ('sec', 1);
    raise exception 'a second parser version for sec was accepted: the regulator is not the key';
  exception when unique_violation then
    null;
  end;

  begin
    insert into market.segment_parser (regulator, version) values ('no-such-regulator', 1);
    raise exception 'a parser version for an unknown regulator was accepted';
  exception when foreign_key_violation then
    null;
  end;

  begin
    insert into market.segment_total_concept (regulator, metric_code, concept)
         values ('no-such-regulator', 'revenue', 'Revenue');
    raise exception 'a segment total concept for an unknown regulator was accepted';
  exception when foreign_key_violation then
    null;
  end;

  -- A total is ordinary unless marked: a row added without thinking about it must not become a
  -- fallback, and a fallback must be said (migration 20261126190100).
  insert into market.segment_total_concept (regulator, metric_code, concept)
       values ('sec', 'revenue', 'T-ordinary');
  if (select fallback from market.segment_total_concept where concept = 'T-ordinary') then
    raise exception 'a segment total concept is a fallback unless marked otherwise';
  end if;

  if not has_table_privilege('ingest_rw', 'market.segment_total_concept', 'select') then
    raise exception 'ingest_rw cannot read segment_total_concept, which its segment parsers need';
  end if;
  if has_table_privilege('ingest_rw', 'market.segment_total_concept', 'insert')
     or has_table_privilege('ingest_rw', 'market.segment_total_concept', 'update')
     or has_table_privilege('ingest_rw', 'market.segment_total_concept', 'delete') then
    raise exception 'ingest_rw may rewrite segment_total_concept: the worker would edit its own vocabulary';
  end if;
end $$;
rollback;
