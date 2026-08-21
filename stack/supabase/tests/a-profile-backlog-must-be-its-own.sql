-- A NEW FIELD FILLED BY AN EXISTING RESOURCE IS INERT WITHOUT ITS OWN BACKLOG.
--
-- Migration 56 added `provider_country_iso2`, the resource wrote it correctly, the typecheck passed,
-- three migration passes passed — and production sat at ZERO rows populated, because the backlog
-- driving that resource asks for securities with no SECTOR and was drained. Nothing could report it:
-- the resource was succeeding.
--
-- `pending_profile_detail` exists so the same thing cannot happen to the descriptive fields. This
-- test pins the distinction that makes it necessary — a security with a sector but no profile is
-- INVISIBLE to `pending_profile` and must be VISIBLE here.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Profileland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000011301','T113 Wanted','equity','ZW'),
  ('00000000-0000-0000-0000-000000011302','T113 Has one','equity','ZW'),
  ('00000000-0000-0000-0000-000000011303','T113 No symbol','equity','ZW')
on conflict (security_id) do nothing;

insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T113A','00000000-0000-0000-0000-000000011301','yfinance'),
  ('ticker','T113B','00000000-0000-0000-0000-000000011302','yfinance')
on conflict (kind_code, value) do nothing;

-- T113A IS ALREADY CLASSIFIED AND ALREADY HAS ITS OPERATING COUNTRY, which is the production
-- situation: `pending_profile` is drained. That is precisely what makes it invisible to the sector
-- backlog and visible only to this one — assertion 5 is what would have caught migration 56.
insert into market.taxonomy (taxonomy_id, name) values ('yf','Provider taxonomy') on conflict (taxonomy_id) do nothing;
insert into market.taxonomy_node (node_id, taxonomy_id, code, name, level)
  values ('00000000-0000-0000-0000-0000000113aa','yf','tech','Technology',1)
on conflict (node_id) do nothing;
insert into market.security_taxonomy (security_id, node_id, source_code) values
  ('00000000-0000-0000-0000-000000011301','00000000-0000-0000-0000-0000000113aa','yfinance')
on conflict do nothing;
update market.security set provider_country_iso2 = 'ZW'
 where security_id = '00000000-0000-0000-0000-000000011301';

insert into market.security_profile (security_id, description, source_code) values
  ('00000000-0000-0000-0000-000000011302','Already described','yfinance')
on conflict (security_id) do nothing;

do $$
declare n integer;
begin
  -- 1. A SECURITY WITH NO PROFILE IS QUEUED.
  select count(*) into n from market.pending_profile_detail where symbol = 'T113A';
  if n <> 1 then raise exception 'a security with no profile is not queued (% rows)', n; end if;

  -- 2. ONE THAT HAS A PROFILE HAS LEFT. The anti-join is over the SECURITY; a `where` over rows
  --    would keep it queued for ever, which is the defect that re-fetched `pending_industry`'s
  --    first 300 securities for months.
  select count(*) into n from market.pending_profile_detail where symbol = 'T113B';
  if n <> 0 then raise exception 'a described security is still queued — the backlog cannot drain'; end if;

  -- 3. ONE WITH NO SYMBOL IS NOT QUEUED. The fetch is by symbol; queueing a security we cannot ask
  --    about spends the page on something that can never answer.
  select count(*) into n from market.pending_profile_detail
   where security_id = '00000000-0000-0000-0000-000000011303';
  if n <> 0 then raise exception 'a security with no symbol is queued — it can never be asked about'; end if;

  -- 4. THE NEGATIVE CACHE REMOVES IT, AND EXPIRES. A company the provider carries nothing for must
  --    stop crowding the page, but "never" is wrong — a listing gains coverage.
  update market.security set profile_detail_missing_at = now()
   where security_id = '00000000-0000-0000-0000-000000011301';
  select count(*) into n from market.pending_profile_detail where symbol = 'T113A';
  if n <> 0 then raise exception 'a negative-cached security is still queued'; end if;

  update market.security set profile_detail_missing_at = now() - interval '31 days'
   where security_id = '00000000-0000-0000-0000-000000011301';
  select count(*) into n from market.pending_profile_detail where symbol = 'T113A';
  if n <> 1 then raise exception 'an expired mark did not re-queue — the cache is permanent, not a cache'; end if;

  -- 5. AND THE DISTINCTION THAT MAKES THIS VIEW NECESSARY: `pending_profile` asks about the SECTOR,
  --    so a security that HAS one is invisible to it. Widening that backlog instead of adding this
  --    one is how a correctly-written resource populates zero rows and reports success.
  perform 1 from market.pending_profile where symbol = 'T113A';
  if found then
    raise exception 'the sector backlog also offers this security — the test cannot show why a separate backlog is needed';
  end if;
end $$;

rollback;

\echo 'ok: a profile backlog must be its own'
