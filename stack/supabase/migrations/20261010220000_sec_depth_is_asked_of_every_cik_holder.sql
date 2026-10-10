-- SEC'S DEPTH IS ASKED OF EVERY CIK HOLDER WITHOUT IT, NOT OF EVERY ONE WITHOUT A CURRENCY.
--
-- WHY. `pending_statements` had two halves: `missing` (no statement at all) and `no_currency`, a CIK
-- holder with a US listing whose statements carry no currency. The second was a proxy for "SEC has
-- not answered for it yet", true only while every Yahoo statement row had a null currency (154,629 of
-- 154,629 on 2026-10-10) and every SEC row had one (0 SEC filers without). Phase 4's company lane
-- writes Yahoo statements WITH the currency Yahoo states (umbrella
-- docs/specs/2026-10-10-yahoo-company-data.md), so the proxy would turn false for exactly the
-- securities it exists for: a CIK holder the lane reaches first would leave the backlog holding four
-- Yahoo years, and SEC's eighteen would never be asked for before Phase 5. The half now asks the
-- question itself, whether any SEC row exists, and is called `no_sec`. Today the two populations are
-- the same (863 CIK holders with a US listing hold SEC rows, 33 do not, 30 of them marked).
--
-- The negative cache keeps its name, `statement_currency_missing_at`: it has always meant "SEC was
-- asked and had nothing", which is still what it records. Probed with a partial index over the SEC
-- rows, the same shape as the currency probe it replaces, which `security_statement_current` still
-- uses.
--
-- AND A SEMI-ANNUAL REPORTER IS NOT MISSING ITS QUARTERS. The company lane writes a half-year as
-- `period_type = 'half'`, where the edge wrote it as a quarter (3,094 such rows in 2,192 securities,
-- 170-195 days apart). `pending_quarters` asked for "no quarter row", so a company whose halves the
-- lane re-files would be re-queued to the edge, which would write them back as quarters. It now asks
-- for no quarter AND no half. The edge's mislabelled rows are retracted when the lane files the same
-- period as a half; a one-shot cleans what remains after the edge's quarters resource retires.

create index if not exists security_statement_sec_idx
  on market.security_statement (security_id)
  where source_code = 'sec';

create or replace view market.pending_statements as
select s.security_id,
       coalesce(ps.symbol, t.value) as symbol,
       coalesce(us.symbol, t.value) as us_ticker,
       case when not a.has_any then 'missing'::text else 'no_sec'::text end as want,
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
                             where x.security_id = s.security_id and x.source_code = 'sec'::text)
            and exists (select 1 from market.listing l
                          join market.exchange e on e.exch_code = l.exch_code
                         where l.security_id = s.security_id and e.country_iso2 = 'US'::text
                           and l.symbol is not null)))
 group by s.security_id, (coalesce(ps.symbol, t.value)), (coalesce(us.symbol, t.value)), t.value,
          a.has_any
 order by (coalesce(max(h.weight), 0::numeric)) desc, s.security_id;

create or replace view market.pending_quarters as
select s.security_id,
       coalesce(ps.symbol, t.value) as symbol,
       coalesce(max(h.weight), 0::numeric) as best_weight
  from market.security s
  left join market.security_provider_symbol ps
         on ps.security_id = s.security_id and ps.provider_code = 'yfinance'::text
  left join market.security_identifier t
         on t.security_id = s.security_id and t.kind_code = 'ticker'::text
  left join market.fund_holding_current h on h.security_id = s.security_id
 where s.security_type_code = 'equity'::text
   and s.cik is null
   and coalesce(ps.symbol, t.value) is not null
   and (s.quarters_missing_at is null or s.quarters_missing_at < (now() - '30 days'::interval))
   and exists (select 1 from market.security_statement a
                where a.security_id = s.security_id and a.period_type = 'annual'::text)
   and not exists (select 1 from market.security_statement q
                    where q.security_id = s.security_id
                      and q.period_type = any (array['quarter'::text, 'half'::text]))
 group by s.security_id, (coalesce(ps.symbol, t.value))
 order by (coalesce(max(h.weight), 0::numeric)) desc;

comment on column market.security_statement.period_type is
  'annual, quarter or half. A half-year is told from a quarter by the gap to the previous period end '
  '(170-195 days), never by the provider''s label: Yahoo labels a half 3M. Part of the primary key, '
  'because a fiscal-year end is both an annual period and the last quarter or half.';
