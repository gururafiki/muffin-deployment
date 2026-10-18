-- SEC IS ASKED BY `us_ticker`, AND THAT MUST BE THE SPELLING SEC USES.
--
-- WHY THIS EXISTS AS A TEST. On its own, asking under the wrong name is a miss. It becomes a WRONG
-- RECORD once `security-statements` treats `Could not find CIK for symbol` as a per-symbol absence
-- — which it now does, and must, or the backlog can never drain. The two changes are individually
-- correct and together they negative-cache a company SEC serves perfectly. Measured 2026-09-06:
-- `symbol=BRK/B` returns "Could not find CIK for symbol: BRK/B" while `symbol=BRK-B` returns full
-- annual statements, and a CIK is refused outright.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. Three rules could be written and two are wrong:
--
--   * "use the ticker identifier"            — asks BRK/B. The shipped defect.             (row 1)
--   * "use the primary listing, any country" — asks a foreign venue's symbol, which can collide
--                                              with a US ticker and name another company. (row 3)
--   * "use a US listing's symbol"            — what ships.
--
-- 2026-10-18: THE QUEUE IS SEC'S ALONE, so a security with no US listing is not asked at all
-- (row 2). It used to be, in the `missing` half yfinance served, with `us_ticker` falling back to
-- the ticker identifier. Yahoo's statements are the Dagster company lane's now, and SEC cannot be
-- asked about a security it does not list. Row 1 carries a second US listing, so "one row per
-- security" still has two candidates to choose between.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('US','United States','US',true), ('ZS','Spellland','ZS',false) on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values
  ('US','US',''), ('ZU','US',''), ('ZS','ZS','.ZS') on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  -- 1. THE BERKSHIRE SHAPE: OpenFIGI spells it with a slash, the market and SEC with a hyphen.
  ('00000000-0000-0000-0000-000000192a01','T192 Dual Class','equity','US',1920001),
  -- 2. No US listing at all. SEC is not asked about it, under any spelling.
  ('00000000-0000-0000-0000-000000192a02','T192 No Us Listing','equity','ZS',1920002),
  -- 3. A PRIMARY foreign listing whose symbol would be a plausible US ticker, beside a US line.
  ('00000000-0000-0000-0000-000000192a03','T192 Foreign Venue','equity','ZS',1920003)
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000192a01','ticker','T192/B'),
  ('00000000-0000-0000-0000-000000192a02','ticker','T192NOUS'),
  ('00000000-0000-0000-0000-000000192a03','ticker','T192FGN')
on conflict (kind_code, value) do nothing;

insert into market.listing (security_id, exch_code, symbol, is_primary) values
  ('00000000-0000-0000-0000-000000192a01','US','T192-B', true),
  -- A second US venue, not primary: the lateral must still return ONE symbol, the primary's.
  ('00000000-0000-0000-0000-000000192a01','ZU','T192-B2', false),
  ('00000000-0000-0000-0000-000000192a03','ZS','T192XX', true),
  ('00000000-0000-0000-0000-000000192a03','US','T192FG', false)
on conflict (security_id, exch_code) do nothing;

-- Row 1 holds Yahoo's statements (the `no_sec` half); rows 2 and 3 hold none (the `missing` half).
insert into market.data_source (code, name) values ('yfinance','yfinance') on conflict do nothing;
insert into market.security_statement
  (security_id, statement, period_ending, period_type, data, source_code, currency, as_of)
select sid, 'income', date '2025-12-31', 'annual', '{}'::jsonb, 'yfinance', null, now()
  from unnest(array['00000000-0000-0000-0000-000000192a01']::uuid[]) sid
on conflict do nothing;

do $$
declare v_dual text; v_fgn text; v_rows int; v_nous int;
begin
  select us_ticker into v_dual from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000192a01';
  select us_ticker into v_fgn  from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000192a03';
  select count(*) into v_nous from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000192a02';

  if v_dual is distinct from 'T192-B' then
    raise exception 'SEC would be asked with % rather than the US listing symbol T192-B — OpenFIGI '
                    'spells Berkshire''s B share BRK/B and SEC has never used that name, so the '
                    '404 gets recorded as the company having no filings',
                    coalesce(v_dual,'null');
  end if;

  if v_fgn is distinct from 'T192FG' then
    raise exception 'SEC would be asked with % rather than the US line T192FG — a FOREIGN venue''s '
                    'symbol (T192XX) or the ticker identifier (T192FGN) supplied the name; SEC '
                    'covers US registrants, so a foreign symbol colliding with a US ticker asks '
                    'about a different company', coalesce(v_fgn,'null');
  end if;

  if v_nous <> 0 then
    raise exception 'a security with no US listing is queued (% rows) — SEC cannot be asked about '
                    'it, and since 2026-10-18 no other provider is asked here', v_nous;
  end if;

  -- One row per security, not one per listing: the lateral must pick a single symbol.
  select count(*) into v_rows from market.pending_statements
   where security_id in ('00000000-0000-0000-0000-000000192a01',
                         '00000000-0000-0000-0000-000000192a02',
                         '00000000-0000-0000-0000-000000192a03');
  if v_rows <> 2 then
    raise exception 'the backlog returned % rows for the 2 securities SEC can be asked about — a '
                    'security with several US listings must be asked about once', v_rows;
  end if;

  raise notice 'ok  SEC is asked by its own spelling, from a US line, and only where it lists';
end $$;

rollback;
