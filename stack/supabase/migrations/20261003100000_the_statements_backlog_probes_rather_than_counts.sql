-- `pending_statements` asks whether a security has statements, and with a currency, by PROBING
-- rather than counting them.
--
-- WHY. `security-statements` has failed almost every run since 2026-09-24 with
-- `pending_statements read failed: canceling statement due to statement timeout`: 0 successes on
-- 09-30, 0 so far on 10-03. The view is read through PostgREST, whose role stops a statement at 8 s.
-- Measured 2026-09-30 on production with `explain analyze`: 8.6 s, of which 8.26 s is one
-- `GroupAggregate` over `security_statement`, run 12,055 times (once per equity) to compute
-- `count(*) filter (where currency is not null)`. That reads every statement row of every equity —
-- 192,951 rows of wide `data` jsonb, 354 MB — to learn two booleans. Nothing in the view changed;
-- the table grew past the ceiling.
--
-- THE TWO BOOLEANS, ASKED DIRECTLY.
--   has_any       does the security hold any statement?   An EXISTS on the primary key's leading
--                 column: one index probe, no heap row read.
--   has_currency  does it hold one WITH a currency?        An EXISTS on a new partial index over
--                 the 44,422 rows that carry one. Evaluated only inside the `no_currency` branch,
--                 after the cheap column tests, so it runs for the few thousand securities that
--                 branch can apply to rather than for every equity.
--
-- MEASURED BEFORE SHIPPING, on production, inside a rolled-back transaction that built the index:
-- the rewrite returns the SAME 55 rows as the shipped view, column for column (an EXCEPT in both
-- directions is empty), in 122 ms against 8,636 ms.

create index if not exists security_statement_with_currency_idx
  on market.security_statement (security_id)
  where currency is not null;

create or replace view market.pending_statements as
select s.security_id,
       coalesce(ps.symbol, t.value) as symbol,
       coalesce(us.symbol, t.value) as us_ticker,
       case when not a.has_any then 'missing'::text else 'no_currency'::text end as want,
       coalesce(max(h.weight), 0::numeric) as best_weight
  from market.security s
  left join market.security_provider_symbol ps
         on ps.security_id = s.security_id and ps.provider_code = 'yfinance'::text
  left join market.security_identifier t
         on t.security_id = s.security_id and t.kind_code = 'ticker'::text
  left join lateral (
    select l.symbol
      from market.listing l
      join market.exchange e on e.exch_code = l.exch_code
     where l.security_id = s.security_id and e.country_iso2 = 'US'::text and l.symbol is not null
     order by l.is_primary desc, l.symbol
     limit 1) us on true
  cross join lateral (
    select exists (select 1 from market.security_statement x
                    where x.security_id = s.security_id) as has_any) a
  left join market.fund_holding_current h on h.security_id = s.security_id
 where s.security_type_code = 'equity'::text
   and coalesce(ps.symbol, t.value) is not null
   and (s.statements_missing_at is null or s.statements_missing_at < (now() - '30 days'::interval))
   and (not a.has_any
        or (t.value is not null
            and s.cik is not null
            and (s.statement_currency_missing_at is null
                 or s.statement_currency_missing_at < (now() - '30 days'::interval))
            and not exists (select 1 from market.security_statement x
                             where x.security_id = s.security_id and x.currency is not null)
            and exists (select 1 from market.listing l
                          join market.exchange e on e.exch_code = l.exch_code
                         where l.security_id = s.security_id and e.country_iso2 = 'US'::text
                           and l.symbol is not null)))
 group by s.security_id, (coalesce(ps.symbol, t.value)), (coalesce(us.symbol, t.value)), t.value, a.has_any
 order by (coalesce(max(h.weight), 0::numeric)) desc, s.security_id;
