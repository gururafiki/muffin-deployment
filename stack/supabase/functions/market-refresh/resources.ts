// Pure fetch+map logic for market-refresh, with NO Supabase dependency.
//
// Split out from index.ts on purpose: this is the part that breaks silently when a
// provider renames a field, changes a sector label, or switches fraction<->percent.
// Keeping it free of supabase-js means `check.ts` can drive it against a real
// openbb-api with nothing else running. index.ts owns HTTP, the refresh claim and
// the upsert; this file owns "what the numbers are".

export interface PerfRow {
  scope: string
  scope_id: string
  period: string
  change_pct: number | null
  as_of: string
  stale_after: string
  source: string
}

/**
 * finviz sector names -> muffin sector ids.
 *
 * finviz does NOT use GICS names: it reports "Consumer Defensive"/"Consumer
 * Cyclical"/"Financial"/"Healthcare"/"Basic Materials"/"Technology" where GICS (and
 * muffin's market.sectors) say Consumer Staples / Consumer Discretionary /
 * Financials / Health Care / Materials / Information Technology. All 11 map 1:1.
 * An unmapped name is reported, never silently inserted under a wrong id.
 */
/**
 * Provider sector label -> muffin sector id.
 *
 * Covers BOTH finviz (`equity/compare/groups`) and yfinance (`equity/profile`), because the two
 * vocabularies are the same except for one label: yfinance says "Financial Services" where finviz
 * says "Financial". Keeping one map means a security classified from a profile lands in the same
 * bucket as a sector read from the sector endpoint — the whole point of having sector ids at all.
 */
export const FINVIZ_SECTOR_IDS: Record<string, string> = {
  'Financial Services': 'financials',
  'Energy': 'energy',
  'Utilities': 'utilities',
  'Real Estate': 'real-estate',
  'Consumer Defensive': 'consumer-staples',
  'Financial': 'financials',
  'Communication Services': 'communication-services',
  'Healthcare': 'health-care',
  'Consumer Cyclical': 'consumer-discretionary',
  'Industrials': 'industrials',
  'Technology': 'information-technology',
  'Basic Materials': 'materials',
}

/**
 * finviz response field -> muffin period id.
 *
 * finviz's group performance carries 1w/1m/3m/6m/ytd/1y plus a day change under the
 * literal key "Change %". There is NO 3y/5y/10y here — those periods stay absent for
 * sectors rather than being faked from a shorter window.
 */
export const FINVIZ_PERIODS: Record<string, string> = {
  'Change %': '1d',
  'performance_1w': '1w',
  'performance_1m': '1m',
  'performance_3m': '3m',
  'performance_6m': '6m',
  'performance_ytd': 'ytd',
  'performance_1y': '1y',
}

/**
 * OpenBB reports performance as a FRACTION (-0.0366 = -3.66%); muffin-ui's
 * `changePct` is a percent. Getting this wrong yields numbers 100x too small that
 * still render as plausible-looking values, so it is asserted in check.ts.
 */
export const toPercent = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 1_000_000) / 10_000 : null

export type Fetcher = (path: string) => Promise<Record<string, unknown>[]>

/** Builds a fetcher bound to an openbb-api base URL. */
export function openbbFetcher(baseUrl: string): Fetcher {
  return async (path) => {
    const res = await fetch(`${baseUrl}${path}`, { headers: { accept: 'application/json' } })
    if (!res.ok) {
      throw new Error(`openbb ${res.status} on ${path}: ${(await res.text()).slice(0, 300)}`)
    }
    // OpenBB answers an unknown symbol with 200 and an EMPTY body, so res.json()
    // throws a bare SyntaxError that says nothing about which call failed.
    const text = await res.text()
    let body: { results?: unknown }
    try {
      body = JSON.parse(text)
    } catch {
      throw new Error(
        `openbb returned ${res.status} with an unparseable body on ${path}: ${text.slice(0, 200) || '(empty)'}`,
      )
    }
    const results = body?.results
    if (!Array.isArray(results) || results.length === 0) {
      throw new Error(`openbb returned no results for ${path}`)
    }
    return results as Record<string, unknown>[]
  }
}

export interface LoadResult {
  rows: PerfRow[]
  /** Provider labels we had no mapping for — logged, never fatal. */
  unmapped: string[]
}

/** One thing to fetch performance for: a scope_id and the symbol that proxies it. */
export interface UniverseEntry {
  scopeId: string
  symbol: string
}

export interface LoadContext {
  fetcher: Fetcher
  now: Date
  /**
   * Resolves the symbols to fetch. Supplied by index.ts from `market.countries`
   * rather than hardcoded here, so the country->ETF mapping stays editable in
   * Studio and this module stays free of any database dependency.
   */
  universe?: () => Promise<UniverseEntry[]>
}

export interface Resource {
  ttlMinutes: number
  load(ctx: LoadContext): Promise<LoadResult>
}

/**
 * Refreshable resources. Phases 2-4 (country growth, sector constituents, the asset
 * universe) add ENTRIES here — not new functions and not new tables.
 */
// ─── country performance, computed from price history ────────────────────────

/** Lookback in days per period. `1d` and `ytd` are handled specially below. */
const PERIOD_DAYS: Record<string, number> = {
  '1w': 7,
  '1m': 30,
  '3m': 91,
  '6m': 182,
  '1y': 365,
  '3y': 1095,
  '5y': 1826,
}

interface Bar {
  date: string
  close: number
}

/** Last bar at or before `iso`; null when the series does not reach back that far. */
function closeAtOrBefore(series: Bar[], iso: string): number | null {
  for (let i = series.length - 1; i >= 0; i--) {
    if (series[i].date <= iso) return series[i].close
  }
  return null
}

const daysBefore = (now: Date, days: number) =>
  new Date(now.getTime() - days * 86_400_000).toISOString().slice(0, 10)

/**
 * Price return per period for one symbol's daily series.
 *
 * PRICE return, not total return — dividends are excluded. That matches how country
 * performance is normally headlined, but it understates high-yield markets; the UI
 * labels the source so the number is never presented as more than it is.
 */
export function returnsFor(series: Bar[], now: Date): Record<string, number> {
  const out: Record<string, number> = {}
  if (series.length < 2) return out
  const latest = series[series.length - 1].close
  const pct = (from: number | null) =>
    from === null || from === 0 ? null : Math.round((latest / from - 1) * 1_000_000) / 10_000

  // 1d is the PREVIOUS BAR, not a date lookback — a weekend or holiday would
  // otherwise resolve "yesterday" to the same bar and report a flat 0.00%.
  const prev = pct(series[series.length - 2].close)
  if (prev !== null) out['1d'] = prev

  for (const [period, days] of Object.entries(PERIOD_DAYS)) {
    const v = pct(closeAtOrBefore(series, daysBefore(now, days)))
    if (v !== null) out[period] = v
  }

  // YTD anchors on the last close of LAST year, so early January is measured from
  // the true year-end rather than from the first bar of the new year (which would
  // report ~0% for the first days of trading).
  const ytd = pct(closeAtOrBefore(series, `${now.getUTCFullYear() - 1}-12-31`))
  if (ytd !== null) out['ytd'] = ytd

  return out
}


/**
 * Multi-period returns for a set of ETFs, in ONE batched request.
 *
 * Shared by `country-performance` and `group-performance`: a country's proxy fund and a tier's
 * proxy fund are the same problem, and the batching, the single-symbol `symbol`-column quirk and
 * the provider choice below are all things that should only be got right once.
 *
 * Provider is yfinance because both alternatives are unavailable: finviz's per-symbol
 * `price_performance` is broken upstream (it duplicates the first character of the symbol), and
 * fmp's `etf/price_performance` is PREMIUM and 402s on this deployment's free key.
 */
async function etfReturns(
  fetcher: Fetcher,
  entries: UniverseEntry[],
  now: Date,
  scope: string,
  ttlMinutes: number,
): Promise<{ rows: PerfRow[]; unmapped: string[] }> {
  // yfinance accepts a comma list and tags each row with `symbol`; ~19 symbols over ~5.2y is
  // ~4 MB and ~5s, inside the worker's 150 MB / 60 s budget. Per-symbol calls would be 19 round
  // trips and risk the timeout.
  const symbols = [...new Set(entries.map((e) => e.symbol))]
  const start = daysBefore(now, 1900)
  const results = await fetcher(
    `/api/v1/etf/historical?symbol=${symbols.join(',')}` +
      `&provider=yfinance&start_date=${start}&interval=1d`,
  )

  // A single-symbol response carries NO `symbol` column — the provider only adds it when several
  // are requested. Fall back to the one symbol asked for.
  const bySymbol = new Map<string, Bar[]>()
  for (const r of results) {
    const symbol = String(r.symbol ?? symbols[0])
    const close = typeof r.close === 'number' ? r.close : Number(r.close)
    const date = String(r.date ?? '').slice(0, 10)
    if (!date || !Number.isFinite(close)) continue
    const list = bySymbol.get(symbol) ?? []
    list.push({ date, close })
    bySymbol.set(symbol, list)
  }
  for (const list of bySymbol.values()) list.sort((a, b) => a.date.localeCompare(b.date))

  const asOf = now.toISOString()
  const staleAfter = new Date(now.getTime() + ttlMinutes * 60_000).toISOString()
  const rows: PerfRow[] = []
  const unmapped: string[] = []

  for (const { scopeId, symbol } of entries) {
    const series = bySymbol.get(symbol)
    // A fund that has been liquidated returns nothing (MSCI Frontier's FM stopped trading), so a
    // missing series is reported rather than silently omitted.
    if (!series || series.length < 2) {
      unmapped.push(`${scopeId}:${symbol}`)
      continue
    }
    for (const [period, changePct] of Object.entries(returnsFor(series, now))) {
      rows.push({
        scope,
        scope_id: scopeId,
        period,
        change_pct: changePct,
        as_of: asOf,
        stale_after: staleAfter,
        source: 'yfinance',
      })
    }
  }
  return { rows, unmapped }
}


/** Per-security returns are reference-ish: a slice per run, so the TTL must let the next run continue. */
export const SEC_PERF_TTL_MINUTES = 24 * 60

/**
 * Multi-period returns for EQUITIES, batched.
 *
 * Separate from `etfReturns` because the endpoint differs (`equity/price/historical`, not
 * `etf/historical`) and the window is much shorter: a constituent list offers 1D-1Y, so ~400 days
 * is enough, where a country card offers 3Y/5Y and needs ~1900. That difference is the whole
 * reason 40 equities cost about what 19 ETFs do.
 *
 * Returns rows rather than writing, so the caller can persist per batch and keep peak memory to
 * one batch — the lesson the price refresh's bare 502 taught.
 */
export async function loadEquityReturns(
  fetcher: Fetcher,
  symbols: string[],
  now: Date,
  ttlMinutes: number,
): Promise<PerfRow[]> {
  if (symbols.length === 0) return []
  const start = daysBefore(now, 400)
  const results = await fetcher(
    `/api/v1/equity/price/historical?symbol=${symbols.join(',')}` +
      `&provider=yfinance&start_date=${start}&interval=1d`,
  )

  // A single-symbol response carries NO `symbol` column — the provider only adds it when several
  // are requested.
  const bySymbol = new Map<string, Bar[]>()
  for (const r of results) {
    const symbol = String(r.symbol ?? symbols[0]).toUpperCase()
    const close = typeof r.close === 'number' ? r.close : Number(r.close)
    const date = String(r.date ?? '').slice(0, 10)
    if (!date || !Number.isFinite(close)) continue
    const list = bySymbol.get(symbol) ?? []
    list.push({ date, close })
    bySymbol.set(symbol, list)
  }
  for (const list of bySymbol.values()) list.sort((a, b) => a.date.localeCompare(b.date))

  const asOf = now.toISOString()
  const staleAfter = new Date(now.getTime() + ttlMinutes * 60_000).toISOString()
  const rows: PerfRow[] = []
  for (const symbol of symbols) {
    const series = bySymbol.get(symbol.toUpperCase())
    // A delisted or renamed ticker returns nothing. Skipped rather than written as zero.
    if (!series || series.length < 2) continue
    for (const [period, changePct] of Object.entries(returnsFor(series, now))) {
      rows.push({
        scope: 'instrument',
        scope_id: symbol,
        period,
        change_pct: changePct,
        as_of: asOf,
        stale_after: staleAfter,
        source: 'yfinance',
      })
    }
  }
  return rows
}

export const RESOURCES: Record<string, Resource> = {
  'sector-performance': {
    ttlMinutes: 24 * 60,
    async load({ fetcher, now }) {
      // provider=finviz is keyless. NOTE: finviz's own field description says
      // "US-listed stocks only", so this is US sector performance — which is what
      // the UI's sector view means today. Do not relabel it as global.
      const results = await fetcher(
        '/api/v1/equity/compare/groups?group=sector&metric=performance&provider=finviz',
      )
      const asOf = now.toISOString()
      const staleAfter = new Date(now.getTime() + this.ttlMinutes * 60_000).toISOString()
      const rows: PerfRow[] = []
      const unmapped: string[] = []

      for (const r of results) {
        const id = FINVIZ_SECTOR_IDS[String(r.name)]
        if (!id) {
          unmapped.push(String(r.name))
          continue
        }
        for (const [field, period] of Object.entries(FINVIZ_PERIODS)) {
          const pct = toPercent(r[field])
          if (pct === null) continue
          rows.push({
            scope: 'sector',
            scope_id: id,
            period,
            change_pct: pct,
            as_of: asOf,
            stale_after: staleAfter,
            source: 'finviz',
          })
        }
      }
      if (rows.length === 0) throw new Error('no rows mapped from finviz sector performance')
      return { rows, unmapped }
    },
  },

  'country-performance': {
    ttlMinutes: 24 * 60,
    async load({ fetcher, now, universe }) {
      if (!universe) throw new Error('country-performance needs a universe resolver')
      const entries = await universe()
      if (entries.length === 0) throw new Error('no countries with an etf_symbol')
      const out = await etfReturns(fetcher, entries, now, 'country', this.ttlMinutes)
      if (out.rows.length === 0) throw new Error('no country returns computed')
      return out
    },
  },

  /**
   * Growth per TIER (developed / emerging / frontier), from each group's proxy ETF.
   *
   * `market.classification_groups.etf` already names them (MSCI developed = URTH, emerging = EEM;
   * FTSE developed = VEA), which is why this needs no new reference data — only the same batched
   * price call the countries use.
   *
   * `scope_id` is `<scheme>:<group>` because a group id is NOT unique across schemes: MSCI and
   * FTSE both have `developed`, and they are different funds (URTH vs VEA) precisely because the
   * two providers disagree about which countries belong. Keying on the bare id would make one
   * silently overwrite the other.
   *
   * The World Bank scheme has no ETFs at all (income bands are not investable), so it contributes
   * nothing here and its groups keep showing no number rather than a borrowed one.
   */
  'group-performance': {
    ttlMinutes: 24 * 60,
    async load({ fetcher, now, universe }) {
      if (!universe) throw new Error('group-performance needs a universe resolver')
      const entries = await universe()
      if (entries.length === 0) throw new Error('no classification groups with an etf')
      const out = await etfReturns(fetcher, entries, now, 'group', this.ttlMinutes)
      if (out.rows.length === 0) throw new Error('no group returns computed')
      return out
    },
  },

  'instrument-performance': {
    ttlMinutes: 24 * 60,
    async load({ fetcher, now, universe }) {
      if (!universe) throw new Error('instrument-performance needs a universe resolver')
      const entries = await universe()
      if (entries.length === 0) throw new Error('no instruments to price')

      // Same batched-history technique as countries — see that resource for why
      // neither finviz nor fmp can serve per-symbol performance here.
      const symbols = [...new Set(entries.map((e) => e.symbol))]
      const results = await fetcher(
        `/api/v1/equity/price/historical?symbol=${symbols.join(',')}` +
          `&provider=yfinance&start_date=${daysBefore(now, 1900)}&interval=1d`,
      )

      const bySymbol = new Map<string, Bar[]>()
      for (const r of results) {
        const symbol = String(r.symbol ?? symbols[0])
        const close = typeof r.close === 'number' ? r.close : Number(r.close)
        const date = String(r.date ?? '').slice(0, 10)
        if (!date || !Number.isFinite(close)) continue
        const list = bySymbol.get(symbol) ?? []
        list.push({ date, close })
        bySymbol.set(symbol, list)
      }
      for (const list of bySymbol.values()) list.sort((a, b) => a.date.localeCompare(b.date))

      const asOf = now.toISOString()
      const staleAfter = new Date(now.getTime() + this.ttlMinutes * 60_000).toISOString()
      const rows: PerfRow[] = []
      const unmapped: string[] = []

      for (const { scopeId, symbol } of entries) {
        const series = bySymbol.get(symbol)
        if (!series || series.length < 2) {
          unmapped.push(symbol)
          continue
        }
        for (const [period, changePct] of Object.entries(returnsFor(series, now))) {
          rows.push({
            scope: 'instrument',
            scope_id: scopeId,
            period,
            change_pct: changePct,
            as_of: asOf,
            stale_after: staleAfter,
            source: 'yfinance',
          })
        }
      }
      if (rows.length === 0) throw new Error('no instrument returns computed')
      return { rows, unmapped }
    },
  },
}

/** Daily bars per symbol, keyed by OUR scope id. Shared by performance and prices. */
export async function loadSeries(
  fetcher: Fetcher,
  entries: UniverseEntry[],
  route: 'equity/price/historical' | 'etf/historical',
  now: Date,
  days = 1900,
): Promise<Map<string, Bar[]>> {
  const symbols = [...new Set(entries.map((e) => e.symbol))]
  const results = await fetcher(
    `/api/v1/${route}?symbol=${symbols.join(',')}` +
      `&provider=yfinance&start_date=${daysBefore(now, days)}&interval=1d`,
  )
  // A single-symbol response carries NO `symbol` column — the provider only adds it
  // when several are requested.
  const bySymbol = new Map<string, Bar[]>()
  for (const r of results) {
    const symbol = String(r.symbol ?? symbols[0])
    const close = typeof r.close === 'number' ? r.close : Number(r.close)
    const date = String(r.date ?? '').slice(0, 10)
    if (!date || !Number.isFinite(close)) continue
    const list = bySymbol.get(symbol) ?? []
    list.push({ date, close })
    bySymbol.set(symbol, list)
  }
  for (const list of bySymbol.values()) list.sort((a, b) => a.date.localeCompare(b.date))
  return bySymbol
}

/** One row of market.prices. */
export interface PriceRow {
  symbol: string
  date: string
  close: number
}

/** Calendar days of history kept for the chart — see 08-instrument-prices.sql. */
export const PRICE_WINDOW_DAYS = 400
/** Inside this many days the series is kept DAILY; before it, weekly. */
export const PRICE_DAILY_DAYS = 90
/**
 * TTLs are PRE-LAUNCH values: deliberately long, because nobody is watching these numbers yet and
 * every refresh spends someone's free-tier quota (finviz, yfinance, SEC, OpenFIGI). Going live is
 * when they should tighten — see `todos.md` -> "Market data TTLs (revisit at launch)" for the
 * intended production values (30-60 min for performance, weekly for holdings).
 *
 * A TTL is about how often it is worth ASKING, not about how often the data changes: sector
 * performance moves continuously, but a day-old number is fine for a page nobody has open.
 */
export const PRICES_TTL_MINUTES = 24 * 60

/**
 * Keep daily bars for the recent window and one bar per week before that.
 *
 * Measured 2026-08-09: storing all ~275 daily bars for 45 symbols is 12,625 rows,
 * and upserting that through PostgREST took the worker past its 60 s limit (the
 * openbb fetch itself is only ~9 s) — production returned 502. Downsampling gives
 * ~107 bars/symbol (~4.8k rows), which still draws 1M at full daily resolution and
 * 1Y with more points than a phone-width chart can resolve.
 *
 * The most recent bar is always kept: it is the one the chart's last point and the
 * "current" level come from.
 */
export function downsampleForChart(series: Bar[], now: Date): Bar[] {
  if (series.length === 0) return series
  const dailyFrom = daysBefore(now, PRICE_DAILY_DAYS)
  const out: Bar[] = []
  let lastBucket = ''
  for (const bar of series) {
    if (bar.date >= dailyFrom) {
      out.push(bar)
      continue
    }
    // Fixed 7-day buckets from the epoch — calendar weeks are not needed, only a
    // stable one-per-week choice.
    const bucket = String(Math.floor(new Date(`${bar.date}T00:00:00Z`).getTime() / 604_800_000))
    if (bucket !== lastBucket) {
      out.push(bar)
      lastBucket = bucket
    }
  }
  const newest = series[series.length - 1]
  if (out[out.length - 1]?.date !== newest.date) out.push(newest)
  return out
}

/** Symbols fetched per batch — see loadPricesBatched. */
export const PRICE_BATCH_SIZE = 12

/**
 * Fetch and shape prices in BATCHES, handing each batch to `sink` before the next
 * is fetched.
 *
 * Doing the whole universe at once works locally but returned 502 from the deployed
 * worker — Kong's bare 502, i.e. the worker died rather than answering, which is not
 * something the function's own try/catch can report. The exact cause was never
 * reproduced off the node; what IS true is that the one-shot version holds the raw
 * response, the parsed bars and every output row live simultaneously, and the worker
 * has a 150 MB cap on a box that is otherwise fully committed.
 *
 * Batching bounds peak memory to roughly one batch and makes a failure attributable
 * to a specific set of symbols instead of "the refresh". If the 502 returns, it will
 * name the batch.
 */
export async function loadPricesBatched(
  fetcher: Fetcher,
  entries: UniverseEntry[],
  now: Date,
  sink: (rows: PriceRow[]) => Promise<void>,
  batchSize = PRICE_BATCH_SIZE,
): Promise<{ written: number; unmapped: string[] }> {
  const unmapped: string[] = []
  let written = 0

  for (let i = 0; i < entries.length; i += batchSize) {
    const batch = entries.slice(i, i + batchSize)
    const bySymbol = await loadSeries(fetcher, batch, 'equity/price/historical', now, PRICE_WINDOW_DAYS)
    const rows: PriceRow[] = []
    for (const { scopeId, symbol } of batch) {
      const series = bySymbol.get(symbol)
      if (!series || series.length === 0) {
        unmapped.push(symbol)
        continue
      }
      // Written under OUR key, not the provider's (NESN vs NESN.SW).
      for (const bar of downsampleForChart(series, now)) {
        rows.push({ symbol: scopeId, date: bar.date, close: bar.close })
      }
    }
    bySymbol.clear()
    if (rows.length > 0) {
      await sink(rows)
      written += rows.length
    }
  }
  return { written, unmapped }
}

/** Collect-everything variant, for tests that want the whole set in hand. */
export async function loadPrices(
  fetcher: Fetcher,
  entries: UniverseEntry[],
  now: Date,
): Promise<{ rows: PriceRow[]; unmapped: string[] }> {
  const rows: PriceRow[] = []
  const { unmapped } = await loadPricesBatched(fetcher, entries, now, async (batch) => {
    rows.push(...batch)
  })
  return { rows, unmapped }
}

/**
 * Profile refresh — the ONE resource that does not write market.performance.
 *
 * It fills `market.instruments` (industry = the real sub-sector, country, market cap)
 * from equity/profile. Kept separate from the RESOURCES table because its output shape
 * is different; index.ts dispatches it explicitly.
 */
export interface ProfileUpdate {
  symbol: string
  name?: string
  provider_sector?: string
  industry?: string
  country?: string
  market_cap?: number
  currency?: string
  updated_at: string
}

export const PROFILE_TTL_MINUTES = 7 * 24 * 60

/**
 * Reference data (fund holdings, resolved tickers) — a week.
 *
 * N-PORT is quarterly and filed ~60 days in arrears, and a ticker resolved from an ISIN does not
 * go stale. A price-shaped TTL here would just re-ask SEC and OpenFIGI for last quarter's answer.
 * The ticker resolution is incremental, so this also has to be short enough that consecutive runs
 * can work through the backlog rather than being told the data is fresh.
 */
export const REFERENCE_TTL_MINUTES = 30 * 24 * 60

/**
 * Ticker resolution.
 *
 * This MUST stay shorter than the fund-holdings TTL. The resource is INCREMENTAL — it does a slice
 * per run — so a TTL sized as "the answer is still good" stalls it: it once carried the 7-day
 * reference TTL, one run resolved a page, and every run for the next week was told the data was
 * fresh while ~9,600 securities sat unresolved.
 *
 * A day is safe now only because the backlog is drained and new securities appear just after a
 * monthly holdings ingest. If a fund is added by hand, run this with `force` rather than waiting.
 * Cheap either way: with an empty backlog it returns without calling OpenFIGI at all.
 */
export const TICKERS_TTL_MINUTES = 24 * 60

export async function loadProfiles(
  fetcher: Fetcher,
  entries: UniverseEntry[],
  now: Date,
): Promise<ProfileUpdate[]> {
  if (entries.length === 0) return []
  // The provider answers under the PRICE symbol, which is not always our primary
  // key (NESN vs NESN.SW), so map its reply back rather than writing a row under a
  // key that does not exist.
  const toScopeId = new Map(entries.map((e) => [e.symbol.toUpperCase(), e.scopeId]))
  const results = await fetcher(
    `/api/v1/equity/profile?symbol=${[...new Set(entries.map((e) => e.symbol))].join(',')}` +
      `&provider=yfinance`,
  )
  const updatedAt = now.toISOString()
  const out: ProfileUpdate[] = []
  for (const r of results) {
    const symbol = toScopeId.get(String(r.symbol ?? '').toUpperCase())
    if (!symbol) continue
    const cap = Number(r.market_cap)
    out.push({
      symbol,
      name: r.name ? String(r.name) : undefined,
      provider_sector: r.sector ? String(r.sector) : undefined,
      // yfinance exposes the industry as `industry_category`, NOT `industry` —
      // `industry` exists on the response and is always null, which silently
      // produced empty sub-sectors until it was checked against real output.
      industry: r.industry_category ? String(r.industry_category) : undefined,
      country: r.hq_country ? String(r.hq_country) : undefined,
      market_cap: Number.isFinite(cap) ? cap : undefined,
      currency: r.currency ? String(r.currency) : undefined,
      updated_at: updatedAt,
    })
  }
  return out
}
