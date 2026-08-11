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
import { listExchange, mapIsinsToLocalSymbols, mapIsinsToTickers } from './figi.ts'
import { hasLocalExchange } from './exchanges.ts'
import { loadFundDirectory } from './edgar.ts'
import {
  loadPricesBatched,
  loadProfiles,
  openbbFetcher,
  PRICES_TTL_MINUTES,
  PROFILE_TTL_MINUTES,
  REFERENCE_TTL_MINUTES,
  TICKERS_TTL_MINUTES,
  RESOURCES,
  FINVIZ_SECTOR_IDS,
  loadEquityReturns,
  SEC_PERF_TTL_MINUTES,
  BACKLOG_TTL_MINUTES,
} from './resources.ts'

const OPENBB_URL = Deno.env.get('OPENBB_API_URL') ?? 'http://openbb-api:6900'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const JSON_HEADERS = { 'Content-Type': 'application/json' }

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
  let force = false
  try {
    const body = await req.json()
    if (body?.resource) resource = String(body.resource)
    if (body?.fund) fundScope = String(body.fund).toUpperCase()
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
  const SEC_PERF_RESOURCE = 'security-performance'
  const LOCAL_SYM_RESOURCE = 'security-local-symbols'
  const LISTINGS_RESOURCE = 'exchange-listings'
  const EXTRA = [
    PROFILE_RESOURCE, PRICES_RESOURCE, HOLDINGS_RESOURCE, TICKERS_RESOURCE, DERIVE_RESOURCE,
    SEC_PROFILE_RESOURCE, SEC_PERF_RESOURCE, LOCAL_SYM_RESOURCE, LISTINGS_RESOURCE,
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
      : resource === SEC_PROFILE_RESOURCE || resource === SEC_PERF_RESOURCE || resource === LOCAL_SYM_RESOURCE || resource === LISTINGS_RESOURCE
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
      const { error } = await market.from('instruments').upsert(updates, { onConflict: 'symbol' })
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
    if (resource === LISTINGS_RESOURCE) {
      const { data: cursors, error: curErr } = await market
        .from('exchange_cursor')
        .select('exch_code,country_iso2,suffix,next_cursor,last_run_at')
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
      const { listings, next, pages, total } = await listExchange(
        exch,
        (target.next_cursor as string | null) ?? undefined,
        { apiKey: Deno.env.get('OPENFIGI_API_KEY') ?? undefined },
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
        const { error } = await market.from('exchange_listing').upsert(chunk, { onConflict: 'figi' })
        if (error) throw new Error(`exchange_listing upsert failed: ${error.message}`)
        written += chunk.length
      }

      const { error: updErr } = await market
        .from('exchange_cursor')
        .update({
          // A null cursor means the venue is exhausted, so the next run starts it over rather than
          // resuming a page that no longer exists.
          next_cursor: next ?? null,
          last_run_at: new Date().toISOString(),
          listings: written,
        })
        .eq('exch_code', exch)
      if (updErr) throw new Error(`exchange_cursor update failed: ${updErr.message}`)

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, exchange: exch, written, pages, total, complete: !next })
    }

    if (resource === LOCAL_SYM_RESOURCE) {
      const wanted: { securityId: string; isin: string; countryIso2: string }[] = []
      for (let page = 0; page < 3; page++) {
        const { data, error } = await market
          .from('pending_local_symbol')
          .select('security_id,isin,country_iso2')
          .order('best_weight', { ascending: false })
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
      const addressable = wanted.filter((w) => hasLocalExchange(w.countryIso2))
      if (addressable.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, resolved: 0, remaining: 0, note: 'no addressable securities pending' })
      }

      const { resolvedCount, requestsUsed, unresolved } = await mapIsinsToLocalSymbols(addressable, {
        apiKey: Deno.env.get('OPENFIGI_API_KEY') ?? undefined,
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

    if (resource === SEC_PROFILE_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_profile')
        .select('security_id,symbol')
        .order('best_weight', { ascending: false })
        .limit(1000)
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

      const deadline = Date.now() + 35_000
      // 20, not 50: a profile lookup is one upstream fetch PER SYMBOL inside yfinance, and foreign
      // listings are markedly slower than US ones. A smaller batch keeps each call inside the
      // fetcher's timeout instead of relying on it.
      const BATCH = 20
      let classified = 0
      let unmapped = 0
      let batchesFailed = 0
      for (let i = 0; i < wanted.length && Date.now() < deadline; i += BATCH) {
        const batch = wanted.slice(i, i + BATCH)
        const bySymbol = new Map(batch.map((b) => [b.symbol.toUpperCase(), b.securityId]))
        // A THROW and an EMPTY ANSWER are different facts and must not be collapsed. If the whole
        // batch fails, the provider is down or rate-limiting — mark nothing, or a single outage
        // would negative-cache thousands of perfectly answerable securities for a month.
        let rows: Record<string, unknown>[] = []
        let providerFailed = false
        try {
          rows = await fetcher(
            `/api/v1/equity/profile?symbol=${batch.map((b) => b.symbol).join(',')}&provider=yfinance`,
          )
        } catch (_e) {
          providerFailed = true
        }
        if (providerFailed || rows.length === 0) {
          // Zero rows for a whole batch is indistinguishable from a failure, so it is treated as
          // one. This is exactly the state that made the drain loop spin: `classified: 0,
          // unmapped: 0, remaining: 1000`, run after run, with nothing to say why.
          batchesFailed++
          continue
        }

        const writes: Record<string, unknown>[] = []
        for (const r of rows) {
          const securityId = bySymbol.get(String(r.symbol ?? '').toUpperCase())
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
            .upsert(writes, { onConflict: 'security_id,node_id,source_code' })
          if (error) throw new Error(`security_taxonomy upsert failed: ${error.message}`)
          classified += writes.length
        }

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
        unmapped,
        batchesFailed,
        remaining: Math.max(0, wanted.length - classified - unmapped),
      })
    }

    // Per-security returns. This is why most constituents render no % change: market.performance
    // scope='instrument' only ever covered the 35 curated symbols.
    if (resource === SEC_PERF_RESOURCE) {
      const { data: pending, error: pendErr } = await market
        .from('pending_performance')
        .select('symbol,fetch_symbol')
        .order('best_weight', { ascending: false })
        .limit(1000)
      if (pendErr) throw new Error(`pending_performance read failed: ${pendErr.message}`)
      // FETCH by the provider's address (`005930.KS`), STORE under the display ticker — the app
      // looks a stock up by the symbol it shows, not by the one yfinance wants.
      const fetchToDisplay = new Map<string, string>()
      for (const r of pending ?? []) {
        fetchToDisplay.set(r.fetch_symbol as string, r.symbol as string)
      }
      const symbols = [...fetchToDisplay.keys()]
      if (symbols.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, refreshed: 0, remaining: 0, note: 'every security has fresh returns' })
      }

      // 40 symbols x ~400 bars is ~1 MB. The country refresh proves 19 symbols x 1900 bars (~4 MB)
      // is safe, so this stays well inside the worker while still covering a page per batch.
      const BATCH = 40
      const deadline = Date.now() + 35_000
      const now = new Date()
      let written = 0
      for (let i = 0; i < symbols.length && Date.now() < deadline; i += BATCH) {
        const batch = symbols.slice(i, i + BATCH)
        const fetched = await loadEquityReturns(fetcher, batch, now, SEC_PERF_TTL_MINUTES).catch(() => [])
        const rows = fetched.map((r) => ({ ...r, scope_id: fetchToDisplay.get(r.scope_id) ?? r.scope_id }))
        if (rows.length === 0) continue
        const { error } = await market
          .from('performance')
          .upsert(rows, { onConflict: 'scope,scope_id,period' })
        if (error) throw new Error(`performance upsert failed: ${error.message}`)
        written += rows.length
      }
      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({ resource, refreshed: written, remaining: Math.max(0, symbols.length - written) })
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
      const writeBatch = async (batch: { securityId: string; ticker: string }[], missed: string[]) => {
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
      .upsert(rows, { onConflict: 'scope,scope_id,period' })
    if (error) throw new Error(`upsert failed: ${error.message}`)

    await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
    return json({ resource, refreshed: rows.length, unmapped })
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e)
    // Record the failure: begin_refresh() then applies its error backoff, so a
    // broken upstream is retried soon but not on every single trigger.
    await market.rpc('finish_refresh', { p_resource: resource, p_ok: false, p_error: message })
    console.error(`market-refresh(${resource}) failed: ${message}`)
    return json({ resource, error: message }, 502)
  }
})
