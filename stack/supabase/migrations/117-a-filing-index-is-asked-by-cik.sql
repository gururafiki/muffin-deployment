-- THE DOCUMENTS THEMSELVES: 10-K, 10-Q, 8-K, 20-F, 6-K and the proxy.
--
-- `security_statement` holds the NUMBERS a filing reported. This holds the filing — its date, its
-- type and a URL — which is what makes a research answer citable rather than asserted. The agent
-- does deep research; having filings indexed against `security_id` is the difference between
-- grounding a claim and searching for it.
--
-- ── THIS ENDPOINT TAKES A CIK, AND THAT MATTERS ─────────────────────────────────────────────────
--
-- Measured 2026-08-22: `equity/fundamental/filings` accepts `cik` directly, unlike
-- `equity/ownership/insider_trading`, which requires `symbol` and rejects a CIK outright. So this
-- resource needs no symbol resolution at all — no `symbol_security` lookup, no US-ticker-versus-
-- display-symbol question, and none of the `CIK not found for symbol BG.VI` failures that cost the
-- insider resource 12 of 26 securities on its first run. The CIK is already the backlog's filter.
--
-- ── AND `form_type` FILTERS WHILE `form_group` DOES NOT ─────────────────────────────────────────
--
-- Unfiltered, the feed is dominated by Form 4s and 144s — the insider noise `security-insider`
-- already indexes properly. `form_type=10-K,10-Q` returns exactly those two (measured, comma
-- separated). `form_group=annual` was tried first and is a NO-OP: it returned Form 4s regardless,
-- which reads as a working filter returning honest results. Do not use it.
--
-- Foreign private issuers file 20-F and 6-K rather than 10-K and 10-Q — BABA returns twelve 6-Ks
-- and no 10-Q — so both vocabularies are asked for in the same call.

insert into market.data_source (code, name, priority) values ('sec-filings', 'SEC filing index', 245)
on conflict (code) do nothing;

create table if not exists market.security_filing (
  -- SEC's accession number IS the filing's identity, globally unique and stable. Unlike Form 4
  -- transactions, this response gives us a real key and there is nothing to hash.
  accession_number text not null,
  security_id      uuid not null references market.security (security_id) on delete cascade,
  filing_date      date,
  report_date      date,
  report_type      text,
  report_url       text,
  filing_detail_url text,
  source_code      text not null references market.data_source (code),
  as_of            timestamptz not null default now(),
  -- Keyed WITH the security: one accession can be filed on behalf of several registrants, and a
  -- bare accession primary key would let the second one silently replace the first.
  primary key (security_id, accession_number)
);

comment on table market.security_filing is
  'The SEC filings themselves — 10-K/10-Q/8-K and the 20-F/6-K a foreign private issuer files instead — with their dates and URLs. `security_statement` holds the numbers a filing reported; this holds the document, which is what makes a research answer citable.';

create index if not exists security_filing_recent_idx
  on market.security_filing (security_id, filing_date desc);

grant select on market.security_filing to anon, authenticated, service_role;
grant insert, update, delete on market.security_filing to service_role;

alter table market.security_filing enable row level security;
drop policy if exists security_filing_read on market.security_filing;
create policy security_filing_read on market.security_filing for select using (true);

-- A CURSOR, like the insider resource and for the same reason: companies keep filing. Deliberately
-- not a `%_missing_at` column — "no 10-K this month" is never a permanent fact.
alter table market.security add column if not exists filings_fetched_at timestamptz;

comment on column market.security.filings_fetched_at is
  'When the SEC filing index was last read for this security. A CURSOR, not a negative cache — companies keep filing, so an absence is never permanent.';

drop view if exists market.pending_filings;
create view market.pending_filings as
select
  s.security_id,
  s.cik,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and s.cik is not null
  and (s.filings_fetched_at is null or s.filings_fetched_at < now() - interval '7 days')
group by s.security_id, s.cik
order by best_weight desc;

comment on view market.pending_filings is
  'SEC filers whose filing index has not been read in the last week, ordered by fund weight. A rolling cursor: it is not meant to empty.';

grant select on market.pending_filings to service_role;

-- ── THE SERVING VIEW ────────────────────────────────────────────────────────────────────────────
--
-- Most recent first, and PERIODIC REPORTS SEPARATED FROM EVENTS. A 10-K and an 8-K answer different
-- questions — "what did the year look like" against "what just happened" — and a single list
-- ordered by date buries the annual report under a month of press releases.
drop view if exists market.security_recent_filings;
create view market.security_recent_filings as
select
  f.security_id,
  f.accession_number,
  f.filing_date,
  f.report_date,
  f.report_type,
  f.report_url,
  f.filing_detail_url,
  -- 10-K/20-F are annual, 10-Q/6-K interim, everything else an event. Stated here rather than in
  -- each caller, so two screens cannot disagree about what counts as a periodic report.
  case
    when f.report_type in ('10-K', '10-K/A', '20-F', '20-F/A') then 'annual'
    when f.report_type in ('10-Q', '10-Q/A', '6-K', '6-K/A')   then 'interim'
    else 'event'
  end as kind
from market.security_filing f;

comment on view market.security_recent_filings is
  'Filings with a `kind` — annual, interim or event. A 10-K and an 8-K answer different questions, and a single date-ordered list buries the annual report under a month of press releases.';

grant select on market.security_recent_filings to anon, authenticated, service_role;

notify pgrst, 'reload schema';
