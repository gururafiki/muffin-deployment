-- INDIA IS SERVED — the resources exist, so the source may now say so.
--
-- Migration 185 landed the normaliser, the axes, the concepts and `pending_in_segments`, and
-- deliberately left `disclosure_source.enabled` false: a source with no resource advertises work
-- nothing can do. `in-filings` and `security-in-segments` now exist, so this flips it, adds the
-- history backlog discovery reads, and schedules both.

\set ON_ERROR_STOP on

-- ── the discovery backlog ───────────────────────────────────────────────────────────────────────
-- AN ANTI-JOIN, NOT AN ORDERING. Written as `select … from security limit 6` this would hand back
-- the same six companies for ever — the defect `derive_security_metrics` shipped with (two
-- production calls returning byte-identical `written: 7386, remaining: 104925`) and the one
-- `pending_industry` ran with for months.
--
-- THE SYMBOL IS `market.listing.symbol`, never `security_identifier.ticker`. That ticker is
-- OpenFIGI's US lookup, which for a foreign company is a thin OTC foreign-ordinary line — 365 of
-- 900 sampled non-US securities were displayed as one. NSE wants the Indian symbol (RELIANCE,
-- HDFCBANK), and the listing is where it lives.
--
-- A CURSOR, NOT A NEGATIVE CACHE, and deliberately not named `%_missing_at`: Indian companies keep
-- filing, so "we have walked this company" is true for a season and never permanently. Ninety days
-- is comfortably inside the annual cycle.
drop view if exists market.pending_in_history;
create view market.pending_in_history as
select s.security_id, l.symbol, coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.listing l on l.security_id = s.security_id
join market.exchange e on e.exch_code = l.exch_code
left join market.security_filer sf on sf.security_id = s.security_id and sf.source_code = 'nse'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and s.country_iso2 = 'IN'
  and e.country_iso2 = 'IN'
  and l.symbol is not null
  and (sf.history_walked_at is null
       or sf.history_walked_at < now() - interval '90 days')
group by s.security_id, l.symbol
-- Weight first: 645 equities against a shared provider budget, so the ones a fund actually holds
-- are worth discovering first.
order by best_weight desc, l.symbol;

comment on view market.pending_in_history is
  'Indian equities whose NSE filing history has not been walked in 90 days. Keyed on market.listing.symbol because that is the Indian symbol NSE wants — security_identifier.ticker is OpenFIGI''s US lookup and for a foreign company is usually a thin OTC line. A cursor rather than a negative cache: Indian companies keep filing, so a walk is true for a season, never permanently.';

grant select on market.pending_in_history to service_role;

-- ── the source may now advertise itself ─────────────────────────────────────────────────────────
update market.disclosure_source set enabled = true where code = 'nse';

-- ── scheduled, because a resource nothing calls cannot fail ─────────────────────────────────────
-- `exchange-listings` was deployed, reachable and absent from the cron, so 16 venues were never
-- swept and no count could show it.
insert into market.cron_resource (position, resource) values
  (430, 'in-filings'),
  (440, 'security-in-segments')
on conflict (position) do update set resource = excluded.resource;

do $$ begin
  -- :07, :12 … offset from the rotation's `*/5`, from segments' `2-59/5` and from Korea's
  -- `4-59/5`, so four passes never fire in the same minute on one Always-Free node.
  --
  -- FIVE MINUTES WITH A FOUR-MINUTE TTL. The TTL must be SHORTER than the interval or the resource
  -- self-skips half its firings — `security-segments` shipped with a 10-minute TTL on a 5-minute
  -- cron and did exactly that.
  perform cron.schedule('muffin-in-segments', '7-59/5 * * * *',
    $c$ select market.cron_post('security-in-segments') $c$);
  -- Discovery is one call per company against a session-cookied API, so it is paced more slowly
  -- than the parse. 645 equities at six a run converges in about a day.
  perform cron.schedule('muffin-in-filings', '13-59/15 * * * *',
    $c$ select market.cron_post('in-filings') $c$);
exception when others then
  raise notice '  --  could not schedule pg_cron job (%): it will be scheduled on the next apply', sqlerrm;
end $$;

notify pgrst, 'reload schema';
