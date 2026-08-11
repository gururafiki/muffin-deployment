-- Every backlog view must be SATISFIABLE: doing the work must remove the row.
--
-- WHY. `pending_industry` asked "has a level-1 sector, has no level-2 industry" and expressed the
-- second half as a left join plus `where … is null`. A `where` filters ROWS, not securities, so a
-- security kept qualifying through its own level-1 rows and could never leave the backlog no matter
-- how many industries it was given. Nothing errored. `security-industries` reported
-- `classified: 282, ok: true` on every run while re-fetching the same top-300 names by fund weight
-- forever — 345 securities classified against 8,412 with a sector, and `security.market_cap` frozen
-- at 386 of 10,060 because the cap rides along on the same response.
--
-- A count-based check cannot catch this (the counts look plausible and simply never move), and the
-- production guard in `market-verify.yml` only speaks after a deploy. This runs offline, on an empty
-- database, against the real migration files.
--
-- Run by the `migrations` job in quality.yml AFTER the two application passes.

\set ON_ERROR_STOP on

begin;

insert into market.security (security_id, name, security_type_code, country_iso2, is_tradeable)
values ('00000000-0000-0000-0000-00000000000a', 'Classified Co',   'equity', 'US', true),
       ('00000000-0000-0000-0000-00000000000b', 'Unclassified Co', 'equity', 'US', true);

insert into market.security_identifier (kind_code, value, security_id, source_code)
values ('ticker', 'FIXA', '00000000-0000-0000-0000-00000000000a', 'openfigi'),
       ('ticker', 'FIXB', '00000000-0000-0000-0000-00000000000b', 'openfigi');

insert into market.taxonomy_node (taxonomy_id, code, name, level)
values ('muffin', 'test-sector', 'Test Sector', 1);
insert into market.taxonomy_node (taxonomy_id, code, name, level, parent_id)
select 'muffin', 'test-sector--sub', 'Test Sub', 2, node_id
  from market.taxonomy_node where taxonomy_id = 'muffin' and code = 'test-sector';

-- THE SHAPE THAT BROKE IT: the level-1 sector arrives from two sources, exactly as production has
-- it (a filing and a provider both classify the same security). One extra level-1 row is all it
-- took for the left-join form to keep the security queued.
insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
select v.s, n.node_id, w.src, now()
  from (values ('00000000-0000-0000-0000-00000000000a'::uuid),
               ('00000000-0000-0000-0000-00000000000b'::uuid)) v(s),
       (values ('yfinance'), ('sec-nport')) w(src),
       market.taxonomy_node n
 where n.taxonomy_id = 'muffin' and n.code = 'test-sector';

-- Only FIXA has been given its industry.
insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
select '00000000-0000-0000-0000-00000000000a', node_id, 'yfinance', now()
  from market.taxonomy_node where taxonomy_id = 'muffin' and code = 'test-sector--sub';

do $$
declare
  classified_still_queued int;
  unclassified_queued     int;
begin
  select count(*) into classified_still_queued
    from market.pending_industry where symbol = 'FIXA';
  select count(*) into unclassified_queued
    from market.pending_industry where symbol = 'FIXB';

  -- The livelock: work was done and the row stayed.
  if classified_still_queued <> 0 then
    raise exception
      'pending_industry is UNSATISFIABLE: FIXA has a level-2 industry and is still queued (% rows). '
      'The "no industry" half must be a not-exists over the SECURITY, not a left join plus is-null.',
      classified_still_queued;
  end if;

  -- The opposite failure: a backlog that excludes work it should be doing is just as silent.
  if unclassified_queued <> 1 then
    raise exception
      'pending_industry dropped work: FIXB has a sector and no industry but appears % times, expected 1.',
      unclassified_queued;
  end if;

  raise notice '  ok  pending_industry is satisfiable (classified leaves, unclassified stays)';
end $$;

rollback;
