-- THE EDGE ASKS ONLY SEC FOR STATEMENTS. YAHOO'S ARE THE COMPANY LANE'S.
--
-- WHY. `security-statements` had two halves. `missing` (a security with no statements at all) was
-- served by yfinance, asked through openbb for four annual periods with no currency. `no_sec` (a
-- CIK holder with a US listing and no SEC row) was served by SEC. Since 2026-10-18 the Dagster
-- company lane (`yahoo_companies`, umbrella docs/specs/2026-10-10-yahoo-company-data.md) fetches
-- Yahoo's annual AND quarterly statements for every equity with a live yfinance symbol, on a
-- seven-day rotation, labelled with the currency Yahoo states. That is Phase 4 step 9: the yfinance
-- half leaves the edge.
--
-- What it held, measured 2026-10-18: 26 securities, and Yahoo answers nothing for any of them.
-- 19 Philippine lines (`.PS`) and 5 Emirati (`.AE`), venues outside keyless yfinance; one Chilean
-- line under a spelling Yahoo does not use (`ANDINAB.SN`, where Yahoo writes `ANDINA-B.SN`); and one
-- US money-market fund (`BISXX`). 25 of the 26 already carried `statements_missing_at`: the half was
-- re-asking, every thirty days, a question already answered no. All 26 also carry a yfinance miss the
-- price lane recorded in the last 30 days, so the Dagster lanes do not ask them either. They belong
-- to the dead-symbol repair (umbrella docs/deferred/2026-10-05-what-the-dead-symbol-repair-cannot-
-- reach.md), not to a statements resource.
--
-- WHAT THE QUEUE IS NOW. Every equity SEC can be asked about and has not answered for: a CIK, a US
-- listing to spell the question with (SEC knows `BRK-B`, not OpenFIGI's `BRK/B`, and never a foreign
-- venue's symbol), and no `sec` row. `want` still says which half a security sits in, so a run
-- reports how many had nothing at all, but both halves are asked of SEC and both exit through the
-- same negative cache, `statement_currency_missing_at` ("SEC was asked and had nothing").
--
-- `statements_missing_at` no longer excludes anything here. It recorded "no provider had
-- statements", which was the yfinance half's answer, and its only writer leaves with this change.
-- Two securities move because of that: Verisure (`VSRPF`) and Midea (`MGCOF`) have a CIK, a US
-- line and no statements, and were excluded by marks the two-provider handler set on 10-16 and
-- 10-17. Under the old handler SEC's absence was recorded only under the yfinance half's cache.
-- Each is asked of SEC once more, then exits under SEC's own mark. The queue goes from 29 to 5.
--
-- `symbol` stays, as the priced symbol a reader of the queue recognises. Nothing asks with it any
-- more, so it may be null. Keeping the column list unchanged keeps the view's ACL.
--
-- AND THE DRAIN SIGNAL WATCHES THE RIGHT CACHE. `backlog_negative_cache` paired this backlog with
-- `statements_missing_at`, so `backlog_drain` would have compared SEC's progress against a column
-- nothing writes any more and could never report `draining_by_marking`. It now pairs with the
-- column the handler marks.
--
-- Guards: tests/sec-is-only-asked-where-it-can-answer.sql (the yfinance half is gone, the SEC half
-- keeps a security with no statements), sec-is-asked-by-its-own-spelling.sql,
-- a-statement-without-a-currency-is-not-done.sql, and logic-check.ts (no yfinance call, both halves
-- marked under SEC's cache).

create or replace view market.pending_statements as
select s.security_id,
       coalesce(ps.symbol, t.value) as symbol,
       us.symbol as us_ticker,
       case when not a.has_any then 'missing'::text else 'no_sec'::text end as want,
       coalesce(max(h.weight), 0::numeric) as best_weight
  from market.security s
  join lateral (
    select l.symbol
      from market.listing l
      join market.exchange e on e.exch_code = l.exch_code
     where l.security_id = s.security_id and e.country_iso2 = 'US'::text and l.symbol is not null
     order by l.is_primary desc, l.symbol
     limit 1) us on true
  left join market.security_provider_symbol ps
         on ps.security_id = s.security_id and ps.provider_code = 'yfinance'::text
  left join market.security_identifier t
         on t.security_id = s.security_id and t.kind_code = 'ticker'::text
  cross join lateral (
    select exists (select 1 from market.security_statement x
                    where x.security_id = s.security_id) as has_any) a
  left join market.fund_holding_current h on h.security_id = s.security_id
 where s.security_type_code = 'equity'::text
   and s.cik is not null
   and (s.statement_currency_missing_at is null
        or s.statement_currency_missing_at < (now() - '30 days'::interval))
   and not exists (select 1 from market.security_statement x
                    where x.security_id = s.security_id and x.source_code = 'sec'::text)
 group by s.security_id, (coalesce(ps.symbol, t.value)), us.symbol, a.has_any
 order by (coalesce(max(h.weight), 0::numeric)) desc, s.security_id;

comment on view market.pending_statements is
  'Equities SEC can be asked for statements and has not answered for: a CIK, a US listing and no '
  '`sec` row. `us_ticker` is the US listing''s symbol, the spelling SEC is asked with (it knows '
  'Berkshire''s B share as BRK-B, where OpenFIGI writes BRK/B). `want` is `missing` for a security '
  'with no statements at all and `no_sec` for one holding only Yahoo''s; both exit through '
  '`statement_currency_missing_at`. Yahoo''s statements are the Dagster company lane''s since '
  '2026-10-18. `symbol` is the priced symbol, for a reader; nothing asks with it.';

update market.backlog_negative_cache
   set missing_column = 'statement_currency_missing_at',
       note = 'SEC was asked and had nothing. The yfinance half and its statements_missing_at left '
              'the edge on 2026-10-18.'
 where backlog = 'pending_statements';
