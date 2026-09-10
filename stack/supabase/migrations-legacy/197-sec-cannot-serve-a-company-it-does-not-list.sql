-- SEC CANNOT SERVE A COMPANY IT DOES NOT LIST, AND ASKING IT 2,317 TIMES A MONTH IS NOT FREE.
--
-- `pending_statements` has two halves: `missing` (no statements at all) and `no_currency` (has
-- them, from yfinance, which carries no currency field — so SEC is asked for a figure that states
-- its own). The second half was scoped on having a CIK and a ticker, and both are satisfied by
-- companies SEC has never heard of.
--
-- Measured 2026-09-07, a day after the marking fix (PR #324) let this half drain at all:
--
--     no_currency                            2,817
--       ..has a US listing                     500
--       ..NO US listing                      2,317
--     of those 2,317, ever served by SEC          0
--
-- Zero of 2,317. That is the same evidence migration 088 used to scope this resource on the CIK —
-- not an inference from shape, but the observation that the population has never once been served.
--
-- AND THE COST IS THE OTHER HALF OF THE QUEUE. It is weight-ordered, so those 2,317 sit at the
-- head: measured across the same day, `no_currency` fell 3,050 -> 2,817 while `missing` went
-- 2,922 -> **2,921**. Securities with no statements at all were starving behind securities that
-- can never be helped, and every 30 days the negative cache expires and they return.
--
-- A PREFERENCE ELSEWHERE, A FILTER HERE, AND THE DIFFERENCE IS DELIBERATE. Migration 192 made
-- `us_ticker` PREFER the US listing symbol while still falling back, because a security with no
-- listing should still be attempted. This is the opposite case: it is not about which name to ask
-- with, it is about whether asking can ever work. The `missing` half is untouched — a security
-- with no statements is still tried through yfinance, which needs no US listing.

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
       -- AND SEC MUST ACTUALLY LIST IT. Measured 2026-09-07: of 2,817 securities in this half,
       -- 2,317 have NO US listing, and **ZERO of those 2,317 have ever received a sec-sourced
       -- statement**. Asking is provably futile, and it is not free — they hold the head of a
       -- weight-ordered queue, so the `missing` half went 2,922 -> 2,921 in a day while this half
       -- drained 233. The securities with no statements AT ALL were starving behind securities
       -- that can never be helped.
       --
       -- `t.value is not null` above is NOT this test. That is OpenFIGI's US lookup, which returns
       -- a thin OTC foreign-ordinary line for most foreign companies — the same distinction
       -- migration 123 drew for the EPS backlog, and the reason `us_ticker` above already prefers
       -- the listing symbol. Having a ticker is not being listed.
       and exists (
         select 1 from market.listing l
           join market.exchange e on e.exch_code = l.exch_code
          where l.security_id = s.security_id
            and e.country_iso2 = 'US'
            and l.symbol is not null
       )
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
