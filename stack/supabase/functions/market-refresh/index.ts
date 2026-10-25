// market-refresh — refreshes market.performance from the OpenBB REST API.
//
// WHY THIS EXISTS
//   Reads never come through here. The app reads market.performance directly over
//   PostgREST (supabase.schema('market')), which is why reads are fast and work
//   pre-auth. This function is only the WRITER: it is triggered when a row's
//   `stale_after` has passed, fetches upstream, and upserts. Stale-while-revalidate
//   — a reader is never blocked on OpenBB.
//
// ABUSE GUARD (load-bearing)
//   The anon key is published in runtime-config.js, so anyone can invoke this.
//   market.begin_refresh() is an atomic claim: it returns false if a refresh is in
//   flight, if one succeeded within the TTL, or if the last attempt failed and is
//   still cooling off. N concurrent triggers collapse into at most ONE upstream
//   fetch. Never bypass it.
//
// RUNTIME LIMITS (set by the main router, functions/main/index.ts)
//   memoryLimitMb = 150, workerTimeoutMs = 60_000, importMapPath = null.
//   No import map means every remote import must be a fully-qualified URL.
//
// The fetch/mapping logic lives in ./resources.ts so it can be exercised with no Supabase
// running — see ./logic-check.ts and ./isolation-check.ts.

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0'
import { fetchAlphaVantageEarnings } from './alpha-vantage.ts'
import { factsFromCompanyFacts, fetchCompanyFacts, fetchSubmissions, fetchSubmissionsPage, submissionsFrom, type ConceptSpec } from './xbrl.ts'
import * as dart from './dart.ts'
import * as nse from './in.ts'
import * as cninfo from './cn.ts'
import * as cnPdf from './cn-pdf.ts'
import { TOO_LARGE, fetchInstance, findInstanceUrl, instanceIsTooLarge, segmentFactsFrom, type SegmentAxisSpec, type SegmentConceptSpec } from './segments.ts'
import { fetchIndustries, slug } from './wikidata.ts'
import { corporateActions, TiingoNoSuchTicker } from './tiingo.ts'
import {
  BACKLOG_TTL_MINUTES,
  SEC_BACKLOG_TTL_MINUTES,
  dedupeBy,
  fetchWithIsolation,
  extractMacroPoints,
  openbbFetcher,
  NEWS_RETENTION_DAYS,
  DAILY_TTL_MINUTES,
  noDataForSymbol,
  symbolList,
  throttled,
  sha256Hex,
} from './resources.ts'

const OPENBB_URL = Deno.env.get('OPENBB_API_URL') ?? 'http://openbb-api:6900'
// Dagster's GraphQL, on the stack's overlay network. Not through http-cache, because it is not a
// provider: the refresh button launches a run there (`launchCompanyRun`).
const DAGSTER_GRAPHQL_URL = Deno.env.get('DAGSTER_GRAPHQL_URL') ?? 'http://dagster-webserver:3000/graphql'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const JSON_HEADERS = { 'Content-Type': 'application/json' }

/** See the note on `scopeLimit` — 300 is measured, not chosen. */
/**
 * Rows of a backlog to claim per run.
 *
 * 600, raised from 300 on 2026-08-12 after measuring: `security-industries` used 22s of its 55s
 * budget at 300 and `security-fundamentals` 27s, so both were bounded by this number rather than by
 * time. The deadline is the intended bound — it is what makes a run safe — and a page that finishes
 * in half the budget only slows the drain. Claiming more than a run can finish is harmless: the
 * remainder stays in the backlog and costs one larger read.
 */
const PROFILE_BACKLOG_PAGE = 600

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: JSON_HEADERS })

/**
 * True when the caller presented the SERVICE-ROLE key.
 *
 * The main router has already verified the JWT's signature, so this only has to
 * read the claim — but it must still be checked, because `force` is the one input
 * that lets a caller bypass the rate limit protecting the upstream provider.
 */
function claims(req: Request): Record<string, unknown> | null {
  const token = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return null
  try {
    const [, payload] = token.split('.')
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')))
  } catch {
    return null
  }
}

function isServiceRole(req: Request): boolean {
  return claims(req)?.role === 'service_role'
}

/**
 * True for an ADMIN user, the Supabase-native way: `app_metadata.role === 'admin'`.
 *
 * `app_metadata` is the right home rather than `user_metadata` — a user can edit their own
 * `user_metadata` through the normal auth API, so a role kept there is self-assignable and worth
 * nothing. `app_metadata` can only be written with the service key (or in Studio), and GoTrue
 * copies it into every token it issues, so it survives a refresh with no extra lookup.
 *
 * The main router has already verified the JWT's SIGNATURE, so reading the claim here is safe —
 * an attacker cannot mint one. Grant it with:
 *   `update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}' where email = '…';`
 */
function isAdmin(req: Request): boolean {
  const c = claims(req)
  if (!c) return false
  if (c.role === 'service_role') return true
  const app = c.app_metadata as Record<string, unknown> | undefined
  return app?.role === 'admin' || (Array.isArray(app?.roles) && app.roles.includes('admin'))
}

/**
 * How much of a resource's budget to leave unspent so a batch already in flight can FINISH.
 *
 * A loop written `while (Date.now() < deadline)` decides whether to START work, not whether it can
 * complete — and a batch that starts one millisecond under the deadline still has to fetch, write,
 * mark and prune, none of which the deadline bounds. `security-performance` demonstrated the cost:
 * measured 2026-08-17 it ran **89 seconds against a 90-second worker**, and was killed outright
 * once with `WorkerRequestCancelled`.
 *
 * A killed worker is strictly worse than a shorter run — it loses the batch in flight AND never
 * calls `finish_refresh`, so the resource is additionally locked out for the 2-minute in-flight
 * TTL. Because the binding constraint here is requests per unit TIME rather than per run, giving
 * up one batch costs nothing real.
 *
 * Found in four resources, not one: `security-performance`, `-fundamentals`, `-industries` and
 * `-profiles` all gated on the bare deadline. The others already reserved 4-6s.
 */
const TAIL_RESERVE_MS = 10_000

/** The schema-scoped client. */
type MarketClient = ReturnType<SupabaseClient['schema']>

/**
 * RESOURCES A FAMILY CUTOVER RETIRED, refused before anything else is decided: the price and
 * performance family on 2026-09-12 (D2), the universe family on 2026-09-26 (Phase 3), the Yahoo
 * company family on 2026-10-18 (Phase 4), Tiingo's corporate actions and SEC's openbb statements
 * on 2026-10-25.
 *
 * Their handlers are still in this file and their `cron_resource` rows are disabled, which stops
 * the SCHEDULE and nothing else. A direct call still reached them: an admin pressing Refresh in the
 * app would have spent a provider request on a family Dagster now owns, and `fx-rates` would have
 * written spot rates into `market.fx_rate` beside the lane that owns that table — two writers for
 * one key. Measured 2026-09-25: the app still asked for `instrument-performance` on every Markets
 * load, and was stopped only because the visitor was not an admin.
 *
 * 410, not 200 with `ok: false`: nothing failed, the request names something that no longer
 * exists here. The value says where the data comes from now, so the answer is actionable.
 *
 * Kept equal to the migrations' `-- RETIRES:` markers by `logic-check.ts`, in both directions.
 */
const RETIRED: Record<string, string> = {
  'security-prices': 'Dagster price lane (price_bar) — read market.price_series',
  'security-daily-history': 'Dagster price history lane (price_bar_history) — read market.price_series',
  'security-price-history': 'Dagster price history lane (price_bar_history) — read market.price_series',
  'instrument-prices': 'Dagster price lane (price_bar) — read market.price_series',
  'security-performance': 'Dagster security_return — read market.performance',
  'instrument-performance': 'Dagster security_return — read market.performance',
  'sector-performance': 'Dagster daily_indices (index_return) — read market.performance',
  'country-performance': 'Dagster daily_indices (index_return) — read market.performance',
  'group-performance': 'Dagster daily_indices (index_return) — read market.performance',
  'fx-rates': 'Dagster daily_fx — read market.fx_rate',
  'fund-holdings': 'Dagster N-PORT discovery (fund_holding, discovered_security) — read market.fund_holdings',
  'exchange-listings': 'Dagster venue sweep (venue_listing) — read market.untracked_listing',
  'security-tickers': 'Dagster symbology ladder (raw_figi_ticker → security_symbology)',
  'security-local-symbols': 'Dagster symbology ladder (raw_figi_local_symbol → security_symbology)',
  'security-yahoo-symbols': 'Dagster symbology ladder (raw_yahoo_symbol → security_symbology)',
  'security-symbol-repair': 'Dagster symbology ladder (security_symbology)',
  'promote-wave': 'the market.promote_listing RPC; waves move to Dagster (Phase 3 stage 4)',
  'promote-listing': 'the market.promote_listing RPC — the Track button calls it directly',
  'sec-cik-map': 'Dagster registries (raw_sec_cik_map → security_cik) — read market.security.cik',
  'in-symbols': 'Dagster registries (raw_nse_equity_list → security_nse_filer)',
  'derive-classifications': 'Dagster security_classification — read market.security_taxonomy',
  'security-profiles': 'Dagster company lane (yahoo_companies) — read market.security_taxonomy',
  'security-profile-detail': 'Dagster company lane (yahoo_companies) — read market.security_profile',
  'security-industries': 'Dagster company lane (yahoo_companies) — read market.security_taxonomy',
  'security-fundamentals': 'Dagster company lane (yahoo_companies) — read market.security_fundamentals',
  'security-share-stats': 'Dagster company lane (yahoo_companies) — read market.security_share_stats',
  'security-management': 'Dagster company lane (yahoo_companies) — read market.security_officer',
  'security-quarters': 'Dagster company lane (yahoo_companies) — read market.security_statement',
  'security-dividends': 'Dagster price lane (yahoo_corporate_action) — read market.security_corporate_action',
  'instrument-profile': 'Dagster company lane (yahoo_companies) — read market.instrument_current',
  'security-metrics': 'Dagster derived_security_metrics — read market.security_metric',
  'security-corporate-actions': 'Dagster price lane (yahoo_corporate_action) — read market.security_corporate_action',
  'security-statements': 'SEC statements move to the Dagster SEC lane (Phase 5) — read market.security_statement',
}

/**
 * LAUNCH THE COMPANY LANE FOR ONE SECURITY: the job's own run, one partition, as its schedule would.
 *
 * `force: true` is `CompanyRun.force` (muffin-ingest `defs/companies/raw.py`): ask for the summary and
 * the statements whatever raw already holds. The run's assets claim the `yfinance` and `sql` pools, so
 * it queues behind them like any other and a press during the price night waits its turn. Measured
 * 2026-10-18: `dagster-webserver:3000` answers on `muffin-net` with no credential, which is why this
 * stays inside the stack and never goes through Cloudflare Access.
 */
async function launchCompanyRun(
  securityId: string,
  symbol: string,
): Promise<{ ok: true; runId: string } | { ok: false; error: string }> {
  const mutation = `mutation($p: ExecutionParams!) { launchRun(executionParams: $p) {
    __typename ... on LaunchRunSuccess { run { runId } }
    ... on RunConfigValidationInvalid { errors { message } } ... on Error { message } } }`
  const params = {
    selector: {
      repositoryLocationName: 'muffin_ingest',
      repositoryName: '__repository__',
      jobName: 'yahoo_companies',
    },
    mode: 'default',
    runConfigData: { ops: { raw_yahoo_company: { config: { force: true } } } },
    executionMetadata: {
      tags: [
        { key: 'dagster/partition', value: securityId },
        { key: 'muffin/reason', value: `refresh button: ${symbol}` },
        // THE JOB'S `run_tags` DO NOT REACH A RUN LAUNCHED HERE: only the scheduler merges them.
        // Measured 2026-10-18, a launched run carried the pools but no `dagster/max_runtime`, so a
        // hung one would have had six hours. One company takes ~30 s once it starts.
        { key: 'dagster/max_runtime', value: '600' },
      ],
    },
  }
  let res: Response
  try {
    res = await fetch(DAGSTER_GRAPHQL_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: mutation, variables: { p: params } }),
      signal: AbortSignal.timeout(15_000),
    })
  } catch (e) {
    return { ok: false, error: `dagster unreachable: ${e instanceof Error ? e.message : String(e)}`.slice(0, 300) }
  }
  const body = await res.json().catch(() => null) as
    | { data?: { launchRun?: Record<string, unknown> }; errors?: { message: string }[] }
    | null
  const launch = body?.data?.launchRun
  if (launch?.__typename === 'LaunchRunSuccess') {
    return { ok: true, runId: String((launch.run as { runId: string }).runId) }
  }
  const errors = launch?.errors as { message: string }[] | undefined
  const why = (launch?.message as string | undefined) ??
    errors?.map((e) => e.message).join('; ') ??
    body?.errors?.[0]?.message ??
    `HTTP ${res.status}`
  return { ok: false, error: `${String(launch?.__typename ?? 'no answer')}: ${why}`.slice(0, 300) }
}

async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok')

  let resource = ''
  let symbolScope: string | undefined
  let force = false
  // Caps how much a backlog resource attempts in one run. Added as a BISECT tool: when
  // `security-industries` died in 3.8s with a bare 502, nothing distinguished "too much work"
  // from "broken regardless of size", and there was no way to ask. It stays because it is also
  // how you drain a backlog gently after an outage.
  let scopeLimit: number | undefined

  /**
   * Default rows per run for the PROFILE-shaped backlogs.
   *
   * 300, measured rather than chosen: at 1,000 the run is flaky (one success, two bare 502s), at
   * 300 and below it is reliable — which is what the `limit` knob was added to find out. The
   * profile endpoint is one upstream fetch PER SYMBOL inside yfinance, so a thousand of them is
   * simply more than one worker should be asked to shepherd, especially while the provider is
   * rate-limiting (40 of ~50 batches failed on the run that did complete).
   *
   * Four warm-ups a day still moves 1,200, and `{"limit": N}` overrides it either way.
   */
  try {
    const body = await req.json()
    if (body?.resource) resource = String(body.resource)
    if (body?.symbol) symbolScope = String(body.symbol).trim()
    if (Number.isFinite(body?.limit)) scopeLimit = Math.max(1, Math.min(1000, Number(body.limit)))
    // `force` bypasses the TTL, NOT the in-flight lock — two concurrent forced
    // refreshes must still collapse into one upstream fetch. Requires the
    // service-role key: the anon key is public, and a public cache-buster is a
    // free way to hammer the provider.
    force = body?.force === true && isServiceRole(req)
  } catch {
    // No body / not JSON — `resource` stays empty and is refused below.
  }

  const DERIVE_RESOURCE = 'derive-classifications'
  const FACETS_RESOURCE = 'facets-refresh'
  const OBSERVABILITY_RESOURCE = 'observability-sample'
  const MACRO_RESOURCE = 'macro-indicators'
  const ONE_SECURITY_RESOURCE = 'security-refresh'
  /**
 * How many securities the backlog still holds — the TRUE total, via `content-range`.
 *
 * Never a page: `PGRST_DB_MAX_ROWS` is 1,000, so `select(...).limit(5000)` returns exactly 1,000
 * and a guard sized on it reports "1000" for ever however bad things get. `head: true` fetches no
 * rows at all, which is also why it is cheap enough to run on every response.
 *
 * Returns null rather than 0 when the count is unavailable: a failed count and an empty backlog
 * are different facts, and reporting the second for the first is how a resource announces itself
 * drained while it is broken.
 */
async function backlogSize(market: MarketClient, view: string): Promise<number | null> {
  const { count, error } = await market.from(view).select('security_id', { count: 'exact', head: true })
  return error ? null : (count ?? null)
}

const NEWS_RESOURCE = 'security-news'
const XBRL_RESOURCE = 'security-xbrl'
const SEGMENTS_RESOURCE = 'security-segments'
const KR_FILINGS_RESOURCE = 'kr-filings'
const KR_SEGMENTS_RESOURCE = 'security-kr-segments'
/** DART's own name for the Korean annual report, and the `filing_form` row seeded by migration 172. */
const KR_ANNUAL_FORM = '사업보고서'
const CN_SEGMENTS_RESOURCE = 'security-cn-segments'
const IN_FILINGS_RESOURCE = 'in-filings'
const IN_SEGMENTS_RESOURCE = 'security-in-segments'
/** NSE labels every annual results filing `Annual`; it is the `filing_form` code seeded for `nse`. */
const IN_ANNUAL_FORM = 'Annual'
const CN_FILINGS_RESOURCE = 'cn-filings'
/** CNINFO's annual-report category, and the `filing_form` code seeded for `cninfo`. */
const CN_ANNUAL_FORM = '年度报告'
// THE SAME CATEGORY CARRIES THREE DOCUMENTS, AND ONLY ONE IS PARSEABLE. Nothing is discarded — a
// summary is a real document and a useful link — but the type has to distinguish them, because
// `security_filing` has no title column and `report_type` is the classification's only carrier.
const CN_SUMMARY_FORM = '年度报告摘要'
const CN_ENGLISH_FORM = '年度报告（英文版）'
const CN_FORM_FOR: Record<string, string> = {
  full: CN_ANNUAL_FORM,
  summary: CN_SUMMARY_FORM,
  english: CN_ENGLISH_FORM,
}
const FILING_HISTORY_RESOURCE = 'security-filing-history'
const WIKIDATA_RESOURCE = 'security-wikidata-industries'
/**
 * ISINs per SPARQL request. The endpoint is public, free and SHARED — a politeness limit rather
 * than a quota, with a 60-second query timeout — so batching is the whole game: measured, 12 ISINs
 * cost ONE request and 0.78 s, where 12 requests would be a dozen seconds of someone else's
 * capacity. Fifty is well inside the timeout and keeps the URL-free POST body small.
 */
const WIKIDATA_BATCH = 50
/** Batches per run. Three requests a run against a shared public endpoint is unremarkable. */
const WIKIDATA_BATCHES = 3
/**
 * Filers per run. Each is ONE request for a 1-5 MB submissions document plus its older pages, so
 * like every SEC resource here the bound is memory rather than the 90-second budget. Eight is
 * deliberately small: this runs once per filer per month and has no reason to be greedy.
 */
const FILING_HISTORY_PAGE = 8
/**
 * How many historical pages to walk per filer. Apple has ONE (1,242 filings, 1994-2015) and most
 * filers have none — the cap exists so a filer with an unusual history cannot consume a whole run.
 * What is skipped is re-offered next month rather than lost.
 */
const FILING_HISTORY_MAX_PAGES = 3
/** The forms that carry audited accounts. A 6-K or 8-K is an event and has no segment note. */
const ACCOUNTS_FORMS = ['10-K', '10-Q', '20-F', '40-F']
/**
 * Filings per run. TWO REQUESTS EACH — the directory listing, then the instance.
 *
 * MEASURED 2026-08-29 rather than estimated, because the first estimate was wrong by 5x. Instance
 * sizes run 0.74 MB (AAPL 10-Q) to **10.92 MB** (Diageo's 20-F; foreign private issuers tag their
 * whole annual report inline, so the 20-F is the big one). The costs that were feared are not the
 * binding ones: the 10.92 MB document downloads in **0.37 s**, parses in **40 ms**, and peaks at
 * **15 MB** of heap. Documents are processed strictly one at a time and released, so a page of 20
 * is ~16 s of a 60 s budget and nowhere near the 256 MB worker.
 *
 * The real constraint is politeness: at 20 filings this is ~0.7 requests/second against SEC's
 * documented allowance of 10.
 */
const SEGMENTS_PAGE = 20
/**
 * WHICH METRICS ARE WORTH KEEPING PER SEGMENT. Revenue makes a business line visible, operating
 * income makes it comparable, and capital expenditure shows where the company is actually spending
 * — together they answer "AWS is 18% of revenue, 59% of profit, and the majority of the capex",
 * which is the question a company-level sector label cannot.
 *
 * ALL THREE COST NOTHING EXTRA: the facts are in the instance this resource already downloads and
 * parses. Measured on Amazon's 10-Q, that document also carries segment `Assets`, `Depreciation`
 * and `CostsAndExpenses` — deliberately not taken yet. `Assets` is an INSTANT fact and
 * `security_segment.period_type` admits only durations; the other two are durations that would
 * work today, but every metric added to `xbrl_concept` is also read by `security-xbrl` for the
 * whole universe, and `security_metric` already holds 3.29M rows. See migration 146.
 */
const SEGMENT_METRICS = [
  'revenue', 'operating_income', 'capital_expenditure',
  // Added by migration 148. `total_assets` is an INSTANT and needed the parser to accept
  // stocks as well as flows; the other two are ordinary durations.
  'total_assets', 'depreciation', 'cost_of_revenue',
  // Added by migration 196, both INSTANTS like `total_assets`. Long-lived assets by geography is
  // REQUIRED by ASC 280 beside geographic revenue and was in every instance we already download —
  // Amazon reports US $180bn / non-US $61.3bn on `StatementGeographicalAxis`. Goodwill is per
  // segment because that is where impairment is tested. 722 and 3,347 filers respectively.
  'long_lived_assets', 'goodwill',
]
const EARNINGS_HISTORY_RESOURCE = 'earnings-history'
const STATEMENTS_RESOURCE = 'security-statements'
// A filer SEC certainly serves, asked when no security in a run got rows, so an empty answer can
// be told from an endpoint that is not answering. `fetchWithIsolation` uses the same control.
const SEC_CONTROL_FILER = 'AAPL'
const EARNINGS_RESOURCE = 'earnings-calendar'
const INSIDER_RESOURCE = 'security-insider'
const FILINGS_RESOURCE = 'security-filings'
const EPS_HISTORY_RESOURCE = 'security-eps-history'
const PRICE_TARGETS_RESOURCE = 'security-price-targets'
  const ACTIONS_RESOURCE = 'security-corporate-actions'
  // EVERY RESOURCE DECLARES ITS TTL HERE, AND THERE IS NO DEFAULT.
  //
  // This was a ternary chain ending in `: PROFILE_TTL_MINUTES`, with the set of known resources
  // kept in a SEPARATE array beside it. The two drifted, and the fallback made the drift silent:
  // a resource missing from the chain did not fail, it inherited SEVEN DAYS.
  //
  // Measured 2026-08-17, three resources had fallen through — and every one of them is an
  // INCREMENTAL backlog, i.e. exactly the kind the comment below warns must never get a
  // completion-shaped TTL:
  //
  //   security-prices           last ran 08-14 18:09, next allowed 08-21 — `pending_prices`
  //                             meanwhile grew 2,940 -> 11,348 (92% of all equities) and the
  //                             newest stored bar stayed frozen at Friday 08-14
  //   security-yahoo-symbols    last ran 08-14 18:06
  //   security-corporate-actions last ran 08-15 12:35
  //
  // The cron called all three on schedule, eight times a day, and each answered
  // `{"skipped":true,"reason":"fresh or in flight"}` — which the warm-up correctly counts as a
  // SUCCESS, because a warm-up finding fresh data is the happy path. So the workflow was green,
  // `refresh_log.ok` was true, no error was ever raised, and price ingestion was simply stopped.
  //
  // A DEFAULT TTL IS A SILENT WRONG ANSWER. Keyed off the map so the two cannot drift again:
  // `EXTRA` is now derived from it rather than maintained beside it, so adding a resource without
  // a TTL is not "the default applies", it is `unknown resource` — a loud 400 on the first call.
  const EXTRA_TTL_MINUTES: Record<string, number> = {
    // ONE MINUTE: the claim is per resource, not per symbol, so the backlog TTL meant a press for
    // one stock refused the next stock for ten minutes. Launching a run is cheap; the run queues.
    [ONE_SECURITY_RESOURCE]: 1,
    // Incremental backlogs: each run drains a SLICE, so the TTL only has to permit the NEXT run.
    // A completion-shaped TTL here does not slow the resource down, it stalls the backlog for the
    // length of the TTL.
    [NEWS_RESOURCE]: BACKLOG_TTL_MINUTES,
    [PRICE_TARGETS_RESOURCE]: BACKLOG_TTL_MINUTES,
    [XBRL_RESOURCE]: BACKLOG_TTL_MINUTES,
    // NOT `BACKLOG_TTL_MINUTES`: these two have their own five-minute pg_cron jobs, and a
    // ten-minute TTL made every other firing a no-op — measured in production, half the runs came
    // back `skipped: fresh or in flight` while reporting ok.
    [SEGMENTS_RESOURCE]: SEC_BACKLOG_TTL_MINUTES,
    // FOUR MINUTES ON A FIVE-MINUTE CRON. A TTL at or above the interval makes the resource
    // self-skip half its firings — which `security-segments` shipped with and
    // `derive-classifications` still does, 29 days in 30.
    [KR_SEGMENTS_RESOURCE]: 4,
    [KR_FILINGS_RESOURCE]: 14,
    // India's instances are 77-109 KB and need no warm-up, so the parse resource can run often;
    // discovery walks one company per call and is bounded by the shared provider budget.
    [IN_SEGMENTS_RESOURCE]: 4,
    [IN_FILINGS_RESOURCE]: 14,
    // Links only, and a company's annual reports change once a year — this is the least urgent
    // thing on the cron and is paced accordingly.
    [CN_FILINGS_RESOURCE]: 29,
    // A PDF costs a download and a parse where an XBRL instance costs a parse, and a Chinese report
    // is 1-6 MB against India's 77-109 KB. Paced between the two.
    [CN_SEGMENTS_RESOURCE]: 9,
    [FILING_HISTORY_RESOURCE]: SEC_BACKLOG_TTL_MINUTES,
    [WIKIDATA_RESOURCE]: BACKLOG_TTL_MINUTES,
    [EARNINGS_HISTORY_RESOURCE]: BACKLOG_TTL_MINUTES,
    [STATEMENTS_RESOURCE]: BACKLOG_TTL_MINUTES,
    // NOT the backlog TTL: this resource has no slice to permit. It re-reads the whole
    // forward window every time, so the TTL is the real cadence of the underlying data —
    // dates get rescheduled and consensus is revised, but not many times a day.
    [EARNINGS_RESOURCE]: DAILY_TTL_MINUTES,
    [INSIDER_RESOURCE]: BACKLOG_TTL_MINUTES,
    [FILINGS_RESOURCE]: BACKLOG_TTL_MINUTES,
    [EPS_HISTORY_RESOURCE]: BACKLOG_TTL_MINUTES,
    [ACTIONS_RESOURCE]: BACKLOG_TTL_MINUTES,
    // NOT the 30-day reference TTL any more. This resource has a DAILY pg_cron job (migration
    // 137), so a 30-day TTL made it self-skip 29 days in 30 — measured, an ordinary invocation
    // returned `skipped: fresh or in flight` and only `force: true` ran it. Tolerable while it
    // only derived sector membership from quarterly fund holdings; not once migrations 143 and 151
    // attached the weighted segment classification and the SIC link, both of which follow
    // continuously re-parsed filings. Twelve hours is what makes the daily job actually run.
    [DERIVE_RESOURCE]: 12 * 60,
    // THE FILTER SPINE IS A SNAPSHOT (migration 80) and its TTL is the staleness the app inherits.
    // Every column in it is reference data written by the backlogs, which the cron drives ~8x a
    // day, so an hour bounds how long a newly ingested security can be missing from a filtered
    // list. NOT a reference-length TTL: this resource does not fetch anything, it rebuilds from
    // rows the other resources already wrote, so the cost of running it often is ~2s of database
    // time and no provider quota at all.
    //
    // FIFTY MINUTES ON AN HOURLY CRON, NOT SIXTY. At sixty the TTL equalled the interval, a coin
    // flip on jitter: measured 2026-10-03, the runs alternated, 13:14 skipped `fresh or in
    // flight`, 14:14 refreshed, 15:14 skipped, so the spine refreshed every two hours while every
    // run recorded ok.
    [FACETS_RESOURCE]: 50,
    // Macro series move on a MONTHLY-to-DAILY cadence depending on the series (CPI monthly, EFFR
    // daily), and the resource re-reads all of them in one pass. Six hours is well inside the
    // slowest series' publication rhythm and far outside any provider's patience.
    [MACRO_RESOURCE]: 6 * 60,
    // TEN MINUTES, which is shorter than anything else here and is the point. This resource takes
    // a MEASUREMENT; a TTL on a measurement means "the last reading is still true", which is
    // exactly the assumption that makes a gauge useless. It is called twice per sweep — once
    // before the resources run and once after — so the TTL only has to be shorter than the gap
    // between those two calls (~19 minutes of paced sweep). A backlog-length TTL would silently
    // collapse the pair into one sample and the "what did this sweep drain" reading would be lost.
    [OBSERVABILITY_RESOURCE]: 10,
  }
  // THERE IS NO DEFAULT RESOURCE. It was `sector-performance`, which the D2 cutover retired, so a
  // request naming nothing was answered as if it had asked for a family that moved to Dagster.
  if (!resource) {
    return json({ error: 'name a resource: {"resource": "<name>"}', known: Object.keys(EXTRA_TTL_MINUTES) }, 400)
  }
  if (Object.hasOwn(RETIRED, resource)) {
    return json({
      resource,
      error: `'${resource}' was retired; its family moved to Dagster`,
      replacedBy: RETIRED[resource],
    }, 410)
  }

  const EXTRA = Object.keys(EXTRA_TTL_MINUTES)
  if (!EXTRA.includes(resource)) {
    return json({ error: `unknown resource '${resource}'`, known: EXTRA }, 400)
  }
  const ttlMinutes = EXTRA_TTL_MINUTES[resource]

  // WRITES ARE ADMIN-ONLY. Reads never come through here — the app reads the tables directly over
  // PostgREST — so refusing a non-admin costs a visitor nothing. Previously any valid JWT (i.e.
  // anyone holding the published anon key) could trigger an upstream fetch; the TTL bounded the
  // damage but the endpoint was still a free way to spend someone else's provider quota.
  //
  // The scheduled warm-up therefore runs with the SERVICE-ROLE key, not the anon key.
  if (!isAdmin(req)) {
    return json({ error: 'refresh is restricted to admin users', resource }, 403)
  }

  const market = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  }).schema('market')

  // Atomic claim. `false` means someone else is refreshing, the data is still fresh,
  // or a recent attempt failed — either way no upstream call is made.
  const { data: claimed, error: claimError } = await market.rpc('begin_refresh', {
    p_resource: resource,
    // force -> a zero TTL and no error backoff, but the in-flight window stands.
    p_min_interval: force ? '0 minutes' : `${ttlMinutes} minutes`,
    ...(force ? { p_error_backoff: '0 minutes' } : {}),
  })
  if (claimError) return json({ error: `claim failed: ${claimError.message}` }, 500)
  if (claimed !== true) return json({ resource, skipped: true, reason: 'fresh or in flight' })

  /**
   * Give the claim back before returning early.
   *
   * `begin_refresh` has taken the lock by this point, and every `return` below it that does not
   * call `finish_refresh` leaves `refresh_log` with `finished_at: null` — which blocks the resource
   * for the whole in-flight TTL. Measured 2026-08-15: a `promote-listing` call with no `figi`
   * answered 400 and the NEXT valid call, 45 seconds later, was refused with
   * `{ skipped: true, reason: 'fresh or in flight' }`. It self-heals after two minutes, so this is
   * a short outage rather than a stuck resource — but it is a self-inflicted one, and it is caused
   * by the request that was ALREADY malformed, so the caller gets punished twice for one mistake.
   *
   * This matters more now that a person can trigger `promote-listing` from a button: a mistyped
   * request would make the next legitimate click fail for no reason the reader can see.
   */
  const releaseAnd = async (body: Record<string, unknown>, status: number) => {
    await market.rpc('finish_refresh', {
      p_resource: resource,
      p_ok: false,
      p_error: String(body.error ?? 'invalid request'),
    })
    return json(body, status)
  }

  const fetcher = openbbFetcher(OPENBB_URL)
  try {
    // Macro series, driven ENTIRELY by `market.macro_indicator`. There is no hardcoded list here:
    // adding a series is a row, which is the whole reason that table is a control table. The route,
    // provider and extra params all come from the row.
    if (resource === MACRO_RESOURCE) {
      const { data: series, error: sErr } = await market
        .from('macro_indicator')
        .select('code,route,provider,params,provider_country,unit')
        .eq('enabled', true)
        .order('sort_order')
      if (sErr) throw new Error(`macro_indicator read failed: ${sErr.message}`)
      const rows = series ?? []
      if (rows.length === 0) throw new Error('no enabled macro series — the catalogue is empty')

      const out: Record<string, string> = {}
      let wrote = 0
      let answered = 0
      let lastError = ''
      for (const s of rows) {
        try {
          const qs = new URLSearchParams({ provider: s.provider })
          if (s.provider_country) qs.set('country', s.provider_country)
          for (const [k, v] of Object.entries((s.params ?? {}) as Record<string, string>)) {
            qs.set(k, String(v))
          }
          // A bounded window: these are latest-value panels, not chart history, and an unbounded
          // request on a daily series is the difference between 30 rows and 20,000.
          const since = new Date(Date.now() - 400 * 86_400_000).toISOString().slice(0, 10)
          qs.set('start_date', since)
          const res = await fetcher(`${s.route}?${qs.toString()}`)
          const points = extractMacroPoints(res as Record<string, unknown>[], s.code)
          if (points.length === 0) {
            // AN EMPTY ANSWER IS NOT A FAILURE, and it is not success either. FRED retires series
            // (JPNCPIALLMINMEI returns 0 rows), and a retired id must not sit as a silently blank
            // panel forever — it is reported per series so the catalogue can be corrected.
            out[s.code] = 'no data'
            continue
          }
          answered += 1
          const { error } = await market.from('macro_observation').upsert(
            dedupeBy(
              points.map((pt) => ({
                indicator_code: s.code,
                as_of: pt.as_of,
                dimension: pt.dimension,
                value: pt.value,
                fetched_at: new Date().toISOString(),
              })),
              (r) => `${r.indicator_code}|${r.as_of}|${r.dimension}`,
            ),
            { onConflict: 'indicator_code,as_of,dimension' },
          )
          if (error) throw new Error(`macro_observation upsert failed: ${error.message}`)
          wrote += points.length
          out[s.code] = `${points.length} points`
        } catch (e) {
          // Per SERIES, so one dead route cannot take the other eleven with it — the same rule as
          // batching provider calls everywhere else in this file.
          lastError = e instanceof Error ? e.message : String(e)
          out[s.code] = `failed: ${lastError.slice(0, 120)}`
        }
      }
      // A run where NOTHING answered is a provider or network event, not twelve dead series.
      // Reported as a failure so it cannot look like a quiet success.
      if (answered === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: false })
        return json({ resource, ok: false, series: rows.length, wrote, detail: out, lastError }, 200)
      }
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, series: rows.length, answered, wrote, detail: out })
    }

    if (resource === OBSERVABILITY_RESOURCE) {
      // THE LOOP IS HERE, NOT IN SQL, AND THAT IS THE WHOLE POINT OF MIGRATION 128.
      //
      // `sample_backlogs()` used to loop over all 26 views inside one function, with a per-item
      // timeout and its own exception handler. The first production call died at 8,068 ms:
      // PostgreSQL arms the statement timer ONCE at statement start, a PostgREST RPC is a SINGLE
      // statement, and assigning `statement_timeout` inside it does not re-arm anything — so the
      // role's 8s bounded the whole function, per-item timeout and error handler included.
      //
      // One RPC per backlog means each is bounded by the slowest SINGLE view (pending_prices at
      // 5,380 ms, comfortably under 8s), while the shared `sampledAt` keeps all 26 rows one
      // coherent reading.
      const sampledAt = new Date().toISOString()
      const deadline = Date.now() + 70_000

      const { data: names, error: listErr } = await market.rpc('backlogs_to_sample')
      if (listErr) throw new Error(`backlogs_to_sample failed: ${listErr.message}`)

      let sampled = 0
      let estimated = 0
      let unreadable = 0
      let skippedByDeadline = 0
      for (const backlog of (names ?? []) as string[]) {
        if (Date.now() > deadline) { skippedByDeadline++; continue }
        const { error } = await market.rpc('sample_backlog', {
          p_backlog: backlog,
          p_sampled_at: sampledAt,
        })
        if (!error) { sampled++; continue }

        // The exact count did not fit. Fall back to the PLANNER's estimate, which costs nothing
        // and is written flagged as an estimate — `pending_prices` was 5,380 ms when this was
        // built and is now past the 8s limit, so the one queue big enough to matter would
        // otherwise be the one with no number at all.
        const { error: estErr } = await market.rpc('sample_backlog_estimate', {
          p_backlog: backlog,
          p_sampled_at: sampledAt,
        })
        if (!estErr) { estimated++; continue }

        unreadable++
        // WRITTEN FROM HERE BECAUSE IT CANNOT BE WRITTEN FROM THERE. A statement timeout aborts
        // its transaction, so a row inserted by the function's own exception handler dies with it.
        // NULL depth is not zero: a backlog that has begun timing out must not read as drained,
        // which is the same "a failure is not an empty result" confusion this pipeline has had six
        // times.
        await market.from('backlog_sample').upsert({
          sampled_at: sampledAt,
          backlog,
          depth: null,
          error: error.message.slice(0, 300),
        }, { onConflict: 'sampled_at,backlog' })
      }

      // NO SAMPLE THAT GROWS WITH THE DATA IS TAKEN HERE. An RPC is one statement under the
      // PostgREST role's 8 s timeout, and the samples crossed it one after another as the tables
      // grew: `sample_universe` at 17.6 s (every hourly call from 2026-09-26 22:04 was cancelled
      // while this run recorded `ok: true`), `sample_coverage` at 8.6 s cold (a coin flip that lost
      // whole days, 2026-09-28 among them), and `sample_quality` at 4.4 s, on its way. Each runs
      // from its own pg_cron job as `postgres`: `muffin-universe` (:05), `muffin-quality` (:06) and
      // `muffin-coverage` (05:23 and 17:23), migrations 20261003135000 and 20261003170000. What
      // stays is the loop above, which isolates each backlog in its own RPC and writes its own
      // error rows.
      let pruned = 0
      const { data: p, error: pErr } = await market.rpc('prune_observability', { p_days: 400 })
      if (!pErr) pruned = Number(p ?? 0)

      // Fail only when NOTHING was measured. One unreadable backlog is a recorded fact, not a
      // failed run — and a run that reports failure on it would train everyone to ignore the alert.
      const ok = sampled > 0 || estimated > 0
      await market.rpc('finish_refresh', {
        p_resource: resource,
        p_ok: ok,
        p_error: ok ? null : 'no backlog sample could be taken',
      })
      return json({
        resource,
        ok,
        sampled,
        estimated,
        unreadable,
        skippedByDeadline,
        pruned,
      })
    }

    // Rebuild the denormalised filter spine. See migration 80: as a plain view it timed out for
    // anon (57014) the moment two filters were combined, because the planner's estimates collapse
    // under conjunction. The RPC is SECURITY DEFINER (refresh requires ownership) and refreshes
    // CONCURRENTLY, so readers are never blocked.
    if (resource === FACETS_RESOURCE) {
      const { data, error } = await market.rpc('refresh_facets')
      if (error) throw new Error(`refresh_facets failed: ${error.message}`)
      const row = Array.isArray(data) ? data[0] : data
      const rows = Number(row?.rows_refreshed ?? 0)
      // A spine with no rows is not a successful refresh — it is the Markets tab showing an empty
      // universe. Fail loudly rather than recording ok on a snapshot of nothing.
      if (!Number.isFinite(rows) || rows === 0) {
        throw new Error('refresh_facets returned 0 rows — the filter spine would serve an empty universe')
      }
      // THE SEGMENT SPINE IS NOT REFRESHED HERE. As its own RPC it was one statement under the
      // PostgREST role's 8 s ceiling, and it crossed it as `security_segment` grew: last success
      // 2026-09-23 at 7,992 ms, then 148 timeouts in a row while this resource recorded ok. It runs
      // from the pg_cron job `muffin-segment-spine` (:16) as `postgres`, and records its own
      // duration in `universe_sample` (migration 20261003190000).
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        rows_refreshed: rows,
        refreshed_at: row?.refreshed_at ?? null,
      })
    }

    // Standalone so a mapping edited in Studio (tracked_fund.represents_code) takes effect without
    // re-ingesting 38 filings — and so classification can be re-run when the holdings themselves are
    // still inside their 7-day TTL, which is what blocked the first production run.
    if (resource === DERIVE_RESOURCE) {
      const { data: classified, error } = await market.rpc('derive_classifications')
      if (error) throw new Error(`derive_classifications failed: ${error.message}`)

      // WEIGHTED CLASSIFICATION FROM THE FILINGS, in the same resource because it is the same
      // table and the same kind of work: pure SQL over rows other resources already wrote, with no
      // provider, no rate limit and no backlog. It is NOT called from `security-segments`, whose
      // five-minute schedule would recompute the whole table 288 times a day — the trap where a
      // follow-on pass performed 576,828 upserts to derive 28 rows.
      //
      // This is what makes "Amazon is 19% cloud by revenue and ~60% by operating income"
      // expressible. Every row it writes sits BELOW yfinance in source priority, so no existing
      // sector page, donut or facet changes.
      const { data: weighted, error: wErr } = await market.rpc('derive_segment_classification')
      if (wErr) throw new Error(`derive_segment_classification failed: ${wErr.message}`)

      // SEC's own industry code for each registrant, which `security-filing-history` writes to
      // `security.sic` from the submissions response. A second opinion that is neither a
      // provider's nor a fund's, and it exists for every filer regardless of whether yfinance has
      // ever answered for the symbol.
      const { data: sic, error: sErr } = await market.rpc('derive_sic_classification')
      if (sErr) throw new Error(`derive_sic_classification failed: ${sErr.message}`)

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, classified, weighted, sic })
    }

    // Splits and dividends — the only corporate-action data in this pipeline. See `tiingo.ts` for
    // why this provider, what it does not cover (local foreign listings 404), and why the binding
    // constraint here is UNIQUE SYMBOLS rather than requests per unit time.
    if (resource === ACTIONS_RESOURCE) {
      const token = Deno.env.get('TIINGO_TOKEN') ?? ''
      if (!token) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, note: 'TIINGO_TOKEN is not set — nothing to do' })
      }

      const { data: pending, error: pErr } = await market
        .from('pending_corporate_actions')
        .select('security_id,symbol')
        .order('best_weight', { ascending: false })
        // Unique tiebreak, so the page is a partition and not a sample.
        .order('security_id', { ascending: true })
        .limit(scopeLimit ?? 60)
      if (pErr) throw new Error(`pending_corporate_actions read failed: ${pErr.message}`)
      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        symbol: r.symbol as string,
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'every security has recent actions' })
      }

      // Five years, which is what makes a split usable: a 3Y or 5Y return needs every split inside
      // its own window, and asking for less would silently under-adjust the long periods.
      const since = new Date(Date.now() - 1900 * 86_400_000).toISOString().slice(0, 10)
      const deadline = Date.now() + 60_000
      // ROWS written, and SECURITIES covered — two different units, kept apart because mixing them
      // is how `remaining` came back 0 on a run that had barely started. 60 securities yielded 521
      // action rows on the first live run, so `wanted.length - written` is negative and clamps to
      // zero, reporting a drained backlog while the provider was refusing us.
      let written = 0
      let covered = 0
      let noTicker = 0
      let none = 0
      let failed = 0
      let lastError: string | null = null
      // Proof the endpoint answered for SOMEONE this run. Without it, a run whose every symbol is
      // one Tiingo does not carry marks the whole page — the shape that cost 8,300 securities once.
      let anyAnswer = false

      for (const item of wanted) {
        if (Date.now() > deadline - 4_000) break
        try {
          const actions = await corporateActions(
            item.symbol, since, token, Math.min(12_000, deadline - Date.now()),
          )
          anyAnswer = true
          if (actions.length === 0) { none++; continue }
          const rows = actions.map((a) => ({
            security_id: item.securityId,
            ex_date: a.exDate,
            kind: a.kind,
            value: a.value,
            // The listing this was OBSERVED on. Without it an action cannot be checked against the
            // series it will adjust — which is how 33 of the first 45 securities ended up with a
            // USD dividend recorded against a KRW price series.
            observed_symbol: item.symbol,
            source_code: 'tiingo',
            as_of: new Date().toISOString(),
          }))
          const { error } = await market
            .from('security_corporate_action')
            .upsert(dedupeBy(rows, (r) => `${r.security_id}|${r.ex_date}|${r.kind}`),
              { onConflict: 'security_id,ex_date,kind' })
          if (error) throw new Error(`corporate action upsert failed: ${error.message}`)
          written += rows.length
          covered++
        } catch (e) {
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          if (e instanceof TiingoNoSuchTicker) {
            // A 404 is evidence ABOUT THIS SYMBOL — Tiingo answered and does not carry it. That is
            // the one case that earns a mark, and it needs no run-wide gate because the provider
            // spoke about this security specifically.
            noTicker++
            const { error } = await market
              .from('security')
              .update({ corporate_actions_missing_at: new Date().toISOString() })
              .eq('security_id', item.securityId)
            if (error) throw new Error(`corporate_actions_missing_at update failed: ${error.message}`)
            continue
          }
          failed++
          lastError = msg
          if (throttled(msg)) break
        }
      }

      // A security Tiingo ANSWERED about with no actions is marked only if the endpoint proved it
      // was working this run. `none` alone is not evidence: a provider returning empty arrays
      // wholesale looks identical.
      if (none > 0 && anyAnswer && written > 0) {
        // Nothing to mark — an empty answer here means "no splits or dividends in five years",
        // which is TRUE of most securities and is not a reason to stop asking. The 30-day
        // `as_of` window in the backlog view is what stops it being re-asked immediately.
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        // rows
        written,
        // securities — `covered + none + noTicker` is what the run actually got through, and
        // `asked - that` is what the deadline or a 429 left behind.
        covered, none, noTicker,
        failed, lastError,
        // True when the provider refused us, so a short run is legible as a backoff rather than
        // as a drained backlog.
        //
        // THIS USED TO SAY the shared `throttled()` catches it "on the 429 in the status line",
        // and that assumption was false. Measured 2026-08-28: of six consecutive refusals, ONE
        // arrived as a 429 and five arrived as **HTTP 200 with a plain-text body**, which
        // `res.json()` turned into `Unexpected token 'Y'` — matching nothing. So every one of
        // those runs reported `ok: true, written: 0` with `throttledOut` FALSE, and the
        // throttle-pressure panel showed a clean provider while it was refusing us all day.
        // `tiingo.ts` now classifies the body before parsing, and `throttled()` knows the wording
        // Tiingo actually uses rather than the one we assumed.
        throttledOut: failed > 0 && !!lastError && throttled(lastError),
        asked: wanted.length,
                // `remaining` IS THE BACKLOG, NOT WHAT IS LEFT OF THIS PAGE. Page-scoped, it reads ~0
        // after any successful run however deep the queue is — measured 2026-09-01,
        // security-prices reported `remaining: 0` against a `pending_prices` of 9,013 and
        // security-corporate-actions 60 against 2,533. It is the one number an operator reads
        // to decide whether a backlog is progressing. The page-scoped figure is kept as
        // `unanswered`, which is a different and also useful fact.
        remaining: await backlogSize(market, 'pending_corporate_actions'),
        unanswered: Math.max(0, wanted.length - covered - none - noTicker),
      })
    }

    if (resource === NEWS_RESOURCE) {
      const deadline = Date.now() + 60_000
      const { data: pending, error: pErr } = await market
        .from('pending_news')
        .select('security_id,symbol,fetch_symbol')
        .limit(scopeLimit ?? 400)
      if (pErr) throw new Error(`pending_news read failed: ${pErr.message}`)

      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        fetchSymbol: String(r.fetch_symbol ?? r.symbol),
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, articles: 0, links: 0, remaining: 0, note: 'every equity is current' })
      }

      let articles = 0
      let links = 0
      let batches = 0
      let batchesFailed = 0
      let pruned = 0
      let throttledOut = false
      let lastError: string | null = null

      const BATCH = 20
      for (let i = 0; i < wanted.length && Date.now() < deadline - 10_000; i += BATCH) {
        const group = wanted.slice(i, i + BATCH)
        const bySymbol = new Map(group.map((g) => [g.fetchSymbol.toUpperCase(), g.securityId]))
        batches++
        try {
          const rows = await fetcher(
            `/api/v1/news/company?symbol=${symbolList(group.map((g) => g.fetchSymbol))}` +
              `&provider=yfinance&limit=10`,
            Math.min(30_000, deadline - Date.now()),
          )

          // ONE ROW PER ARTICLE, not per (article, security). 11% of articles come back for more
          // than one security and a market-wide story for hundreds; `text` is dropped because it
          // was byte-identical to `summary` in all 200 rows measured.
          const articleRows = new Map<string, Record<string, unknown>>()
          const linkRows: { url: string; security_id: string; source_code: string }[] = []
          for (const r of rows) {
            const url = String(r.url ?? '')
            const published = String(r.date ?? '')
            const title = String(r.title ?? '')
            if (!url || !published || !title) continue
            const id = bySymbol.get(String(r.symbol ?? '').toUpperCase())
            if (!id) continue
            articleRows.set(url, {
              url,
              published_at: published,
              title,
              source: typeof r.source === 'string' ? r.source : null,
              summary: typeof r.summary === 'string' ? r.summary : null,
            })
            linkRows.push({ url, security_id: id, source_code: 'yfinance' })
          }

          if (articleRows.size > 0) {
            const list = [...articleRows.values()]
            for (let j = 0; j < list.length; j += 500) {
              const { error } = await market.from('news_article')
                .upsert(list.slice(j, j + 500), { onConflict: 'url' })
              if (error) throw new Error(`news_article upsert failed: ${error.message}`)
            }
            articles += list.length

            // THE ARTICLE FIRST, THE LINK SECOND. `news_security.url` is a foreign key, so a link
            // written before its article fails the statement and takes the batch with it.
            const deduped = dedupeBy(linkRows, (r) => `${r.url}|${r.security_id}`)
            for (let j = 0; j < deduped.length; j += 500) {
              const { error } = await market.from('news_security')
                .upsert(deduped.slice(j, j + 500), { onConflict: 'url,security_id', ignoreDuplicates: true })
              if (error) throw new Error(`news_security upsert failed: ${error.message}`)
            }
            links += deduped.length
          }

          // STAMPED WHETHER OR NOT ANYTHING CAME BACK. The backlog is keyed on when we asked, so a
          // security the provider has no news for would otherwise be re-asked every run for ever.
          for (const g of group) {
            const { error } = await market.from('security')
              .update({ news_fetched_at: new Date().toISOString() })
              .eq('security_id', g.securityId)
            if (error) throw new Error(`news_fetched_at update failed: ${error.message}`)
          }
        } catch (e) {
          batchesFailed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          lastError = msg
          if (throttled(msg)) { throttledOut = true; break }
        }
      }

      // PRUNED EVERY RUN, not on a separate schedule. A retention window enforced by a resource
      // nobody remembers to call is a retention window that does not exist.
      const { data: prunedCount, error: prErr } = await market.rpc('prune_news', { p_days: NEWS_RETENTION_DAYS })
      if (prErr) throw new Error(`prune_news failed: ${prErr.message}`)
      pruned = typeof prunedCount === 'number' ? prunedCount : 0

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource, articles, links, batches, batchesFailed, pruned, throttledOut, lastError,
        remaining: await backlogSize(market, 'pending_news'),
      })
    }

    // ANALYST ACTIONS. Distinct in GRAIN from `security_estimate`, which holds the daily consensus
    // LEVEL for 9,009 securities globally; this is the US-listed event stream behind it — who
    // re-rated, when, and in which direction.
    if (resource === PRICE_TARGETS_RESOURCE) {
      const deadline = Date.now() + 60_000
      const { data: pending, error: pErr } = await market
        .from('pending_price_targets')
        .select('security_id,symbol')
        .limit(scopeLimit ?? 600)
      if (pErr) throw new Error(`pending_price_targets read failed: ${pErr.message}`)

      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        symbol: String(r.symbol),
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, actions: 0, remaining: 0, note: 'every US-listed equity is current' })
      }

      let actions = 0
      let batches = 0
      let batchesFailed = 0
      let advanced = 0
      let throttledOut = false
      let stoppedEarly = false
      let lastError: string | null = null

      // DO NOT START A BATCH THE BUDGET CANNOT FINISH, AND LEARN THE COST RATHER THAN GUESSING IT.
      // The first version gated on a flat `deadline - 8_000`. Measured on the first live run, a
      // batch of 40 takes ~15s against finviz, so the final batch of EVERY run was started with 8s
      // left and cut short: `lastError: "Signal timed out."` on every single run, for ever. Nothing
      // was corrupted — `fetchWithIsolation` returned the error, the cursor correctly did not
      // advance those securities and they came back next run — but it permanently poisons the one
      // field an operator reads to tell whether anything is wrong, which is this file's
      // "a monitoring line with no content" failure.
      //
      // A bigger constant would only re-tune the magic number to one afternoon's measurement. The
      // budget is LEARNED instead: after each batch we know exactly what a batch costs here, so the
      // next one starts only if that much time plus a small margin remains. It self-corrects when
      // the provider slows down or speeds up, and needs no seed — the first batch always runs,
      // because a run that attempts nothing is worse than one that overruns slightly.
      const BATCH = 40
      let lastBatchMs = 0
      for (let i = 0; i < wanted.length; i += BATCH) {
        if (Date.now() + lastBatchMs + 3_000 > deadline) { stoppedEarly = true; break }
        const group = wanted.slice(i, i + BATCH)
        const bySymbol = new Map(group.map((g) => [g.symbol.toUpperCase(), g.securityId]))
        const startedAt = Date.now()
        batches++
        try {
          // ISOLATED, because one dead symbol kills a batched provider call and this backlog is
          // weight-ordered — the same poisoned head would return every run. A delisted US ticker is
          // the realistic case here, since the view already excludes the suffixed and OTC lines
          // finviz answers with 400.
          const iso = await fetchWithIsolation(
            fetcher,
            (syms: string[]) =>
              `/api/v1/equity/estimates/price_target?symbol=${symbolList(syms)}&provider=finviz`,
            group.map((g) => g.symbol),
            Math.min(30_000, deadline - Date.now()),
            deadline,
          )
          // A BATCH THAT ERRORED IS A FAILED BATCH. Reporting `batchesFailed: 0` beside a batch
          // that answered nothing made the tally read as a clean run — `fetchWithIsolation`
          // returns its error rather than throwing, so the catch below never sees it.
          if (iso.error) {
            lastError = iso.error
            batchesFailed++
          }

          const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null)
          const payload = iso.rows.flatMap((r) => {
            const id = bySymbol.get(String(r.symbol ?? '').toUpperCase())
            const day = String(r.published_date ?? '').slice(0, 10)
            const firm = typeof r.analyst_company === 'string' ? r.analyst_company.trim() : ''
            // (date, firm) is the key, so a row missing either cannot be stored idempotently.
            if (!id || !day || !firm) return []
            return [{
              security_id: id,
              published_date: day,
              analyst_company: firm,
              // `adj_price_target` IS THE NEW TARGET and `price_target` the PREVIOUS one. Measured
              // over 160 rows: `price_target` NEVER appears alone, `adj_price_target` appears alone
              // 55 times (Initiated/Resumed have no prior target), and where both appear they always
              // differ — which rules out `adj` meaning split-adjusted. Reading `price_target` as the
              // target would store the SUPERSEDED number and be null 40% of the time.
              target_from: num(r.price_target),
              target_to: num(r.adj_price_target),
              status: typeof r.status === 'string' ? r.status : null,
              rating_change: typeof r.rating_change === 'string' ? r.rating_change : null,
              source_code: 'finviz',
              fetched_at: new Date().toISOString(),
            }]
          })

          if (payload.length > 0) {
            const { error } = await market.from('security_price_target').upsert(
              dedupeBy(payload, (r) => `${r.security_id}|${r.published_date}|${r.analyst_company}`),
              { onConflict: 'security_id,published_date,analyst_company' })
            if (error) throw new Error(`security_price_target upsert failed: ${error.message}`)
            actions += payload.length
          }

          // ADVANCE THE WHOLE GROUP ON A SUCCESSFUL ASK, NOT ONLY THE SYMBOLS THAT ANSWERED.
          // `fetchWithIsolation` returns a null error only when the provider demonstrably answered
          // — with rows, or after isolating each symbol and proving the provider healthy with a
          // control. A US small cap with no analyst coverage legitimately returns NOTHING, so
          // advancing only on rows would leave it at the head of a weight-ordered backlog for ever:
          // the stall this codebase has hit in five separate resources. Conversely a transport
          // failure advances nothing, because a thirty-second outage must not cost a week of
          // staleness — the rule `insider_fetched_at` records.
          if (!iso.error) {
            const { error } = await market.from('security')
              .update({ price_targets_fetched_at: new Date().toISOString() })
              .in('security_id', group.map((g) => g.securityId))
            if (error) throw new Error(`price_targets_fetched_at update failed: ${error.message}`)
            advanced += group.length
          }
        } catch (e) {
          batchesFailed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          lastError = msg
          if (throttled(msg)) { throttledOut = true; break }
        } finally {
          // In `finally` so a thrown batch still teaches the loop what a batch costs — otherwise a
          // single slow failure would leave the estimate stale and the next start over-eager.
          lastBatchMs = Date.now() - startedAt
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        // `stoppedEarly` is the ORDINARY case for a 3,262-deep backlog and is reported as its own
        // fact rather than as an error: the run ended because our budget ended, not because
        // anything failed, and those are different things.
        resource, actions, batches, batchesFailed, advanced, stoppedEarly, throttledOut, lastError,
        remaining: await backlogSize(market, 'pending_price_targets'),
      })
    }

    // SEVENTEEN YEARS, QUARTERLY, ONE REQUEST PER FILER.
    if (resource === XBRL_RESOURCE) {
      const deadline = Date.now() + 60_000
      const { data: concepts, error: cErr } = await market
        .from('xbrl_concept')
        .select('metric_code,concept,priority,unit,taxonomy')
      if (cErr) throw new Error(`xbrl_concept read failed: ${cErr.message}`)
      const specs: ConceptSpec[] = (concepts ?? []).map((c) => ({
        metricCode: c.metric_code as string,
        concept: c.concept as string,
        priority: Number(c.priority),
        unit: String(c.unit),
        taxonomy: String(c.taxonomy ?? 'us-gaap'),
      }))
      if (specs.length === 0) throw new Error('xbrl_concept is empty — every filer would yield nothing')

      const { data: pending, error: pErr } = await market
        .from('pending_xbrl')
        .select('security_id,cik')
        .limit(scopeLimit ?? 150)
      if (pErr) throw new Error(`pending_xbrl read failed: ${pErr.message}`)

      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        cik: Number(r.cik),
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'every filer is current' })
      }

      let written = 0
      let filers = 0
      let noFacts = 0
      let failed = 0
      let anySucceeded = false
      let lastError: string | null = null

      for (const item of wanted) {
        // ONE AT A TIME AND BOUNDED. companyfacts is ~3.6 MB for a large filer; holding several in
        // a 256 MB worker at once is how a resource dies with a bare 502 instead of an error.
        if (Date.now() > deadline - 6_000) break
        try {
          const payload = await fetchCompanyFacts(item.cik, Math.min(25_000, deadline - Date.now()))
          if (payload !== null) anySucceeded = true
          const facts = payload === null ? [] : factsFromCompanyFacts(payload, specs)
          filers++

          if (facts.length === 0) {
            // Marked only when SEC actually answered for someone this run — a refusal is about the
            // endpoint, not about this filer.
            if (anySucceeded) {
              noFacts++
              const { error } = await market
                .from('security')
                .update({ xbrl_missing_at: new Date().toISOString() })
                .eq('security_id', item.securityId)
              if (error) throw new Error(`xbrl_missing_at update failed: ${error.message}`)
            }
          } else {
            const rows = facts.map((f) => ({
              security_id: item.securityId,
              metric_code: f.metricCode,
              period_type: f.periodType,
              as_of: f.periodEnding,
              value: f.value,
              currency_code: f.currency,
              source_code: 'sec-xbrl',
              fetched_at: new Date().toISOString(),
            }))
            // LEARN THE CURRENCY FIRST. `security_metric.currency_code` is a foreign key, and an
            // IFRS filer reports in its own currency — DKK, TWD, EUR — so a code the table has
            // never seen fails the STATEMENT and takes the whole filer with it.
            const curs = [...new Set(rows.map((r) => r.currency_code).filter(Boolean))] as string[]
            if (curs.length > 0) {
              const { error: cuErr } = await market.from('currency')
                .upsert(curs.map((code) => ({ code })), { onConflict: 'code', ignoreDuplicates: true })
              if (cuErr) throw new Error(`currency learn failed: ${cuErr.message}`)
            }
            for (let i = 0; i < rows.length; i += 500) {
              const { error } = await market
                .from('security_metric')
                .upsert(
                  dedupeBy(rows.slice(i, i + 500),
                    (r) => `${r.security_id}|${r.metric_code}|${r.period_type}|${r.as_of}`),
                  { onConflict: 'security_id,metric_code,period_type,as_of' },
                )
              if (error) throw new Error(`security_metric xbrl upsert failed: ${error.message}`)
            }
            written += rows.length
          }

          // RECORDED WHETHER OR NOT FACTS CAME BACK. The backlog is keyed on when we last ASKED,
          // so failing to stamp it here would re-ask the same filers every run for ever.
          const { error: tErr } = await market
            .from('security')
            .update({ xbrl_fetched_at: new Date().toISOString() })
            .eq('security_id', item.securityId)
          if (tErr) throw new Error(`xbrl_fetched_at update failed: ${tErr.message}`)
        } catch (e) {
          failed++
          lastError = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource, written, filers, noFacts, failed, lastError,
        remaining: await backlogSize(market, 'pending_xbrl'),
      })
    }

    // THE ONLY MULTI-VALUED CLASSIFICATION AVAILABLE HERE.
    //
    // Every other source gives one answer per security. Wikidata's `industry (P452)` is a list, and
    // it joins on the ISIN this pipeline already holds — Amazon comes back as retail, web service,
    // e-commerce and web hosting service rather than as one of them.
    if (resource === WIKIDATA_RESOURCE) {
      const deadline = Date.now() + 60_000

      const { data: pending, error: pErr } = await market
        .from('pending_wikidata')
        .select('security_id,isin')
        .limit(scopeLimit ?? WIKIDATA_BATCH * WIKIDATA_BATCHES)
      if (pErr) throw new Error(`pending_wikidata read failed: ${pErr.message}`)

      const wanted = (pending ?? []).map((r) => ({
        securityId: String(r.security_id),
        isin: String(r.isin),
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'every equity has been asked' })
      }

      const byIsin = new Map<string, string[]>()
      for (const w of wanted) {
        const a = byIsin.get(w.isin)
        if (a) a.push(w.securityId)
        else byIsin.set(w.isin, [w.securityId])
      }

      let written = 0
      let matched = 0
      let unmatched = 0
      let batches = 0
      let batchesFailed = 0
      let firstError: string | null = null
      let lastError: string | null = null

      const isins = [...byIsin.keys()]
      for (let i = 0; i < isins.length; i += WIKIDATA_BATCH) {
        if (Date.now() > deadline - 12_000) break
        const chunk = isins.slice(i, i + WIKIDATA_BATCH)
        batches++
        try {
          const results = await fetchIndustries(chunk, Math.min(30_000, deadline - Date.now()))
          const found = new Map(results.map((r) => [r.isin, r]))

          // The taxonomy nodes, created on discovery. Wikidata's vocabulary is open, so there is
          // no list to seed — unlike SIC, where SEC publishes a closed 444 and inventing entries
          // would be authoring reference data from memory.
          const labels = [...new Set(results.flatMap((r) => r.industries))]
          if (labels.length > 0) {
            const { error: nErr } = await market.from('taxonomy_node').upsert(
              dedupeBy(
                labels.map((l) => ({ taxonomy_id: 'wikidata', code: slug(l), name: l, level: 1 })),
                (r) => `${r.taxonomy_id}|${r.code}`,
              ),
              { onConflict: 'taxonomy_id,code', ignoreDuplicates: true },
            )
            if (nErr) throw new Error(`taxonomy_node upsert failed: ${nErr.message}`)
          }

          // Read the node ids back — the upsert above ignores duplicates, so it returns nothing
          // useful for rows that already existed.
          const codes = [...new Set(labels.map(slug))]
          const nodeId = new Map<string, string>()
          for (let c = 0; c < codes.length; c += 100) {
            const { data: nodes, error: qErr } = await market
              .from('taxonomy_node')
              .select('node_id,code')
              .eq('taxonomy_id', 'wikidata')
              .in('code', codes.slice(c, c + 100))
            if (qErr) throw new Error(`taxonomy_node read failed: ${qErr.message}`)
            for (const n of nodes ?? []) nodeId.set(String(n.code), String(n.node_id))
          }

          const rows: Record<string, unknown>[] = []
          const nowIso = new Date().toISOString()
          for (const isin of chunk) {
            const hit = found.get(isin)
            const ids = byIsin.get(isin) ?? []
            if (!hit || hit.industries.length === 0) {
              unmatched += ids.length
              const { error } = await market
                .from('security')
                .update({ wikidata_missing_at: nowIso })
                .in('security_id', ids)
              if (error) throw new Error(`wikidata_missing_at update failed: ${error.message}`)
              continue
            }
            matched += ids.length
            for (const securityId of ids) {
              for (const label of hit.industries) {
                const id = nodeId.get(slug(label))
                if (id) {
                  rows.push({
                    security_id: securityId, node_id: id,
                    source_code: 'wikidata', as_of: nowIso,
                  })
                }
              }
            }
          }

          for (let r = 0; r < rows.length; r += 500) {
            const { error } = await market.from('security_taxonomy').upsert(
              dedupeBy(rows.slice(r, r + 500),
                (x) => `${x.security_id}|${x.node_id}|${x.source_code}`),
              { onConflict: 'security_id,node_id,source_code', ignoreDuplicates: true },
            )
            if (error) throw new Error(`security_taxonomy wikidata upsert failed: ${error.message}`)
          }
          written += rows.length
        } catch (e) {
          // A FAILED BATCH MARKS NOTHING. The endpoint is shared and public, so a timeout or a
          // throttle is about the endpoint rather than about these ISINs — negative-caching them
          // for 30 days on an outage is precisely how 1,369 securities were once written off.
          batchesFailed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          if (firstError === null) firstError = msg
          lastError = msg
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource, written, matched, unmatched, batches, batchesFailed, firstError, lastError,
        remaining: await backlogSize(market, 'pending_wikidata'),
      })
    }

    // THE COMPLETE FILING HISTORY, AND THE SIC, IN ONE REQUEST PER FILER.
    //
    // `security-filings` asks openbb for `equity/fundamental/filings?...&limit=40`, which is two to
    // three years per company — measured, `security_filing` held 8,450 accounts filings for 2026
    // and FOUR for 2015. Segment depth is exactly filing depth, so that limit was the ceiling on
    // this whole feature. SEC's own submissions API returns everything in one keyless call, and
    // carries `sic` in the same payload.
    if (resource === FILING_HISTORY_RESOURCE) {
      const deadline = Date.now() + 60_000

      const { data: pending, error: pErr } = await market
        .from('pending_filing_history')
        .select('security_id,cik')
        .limit(scopeLimit ?? FILING_HISTORY_PAGE)
      if (pErr) throw new Error(`pending_filing_history read failed: ${pErr.message}`)

      const wanted = (pending ?? []).map((r) => ({
        securityId: String(r.security_id),
        cik: Number(r.cik),
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'every filer has a walked history' })
      }

      let written = 0
      let filers = 0
      let classified = 0
      let tickers = 0
      let noFilings = 0
      let failed = 0
      let firstError: string | null = null
      let lastError: string | null = null

      for (const item of wanted) {
        if (Date.now() > deadline - 8_000) break
        try {
          const head = await fetchSubmissions(item.cik, Math.min(25_000, deadline - Date.now()))
          if (head === null) {
            // SEC HAS NO SUCH CIK — an ANSWER, not a failure, so the cursor advances. Leaving it
            // would re-ask for a filer that will never exist, every run, for ever.
            noFilings++
          } else {
            const parsed = submissionsFrom(head, ACCOUNTS_FORMS)
            const rows = [...parsed.filings]

            // The older pages hold everything before the 1,000 most recent filings, which for an
            // active filer is where the pre-2020 accounts live.
            for (const page of parsed.olderPages.slice(0, FILING_HISTORY_MAX_PAGES)) {
              if (Date.now() > deadline - 10_000) break
              const older = await fetchSubmissionsPage(page, Math.min(20_000, deadline - Date.now()))
              if (older !== null) rows.push(...submissionsFrom(older, ACCOUNTS_FORMS).filings)
            }

            if (rows.length === 0) noFilings++
            else {
              const filingRows = rows.map((f) => ({
                security_id: item.securityId,
                accession_number: f.accession,
                report_type: f.form,
                filing_date: f.filingDate,
                report_date: f.reportDate,
                is_xbrl: f.isXbrl,
                source_code: 'sec-submissions',
                as_of: new Date().toISOString(),
              }))
              for (let i = 0; i < filingRows.length; i += 500) {
                const { error } = await market
                  .from('security_filing')
                  .upsert(
                    dedupeBy(filingRows.slice(i, i + 500),
                      (r) => `${r.security_id}|${r.accession_number}`),
                    // DO NOTHING, NOT DO UPDATE. `security-filings` owns the recent window and
                    // writes `report_url` / `filing_detail_url` this endpoint does not carry; a
                    // full-row upsert would blank those every month and the two resources would
                    // overwrite each other's provenance on every rotation. This resource only ever
                    // ADDS the history that was missing.
                    { onConflict: 'security_id,accession_number', ignoreDuplicates: true },
                  )
                if (error) throw new Error(`security_filing history upsert failed: ${error.message}`)
              }
              written += filingRows.length
            }

            // THE SIC RIDES ALONG. Sixth instance in this pipeline of "the answer is already in a
            // response you fetch" — the classification costs no request of its own.
            const patch: Record<string, unknown> = {
              filing_history_fetched_at: new Date().toISOString(),
            }
            if (parsed.sic !== null) {
              patch.sic = parsed.sic
              patch.sic_description = parsed.sicDescription
              classified++
            }
            const { error: uErr } = await market
              .from('security').update(patch).eq('security_id', item.securityId)
            if (uErr) throw new Error(`filing_history cursor update failed: ${uErr.message}`)

            // AND SO DOES THE REGISTRANT'S WHOLE IDENTITY, including the one fact this pipeline
            // otherwise GUESSES: its US ticker. OpenFIGI's US lookup returns the thin OTC
            // foreign-ordinary line for most foreign companies (TSMWF, ASMLF, BUDFF); SEC states
            // TSM, and states it in a response already on the wire.
            const pf = parsed.profile
            const { error: fpErr } = await market.from('filer_profile').upsert({
              security_id: item.securityId,
              entity_type: pf.entityType,
              owner_org: pf.ownerOrg,
              ein: pf.ein,
              lei: pf.lei,
              category: pf.category,
              fiscal_year_end: pf.fiscalYearEnd,
              state_of_incorporation: pf.stateOfIncorporation,
              website: pf.website,
              investor_website: pf.investorWebsite,
              phone: pf.phone,
              us_ticker: pf.usTicker,
              us_exchange: pf.usExchange,
              hq_street: pf.hqStreet,
              hq_city: pf.hqCity,
              hq_state_or_country: pf.hqStateOrCountry,
              hq_zip: pf.hqZip,
              source_code: 'sec-submissions',
              as_of: new Date().toISOString(),
            }, { onConflict: 'security_id' })
            if (fpErr) throw new Error(`filer_profile upsert failed: ${fpErr.message}`)
            if (pf.usTicker !== null) tickers++

            if (pf.formerNames.length > 0) {
              const { error: fnErr } = await market.from('security_former_name').upsert(
                dedupeBy(
                  pf.formerNames.map((f) => ({
                    security_id: item.securityId,
                    name: f.name,
                    from_date: f.from,
                    to_date: f.to,
                    source_code: 'sec-submissions',
                  })),
                  (r) => `${r.security_id}|${r.name}`,
                ),
                { onConflict: 'security_id,name' },
              )
              if (fnErr) throw new Error(`security_former_name upsert failed: ${fnErr.message}`)
            }
            filers++
            continue
          }

          // Reached only for the "SEC has no such CIK" branch above: the cursor still advances,
          // because that is an answer about the filer rather than a failure to ask.
          const { error: cErr } = await market
            .from('security')
            .update({ filing_history_fetched_at: new Date().toISOString() })
            .eq('security_id', item.securityId)
          if (cErr) throw new Error(`filing_history cursor update failed: ${cErr.message}`)
          filers++
        } catch (e) {
          failed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          if (firstError === null) firstError = msg
          lastError = msg
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource, written, filers, classified, tickers, noFilings, failed, firstError, lastError,
        remaining: await backlogSize(market, 'pending_filing_history'),
      })
    }

    // REVENUE AND PROFIT PER BUSINESS LINE — the numbers companyfacts cannot give.
    //
    // `security-xbrl` above reads the SAME company through `data.sec.gov`, and the XBRL REST APIs
    // STRIP DIMENSIONS: measured, AAPL revenue comes back as one value per period ($416.16bn for
    // FY2025) with no iPhone in it. The filing's own instance keeps them, and is small — 778 KB for
    // a 10-Q, 2.07 MB for a 10-K — so this is an ordinary backlog over filings `security_filing`
    // already holds rather than a bulk import that would need a second executor.
    // ── KOREA: DISCOVERY ────────────────────────────────────────────────────────────────────────
    //
    // Two phases, because DART caps `list.json` at a THREE-MONTH window whenever `corp_code` is
    // absent (measured: a 9-month request answers `status 100`). Phase A sweeps windows to learn
    // which listed filers we hold; phase B then asks each one for its own history, where no window
    // limit applies at all.
    //
    // CURSORED, NOT A SINGLE SWEEP: 61 list calls took 247 s, far more than one 90 s worker.
    if (resource === KR_FILINGS_RESOURCE) {
      const deadline = Date.now() + 70_000
      const budget = () => Math.min(30_000, Math.max(2_000, deadline - Date.now()))

      const { data: cursorRows, error: cErr } = await market
        .from('dart_discovery_cursor').select('window_end,cls,page,mapped_at').limit(1)
      if (cErr) throw new Error(`dart_discovery_cursor read failed: ${cErr.message}`)
      const cursor = cursorRows?.[0] ?? { window_end: null, cls: 'Y', page: 1, mapped_at: null }

      let mapped = 0
      let filingsWritten = 0
      let walkedCount = 0
      let windows = 0
      let sweepPosition: string | null = null
      let listCalls = 0
      let firstError: string | null = null
      let lastError: string | null = null

      // The six-digit code in front of every Korean symbol is DART's own `stock_code`, so the
      // mapping needs no separate download — `corpCode.xml` is 3.6 MB and timed out twice at 240 s
      // in an earlier spike, and is deliberately not used.
      const { data: krRows, error: kErr } = await market
        .from('security_facets')
        .select('security_id,symbol')
        .eq('country_iso2', 'KR')
        .eq('security_type_code', 'equity')
        .limit(2000)
      if (kErr) throw new Error(`security_facets read failed: ${kErr.message}`)
      const byStockCode = new Map<string, string>()
      for (const r of krRows ?? []) {
        const code = dart.stockCodeFromSymbol(r.symbol as string | null)
        if (code) byStockCode.set(code, r.security_id as string)
      }

      if (cursor.mapped_at === null) {
        // ── PHASE A: which of our securities file with DART ──────────────────────────────────
        // Walks backwards in 3-month windows. Korean annual reports are filed within 90 days of a
        // December year-end, so the March window carries almost all of them — but walking rather
        // than assuming means a company with a non-calendar year is picked up too.
        let end = cursor.window_end ? new Date(cursor.window_end) : new Date()
        const ymd = (d: Date) => d.toISOString().slice(0, 10).replace(/-/g, '')
        const seen = new Map<string, dart.DartFiling>()

        // RESUMES WHERE THE LAST RUN STOPPED, AND ONLY ADVANCES A WINDOW IT ACTUALLY FINISHED.
        // A window is ~35 calls and a run affords ~15 (DART answers in ~3.5 s from the node), so
        // "walk two windows per run" is not achievable and pretending otherwise loses pages: the
        // old shape advanced `end` when the deadline cut the page loop short, recording a window as
        // swept with two thirds of it unread. A refused sweep must not read as a finished one.
        let cls: 'Y' | 'K' = (cursor.cls === 'K' ? 'K' : 'Y')
        let page = Math.max(1, Number(cursor.page ?? 1))
        let exhausted = false

        outer:
        while (Date.now() < deadline - 20_000 && windows < 2) {
          const from = new Date(end)
          from.setMonth(from.getMonth() - 3)
          from.setDate(from.getDate() + 1)
          // Both share classes for this window, starting wherever the cursor left off.
          for (const c of (['Y', 'K'] as const).slice(cls === 'K' ? 1 : 0)) {
            cls = c
            let pages = page
            while (page <= pages) {
              if (Date.now() > deadline - 15_000) break outer
              try {
                const res = await dart.listFilings(
                  { from: ymd(from), to: ymd(end), corpCls: c, page }, budget(),
                )
                listCalls++
                pages = Math.max(1, res.totalPages)
                for (const f of res.filings) {
                  if (f.stockCode && byStockCode.has(f.stockCode)) seen.set(f.rceptNo, f)
                }
              } catch (e) {
                const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
                if (firstError === null) firstError = msg
                lastError = msg
                // A window we could not read is NOT a window we have read. Stop here and let the
                // next run resume at this exact page rather than advancing past it.
                break outer
              }
              page++
            }
            page = 1
          }
          // Both classes ran to their last page: this window is genuinely done.
          windows++
          exhausted = true
          cls = 'Y'
          page = 1
          end = new Date(from)
          end.setDate(end.getDate() - 1)
        }

        // `security_filer` is the mapping; `security_filing` is the queue. Both are written here so
        // the parse resource costs ONE fetch per run rather than a lookup plus a fetch.
        const filers = new Map<string, { security_id: string; source_code: string; filer_id: string }>()
        const filings: Record<string, unknown>[] = []
        for (const f of seen.values()) {
          const securityId = byStockCode.get(f.stockCode)!
          filers.set(securityId, { security_id: securityId, source_code: 'dart', filer_id: f.corpCode })
          if (!f.reportName.includes(KR_ANNUAL_FORM)) continue
          filings.push({
            security_id: securityId,
            accession_number: f.rceptNo,
            report_type: KR_ANNUAL_FORM,
            filing_date: `${f.receiptDate.slice(0, 4)}-${f.receiptDate.slice(4, 6)}-${f.receiptDate.slice(6, 8)}`,
            source_code: 'dart',
            is_xbrl: true,
          })
        }
        if (filers.size > 0) {
          const { error } = await market.from('security_filer')
            .upsert([...filers.values()], { onConflict: 'security_id,source_code' })
          if (error) throw new Error(`security_filer upsert failed: ${error.message}`)
          mapped = filers.size
        }
        if (filings.length > 0) {
          const { error } = await market.from('security_filing')
            .upsert(dedupeBy(filings, (r) => `${r.security_id}|${r.accession_number}`),
              { onConflict: 'security_id,accession_number', ignoreDuplicates: true })
          if (error) throw new Error(`security_filing upsert failed: ${error.message}`)
          filingsWritten = filings.length
        }

        // Two full years of windows is past every December year-end twice; anything still unmapped
        // does not file a periodic report we can read, and re-walking history for ever would spend
        // a call budget on a settled answer.
        // `exhausted` gates the completion test: two years of windows is the stopping rule, and a
        // run that merely ran out of budget inside the current window has not reached it.
        const done = exhausted && end < new Date(Date.now() - 2 * 365 * 24 * 3600 * 1000)
        const { error: uErr } = await market.from('dart_discovery_cursor').update({
          window_end: end.toISOString().slice(0, 10),
          cls,
          page,
          mapped_at: done ? new Date().toISOString() : null,
          updated_at: new Date().toISOString(),
        }).eq('singleton', true)
        sweepPosition = `${end.toISOString().slice(0, 10)} ${cls} p${page}`
        if (uErr) throw new Error(`dart_discovery_cursor update failed: ${uErr.message}`)
      } else {
        // ── PHASE B: one company's whole history, no window limit ────────────────────────────
        // AN ANTI-JOIN, NOT AN ORDERING. Read straight from `security_filer` with a `limit`, this
        // returns the same eight companies on every run for ever — `written` reads as throughput
        // and the ninth company is never reached. `pending_kr_history` excludes what has been
        // walked in the last 90 days, so the page advances and the re-walks still happen.
        const { data: needy, error: nErr } = await market
          .from('pending_kr_history')
          .select('security_id,filer_id')
          .limit(scopeLimit ?? 8)
        if (nErr) throw new Error(`pending_kr_history read failed: ${nErr.message}`)

        const filings: Record<string, unknown>[] = []
        // Stamped only for a company the provider actually ANSWERED for. `parseListBody` already
        // separates DART's '013' — "no matching data", an empty answer — from a real failure, so a
        // company with no annual report in range is settled and a company we could not reach comes
        // back next run. Advancing on a transport error would make a thirty-second DART outage
        // cost that company a 90-day wait.
        const walked: string[] = []
        for (const r of needy ?? []) {
          if (Date.now() > deadline - 15_000) break
          try {
            const res = await dart.listFilings(
              { corpCode: String(r.filer_id), from: '20150101', to: new Date().toISOString().slice(0, 10).replace(/-/g, '') },
              budget(),
            )
            listCalls++
            walked.push(String(r.security_id))
            for (const f of res.filings) {
              if (!f.reportName.includes(KR_ANNUAL_FORM)) continue
              filings.push({
                security_id: r.security_id,
                accession_number: f.rceptNo,
                report_type: KR_ANNUAL_FORM,
                filing_date: `${f.receiptDate.slice(0, 4)}-${f.receiptDate.slice(4, 6)}-${f.receiptDate.slice(6, 8)}`,
                source_code: 'dart',
                is_xbrl: true,
              })
            }
          } catch (e) {
            const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
            if (firstError === null) firstError = msg
            lastError = msg
          }
        }
        if (filings.length > 0) {
          const { error } = await market.from('security_filing')
            .upsert(dedupeBy(filings, (r) => `${r.security_id}|${r.accession_number}`),
              { onConflict: 'security_id,accession_number', ignoreDuplicates: true })
          if (error) throw new Error(`security_filing upsert failed: ${error.message}`)
          filingsWritten = filings.length
        }
        // AFTER the filings are safely written, never before: stamping first and failing the upsert
        // would advance the cursor past work that was never stored.
        if (walked.length > 0) {
          const { error } = await market.from('security_filer')
            .update({ history_walked_at: new Date().toISOString() })
            .eq('source_code', 'dart')
            .in('security_id', walked)
          if (error) throw new Error(`security_filer cursor update failed: ${error.message}`)
          walkedCount = walked.length
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource, phase: cursor.mapped_at === null ? 'mapping' : 'history',
        // `written` AS WELL AS `filings`, because `refresh_run.written` is a GENERATED column over
        // this jsonb and a resource that never names the key contributes NOTHING to the throughput
        // panel — it draws as a flat line while the resource is doing real work. Measured
        // 2026-09-05: 42 runs, `written` null throughout, 118 and 92 filings written in the last
        // two. `filings` is kept as the resource's own noun; `written` is the shared unit.
        mapped, written: filingsWritten, filings: filingsWritten,
        walked: walkedCount, windows, listCalls,
        // WHERE THE SWEEP IS, not just how much it did. `windows: 0` is the normal case for a run
        // that made real progress inside one window, so without the position it reads as a stall.
        ...(cursor.mapped_at === null ? { at: sweepPosition } : {}),
        firstError, lastError,
        // ITS OWN BACKLOG, not the parse queue's. `remaining` has to mean the same thing in every
        // resource, and reporting `pending_kr_segments` here would describe a different resource's
        // work — a number that moves when this one does nothing.
        remaining: await backlogSize(market, 'pending_kr_history'),
      })
    }

    // ── KOREA: PARSE ────────────────────────────────────────────────────────────────────────────
    //
    // ONE FILING PER RUN, and that is a measurement rather than caution: 802 KB takes 73.5 s from
    // outside Korea against a 90 s worker. A killed worker does not throw, it DIES — holding the
    // in-flight lock and stamping nothing — which is the 127 MB AEP filing that blocked the SEC
    // queue for two days. So the fetch takes the REMAINING budget, and anything it cannot finish is
    // left for the next run with the cache warm behind it.
    // ── China: filing LINKS, because every filing is a PDF ──────────────────────────────────────
    //
    // China is the largest coverage gap at 2,311 equities and was spiked NOT VIABLE for segments
    // (migration 183): CNINFO's route works and is reachable, but every filing is a PDF. A PDF
    // cannot give a segment split; it can give a reader the annual report, which is better than the
    // nothing those securities have today — and it costs no schema and no UI, because
    // `security_filing.report_url` exists and the Filings section already renders it as a link.
    if (resource === CN_FILINGS_RESOURCE) {
      const deadline = Date.now() + 70_000

      const { data: pending, error: pErr } = await market
        .from('pending_cn_filings')
        .select('security_id,symbol')
        .limit(scopeLimit ?? 8)
      if (pErr) throw new Error(`pending_cn_filings read failed: ${pErr.message}`)

      let walked = 0
      let written = 0
      let noOrgId = 0
      let failed = 0
      let firstError: string | null = null
      let lastError: string | null = null

      for (const item of pending ?? []) {
        if (Date.now() > deadline - 12_000) break
        const code = String(item.symbol)
        try {
          const orgId = await cninfo.orgIdFor(code, Math.min(20_000, deadline - Date.now()))
          walked++
          if (orgId === null) {
            // A CODE CNINFO DOES NOT KNOW IS AN ANSWER, not a failure — a delisted or
            // Hong-Kong-listed line will never resolve, and counting it as an error would make a
            // healthy run look broken.
            noOrgId++
          } else {
            const filings = await cninfo.annualReports(
              code, orgId, Math.min(25_000, deadline - Date.now()),
            )
            if (filings.length > 0) {
              const rows = filings.map((f) => ({
                security_id: item.security_id,
                // The PDF's own URL is the document's identity here; there is no accession number
                // in this system. `(source_code, accession_number)` is already the key, so only the
                // NAME is SEC-specific.
                accession_number: f.url,
                report_type: CN_FORM_FOR[f.kind] ?? CN_ANNUAL_FORM,
                report_date: f.date,
                report_url: f.url,
                source_code: 'cninfo',
                // LOAD-BEARING. `pending_segments` and its siblings select filings to PARSE; a PDF
                // that looked parseable would send the segment resources to spend their budget
                // fetching documents they cannot read.
                is_xbrl: false,
              }))
              // MERGE, NOT IGNORE. `ignoreDuplicates` meant a re-walk could never correct a row it
              // had already written — which is exactly what was needed once the three document
              // kinds were told apart, and would have left the first 13 companies mis-typed for
              // ever. Only the columns in the payload are written, so `segments_parsed_at` and
              // `segments_parser_version` are untouched: a re-walk must not make a filing look
              // unread.
              const { error } = await market.from('security_filing').upsert(
                dedupeBy(rows, (r) => `${r.security_id}|${r.accession_number}`),
                { onConflict: 'security_id,accession_number' },
              )
              if (error) throw new Error(`security_filing upsert failed: ${error.message}`)
              written += rows.length
            }
          }

          const { error: fErr } = await market.from('security_filer').upsert(
            [{
              security_id: item.security_id,
              source_code: 'cninfo',
              filer_id: orgId ?? code,
              history_walked_at: new Date().toISOString(),
            }],
            { onConflict: 'security_id,source_code' },
          )
          if (fErr) throw new Error(`security_filer upsert failed: ${fErr.message}`)
        } catch (e) {
          failed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          if (firstError === null) firstError = msg
          lastError = msg
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        walked,
        written,
        noOrgId,
        failed,
        remaining: await backlogSize(market, 'pending_cn_filings'),
        first_error: firstError,
        last_error: lastError,
      })
    }

    // ── India: parse ────────────────────────────────────────────────────────────────────────────
    //
    // The same shape as the Korean parser, with ONE addition: `nse.normalise` rewrites the instance
    // before `segmentFactsFrom` sees it. India's members are anonymous positional slots whose names
    // live in a sibling fact, and its period is not in the context dates at all — see `in.ts`.
    // Everything after the normalise call is deliberately identical to the SEC and DART paths,
    // including the per-accession retraction, because three writers to one table must not disagree
    // about how it is written.
    if (resource === IN_SEGMENTS_RESOURCE) {
      const deadline = Date.now() + 78_000

      const { data: axisRows, error: aErr } = await market
        .from('segment_axis').select('taxonomy,axis,kind,priority,required_member')
      if (aErr) throw new Error(`segment_axis read failed: ${aErr.message}`)
      const { data: exclRows, error: xErr } = await market
        .from('segment_member_class').select('member_code,class')
      if (xErr) throw new Error(`segment_member_class read failed: ${xErr.message}`)
      const memberRoles = (exclRows ?? []).map((r) => ({
        memberCode: String(r.member_code), class: String(r.class),
      }))
      const axes: SegmentAxisSpec[] = (axisRows ?? []).map((r) => ({
        axis: String(r.axis),
        kind: String(r.kind) as SegmentAxisSpec['kind'],
        priority: Number(r.priority),
        requiredMember: r.required_member === null || r.required_member === undefined
          ? null : String(r.required_member),
      }))
      const { data: conceptRows, error: cErr } = await market
        .from('xbrl_concept').select('metric_code,concept,priority').in('metric_code', SEGMENT_METRICS)
      if (cErr) throw new Error(`xbrl_concept read failed: ${cErr.message}`)
      const concepts: SegmentConceptSpec[] = (conceptRows ?? []).map((r) => ({
        metricCode: String(r.metric_code), concept: String(r.concept), priority: Number(r.priority),
      }))
      if (concepts.length === 0) throw new Error('no segment concepts — xbrl_concept has no revenue rows')

      const { data: verRows, error: vErr } = await market
        .from('segment_parser').select('version').limit(1)
      if (vErr) throw new Error(`segment_parser read failed: ${vErr.message}`)
      const parserVersion = Number(verRows?.[0]?.version ?? 1)

      const { data: pending, error: pErr } = await market
        .from('pending_in_segments')
        .select('security_id,accession_number,report_type,filing_date')
        .limit(scopeLimit ?? 8)
      if (pErr) throw new Error(`pending_in_segments read failed: ${pErr.message}`)

      let written = 0
      let filings = 0
      let noInstance = 0
      let noSegments = 0
      let standalone = 0
      let failed = 0
      let firstError: string | null = null
      let lastError: string | null = null

      for (const item of pending ?? []) {
        if (Date.now() > deadline - 15_000) break
        try {
          const raw = await nse.fetchInstance(
            String(item.accession_number), Math.max(10_000, deadline - Date.now() - 10_000),
          )
          filings++
          if (raw === null) { noInstance++ } else {
            const norm = nse.normalise(raw)
            if (norm === nse.NOT_CONSOLIDATED) {
              // NOT A FAILURE. Every company files twice and we want one of them; counting the
              // standalone as an error would make this resource look broken on a healthy run.
              standalone++
            } else {
              const facts = segmentFactsFrom(norm.xml, axes, concepts, memberRoles)
              if (facts.length === 0) noSegments++

              // Only when the document was actually READ — the same rule as the SEC and DART
              // paths, for the same reason: a fetch that answered nothing is not the filing
              // saying it discloses nothing.
              const { error: rtErr } = await market.from('security_segment').delete()
                .eq('security_id', item.security_id).eq('accession_number', item.accession_number)
              if (rtErr) throw new Error(`security_segment retract failed: ${rtErr.message}`)

              if (facts.length > 0) {
                const rows = facts.map((f) => ({
                  security_id: item.security_id,
                  accession_number: item.accession_number,
                  axis: f.axis, member_code: f.memberCode,
                  parent_axis: f.parentAxis, parent_member: f.parentMember,
                  metric_code: f.metricCode, period_type: f.periodType,
                  period_start: f.periodStart, period_ending: f.periodEnding,
                  value: f.value, currency_code: f.currency,
                  partition_id: f.partitionId, reconciled_to: f.reconciledTo,
                  source_code: 'nse',
                }))
                for (let i = 0; i < rows.length; i += 500) {
                  const { error } = await market.from('security_segment').upsert(
                    dedupeBy(rows.slice(i, i + 500),
                      (r) => `${r.security_id}|${r.axis}|${r.member_code}|${r.parent_member ?? ''}|` +
                        `${r.metric_code}|${r.period_type}|${r.period_ending}`),
                    { onConflict: 'security_id,axis,member_code,parent_key,metric_code,period_type,period_ending' },
                  )
                  if (error) throw new Error(`security_segment upsert failed: ${error.message}`)
                }
                written += rows.length
              }
            }
          }

          // Stamped whether or not it yielded segments — a filed document is immutable, so "this
          // one discloses none" is permanent. A throw never reaches here, so an outage re-queues.
          const { error: tErr } = await market.from('security_filing').update({
            segments_parsed_at: new Date().toISOString(),
            segments_parser_version: parserVersion,
          }).eq('security_id', item.security_id).eq('accession_number', item.accession_number)
          if (tErr) throw new Error(`segments_parsed_at update failed: ${tErr.message}`)
        } catch (e) {
          failed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          if (firstError === null) firstError = msg
          lastError = msg
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        filings,
        written,
        noInstance,
        noSegments,
        standalone,
        failed,
        remaining: await backlogSize(market, 'pending_in_segments'),
        first_error: firstError,
        last_error: lastError,
      })
    }

    // ── China: segments out of the annual-report PDF ────────────────────────────────────────────
    //
    // The CSRC mandates `主营业务分行业/分产品/分地区情况` in every A-share annual report, so this
    // reads a standard form rather than scraping each filer. Everything after the parse is the same
    // machinery the XBRL paths use — `assignPartitions`, the per-accession retraction, the dedupe
    // and the upsert — because `cn-pdf.ts` produces `SegmentFact[]` and nothing downstream knows or
    // cares that the source was a PDF.
    if (resource === CN_SEGMENTS_RESOURCE) {
      const deadline = Date.now() + 70_000
      const { data: pending, error: pErr } = await market
        .from('pending_cn_segments')
        .select('security_id,accession_number,report_url')
        // A PAGE OF ONE, FOR THE REASON `security-kr-segments` USES ONE: the cost is per DOCUMENT
        // and it is MEMORY, not time. `cn-pdf.ts` records 298 ms and 124 MB for a single report
        // against a 256 MB worker, so a page of six cannot fit however fast it runs -- and a
        // killed worker writes no `refresh_run` row, so nothing is stamped and the same six return
        // at the head for ever. Measured 2026-09-09: not one run has finished since 2026-09-07
        // 17:05, while `refresh_log` still shows a claim opened and never closed.
        //
        // The obvious suspect was the size gate, and it is NOT the cause: the three documents at
        // the head are 9.6 MB, 1.5 MB and 1.4 MB against a 24 MB limit, so every one is admitted
        // and lowering the limit would have changed nothing.
        .limit(scopeLimit ?? 1)
      if (pErr) throw new Error(`pending_cn_segments read failed: ${pErr.message}`)

      const { data: pv, error: vErr } = await market.from('segment_parser').select('version').single()
      if (vErr) throw new Error(`segment_parser read failed: ${vErr.message}`)
      const parserVersion = Number((pv as { version?: unknown } | null)?.version ?? 0)

      let filings = 0
      let written = 0
      let noTable = 0
      let noReport = 0
      let tooLarge = 0
      let failed = 0
      let firstError: string | null = null
      let lastError: string | null = null

      for (const item of pending ?? []) {
        // A 1-6 MB download plus a parse; leaving less than this invites a killed worker, and a
        // killed worker stamps nothing and returns the same filing at the head for ever.
        if (Date.now() > deadline - 20_000) break
        try {
          const bytes = await cnPdf.fetchReport(
            String(item.report_url), Math.min(45_000, deadline - Date.now() - 10_000),
          )
          filings++
          if (bytes === cnPdf.TOO_LARGE) {
            // A REFUSAL AND AN ABSENCE ARE DIFFERENT FACTS. Counted separately so an oversized
            // document is visible rather than looking like a company that discloses nothing.
            tooLarge++
          } else if (bytes === null) {
            noReport++
          } else {
            const parsed = await cnPdf.segmentFactsFromPdf(bytes)
            if (parsed.facts.length === 0) noTable++

            // Only when the document was actually READ — the same rule as the SEC, DART and NSE
            // paths. A fetch that answered nothing is not the filing saying it discloses nothing.
            const { error: rtErr } = await market.from('security_segment').delete()
              .eq('security_id', item.security_id).eq('accession_number', item.accession_number)
            if (rtErr) throw new Error(`security_segment retract failed: ${rtErr.message}`)

            if (parsed.facts.length > 0) {
              const rows = parsed.facts.map((f) => ({
                security_id: item.security_id,
                accession_number: item.accession_number,
                axis: f.axis, member_code: f.memberCode,
                parent_axis: f.parentAxis, parent_member: f.parentMember,
                metric_code: f.metricCode, period_type: f.periodType,
                period_start: f.periodStart, period_ending: f.periodEnding,
                value: f.value, currency_code: f.currency,
                partition_id: f.partitionId, reconciled_to: f.reconciledTo,
                source_code: 'cninfo',
              }))
              for (let i = 0; i < rows.length; i += 500) {
                const { error } = await market.from('security_segment').upsert(
                  dedupeBy(rows.slice(i, i + 500),
                    (r) => `${r.security_id}|${r.axis}|${r.member_code}|${r.parent_member ?? ''}|` +
                      `${r.metric_code}|${r.period_type}|${r.period_ending}`),
                  { onConflict: 'security_id,axis,member_code,parent_key,metric_code,period_type,period_ending' },
                )
                if (error) throw new Error(`security_segment upsert failed: ${error.message}`)
              }
              written += rows.length
            }
          }

          // Stamped whether or not it yielded segments — a filed document is immutable, so "this
          // one discloses none" is permanent. A throw never reaches here, so an outage re-queues.
          // An OVERSIZED document is stamped too: refusing it is a settled fact about that file,
          // and not stamping it is what made one 127 MB filing block `security-segments` for two
          // days.
          const { error: tErr } = await market.from('security_filing').update({
            segments_parsed_at: new Date().toISOString(),
            segments_parser_version: parserVersion,
          }).eq('security_id', item.security_id).eq('accession_number', item.accession_number)
          if (tErr) throw new Error(`segments_parsed_at update failed: ${tErr.message}`)
        } catch (e) {
          failed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          if (firstError === null) firstError = msg
          lastError = msg
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        filings,
        written,
        noTable,
        noReport,
        tooLarge,
        failed,
        remaining: await backlogSize(market, 'pending_cn_segments'),
        first_error: firstError,
        last_error: lastError,
      })
    }

    // ── India: discovery ────────────────────────────────────────────────────────────────────────
    //
    // A CURSOR, NOT A NEGATIVE CACHE, for the reason `security_filer.history_walked_at` exists for
    // Korea: Indian companies keep filing, so "we have walked this company" is true for a season
    // and never permanently. And an ANTI-JOIN, not an ordering — read straight from the security
    // list with a `limit`, this would return the same companies for ever, which is the defect
    // `pending_industry` ran with for months.
    if (resource === IN_FILINGS_RESOURCE) {
      const deadline = Date.now() + 70_000

      // Indian equities whose NSE symbol we hold and whose history has not been walked recently.
      // The symbol is `market.listing.symbol` (RELIANCE, HDFCBANK), which is already populated —
      // NOT the `security_identifier` ticker, which is OpenFIGI's US lookup and for a foreign
      // company is a thin OTC line.
      const { data: pending, error: pErr } = await market
        .from('pending_in_history')
        .select('security_id,symbol')
        .limit(scopeLimit ?? 6)
      if (pErr) throw new Error(`pending_in_history read failed: ${pErr.message}`)

      let mapped = 0
      let filingsWritten = 0
      let walked = 0
      let failed = 0
      let firstError: string | null = null
      let lastError: string | null = null

      for (const item of pending ?? []) {
        if (Date.now() > deadline - 15_000) break
        const symbol = String(item.symbol)
        try {
          const listed = await nse.listFilings(symbol, Math.min(25_000, deadline - Date.now()))
          walked++
          if (listed.length > 0) {
            const { error: fErr } = await market.from('security_filer').upsert(
              [{ security_id: item.security_id, source_code: 'nse', filer_id: symbol }],
              { onConflict: 'security_id,source_code' },
            )
            if (fErr) throw new Error(`security_filer upsert failed: ${fErr.message}`)
            mapped++

            // The accession is NSE's own document URL — it is what `fetchInstance` needs, and
            // `(source_code, accession_number)` is already the key, so only the NAME is
            // SEC-specific. Carried in `report_url` too, so a reader can open the filing.
            const rows = listed.map((f) => ({
              security_id: item.security_id,
              accession_number: f.xbrlUrl,
              report_type: IN_ANNUAL_FORM,
              report_date: nse.isoFromNseDate(f.toDate),
              report_url: f.xbrlUrl,
              source_code: 'nse',
              is_xbrl: true,
            }))
            const { error: gErr } = await market.from('security_filing').upsert(
              dedupeBy(rows, (r) => `${r.security_id}|${r.accession_number}`),
              { onConflict: 'security_id,accession_number', ignoreDuplicates: true },
            )
            if (gErr) throw new Error(`security_filing upsert failed: ${gErr.message}`)
            filingsWritten += rows.length
          }

          // Stamped whether or not it listed anything: a company that files nothing NSE indexes is
          // a fact for this season. A throw never reaches here, so an outage re-queues rather than
          // marking the company walked — the same rule `insider_fetched_at` follows.
          const walkedAt = new Date().toISOString()
          const { data: stamped, error: tErr } = await market.from('security_filer')
            .update({ history_walked_at: walkedAt })
            .eq('security_id', item.security_id).eq('source_code', 'nse')
            .select('security_id')
          if (tErr) throw new Error(`history_walked_at update failed: ${tErr.message}`)
          // AN UPDATE THAT MATCHES NO ROW IS NOT AN ERROR, AND THAT KEPT SIX COMPANIES AT THE HEAD
          // OF THIS QUEUE FOR TWO WEEKS. The filer row above is created only when NSE lists
          // something, so a company asked under its listing symbol that NSE lists nothing for had
          // no row to stamp: `walked: 6, mapped: 0, failed: 0` every 15 minutes from at least
          // 2026-10-06, five REITs/InvITs and TD Power ahead of 289 companies never reached. The
          // walk is recorded on the security instead. Not by inserting a filer row: that row means
          // NSE lists the company, and the coverage model counts it as `held`.
          if ((stamped ?? []).length === 0) {
            const { error: sErr } = await market.from('security')
              .update({ nse_history_walked_at: walkedAt })
              .eq('security_id', item.security_id)
            if (sErr) throw new Error(`nse_history_walked_at update failed: ${sErr.message}`)
          }
        } catch (e) {
          failed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          if (firstError === null) firstError = msg
          lastError = msg
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        walked,
        mapped,
        written: filingsWritten,
        failed,
        // THE BACKLOG'S OWN SIZE, not page arithmetic. Nine resources once reported `remaining: 0`
        // against a queue of 9,013 because they subtracted what the page covered.
        remaining: await backlogSize(market, 'pending_in_history'),
        first_error: firstError,
        last_error: lastError,
      })
    }

    if (resource === KR_SEGMENTS_RESOURCE) {
      const deadline = Date.now() + 78_000

      const { data: axisRows, error: aErr } = await market
        .from('segment_axis').select('taxonomy,axis,kind,priority,required_member')
      if (aErr) throw new Error(`segment_axis read failed: ${aErr.message}`)
      // WHICH MEMBERS CANNOT BE A BUSINESS LINE, and in which of the two ways. Read here rather
      // than hardcoded: they are standard taxonomy members, more will turn up, and adding one must
      // not need a deploy. A control table nothing reads is decoration.
      const { data: exclRows, error: xErr } = await market
        .from('segment_member_class').select('member_code,class')
      if (xErr) throw new Error(`segment_member_class read failed: ${xErr.message}`)
      const memberRoles = (exclRows ?? []).map((r) => ({ memberCode: String(r.member_code), class: String(r.class) }))
      const axes: SegmentAxisSpec[] = (axisRows ?? []).map((r) => ({
        axis: String(r.axis),
        kind: String(r.kind) as SegmentAxisSpec['kind'],
        priority: Number(r.priority),
        requiredMember: r.required_member === null || r.required_member === undefined
          ? null : String(r.required_member),
      }))
      const { data: conceptRows, error: cErr } = await market
        .from('xbrl_concept').select('metric_code,concept,priority').in('metric_code', SEGMENT_METRICS)
      if (cErr) throw new Error(`xbrl_concept read failed: ${cErr.message}`)
      const concepts: SegmentConceptSpec[] = (conceptRows ?? []).map((r) => ({
        metricCode: String(r.metric_code), concept: String(r.concept), priority: Number(r.priority),
      }))
      if (concepts.length === 0) throw new Error('no segment concepts — xbrl_concept has no revenue rows')

      const { data: verRows, error: vErr } = await market
        .from('segment_parser').select('version').limit(1)
      if (vErr) throw new Error(`segment_parser read failed: ${vErr.message}`)
      const parserVersion = Number(verRows?.[0]?.version ?? 1)

      const { data: pending, error: pErr } = await market
        .from('pending_kr_segments')
        .select('security_id,accession_number,report_type,filing_date')
        // FOUR, NOT ONE — because a WARM filing costs ~4 s and a cold one costs the whole budget.
        // The loop is bounded by the deadline either way, so this cannot overrun: a page of cold
        // filings still warms exactly one and stops. What it buys is that a run which finds
        // filings already cached (the previous run's warm-ups, or a re-parse after a
        // `segment_parser.version` bump, where every instance is already stored) drains them
        // together instead of one per five minutes.
        .limit(scopeLimit ?? 4)
      if (pErr) throw new Error(`pending_kr_segments read failed: ${pErr.message}`)

      let written = 0
      let filings = 0
      let noInstance = 0
      let noSegments = 0
      let tooLarge = 0
      let failed = 0
      let warmed = 0
      let firstError: string | null = null
      let lastError: string | null = null

      for (const item of pending ?? []) {
        if (Date.now() > deadline - 20_000) break
        try {
          const xml = await dart.fetchInstance(
            String(item.accession_number), Math.max(10_000, deadline - Date.now() - 12_000),
          )
          const oversize = xml === dart.TOO_LARGE
          const facts = typeof xml === 'string' ? segmentFactsFrom(xml, axes, concepts, memberRoles) : []
          filings++
          if (oversize) tooLarge++
          else if (xml === null) noInstance++
          else if (facts.length === 0) noSegments++


          // A PARSER RULE THAT STOPS EMITTING A FACT CAN NEVER RETRACT IT — an upsert only ever
          // writes. `partition_id` demotions self-heal (the member is still emitted, at 0, and
          // overwrites its own row), but a member the parser now DROPS is never seen again, so its
          // last row survives for ever, in a served partition, looking freshly written. Measured
          // 2026-09-05 the moment the subtotal rule shipped: 33 rows of
          // `ReportableSegmentAggregationBeforeOtherOperatingSegmentMember` and 8 of
          // `OperatingSegmentsMember` sat in partition 1 — a subtotal counted beside its own
          // children, which is the double count the rule exists to prevent.
          //
          // Retracting per ACCESSION is what makes it exact: these rows are this filing's own
          // statement of itself, so a re-read replaces them wholesale. It is not keyed on the
          // upsert's conflict target, which omits the accession deliberately — a newer filing
          // restating a period takes ownership of the row, and deleting by accession then correctly
          // leaves it alone.
          //
          // ONLY WHEN THE DOCUMENT WAS ACTUALLY READ. `facts` is empty for FOUR different reasons
          // and only one of them is "this filing discloses no segments": the index lookup can
          // return nothing, the fetch can return null, and the size gate can refuse the document —
          // none of which is evidence about what the filing says. The first version of this
          // retraction ran unconditionally and its comment claimed "a fetch that THREW never
          // reaches here, so an outage retracts nothing", which is true of a THROW and false of a
          // null: 281 filings took this path in the three hours it was live (275 noInstance, 6
          // tooLarge) and `security_segment` fell by 91 rows while the drain was actively adding.
          // A REQUEST THAT FAILED AND A REQUEST THAT ANSWERED NOTHING ARE DIFFERENT FACTS — the
          // seventh instance of that shape in this pipeline, introduced by me while fixing a
          // different one. A parsed document with no segments still retracts, because that IS the
          // filing speaking.
          if (typeof xml === 'string' && !oversize) {
            const { error: rtErr } = await market.from('security_segment').delete()
              .eq('security_id', item.security_id).eq('accession_number', item.accession_number)
            if (rtErr) throw new Error(`security_segment retract failed: ${rtErr.message}`)
          }

          if (facts.length > 0) {
            const rows = facts.map((f) => ({
              security_id: item.security_id,
              accession_number: item.accession_number,
              axis: f.axis, member_code: f.memberCode,
              parent_axis: f.parentAxis, parent_member: f.parentMember,
              metric_code: f.metricCode, period_type: f.periodType,
              period_start: f.periodStart, period_ending: f.periodEnding,
              value: f.value, currency_code: f.currency,
              partition_id: f.partitionId, reconciled_to: f.reconciledTo,
              source_code: 'dart',
            }))
            for (let i = 0; i < rows.length; i += 500) {
              const { error } = await market.from('security_segment').upsert(
                dedupeBy(rows.slice(i, i + 500),
                  (r) => `${r.security_id}|${r.axis}|${r.member_code}|${r.parent_member ?? ''}|` +
                    `${r.metric_code}|${r.period_type}|${r.period_ending}`),
                // `parent_key` IS PART OF THE KEY, and omitting it does not merely mis-dedupe —
                // it names a constraint that does not exist, so the upsert fails outright with
                // `no unique or exclusion constraint matching the ON CONFLICT specification`. It
                // is a STORED GENERATED column (`coalesce(parent_member, '')`) because a primary
                // key admits no NULLs and the flat case must keep working. Same target as the SEC
                // path, deliberately — two writers to one table must not disagree about its key.
                { onConflict: 'security_id,axis,member_code,parent_key,metric_code,period_type,period_ending' },
              )
              if (error) throw new Error(`security_segment upsert failed: ${error.message}`)
            }
            written += rows.length
          }

          // Stamped whether or not it had segments — "this filing discloses none" is a permanent
          // fact about an immutable document. A fetch that THREW never reaches here, so an outage
          // or a timeout re-queues the filing rather than marking it read.
          const { error: tErr } = await market.from('security_filing').update({
            segments_parsed_at: new Date().toISOString(),
            segments_parser_version: parserVersion,
          }).eq('security_id', item.security_id).eq('accession_number', item.accession_number)
          if (tErr) throw new Error(`segments_parsed_at update failed: ${tErr.message}`)
        } catch (e) {
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          // A DEADLINE ABORT ON A COLD FILING IS A WARM-UP, NOT A FAILURE — and calling it one
          // would make this resource report a failure on every other run for ever.
          //
          // Measured in production 2026-09-05: a cold filing takes 73.9 s through the cache
          // (802,368 bytes for Samsung, 982,619 for the queue head) against a fetch budget of
          // ~66 s, so the FIRST attempt at any filing always aborts. `proxy_ignore_client_abort on`
          // means nginx keeps reading and stores the response anyway — verified, the next request
          // for the same filing is a HIT in 1.6 ms — so that run did the useful half of the work
          // and the next run parses it in ~4 s.
          //
          // Counting it as `failed` would put a permanent error on a healthy resource, which is
          // how an alert becomes one nobody reads. It is reported as `warmed`, and it deliberately
          // does NOT set lastError: the run succeeded at what it could do in the time.
          if (e instanceof Error && /aborted|AbortError/i.test(msg)) {
            warmed++
          } else {
            failed++
            if (firstError === null) firstError = msg
            lastError = msg
          }
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource, written, filings, warmed, noInstance, noSegments, tooLarge, failed,
        firstError, lastError,
        remaining: await backlogSize(market, 'pending_kr_segments'),
      })
    }

    if (resource === SEGMENTS_RESOURCE) {
      const deadline = Date.now() + 60_000

      const { data: axisRows, error: aErr } = await market
        .from('segment_axis')
        .select('taxonomy,axis,kind,priority,required_member')
      if (aErr) throw new Error(`segment_axis read failed: ${aErr.message}`)
      // The same subtotal list the SEC handler reads — one control table, both regulators.
      const { data: exclRows2, error: xErr2 } = await market
        .from('segment_member_class').select('member_code,class')
      if (xErr2) throw new Error(`segment_member_class read failed: ${xErr2.message}`)
      const memberRoles = (exclRows2 ?? []).map((r) => ({ memberCode: String(r.member_code), class: String(r.class) }))
      const axes: SegmentAxisSpec[] = (axisRows ?? []).map((r) => ({
        axis: String(r.axis),
        kind: String(r.kind) as SegmentAxisSpec['kind'],
        priority: Number(r.priority),
        // Pins the member a qualifier must carry — Korea's consolidated-versus-separate axis.
        requiredMember: r.required_member === null || r.required_member === undefined
          ? null
          : String(r.required_member),
      }))
      if (axes.length === 0) throw new Error('segment_axis is empty — every filing would yield nothing')

      // REUSED, NOT DUPLICATED. `xbrl_concept` already records which concepts express which metric
      // for both us-gaap and ifrs-full — the same catalogue `security-xbrl` drives. A second list
      // here would be the same fact in two places, which this schema has already watched drift.
      const { data: conceptRows, error: cErr } = await market
        .from('xbrl_concept')
        .select('metric_code,concept,priority')
        .in('metric_code', SEGMENT_METRICS)
      if (cErr) throw new Error(`xbrl_concept read failed: ${cErr.message}`)
      const concepts: SegmentConceptSpec[] = (conceptRows ?? []).map((r) => ({
        metricCode: String(r.metric_code),
        concept: String(r.concept),
        priority: Number(r.priority),
      }))
      if (concepts.length === 0) throw new Error('no segment concepts — xbrl_concept has no revenue rows')

      const { data: verRows, error: vErr } = await market
        .from('segment_parser').select('version').limit(1)
      if (vErr) throw new Error(`segment_parser read failed: ${vErr.message}`)
      const parserVersion = Number(verRows?.[0]?.version ?? 1)

      const { data: pending, error: pErr } = await market
        .from('pending_segments')
        .select('security_id,accession_number,cik,report_type')
        .limit(scopeLimit ?? SEGMENTS_PAGE)
      if (pErr) throw new Error(`pending_segments read failed: ${pErr.message}`)

      const wanted = (pending ?? []).map((r) => ({
        securityId: String(r.security_id),
        accession: String(r.accession_number),
        cik: Number(r.cik),
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'every filing has been read' })
      }

      let written = 0
      let filings = 0
      let noInstance = 0
      let noSegments = 0
      let tooLarge = 0
      let failed = 0
      let firstError: string | null = null
      let lastError: string | null = null

      for (const item of wanted) {
        // ONE AT A TIME AND BOUNDED, for the reason `security-xbrl` records: several multi-megabyte
        // documents held at once in a 256 MB worker is how a resource dies with a bare 502 rather
        // than an error anyone can read.
        if (Date.now() > deadline - 8_000) break
        try {
          const ref = await findInstanceUrl(item.cik, item.accession, Math.min(15_000, deadline - Date.now()))
          // REFUSED BEFORE IT IS FETCHED, from the size `index.json` already told us. A 128 MB
          // instance is ~256 MB as a UTF-16 string against a 256 MB worker, and the worker does not
          // throw — it is KILLED, so nothing is stamped and the same filing returns at the head of
          // every run. That wedged this resource for two days. See MAX_INSTANCE_BYTES.
          const refused = ref !== null && instanceIsTooLarge(ref.bytes)
          const fetched = ref === null || refused
            ? null
            : await fetchInstance(ref.url, Math.min(25_000, deadline - Date.now()))
          // The second gate, for the HTML-index path where no size was known up front.
          const oversize = refused || fetched === TOO_LARGE
          const xml = typeof fetched === 'string' ? fetched : null
          const facts = xml === null ? [] : segmentFactsFrom(xml, axes, concepts, memberRoles)
          filings++
          // THREE OUTCOMES, NOT TWO. "no XBRL to read", "too large to read" and "read, no segments"
          // are different facts; counting a refusal as an absence is how this pipeline has twice
          // mistaken a decision of its own for a property of the data.
          if (oversize) tooLarge++
          else if (ref === null || xml === null) noInstance++
          else if (facts.length === 0) noSegments++


          // A PARSER RULE THAT STOPS EMITTING A FACT CAN NEVER RETRACT IT — an upsert only ever
          // writes. `partition_id` demotions self-heal (the member is still emitted, at 0, and
          // overwrites its own row), but a member the parser now DROPS is never seen again, so its
          // last row survives for ever, in a served partition, looking freshly written. Measured
          // 2026-09-05 the moment the subtotal rule shipped: 33 rows of
          // `ReportableSegmentAggregationBeforeOtherOperatingSegmentMember` and 8 of
          // `OperatingSegmentsMember` sat in partition 1 — a subtotal counted beside its own
          // children, which is the double count the rule exists to prevent.
          //
          // Retracting per ACCESSION is what makes it exact: these rows are this filing's own
          // statement of itself, so a re-read replaces them wholesale. It is not keyed on the
          // upsert's conflict target, which omits the accession deliberately — a newer filing
          // restating a period takes ownership of the row, and deleting by accession then correctly
          // leaves it alone.
          //
          // ONLY WHEN THE DOCUMENT WAS ACTUALLY READ. `facts` is empty for FOUR different reasons
          // and only one of them is "this filing discloses no segments": the index lookup can
          // return nothing, the fetch can return null, and the size gate can refuse the document —
          // none of which is evidence about what the filing says. The first version of this
          // retraction ran unconditionally and its comment claimed "a fetch that THREW never
          // reaches here, so an outage retracts nothing", which is true of a THROW and false of a
          // null: 281 filings took this path in the three hours it was live (275 noInstance, 6
          // tooLarge) and `security_segment` fell by 91 rows while the drain was actively adding.
          // A REQUEST THAT FAILED AND A REQUEST THAT ANSWERED NOTHING ARE DIFFERENT FACTS — the
          // seventh instance of that shape in this pipeline, introduced by me while fixing a
          // different one. A parsed document with no segments still retracts, because that IS the
          // filing speaking.
          if (xml !== null && !oversize) {
            const { error: rtErr } = await market.from('security_segment').delete()
              .eq('security_id', item.securityId).eq('accession_number', item.accession)
            if (rtErr) throw new Error(`security_segment retract failed: ${rtErr.message}`)
          }

          if (facts.length > 0) {
            const rows = facts.map((f) => ({
              security_id: item.securityId,
              axis: f.axis,
              member_code: f.memberCode,
              metric_code: f.metricCode,
              period_type: f.periodType,
              period_ending: f.periodEnding,
              period_start: f.periodStart,
              value: f.value,
              currency_code: f.currency,
              partition_id: f.partitionId,
              // NULL for an ordinary flat member; set when a filing nests one segmentation inside
              // another (Alphabet's Search WITHIN Google Services). A nested row's siblings sum to
              // the PARENT, not the company, so the two levels are served by two views.
              parent_axis: f.parentAxis,
              parent_member: f.parentMember,
              // What this split was accepted against, so a guard can check it WITHOUT a second
              // source. Comparing to `security_metric` compares two independently derived totals
              // and reported five false failures on the first day.
              reconciled_to: f.reconciledTo,
              accession_number: item.accession,
              source_code: 'sec-segments',
              as_of: new Date().toISOString(),
            }))
            // LEARN THE CURRENCY FIRST, exactly as the XBRL resource does. `currency_code` is a
            // foreign key and a foreign private issuer reports in its own currency, so a code the
            // table has never seen fails the STATEMENT and takes the whole filing with it.
            const curs = [...new Set(rows.map((r) => r.currency_code).filter(Boolean))] as string[]
            if (curs.length > 0) {
              const { error: cuErr } = await market.from('currency')
                .upsert(curs.map((code) => ({ code })), { onConflict: 'code', ignoreDuplicates: true })
              if (cuErr) throw new Error(`currency learn failed: ${cuErr.message}`)
            }
            for (let i = 0; i < rows.length; i += 500) {
              const { error } = await market
                .from('security_segment')
                .upsert(
                  // THE DEDUPE KEY CARRIES `period_type`, and so does the conflict target. A
                  // fiscal-year end is both an annual period and a Q4 one; a key without it drops
                  // the annual row as a duplicate of the quarterly one BEFORE the upsert ever sees
                  // it, and the figure is then wrong by 4x with an identical row count.
                  dedupeBy(rows.slice(i, i + 500),
                    (r) => `${r.security_id}|${r.axis}|${r.member_code}|${r.parent_member ?? ''}|` +
                      `${r.metric_code}|${r.period_type}|${r.period_ending}`),
                  // `parent_key` is a STORED GENERATED column — `coalesce(parent_member, '')` —
                  // because a primary key admits no NULLs and the flat case must keep working. The
                  // dedupe key above mirrors it exactly, or a nested cell and a flat member of the
                  // same axis collapse before the upsert ever sees them.
                  { onConflict: 'security_id,axis,member_code,parent_key,metric_code,period_type,period_ending' },
                )
              if (error) throw new Error(`security_segment upsert failed: ${error.message}`)
            }
            written += rows.length
          }

          // STAMPED ONLY AFTER SEC ANSWERED, and stamped whether or not it had segments — "this
          // filing discloses none" is a permanent fact about an immutable document, which is why
          // this is a cursor rather than a `%_missing_at` with an expiry. A fetch that THREW never
          // reaches here, so an outage re-queues the filing instead of marking it read.
          const { error: tErr } = await market
            .from('security_filing')
            .update({
              segments_parsed_at: new Date().toISOString(),
              segments_parser_version: parserVersion,
            })
            .eq('security_id', item.securityId)
            .eq('accession_number', item.accession)
          if (tErr) throw new Error(`segments_parsed_at update failed: ${tErr.message}`)
        } catch (e) {
          failed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          // BOTH ENDS OF THE RUN. A rate limit at call two otherwise overwrites the real failure at
          // call one, which cost a whole diagnosis on `security-eps-history`.
          if (firstError === null) firstError = msg
          lastError = msg
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource, written, filings, noInstance, noSegments, tooLarge, failed, firstError, lastError,
        remaining: await backlogSize(market, 'pending_segments'),
      })
    }

    if (resource === EARNINGS_HISTORY_RESOURCE) {
      // ACTUAL-VERSUS-ESTIMATE, FROM THE ENDPOINT WE ALREADY CALL.
      //
      // `security-eps-history` bought this from alpha_vantage at 25 calls a DAY, one symbol per
      // call, and reached 79 securities in weeks. The forward earnings calendar had the same data
      // all along and nobody had asked it for a PAST range: measured 2026-08-28, one 3-day window
      // returns 643 companies WITH `eps_actual`, `eps_consensus` and `surprise_percent`, and 2018
      // answers as readily as 2024. That resource is retired (migration 138).
      //
      // A SWEEP, NOT A BACKLOG. There is no entity to ask about — the resource walks a calendar
      // backwards — so what it remembers is a POSITION, not a negative cache.
      const deadline = Date.now() + 60_000
      const CHUNK_DAYS = 3

      const { data: cur, error: cErr } = await market
        .from('earnings_history_cursor')
        .select('walked_to,stop_at')
        .limit(1)
        .maybeSingle()
      if (cErr) throw new Error(`earnings_history_cursor read failed: ${cErr.message}`)
      let walkedTo = new Date(String(cur?.walked_to ?? new Date().toISOString().slice(0, 10)))
      const stopAt = new Date(String(cur?.stop_at ?? '2015-01-01'))

      if (walkedTo <= stopAt) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'the sweep has reached its floor' })
      }

      // The same resolver the forward calendar uses, and for the same reason: loading
      // `symbol_security` whole silently returns a twelfth of it under PGRST_DB_MAX_ROWS, which
      // once matched 22 of 753 rows while reading like a fact about coverage.
      const idBySymbol = new Map<string, string>()
      const resolve = async (symbols: string[]) => {
        const unknown = [...new Set(symbols)].filter((sym) => !idBySymbol.has(sym))
        for (let i = 0; i < unknown.length; i += 100) {
          const chunk = unknown.slice(i, i + 100)
          const { data, error } = await market
            .from('symbol_security')
            .select('symbol,security_id')
            .in('symbol', chunk)
          if (error) throw new Error(`symbol_security read failed: ${error.message}`)
          for (const r of data ?? []) idBySymbol.set(String(r.symbol).toUpperCase(), r.security_id as string)
          for (const sym of chunk) if (!idBySymbol.has(sym)) idBySymbol.set(sym, '')
        }
      }

      const iso = (d: Date) => d.toISOString().slice(0, 10)
      let fetched = 0, written = 0, matched = 0, windows = 0, failed = 0
      let lastError: string | null = null

      while (walkedTo > stopAt && Date.now() < deadline - TAIL_RESERVE_MS) {
        const end = new Date(walkedTo)
        const start = new Date(end.getTime() - (CHUNK_DAYS - 1) * 86_400_000)
        windows++
        let rows: Record<string, unknown>[] = []
        try {
          // THREE DAYS, NOT FIVE. A five-day window times out on this endpoint — the chunk size is
          // part of the contract rather than a tuning knob.
          rows = await fetcher(
            `/api/v1/equity/calendar/earnings?provider=nasdaq` +
              `&start_date=${iso(start)}&end_date=${iso(end)}`,
            Math.min(30_000, deadline - Date.now()),
          )
        } catch (e) {
          failed++
          const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          lastError = msg
          if (throttled(msg)) break
          // THE CURSOR IS NOT ADVANCED ON A FAILURE. A window we could not read must be re-read,
          // or a thirty-second provider blip costs three days of history permanently — the same
          // rule `security-insider`'s cursor follows.
          break
        }
        fetched += rows.length

        // Only rows that actually REPORTED carry a surprise; the rest are scheduled dates the
        // forward calendar already owns.
        const reported = rows.filter((r) => r.eps_actual !== null && r.eps_actual !== undefined)
        await resolve(reported.map((r) => String(r.symbol ?? '').toUpperCase()))

        const out: Record<string, unknown>[] = []
        for (const r of reported) {
          const sid = idBySymbol.get(String(r.symbol ?? '').toUpperCase())
          if (!sid) continue
          const actual = Number(r.eps_actual)
          const est = r.eps_consensus === null || r.eps_consensus === undefined ? null : Number(r.eps_consensus)
          // PERIOD END: the calendar reports a MONTH ('2026-06') while this table's key is a DATE.
          // A 52/53-week filer closes its quarter on the Saturday nearest the month end and lands
          // in the following month about half the time, so no exact date is recoverable here — the
          // month's last day is used CONSISTENTLY, which is what a primary key needs. The precise
          // fiscal end lives in `security_metric.as_of`, from the filing.
          const pe = String(r.period_ending ?? '')
          const periodEnding = /^\d{4}-\d{2}$/.test(pe)
            ? iso(new Date(Date.UTC(Number(pe.slice(0, 4)), Number(pe.slice(5, 7)), 0)))
            : (/^\d{4}-\d{2}-\d{2}$/.test(pe) ? pe : null)
          if (!periodEnding) continue
          // A FRACTION FROM THE WRAPPER, A PERCENT IN THE COLUMN. Measured: XOM -0.0435 against a
          // computed -4.35%. Storing it raw in a column named `_pct` is the fraction/percent
          // confusion this schema has already had three times.
          const spRaw = r.surprise_percent
          out.push({
            security_id: sid,
            period_ending: periodEnding,
            eps_actual: actual,
            eps_estimated: est,
            surprise: est === null ? null : actual - est,
            surprise_pct: spRaw === null || spRaw === undefined ? null : Number(spRaw) * 100,
            reported_date: r.report_date ?? null,
            source_code: 'nasdaq',
            as_of: new Date().toISOString(),
          })
        }
        matched += out.length

        for (let i = 0; i < out.length; i += 500) {
          const { error } = await market
            .from('security_eps_history')
            .upsert(
              dedupeBy(out.slice(i, i + 500), (r) => `${r.security_id}|${r.period_ending}`),
              { onConflict: 'security_id,period_ending' },
            )
          if (error) throw new Error(`security_eps_history upsert failed: ${error.message}`)
        }
        written += out.length

        // Advanced ONLY after the window's rows are written, for the same reason the deep-daily
        // marker is: a cursor that moves before the data lands loses the window silently.
        walkedTo = new Date(start.getTime() - 86_400_000)
        const { error: uErr } = await market
          .from('earnings_history_cursor')
          .update({ walked_to: iso(walkedTo), updated_at: new Date().toISOString() })
          .eq('only_row', true)
        if (uErr) throw new Error(`earnings_history_cursor update failed: ${uErr.message}`)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        written,
        matched,
        fetched,
        windows,
        failed,
        lastError,
        walkedTo: iso(walkedTo),
        remaining: Math.max(0, Math.round((walkedTo.getTime() - stopAt.getTime()) / 86_400_000)),
      })
    }

    // WHEN THIS COMPANY NEXT REPORTS.
    //
    // `equity/calendar/earnings` takes a DATE RANGE, not a symbol — one call returned 116 companies
    // for a three-day window (measured). That makes it the cheapest thing here per fact delivered.
    // A FIVE-DAY window timed out, so the chunk size is part of the contract, not a tuning knob.
    //
    // A ROLLING REFRESH, NOT A BACKLOG. Every other resource drains a queue; the earnings horizon
    // MOVES, dates are rescheduled and estimates revised up to the day. So each run re-reads the
    // whole forward window and the newest answer wins — a backlog here would freeze a date that
    // later changed.
    // WHO INSIDE THE COMPANY IS BUYING, AND WHO IS SELLING.
    //
    // Form 4 filings via `equity/ownership/insider_trading?provider=sec`. Chosen over
    // `equity/fundamental/management` because neither BATCHES (measured: two symbols return zero
    // rows) and this one runs on SEC — 10 requests a second documented, ~0.17s each, and scoped to
    // the 3,516 securities that have a CIK — rather than the yfinance budget every other backlog is
    // already queued behind.
    //
    // A ROLLING CURSOR, NOT A BACKLOG: insiders keep trading, so `insider_fetched_at` records when
    // we last looked and never that there is nothing to find. `pending_insider` is not meant to
    // empty.
    // THE FILINGS THEMSELVES — the documents, not the numbers in them.
    //
    // ASKED BY CIK, which this endpoint accepts and `insider_trading` does not. So there is no
    // symbol resolution here at all: no `symbol_security` lookup, no US-ticker-versus-display-symbol
    // question, and none of the `CIK not found for symbol BG.VI` failures that cost the insider
    // resource 12 of 26 securities on its first run. The backlog already filters on the CIK.
    // DEEP EPS HISTORY — actual against estimate, going back years.
    //
    // CALLED DIRECTLY, NOT THROUGH openbb-api, and that is the whole reason this resource is safe.
    // Alpha Vantage's free key allows 25 requests a DAY, and when it is spent it answers 200 with an
    // `Information` field about the limit — which openbb translates into an empty **204**, exactly
    // what it returns for a symbol it genuinely has nothing for. Measured 2026-08-22: MSFT returned
    // full data from the raw API in the same minute openbb reported 204 for it.
    //
    // A resource that could not tell those apart would negative-cache real companies for 90 days
    // every time the quota ran out, which at 24 calls a day against a 25 limit is most days. So it
    // reads the field that carries the difference.
    //
    // THREE A RUN because of that same quota, over holdings above 1% with a 90-day cursor — ~2,000
    // calls a year against a ~9,000 budget.
    if (resource === EPS_HISTORY_RESOURCE) {
      const avKey = Deno.env.get('ALPHA_VANTAGE_API_KEY') ?? ''
      if (!avKey) {
        // ABSENT, NOT BROKEN. The stack renders this variable empty when no key is configured, and
        // saying so is more useful than 25 failed requests.
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, securities: 0, note: 'ALPHA_VANTAGE_API_KEY is not set' })
      }

      const { data: pending, error: pendErr } = await market
        .from('pending_eps_history')
        .select('security_id,symbol')
        .order('best_weight', { ascending: false })
        .limit(scopeLimit ?? 3)
      if (pendErr) throw new Error(`pending_eps_history read failed: ${pendErr.message}`)
      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        symbol: String(r.symbol),
      }))
      const remaining = await backlogSize(market, 'pending_eps_history')
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, securities: 0, remaining, note: 'every large holding is current' })
      }

      const deadline = Date.now() + 60_000
      let written = 0
      let securities = 0
      let noHistory = 0
      let notCovered = 0
      let failed = 0
      let rateLimited = false
      let lastError: string | null = null
      let firstError: string | null = null

      for (const [i, item] of wanted.entries()) {
        if (Date.now() > deadline - TAIL_RESERVE_MS) break
        // THE PROVIDER NAMES ITS OWN PACE — "1 request per second" is in the throttle text it
        // returns. Three calls back to back tripped it on the second, and a tripped run marks
        // nothing, so the sleep costs a few seconds and buys the whole page.
        if (i > 0) await new Promise((r) => setTimeout(r, 1_500))
        let got: Awaited<ReturnType<typeof fetchAlphaVantageEarnings>>
        try {
          got = await fetchAlphaVantageEarnings(item.symbol, avKey, Math.min(20_000, deadline - Date.now()))
        } catch (e) {
          failed++
          lastError = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          firstError ??= `${item.symbol}: ${lastError}`
          continue
        }

        // THE QUOTA IS NOT A FACT ABOUT THIS SECURITY. Stop the run, mark nothing, leave every
        // cursor untouched — continuing would spend the remaining calls proving the same thing.
        if (got.rateLimited) {
          rateLimited = true
          lastError = got.note
          break
        }

        // ASKED, AND NOT CARRIED. Marking here is what lets the head advance: the backlog is
        // ordered by fund weight, so an unanswerable symbol at the top is re-asked on every run
        // until something records that we asked. The cursor gives it 90 days, not for ever — a
        // company can gain a US listing, and 90 days is the same quarterly cadence a covered
        // security refreshes on.
        if (got.notCovered) {
          notCovered++
          const { error: nErr } = await market
            .from('security')
            .update({ eps_history_fetched_at: new Date().toISOString() })
            .eq('security_id', item.securityId)
          if (nErr) throw new Error(`eps_history_fetched_at update failed: ${nErr.message}`)
          continue
        }
        if (got.quarters === null) {
          // An unexpected shape or a transport-level refusal. Reported, never marked: if the
          // provider renames a field, this must be loud rather than quietly concluding that every
          // security in the page has no earnings history.
          failed++
          lastError = got.note
          firstError ??= `${item.symbol}: ${got.note}`
          continue
        }

        const out = got.quarters.map((q) => ({
          security_id: item.securityId,
          period_ending: q.periodEnding,
          // NOT `|| null` — a genuine EPS of 0 is a real figure and must survive.
          eps_actual: q.actual,
          eps_estimated: q.estimated,
          surprise: q.surprise,
          // Already a PERCENT from the raw API (12.5891), unlike openbb's wrapper which sends the
          // fraction 0.125891. Reading the provider directly means reading ITS units.
          surprise_pct: q.surprisePct,
          reported_date: q.reportedDate,
          source_code: 'alpha-vantage',
          as_of: new Date().toISOString(),
        }))

        if (out.length > 0) {
          const { error } = await market
            .from('security_eps_history')
            .upsert(dedupeBy(out, (r) => `${r.security_id}|${r.period_ending}`),
              { onConflict: 'security_id,period_ending' })
          if (error) throw new Error(`security_eps_history upsert failed: ${error.message}`)
          written += out.length
          securities++
        } else {
          // An ANSWER with no quarters — the provider replied and has nothing for this symbol.
          // Safe to mark only because `rateLimited` and the null-shape case were handled above.
          noHistory++
        }

        const { error: cErr } = await market
          .from('security')
          .update({ eps_history_fetched_at: new Date().toISOString() })
          .eq('security_id', item.securityId)
        if (cErr) throw new Error(`eps_history_fetched_at update failed: ${cErr.message}`)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: !rateLimited })
      return json({
        resource,
        written,
        securities,
        noHistory,
        // Asked and not carried — the head advanced. Counted apart from `failed` because it is an
        // answer, and apart from `noHistory` because that one HAS a US listing and simply has no
        // earnings on file.
        notCovered,
        failed,
        // Reported so an exhausted day reads as itself rather than as a broken resource.
        rateLimited,
        // BOTH ENDS OF THE RUN. `lastError` alone is whatever happened last, and a rate limit at
        // call two overwrites the real failure at call one — which is exactly how the first
        // production run reported a quota problem while an unanswerable symbol was the story.
        firstError,
        lastError,
        remaining: await backlogSize(market, 'pending_eps_history'),
      })
    }

    if (resource === FILINGS_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_filings')
        .select('security_id,cik')
        .order('best_weight', { ascending: false })
        .limit(scopeLimit ?? 120)
      if (pendErr) throw new Error(`pending_filings read failed: ${pendErr.message}`)
      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        cik: String(r.cik),
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, securities: 0, note: 'every filer was read this week' })
      }

      // BOTH VOCABULARIES IN ONE CALL. A domestic registrant files 10-K/10-Q; a foreign private
      // issuer files 20-F/6-K instead — BABA returns twelve 6-Ks and no 10-Q. `form_type` filters
      // (comma separated, measured); `form_group` was tried first and is a NO-OP that returns
      // Form 4s regardless, which reads as a working filter returning honest results.
      const FORM_TYPES = ['10-K', '10-Q', '8-K', '20-F', '6-K', 'DEF 14A']
        .map((t) => encodeURIComponent(t))
        .join(',')

      const deadline = Date.now() + 60_000
      let written = 0
      let securities = 0
      let noFilings = 0
      let failed = 0
      let lastError: string | null = null

      for (const item of wanted) {
        if (Date.now() > deadline - TAIL_RESERVE_MS) break
        let rows: Record<string, unknown>[] = []
        try {
          rows = await fetcher(
            `/api/v1/equity/fundamental/filings?cik=${encodeURIComponent(item.cik)}` +
              `&form_type=${FORM_TYPES}&provider=sec&limit=40`,
            Math.min(20_000, deadline - Date.now()),
          )
        } catch (e) {
          const msg = e instanceof Error ? e.message.slice(0, 300) : String(e).slice(0, 300)
          // A 400 NAMING THE ABSENCE IS AN ANSWER, the same distinction the insider resource makes:
          // a filer with none of these forms in the window has been asked, and the cursor advances.
          // A TRANSPORT error is not an answer and must leave the cursor alone, or a thirty-second
          // openbb-api restart costs a week of staleness for the whole page.
          if (/no .* data|not found/i.test(msg) && !/connect|refused|timeout/i.test(msg)) {
            noFilings++
            const { error: cErr } = await market
              .from('security')
              .update({ filings_fetched_at: new Date().toISOString() })
              .eq('security_id', item.securityId)
            if (cErr) throw new Error(`filings_fetched_at update failed: ${cErr.message}`)
            continue
          }
          failed++
          lastError = msg
          continue
        }

        const out: Record<string, unknown>[] = []
        for (const r of rows) {
          const accession = String(r.accession_number ?? '').trim()
          if (!accession) continue
          out.push({
            accession_number: accession,
            security_id: item.securityId,
            filing_date: r.filing_date ? String(r.filing_date).slice(0, 10) : null,
            report_date: r.report_date ? String(r.report_date).slice(0, 10) : null,
            report_type: r.report_type ? String(r.report_type) : null,
            report_url: r.report_url ? String(r.report_url) : null,
            filing_detail_url: r.filing_detail_url ? String(r.filing_detail_url) : null,
            source_code: 'sec-filings',
            as_of: new Date().toISOString(),
          })
        }

        if (out.length > 0) {
          const { error } = await market
            .from('security_filing')
            .upsert(
              dedupeBy(out, (r) => `${r.security_id}|${r.accession_number}`),
              { onConflict: 'security_id,accession_number' },
            )
          if (error) throw new Error(`security_filing upsert failed: ${error.message}`)
          written += out.length
          securities++
        } else {
          noFilings++
        }

        const { error: cErr } = await market
          .from('security')
          .update({ filings_fetched_at: new Date().toISOString() })
          .eq('security_id', item.securityId)
        if (cErr) throw new Error(`filings_fetched_at update failed: ${cErr.message}`)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        written,
        securities,
        noFilings,
        failed,
        lastError,
        remaining: await backlogSize(market, 'pending_filings'),
      })
    }

    if (resource === INSIDER_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_insider')
        .select('security_id')
        .order('best_weight', { ascending: false })
        .limit(scopeLimit ?? 120)
      if (pendErr) throw new Error(`pending_insider read failed: ${pendErr.message}`)
      const wanted = (pending ?? []).map((r) => r.security_id as string)
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, securities: 0, note: 'every filer was read this week' })
      }

      // THE US TICKER, NOT THE DISPLAY SYMBOL — and the endpoint gives no choice.
      //
      // It requires `symbol` and rejects a CIK outright (`cik=` answers "Field required: symbol";
      // `symbol=0000320193` answers "CIK not found"), so the CIK we already hold cannot be passed.
      // And the DISPLAY symbol is the wrong key here: `symbol_security` serves the primary listing,
      // which for Bunge is `BG.VI` — SEC has no CIK for a Vienna line, and the first real run
      // failed 12 of 26 securities on exactly that. `BG` works.
      //
      // This is the mirror of the rule migration 39 established. `security_identifier`'s `ticker`
      // is OpenFIGI's US lookup, which is the WRONG symbol for prices (it is a thin OTC
      // foreign-ordinary line for a foreign company) and the RIGHT one for anything asking SEC,
      // because SEC only knows US registrants. Same company, two correct answers, different
      // questions.
      //
      // CHUNKED, because an `in.()` filter is a URL and its size is a LENGTH budget: 120 UUIDs is
      // already ~4.7 KB, and 6.5 KB is where the proxy answers a bare 502 with nothing pointing at
      // the cause. `scopeLimit` can raise the page, so the bound lives here.
      const symbolById = new Map<string, string>()
      for (let i = 0; i < wanted.length; i += 100) {
        const { data: symRows, error: symErr } = await market
          .from('security_identifier')
          .select('value,security_id')
          .eq('kind_code', 'ticker')
          .in('security_id', wanted.slice(i, i + 100))
        if (symErr) throw new Error(`security_identifier read failed: ${symErr.message}`)
        for (const r of symRows ?? []) symbolById.set(r.security_id as string, String(r.value))
      }

      const deadline = Date.now() + 60_000
      let written = 0
      let securities = 0
      let noFilings = 0
      let failed = 0
      let lastError: string | null = null

      for (const securityId of wanted) {
        if (Date.now() > deadline - TAIL_RESERVE_MS) break
        const symbol = symbolById.get(securityId)
        if (!symbol) continue

        let rows: Record<string, unknown>[] = []
        try {
          rows = await fetcher(
            `/api/v1/equity/ownership/insider_trading?symbol=${encodeURIComponent(symbol)}` +
              `&provider=sec&limit=50`,
            Math.min(20_000, deadline - Date.now()),
          )
        } catch (e) {
          const msg = e instanceof Error ? e.message.slice(0, 300) : String(e).slice(0, 300)
          // A 400 THAT SAYS "NO FORM 4 DATA" IS AN ANSWER, NOT A FAILURE — and the provider states
          // it outright rather than leaving it to be inferred from a status code. Thin OTC
          // foreign-ordinary lines like BBVXF have no Form 4 because the company is not a US
          // registrant; that is a settled fact about the security, reached by asking.
          //
          // Treating it as a failure would leave the cursor unadvanced and bring the same
          // securities back every run for ever — 8 of 30 on the run that surfaced this. The
          // distinction is the one this pipeline keeps relearning: A REQUEST THAT FAILED AND A
          // REQUEST THAT ANSWERED NOTHING ARE DIFFERENT FACTS, and here the message says which.
          if (/no form 4 data/i.test(msg)) {
            noFilings++
            const { error: cErr } = await market
              .from('security')
              .update({ insider_fetched_at: new Date().toISOString() })
              .eq('security_id', securityId)
            if (cErr) throw new Error(`insider_fetched_at update failed: ${cErr.message}`)
            continue
          }
          failed++
          lastError = msg
          // A TRANSPORT ERROR IS NOT AN ANSWER. `Connection refused` means openbb-api was
          // restarting or had been OOM-killed — measured, a deploy restart produced exactly that
          // for ~a minute. The cursor stays put so the security comes back next run rather than
          // waiting a week because the service was down for thirty seconds.
          continue
        }

        const out: Record<string, unknown>[] = []
        for (const r of rows) {
          const txDate = String(r.transaction_date ?? '').slice(0, 10)
          const shares = Number(r.securities_transacted)
          const price = Number(r.transaction_price)
          const ownedAfter = Number(r.securities_owned)
          const owner = r.owner_name ? String(r.owner_name) : ''
          const direction = r.acquisition_or_disposition ? String(r.acquisition_or_disposition) : null
          if (!txDate) continue
          // DETERMINISTIC KEY over the filing's own facts, because the response carries no id.
          // Re-fetching the same filing must be idempotent rather than duplicating it every run,
          // and this resource re-reads each security weekly by design.
          const key = await sha256Hex(
            [securityId, txDate, owner, direction ?? '', String(r.security_type ?? ''),
             Number.isFinite(shares) ? shares : '', Number.isFinite(price) ? price : ''].join('|'),
          )
          out.push({
            trade_key: key,
            security_id: securityId,
            filing_date: r.filing_date ? String(r.filing_date).slice(0, 10) : null,
            transaction_date: txDate,
            owner_name: owner || null,
            owner_title: r.owner_title ? String(r.owner_title) : null,
            direction,
            transaction_type: r.transaction_type ? String(r.transaction_type) : null,
            security_type: r.security_type ? String(r.security_type) : null,
            shares: Number.isFinite(shares) ? shares : null,
            shares_owned_after: Number.isFinite(ownedAfter) ? ownedAfter : null,
            price: Number.isFinite(price) ? price : null,
            source_code: 'sec-form4',
            as_of: new Date().toISOString(),
          })
        }

        if (out.length > 0) {
          const { error } = await market
            .from('insider_trade')
            .upsert(dedupeBy(out, (r) => String(r.trade_key)), { onConflict: 'trade_key' })
          if (error) throw new Error(`insider_trade upsert failed: ${error.message}`)
          written += out.length
          securities++
        } else {
          // ASKED AND ANSWERED WITH NOTHING, which for Form 4 is ordinary — plenty of companies go
          // a quarter without an insider transaction. The cursor still advances: this is "we
          // looked", not "there is nothing to find".
          noFilings++
        }

        const { error: cErr } = await market
          .from('security')
          .update({ insider_fetched_at: new Date().toISOString() })
          .eq('security_id', securityId)
        if (cErr) throw new Error(`insider_fetched_at update failed: ${cErr.message}`)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        written,
        securities,
        noFilings,
        failed,
        lastError,
        remaining: await backlogSize(market, 'pending_insider'),
      })
    }

    if (resource === EARNINGS_RESOURCE) {
      const deadline = Date.now() + 60_000
      const CHUNK_DAYS = 3
      const HORIZON_DAYS = 21
      const day = (offset: number) =>
        new Date(Date.now() + offset * 86_400_000).toISOString().slice(0, 10)

      // RESOLVED BY ASKING FOR THE SYMBOLS WE ACTUALLY GOT, NEVER BY LOADING THE MAP.
      //
      // The first version selected all of `symbol_security` in one go. It holds 12,090 rows and
      // `PGRST_DB_MAX_ROWS` is 1,000, so the map silently contained a twelfth of the universe:
      // measured, a run wrote 753 calendar rows and matched **22** of them, with NVDA and CRM
      // landing at `security_id: null` while both are tracked. No error, and the count reads like
      // a fact about coverage rather than about paging. Third time this cap has bitten in this
      // codebase — the FX history probe did the same thing yesterday.
      //
      // An `in.()` filter is a URL, so its chunk size is a LENGTH budget rather than a row budget:
      // 500 ISINs is a ~6.5 KB URL and the proxy answers a bare 502. 100 is the documented safe size.
      const idBySymbol = new Map<string, string>()
      const resolve = async (symbols: string[]) => {
        const unknown = [...new Set(symbols)].filter((sym) => !idBySymbol.has(sym))
        for (let i = 0; i < unknown.length; i += 100) {
          const chunk = unknown.slice(i, i + 100)
          const { data, error } = await market
            .from('symbol_security')
            .select('symbol,security_id')
            .in('symbol', chunk)
          if (error) throw new Error(`symbol_security read failed: ${error.message}`)
          for (const r of data ?? []) {
            idBySymbol.set(String(r.symbol).toUpperCase(), r.security_id as string)
          }
          // Remember the misses too, so a symbol nasdaq reports and this universe does not track is
          // asked about once per run rather than once per window.
          for (const sym of chunk) if (!idBySymbol.has(sym)) idBySymbol.set(sym, '')
        }
      }

      let fetched = 0
      let written = 0
      let matched = 0
      let windows = 0
      let failed = 0
      let lastError: string | null = null

      for (let offset = -7; offset < HORIZON_DAYS && Date.now() < deadline - TAIL_RESERVE_MS; offset += CHUNK_DAYS) {
        let rows: Record<string, unknown>[] = []
        try {
          rows = await fetcher(
            `/api/v1/equity/calendar/earnings?provider=nasdaq` +
              `&start_date=${day(offset)}&end_date=${day(offset + CHUNK_DAYS - 1)}`,
            Math.min(25_000, deadline - Date.now()),
          )
        } catch (e) {
          failed++
          lastError = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          continue
        }
        windows++
        fetched += rows.length

        await resolve(
          rows.map((r) => String(r.symbol ?? '').toUpperCase()).filter((sym) => sym.length > 0),
        )

        const out: Record<string, unknown>[] = []
        for (const r of rows) {
          const symbol = String(r.symbol ?? '').toUpperCase()
          const reportDate = String(r.report_date ?? '').slice(0, 10)
          if (!symbol || !reportDate) continue
          // '' is a remembered MISS, not an id.
          const securityId = idBySymbol.get(symbol) || null
          if (securityId) matched++
          const consensus = Number(r.eps_consensus)
          const previous = Number(r.eps_previous)
          const estimates = Number(r.num_estimates)
          out.push({
            symbol,
            report_date: reportDate,
            // NULL rather than dropped when we do not track the company: nasdaq covers far more US
            // listings than this universe holds, and discarding them would mean re-fetching the
            // same unresolvable rows for ever to learn the same nothing.
            security_id: securityId,
            name: r.name ? String(r.name) : null,
            eps_consensus: Number.isFinite(consensus) ? consensus : null,
            eps_previous: Number.isFinite(previous) ? previous : null,
            num_estimates: Number.isFinite(estimates) ? Math.round(estimates) : null,
            period_ending: r.period_ending ? String(r.period_ending) : null,
            reporting_time: r.reporting_time ? String(r.reporting_time) : null,
            source_code: 'nasdaq',
            as_of: new Date().toISOString(),
          })
        }

        if (out.length > 0) {
          const { error } = await market
            .from('earnings_calendar')
            .upsert(dedupeBy(out, (r) => `${r.symbol}|${r.report_date}`),
              { onConflict: 'symbol,report_date' })
          if (error) throw new Error(`earnings_calendar upsert failed: ${error.message}`)
          written += out.length
        }
      }

      // A CALENDAR, NOT AN ARCHIVE. Ninety days of history so a page can say "reported on the 26th"
      // as well as "reports on the 26th"; beyond that the row is answering no question anyone asks
      // and `security_statement` already holds what was actually reported.
      const cutoff = new Date(Date.now() - 90 * 86_400_000).toISOString().slice(0, 10)
      const { error: delErr } = await market
        .from('earnings_calendar')
        .delete()
        .lt('report_date', cutoff)
      if (delErr) throw new Error(`earnings_calendar prune failed: ${delErr.message}`)

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: failed === 0 })
      return json({
        resource,
        windows,
        fetched,
        written,
        // How many of the calendar's companies this universe actually tracks. A collapse here means
        // the symbol map broke, not that companies stopped reporting.
        matched,
        failed,
        lastError,
      })
    }

    // Statements are fetched PER SECURITY, not per batch: each of the three endpoints returns one
    // row per PERIOD, and a multi-symbol response would interleave periods from different
    // companies with only a `symbol` field to tell them apart. One symbol at a time keeps the
    // attribution structural rather than something to get right.
    if (resource === STATEMENTS_RESOURCE) {
      // SEC ONLY, SINCE 2026-10-18. Yahoo's statements are the Dagster company lane's
      // (`yahoo_companies`), annual and quarterly and labelled with their currency. This resource
      // used to ask yfinance too, for a security with no statements at all, and by then that half
      // held 26 securities Yahoo answers nothing for. Migration 20261018200000 narrowed the queue to
      // what SEC can answer: a CIK, a US listing to spell the question with, and no `sec` row.
      const { data: pending, error: pErr } = await market
        .from('pending_statements')
        .select('security_id,us_ticker,want')
        .order('best_weight', { ascending: false })
        // 60, because it is three calls PER SECURITY (income, balance, cash), 180 requests a run,
        // which fills the worker. These endpoints do not batch: two symbols in one call answered
        // nothing (measured 2026-08-13), and SEC is asked per filer anyway.
        .limit(scopeLimit ?? 60)
      if (pErr) throw new Error(`pending_statements read failed: ${pErr.message}`)
      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        usTicker: (r.us_ticker as string | null) ?? null,
        want: (r.want as string | null) ?? 'missing',
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'SEC has been asked about every filer' })
      }
      let fromSec = 0
      let secFailed = 0
      let secNone = 0
      // Proof the SEC endpoint produced rows for SOMEONE this run. Without it, a throttled or
      // broken provider marks every security it touches as "does not file" — the defect that put
      // `statements_missing_at` on 5,613 securities in one afternoon.
      let secOk = false

      const deadline = Date.now() + 60_000
      let written = 0
      let throttledOut = false
      const answered = new Set<string>()
      // Securities SEC answered with no rows, held until the run can show the endpoint answers at
      // all (below).
      const emptyAnswer: string[] = []
      let controlAnswered: boolean | null = null
      const markSecNone = async (securityId: string) => {
        secNone++
        const { error } = await market
          .from('security')
          .update({ statement_currency_missing_at: new Date().toISOString() })
          .eq('security_id', securityId)
        if (error) throw new Error(`statement_currency_missing_at update failed: ${error.message}`)
      }

      for (const item of wanted) {
        // The view requires a US listing, so this is defence, not a filter: SEC resolves `SAP` and
        // never `SAP.DE`, and a question it cannot parse must not be asked.
        if (!item.usTicker) continue
        if (Date.now() > deadline - 8_000) break
        const rows: Record<string, unknown>[] = []
        // Per-security, not per-run. A tally cannot be evidence about one symbol: `secOk` says
        // the endpoint produced rows for SOMEONE, `secAsked` that we finished asking about THIS
        // one, and only both together justify recording that SEC has nothing for it.
        let secAsked = true
        let secRows = 0
        // Set when SEC states, per symbol, that it cannot resolve this security at all. That is
        // evidence about the SYMBOL, so it justifies the mark on its own — unlike an empty
        // answer, which needs the run-level `secOk` to rule out an outage.
        let secNoSuchSymbol = false
        for (const kind of ['income', 'balance', 'cash'] as const) {
          const remaining = deadline - Date.now()
          if (remaining < 5_000) { secAsked = false; break }
          try {
            // ANNUAL ONLY: `period=quarter` answers 422. Quarters come from SEC's XBRL company
            // facts (`security-xbrl`) and from Yahoo through the company lane.
            const got = await fetcher(
              `/api/v1/equity/fundamental/${kind}?symbol=${encodeURIComponent(item.usTicker)}` +
                `&provider=sec&period=annual&limit=25`,
              Math.min(20_000, remaining),
            )
            for (const r of got) {
              const period = String(r.period_ending ?? r.date ?? '').slice(0, 10)
              if (!period) continue
              answered.add(item.securityId)
              rows.push({
                security_id: item.securityId,
                statement: kind,
                period_ending: period,
                // PART OF THE PRIMARY KEY SINCE MIGRATION 106 and NOT NULL: a fiscal-year end is
                // both an annual period and a fourth-quarter one, so the two must be able to coexist.
                period_type: 'annual',
                // THE POINT OF THIS PROVIDER: SEC states the reporting currency, and 20-F filers
                // report in their own (EUR, DKK, PEN, TWD among the first 522 rows).
                currency: r.reported_currency ? String(r.reported_currency) : null,
                data: r,
                source_code: 'sec',
                as_of: new Date().toISOString(),
              })
            }
            if (got.length > 0) { fromSec++; secRows += got.length; secOk = true }
          } catch (e) {
            // A SEC failure is counted, never marked: a failure is not evidence the company does
            // not file.
            const msg = e instanceof Error ? e.message : String(e)
            if (throttled(msg)) { secFailed++; secAsked = false; throttledOut = true; break }
            // …BUT A 404 THAT NAMES THE SYMBOL IS THE ANSWER, NOT A FAILURE TO GET ONE.
            //
            // openbb's SEC provider resolves symbol -> CIK through SEC's own ticker map, so a US
            // OTC foreign-ordinary line absent from that map can never be served — `AIBRF`
            // (AIB Group, 16.08% fund weight) and `BWAGF` return `ContentTypeError -> 404` for
            // every statement kind while AAPL answers in the same seconds.
            //
            // Treating that as a failure set `secAsked = false`, so the "SEC has nothing for
            // this company" branch below could never run and the security stayed in the backlog
            // for ever. Measured 2026-09-06: `written: 240, secFailed: 180, fromSec: 0,
            // remaining: 5972` BYTE-IDENTICAL on six consecutive runs. Three outcomes, not two:
            // answered, answered-with-nothing, and did not answer.
            if (noDataForSymbol(msg)) { secNoSuchSymbol = true; continue }
            secFailed++
            secAsked = false
          }
        }

        if (rows.length > 0) {
          const { error } = await market
            .from('security_statement')
            .upsert(dedupeBy(rows, (r) => `${r.security_id}|${r.statement}|${r.period_ending}|${r.period_type}`),
              { onConflict: 'security_id,statement,period_ending,period_type' })
          if (error) throw new Error(`security_statement upsert failed: ${error.message}`)
          written += rows.length
        }

        // SEC HAS NOTHING FOR THIS COMPANY — recorded, or the backlog can never drain. A failure,
        // a throttle or a deadline is not evidence, so only two answers are:
        //
        // A 404 THAT NAMES THE SYMBOL carries its own evidence and is marked at once. Requiring the
        // run-level tally in front of it is the `security-profile-detail` stall: once a
        // weight-ordered backlog's answerable head has drained, no security in the page answers,
        // the tally never becomes true, and the page can never be marked.
        //
        // AN EMPTY ANSWER is evidence only once the run shows the endpoint answers at all, so it
        // waits for `secOk` below. BOTH HALVES are marked since 2026-10-18. A `missing` security
        // (no statements at all) used to fall through to yfinance, and SEC's answer was recorded
        // only under the yfinance half's `statements_missing_at`.
        if (rows.length === 0 && secNoSuchSymbol) {
          await markSecNone(item.securityId)
        } else if (rows.length === 0 && secAsked && secRows === 0) {
          emptyAnswer.push(item.securityId)
        }
        if (throttledOut) break
      }

      // AN EMPTY ANSWER NEEDS PROOF THE ENDPOINT ANSWERS, AND A SMALL QUEUE NEVER SUPPLIES IT.
      // `secOk` is set only when some security in the run got rows, so a queue holding only
      // companies SEC has nothing for could never be marked: measured 2026-10-18, REAX, OCTLF and
      // CIB were asked on every run (three calls each, `unanswered: 3`) and never recorded. A
      // control filer settles it, as `fetchWithIsolation`'s control symbol does: rows for the
      // control prove SEC is answering, so the empty answers are about the companies. A failed or
      // empty control marks nothing, and costs one call, only on a run where nothing else answered.
      if (emptyAnswer.length > 0 && !secOk && !throttledOut && deadline - Date.now() > 5_000) {
        try {
          // PAST THE CACHE: http-cache keeps serving an expired 200 while its refresh fails, so a
          // cached answer for AAPL would prove nothing about SEC (`FetchOptions`).
          const got = await fetcher(
            `/api/v1/equity/fundamental/income?symbol=${SEC_CONTROL_FILER}&provider=sec&period=annual&limit=1`,
            Math.min(20_000, deadline - Date.now()), { uncached: true },
          )
          controlAnswered = got.length > 0
          if (controlAnswered) secOk = true
        } catch (_e) {
          controlAnswered = false
        }
      }
      if (emptyAnswer.length > 0 && secOk) {
        for (const securityId of emptyAnswer) await markSecNone(securityId)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        written,
        // Statement kinds SEC answered with rows: up to three per security asked.
        fromSec,
        secFailed,
        // Securities recorded as having nothing at SEC this run.
        secNone,
        // Asked only when nothing else answered: true marks the empty answers, false or null none.
        controlAnswered,
        throttledOut,
        symbolsAnswered: answered.size,
        symbolsAsked: wanted.length,
        // THE BACKLOG, COUNTED — not what is left of this page.
        //
        // The page-scoped number is `unanswered` below. `remaining` used to be page-scoped too and
        // therefore reported 0 on a run that had asked 20 of 8,633 — which is indistinguishable
        // from a drained backlog, the single most dangerous reading in this pipeline (a backlog
        // that empties by MARKING looks exactly like one that empties by WORKING).
        //
        // Counted with `head: true`, so it is a `content-range` and not a page: a `.limit()` above
        // PGRST_DB_MAX_ROWS silently returns 1,000 and would report "1000" for ever however bad
        // things got.
        remaining: await backlogSize(market, 'pending_statements'),
        // What this PAGE neither answered nor recorded. Non-zero here with `remaining` still large
        // is an ordinary partial run; non-zero here on every run is a provider problem.
        unanswered: Math.max(0, wanted.length - answered.size - secNone),
      })
    }

    // Everything for ONE security, from the stock page. Scoped rather than universe-wide because
    // the resources it wraps are budgeted for a backlog and would refuse on their TTL, and because
    // fundamentals cost one of 25 daily calls — spending those on what someone is looking at is
    // the only shape that provider supports.
    // ON DEMAND, THROUGH DAGSTER (Phase 4 decision 8). This handler used to fetch the profile, the
    // fundamentals and Yahoo's statements itself through openbb, and wrote the metrics response's
    // REPORTING currency into the listing's QUOTE currency on the way (`writeCurrencyFor`). The
    // company lane owns all of that now, so a press launches this security's partition of
    // `yahoo_companies` with `force: true`.
    //
    // It answers `queued`, never `refreshed`: the data arrives minutes later, and a button that said
    // "refreshed" would invite a reload that shows nothing new.
    if (resource === ONE_SECURITY_RESOURCE) {
      const wanted = String(symbolScope ?? '').trim().toUpperCase()
      if (!wanted) return releaseAnd({ error: 'security-refresh needs a `symbol`' }, 400)

      const { data: rows, error: findErr } = await market
        .from('security_current')
        .select('security_id,symbol,name')
        .eq('symbol', wanted)
        .limit(1)
      if (findErr) throw new Error(`security lookup failed: ${findErr.message}`)
      let securityId = (rows ?? [])[0]?.security_id as string | undefined

      // Fall back to the PROVIDER symbol. A non-US security often has no `ticker` identifier at
      // all — only `005930.KS` in security_provider_symbol — so a display-symbol lookup alone
      // reports "unknown symbol" for a security we hold.
      if (!securityId) {
        const { data: viaProvider } = await market
          .from('security_provider_symbol')
          .select('security_id')
          .eq('provider_code', 'yfinance')
          .eq('symbol', wanted)
          .maybeSingle()
        securityId = (viaProvider?.security_id as string | undefined) ?? undefined
      }
      if (!securityId) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, symbol: wanted, queued: false, reason: 'unknown symbol' })
      }

      const launched = await launchCompanyRun(securityId, wanted)
      if (!launched.ok) {
        // Not an exception: Dagster answered, or did not, and the caller is told which. A security
        // with no partition yet (promoted minutes ago) is refused here, by name.
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: false, p_error: launched.error })
        return json({ resource, symbol: wanted, queued: false, reason: launched.error })
      }
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, symbol: wanted, queued: true, runId: launched.runId })
    }

    // Every resource `EXTRA_TTL_MINUTES` accepts has a handler above, so reaching this line is a
    // defect in this file rather than a bad request. Thrown, so the catch records it in
    // `refresh_log` like any other failure instead of answering a 200 that did nothing.
    throw new Error(`no handler for '${resource}'`)
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e)
    // Record the failure: begin_refresh() then applies its error backoff, so a
    // broken upstream is retried soon but not on every single trigger.
    await market.rpc('finish_refresh', { p_resource: resource, p_ok: false, p_error: message })
    console.error(`market-refresh(${resource}) failed: ${message}`)
    // 200 WITH `ok: false`, NOT 502 — the invocation succeeded and is REPORTING a failed outcome.
    //
    // This used to return 502 and the reason never reached the caller: something in
    // Cloudflare/Traefik/Kong owns that status and replaces the body with its own 16-byte
    // `error code: 502`. Measured 2026-08-13 — a 400 from this same function arrives with its full
    // 482-byte JSON, so it is the 502 specifically that is synthesized, not bodies in general.
    //
    // The cost was not cosmetic. `security-profiles` was rate-limited and said so in
    // `refresh_log`, while every caller saw a bare 502 — which this codebase documents as meaning
    // A DEAD WORKER ("look at memory, not at your error handling"). Four probes went into
    // re-deriving from the database what the response had already been told. The warm-up's
    // `::warning::$r failed (HTTP 502): error code: 502` had been saying nothing for the same
    // reason.
    //
    // Keeping 5xx for genuine crashes is the point: with application failures out of that range, a
    // bare 502 means what the docs say again.
    return json({ resource, ok: false, error: message })
  }
}

/**
 * Append one row to `market.refresh_run` describing what an invocation did.
 *
 * WHY THIS IS A WRAPPER AND NOT ~40 EDITS. `market.refresh_log` is keyed `resource text PRIMARY
 * KEY`, so it holds the LATEST run and nothing else — this pipeline has no history by
 * construction. The reports that would BE the history are already assembled at every `return
 * json(...)` site in this file, and were being echoed into a GitHub Actions log and discarded:
 * 38 resources x 8 runs a day. Recording them at the ~40 return sites would mean the next resource
 * added below one of them is silently unrecorded, so the record is taken from the RESPONSE
 * instead, in one place that every path must pass through.
 *
 * It is deliberately taken here rather than in `market-warmup.yml`, which also holds the body:
 * this catches UI-triggered and `force` runs too, and the workflow cannot see either.
 *
 * THREE THINGS THIS MUST NOT DO:
 *
 *   1. Fail the request. Everything is inside one try/catch and the worst case is a missing row.
 *      A metrics write that breaks a refresh is strictly worse than no metrics.
 *   2. Hang. It is AWAITED — a dropped record defeats the point, and `EdgeRuntime.waitUntil` is
 *      not something to bet a complete record on — but bounded by `abortSignal`, so a slow or
 *      unreachable database costs 5 seconds of a 90-second budget rather than the whole run.
 *   3. Call a failure a success, or a skip a failure. `{ skipped: true, reason: 'fresh or in
 *      flight' }` is a 200 and a SUCCESS: the TTL guard did its job. And since 2026-08-13 an
 *      application failure is ALSO a 200, carrying `"ok": false` — so the HTTP status alone is
 *      not the verdict. Both are recorded, separately, because a resource that only ever skips
 *      and one that genuinely runs are different facts and `ok` alone cannot tell them apart.
 */
async function recordRun(res: Response, fallbackResource: string, startedAt: Date): Promise<void> {
  try {
    const finishedAt = new Date()

    let report: Record<string, unknown> | null = null
    try {
      report = await res.json()
    } catch {
      // Not JSON. A proxy-synthesized `error code: 502` lands here — which is exactly the case
      // worth recording, since it is the signature of a dead worker.
      report = null
    }

    // Every ordinary path echoes `resource`; the two early 400/500s do not, which is what the
    // fallback read off the request is for.
    const resource = typeof report?.resource === 'string' ? report.resource : fallbackResource
    const skipped = report?.skipped === true
    const error = typeof report?.error === 'string' ? report.error : null
    // `ok: false` is explicit and beats the status code. Otherwise a 2xx with no `error` is a
    // success — including a skip.
    const ok = report?.ok === false ? false : res.ok && error === null

    await observability.from('refresh_run').insert({
      resource,
      started_at: startedAt.toISOString(),
      finished_at: finishedAt.toISOString(),
      duration_ms: finishedAt.getTime() - startedAt.getTime(),
      ok,
      skipped,
      http_status: res.status,
      error,
      // `written`, `remaining` and `failed` are GENERATED from this column — never sent, so they
      // cannot drift from the report they claim to summarise.
      report,
    }).abortSignal(AbortSignal.timeout(5_000))
  } catch (e) {
    console.error(`refresh_run insert failed: ${e instanceof Error ? e.message : String(e)}`)
  }
}

/** Its own client: the handler builds one per request, and this outlives the handler's scope. */
const observability = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
}).schema('market')

Deno.serve(async (req: Request) => {
  const startedAt = new Date()

  // From a CLONE. A Request body can only be read once and `handle` reads it itself; without the
  // clone this would consume the body and every request would be refused for naming no resource.
  let requested = '(none)'
  try {
    const body = await req.clone().json()
    if (body?.resource) requested = String(body.resource)
  } catch {
    // No body, or not JSON — `handle` refuses it, and the run is recorded under `(none)`.
  }

  const res = await handle(req)
  await recordRun(res.clone(), requested, startedAt)
  return res
})
