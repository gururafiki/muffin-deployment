-- MIGRATION FILENAMES MUST SORT NUMERICALLY UNDER A LEXICOGRAPHIC SORT.
--
-- WHY THIS IS A TEST. Every place that enumerates migrations sorts them as STRINGS: Ansible's
-- Jinja `| sort` (which has no numeric option at all), CI's `ls | sort`, and the local harness.
-- That is invisible for 99 migrations and wrong on the hundredth — `100-news.sql` sorts between
-- `02-market.sql` and `29-...`, so it runs before the schema it depends on and the deploy fails
-- on a file that is perfectly correct.
--
-- Zero-padding to three digits makes lexicographic order BE numeric order, needing no `sort -V`
-- (which busybox does not always have) and no Jinja gymnastics. This asserts the shape holds, so
-- the next person adding `1000-` is told rather than discovering it on a deploy.
--
-- It runs as a SQL test because that is where this repo's behaviour checks live, and it needs no
-- database — the assertion is about filenames.

\set ON_ERROR_STOP on

do $$
declare
  bad text;
begin
  -- `pg_ls_dir` is superuser-only, which the migration tests are; production never runs this file.
  select string_agg(f, ', ')
    into bad
    from pg_ls_dir('/repo/stack/supabase/migrations') as f
   where f like '%.sql'
     and f !~ '^[0-9]{3}-';
  if bad is not null then
    raise exception
      'migration filenames must start with a THREE-DIGIT zero-padded number: %. Every enumerator sorts them as strings — Jinja has no numeric sort — so `100-` would run between `02-` and `29-`', bad;
  end if;
end $$;

\echo 'ok: every migration filename sorts numerically under a plain string sort'
