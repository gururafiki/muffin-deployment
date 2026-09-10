-- ASK SEC BY THE SYMBOL SEC USES, OR A NEGATIVE CACHE RECORDS OUR TYPO AS THE COMPANY'S ABSENCE.
--
-- Migration 188 fixed this for `apply_cik_map`: `security_identifier.ticker` is OpenFIGI's US
-- lookup and spells Berkshire's B share `BRK/B`, while SEC and the market spell it `BRK-B`.
-- `pending_statements.us_ticker` is that same identifier, and `security-statements` passes it
-- straight to `equity/fundamental/{income,balance,cash}?provider=sec`.
--
-- Measured 2026-09-06 against the deployed openbb-api:
--
--     symbol=BRK/B      -> {"detail":"Could not find CIK for symbol: BRK/B"}
--     symbol=BRK-B      -> 200, full annual statements
--     symbol=1067983    -> {"detail":"Could not find CIK for symbol: 1067983"}   (a CIK is refused)
--
-- ON ITS OWN THAT WAS MERELY A MISS. It becomes a WRONG RECORD the moment migration 191's sibling
-- change (PR #324) starts treating `Could not find CIK for symbol` as a per-symbol absence — which
-- it is, and which the `no_currency` half of the backlog needs in order to drain at all. Without
-- this migration that change would stamp `statement_currency_missing_at` on Berkshire and exclude
-- it for 30 days, having asked under a name SEC has never used. This file already states the rule:
-- **a wrong name is not a missing security, and only the provider can tell you which** — so the
-- spelling has to be ruled out BEFORE an absence is recorded, not after.
--
-- WORTH EXACTLY ONE SECURITY TODAY, and that is the honest number: of 3,050 securities in the
-- `no_currency` half, one has a US listing symbol differing from its ticker identifier. It is
-- Berkshire Hathaway, a 12.46% fund weight that had NO SEC data at all until migration 188 this
-- morning, so the alternative is re-breaking it the same day. The guard is what generalises, not
-- the count: every future security whose OpenFIGI spelling diverges is now asked correctly.
--
-- ONLY US VENUES, via `exchange.country_iso2` rather than the literal `exch_code` — SEC's map
-- covers US registrants, and a foreign venue's symbol colliding with a US ticker would ask about a
-- different company entirely. Same guard, same reason, as migration 188.

drop view if exists market.pending_statements;
create view market.pending_statements as
select s.security_id,
       coalesce(ps.symbol, t.value) as symbol,
       -- THE SYMBOL SEC ITSELF LISTS THE SECURITY UNDER, falling back to OpenFIGI's ticker where
       -- no US listing is recorded. A preference, never a filter: a security with no US listing
       -- must still be attempted, or it silently leaves the backlog instead of being asked.
       coalesce(us.symbol, t.value) as us_ticker,
       case when st.security_id is null then 'missing' else 'no_currency' end as want,
       coalesce(max(h.weight), 0::numeric) as best_weight
  from market.security s
  left join market.security_provider_symbol ps
    on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
  left join market.security_identifier t
    on t.security_id = s.security_id and t.kind_code = 'ticker'
  left join lateral (
    select l.symbol
      from market.listing l
      join market.exchange e on e.exch_code = l.exch_code
     where l.security_id = s.security_id
       and e.country_iso2 = 'US'
       and l.symbol is not null
     order by l.is_primary desc, l.symbol
     limit 1
  ) us on true
  left join lateral (
    select x.security_id,
           count(*) filter (where x.currency is not null) as with_currency
      from market.security_statement x
     where x.security_id = s.security_id
     group by x.security_id
  ) st on true
  left join market.fund_holding_current h on h.security_id = s.security_id
 where s.security_type_code = 'equity'
   and coalesce(ps.symbol, t.value) is not null
   and (s.statements_missing_at is null or s.statements_missing_at < now() - interval '30 days')
   and (
     st.security_id is null
     or (
       st.with_currency = 0
       and t.value is not null
       and s.cik is not null
       and (s.statement_currency_missing_at is null
            or s.statement_currency_missing_at < now() - interval '30 days')
     )
   )
 group by s.security_id, coalesce(ps.symbol, t.value), coalesce(us.symbol, t.value), t.value,
          st.security_id, st.with_currency
 order by coalesce(max(h.weight), 0::numeric) desc, s.security_id;

comment on view market.pending_statements is
  'Equities needing statements, or needing a currency for the ones they have. `us_ticker` is the symbol a US venue lists the security under, falling back to the OpenFIGI ticker identifier — SEC is asked by it, and OpenFIGI spells Berkshire''s B share BRK/B where SEC uses BRK-B. Asking under the wrong name and then recording the 404 as an absence would negative-cache a company SEC serves perfectly.';

-- A DROP TAKES THE GRANTS WITH IT, and superuser cannot see that (migration 189, same week).
grant select on market.pending_statements to service_role;

notify pgrst, 'reload schema';
