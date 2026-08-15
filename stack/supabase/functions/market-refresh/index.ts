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
// The fetch/mapping logic lives in ./resources.ts so it can be exercised against a
// real openbb-api with no Supabase running — see ./check.ts.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0'
import { ingestFund } from './ingest.ts'
import {
  listExchange,
  mapIsinsToLocalSymbols,
  mapIsinsToTickers,
  mapTickers,
  PAGING_CEILING,
} from './figi.ts'
import { fetchFundamentals } from './fundamentals.ts'
import { hasLocalExchange, venueForSymbol, venuesFromRows } from './exchanges.ts'
import { pickHomeListing, searchByIsin } from './yahoo.ts'
import { loadFundDirectory } from './edgar.ts'
import {
  BACKLOG_TTL_MINUTES,
  barFrom,
  dedupeBy,
  fetchWithIsolation,
  FINVIZ_SECTOR_IDS,
  loadEquityReturns,
  loadPricesBatched,
  loadProfiles,
  openbbFetcher,
  planPriceFetches,
  PRICE_WINDOW_DAYS,
  PRICES_TTL_MINUTES,
  PROFILE_TTL_MINUTES,
  REFERENCE_TTL_MINUTES,
  RESOURCES,
  SEC_PERF_TTL_MINUTES,
  symbolList,
  throttled,
  TICKERS_TTL_MINUTES,
  type PerfRow,
} from './resources.ts'

const OPENBB_URL = Deno.env.get('OPENBB_API_URL') ?? 'http://openbb-api:6900'
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

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok')

  let resource = 'sector-performance'
  let fundScope: string | undefined
  let figiScope: string | undefined
  let symbolScope: string | undefined
  let exchScope: string | undefined
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
    if (body?.fund) fundScope = String(body.fund).toUpperCase()
    if (body?.figi) figiScope = String(body.figi).trim()
    if (body?.symbol) symbolScope = String(body.symbol).trim()
    // Which venue a promoted ticker lives on. Defaults to US, where the ADRs are.
    if (body?.exchange) exchScope = String(body.exchange).trim()
    if (Number.isFinite(body?.limit)) scopeLimit = Math.max(1, Math.min(1000, Number(body.limit)))
    // `force` bypasses the TTL, NOT the in-flight lock — two concurrent forced
    // refreshes must still collapse into one upstream fetch. Requires the
    // service-role key: the anon key is public, and a public cache-buster is a
    // free way to hammer the provider.
    force = body?.force === true && isServiceRole(req)
  } catch {
    // No body / not JSON — fall back to the default resource.
  }

  const PROFILE_RESOURCE = 'instrument-profile'
  const PRICES_RESOURCE = 'instrument-prices'
  const HOLDINGS_RESOURCE = 'fund-holdings'
  const TICKERS_RESOURCE = 'security-tickers'
  const DERIVE_RESOURCE = 'derive-classifications'
  const SEC_PROFILE_RESOURCE = 'security-profiles'
  const INDUSTRY_RESOURCE = 'security-industries'
  const SEC_PERF_RESOURCE = 'security-performance'
  const LOCAL_SYM_RESOURCE = 'security-local-symbols'
  const LISTINGS_RESOURCE = 'exchange-listings'
  const PROMOTE_RESOURCE = 'promote-listing'
  const ONE_SECURITY_RESOURCE = 'security-refresh'
  const FUNDAMENTALS_RESOURCE = 'security-fundamentals'
  const STATEMENTS_RESOURCE = 'security-statements'
  const YAHOO_SYMBOL_RESOURCE = 'security-yahoo-symbols'
  const SEC_PRICES_RESOURCE = 'security-prices'
  const EXTRA = [
    PROFILE_RESOURCE, PRICES_RESOURCE, HOLDINGS_RESOURCE, TICKERS_RESOURCE, DERIVE_RESOURCE,
    SEC_PROFILE_RESOURCE, SEC_PERF_RESOURCE, LOCAL_SYM_RESOURCE, LISTINGS_RESOURCE,
    INDUSTRY_RESOURCE, PROMOTE_RESOURCE, ONE_SECURITY_RESOURCE, FUNDAMENTALS_RESOURCE, STATEMENTS_RESOURCE,
    YAHOO_SYMBOL_RESOURCE, SEC_PRICES_RESOURCE,
  ]
  const spec = RESOURCES[resource]
  if (!spec && !EXTRA.includes(resource)) {
    return json({ error: `unknown resource '${resource}'`, known: [...Object.keys(RESOURCES), ...EXTRA] }, 400)
  }
  const ttlMinutes = spec
    ? spec.ttlMinutes
    : resource === PRICES_RESOURCE
      ? PRICES_TTL_MINUTES
      // Incremental: each run drains a slice of the backlog, so the TTL must be short enough that
      // the NEXT run is allowed to happen. A completion-shaped TTL here stalls it for a week.
      // Incremental resources, same reasoning as security-tickers: the TTL must be short enough
      // that the NEXT run is allowed to continue the backlog.
      : resource === SEC_PROFILE_RESOURCE || resource === SEC_PERF_RESOURCE || resource === LOCAL_SYM_RESOURCE || resource === LISTINGS_RESOURCE ||
        resource === INDUSTRY_RESOURCE || resource === PROMOTE_RESOURCE ||
        resource === ONE_SECURITY_RESOURCE || resource === FUNDAMENTALS_RESOURCE ||
        resource === STATEMENTS_RESOURCE
        ? BACKLOG_TTL_MINUTES
      : resource === TICKERS_RESOURCE
        ? TICKERS_TTL_MINUTES
      // Reference data, not prices: N-PORT is quarterly, so a short TTL would just re-ask SEC for
      // last quarter's answer. Both of these finish what they start in a single run.
      : resource === HOLDINGS_RESOURCE || resource === DERIVE_RESOURCE
        ? REFERENCE_TTL_MINUTES
        : PROFILE_TTL_MINUTES

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

  // The venue catalog, read ONCE per request after the claim (so a skipped request costs nothing)
  // and passed down to every consumer. `market.exchange` is the single source of truth for
  // exchange code -> country -> provider suffix; it used to be a hardcoded map here AND a second
  // copy in `exchange_cursor`, which had drifted to 54 rows against 38.
  const { data: venueRows, error: venueErr } = await market
    .from('exchange')
    .select('exch_code,country_iso2,suffix')
    .eq('enabled', true)
    .order('preference')
  if (venueErr) return releaseAnd({ error: `exchange catalog read failed: ${venueErr.message}` }, 500)
  const venues = venuesFromRows(venueRows ?? [])

  const fetcher = openbbFetcher(OPENBB_URL)
  // `price_symbol` is the symbol the provider knows when it differs from the
  // display ticker (NESN vs NESN.SW); `symbol` stays the key we write back under.
  const instrumentUniverse = async () => {
    // `priced = false` (cash, a bond yield) has no meaningful price return — skip it
    // so the UI shows no number rather than a misleading one.
    const { data, error } = await market
      .from('instruments')
      .select('symbol,price_symbol')
      .eq('priced', true)
    if (error) throw new Error(`instruments read failed: ${error.message}`)
    return (data ?? []).map((i) => ({
      scopeId: i.symbol as string,
      symbol: (i.price_symbol as string | null) ?? (i.symbol as string),
    }))
  }

  try {
    // The profile refresh writes market.instruments rather than market.performance,
    // so it does not go through the RESOURCES table.
    if (resource === PROFILE_RESOURCE) {
      // Equities only: an ETF, a commodity or a coin has no sector/industry to
      // fetch, and a batch of them can come back empty, which reads as a failure.
      const { data: eq, error: eqErr } = await market
        .from('instruments')
        .select('symbol,price_symbol')
        .eq('asset_type', 'equity')
      if (eqErr) throw new Error(`instruments read failed: ${eqErr.message}`)
      const equities = (eq ?? []).map((i) => ({
        scopeId: i.symbol as string,
        symbol: (i.price_symbol as string | null) ?? (i.symbol as string),
      }))
      const updates = await loadProfiles(fetcher, equities, new Date())
      if (updates.length === 0) throw new Error('no profiles returned')
      // upsert, not update: `symbol` is the PK and every row already exists, but
      // upsert keeps this correct if the universe gains a ticker mid-flight.
      const { error } = await market.from('instruments').upsert(dedupeBy(updates, (u) => String(u.symbol)), { onConflict: 'symbol' })
      if (error) throw new Error(`instruments upsert failed: ${error.message}`)
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, refreshed: updates.length })
    }

    if (resource === HOLDINGS_RESOURCE) {
      // Scope to one fund so a newly added ETF is ingested in seconds instead of
      // waiting for the monthly pass or re-running all 40.
      let symbols: string[]
      if (fundScope) {
        symbols = [fundScope]
      } else {
        const { data, error } = await market
          .from('tracked_fund')
          .select('symbol')
          .eq('enabled', true)
          .order('symbol')
        if (error) throw new Error(`tracked_fund read failed: ${error.message}`)
        symbols = (data ?? []).map((f) => f.symbol as string)
      }
      if (symbols.length === 0) throw new Error('no enabled funds in market.tracked_fund')

      // One shared SEC directory fetch (28k rows) for the whole run.
      const directory = await loadFundDirectory()
      const results = []
      const failures: string[] = []
      let added = 0
      let holdings = 0
      for (const sym of symbols) {
        try {
          const r = await ingestFund(market, sym, directory)
          if (!r) { failures.push(`${sym}: no filing found`); continue }
          results.push(r)
          added += r.securitiesAdded
          holdings += r.holdings
        } catch (e) {
          // One fund's filing being malformed must not lose the other 39.
          failures.push(`${sym}: ${e instanceof Error ? e.message : String(e)}`)
        }
      }
      await market.from('ingest_run').insert({
        source_code: 'sec-nport',
        resource,
        scope: fundScope ?? null,
        finished_at: new Date().toISOString(),
        ok: failures.length < symbols.length,
        securities_added: added,
        holdings_written: holdings,
        error: failures.length ? failures.join(' | ').slice(0, 2000) : null,
      })
      if (results.length === 0) throw new Error(`every fund failed: ${failures.join(' | ').slice(0, 300)}`)
      // Classify from the holdings we just landed. A sector SPDR's holdings ARE that sector, so this
      // needs no provider — but it has to run AFTER the ingest, when the holdings are complete.
      const { data: classified, error: clsErr } = await market.rpc('derive_classifications')
      if (clsErr) throw new Error(`derive_classifications failed: ${clsErr.message}`)
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, funds: results.length, securitiesAdded: added, holdings, classified, failures, results })
    }

    // Standalone so a mapping edited in Studio (tracked_fund.represents_code) takes effect without
    // re-ingesting 38 filings — and so classification can be re-run when the holdings themselves are
    // still inside their 7-day TTL, which is what blocked the first production run.
    if (resource === DERIVE_RESOURCE) {
      const { data: classified, error } = await market.rpc('derive_classifications')
      if (error) throw new Error(`derive_classifications failed: ${error.message}`)
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, classified })
    }

    // Sector for securities NO sector SPDR holds — i.e. everything non-US. Written as a SECOND
    // source (`yfinance`, priority 100) beside the filing-derived one (`sec-nport`, 300), so a
    // security XLK holds keeps its filing sector and everything else gains a provider opinion.
    // Address non-US securities the way the price provider does. This is the root of the whole
    // non-US gap: without a local symbol there is no ticker, so no profile, so no sector and no
    // price — Korea had 10 tickers across 467 securities.
    // Enumerate one exchange per run, resuming from its cursor. A venue is thousands of rows at
    // 100 per request, so this is the same slice-per-run shape as every other backlog — the
    // difference is that the slice boundary is OpenFIGI's own cursor rather than our ordering.
    // Pull one directory listing into the universe. Deliberately creates ONLY identity — the
    // existing backlogs then classify and price it with no new code, which is the whole reason
    // they select on "has a symbol, lacks X" rather than on a fixed list.
    // Everything for ONE security, from the stock page. Scoped rather than universe-wide because
    // the resources it wraps are budgeted for a backlog and would refuse on their TTL, and because
    // fundamentals cost one of 25 daily calls — spending those on what someone is looking at is
    // the only shape that provider supports.
    // Statements are fetched PER SECURITY, not per batch: each of the three endpoints returns one
    // row per PERIOD, and a multi-symbol response would interleave periods from different
    // companies with only a `symbol` field to tell them apart. One symbol at a time keeps the
    // attribution structural rather than something to get right.
    if (resource === STATEMENTS_RESOURCE) {
      const { data: pending, error: pErr } = await market
        .from('pending_statements')
        .select('security_id,symbol')
        .order('best_weight', { ascending: false })
        // 60, because it is three calls PER SECURITY — 180 requests a run, which fills the worker.
        // It was briefly 300 on the assumption that batching worked; it does not (see STMT_BATCH).
        .limit(scopeLimit ?? 60)
      if (pErr) throw new Error(`pending_statements read failed: ${pErr.message}`)
      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        symbol: r.symbol as string,
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'every security has statements' })
      }

      const deadline = Date.now() + 60_000
      let written = 0
      let none = 0
      let failed = 0
      let throttledOut = false

      // BATCHED, at ten symbols a call.
      //
      // This fetched ONE security at a time — three calls each, for income, balance and cash — on
      // the reasoning that a multi-symbol response "interleaves periods from different companies
      // with only a `symbol` to separate them". A symbol IS enough to separate them: it is exactly
      // how `security-fundamentals` and `security-performance` attribute their batched responses,
      // and `equity/fundamental/metrics` — the same router family, the same provider — has been
      // called with `symbolList()` all along.
      //
      // The cost of not batching was the whole schedule: 60 securities a run against a backlog of
      // 8,851, four cron runs a day, is about five weeks. Ten per call makes it days.
      //
      // NOT ASSUMED, THOUGH. `symbolsAnswered` counts the distinct symbols a batched response
      // actually attributes, and it is reported: if this provider silently answers for only the
      // first symbol, that number is 1 per batch and says so on the first run. The failure mode
      // if it does is a backlog that does not drain — visible and harmless — rather than
      // securities wrongly marked, because marking still requires the run to have written
      // something.
      // ONE. Measured 2026-08-13 the moment the batched version deployed:
      //
      //   symbolsAsked 50   symbolsAnswered 0   written 0   failed 0   none 0
      //
      // `equity/fundamental/income|balance|cash` do NOT accept several symbols, even though
      // `equity/fundamental/metrics` — same router family, same provider — does. That is precisely
      // the "route convention is not perfectly regular" warning in CLAUDE.md, and I batched on the
      // family resemblance rather than a measurement.
      //
      // The reporting is what made this a five-minute revert instead of a silent outage: `written`
      // and `none` both zero says the run did nothing AND blamed nobody, and `symbolsAnswered` says
      // why. Keep them — if a future openbb release makes these endpoints batch, this number will
      // say so.
      const STMT_BATCH = 1
      const symbolsAnswered = new Set<string>()
      for (let i = 0; i < wanted.length && Date.now() < deadline - 6_000; i += STMT_BATCH) {
        const group = wanted.slice(i, i + STMT_BATCH)
        const bySymbol = new Map(group.map((g) => [g.symbol.toUpperCase(), g]))
        const rowsFor = new Map<string, Record<string, unknown>[]>()
        const answered = new Set<string>()

        for (const kind of ['income', 'balance', 'cash'] as const) {
          const remaining = deadline - Date.now()
          if (remaining < 5_000) break
          try {
            const got = await fetcher(
              `/api/v1/equity/fundamental/${kind}?symbol=${symbolList(group.map((g) => g.symbol))}` +
                `&provider=yfinance&limit=4`,
              Math.min(20_000, remaining),
            )
            for (const r of got) {
              // Attributed BY SYMBOL, never by position: the provider returns a row per period, so
              // a batch is inherently out of order and positional pairing would file one company's
              // balance sheet under another's name.
              const sym = String(r.symbol ?? (group.length === 1 ? group[0].symbol : '')).toUpperCase()
              const item = bySymbol.get(sym)
              if (!item) continue
              answered.add(sym)
              symbolsAnswered.add(sym)
              const period = String(r.period_ending ?? r.date ?? '').slice(0, 10)
              if (!period) continue
              const list = rowsFor.get(sym) ?? []
              list.push({
                security_id: item.securityId,
                statement: kind,
                period_ending: period,
                period_type: r.fiscal_period ? String(r.fiscal_period) : null,
                currency: r.reported_currency ? String(r.reported_currency) : null,
                data: r,
                source_code: 'yfinance',
                as_of: new Date().toISOString(),
              })
              rowsFor.set(sym, list)
            }
          } catch (e) {
            failed++
            const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
            // Same rule as everywhere else: a refusal is about the endpoint, not these securities.
            if (throttled(msg)) { throttledOut = true; break }
          }
        }
        if (throttledOut) break

        for (const item of group) {
          const sym = item.symbol.toUpperCase()
          const rows = rowsFor.get(sym) ?? []
          const anyAnswer = answered.has(sym)

        if (rows.length > 0) {
          const { error } = await market
            .from('security_statement')
            .upsert(dedupeBy(rows, (r) => `${r.security_id}|${r.statement}|${r.period_ending}`),
              { onConflict: 'security_id,statement,period_ending' })
          if (error) throw new Error(`security_statement upsert failed: ${error.message}`)
          written += rows.length
        } else if (anyAnswer || (failed === 0 && written > 0)) {
          // Answered with nothing, rather than not answered at all — record it so this security
          // stops being re-asked. A provider failure is NOT marked, or one outage would silence
          // thousands of companies for a month.
          //
          // `failed === 0` ALONE WAS THE HOLE, and it is a big one: when a throttled provider
          // answers 200-with-no-rows instead of erroring, nothing fails and nothing answers, so
          // this marked every security it touched. 5,613 carried `statements_missing_at` from a
          // single afternoon. `written > 0` is the missing half — proof the endpoint produced rows
          // for SOMEONE in this run, not merely that it declined to throw.
          none++
          const { error } = await market
            .from('security')
            .update({ statements_missing_at: new Date().toISOString() })
            .eq('security_id', item.securityId)
          if (error) throw new Error(`statements_missing_at update failed: ${error.message}`)
        }
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        written,
        none,
        failed,
        throttledOut,
        // THE EVIDENCE THAT BATCHING WORKS, reported rather than assumed. This endpoint family was
        // only ever called one symbol at a time here, so nothing had established that
        // `income`/`balance`/`cash` attribute a multi-symbol response the way `metrics` does. If
        // this comes back at roughly one per batch, the provider is answering for the first symbol
        // only and the batch size must go back to 1.
        symbolsAnswered: symbolsAnswered.size,
        symbolsAsked: wanted.length,
        remaining: Math.max(0, wanted.length - written),
      })
    }

    if (resource === FUNDAMENTALS_RESOURCE) {
      const { data: pending, error: pErr } = await market
        .from('pending_fundamentals')
        .select('security_id,symbol')
        .order('best_weight', { ascending: false })
        .limit(scopeLimit ?? PROFILE_BACKLOG_PAGE)
      if (pErr) throw new Error(`pending_fundamentals read failed: ${pErr.message}`)
      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        symbol: r.symbol as string,
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'every security has fundamentals' })
      }

      const deadline = Date.now() + 60_000
      const BATCH = 10
      let written = 0
      let missing = 0
      let batchesFailed = 0
      let throttledOut = false
      let emptyBatches = 0
      let lastError: string | null = null
      // Market caps recovered from the metrics response, which carries one for the non-US
      // listings `equity/profile` does not.
      let capped = 0

      for (let i = 0; i < wanted.length && Date.now() < deadline; i += BATCH) {
        const batch = wanted.slice(i, i + BATCH)
        const remaining = deadline - Date.now()
        if (remaining < 3_000) break
        let rows: Record<string, unknown>[] = []
        let deadSymbols: string[] = []
        try {
          // ISOLATE. Measured 2026-08-12: ALL 60 batches of a 600-row page failed with
          //   openbb 400 ... {"detail":"Error getting data for 2689.HK -> YFR..."}
          // One symbol the provider cannot answer for 400s the whole batch, so nothing was written
          // and nothing negative-cached — the backlog sat at 6,075 through repeated runs while
          // every count stayed plausible. `security-industries` got this fix in the morning and
          // this call site did not; a rule at one call site is not a rule.
          const got = await fetchWithIsolation(
            fetcher,
            (syms) => `/api/v1/equity/fundamental/metrics?symbol=${symbolList(syms)}&provider=yfinance`,
            batch.map((b) => b.symbol),
            Math.min(20_000, remaining),
            deadline,
          )
          rows = got.rows
          deadSymbols = got.dead
          if (got.error) {
            batchesFailed++
            lastError = got.error
            // STOP THE RUN ON A THROTTLE — do not spend the rest of the page on it.
            //
            // A rate limit is not a per-batch accident: once yfinance is refusing us, every
            // remaining batch fails too. Measured 2026-08-13 — `security-fundamentals` reads 600
            // rows at BATCH 10, so a throttled run fired SIXTY requests, failed all sixty, wrote
            // nothing, and each of those requests pushed the limit further out. `batchesFailed: 60`
            // with `written: 0`, repeatedly.
            //
            // Breaking turns that into one failed request and an early return. The backlog is
            // incremental, so a short run costs nothing; the next one starts where this stopped.
            if (throttled(got.error)) { throttledOut = true; break }
            // THE BATCH FAILED — that is not the same as the provider having nothing to say. With
            // nothing returned and nothing individually blamed, `fetchWithIsolation` has already
            // judged this an outage, and falling through to the empty-answer branch below would
            // negative-cache the whole page on the strength of a failed request.
            //
            // Measured 2026-08-12, immediately after shipping the isolation fix: `written: 0,
            // missing: 600` — 600 securities marked unanswerable for 30 days because every batch
            // 400'd. Same defect as the morning's 1,369, in a new place, introduced by the fix for
            // the old one. `got.dead` was correctly empty; this path ignored that and marked anyway.
            if (rows.length === 0 && deadSymbols.length === 0) continue
          }
        } catch (e) {
          // The reason was being DISCARDED here, which is why this took four wrong guesses to
          // narrow: the log only ever said "returned nothing for all N batches", and the same
          // message covers a timeout, a refused connection and a malformed URL.
          batchesFailed++
          lastError = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          // Same rule as the isolation path: once the provider is refusing us, the rest of
          // the page will refuse too, and each attempt pushes the limit further out.
          if (throttled(lastError)) { throttledOut = true; break }
          continue
        }
        // A symbol the provider refuses ON ITS OWN is unanswerable, so stop asking. Without this
        // the isolation pass would rescue the batch and the poison symbol would return next run,
        // costing an extra request per run forever.
        if (deadSymbols.length > 0) {
          const deadIds = batch
            .filter((b) => deadSymbols.includes(b.symbol))
            .map((b) => b.securityId)
          const { error } = await market
            .from('security')
            .update({ fundamentals_missing_at: new Date().toISOString() })
            .in('security_id', deadIds)
          if (error) throw new Error(`fundamentals_missing_at update failed: ${error.message}`)
          missing += deadIds.length
        }

        // An empty answer is NOT a failure — it means the provider has nothing for these symbols.
        // Counting it as one meant they were never negative-cached, so they were re-asked every
        // run and the guard below eventually failed the whole resource on them.
        // Excludes anything the isolation pass just recorded, so one batch cannot be counted twice
        // (the `noIndustry: 23 for a batch of 20` tally bug, in a second place).
        // ...BUT ONLY ONCE THIS ENDPOINT HAS ANSWERED FOR SOMEONE IN THIS RUN.
        //
        // An empty answer is a legitimate "no data for these" — right up until the endpoint stops
        // answering at all, when it becomes "no data for anyone" and marking a batch on it is how a
        // provider hiccup gets recorded as hundreds of permanently unanswerable securities.
        //
        // MEASURED, NOT HYPOTHETICAL — this is what it did on 2026-08-13. Draining hard enough to
        // trip yfinance's rate limit made it answer 200-with-no-rows rather than erroring, so
        // `fetchWithIsolation`'s outage rule (which only sees THROWS) never fired, and this branch
        // marked **1,414 securities** as having no industry. Among them: INTC, PEP, XOM, TXN, EA,
        // SCCO. The largest companies in the United States, recorded as unclassifiable, silently,
        // while the backlog went to zero and looked drained.
        if (rows.length === 0) {
          emptyBatches++
          if (written > 0) {
            const { error } = await market
              .from('security')
              .update({ fundamentals_missing_at: new Date().toISOString() })
              .in('security_id', batch.filter((b) => !deadSymbols.includes(b.symbol)).map((b) => b.securityId))
            if (error) throw new Error(`fundamentals_missing_at update failed: ${error.message}`)
            missing += batch.filter((b) => !deadSymbols.includes(b.symbol)).length
          }
          continue
        }

        // Mapped BY SYMBOL, never by index: the provider returns the rows out of order (asking for
        // AAPL,MSFT,SAP came back MSFT,AAPL,SAP), so positional pairing would attach one company's
        // fundamentals to another.
        const bySymbol = new Map(batch.map((b) => [b.symbol.toUpperCase(), b.securityId]))
        const writes: Record<string, unknown>[] = []
        const answered = new Set<string>()
        for (const r of rows) {
          const id = bySymbol.get(String(r.symbol ?? '').toUpperCase())
          if (!id) continue
          answered.add(id)
          const n = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : null)
          writes.push({
            security_id: id,
            source_code: 'yfinance',
            as_of: new Date().toISOString(),
            pe_ratio: n(r.pe_ratio),
            forward_pe: n(r.forward_pe),
            peg_ratio: n(r.peg_ratio),
            price_to_book: n(r.price_to_book),
            profit_margin: n(r.profit_margin),
            gross_margin: n(r.gross_margin),
            operating_margin: n(r.operating_margin),
            return_on_equity: n(r.return_on_equity),
            revenue_growth: n(r.revenue_growth),
            debt_to_equity: n(r.debt_to_equity),
            dividend_yield: n(r.dividend_yield),
            beta: n(r.beta),
            enterprise_value: n(r.enterprise_value),
            raw: r,
          })
        }
        if (writes.length > 0) {
          const { error } = await market
            .from('security_fundamentals')
            .upsert(dedupeBy(writes, (w) => String(w.security_id)), { onConflict: 'security_id' })
          if (error) throw new Error(`fundamentals upsert failed: ${error.message}`)
          written += writes.length

          // The metrics response names the currency and the statement endpoints do not, so this is
          // where a security learns what its figures are denominated in. Without it a KRW income
          // statement renders with a dollar sign.
          //
          // LEARN THE CURRENCY BEFORE REFERENCING IT. `security.currency_code` is a foreign key to
          // `market.currency`, so a code that table has never seen does not fail one row — it fails
          // the statement, and this handler turns that into a failed resource:
          //   currency_code update failed: insert or update on table "security" violates foreign
          //   key constraint "security_currency_code_fkey"
          // Caught in production 2026-08-12, minutes after symbol resolution began reaching Saudi,
          // Malaysian and Chilean listings and therefore currencies the filings had never carried.
          //
          // `ingest.ts` already does exactly this for N-PORT ("Lookup values are DISCOVERED from
          // filings, not seeded... an unseen currency would fail the whole insert"). It is the same
          // rule, at a call site it had not reached — the third time today that a rule living in
          // one place failed to hold in another.
          const seen = [...new Set(
            writes
              .map((w) => (w.raw as Record<string, unknown> | undefined)?.currency)
              .filter((c): c is string => typeof c === 'string' && /^[A-Za-z]{3}$/.test(c))
              .map((c) => c.toUpperCase()),
          )]
          if (seen.length > 0) {
            const { error: curErr } = await market
              .from('currency')
              .upsert(seen.map((code) => ({ code })), { onConflict: 'code', ignoreDuplicates: true })
            if (curErr) throw new Error(`currency learn failed: ${curErr.message}`)
          }

          for (const w of writes) {
            const raw = (w.raw as Record<string, unknown> | undefined)?.currency
            if (typeof raw !== 'string' || !/^[A-Za-z]{3}$/.test(raw)) continue
            const cur = raw.toUpperCase()
            // THE PROVIDER WINS, and this is the one place a filing does not.
            //
            // N-PORT's `curCd` is the currency the FUND valued the position in — for a US-domiciled
            // fund that is frequently USD regardless of where the security trades. The provider
            // reports the quote currency of the symbol we asked about, which IS the security's own
            // currency by construction.
            //
            // Measured 2026-08-13: of 1,000 securities with fundamentals, 14 disagreed and every
            // one was `stored=USD` against `provider=PEN/CLP/BRL/EUR` — Peruvian, Chilean and
            // Brazilian securities labelled in dollars. That mislabels the figures the stock page
            // renders, which is exactly what the currency work fixed for everything else.
            //
            // Previously `.is('currency_code', null)` meant the first value ever written stuck, so
            // an early wrong N-PORT currency was permanent.
            // `.neq()` alone would skip every row where the column is NULL — SQL comparisons
            // against NULL are never true, and NULL is the majority case here. `.or()` covers both
            // "never set" and "set to something the provider disagrees with".
            const { error: cErr } = await market
              .from('security')
              .update({ currency_code: cur })
              .eq('security_id', w.security_id as string)
              .or(`currency_code.is.null,currency_code.neq.${cur}`)
            if (cErr) throw new Error(`currency_code update failed: ${cErr.message}`)
          }

          // MARKET CAP IS IN THIS RESPONSE TOO, and it was being written to `raw` and nowhere else.
          //
          // `security.market_cap` is filled by `security-profiles` from `equity/profile`, which
          // does not carry a cap for most non-US listings — so coverage sat at 8,163 of 12,348
          // (66%) with `market_cap_at` unset for the rest, i.e. no attempt ever recorded. Measured
          // 2026-08-14: **2,871 of the 2,952 equities that have a sector but no cap already had
          // one sitting in `security_fundamentals.raw.market_cap`**, fetched by this resource and
          // discarded — COSCO Shipping, HEXPOL, Emmi, Jinxin Fertility. Writing it here takes
          // coverage to ~89% with no new upstream call.
          //
          // Fourth time the answer was already inside a response we fetch: market cap from the
          // profile, the operating country from the profile, the currency from these metrics, and
          // now the cap from these metrics. Look at what a response CONTAINS before concluding a
          // field needs a provider.
          //
          // Denominated in the security's own currency, exactly like the profile's value — which
          // is why `market-verify`'s mega-cap check is US-only and must stay so.
          for (const w of writes) {
            const raw = w.raw as Record<string, unknown> | undefined
            const cap = Number(raw?.market_cap)
            if (!Number.isFinite(cap) || cap <= 0) continue
            const { error: mErr } = await market
              .from('security')
              .update({ market_cap: cap, market_cap_at: new Date().toISOString() })
              .eq('security_id', w.security_id as string)
            if (mErr) throw new Error(`market_cap update failed: ${mErr.message}`)
            capped++
          }
        }
        const missed = batch.map((b) => b.securityId).filter((id) => !answered.has(id))
        if (missed.length > 0) {
          missing += missed.length
          const { error } = await market
            .from('security')
            .update({ fundamentals_missing_at: new Date().toISOString() })
            .in('security_id', missed)
          if (error) throw new Error(`fundamentals_missing_at update failed: ${error.message}`)
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      // No longer THROWS when nothing was written. A run that legitimately finds only
      // unanswerable securities is not a failure, and failing the resource on it is what stopped
      // the backlog dead once the answerable ones were done. The counters say what happened.
      return json({
        resource, written, missing, capped, emptyBatches, batchesFailed, lastError, throttledOut,
        remaining: Math.max(0, wanted.length - written - missing),
      })
    }

    if (resource === ONE_SECURITY_RESOURCE) {
      const wanted = String(symbolScope ?? '').trim().toUpperCase()
      if (!wanted) return releaseAnd({ error: 'security-refresh needs a `symbol`' }, 400)

      const { data: rows, error: findErr } = await market
        .from('security_current')
        .select('security_id,symbol,name')
        .eq('symbol', wanted)
        .limit(1)
      if (findErr) throw new Error(`security lookup failed: ${findErr.message}`)
      let target = (rows ?? [])[0]

      // Fall back to the PROVIDER symbol. A non-US security often has no `ticker` identifier at
      // all — only `005930.KS` in security_provider_symbol — so a display-symbol lookup alone
      // reports "unknown symbol" for a security we hold.
      if (!target) {
        const { data: viaProvider } = await market
          .from('security_provider_symbol')
          .select('security_id')
          .eq('provider_code', 'yfinance')
          .eq('symbol', wanted)
          .maybeSingle()
        if (viaProvider?.security_id) {
          target = { security_id: viaProvider.security_id, symbol: wanted, name: null }
        }
      }
      if (!target) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, symbol: wanted, refreshed: false, reason: 'unknown symbol' })
      }
      const securityId = target.security_id as string

      // The address the price provider knows, which is not always the display ticker.
      const { data: ps } = await market
        .from('security_provider_symbol')
        .select('symbol')
        .eq('security_id', securityId)
        .eq('provider_code', 'yfinance')
        .maybeSingle()
      const fetchSymbol = (ps?.symbol as string | undefined) ?? wanted

      const out: Record<string, unknown> = { resource, symbol: wanted }

      // 1. Returns.
      try {
        const perf = await loadEquityReturns(fetcher, [fetchSymbol], new Date(), SEC_PERF_TTL_MINUTES, 15_000)
        const rowsOut = perf.map((r) => ({ ...r, scope_id: wanted }))
        if (rowsOut.length > 0) {
          const { error } = await market
            .from('performance')
            .upsert(dedupeBy(rowsOut, (r) => `${r.scope}|${r.scope_id}|${r.period}`),
            { onConflict: 'scope,scope_id,period' })
          if (error) throw new Error(`performance upsert failed: ${error.message}`)
        }
        out.returns = rowsOut.length
      } catch (e) {
        out.returnsError = e instanceof Error ? e.message.slice(0, 160) : String(e).slice(0, 160)
      }

      // 2. Profile: market cap, and the sector if it is still missing.
      try {
        const prof = await fetcher(
          `/api/v1/equity/profile?symbol=${encodeURIComponent(fetchSymbol)}&provider=yfinance`,
          15_000,
        )
        const cap = Number(prof[0]?.market_cap)
        if (Number.isFinite(cap) && cap > 0) {
          const { error } = await market
            .from('security')
            .update({ market_cap: cap, market_cap_at: new Date().toISOString() })
            .eq('security_id', securityId)
          if (error) throw new Error(`market_cap update failed: ${error.message}`)
          out.marketCap = cap
        }
      } catch (e) {
        out.profileError = e instanceof Error ? e.message.slice(0, 160) : String(e).slice(0, 160)
      }

      // 3. Fundamentals — keyless, and it covers the non-US listings that defeated every provider
      //    we hold a key for. Fetched by the PROVIDER symbol, like prices.
      try {
        const f = await fetchFundamentals(fetcher, fetchSymbol, 15_000)
        if (!f) out.fundamentals = 'not covered'
        else {
          const { error } = await market.from('security_fundamentals').upsert(
            {
              security_id: securityId,
              source_code: 'yfinance',
              as_of: new Date().toISOString(),
              pe_ratio: f.peRatio ?? null,
              forward_pe: f.forwardPe ?? null,
              peg_ratio: f.pegRatio ?? null,
              price_to_book: f.priceToBook ?? null,
              profit_margin: f.profitMargin ?? null,
              gross_margin: f.grossMargin ?? null,
              operating_margin: f.operatingMargin ?? null,
              return_on_equity: f.returnOnEquity ?? null,
              revenue_growth: f.revenueGrowth ?? null,
              debt_to_equity: f.debtToEquity ?? null,
              dividend_yield: f.dividendYield ?? null,
              beta: f.beta ?? null,
              enterprise_value: f.enterpriseValue ?? null,
              raw: f.raw,
            },
            { onConflict: 'security_id' },
          )
          if (error) throw new Error(`fundamentals upsert failed: ${error.message}`)
          out.fundamentals = 'updated'
        }
      } catch (e) {
        out.fundamentalsError = e instanceof Error ? e.message.slice(0, 160) : String(e).slice(0, 160)
      }

      // 4. STATEMENTS, because on demand is the only route that reaches them in a useful time.
      //
      // `security-statements` fetches ONE security at a time — three calls each, and the endpoints
      // do not accept several symbols (measured: `symbolsAsked 50, symbolsAnswered 0`). At 60 a run
      // and four cron passes a day, an 8,791-deep backlog is about five weeks. So the securities a
      // person actually opens would be among the last to get statements, which is exactly backwards.
      //
      // This costs three requests on a button a person pressed, for the one security they are
      // looking at. The backlog stays as the background sweep; this is what makes the wait
      // irrelevant for anything anyone cares about.
      try {
        const stRows: Record<string, unknown>[] = []
        for (const kind of ['income', 'balance', 'cash'] as const) {
          const got = await fetcher(
            `/api/v1/equity/fundamental/${kind}?symbol=${encodeURIComponent(fetchSymbol)}` +
              `&provider=yfinance&limit=4`,
            12_000,
          )
          for (const r of got) {
            const period = String(r.period_ending ?? r.date ?? '').slice(0, 10)
            if (!period) continue
            stRows.push({
              security_id: securityId,
              statement: kind,
              period_ending: period,
              period_type: r.fiscal_period ? String(r.fiscal_period) : null,
              currency: r.reported_currency ? String(r.reported_currency) : null,
              data: r,
              source_code: 'yfinance',
              as_of: new Date().toISOString(),
            })
          }
        }
        if (stRows.length === 0) out.statements = 'not covered'
        else {
          const { error } = await market.from('security_statement').upsert(
            dedupeBy(stRows, (r) => `${r.security_id}|${r.statement}|${r.period_ending}`),
            { onConflict: 'security_id,statement,period_ending' },
          )
          if (error) throw new Error(`security_statement upsert failed: ${error.message}`)
          out.statements = `${stRows.length} rows`
        }
      } catch (e) {
        // Deliberately NOT written to `statements_missing_at`. A failure on a button press says
        // nothing about whether the provider has statements for this security, and marking here
        // would exclude it from the backlog for 30 days on the strength of one bad request.
        out.statementsError = e instanceof Error ? e.message.slice(0, 160) : String(e).slice(0, 160)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ ...out, refreshed: true })
    }

    if (resource === PROMOTE_RESOURCE) {
      let figi = String(figiScope ?? '').trim()

      // PROMOTE BY TICKER, without waiting for the venue to be enumerated. The directory route
      // needs the sweep to have reached the listing and it pages no deeper than 15,000, so `BABA`
      // was unreachable that way while being one `/v3/mapping` call away. Promotion only ever
      // needed the FIGI.
      const tickerArg = String(symbolScope ?? '').trim().toUpperCase()
      const exchArg = String(exchScope ?? 'US').trim().toUpperCase()
      // What the mapping told us, kept so the security can be created from it when the sweep has
      // not reached this listing. Resolving the FIGI alone is HALF A FEATURE: `untracked_listing`
      // is built from `exchange_listing`, so a ticker the directory has never enumerated resolves
      // and then promotes nothing. Measured on the first BABA attempt: `figi BBG006G2JVL2,
      // promoted: false, reason: already tracked or unknown figi` — the FIGI was right and there
      // was simply no row to promote.
      let mapped: { name?: string; compositeFigi?: string; securityType?: string } | undefined
      if (!figi && tickerArg) {
        const hits = await mapTickers(
          [{ ticker: tickerArg, exchCode: exchArg }],
          { apiKey: Deno.env.get('OPENFIGI_API_KEY') ?? undefined },
        )
        mapped = hits[0]
        if (!mapped?.compositeFigi) {
          return json({
            resource, ticker: tickerArg, promoted: false,
            reason: 'OpenFIGI has no listing for that ticker on that exchange',
          })
        }
        figi = mapped.compositeFigi
      }

      if (!figi) return releaseAnd({ error: 'promote-listing needs a `figi` or a `symbol`' }, 400)

      const { data: listing, error: lErr } = await market
        .from('untracked_listing')
        .select('figi,composite_figi,exch_code,ticker,name,country_iso2,provider_symbol')
        .eq('figi', figi)
        .maybeSingle()
      if (lErr) throw new Error(`untracked_listing read failed: ${lErr.message}`)
      // Already promoted is a SUCCESS, not an error: two people tapping the same row should not
      // produce a failure for the second one.
      // Is it already ours? Then this is a SUCCESS, not an error — two people tapping the same row
      // must not fail for the second one.
      const { data: existing, error: exErr } = await market
        .from('security_identifier')
        .select('security_id')
        .eq('kind_code', 'figi')
        .eq('value', figi)
        .maybeSingle()
      if (exErr) throw new Error(`security_identifier read failed: ${exErr.message}`)
      if (existing) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, figi, promoted: false, reason: 'already tracked' })
      }

      // NOT IN THE DIRECTORY, BUT NAMED BY A PERSON. Build the row from the mapping response
      // instead of refusing: that is the whole point of promoting by ticker, since the US alone
      // holds 20,107 common stocks and OpenFIGI pages to 15,000, so waiting for the sweep is not an
      // answer for "this major company should be here".
      const source = listing ?? (mapped
        ? {
            figi,
            composite_figi: figi,
            exch_code: exchArg,
            ticker: tickerArg,
            name: mapped.name ?? tickerArg,
            // The mapping response carries no country. Left NULL rather than guessed — the country
            // a security is FILED under is not one to invent, and `security-profiles` fills it.
            country_iso2: null,
            // No suffix for a US listing; anywhere else the local-symbol backlog resolves it.
            provider_symbol: exchArg === 'US' ? tickerArg : null,
          }
        : null)

      if (!source) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, figi, promoted: false, reason: 'unknown figi and no ticker to map' })
      }

      const securityId = crypto.randomUUID()
      const { error: sErr } = await market.from('security').insert({
        security_id: securityId,
        name: source.name,
        security_type_code: 'equity',
        country_iso2: source.country_iso2 ?? null,
        is_tradeable: true,
      })
      if (sErr) throw new Error(`security insert failed: ${sErr.message}`)

      // FIGI first — it is what stops this listing being offered as untracked again.
      const identifiers = [
        { kind_code: 'figi', value: source.composite_figi ?? source.figi, security_id: securityId, source_code: 'openfigi' },
        { kind_code: 'ticker', value: source.ticker, security_id: securityId, source_code: 'openfigi' },
      ]
      const { error: iErr } = await market
        .from('security_identifier')
        .upsert(identifiers, { onConflict: 'kind_code,value', ignoreDuplicates: true })
      if (iErr) throw new Error(`identifier insert failed: ${iErr.message}`)

      if (source.provider_symbol) {
        const { error: pErr } = await market.from('security_provider_symbol').upsert(
          { security_id: securityId, provider_code: 'yfinance', symbol: source.provider_symbol },
          { onConflict: 'security_id,provider_code', ignoreDuplicates: true },
        )
        if (pErr) throw new Error(`provider symbol insert failed: ${pErr.message}`)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        figi,
        promoted: true,
        securityId,
        symbol: source.provider_symbol ?? source.ticker,
        note: 'sector and returns arrive on the next security-profiles / security-performance run',
      })
    }

    if (resource === LISTINGS_RESOURCE) {
      const { data: cursors, error: curErr } = await market
        .from('exchange_cursor')
        .select('exch_code,country_iso2,suffix,next_cursor,last_run_at,security_type,query_prefix')
        .eq('enabled', true)
        // Least recently run first, so no venue is starved by the ones before it. A venue
        // mid-enumeration (next_cursor set) is finished before a fresh one is started.
        .order('next_cursor', { ascending: false, nullsFirst: false })
        .order('last_run_at', { ascending: true, nullsFirst: true })
        .limit(1)
      if (curErr) throw new Error(`exchange_cursor read failed: ${curErr.message}`)
      const target = (cursors ?? [])[0]
      if (!target) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, note: 'no enabled exchanges' })
      }

      const exch = target.exch_code as string
      const suffix = (target.suffix as string | null) ?? ''
      // WHICH KIND OF INSTRUMENT THIS VENUE IS PART-WAY THROUGH. Sweeping only `Common Stock` loses
      // every ADR: `BABA` is `securityType2: 'Depositary Receipt'`, which is why a 15,000-row US
      // sweep held `BABB`, `BABAF` and `BABYF` but not `BABA` — and the same for TSM, NVO and every
      // other foreign company's US line, the exact names someone expects to find.
      const secType = (target.security_type as string | null) ?? 'Common Stock'
      // NULL means "sweep the venue whole"; a prefix means it is too large for one query.
      const prefix = (target.query_prefix as string | null) ?? undefined
      const { listings, next, pages, total, throttled: figiThrottled } = await listExchange(
        exch,
        (target.next_cursor as string | null) ?? undefined,
        {
          apiKey: Deno.env.get('OPENFIGI_API_KEY') ?? undefined,
          securityType2: secType,
          query: prefix,
        },
      )

      let written = 0
      for (let i = 0; i < listings.length; i += 500) {
        const chunk = listings.slice(i, i + 500).map((l) => ({
          figi: l.figi,
          composite_figi: l.compositeFigi ?? null,
          exch_code: exch,
          ticker: l.ticker,
          name: l.name ?? null,
          security_type: l.securityType ?? null,
          country_iso2: target.country_iso2 ?? null,
          provider_symbol: `${l.ticker}${suffix}`,
          last_seen_at: new Date().toISOString(),
        }))
        const { error } = await market.from('exchange_listing').upsert(dedupeBy(chunk, (c) => String(c.figi)), { onConflict: 'figi' })
        if (error) throw new Error(`exchange_listing upsert failed: ${error.message}`)
        written += chunk.length
      }

      // When a TYPE is exhausted, advance to the next one rather than declaring the venue done.
      // The list is a table, so adding "Preferred Stock" later is a row rather than a deploy.
      // WHERE TO GO NEXT — three nested dimensions: page -> prefix -> type.
      let nextType = secType
      let nextPrefix: string | null = prefix ?? null

      // Too big to page through whole, so take it in slices. Decided from the `total` the API
      // itself reports rather than a list of "big" exchanges: Athens has 606 listings and slicing
      // it into 36 would be 36 requests to fetch what one gets.
      if (!prefix && (total ?? 0) > PAGING_CEILING) {
        const { data: first, error: pErr } = await market
          .from('exchange_sweep_partition')
          .select('prefix,sort_order')
          .order('sort_order')
          .limit(1)
        if (pErr) throw new Error(`exchange_sweep_partition read failed: ${pErr.message}`)
        nextPrefix = (first?.[0]?.prefix as string | undefined) ?? null
      } else if (!next) {
        const { data: parts, error: pErr } = await market
          .from('exchange_sweep_partition')
          .select('prefix,sort_order')
          .order('sort_order')
        if (pErr) throw new Error(`exchange_sweep_partition read failed: ${pErr.message}`)
        const prefixes = (parts ?? []).map((r) => r.prefix as string)

        if (prefix) {
          const at = prefixes.indexOf(prefix)
          nextPrefix = at >= 0 && at + 1 < prefixes.length ? prefixes[at + 1] : null
        }

        // Only advance the TYPE once the prefixes are exhausted (or there were none).
        if (!nextPrefix) {
          const { data: types, error: tErr } = await market
            .from('exchange_sweep_type')
            .select('security_type,sort_order')
            .order('sort_order')
          if (tErr) throw new Error(`exchange_sweep_type read failed: ${tErr.message}`)
          const order = (types ?? []).map((t) => t.security_type as string)
          const at = order.indexOf(secType)
          // Past the last type, wrap to the first: the directory is a living thing, and a venue
          // swept months ago should eventually be re-enumerated for new listings.
          nextType = order.length === 0 ? secType : order[(at + 1) % order.length]
        }
      }

      const { error: updErr } = await market
        .from('exchange_cursor')
        .update({
          // A null cursor means this TYPE is exhausted, so the next run starts the next type rather
          // than resuming a page that no longer exists.
          next_cursor: next ?? null,
          security_type: nextType,
          query_prefix: next ? (prefix ?? null) : nextPrefix,
          last_run_at: new Date().toISOString(),
          // ONLY RECORD A COUNT A RUN ACTUALLY PRODUCED. `listings: written` unconditionally meant
          // a refused run overwrote the venue's total with zero: Japan went 1,800 -> 0 on a run
          // that fetched nothing, destroying the only record of what had been swept there. A run
          // that wrote nothing has nothing to say about the venue, so it says nothing.
          ...(written > 0 ? { listings: written } : {}),
        })
        .eq('exch_code', exch)
      if (updErr) throw new Error(`exchange_cursor update failed: ${updErr.message}`)

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      // `throttled` is reported, not folded into `complete`. A refused run and an exhausted venue
      // both come back with no listings, and telling them apart is the whole point: without it,
      // `written: 0, pages: 0, complete: false` reads as "nothing to do" and a sweep that is being
      // refused looks exactly like one that is finished.
      return json({
        resource, exchange: exch, written, pages, total,
        complete: !next && !figiThrottled,
        throttled: figiThrottled,
      })
    }

    if (resource === LOCAL_SYM_RESOURCE) {
      const wanted: { securityId: string; isin: string; countryIso2: string }[] = []
      for (let page = 0; page < 3; page++) {
        const { data, error } = await market
          .from('pending_local_symbol')
          .select('security_id,isin,country_iso2')
          .order('best_weight', { ascending: false })
          // A SECOND, UNIQUE SORT KEY — without it these pages are not a partition.
          // `best_weight` is 0 for every security no tracked fund holds, which is most of this
          // backlog, and Postgres gives no stable order among ties: two `range()` calls can return
          // the same row twice and never return another. Re-processing is harmless (the writes are
          // idempotent) but the SKIPPED rows are not — they sit at a page boundary the resource
          // never reaches, which looks exactly like a backlog that has stopped draining.
          .order('security_id', { ascending: true })
          .range(page * 1000, (page + 1) * 1000 - 1)
        if (error) throw new Error(`pending_local_symbol read failed: ${error.message}`)
        const rows = data ?? []
        wanted.push(...rows.map((r) => ({
          securityId: r.security_id as string,
          isin: r.isin as string,
          countryIso2: r.country_iso2 as string,
        })))
        if (rows.length < 1000) break
      }
      // Only countries we know how to address; the rest would resolve to a symbol yfinance does
      // not recognise, which yields an empty series that looks like an outage.
      const addressable = wanted.filter((w) => hasLocalExchange(w.countryIso2, venues))
      if (addressable.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, resolved: 0, remaining: 0, note: 'no addressable securities pending' })
      }

      const { resolvedCount, requestsUsed, unresolved } = await mapIsinsToLocalSymbols(addressable, {
        apiKey: Deno.env.get('OPENFIGI_API_KEY') ?? undefined,
        venues,
        onBatch: async (found, missed) => {
          if (found.length > 0) {
            const { error } = await market.from('security_provider_symbol').upsert(
              found.map((f) => ({
                security_id: f.securityId,
                provider_code: 'yfinance',
                symbol: f.symbol,
              })),
              { onConflict: 'security_id,provider_code', ignoreDuplicates: true },
            )
            if (error) throw new Error(`provider symbol upsert failed: ${error.message}`)

            // Store the composite FIGI as an identifier. It is the ONLY key that joins a security
            // to `exchange_listing` (the directory endpoint returns no ISIN), so capturing it as
            // we resolve is what makes the directory usable later.
            const figis = found
              .filter((f) => f.compositeFigi)
              .map((f) => ({
                kind_code: 'figi',
                value: f.compositeFigi as string,
                security_id: f.securityId,
                source_code: 'openfigi',
              }))
            if (figis.length > 0) {
              const { error: figiErr } = await market
                .from('security_identifier')
                .upsert(figis, { onConflict: 'kind_code,value', ignoreDuplicates: true })
              if (figiErr) throw new Error(`figi identifier upsert failed: ${figiErr.message}`)
            }
          }
          // A negative result is a result: without this the same unaddressable securities are
          // re-sent on every run and crowd out the ones that would resolve.
          if (missed.length > 0) {
            const { error } = await market
              .from('security')
              .update({ local_symbol_missing_at: new Date().toISOString() })
              .in('security_id', missed)
            if (error) throw new Error(`local_symbol_missing_at update failed: ${error.message}`)
          }
        },
      })
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        resolved: resolvedCount,
        unresolved,
        requestsUsed,
        remaining: Math.max(0, addressable.length - resolvedCount - unresolved),
      })
    }


    // Keep the daily bars we already download. `security-performance` fetches ~400 days per
    // security to compute seven numbers and discards the series, so a chart is possible for the 47
    // curated instruments and nobody else.
    //
    // INCREMENTAL: the backlog carries each security's newest stored bar and the fetch starts
    // there, so a daily refresh asks for a day rather than four hundred. Batches are grouped by how
    // far back their members need, because the provider takes one start_date per request.
    if (resource === SEC_PRICES_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_prices')
        .select('security_id,symbol,fetch_symbol,last_date')
        .order('best_weight', { ascending: false })
        // 400, measured: 52s of the 55s budget, 73,542 rows, no failures. The DEADLINE is meant to
        // be what stops a run — a page small enough to finish in 5s just wastes 50 of them, and at
        // 120 this backlog would have taken 20 days to drain against a 4x/day cron.
        // Overshooting is safe: unprocessed rows stay in the backlog and cost one bigger read.
        .limit(scopeLimit ?? 400)
      if (pendErr) throw new Error(`pending_prices read failed: ${pendErr.message}`)

      const wanted = dedupeBy(pending ?? [], (r) => String(r.security_id))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, written: 0, remaining: 0, note: 'every series is current' })
      }

      const bySymbolId = new Map(wanted.map((r) => [String(r.symbol), String(r.security_id)]))
      const plans = planPriceFetches(
        wanted.map((r) => ({
          symbol: String(r.symbol),
          fetchSymbol: String(r.fetch_symbol ?? r.symbol),
          lastDate: (r.last_date as string | null) ?? null,
        })),
        new Date(),
        20,
      )

      const deadline = Date.now() + 55_000
      let written = 0
      let emptySeries = 0
      let batchesFailed = 0
      let throttledOut = false
      let lastError: string | null = null
      // Bars recovered by asking a symbol on its own after its batch produced nothing. A non-zero
      // value here means a BATCH was hiding an answerable security, which is worth seeing.
      let isolatedWrites = 0
      const cutoff = new Date(Date.now() - PRICE_WINDOW_DAYS * 86_400_000).toISOString().slice(0, 10)

      for (const plan of plans) {
        const remaining = deadline - Date.now()
        if (remaining < 5_000) break
        let rows: Record<string, unknown>[] = []
        try {
          rows = await fetcher(
            `/api/v1/equity/price/historical?symbol=${symbolList(plan.symbols.map((s) => s.fetchSymbol))}` +
              `&provider=yfinance&start_date=${plan.startDate}&interval=1d`,
            Math.min(20_000, remaining),
          )
        } catch (e) {
          batchesFailed++
          lastError = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          // Same rule as the isolation path: once the provider is refusing us, the rest of
          // the page will refuse too, and each attempt pushes the limit further out.
          if (throttled(lastError)) { throttledOut = true; break }
          continue
        }

        // Map the provider's answer back onto OUR display symbol: it replies under the fetch symbol
        // (`HEXA-B.ST`), and the series is stored under the display symbol, which since #79 is the
        // primary listing. They are usually the same now — usually is not always.
        // Keyed on SECURITY_ID, not on the symbol. `market.prices.symbol` is a foreign key to the
        // curated instruments table, so a universe-wide write into it is refused — correctly. And a
        // symbol is not a stable key: migration 39 changed the display symbol for 41% of non-US
        // securities, and anything keyed on it needed re-keying by hand.
        const toId = new Map(plan.symbols.map((s) => [s.fetchSymbol.toUpperCase(), bySymbolId.get(s.symbol)]))
        const priceRows: { security_id: string; date: string; close: number }[] = []
        for (const r of rows) {
          const parsed = barFrom(r, plan.symbols[0].fetchSymbol)
          if (!parsed) continue
          const id = toId.get(parsed.symbol.toUpperCase())
          if (!id || parsed.bar.date < cutoff) continue
          priceRows.push({ security_id: id, date: parsed.bar.date, close: parsed.bar.close })
        }

        if (priceRows.length === 0) {
          // The provider answered and had nothing for these. Negative-cache so they stop being
          // re-asked — but only when the batch itself did not fail, or a rate limit would mark the
          // whole universe unpriceable (the 1,369 mistake).
          //
          // "DID NOT FAIL" IS A THROW CHECK, AND THAT WAS THE HOLE. A throttled provider answers
          // 200-with-no-rows rather than erroring, so nothing throws, every batch looks like a
          // clean "no data", and the whole page is marked anyway — the mistake this comment was
          // written to prevent, committed underneath it. `written > 0` is the missing half: proof
          // the provider produced bars for SOMEONE in this run.
          //
          // AND `written > 0` KILLS THE BACKLOG THE MOMENT ITS ANSWERABLE WORK IS DONE, which is
          // where this now stands. Once every security left is one yfinance does not carry, no
          // batch produces a bar, `written` stays 0 for the whole run, the gate never fires, and
          // the same securities are re-asked eight times a day for ever. Measured 2026-08-14:
          // `written: 0, emptySeries: 300, batchesFailed: 0, remaining: 393` — unchanged run after
          // run, 301 of them never priced at all. Driving `security-refresh` at ICT.PS and FAB.AE
          // returns `returns: 0, "not covered"`: the Philippines and the UAE are genuinely outside
          // the keyless provider. Fourth instance of this exact shape (`security-fundamentals` and
          // `security-industries` both died this way, and `security-performance` this morning).
          //
          // So evidence comes from ISOLATION, not from a run-wide tally — the same rule
          // `security-performance` now uses. A symbol asked ON ITS OWN that answers with no bars is
          // evidence about that symbol; a batch that produced nothing says only that the batch
          // produced nothing. Bounded by the deadline, so a run isolates what it has budget for and
          // leaves the rest; a throttled provider makes every isolation throw, so a throttled run
          // marks nothing.
          const emptyIds: string[] = []
          for (const sym of plan.symbols) {
            if (Date.now() > deadline - 5_000) break
            const id = bySymbolId.get(sym.symbol)
            if (!id) continue
            try {
              const alone = await fetcher(
                `/api/v1/equity/price/historical?symbol=${symbolList([sym.fetchSymbol])}` +
                  `&provider=yfinance&start_date=${plan.startDate}&interval=1d`,
                Math.min(8_000, deadline - Date.now()),
              )
              const bars = alone
                .map((r) => barFrom(r, sym.fetchSymbol))
                .filter((b): b is NonNullable<typeof b> => !!b && b.bar.date >= cutoff)
              if (bars.length === 0) {
                emptyIds.push(id)
              } else {
                const { error } = await market.from('security_price').upsert(
                  bars.map((b) => ({ security_id: id, date: b.bar.date, close: b.bar.close })),
                  { onConflict: 'security_id,date' },
                )
                if (error) throw new Error(`security_price upsert failed: ${error.message}`)
                written += bars.length
                isolatedWrites += bars.length
              }
            } catch (e) {
              const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
              if (throttled(msg)) { lastError = msg; throttledOut = true; break }
              // A refusal is not an answer. Left unmarked and retried next run.
            }
          }
          const ids = emptyIds
          if (ids.length > 0) {
            const { error } = await market
              .from('security')
              .update({ prices_missing_at: new Date().toISOString() })
              .in('security_id', ids)
            if (error) throw new Error(`prices_missing_at update failed: ${error.message}`)
          }
          // COUNT WHAT WAS ACTUALLY EMPTY, not the size of the batch that came back empty. Since
          // isolation can now recover a security whose BATCH produced nothing — that is the whole
          // reason for asking individually — `plan.symbols.length` would report securities as
          // having no series in the same run that wrote bars for them. A counter that overstates is
          // how the statements coverage was misread as 12x its real value.
          emptySeries += emptyIds.length
          continue
        }

        for (let i = 0; i < priceRows.length; i += 500) {
          const { error } = await market
            .from('security_price')
            .upsert(dedupeBy(priceRows.slice(i, i + 500), (r) => `${r.security_id}|${r.date}`),
              { onConflict: 'security_id,date' })
          if (error) throw new Error(`security_price upsert failed: ${error.message}`)
        }
        written += priceRows.length

        // Keep the window bounded. Without this the table grows forever and the "~400 bars per
        // security" sizing that justified storing this at all stops being true.
        const touched = [...new Set(priceRows.map((r) => r.security_id))]
        for (let i = 0; i < touched.length; i += 100) {
          const { error } = await market
            .from('security_price')
            .delete()
            .in('security_id', touched.slice(i, i + 100))
            .lt('date', cutoff)
          if (error) throw new Error(`price window prune failed: ${error.message}`)
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource, written, emptySeries, isolatedWrites, batchesFailed, lastError, throttledOut,
        plans: plans.length, remaining: wanted.length,
      })
    }

    // Ask the price provider what IT calls this security, instead of sending Bloomberg's spelling.
    //
    // OpenFIGI's `ticker` is the Bloomberg form and the provider rejects it: `BRK/B` and `RR/.L`
    // 400, while `6.HK` and `ESSITYB.ST` return "no data" because Hong Kong pads to four digits and
    // Stockholm share classes take a hyphen. The last two carry no unusual character at all, which
    // is why this resolves from a SOURCE rather than applying rules written from memory — the
    // mistake `exchanges.ts` records, where a hand-written table silently dropped 534 securities.
    if (resource === YAHOO_SYMBOL_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_yahoo_symbol')
        .select('security_id,isin,country_iso2,current_symbol')
        .order('best_weight', { ascending: false })
        // 300, raised from 60 after measuring: 60 symbols took 5s and 200 took 18s of the 55s
        // budget, with `failed: 0` at both. The endpoint is far less rate-limiting than the
        // one-call-per-security shape suggested, and the wall-clock deadline is the real bound.
        //
        // This resource GATES the others — a security without a correct symbol cannot get a
        // profile, an industry, fundamentals or prices — so at 60 a backlog of 8,792 needed 18 days
        // and everything downstream waited on it. Kept well under the measured ceiling rather than
        // maximised: this is somebody else's free endpoint.
        .limit(scopeLimit ?? 300)
      if (pendErr) throw new Error(`pending_yahoo_symbol read failed: ${pendErr.message}`)

      const wanted = dedupeBy(pending ?? [], (r) => String(r.security_id))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, resolved: 0, remaining: 0, note: 'nothing to re-address' })
      }

      // BOUNDED BY WALL CLOCK, not by request count. Yahoo's search is rate-limited and one call
      // per security is not batchable, so a count-based bound is a bound on nothing: 15 anonymous
      // OpenFIGI requests once took ~40s on a laptop and blew the worker on this node. On an
      // incremental resource, stopping early is free.
      const deadline = Date.now() + 55_000
      let resolved = 0
      let unresolved = 0
      let failed = 0
      let lastError: string | null = null
      const changed: string[] = []

      for (const row of wanted) {
        const remaining = deadline - Date.now()
        if (remaining < 4_000) break
        let hits
        try {
          hits = await searchByIsin(String(row.isin), Math.min(8_000, remaining))
        } catch (e) {
          // A refusal is about the ENDPOINT, not this security — do not negative-cache it, or a
          // rate limit becomes 60 securities marked unresolvable for a month. This is the same
          // rule `fetchWithIsolation` learned the hard way after mismarking 1,369 of them.
          failed++
          lastError = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          continue
        }

        const symbol = pickHomeListing(hits, String(row.country_iso2), venues)
        if (!symbol) {
          // Answered, and nothing on this security's home market. That IS about the security.
          const { error } = await market
            .from('security')
            .update({ yahoo_symbol_missing_at: new Date().toISOString() })
            .eq('security_id', row.security_id)
          if (error) throw new Error(`yahoo_symbol_missing_at update failed: ${error.message}`)
          unresolved++
          continue
        }
        if (symbol === row.current_symbol) {
          // The spelling was never the problem for this one; stop re-asking about it.
          const { error } = await market
            .from('security')
            .update({ yahoo_symbol_missing_at: new Date().toISOString() })
            .eq('security_id', row.security_id)
          if (error) throw new Error(`yahoo_symbol_missing_at update failed: ${error.message}`)
          unresolved++
          continue
        }

        const { error: psErr } = await market.from('security_provider_symbol').upsert(
          { security_id: row.security_id, provider_code: 'yfinance', symbol },
          { onConflict: 'security_id,provider_code' },
        )
        if (psErr) throw new Error(`provider symbol upsert failed: ${psErr.message}`)

        // KEEP EVERY VENUE THE SEARCH REVEALED, not just the one we priced on. The ISIN search
        // returns the security's other listings — the ADR, the cross-listing — and until now they
        // were discarded, which is exactly why "local line vs ADR" had no answer. `is_primary` is
        // reserved for the home-market pick; a partial unique index enforces one per security.
        const listings = hits
          .filter((h) => !h.quoteType || h.quoteType === 'EQUITY')
          .map((h) => ({ sym: (h.symbol ?? '').trim(), exch: venueForSymbol((h.symbol ?? '').trim(), venues) }))
          .filter((h) => h.sym && h.exch)
        const seenExch = new Set<string>()
        const listingRows = []
        for (const l of listings) {
          // One row per venue: an ISIN search can return the same exchange twice (share classes).
          if (seenExch.has(l.exch as string)) continue
          seenExch.add(l.exch as string)
          listingRows.push({
            security_id: row.security_id,
            exch_code: l.exch as string,
            provider_symbol: l.sym,
            is_primary: l.sym === symbol,
            source_code: 'yfinance',
            last_seen_at: new Date().toISOString(),
          })
        }
        if (listingRows.length > 0) {
          // INSERTED NON-PRIMARY, then promoted separately. `onConflict: 'security_id,exch_code'`
          // names the PRIMARY KEY, so `ignoreDuplicates` does nothing for the PARTIAL UNIQUE INDEX
          // `listing_one_primary_idx` — and a security that already has a primary on one exchange
          // fails the whole statement when a second is inserted for another:
          //
          //   listing upsert failed: duplicate key value violates unique constraint
          //   "listing_one_primary_idx"
          //
          // Caught in production 2026-08-13 by the ingestion watch.
          const { error: lErr } = await market.from('listing').upsert(
            listingRows.map((r) => ({ ...r, is_primary: false })),
            { onConflict: 'security_id,exch_code', ignoreDuplicates: true },
          )
          if (lErr) throw new Error(`listing upsert failed: ${lErr.message}`)

          // Promote the home-market pick: demote first so exactly one row can hold the flag. Two
          // statements rather than one because the index is what enforces the invariant, and an
          // upsert cannot express "move this flag".
          const chosen = listingRows.find((r) => r.provider_symbol === symbol)
          if (chosen) {
            const { error: dErr } = await market.from('listing')
              .update({ is_primary: false })
              .eq('security_id', row.security_id).eq('is_primary', true)
            if (dErr) throw new Error(`demote primary failed: ${dErr.message}`)
            const { error: pErr } = await market.from('listing')
              .update({ is_primary: true })
              .eq('security_id', row.security_id).eq('exch_code', chosen.exch_code)
            if (pErr) throw new Error(`promote primary failed: ${pErr.message}`)
          }
        }

        // A NEW SYMBOL INVALIDATES EVERY SYMBOL-KEYED NEGATIVE CACHE. Those flags record "we asked
        // and got nothing" — but we asked under the WRONG NAME, so leaving them set would fix the
        // spelling and still exclude the security from every backlog for 30 days. This clearing is
        // the difference between resolving a symbol and actually recovering the security.
        //
        // The list lives in `market.clear_symbol_caches` rather than here. It used to be five
        // columns written out at this call site, and `prices_missing_at` (migration 42, later)
        // never joined them — so 4,801 equities stayed locked out of `pending_prices` after their
        // symbol was corrected, with no error and no symptom. Next to the columns it is at least
        // enforceable: `tests/negative-caches-are-classified.sql` fails when a `%_missing_at`
        // column is added and nobody says which side of this it belongs on.
        const { error: clrErr } = await market
          .rpc('clear_symbol_caches', { p_security_id: row.security_id })
        if (clrErr) throw new Error(`clearing negative caches failed: ${clrErr.message}`)

        resolved++
        if (changed.length < 12) changed.push(`${row.current_symbol ?? '?'} -> ${symbol}`)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        resolved,
        unresolved,
        failed,
        lastError,
        examples: changed,
        remaining: wanted.length - resolved - unresolved - failed,
      })
    }

    // Level 2 of the taxonomy: the sub-sector a sector page shows as chips. The data was already
    // arriving and being discarded — yfinance returns `industry_category` in the SAME response
    // `security-profiles` reads for the sector.
    //
    // Nodes are created ON DEMAND under the security's sector, so the vocabulary is whatever the
    // provider actually uses rather than a list authored ahead of time and guessed at.
    if (resource === INDUSTRY_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_industry')
        .select('security_id,symbol,sector_id')
        .order('best_weight', { ascending: false })
        .limit(scopeLimit ?? PROFILE_BACKLOG_PAGE)
      if (pendErr) throw new Error(`pending_industry read failed: ${pendErr.message}`)
      // ONE ROW PER SECURITY. `pending_industry` yields one row per (security, level-1 sector), so
      // a security classified into two sectors arrives twice — which spent its symbol twice at the
      // provider and produced two identical `security_taxonomy` writes in one statement, the
      // `ON CONFLICT DO UPDATE ... a second time` failure. `dedupeBy` at the upsert is the
      // backstop; this stops it at the source and saves the duplicate fetch.
      const wanted = dedupeBy(pending ?? [], (r) => String(r.security_id)).map((r) => ({
        securityId: r.security_id as string,
        symbol: r.symbol as string,
        sectorId: r.sector_id as string,
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, classified: 0, remaining: 0, note: 'every security has an industry' })
      }

      // The sector comes WITH the backlog row. Looking it up separately meant an `in.()` filter
      // holding 500 uuids — an ~18 KB URL, and PostgREST answers those with a bare 502.
      const sectorOf = new Map(wanted.map((w) => [w.securityId, w.sectorId]))

      const { data: nodes, error: nodeErr } = await market
        .from('taxonomy_node')
        .select('node_id,code,name,level,parent_id')
        .eq('taxonomy_id', 'muffin')
      if (nodeErr) throw new Error(`taxonomy_node read failed: ${nodeErr.message}`)
      const sectorNode = new Map(
        (nodes ?? []).filter((n) => n.level === 1).map((n) => [n.code as string, n.node_id as string]),
      )
      // Level-2 nodes are keyed on `(taxonomy, code)`; the code is the slugged industry name.
      const industryNode = new Map(
        (nodes ?? []).filter((n) => n.level === 2).map((n) => [n.code as string, n.node_id as string]),
      )
      const slug = (name: string) =>
        name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '').slice(0, 60)

      const deadline = Date.now() + 60_000
      const BATCH = 20
      let classified = 0
      let noIndustry = 0
      let capped = 0
      let batchesFailed = 0
      let throttledOut = false
      let lastError: string | null = null

      for (let i = 0; i < wanted.length && Date.now() < deadline; i += BATCH) {
        const batch = wanted.slice(i, i + BATCH)
        const remaining = deadline - Date.now()
        if (remaining < 3_000) break
        // Securities the isolation pass has already negative-cached in this batch, so the empty-answer
        // branch below does not count them a second time.
        const alreadyMissing = new Set<string>()
        let rows: Record<string, unknown>[] = []
        try {
          // ISOLATE rather than lose the batch. The highest-weight page permanently contains
          // Bloomberg spellings (`BRK/B`, `WALMEX*.MX`, `RR/.L`, `PE&OLES*.MX`) that 400 even once
          // encoded, and because the backlog is ordered by fund weight that batch sat at the head
          // of EVERY run — twenty securities re-failing forever, nineteen of them innocent.
          const got = await fetchWithIsolation(
            fetcher,
            (syms) => `/api/v1/equity/profile?symbol=${symbolList(syms)}&provider=yfinance`,
            batch.map((b) => b.symbol),
            Math.min(15_000, remaining),
            deadline,
          )
          rows = got.rows
          if (got.error) {
            batchesFailed++
            lastError = got.error
            // STOP THE RUN ON A THROTTLE — do not spend the rest of the page on it.
            //
            // A rate limit is not a per-batch accident: once yfinance is refusing us, every
            // remaining batch fails too. Measured 2026-08-13 — `security-fundamentals` reads 600
            // rows at BATCH 10, so a throttled run fired SIXTY requests, failed all sixty, wrote
            // nothing, and each of those requests pushed the limit further out. `batchesFailed: 60`
            // with `written: 0`, repeatedly.
            //
            // Breaking turns that into one failed request and an early return. The backlog is
            // incremental, so a short run costs nothing; the next one starts where this stopped.
            if (throttled(got.error)) { throttledOut = true; break }
          }
          // A symbol the provider refuses ON ITS OWN is genuinely unanswerable, so stop asking.
          // `industry_missing_at` was never reached for these: it is only written when a batch
          // comes back EMPTY, and a 400 is not empty.
          if (got.dead.length > 0) {
            const deadIds = batch
              .filter((b) => got.dead.includes(b.symbol))
              .map((b) => b.securityId)
            const { error } = await market
              .from('security')
              .update({ industry_missing_at: new Date().toISOString() })
              .in('security_id', deadIds)
            if (error) throw new Error(`industry_missing_at update failed: ${error.message}`)
            noIndustry += deadIds.length
            for (const id of deadIds) alreadyMissing.add(id)
          }
        } catch (e) {
          batchesFailed++
          lastError = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          // Same rule as the isolation path: once the provider is refusing us, the rest of
          // the page will refuse too, and each attempt pushes the limit further out.
          if (throttled(lastError)) { throttledOut = true; break }
          continue
        }
        // ...BUT ONLY ONCE THIS ENDPOINT HAS ANSWERED FOR SOMEONE IN THIS RUN.
        //
        // An empty answer is a legitimate "no data for these" — right up until the endpoint stops
        // answering at all, when it becomes "no data for anyone" and marking a batch on it is how a
        // provider hiccup gets recorded as hundreds of permanently unanswerable securities.
        //
        // MEASURED, NOT HYPOTHETICAL — this is what it did on 2026-08-13. Draining hard enough to
        // trip yfinance's rate limit made it answer 200-with-no-rows rather than erroring, so
        // `fetchWithIsolation`'s outage rule (which only sees THROWS) never fired, and this branch
        // marked **1,414 securities** as having no industry. Among them: INTC, PEP, XOM, TXN, EA,
        // SCCO. The largest companies in the United States, recorded as unclassifiable, silently,
        // while the backlog went to zero and looked drained.
        if (rows.length === 0) {
          // Empty is "no data for these", not a fault — record it so they stop being re-asked.
          // EXCLUDING anything the isolation pass already marked, or a batch where some symbols
          // failed individually and the rest answered empty counts both groups and reports more
          // securities than the batch contains (measured: `noIndustry: 23` for a batch of 20 —
          // 3 dead plus all 20 again). The write is idempotent, so this was a lying TALLY rather
          // than bad data; a tally is what the next person diagnoses from, so it has to be true.
          const stillUnrecorded = batch
            .filter((b) => !alreadyMissing.has(b.securityId))
            .map((b) => b.securityId)
          if (stillUnrecorded.length > 0 && classified > 0) {
            const { error } = await market
              .from('security')
              .update({ industry_missing_at: new Date().toISOString() })
              .in('security_id', stillUnrecorded)
            if (error) throw new Error(`industry_missing_at update failed: ${error.message}`)
            noIndustry += stillUnrecorded.length
          }
          continue
        }

        const bySymbol = new Map(batch.map((b) => [b.symbol.toUpperCase(), b.securityId]))
        const answered = new Set<string>()

        // Collected FIRST, then written in two calls. Creating a node inside the per-security loop
        // meant an upsert plus a read-back for every new industry — ~40 extra round trips a batch
        // while the vocabulary was still filling, which killed the worker (a bare 502).
        const wantNode = new Map<string, { label: string; parent: string }>()
        const pairs: { securityId: string; code: string }[] = []
        // Market cap rides along here too. `pending_profile` excludes anything already classified,
        // so `security-profiles` never revisits it — but this resource fetches EXACTLY that set
        // (has a sector, lacks an industry), which is where the caps for the existing universe
        // come from. Same response, no extra request.
        const caps: { security_id: string; market_cap: number }[] = []
        // The CURRENCY rides along too. `equity/profile` returns it in the SAME response the market
        // cap comes from and it was being discarded, leaving 1,675 securities with a cap and no
        // currency — which `formatMoney` then renders unlabelled. Same reasoning as the cap itself:
        // no extra request, no new provider, only storing a field already on the wire.
        const currencies: { security_id: string; code: string }[] = []
        for (const r of rows) {
          const securityId = bySymbol.get(String(r.symbol ?? '').toUpperCase())
          if (!securityId) continue
          answered.add(securityId)
          const cap = Number(r.market_cap)
          if (Number.isFinite(cap) && cap > 0) caps.push({ security_id: securityId, market_cap: cap })
          const cur = typeof r.currency === 'string' ? r.currency.trim().toUpperCase() : ''
          if (/^[A-Z]{3}$/.test(cur)) currencies.push({ security_id: securityId, code: cur })
          // `industry_category`, NOT `industry` — the latter is present on the yfinance response
          // and is always null, which is how the old sub-sectors silently came back empty.
          const label = String(r.industry_category ?? '').trim()
          const sectorCode = sectorOf.get(securityId)
          const parent = sectorCode ? sectorNode.get(sectorCode) : undefined
          if (!label || !parent) continue
          const code = `${sectorCode}--${slug(label)}`
          if (!industryNode.has(code)) wantNode.set(code, { label, parent })
          pairs.push({ securityId, code })
        }

        // One upsert for every new node in the batch...
        if (wantNode.size > 0) {
          const { error } = await market.from('taxonomy_node').upsert(
            [...wantNode].map(([code, v]) => ({
              taxonomy_id: 'muffin', code, name: v.label, parent_id: v.parent, level: 2,
            })),
            { onConflict: 'taxonomy_id,code', ignoreDuplicates: true },
          )
          if (error) throw new Error(`taxonomy_node insert failed: ${error.message}`)
          // ...and ONE read-back. Necessary rather than trusting generated ids: `ignoreDuplicates`
          // means a concurrent run may have won the insert, and referencing an id that was never
          // written would fail the foreign key.
          const { data: got, error: readErr } = await market
            .from('taxonomy_node')
            .select('node_id,code')
            .eq('taxonomy_id', 'muffin')
            .in('code', [...wantNode.keys()])
          if (readErr) throw new Error(`taxonomy_node read-back failed: ${readErr.message}`)
          for (const n of got ?? []) industryNode.set(n.code as string, n.node_id as string)
        }

        for (const c of caps) {
          const { error } = await market
            .from('security')
            .update({ market_cap: c.market_cap, market_cap_at: new Date().toISOString() })
            .eq('security_id', c.security_id)
          if (error) throw new Error(`market_cap update failed: ${error.message}`)
        }
        capped += caps.length

        // Learn the codes BEFORE referencing them: `security.currency_code` is a foreign key, and an
        // unseen code fails the STATEMENT rather than the row — the exact failure the fundamentals
        // path hit on 2026-08-12.
        const unseen = [...new Set(currencies.map((c) => c.code))]
        if (unseen.length > 0) {
          const { error: curErr } = await market
            .from('currency')
            .upsert(unseen.map((code) => ({ code })), { onConflict: 'code', ignoreDuplicates: true })
          if (curErr) throw new Error(`currency learn failed: ${curErr.message}`)
        }
        for (const c of currencies) {
          const { error } = await market
            .from('security')
            .update({ currency_code: c.code })
            .eq('security_id', c.security_id)
            .or(`currency_code.is.null,currency_code.neq.${c.code}`)
          if (error) throw new Error(`currency_code update failed: ${error.message}`)
        }

        const writes = pairs
          .filter((p) => industryNode.has(p.code))
          .map((p) => ({
            security_id: p.securityId,
            node_id: industryNode.get(p.code) as string,
            source_code: 'yfinance',
            as_of: new Date().toISOString(),
          }))

        if (writes.length > 0) {
          const { error } = await market
            .from('security_taxonomy')
            .upsert(dedupeBy(writes, (w) => `${w.security_id}|${w.node_id}|${w.source_code}`),
              { onConflict: 'security_id,node_id,source_code' })
          if (error) throw new Error(`security_taxonomy upsert failed: ${error.message}`)
          classified += writes.length
        }
        // Answered about but with no industry, or no sector to hang it under. Recorded so they
        // stop being re-asked — the fifth time this has been needed here.
        const missed = batch
          .map((b) => b.securityId)
          .filter((id) => answered.has(id) && !writes.some((w) => w.security_id === id))
        if (missed.length > 0) {
          noIndustry += missed.length
          const { error } = await market
            .from('security')
            .update({ industry_missing_at: new Date().toISOString() })
            .in('security_id', missed)
          if (error) throw new Error(`industry_missing_at update failed: ${error.message}`)
        }
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        classified,
        capped,
        noIndustry,
        batchesFailed,
        // True when the run stopped early because the provider began refusing.
        // Without it a throttled run is indistinguishable from a drained backlog.
        throttledOut,
        lastError,
        remaining: Math.max(0, wanted.length - classified - noIndustry),
      })
    }

    if (resource === SEC_PROFILE_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_profile')
        .select('security_id,symbol')
        .order('best_weight', { ascending: false })
        .limit(scopeLimit ?? PROFILE_BACKLOG_PAGE)
      if (pendErr) throw new Error(`pending_profile read failed: ${pendErr.message}`)
      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        symbol: r.symbol as string,
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, classified: 0, remaining: 0, note: 'every security has a sector' })
      }

      // muffin sector id -> taxonomy node, resolved once.
      const { data: nodes, error: nodeErr } = await market
        .from('taxonomy_node')
        .select('node_id,code')
        .eq('taxonomy_id', 'muffin')
      if (nodeErr) throw new Error(`taxonomy_node read failed: ${nodeErr.message}`)
      const nodeByCode = new Map((nodes ?? []).map((n) => [n.code as string, n.node_id as string]))

      // COUNTRY NAME -> ISO-2, from the same table the globe reads so the two cannot disagree.
      // `hq_country` is an English name ("Taiwan", "United Kingdom"), not a code. Aliases cover the
      // spellings `countries.name` states formally and no provider emits ("Russian Federation").
      const { data: countryRows, error: cErr } = await market
        .from('countries')
        .select('iso2,name')
      if (cErr) throw new Error(`countries read failed: ${cErr.message}`)
      const isoByCountryName = new Map(
        (countryRows ?? []).map((c) => [String(c.name).trim().toLowerCase(), c.iso2 as string]),
      )
      const { data: aliasRows, error: aErr } = await market
        .from('country_alias')
        .select('provider_name,iso2')
      if (aErr) throw new Error(`country_alias read failed: ${aErr.message}`)
      for (const a of aliasRows ?? []) {
        isoByCountryName.set(String(a.provider_name).trim().toLowerCase(), a.iso2 as string)
      }

      const deadline = Date.now() + 60_000
      // 20, not 50: a profile lookup is one upstream fetch PER SYMBOL inside yfinance, and foreign
      // listings are markedly slower than US ones. A smaller batch keeps each call inside the
      // fetcher's timeout instead of relying on it.
      const BATCH = 20
      let classified = 0
      let unmapped = 0
      let capped = 0
      let noProfile = 0
      // Securities in batches that came back empty BEFORE this endpoint had answered for anyone.
      // Deliberately not marked and deliberately counted: a run reporting a large number here is
      // saying "the endpoint is not answering", which is exactly what a silent skip would hide.
      let emptyBeforeAnyAnswer = 0
      let batchesFailed = 0
      let throttledOut = false
      let lastError: string | null = null
      let homed = 0
      let noCountryMarked = 0
      // Provider country names no row in `countries` or `country_alias` could resolve. Reported so
      // the alias table is filled from what the provider actually says.
      const unresolvedCountries = new Set<string>()
      for (let i = 0; i < wanted.length && Date.now() < deadline; i += BATCH) {
        const batch = wanted.slice(i, i + BATCH)
        const bySymbol = new Map(batch.map((b) => [b.symbol.toUpperCase(), b.securityId]))
        // A THROW and an EMPTY ANSWER are different facts and must not be collapsed. If the whole
        // batch fails, the provider is down or rate-limiting — mark nothing, or a single outage
        // would negative-cache thousands of perfectly answerable securities for a month.
        let rows: Record<string, unknown>[] = []
        let providerFailed = false
        try {
          // Bounded by what is LEFT of the budget, not a fixed 20s. A fixed timeout lets a batch
          // start at 34.9s and run to 55s, and the writes after it push the worker past its 60s
          // limit — which is a bare 502, not a caught error. The deadline has to bound the call,
          // not just the decision to start one.
          const remaining = deadline - Date.now()
          if (remaining < 3_000) break
          // Same isolation: one unanswerable symbol must not cost the other forty-nine.
          const got = await fetchWithIsolation(
            fetcher,
            (syms) => `/api/v1/equity/profile?symbol=${symbolList(syms)}&provider=yfinance`,
            batch.map((b) => b.symbol),
            Math.min(15_000, remaining),
            deadline,
          )
          rows = got.rows
        } catch (_e) {
          providerFailed = true
        }
        // A REQUEST THAT FAILED AND A REQUEST THAT ANSWERED NOTHING ARE DIFFERENT FACTS.
        //
        // These were one branch, on the reasoning that zero rows is "indistinguishable from a
        // failure". They are not indistinguishable — `providerFailed` is precisely the flag that
        // tells them apart, and OpenBB answers 204 NO CONTENT when a provider genuinely has
        // nothing, which is an answer rather than a fault.
        //
        // Merging them meant an unanswerable batch was counted as failed AND skipped the
        // negative-cache write below, so those securities returned on every run forever. Then the
        // `batchesFailed > 0 && classified === 0` guard failed the whole resource — which happens
        // exactly when the answerable work is DONE and only unanswerable securities are left, so
        // it looks like the provider breaking at the moment everything started working.
        //
        // Measured 2026-08-13: `pending_profile` fell 2,665 -> 2,437 and then froze there across
        // every subsequent run, while `security-industries`, `security-statements` and
        // `security-fundamentals` — hitting the SAME `equity/profile` endpoint — all reported ok.
        // The provider was fine throughout.
        //
        // FIFTH instance of this shape here (`figi_missing_at`, `security-fundamentals`,
        // `security-industries`, the isolation empty-branch, now this). The first two were FIXED
        // and this call site was not: a rule at one call site is not a rule.
        if (providerFailed) {
          batchesFailed++
          continue
        }
        if (rows.length === 0) {
          // The provider answered and had nothing to say about any of them — but ONLY blame the
          // securities once this endpoint has demonstrably answered for someone in this run.
          //
          // WITHOUT THAT CONDITION THIS IS THE 1,369 INCIDENT AGAIN, in a new column. Checked
          // before shipping rather than after: the head of `pending_profile` was `HBNC, TRST, CAC,
          // CLB, HAFC, MYE, MAZE, CHRD, CFR, IRMD, PRI, COLB` — ordinary US mid-caps — and Yahoo
          // returns a full profile WITH a sector for them (CFR -> Financial Services, CHRD ->
          // Energy). So a run where every batch comes back empty is not 600 unanswerable
          // securities; it is the endpoint not answering, and marking them would have locked 2,437
          // perfectly good securities out for 30 days.
          //
          // `classified > 0` is the proof the endpoint works, and it is safe here in a way it was
          // NOT for the throw path (a rate limit is progressive, so "it answered earlier" says
          // nothing about now). An empty 200/204 is not a refusal signature, and the failure mode
          // this guards is far worse than a delayed drain: a batch left unmarked is retried next
          // run, whereas one wrongly marked is gone for a month.
          if (classified > 0) {
            const { error } = await market
              .from('security')
              .update({ profile_missing_at: new Date().toISOString() })
              .in('security_id', batch.map((b) => b.securityId))
            if (error) throw new Error(`profile_missing_at update failed: ${error.message}`)
            noProfile += batch.length
          } else {
            emptyBeforeAnyAnswer += batch.length
          }
          continue
        }

        const writes: Record<string, unknown>[] = []
        // Market cap rides along on the SAME response. It was recorded as blocked on a paid
        // provider for weeks; only deep fundamentals are. Capturing it costs nothing here.
        const caps: { security_id: string; market_cap: number }[] = []
        // So does the OPERATING country, and discarding it is why Alibaba sits under the Cayman
        // Islands: N-PORT reports incorporation, `hq_country` reports where the company actually
        // is. Same response, same run, one more column.
        const homes: { security_id: string; provider_country_iso2: string }[] = []
        // Answered about, no usable country. Negative-cached so the backlog can drain.
        const noCountry: string[] = []
        for (const r of rows) {
          const securityId = bySymbol.get(String(r.symbol ?? '').toUpperCase())
          const cap = Number(r.market_cap)
          if (securityId && Number.isFinite(cap) && cap > 0) {
            caps.push({ security_id: securityId, market_cap: cap })
          }
          const hq = String(r.hq_country ?? '').trim()
          if (securityId) {
            const iso = hq ? isoByCountryName.get(hq.toLowerCase()) : undefined
            if (iso) {
              homes.push({ security_id: securityId, provider_country_iso2: iso })
            } else {
              // THE PROFILE ANSWERED AND STILL GAVE NO USABLE COUNTRY, which is a fact about this
              // security and earns a negative cache. Without one it re-enters `pending_profile`
              // on every run for ever — the failure this schema has rediscovered five times, and
              // the reason `symbol_cache_classification` exists.
              noCountry.push(securityId)
              // An unresolved NAME is also counted and NAMED, never silently dropped: the alias
              // table is meant to be filled from this report rather than from a guess about the
              // provider's vocabulary. (An empty `hq_country` is not a name and adds nothing.)
              if (hq && unresolvedCountries.size < 40) unresolvedCountries.add(hq)
            }
          }
          const code = FINVIZ_SECTOR_IDS[String(r.sector ?? '')]
          // An unrecognised provider label is COUNTED, not silently dropped: a vocabulary change
          // upstream would otherwise look like a provider with no sectors.
          if (!securityId || !code) { unmapped++; continue }
          const nodeId = nodeByCode.get(code)
          if (!nodeId) { unmapped++; continue }
          writes.push({
            security_id: securityId,
            node_id: nodeId,
            source_code: 'yfinance',
            as_of: new Date().toISOString(),
          })
        }
        if (writes.length > 0) {
          const { error } = await market
            .from('security_taxonomy')
            .upsert(dedupeBy(writes, (w) => `${w.security_id}|${w.node_id}|${w.source_code}`),
              { onConflict: 'security_id,node_id,source_code' })
          if (error) throw new Error(`security_taxonomy upsert failed: ${error.message}`)
          classified += writes.length
        }
        // Written per security rather than in one upsert: `security` rows already exist, so this
        // is an UPDATE, and PostgREST has no bulk update by differing values.
        for (const c of caps) {
          const { error } = await market
            .from('security')
            .update({ market_cap: c.market_cap, market_cap_at: new Date().toISOString() })
            .eq('security_id', c.security_id)
          if (error) throw new Error(`market_cap update failed: ${error.message}`)
        }
        capped += caps.length

        // Grouped by ISO code, so this is one update per COUNTRY in the batch rather than one per
        // security — a batch of 20 is typically two or three countries.
        const byIso = new Map<string, string[]>()
        for (const h of homes) {
          const list = byIso.get(h.provider_country_iso2) ?? []
          list.push(h.security_id)
          byIso.set(h.provider_country_iso2, list)
        }
        for (const [iso, ids] of byIso) {
          const { error } = await market
            .from('security')
            .update({ provider_country_iso2: iso })
            .in('security_id', ids)
          if (error) throw new Error(`provider_country_iso2 update failed: ${error.message}`)
        }
        homed += homes.length

        // GATED ON THE BATCH HAVING ANSWERED, like every other marking site here: `rows` empty
        // means the provider said nothing, not that these securities have no country. A throttled
        // yfinance returns 200-with-no-rows, and marking on that is what recorded ~8,300
        // securities as permanently unanswerable in one afternoon.
        if (noCountry.length > 0 && rows.length > 0) {
          const { error } = await market
            .from('security')
            .update({ provider_country_missing_at: new Date().toISOString() })
            .in('security_id', noCountry)
          if (error) throw new Error(`provider_country_missing_at update failed: ${error.message}`)
        }
        noCountryMarked += noCountry.length

        // Everything in the batch the provider DID answer for, but not about — a ticker it does
        // not carry, or a sector label outside the map. Recorded so it stops being re-asked; the
        // batch answering at all is what proves the provider was up.
        const answered = new Set(writes.map((w) => w.security_id as string))
        const missed = batch.filter((b) => !answered.has(b.securityId)).map((b) => b.securityId)
        if (missed.length > 0) {
          const { error } = await market
            .from('security')
            .update({ profile_missing_at: new Date().toISOString() })
            .in('security_id', missed)
          if (error) throw new Error(`profile_missing_at update failed: ${error.message}`)
        }
      }
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      // `batchesFailed` is reported rather than hidden: a run that classified nothing because the
      // provider was down must not look like a run that found nothing left to do.
      if (batchesFailed > 0 && classified === 0) {
        throw new Error(`profile provider returned nothing for all ${batchesFailed} batches`)
      }
      return json({
        resource,
        classified,
        capped,
        unmapped,
        // Securities the provider ANSWERED about and had no profile for, now negative-cached.
        // Reported separately from `batchesFailed` because they are the opposite thing: progress.
        // A run of `classified: 0, noProfile: 600` is a backlog draining correctly, and it used to
        // be indistinguishable from a provider outage.
        noProfile,
        emptyBeforeAnyAnswer,
        batchesFailed,
        // True when the run stopped early because the provider began refusing.
        // Without it a throttled run is indistinguishable from a drained backlog.
        throttledOut,
        // Operating-HQ countries recorded, and the provider spellings nothing could resolve.
        // The names are LISTED, not just counted: the whole point of `country_alias` is to be
        // filled from what the provider actually says, and a bare count cannot tell you that.
        homed,
        noCountryMarked,
        unresolvedCountries: [...unresolvedCountries],
        remaining: Math.max(0, wanted.length - classified - unmapped - noProfile),
      })
    }

    // Per-security returns. This is why most constituents render no % change: market.performance
    // scope='instrument' only ever covered the 35 curated symbols.
    if (resource === SEC_PERF_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_performance')
        .select('security_id,symbol,fetch_symbol')
        .order('best_weight', { ascending: false })
        .limit(1000)
      if (pendErr) throw new Error(`pending_performance read failed: ${pendErr.message}`)
      // FETCH by the provider's address (`005930.KS`), STORE under the display ticker — the app
      // looks a stock up by the symbol it shows, not by the one yfinance wants.
      const fetchToDisplay = new Map<string, string>()
      const fetchToSecurity = new Map<string, string>()
      for (const r of pending ?? []) {
        fetchToDisplay.set(r.fetch_symbol as string, r.symbol as string)
        fetchToSecurity.set(r.fetch_symbol as string, r.security_id as string)
      }
      const symbols = [...fetchToDisplay.keys()]
      if (symbols.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, refreshed: 0, remaining: 0, note: 'every security has fresh returns' })
      }

      // 40 symbols x ~400 bars is ~1 MB. The country refresh proves 19 symbols x 1900 bars (~4 MB)
      // is safe, so this stays well inside the worker while still covering a page per batch.
      const BATCH = 40
      const deadline = Date.now() + 60_000
      const now = new Date()
      let written = 0
      let batchesFailed = 0
      let throttledOut = false
      let emptyBatches = 0
      let lastError: string | null = null
      for (let i = 0; i < symbols.length && Date.now() < deadline; i += BATCH) {
        const batch = symbols.slice(i, i + BATCH)
        const remaining = deadline - Date.now()
        if (remaining < 3_000) break
        // A throw and an empty answer are DIFFERENT FACTS. Collapsing them with `.catch(() => [])`
        // is why this reported `refreshed: 0, remaining: 1000` run after run with nothing to say
        // whether the provider was refusing the symbols or simply had no data for them.
        let fetched: PerfRow[] = []
        try {
          fetched = await loadEquityReturns(
            fetcher, batch, now, SEC_PERF_TTL_MINUTES, Math.min(15_000, remaining),
          )
        } catch (e) {
          batchesFailed++
          lastError = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
          // Same rule as the isolation path: once the provider is refusing us, the rest of
          // the page will refuse too, and each attempt pushes the limit further out.
          if (throttled(lastError)) { throttledOut = true; break }
          continue
        }
        const rows = fetched.map((r) => ({ ...r, scope_id: fetchToDisplay.get(r.scope_id) ?? r.scope_id }))
        // A 200 THAT OMITS A SYMBOL SAYS NOTHING ABOUT THAT SYMBOL — so it is asked again, ALONE,
        // and only an answer about it on its own is allowed to mark it.
        //
        // The previous rule gated on `fetched.length > 0`: if ANY symbol in the batch answered,
        // every absent one was recorded as permanently unanswerable. That is a TALLY, and the
        // provider defeats tallies — yfinance throttles PROGRESSIVELY, answering some symbols in a
        // batch while refusing others, with no error anywhere because the refusal is an omission
        // from a 200 rather than a throw. `fetchWithIsolation` exists for exactly this and could
        // not help here: it isolates when the call THROWS, and this call succeeds.
        //
        // Measured 2026-08-14, which is how this was found: 3,045 securities carried
        // `performance_missing_at`, and 2,548 of them HAD daily price bars from the last five days
        // — the provider was demonstrably answering for them. Among them MediaTek, Tapestry,
        // Ferguson, Royalty Pharma, Edenred and ACS (an IBEX 35 constituent). 2,297 were marked in
        // a single pass on 08-11. Driving `security-refresh` against TPR and 2454.TW returned all
        // seven periods, a market cap, fundamentals and statements — so the marks were simply false.
        //
        // The bound is the DEADLINE, not a count of misses: a run isolates what it has budget for
        // and leaves the rest for the next one. Nothing is marked for want of time — that is the
        // negative-cache equivalent of blaming the victim, and `fetchWithIsolation` already refuses
        // to do it. A throttle makes every isolation throw, so a throttled run marks NOTHING.
        const got = new Set(fetched.map((r) => r.scope_id))
        const missed = batch.filter((sym) => !got.has(sym))
        const confirmedDead: string[] = []
        for (const sym of missed) {
          if (Date.now() > deadline - 4_000) break
          try {
            const alone = await loadEquityReturns(
              fetcher, [sym], now, SEC_PERF_TTL_MINUTES,
              Math.min(8_000, deadline - Date.now()),
            )
            if (alone.length === 0) {
              // Answered about this symbol on its own and had no usable series for it. That is
              // evidence about the SYMBOL, which is the only thing that earns a mark.
              confirmedDead.push(sym)
            } else {
              rows.push(...alone.map((r) => ({ ...r, scope_id: fetchToDisplay.get(r.scope_id) ?? r.scope_id })))
            }
          } catch (e) {
            // A refusal is not an answer. Left unmarked and retried next run.
            const msg = e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200)
            if (throttled(msg)) { lastError = msg; throttledOut = true; break }
          }
        }
        const missedIds = confirmedDead
          .map((sym) => fetchToSecurity.get(sym))
          .filter((id): id is string => !!id)
        if (missedIds.length > 0) {
          const { error } = await market
            .from('security')
            .update({ performance_missing_at: new Date().toISOString() })
            .in('security_id', missedIds)
          if (error) throw new Error(`performance_missing_at update failed: ${error.message}`)
          // MARKING MUST RETRACT, for the same reason producing must. The upsert path already
          // deletes periods a successful run stopped producing; giving up on a security left its
          // OLD rows untouched — and then excluded it from the backlog for 30 days, so nothing
          // could ever correct them. That is how a stale number outlives the fix that stopped
          // generating it: REA.AX, 1803.T and MRP.JO were all still serving 1d/1w/1m = 0.00% from
          // 08-10, frozen behind a mark set on 08-12, while their real prices moved every day.
          for (let j = 0; j < confirmedDead.length; j += 100) {
            const slice = confirmedDead.slice(j, j + 100).map((s) => fetchToDisplay.get(s) ?? s)
            const { error: delErr } = await market
              .from('performance')
              .delete()
              .eq('scope', 'instrument')
              .in('scope_id', slice)
            if (delErr) throw new Error(`stale performance retract failed: ${delErr.message}`)
          }
        }
        if (throttledOut) break
        if (rows.length === 0) { emptyBatches++; continue }
        const { error } = await market
          .from('performance')
          .upsert(dedupeBy(rows, (r) => `${r.scope}|${r.scope_id}|${r.period}`),
            { onConflict: 'scope,scope_id,period' })
        if (error) throw new Error(`performance upsert failed: ${error.message}`)

        // AN UPSERT CANNOT RETRACT. A period we no longer produce keeps whatever was written last
        // time, forever — so the moment `returnsFor` starts omitting a period (a series that
        // shortened, or one broken by a unit change), the OLD wrong number survives every future
        // refresh and looks freshly written. That is the shape of every silent defect in this
        // pipeline, so the write is made authoritative: for each symbol answered, delete the
        // periods this run deliberately did not produce.
        // Grouped by the period-set signature rather than done per symbol — in practice almost
        // every symbol yields the same full set, so this is one delete, not one per security.
        const producedBySymbol = new Map<string, Set<string>>()
        for (const r of rows) {
          const set = producedBySymbol.get(r.scope_id) ?? new Set<string>()
          set.add(r.period)
          producedBySymbol.set(r.scope_id, set)
        }
        const bySignature = new Map<string, { periods: string[]; symbols: string[] }>()
        for (const [sym, periods] of producedBySymbol) {
          const sig = [...periods].sort().join(',')
          const entry = bySignature.get(sig) ?? { periods: [...periods], symbols: [] }
          entry.symbols.push(sym)
          bySignature.set(sig, entry)
        }
        for (const { periods, symbols } of bySignature.values()) {
          // `in.()` is a URL, so chunk the symbol list — 6.5 KB earns a bare 502.
          for (let j = 0; j < symbols.length; j += 100) {
            const { error: delErr } = await market
              .from('performance')
              .delete()
              .eq('scope', 'instrument')
              .in('scope_id', symbols.slice(j, j + 100))
              .not('period', 'in', `(${periods.join(',')})`)
            if (delErr) throw new Error(`stale period delete failed: ${delErr.message}`)
          }
        }
        written += rows.length
      }
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        refreshed: written,
        batchesFailed,
        emptyBatches,
        lastError,
        remaining: Math.max(0, symbols.length - written),
      })
    }

    if (resource === TICKERS_RESOURCE) {
      // Only securities that still need one, MOST VISIBLE FIRST. `pending_ticker` orders by the
      // security's weight in a sector fund, so the names a sector page actually renders are
      // resolved in the first run rather than after the whole 9.7k backlog.
      // PAGED: PostgREST caps a response at db-max-rows (1000 here), so a bare .limit(4000)
      // silently returns 1000 and the run resolves a quarter of what it could. With an API key
      // one run can map 4,000, so the page size is the binding constraint, not the rate limit.
      const PAGE = 1000
      const wanted: { securityId: string; isin: string }[] = []
      for (let page = 0; page < 4; page++) {
        const { data, error: pendErr } = await market
          .from('pending_ticker')
          .select('security_id,isin')
          // Ordered explicitly rather than trusting the view's ORDER BY: a view's ordering is not
          // contractual once PostgREST wraps it, and the ordering is the whole point of the backlog.
          .order('best_weight', { ascending: false })
          // Unique tiebreak, so the four pages are a partition rather than four samples. See the
          // note in `security-local-symbols`: ordering by a non-unique column alone lets a row be
          // returned twice and another never at all.
          .order('security_id', { ascending: true })
          .range(page * PAGE, (page + 1) * PAGE - 1)
        if (pendErr) throw new Error(`pending_ticker read failed: ${pendErr.message}`)
        const rows = data ?? []
        wanted.push(...rows.map((r) => ({ securityId: r.security_id as string, isin: r.isin as string })))
        if (rows.length < PAGE) break
      }
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, resolved: 0, remaining: 0, note: 'every security already has a ticker' })
      }

      // Written PER BATCH rather than accumulated: with a key a run maps thousands of ISINs, and
      // holding all of that in a 150 MB worker is what killed it (a bare 502, no error body — the
      // same failure and the same fix as the price refresh). This also means a worker that dies
      // keeps the progress it already made.
      const writeBatch = async (batch: { securityId: string; ticker: string; name?: string }[], missed: string[]) => {
        // Record the misses FIRST — a negative result is a result. Without it the ~80% of holdings
        // with no US listing stay in the backlog and are re-sent to OpenFIGI four times a day
        // forever, starving the securities that could actually resolve.
        if (missed.length > 0) {
          const { error: missErr } = await market
            .from('security')
            .update({ figi_missing_at: new Date().toISOString() })
            .in('security_id', missed)
          if (missErr) throw new Error(`figi_missing_at update failed: ${missErr.message}`)
        }
        if (batch.length === 0) return
        // A ticker is NOT globally unique (identifier_kind says so), so two securities can
        // legitimately want the same symbol — a different exchange, or a delisted line. The PK
        // keeps the first and `ignoreDuplicates` stops one collision failing the batch.
        const { error: insErr } = await market.from('security_identifier').upsert(
          batch.map((r) => ({
            kind_code: 'ticker',
            value: r.ticker,
            security_id: r.securityId,
            source_code: 'openfigi',
          })),
          { onConflict: 'kind_code,value', ignoreDuplicates: true },
        )
        if (insErr) throw new Error(`ticker upsert failed: ${insErr.message}`)

        // A PLACEHOLDER NAME IS NOT A NAME, and the fix arrives in this same response.
        //
        // N-PORT lets a filer report a holding as `New Issuer: BB Company ID:<n>` — a Bloomberg
        // internal id, not a company — and 28 securities carry one. The app renders `security.name`
        // verbatim, so those read as exactly that string. OpenFIGI knows them, and it has been
        // returning the name alongside the ticker all along; it was simply dropped on the floor.
        // Measured: INE377Y01014 -> BAJAJ HOUSING FINANCE LTD, AEE01569T248 -> TALABAT HOLDING PLC,
        // INE379A01028 -> ITC HOTELS LIMITED.
        //
        // Only replaces a PLACEHOLDER. A real filed name is the filing's own word for the security
        // and outranks a vendor's, which is the same rule `security_taxonomy` follows for a curated
        // sector over a provider's.
        for (const r of batch) {
          if (!r.name) continue
          const { error } = await market
            .from('security')
            .update({ name: r.name })
            .eq('security_id', r.securityId)
            .or('name.ilike.New Issuer:*,name.ilike.*Company ID:*')
          if (error) throw new Error(`placeholder rename failed: ${error.message}`)
        }
        // Now priceable and linkable, which is what `is_tradeable` means.
        const { error: updErr } = await market
          .from('security')
          .update({ is_tradeable: true })
          .in('security_id', batch.map((r) => r.securityId))
        if (updErr) throw new Error(`is_tradeable update failed: ${updErr.message}`)
      }

      const { requestsUsed, unresolved, resolvedCount } = await mapIsinsToTickers(wanted, {
        apiKey: Deno.env.get('OPENFIGI_API_KEY') ?? undefined,
        onBatch: writeBatch,
      })

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        resolved: resolvedCount,
        unresolved,
        requestsUsed,
        // What is left for the next run — this resource is incremental by design.
        remaining: Math.max(0, wanted.length - resolvedCount - unresolved),
      })
    }

    if (resource === PRICES_RESOURCE) {
      // Fetched and written in batches so peak memory is one batch, not the whole
      // universe — the one-shot version died on the node without answering.
      let batchNo = 0
      const { written, unmapped } = await loadPricesBatched(
        fetcher,
        await instrumentUniverse(),
        new Date(),
        async (rows) => {
          const n = batchNo++
          const { error } = await market.from('prices').upsert(rows, { onConflict: 'symbol,date' })
          if (error) throw new Error(`prices upsert failed on batch ${n} (${rows.length} rows): ${error.message}`)
        },
      )
      if (written === 0) throw new Error('no price rows loaded')
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, refreshed: written, unmapped })
    }

    const { rows, unmapped } = await spec!.load({
      fetcher,
      now: new Date(),
      // Universes live in the DB (editable in Studio), not in the function, so a
      // corrected ETF proxy or a new ticker takes effect without a redeploy.
      universe: async () => {
        if (resource === 'instrument-performance') return await instrumentUniverse()
        if (resource === 'group-performance') {
          // Tiers get their growth from each group's proxy ETF, which the reference data already
          // names. Scoped `<scheme>:<group>` because a group id is not unique across schemes —
          // MSCI and FTSE both have `developed`, backed by DIFFERENT funds (URTH vs VEA).
          const { data, error } = await market
            .from('classification_groups')
            .select('id,scheme_id,etf')
            .not('etf', 'is', null)
          if (error) throw new Error(`group universe read failed: ${error.message}`)
          // Skip funds already marked dead in tracked_fund. FM stopped filing in 2024 because it
          // was liquidated, and a liquidated fund has no price series either — asking for one is
          // how this resource spent a day returning 502s.
          const { data: dead } = await market
            .from('tracked_fund')
            .select('symbol')
            .eq('enabled', false)
          const retired = new Set((dead ?? []).map((f) => f.symbol as string))
          return (data ?? [])
            .filter((g) => !retired.has(g.etf as string))
            .map((g) => ({
              scopeId: `${g.scheme_id as string}:${g.id as string}`,
              symbol: g.etf as string,
            }))
        }
        const { data, error } = await market
          .from('countries')
          .select('iso2,etf_symbol')
          .not('etf_symbol', 'is', null)
        if (error) throw new Error(`universe read failed: ${error.message}`)
        return (data ?? []).map((c) => ({ scopeId: c.iso2 as string, symbol: c.etf_symbol as string }))
      },
    })
    if (unmapped.length) {
      // Loud, not fatal: a provider rename should degrade, not blank the screen.
      console.error(`market-refresh(${resource}): unmapped provider labels: ${unmapped.join(', ')}`)
    }

    const { error } = await market
      .from('performance')
      .upsert(dedupeBy(rows, (r) => `${r.scope}|${r.scope_id}|${r.period}`),
            { onConflict: 'scope,scope_id,period' })
    if (error) throw new Error(`upsert failed: ${error.message}`)

    await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
    return json({ resource, refreshed: rows.length, unmapped })
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
})
