-- SEC'S OWN INDUSTRY CODE IS A CLASSIFICATION, NOT TWO COLUMNS NOBODY JOINS.
--
-- `security-filing-history` writes `security.sic` and `sic_description` from the submissions
-- response — a real opinion, assigned by SEC from the registrant's own description of its business,
-- and therefore neither a provider's nor a fund's. It sat unjoined until migration 151.
--
-- The value is that it DISAGREES and that it exists independently: a filer has a SIC whether or not
-- yfinance has ever answered for its symbol. So the assertions here are about coexistence — SEC's
-- opinion must not displace the one every page already reads.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZS','Sicland','ZS',false)
  on conflict (iso2) do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik, sic) values
  ('00000000-0000-0000-0000-000000015101','T151 Computer Co','equity','ZS','0000320193','3571'),
  -- A 3-digit code, which SEC really does assign (0100 AGRICULTURAL PRODUCTION-CROPS is listed as
  -- `100`). Stored unpadded it would join nothing.
  ('00000000-0000-0000-0000-000000015102','T151 Farm Co','equity','ZS','0000000002','100'),
  ('00000000-0000-0000-0000-000000015103','T151 No Filer','equity','ZS',null,null)
on conflict (security_id) do update set sic = excluded.sic;

-- The security also has a yfinance sector, which must survive.
insert into market.taxonomy_node (node_id, taxonomy_id, code, name, level) values
  ('00000000-0000-0000-0000-0000001510a1','muffin','t151-tech','Information technology',1)
on conflict (taxonomy_id, code) do nothing;
insert into market.security_taxonomy (security_id, node_id, source_code) values
  ('00000000-0000-0000-0000-000000015101','00000000-0000-0000-0000-0000001510a1','yfinance')
on conflict do nothing;

do $$
declare n integer; nm text;
begin
  perform market.derive_sic_classification();

  -- 1. THE FILER IS LINKED TO SEC'S OWN NODE, with SEC's own title.
  select tn.name into nm
    from market.security_taxonomy st
    join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'sic'
   where st.security_id = '00000000-0000-0000-0000-000000015101' and st.source_code = 'sic';
  if nm is distinct from 'ELECTRONIC COMPUTERS' then
    raise exception 'SIC 3571 should link to ELECTRONIC COMPUTERS, got %', nm;
  end if;

  -- 2. A 3-DIGIT CODE IS ZERO-PADDED. SEC lists 0100 as `100`, so an unpadded join silently
  --    classifies nothing for every agricultural, mining and construction filer.
  select tn.code into nm
    from market.security_taxonomy st
    join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'sic'
   where st.security_id = '00000000-0000-0000-0000-000000015102' and st.source_code = 'sic';
  if nm is distinct from '0100' then
    raise exception 'a 3-digit SIC must be padded to 4 to join, got %', nm;
  end if;

  -- 3. A SECURITY WITH NO SIC GETS NOTHING, rather than a spurious link.
  select count(*) into n from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000015103';
  if n <> 0 then raise exception 'a security with no SIC must not be classified, got % rows', n; end if;

  -- 4. THE PROVIDER'S OPINION SURVIVES, AND STILL WINS. `security_current.sector_id` resolves by
  --    source priority, and SIC is seeded at 70 against yfinance's 100 precisely so that every
  --    sector page, donut and facet reads exactly as it did before.
  select count(*) into n from market.security_taxonomy
   where security_id = '00000000-0000-0000-0000-000000015101';
  if n <> 2 then raise exception 'both classifications must coexist, got % rows', n; end if;
  select ds.code into nm
    from market.security_taxonomy st
    join market.data_source ds on ds.code = st.source_code
   where st.security_id = '00000000-0000-0000-0000-000000015101'
   order by ds.priority desc limit 1;
  if nm <> 'yfinance' then
    raise exception 'SIC must not outrank the provider sector a page reads, winner was %', nm;
  end if;

  -- 5. AND IT MUST BE VISIBLE. `security_industries` filtered `taxonomy_id = 'muffin'` when it was
  --    written, so SIC and Wikidata — the two sources whose entire purpose is to be a second
  --    opinion — were stored correctly and served by nothing. Measured in production: 36 SIC
  --    classifications, zero of them readable.
  select count(*) into n from market.security_industries
   where security_id = '00000000-0000-0000-0000-000000015101' and source_code = 'sic';
  if n <> 1 then
    raise exception
      'security_industries must expose the SIC classification, got % rows — a view that hides a source hides the feature', n;
  end if;

  raise notice '  ok  SEC''s industry is a second opinion that coexists, is visible, and does not outrank';
end $$;

do $$
declare n integer;
begin
  -- 5. IT RETRACTS. A registrant whose SIC changes must lose the old link — an upsert cannot.
  update market.security set sic = '2080'
   where security_id = '00000000-0000-0000-0000-000000015101';
  perform market.derive_sic_classification();
  select count(*) into n
    from market.security_taxonomy st
    join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'sic'
   where st.security_id = '00000000-0000-0000-0000-000000015101' and tn.code = '3571';
  if n <> 0 then raise exception 'a changed SIC must drop the old link, still % rows', n; end if;
  select count(*) into n
    from market.security_taxonomy st
    join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'sic'
   where st.security_id = '00000000-0000-0000-0000-000000015101' and tn.code = '2080';
  if n <> 1 then raise exception 'the new SIC must be linked, got % rows', n; end if;
  raise notice '  ok  a changed SIC replaces its link rather than accumulating one';
end $$;

rollback;
