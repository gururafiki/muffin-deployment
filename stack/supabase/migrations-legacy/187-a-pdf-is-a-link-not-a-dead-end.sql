-- A PDF IS A LINK, NOT A DEAD END.
--
-- China is the largest coverage gap in the universe — 2,311 equities with `capability = 'none'` —
-- and migration 183 recorded it NOT VIABLE for segments: CNINFO's search works and the node can
-- reach it, but every filing is a PDF (2,771 announcements for China Yangtze Power, all
-- `adjunctType: PDF`, the FY2025 annual report beginning `%PDF-1.7`).
--
-- A PDF cannot give a segment split. It can give a reader the annual report, and those 2,311
-- securities currently have NOTHING — no filings, no segments, no link. This costs no schema and no
-- UI work: `security_filing.report_url` already exists and `security-filings.tsx` already renders a
-- row as a tappable link.
--
-- IT DOES NOT MAKE CHINA "SERVED". `disclosure_source.cninfo.enabled` stays FALSE, because that
-- flag means a jurisdiction's SEGMENTS are reachable and they are not. A link is a courtesy, not
-- coverage, and conflating them would put 2,311 securities into a coverage number that no segment
-- resource can honour.

\set ON_ERROR_STOP on

-- `security_filing.source_code` is a foreign key, so the row must exist before a resource writes
-- one — migration 088's lesson, where an unseeded source killed the resource on its first real run
-- and no migration test could see it.
insert into market.data_source (code, name, priority) values
  ('cninfo', 'CNINFO (China) — CSRC disclosure platform', 230)
on conflict (code) do update set name = excluded.name;

-- NOT `carries_segments`. The form is real and the link is useful, but nothing can parse it, and a
-- form marked as carrying segments would put PDFs into a parse backlog that shares its provider
-- budget with four other resources.
insert into market.filing_form (source_code, form_code, is_annual, carries_segments) values
  ('cninfo', '年度报告', true, false)
on conflict (source_code, form_code) do update
  set is_annual = excluded.is_annual, carries_segments = excluded.carries_segments;

-- ── the backlog ─────────────────────────────────────────────────────────────────────────────────
-- AN ANTI-JOIN, NOT AN ORDERING, and a 180-day CURSOR rather than a negative cache: a Chinese
-- company files an annual report every spring, so "we have its filings" is true for a season.
-- The symbol is the six-digit mainland code from `market.listing`, which is what CNINFO's search
-- takes — never `security_identifier.ticker`, which is OpenFIGI's US lookup and for a Chinese
-- company is a thin OTC line like `CICHF`.
drop view if exists market.pending_cn_filings;
create view market.pending_cn_filings as
select s.security_id, l.symbol, coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.listing l on l.security_id = s.security_id
left join market.security_filer sf on sf.security_id = s.security_id and sf.source_code = 'cninfo'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and s.country_iso2 = 'CN'
  -- The six-digit mainland code, which is what CNINFO indexes.
  and l.symbol ~ '^[0-9]{6}$'
  and (sf.history_walked_at is null or sf.history_walked_at < now() - interval '180 days')
group by s.security_id, l.symbol
order by best_weight desc, l.symbol;

comment on view market.pending_cn_filings is
  'Chinese equities whose CNINFO annual-report links have not been fetched in 180 days. Links only — China is measured NOT viable for segments (migration 183), every filing being a PDF — so rows land with is_xbrl = false and the form is not marked carries_segments, keeping them out of every parse backlog.';

grant select on market.pending_cn_filings to service_role;

insert into market.cron_resource (position, resource) values (450, 'cn-filings')
on conflict (position) do update set resource = excluded.resource;

do $$ begin
  -- Half-hourly at :21, offset from every other segment pass. Annual reports change once a year,
  -- so this is the least urgent resource on the node and is paced accordingly.
  perform cron.schedule('muffin-cn-filings', '21-59/30 * * * *',
    $c$ select market.cron_post('cn-filings') $c$);
exception when others then
  raise notice '  --  could not schedule pg_cron job (%): it will be scheduled on the next apply', sqlerrm;
end $$;

notify pgrst, 'reload schema';
