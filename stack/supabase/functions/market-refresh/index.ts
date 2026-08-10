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
import { mapIsinsToTickers } from './figi.ts'
import { loadFundDirectory } from './edgar.ts'
import {
  loadPricesBatched,
  loadProfiles,
  openbbFetcher,
  PRICES_TTL_MINUTES,
  PROFILE_TTL_MINUTES,
  REFERENCE_TTL_MINUTES,
  RESOURCES,
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
function isServiceRole(req: Request): boolean {
  const token = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '')
  if (!token) return false
  try {
    const [, payload] = token.split('.')
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/'))).role === 'service_role'
  } catch {
    return false
  }
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
  const EXTRA = [PROFILE_RESOURCE, PRICES_RESOURCE, HOLDINGS_RESOURCE, TICKERS_RESOURCE]
  const spec = RESOURCES[resource]
  if (!spec && !EXTRA.includes(resource)) {
    return json({ error: `unknown resource '${resource}'`, known: [...Object.keys(RESOURCES), ...EXTRA] }, 400)
  }
  const ttlMinutes = spec
    ? spec.ttlMinutes
    : resource === PRICES_RESOURCE
      ? PRICES_TTL_MINUTES
      : resource === HOLDINGS_RESOURCE || resource === TICKERS_RESOURCE
        // Reference data, not prices: N-PORT is quarterly and a resolved ticker does not expire.
        // A short TTL here would just re-ask SEC and OpenFIGI for last quarter's answer.
        ? REFERENCE_TTL_MINUTES
        : PROFILE_TTL_MINUTES

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

    if (resource === TICKERS_RESOURCE) {
      // Only securities that still need one, MOST VISIBLE FIRST. `pending_ticker` orders by the
      // security's weight in a sector fund, so the names a sector page actually renders are
      // resolved in the first run rather than after the whole 9.7k backlog.
      const { data: pending, error: pendErr } = await market
        .from('pending_ticker')
        .select('security_id,isin')
        // Ordered explicitly rather than trusting the view's ORDER BY: a view's ordering is not
        // contractual once PostgREST wraps it, and the ordering is the whole point of the backlog.
        .order('best_weight', { ascending: false })
        .limit(4000)
      if (pendErr) throw new Error(`pending_ticker read failed: ${pendErr.message}`)
      const wanted = (pending ?? []).map((r) => ({
        securityId: r.security_id as string,
        isin: r.isin as string,
      }))
      if (wanted.length === 0) {
        await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
        return json({ resource, resolved: 0, remaining: 0, note: 'every security already has a ticker' })
      }

      const { results, requestsUsed, unresolved } = await mapIsinsToTickers(wanted, {
        apiKey: Deno.env.get('OPENFIGI_API_KEY') ?? undefined,
      })

      // A ticker is NOT globally unique (identifier_kind says so), so two securities can legitimately
      // want the same symbol — different exchanges, or a delisted line. The PK keeps the first and
      // `ignoreDuplicates` stops the whole batch failing over it.
      let written = 0
      for (let i = 0; i < results.length; i += 500) {
        const chunk = results.slice(i, i + 500)
        const { error } = await market.from('security_identifier').upsert(
          chunk.map((r) => ({
            kind_code: 'ticker',
            value: r.ticker,
            security_id: r.securityId,
            source_code: 'openfigi',
          })),
          { onConflict: 'kind_code,value', ignoreDuplicates: true },
        )
        if (error) throw new Error(`ticker upsert failed: ${error.message}`)
        written += chunk.length
      }
      // Now priceable and linkable, which is what `is_tradeable` means.
      for (let i = 0; i < results.length; i += 500) {
        const ids = results.slice(i, i + 500).map((r) => r.securityId)
        const { error } = await market.from('security').update({ is_tradeable: true }).in('security_id', ids)
        if (error) throw new Error(`is_tradeable update failed: ${error.message}`)
      }

      await market.rpc('finish_refresh', { p_resource: resource, p_ok: true })
      return json({
        resource,
        resolved: written,
        unresolved,
        requestsUsed,
        // What is left for the next run — this resource is incremental by design.
        remaining: Math.max(0, wanted.length - written - unresolved),
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
