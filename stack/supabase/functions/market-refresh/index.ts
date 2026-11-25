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
import { fetchIndustries, slug } from './wikidata.ts'
import { BACKLOG_TTL_MINUTES, dedupeBy } from './resources.ts'

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
 * on 2026-10-25, the Korean and Indian segment parsers on 2026-11-04 (until Phase 6), finviz's
 * price targets on 2026-11-06, the rest of the SEC family on 2026-11-07 (Phase 5 step 9), and the
 * SEC segment parser on 2026-11-14 (Phase 6 step 3).
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
  'security-kr-segments': 'Dagster DART lane (dart_segment) — read market.security_segment_current',
  'security-in-segments': 'Dagster NSE lane (nse_segment) — read market.security_segment_current',
  'security-segments': 'Dagster SEC segment lane (raw_sec_instance → sec_segment) — read market.security_segment_current',
  'security-cn-segments': 'Dagster CNINFO lane (cninfo_segment) — read market.security_segment_current',
  'cn-filings': 'Dagster CNINFO lane (raw_cninfo_filings → cninfo_segment) — read market.security_filing',
  'kr-filings': 'Dagster DART lane (raw_dart_filings → dart_segment) — read market.security_filing',
  'in-filings': 'Dagster NSE lane (raw_nse_filings → nse_segment) — read market.security_filing',
  'security-price-targets': 'finviz moved its quote page; analyst actions move to the Dagster company lane (Yahoo) — read market.security_price_target',
  'security-xbrl': 'Dagster SEC filer lane (sec_statement → derived_security_metrics) — read market.security_metric',
  'security-filings': 'Dagster SEC filer lane (sec_filing) — read market.security_recent_filings',
  'security-filing-history': 'Dagster SEC filer lane (sec_filing) — read market.security_filing',
  'security-insider': 'Dagster SEC Form 4 lane (sec_form4_trade) — read market.security_insider_summary',
  'security-eps-history': 'unscheduled since 2026-08-28; earnings-history (the nasdaq calendar) writes the same table — read market.security_eps_history',
  'facets-refresh': 'pg_cron muffin-facets runs market.refresh_facets() as postgres, off the 8 s RPC ceiling — read market.security_facets',
  'earnings-calendar': 'Dagster earnings lanes (raw_nasdaq_earnings → nasdaq_earnings, yahoo_earnings) — read market.security_next_earnings',
  'earnings-history': 'Dagster earnings lanes (nasdaq_earnings, yahoo_earnings) — read market.security_earnings_history',
  'security-news': 'Dagster news lane (raw_yahoo_news → company_news) — read market.security_news',
  'macro-indicators': 'Dagster macro lane (raw_macro_series → macro_observation) — read market.macro_current',
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

  const FACETS_RESOURCE = 'facets-refresh'
  const OBSERVABILITY_RESOURCE = 'observability-sample'
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
    [WIKIDATA_RESOURCE]: BACKLOG_TTL_MINUTES,
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

  try {
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
