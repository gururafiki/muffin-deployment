-- NSE ANSWERS AN UNKNOWN SYMBOL WITH AN EMPTY 200, SO ASKING WRONGLY LOOKS EXACTLY LIKE SUCCESS.
--
-- WHY THIS EXISTS AS A TEST. `pending_in_history` shipped reading `market.listing.symbol`, on the
-- strength of a planning probe against RELIANCE, HDFCBANK and INFY — three symbols that happen to
-- match NSE's own. Measured 2026-09-06 against NSE's published equity list, only 239 of 645 Indian
-- equities carry a listing symbol NSE recognises; the rest hold a vendor abbreviation. Confirmed
-- against the provider: SUEL returns 0 results and SUZLON 39, HUVR 0 and HINDUNILVR 38. The
-- resource reported `walked: 6, mapped: 0, failed: 0` — succeeding at asking the wrong question,
-- with no count in the system able to show it.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. Every security below has a listing symbol that
-- is NOT its NSE symbol, so a backlog still reading `listing.symbol` fails on all of them; and the
-- security NSE does not list keeps its listing symbol, so a rule that simply dropped unresolved
-- securities would pass the first assertion and fail the last.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('IN','India','IN',true), ('ZN','Notindia','ZN',false) on conflict (iso2) do nothing;
insert into market.data_source (code, name) values ('nse','NSE') on conflict do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values
  ('IN','IN','.NS'), ('ZN','ZN','.ZN') on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  -- 1. The ordinary case: a vendor abbreviation that NSE does not know.
  ('00000000-0000-0000-0000-000000190a01','T190 Suzlon-like','equity','IN'),
  -- 2. A second one, so a single-row fixture cannot pass by luck.
  ('00000000-0000-0000-0000-000000190a02','T190 Unilever-like','equity','IN'),
  -- 3. NSE does not list this company. It must keep its listing symbol and stay in the queue —
  --    dropping it would silently shrink the universe rather than fail to resolve one name.
  ('00000000-0000-0000-0000-000000190a03','T190 Unlisted','equity','IN'),
  -- 4. NOT INDIAN, and its ISIN is deliberately in the map. A filer id is per (security,
  --    regulator): writing one here advertises a filing route that does not exist.
  ('00000000-0000-0000-0000-000000190a04','T190 Foreign','equity','ZN'),
  -- 5. Two NSE symbols claim this ISIN. That is not a tie to break with min().
  ('00000000-0000-0000-0000-000000190a05','T190 Ambiguous','equity','IN')
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000190a01','isin','INE190T01011'),
  ('00000000-0000-0000-0000-000000190a02','isin','INE190T01029'),
  ('00000000-0000-0000-0000-000000190a03','isin','INE190T01037'),
  ('00000000-0000-0000-0000-000000190a04','isin','ZN190T010045'),
  ('00000000-0000-0000-0000-000000190a05','isin','INE190T01052'),
  -- THE RIVALRY IS SET UP BEFORE ANY CALL. A jsonb object cannot hold one key twice, so two
  -- symbols claiming one security is expressed as two ISINs it holds, each claimed by a different
  -- NSE listing. Adding this AFTER a first successful call would test nothing: the row would
  -- already be written, and the function does not delete — it declines to write.
  ('00000000-0000-0000-0000-000000190a05','isin','INE190T01060')
on conflict (kind_code, value) do nothing;

-- EVERY listing symbol is a vendor abbreviation, so nothing here can pass by accident.
insert into market.listing (security_id, exch_code, symbol, is_primary) values
  ('00000000-0000-0000-0000-000000190a01','IN','T190SUEL', true),
  ('00000000-0000-0000-0000-000000190a02','IN','T190HUVR', true),
  ('00000000-0000-0000-0000-000000190a03','IN','T190NONE', true),
  ('00000000-0000-0000-0000-000000190a04','ZN','T190FGN',  true),
  ('00000000-0000-0000-0000-000000190a05','IN','T190AMB',  true)
on conflict (security_id, exch_code) do nothing;

do $$
declare
  v_updated int;
  v_one text; v_two text; v_none text; v_foreign text; v_ambig text;
begin
  select market.apply_nse_symbol_map(jsonb_build_object(
    'INE190T01011', 'T190SUZLON',      -- 1
    'INE190T01029', 'T190HINDUNILVR',  -- 2
    'ZN190T010045', 'T190WRONGCOUNTRY',-- 4: in the map, but the security is not Indian
    'INE190T01052', 'T190RIVALA',      -- 5: two symbols claim this security ...
    'INE190T01060', 'T190RIVALB'       -- 5: ... so it must resolve to NEITHER
  )) into v_updated;

  select symbol into v_one     from market.pending_in_history where security_id = '00000000-0000-0000-0000-000000190a01';
  select symbol into v_two     from market.pending_in_history where security_id = '00000000-0000-0000-0000-000000190a02';
  select symbol into v_none    from market.pending_in_history where security_id = '00000000-0000-0000-0000-000000190a03';
  select filer_id into v_foreign from market.security_filer where security_id = '00000000-0000-0000-0000-000000190a04' and source_code = 'nse';
  select filer_id into v_ambig from market.security_filer where security_id = '00000000-0000-0000-0000-000000190a05' and source_code = 'nse';

  if v_one is distinct from 'T190SUZLON' then
    raise exception 'the backlog still asks with the vendor abbreviation (got %, wanted T190SUZLON) '
                    '— NSE answers an unknown symbol with an EMPTY 200, so this reads as a company '
                    'that files nothing rather than as a question asked wrongly',
                    coalesce(v_one,'null');
  end if;

  if v_two is distinct from 'T190HINDUNILVR' then
    raise exception 'a second security did not resolve (got %) — one resolving row can pass by '
                    'luck', coalesce(v_two,'null');
  end if;

  if v_none is distinct from 'T190NONE' then
    raise exception 'a security NSE does not list lost its listing symbol (got %) — the resolved '
                    'id must be a PREFERENCE over the listing symbol, not a filter, or a company '
                    'absent from NSE''s list is silently dropped from the queue instead of tried',
                    coalesce(v_none,'null');
  end if;

  if v_foreign is not null then
    raise exception 'a non-Indian security was given an NSE filer id (%) — a filer id is per '
                    '(security, regulator), and one written here advertises a filing route that '
                    'does not exist', v_foreign;
  end if;

  if v_ambig is not null then
    raise exception 'two NSE symbols claimed one ISIN and min() picked % — that is not a tie to '
                    'break, it means we cannot say which listing this is, and a wrong filer id '
                    'attributes another company''s filings', v_ambig;
  end if;

  -- Idempotence: re-applying an unchanged map must write nothing. `history_walked_at` lives on
  -- this table, so a needless update is WAL for nothing on a resource that runs on a TTL.
  select market.apply_nse_symbol_map(jsonb_build_object(
    'INE190T01011', 'T190SUZLON', 'INE190T01029', 'T190HINDUNILVR')) into v_updated;
  if v_updated <> 0 then
    raise exception 're-applying an unchanged map wrote % rows — the "is distinct from" guard is '
                    'gone', v_updated;
  end if;

  raise notice 'ok  India asks with NSE''s own symbol, keeps the unlisted, and refuses both a '
               'foreign security and an ambiguous ISIN';
end $$;

rollback;
