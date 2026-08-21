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
  /**
   * Daily-reinvested TOTAL return for the same period, or null when it could not be computed.
   *
   * NULL IS NOT ZERO and must never be coalesced to `change_pct`: that would erase the difference
   * between "this security paid no income" and "we do not know what it paid". Where a security
   * genuinely paid nothing in the window the two values are equal anyway, which is exactly why an
   * overwrite would look correct in the cases where it changes nothing.
   */
  total_return_pct?: number | null
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

/**
 * Symbols for a batched `?symbol=` parameter — each ENCODED, joined by a literal comma.
 *
 * The comma stays raw because it is OpenBB's list separator; everything else must not be.
 * Single-symbol calls already used `encodeURIComponent`; the eight batched ones interpolated
 * `join(',')` straight into the URL, and real tickers are not URL-safe:
 *
 *   `&`  `PE&OLES*.MX` (Industrias Peñoles) — the WORST case, and silent. Unencoded it ENDS the
 *        `symbol` parameter and starts a new one, so the provider sees a truncated list, answers
 *        200 for it, and every symbol after the `&` in that batch vanishes with no error.
 *   `/`  `BRK/B`, and the UK convention `BP/.L` `RR/.L` `AV/.L` `NG/.L` — a 400 that fails the
 *        WHOLE batch of 20 (measured 2026-08-11: `openbb 400 on /api/v1/equity/profile?
 *        symbol=NDA.HE,388.HK,PBK.KL,MAY.KL,BRK/B`). One dead symbol killing a batched call is a
 *        recurring shape here; see `group-performance` and FM.
 *   `*`  `WALMEX*.MX` `AC*.MX` — legal in a URL and left alone by `encodeURIComponent`, so this
 *        does not fix them. That is a SYMBOL-FORMAT problem, not a URL one: these are Bloomberg
 *        tickers from OpenFIGI and yfinance spells them differently. Tracked separately rather
 *        than guessed at — authoring a translation table from memory is the `exchanges.ts` mistake.
 *
 * Measured in a 1,000-symbol sample of `pending_industry`: 10 with `*`, 8 with `/`, 1 with `&`.
 */
export const symbolList = (symbols: string[]): string =>
  symbols.map((s) => encodeURIComponent(s)).join(',')

/**
 * Last-wins dedupe on the CONFLICT KEY, for anything about to be `upsert`ed with `DO UPDATE`.
 *
 * Postgres refuses an `INSERT ... ON CONFLICT DO UPDATE` whose statement contains the same conflict
 * key twice — `ON CONFLICT DO UPDATE command cannot affect row a second time` (SQLSTATE 21000). It
 * is not a warning and not a partial write: the whole statement fails, which fails the batch, which
 * fails the resource.
 *
 * MEASURED 2026-08-12, from the edge-runtime logs on the node:
 *   [Error] market-refresh(security-industries) failed:
 *           security_taxonomy upsert failed: ON CONFLICT DO UPDATE command cannot affect row a second time
 *
 * `pending_industry` yields one row per (security, level-1 sector), so a security classified into
 * two sectors is returned TWICE, fetched twice, and produces two identical
 * `(security_id, node_id, source_code)` writes. That is why the failure looked like it depended on
 * page size — the duplicated securities only fall inside the larger slices, so `limit` 10 and 20
 * succeeded while 40, 100 and 300 returned a bare 502.
 *
 * This is the THIRD time this shape has bitten: `ingest.ts` already dedupes fund holdings because
 * one filing lists a position in several lots, and the sector views had to `distinct on` for the
 * same reason. A provider list, a backlog view and a filing can all repeat a key; the upsert is
 * where that stops being harmless.
 *
 * `ignoreDuplicates: true` (DO NOTHING) has no such restriction, so those call sites are safe.
 */
export function dedupeBy<T>(rows: T[], key: (row: T) => string): T[] {
  const byKey = new Map<string, T>()
  for (const row of rows) byKey.set(key(row), row)
  return [...byKey.values()]
}

/**
 * Fetch a batch; if the batch fails, ISOLATE the symbols that broke it instead of losing all of it.
 *
 * "One dead symbol kills a batched provider call" is the most repeated failure in this pipeline —
 * `group-performance` on FM (liquidated 2025), `security-profiles` on foreign listings, and now
 * `security-industries`, whose highest-weight page permanently contains `BRK/B`, `WALMEX*.MX`,
 * `RR/.L` and `PE&OLES*.MX`. Those are Bloomberg spellings from OpenFIGI; encoding them made the
 * URL well-formed and the provider still answers 400:
 *
 *   openbb 400 on /api/v1/equity/profile?symbol=NDA.HE,...,BRK%2FB,...,PE%26OLES*.MX
 *
 * Because the backlog is ordered by fund weight and those names are heavy, that batch sits at the
 * head of EVERY run — so twenty securities were re-fetched and re-failed forever, and the nineteen
 * innocent ones never got a chance. `industry_missing_at` could not save them either: it is only
 * written when a batch comes back EMPTY, and a 400 is not empty.
 *
 * The provider knows which symbol is bad, so ask it rather than guessing from the spelling. The
 * retry only happens on failure, so a healthy run pays nothing, and it is bounded by the caller's
 * deadline — an isolation pass must never be the thing that kills the worker.
 *
 * Returns the rows that DID answer plus the symbols that individually failed, so the caller can
 * negative-cache exactly those and stop asking.
 */
export async function fetchWithIsolation(
  fetcher: Fetcher,
  buildPath: (symbols: string[]) => string,
  symbols: string[],
  timeoutMs: number,
  deadline: number,
  /**
   * A symbol the provider is known to answer for, used to tell an OUTAGE from a batch in which
   * every symbol is genuinely uncovered. Pass null to skip the probe.
   *
   * WHY THIS EXISTS. The count rule below — "if every symbol failed alone, blame the provider" —
   * is an INFERENCE, and it becomes wrong in exactly the situation a draining backlog produces:
   * the answerable securities leave, the unanswerable ones concentrate, and eventually a whole
   * batch is legitimately uncovered. Measured 2026-08-20, the head of `pending_price_history` was
   * ICT.PS, FAB.AE, EAND.AE, BDO.PS, WARBABAN.KW, ANDINAB.SN — the Philippines, UAE, Kuwait and
   * Chile, all outside keyless yfinance. Nothing could be marked, so the same 24 came back every
   * run and the resource reported `written: 0` for ever while the provider was demonstrably
   * healthy (AAPL returned 1,077 weekly bars in the same minute).
   *
   * A control symbol replaces the inference with evidence: if it answers, the provider is up and
   * the symbols that failed alone are genuinely bad.
   */
  control: string | null = 'AAPL',
): Promise<{ rows: Record<string, unknown>[]; dead: string[]; error: string | null }> {
  try {
    const rows = await fetcher(buildPath(symbols), timeoutMs)
    // A 200 WITH NO ROWS IS NOT A SUCCESS. yfinance answers a throttle this way, and a batch of
    // uncovered symbols answers it this way too — indistinguishable here, and the difference is
    // whether the caller may mark them. Falling through to the isolation path below is what lets
    // the control symbol decide.
    if (rows.length > 0 || symbols.length <= 1) return { rows, dead: [], error: null }
  } catch (e) {
    return await isolate(fetcher, buildPath, symbols, timeoutMs, deadline, control,
      e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200))
  }
  return await isolate(fetcher, buildPath, symbols, timeoutMs, deadline, control,
    'batch answered with no rows')
}

async function isolate(
  fetcher: Fetcher,
  buildPath: (symbols: string[]) => string,
  symbols: string[],
  timeoutMs: number,
  deadline: number,
  control: string | null,
  error: string,
): Promise<{ rows: Record<string, unknown>[]; dead: string[]; error: string | null }> {
  {
    // A single symbol that fails alone is genuinely bad; one that succeeds alone was collateral.
    // An EMPTY answer counts as failing: the question is whether this symbol yields data, and a
    // 200 with no rows is a no.
    const rows: Record<string, unknown>[] = []
    const dead: string[] = []
    for (const symbol of symbols) {
      const remaining = deadline - Date.now()
      // Out of budget: the untried symbols are NOT marked dead. Recording them as unanswerable
      // because we ran out of time would be the negative-cache equivalent of blaming the victim.
      if (remaining < 2_000) break
      try {
        const got = await fetcher(buildPath([symbol]), Math.min(timeoutMs, remaining))
        if (got.length > 0) rows.push(...got)
        else dead.push(symbol)
      } catch {
        dead.push(symbol)
      }
    }
    // IF NOTHING ANSWERED, BLAME THE PROVIDER, NOT THE UNIVERSE.
    //
    // A bad symbol is rare and isolated — a handful of Bloomberg spellings in a batch of twenty.
    // When EVERY symbol fails alone, the far likelier explanation is that the provider is down or
    // rate-limiting, and calling twenty securities permanently unanswerable on that evidence is how
    // a backlog destroys itself.
    //
    // MEASURED THE HARD WAY, 2026-08-12: draining aggressively tripped yfinance's rate limit, every
    // batch then failed, and this function negative-cached **1,369 securities for 30 days** —
    // including `HTHT` (H World, Nasdaq) and `LEGN` (Legend Biotech, Nasdaq), which are perfectly
    // ordinary tickers. The runs reported `classified: 0, noIndustry: 200` and looked like healthy
    // progress. Cleared by hand; this is what stops a repeat.
    //
    // `security-performance` already carried exactly this rule in a comment — "if the whole batch
    // fails, the provider is down or rate-limiting, mark nothing" — and it did not travel to the
    // helper that generalised the batching. A rule written at one call site is not a rule.
    //
    // FIRST, THOUGH: ASK THE ERROR. It usually says.
    //
    // The count rule above is an INFERENCE, and the provider states the answer outright —
    // `YFRateLimitError: Too Many Requests` is not a fact about a symbol under any reading. Acting
    // on the message instead of the tally also covers the case counts cannot see at all: a
    // throttle that refuses only SOME batches, where `rows.length > 0` and the count rule never
    // fires, so a handful of securities get blamed for a rate limit on every run.
    //
    // Found by causing it, 2026-08-13: draining six resources back to back tripped the limit, and
    // the truncated message (`Error getting data for ITGR -> YFR…`) read as an ordinary symbol
    // failure. That is how it costs 1,369 negative-cached securities — the message is right there
    // and nothing was reading it.
    if (throttled(error)) {
      return { rows, dead: [], error: `${error} (provider is RATE-LIMITING — no symbol blamed)` }
    }
    //
    // THE COUNT RULE STAYS AS IT WAS. It was briefly changed to blame the symbols whenever the
    // provider had already returned rows earlier in the run, on the theory that a draining backlog
    // concentrates its unanswerable tail into uniformly-bad batches. MEASURED AND WRONG: after the
    // throttling stopped, `security-industries` reported `remaining: 0, note: every security has an
    // industry`. The batches that looked permanently stuck had drained — every failure was this
    // rate limit, self-inflicted by draining six resources back to back.
    //
    // The theory was also unsafe on its own terms: a rate limit is PROGRESSIVE, so a run can answer
    // 195 securities and then start refusing, and "it answered earlier" is not evidence it is up
    // now. It would have blamed innocent securities in exactly the situation that once
    // negative-cached 1,369 of them.
    // AND THE CONTROL SYMBOL TURNS THAT INFERENCE INTO EVIDENCE.
    //
    // The count rule is right when the provider is refusing, and wrong when a draining backlog has
    // concentrated genuinely uncovered securities into one batch — a state this pipeline reaches
    // by design, and did: `pending_price_history` stalled on 24 Philippine, Emirati, Kuwaiti and
    // Chilean symbols for which yfinance has nothing, reporting `written: 0` for ever while AAPL
    // returned 1,077 bars in the same minute.
    //
    // So ask something known to work. If it answers, the provider is up and these symbols really
    // are unanswerable; if it does not, mark nothing. One extra call, and only for a batch that
    // produced nothing at all.
    if (rows.length === 0 && dead.length > 0) {
      if (control && deadline - Date.now() > 4_000) {
        try {
          const probe = await fetcher(buildPath([control]), Math.min(timeoutMs, deadline - Date.now()))
          if (probe.length > 0) {
            return { rows, dead, error: `${error} (control ${control} answered — the provider is up and these symbols are unanswerable)` }
          }
        } catch {
          // The control failed too; fall through to treating this as an outage.
        }
      }
      return { rows, dead: [], error: `${error} (all ${dead.length} failed individually and the control did not answer — treated as a provider outage, not bad symbols)` }
    }
    return { rows, dead, error }
  }
}

/**
 * Does this provider error say the provider is REFUSING us, rather than saying anything about the
 * symbol we asked for?
 *
 * Matched on the wire text because that is where the provider states it. Every entry was seen in a
 * real response from this deployment or is the standard HTTP spelling of the same thing; the list
 * is deliberately short, since a false positive here means a genuinely dead symbol is retried
 * forever, and a false negative means a rate limit is recorded as 20 unanswerable securities.
 */
export function throttled(message: string): boolean {
  const m = message.toLowerCase()
  return m.includes('ratelimit') ||
    m.includes('rate limit') ||
    m.includes('too many requests') ||
    m.includes('429')
}

export type Fetcher = (path: string, timeoutMs?: number) => Promise<Record<string, unknown>[]>

/** Builds a fetcher bound to an openbb-api base URL. */
/**
 * @param timeoutMs Per-request ceiling. WITHOUT ONE, a slow upstream call does not fail — it runs
 *   past the worker's 60s limit and the worker is killed, which surfaces as a bare 502 with no
 *   error body and nothing naming the call. That is exactly how `security-profiles` broke the
 *   moment its symbols became foreign listings: yfinance answers `equity/profile` for 50 non-US
 *   tickers far more slowly than for 50 US ones, and a resource that catches provider errors per
 *   batch never got the chance to catch anything.
 *
 *   A timeout turns that into a skipped batch, which the caller already knows how to report.
 */
export function openbbFetcher(baseUrl: string, timeoutMs = 20_000): Fetcher {
  return async (path, overrideTimeoutMs) => {
    const res = await fetch(`${baseUrl}${path}`, {
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(overrideTimeoutMs ?? timeoutMs),
    })
    if (!res.ok) {
      throw new Error(`openbb ${res.status} on ${path}: ${(await res.text()).slice(0, 300)}`)
    }
    // 204 NO CONTENT is OpenBB saying "the provider has nothing for these symbols" — a legitimate
    // answer, not a failure. Measured against `.SR`, `.TA` and `.NS` listings, which yfinance
    // simply does not carry. Treating it as an error failed the whole batch and lost the symbols
    // in it that WOULD have returned data.
    if (res.status === 204) return []

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
    // An empty `results` is also "no data" rather than a fault. Callers that REQUIRE rows say so
    // themselves (`no profiles returned`, `no country returns computed`); making the fetcher throw
    // meant a batch of unlisted symbols was indistinguishable from a provider outage.
    if (!Array.isArray(results)) {
      throw new Error(`openbb returned a non-array \`results\` for ${path}`)
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

export interface Bar {
  date: string
  close: number
  /**
   * Cash dividend with this bar's date as the EX-DATE, when the provider reported one.
   *
   * THIS ARRIVES ON A CALL WE ALREADY MAKE. openbb's yfinance provider sets
   * `include_actions: bool = Field(default=True)` and aliases the column
   * (`__alias_dict__ = {'dividend': 'dividends'}`), so every price response has carried this field
   * and `barFrom` discarded it. Verified against Yahoo directly: the chart response returns
   * `events.dividends` alongside the bars in ONE request.
   *
   * Fifth instance of the same lesson — market cap twice, the operating country, the currency, and
   * now this — and the cheapest of them, because it needs no new request and not even a new
   * request PARAMETER.
   */
  dividend?: number
  /**
   * Split RATIO with this bar's date as the ex-date (2 = two-for-one, 0.1 = a one-for-ten
   * reverse), when the provider reported one. Arrives on the same response as `dividend` —
   * openbb aliases it `split_ratio` from yfinance's `stock_splits`.
   *
   * RECORDED, NOT APPLIED. Bars come back already split-adjusted (`adjustment` defaults to
   * `splits_only`), so nothing here corrects a price and nothing should: applying these to
   * already-adjusted closes would divide them a second time. Verified on NFLX's 10-for-1 of
   * 2025-11-17, whose stored series is smooth across the ex-date. This is a fact worth having —
   * a stock page can say a split happened — not an input to the return maths.
   */
  splitRatio?: number
}

/**
 * One provider row -> a usable bar, or null.
 *
 * A CLOSE OF ZERO IS NOT A PRICE, and rejecting it is the whole point of this helper.
 * `Number.isFinite(0)` is true, so a zero bar used to be accepted like any other — and because
 * `returnsFor` guards only the DENOMINATOR (`from === 0`), a zero as the LATEST close makes every
 * period compute `(0 / from - 1)` = exactly -100%.
 *
 * Measured 2026-08-11: 1,078 of 20,399 `performance` rows sat at exactly -100% — 154 securities,
 * each with -100% on ALL SEVEN periods including `1d`. A security cannot fall 100% in a day and
 * also 100% over a year; that is a computation, not a market. They are concentrated in late
 * timezones (India 50, Taiwan 36, mainland China 34, Hong Kong 8, Korea 3) plus 22 US listings —
 * i.e. an empty or not-yet-traded session, not 154 simultaneous bankruptcies.
 *
 * `check.ts` has asserted `every close is positive` against the live provider all along; it only
 * ever ran over the curated instruments, which are liquid US names that never produce a zero bar.
 * The invariant was stated but never enforced where the data actually enters.
 *
 * Dropping the bar (rather than zeroing the return) means the series simply ends at the last real
 * close, so the reported move is stale-but-true instead of fabricated. A security whose every bar
 * is zero yields a series shorter than 2 and is skipped, which is the honest answer: no data.
 */
export function barFrom(r: Record<string, unknown>, fallbackSymbol: string): { symbol: string; bar: Bar } | null {
  const symbol = String(r.symbol ?? fallbackSymbol)
  const close = typeof r.close === 'number' ? r.close : Number(r.close)
  const date = String(r.date ?? '').slice(0, 10)
  if (!date || !Number.isFinite(close) || close <= 0) return null
  // A dividend of 0 is the provider saying "no dividend on this bar", not a zero-value event, so
  // only a positive number is carried. Guarded rather than trusted: a string would coerce.
  const div = typeof r.dividend === 'number' ? r.dividend : Number(r.dividend)
  const dividend = Number.isFinite(div) && div > 0 ? div : undefined
  // A ratio of 1 is "no split on this bar" — the provider's way of saying nothing happened, the
  // same as a 0 dividend. A ratio of 0 would be nonsense and is rejected rather than stored.
  const sr = typeof r.split_ratio === 'number' ? r.split_ratio : Number(r.split_ratio)
  const splitRatio = Number.isFinite(sr) && sr > 0 && Math.abs(sr - 1) > 1e-9 ? sr : undefined
  const bar: Bar = { date, close }
  if (dividend !== undefined) bar.dividend = dividend
  if (splitRatio !== undefined) bar.splitRatio = splitRatio
  return { symbol, bar }
}

/** Index of the last bar at or before `iso`; null when the series does not reach back that far. */
function indexAtOrBefore(series: Bar[], iso: string): number | null {
  for (let i = series.length - 1; i >= 0; i--) {
    if (series[i].date <= iso) return i
  }
  return null
}

/**
 * A single-bar move this large is a UNIT CHANGE or an unadjusted corporate action, not a market.
 *
 * Measured 2026-08-12 over all 40 securities with a 1y return >= +300%, by re-fetching each series
 * from the provider and taking its largest one-day ratio. The two populations separate cleanly with
 * nothing in between:
 *
 *   discontinuous (6)   AMRM.TA 96.6x   ISHO.TA 101.0x   ARZTF 30.3x
 *                       PBMRF 28.7x     YZOFF 25.5x      KLTHF 6.0x
 *   real (34)           ASAAF 2.04x  KXHCF 1.45x  009150.KS 1.30x  SNDK 1.28x  MU 1.19x
 *
 * So the largest legitimate move observed is 2.04x and the smallest illegitimate one 6.0x.
 *
 * AMRM.TA and ISHO.TA jump ~100x on THE SAME DAY (2026-05-18) and are both quoted in `ILA` — that
 * is Yahoo switching Tel Aviv quotes from shekels to agorot, which no amount of care at our end
 * would have made into a real +9,000% return. The USD names are OTC lines where a ratio change went
 * unadjusted. A reverse split would look identical, and is equally not comparable across the break.
 *
 * Deliberately NOT a cap on the reported return: SNDK really is up 2,692% and MU 580%, and
 * clipping those would be inventing a different wrong number. What is untrustworthy is a return
 * MEASURED ACROSS the break, so that is exactly what gets dropped.
 */
const DISCONTINUITY_RATIO = 5

/** Index of the bar immediately AFTER the most recent discontinuity, or 0 when there is none. */
export function firstComparableIndex(series: Bar[]): number {
  for (let i = series.length - 1; i >= 1; i--) {
    const prev = series[i - 1].close
    const cur = series[i].close
    if (prev > 0 && cur > 0 && (cur / prev > DISCONTINUITY_RATIO || prev / cur > DISCONTINUITY_RATIO)) {
      return i
    }
  }
  return 0
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
/**
 * Daily-reinvested TOTAL return alongside the price return, per period.
 *
 * Everything this pipeline reports has been a PRICE return, which understates any market that pays
 * income — and for a 10-year horizon on a high-yield market that is not a rounding error, it is the
 * majority of the return. The dividends have been arriving on the price response all along
 * (openbb's yfinance provider defaults `include_actions` to true); #149 started keeping them, and
 * this is what they were for.
 *
 * REINVESTED, not summed. The simple form `(P_end - P_start + ΣD) / P_start` treats a dividend paid
 * nine years ago as if it sat in cash; the reinvested form compounds it, which is what a total
 * return index means and what anyone comparing against one will expect:
 *
 *     cum[i] = cum[i-1] × (P_i + D_i) / P_{i-1}          TR(j → end) = cum[end] / cum[j] − 1
 *
 * One pass to build the cumulative product, then O(1) per period — the same cost as the price
 * return it sits beside.
 *
 * RETURNED SEPARATELY, NEVER INSTEAD. A chart draws prices and a return figure wants total; and if
 * a security has no dividends in the window the two are identical, so overwriting `change_pct`
 * would look correct in exactly the cases where it changes nothing and be wrong everywhere else.
 */
export function totalReturnsFor(series: Bar[], now: Date): Record<string, number> {
  const out: Record<string, number> = {}
  if (series.length < 2) return out

  // The SAME eligibility rules as the price return — staleness, a positive latest close, and the
  // comparability cut after a redenomination. A total return computed across a break is wrong for
  // exactly the same reason a price return is, and duplicating the checks loosely is how the two
  // would drift apart.
  const latestDate = series[series.length - 1].date
  if (latestDate < daysBefore(now, 10)) return out
  const latest = series[series.length - 1].close
  if (!Number.isFinite(latest) || latest <= 0) return out
  const comparableFrom = firstComparableIndex(series)

  // cum[i] is the value at bar i of one unit invested at bar 0 with dividends reinvested.
  const cum = new Array<number>(series.length)
  cum[0] = 1
  for (let i = 1; i < series.length; i++) {
    const prev = series[i - 1].close
    // A non-positive previous close cannot denominate a return. Carry the factor forward unchanged
    // rather than poisoning every later period with NaN or Infinity.
    if (!Number.isFinite(prev) || prev <= 0) { cum[i] = cum[i - 1]; continue }
    const d = series[i].dividend ?? 0
    cum[i] = cum[i - 1] * ((series[i].close + d) / prev)
  }

  const trAt = (idx: number | null) => {
    if (idx === null || idx < comparableFrom) return null
    const base = cum[idx]
    if (!Number.isFinite(base) || base <= 0) return null
    const v = cum[series.length - 1] / base - 1
    if (!Number.isFinite(v)) return null
    return Math.round(v * 1_000_000) / 10_000
  }

  const prev = trAt(series.length - 2)
  if (prev !== null) out['1d'] = prev
  for (const [period, days] of Object.entries(PERIOD_DAYS)) {
    const v = trAt(indexAtOrBefore(series, daysBefore(now, days)))
    if (v !== null) out[period] = v
  }
  const ytd = trAt(indexAtOrBefore(series, `${now.getUTCFullYear() - 1}-12-31`))
  if (ytd !== null) out['ytd'] = ytd
  return out
}

export function returnsFor(series: Bar[], now: Date): Record<string, number> {
  const out: Record<string, number> = {}
  if (series.length < 2) return out

  // A STALE SERIES CANNOT PRODUCE A CURRENT RETURN. When an instrument stops trading the provider
  // keeps serving its final bars, so every period is measured between two identical closes and
  // comes back as exactly +0.0% — which reads as "the market was flat", not "this fund is dead".
  //
  // Measured 2026-08-13: Egypt, Nigeria and Portugal each showed +0.0% on ALL periods, dated today,
  // computed from EGPT / NGE / PGAL — ETFs whose last SEC filing was 2022, 2023 and 2024 and which
  // have no bars in the last month. Colombia (GXG) still trades and its +42.5% is real, which is
  // why this keys on the DATA being stale rather than on a list of dead tickers.
  //
  // Ten days, not two: a long weekend plus a public holiday either side is a legitimate gap, and
  // several of these markets close for multi-day festivals. Anything still trading has a bar inside
  // ten calendar days.
  const latestDate = series[series.length - 1].date
  const freshEnough = daysBefore(now, 10)
  if (latestDate < freshEnough) return out

  const latest = series[series.length - 1].close
  // DEFENCE IN DEPTH, and it earned that immediately: `barFrom` already drops non-positive closes
  // at the parse, but this function is exported and computes the number, so the rule has to hold
  // here too. Without it a zero latest close still yields -100% on EVERY period — which is the
  // exact 1,078-row defect, reachable through any caller that builds a series another way.
  // The same mistake in miniature as `check.ts` asserting `close > 0` somewhere the data never
  // passed through.
  if (!Number.isFinite(latest) || latest <= 0) return out

  // Anything at or after this index is denominated the same way the latest bar is. A period whose
  // anchor sits BEFORE it would be measured across a unit change or an unadjusted corporate action,
  // so it is omitted rather than reported. Per-period, not per-symbol: after a break, the short
  // windows are still perfectly good and only the long ones have to go.
  const comparableFrom = firstComparableIndex(series)

  const pctAt = (idx: number | null) => {
    if (idx === null || idx < comparableFrom) return null
    const from = series[idx].close
    if (from === 0) return null
    // A WINDOW THAT NEVER MOVED IS NOT A 0.00% RETURN — it is a series that is not being priced.
    //
    // Measured 2026-08-13, which is how this was found: `GOTO.JK` had 62 bars across the 3-month
    // window and ONE distinct close (50, every single trading day); `AOT-R.BK` had 65 bars and two.
    // Both are ordinary listings on live exchanges. A stock does not close at exactly the same
    // price for sixty-two consecutive sessions, so the provider is padding, not quoting.
    //
    // The existing guards cannot see this: the closes are positive (so `barFrom` accepts them), the
    // latest bar is today (so the staleness rule passes), and there is no discontinuity (so
    // `firstComparableIndex` has nothing to cut). It renders as "this market was flat", which is a
    // claim about the market rather than an admission that we have no prices for it.
    //
    // Per WINDOW, not per series: a security can legitimately be flat over a week and informative
    // over a year, and the long windows of these same symbols do contain real movement.
    let moved = false
    for (let i = idx + 1; i < series.length; i++) {
      if (series[i].close !== from) { moved = true; break }
    }
    if (!moved) return null
    return Math.round((latest / from - 1) * 1_000_000) / 10_000
  }

  // 1d is the PREVIOUS BAR, not a date lookback — a weekend or holiday would
  // otherwise resolve "yesterday" to the same bar and report a flat 0.00%.
  const prev = pctAt(series.length - 2)
  if (prev !== null) out['1d'] = prev

  for (const [period, days] of Object.entries(PERIOD_DAYS)) {
    const v = pctAt(indexAtOrBefore(series, daysBefore(now, days)))
    if (v !== null) out[period] = v
  }

  // YTD anchors on the last close of LAST year, so early January is measured from
  // the true year-end rather than from the first bar of the new year (which would
  // report ~0% for the first days of trading).
  const ytd = pctAt(indexAtOrBefore(series, `${now.getUTCFullYear() - 1}-12-31`))
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
  // BATCHED, and that is load-bearing rather than tidiness. yfinance accepts a comma list, but ONE
  // bad symbol takes the whole call down with it: `group-performance` 502'd every time (a dead
  // worker, no error body) purely because its five symbols include FM, a fund that was liquidated
  // in 2025 — while `country-performance` sailed through with 45 live ones. Batching bounds the
  // blast radius to a batch, and the per-batch catch means a delisted fund costs its own row and
  // nothing else.
  const symbols = [...new Set(entries.map((e) => e.symbol))]
  const start = daysBefore(now, 1900)
  const BATCH = 12

  const bySymbol = new Map<string, Bar[]>()
  const failedBatches: string[] = []
  for (let i = 0; i < symbols.length; i += BATCH) {
    const chunk = symbols.slice(i, i + BATCH)
    let results: Record<string, unknown>[] = []
    try {
      results = await fetcher(
        `/api/v1/etf/historical?symbol=${symbolList(chunk)}` +
          `&provider=yfinance&start_date=${start}&interval=1d`,
      )
    } catch (e) {
      failedBatches.push(`${chunk.join('/')}: ${e instanceof Error ? e.message : String(e)}`)
      continue
    }
    // A single-symbol response carries NO `symbol` column — the provider only adds it when several
    // are requested. Fall back to the one symbol asked for.
    for (const r of results) {
      const parsed = barFrom(r, chunk[0])
      if (!parsed) continue
      const list = bySymbol.get(parsed.symbol) ?? []
      list.push(parsed.bar)
      bySymbol.set(parsed.symbol, list)
    }
  }
  if (failedBatches.length > 0) {
    console.error(`${scope}: ${failedBatches.length} batch(es) failed: ${failedBatches.join(' | ')}`)
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
    // Both, from the same series and the same eligibility rules. `?? null` rather than a fallback
    // to the price return: a period the total-return pass declines to produce is UNKNOWN, not
    // income-free.
    const tr = totalReturnsFor(series, now)
    for (const [period, changePct] of Object.entries(returnsFor(series, now))) {
      rows.push({
        scope,
        scope_id: scopeId,
        period,
        change_pct: changePct,
        total_return_pct: tr[period] ?? null,
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
 * TTL for the BACKLOG resources (`security-profiles`, `security-performance`).
 *
 * Short on purpose, and it costs nothing: an incremental resource with an empty backlog returns
 * without calling any provider, so the TTL only has to be long enough to avoid a pointless table
 * read. It has to be SHORT while a backlog exists, though — these have ~9,000 securities to work
 * through at ~1,000 a run, and a day-long TTL would stretch that over a week and a half.
 *
 * This is the same trap `security-tickers` fell into: it once carried the 7-day reference TTL, one
 * run resolved a page, and every run for the next week was told the data was fresh.
 */
export const BACKLOG_TTL_MINUTES = 10

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
  timeoutMs?: number,
): Promise<PerfRow[]> {
  if (symbols.length === 0) return []
  const start = daysBefore(now, 400)
  const results = await fetcher(
    `/api/v1/equity/price/historical?symbol=${symbolList(symbols)}` +
      `&provider=yfinance&start_date=${start}&interval=1d`,
    timeoutMs,
  )

  // A single-symbol response carries NO `symbol` column — the provider only adds it when several
  // are requested.
  const bySymbol = new Map<string, Bar[]>()
  for (const r of results) {
    const parsed = barFrom(r, symbols[0])
    if (!parsed) continue
    const key = parsed.symbol.toUpperCase()
    const list = bySymbol.get(key) ?? []
    list.push(parsed.bar)
    bySymbol.set(key, list)
  }
  for (const list of bySymbol.values()) list.sort((a, b) => a.date.localeCompare(b.date))

  const asOf = now.toISOString()
  const staleAfter = new Date(now.getTime() + ttlMinutes * 60_000).toISOString()
  const rows: PerfRow[] = []
  for (const symbol of symbols) {
    const series = bySymbol.get(symbol.toUpperCase())
    // A delisted or renamed ticker returns nothing. Skipped rather than written as zero.
    if (!series || series.length < 2) continue
    const trA = totalReturnsFor(series, now)
    for (const [period, changePct] of Object.entries(returnsFor(series, now))) {
      rows.push({
        scope: 'instrument',
        scope_id: symbol,
        period,
        change_pct: changePct,
        total_return_pct: trA[period] ?? null,
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
        `/api/v1/equity/price/historical?symbol=${symbolList(symbols)}` +
          `&provider=yfinance&start_date=${daysBefore(now, 1900)}&interval=1d`,
      )

      const bySymbol = new Map<string, Bar[]>()
      for (const r of results) {
        const parsed = barFrom(r, symbols[0])
        if (!parsed) continue
        const list = bySymbol.get(parsed.symbol) ?? []
        list.push(parsed.bar)
        bySymbol.set(parsed.symbol, list)
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
        const trB = totalReturnsFor(series, now)
        for (const [period, changePct] of Object.entries(returnsFor(series, now))) {
          rows.push({
            scope: 'instrument',
            scope_id: scopeId,
            period,
            change_pct: changePct,
            total_return_pct: trB[period] ?? null,
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
    `/api/v1/${route}?symbol=${symbolList(symbols)}` +
      `&provider=yfinance&start_date=${daysBefore(now, days)}&interval=1d`,
  )
  // A single-symbol response carries NO `symbol` column — the provider only adds it
  // when several are requested.
  const bySymbol = new Map<string, Bar[]>()
  for (const r of results) {
    const parsed = barFrom(r, symbols[0])
    if (!parsed) continue
    const list = bySymbol.get(parsed.symbol) ?? []
    list.push(parsed.bar)
    bySymbol.set(parsed.symbol, list)
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

/**
 * How far back the WEEKLY series goes. One constant, because it is a disk budget rather than a
 * preference: 1,077 bars per security at ~186 bytes (measured, 568 MB over 3,056,435 rows) is
 * ~2.3 GB across 11,347 equities, against 14 GB free on the node when this was written. Changing
 * it changes what the deployment costs, so it should be changed here and nowhere else.
 */
export const PRICE_HISTORY_YEARS = 20

/**
 * How long an article is kept. The provider only reaches back about a month, so a weekly refresh
 * adds roughly a quarter of a fresh set each time — unbounded, that compounds for ever for data
 * whose value decays in days. 90 days is deep enough for a stock page and shallow enough that the
 * table settles rather than grows.
 */
export const NEWS_RETENTION_DAYS = 90
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
    `/api/v1/equity/profile?symbol=${symbolList([...new Set(entries.map((e) => e.symbol))])}` +
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

/**
 * Group a price backlog into batches that can share ONE `start_date`.
 *
 * The provider takes a single `start_date` per request, so a batch is only as cheap as its
 * furthest-behind member: mixing a security we have never priced (needs 400 days) with one that is
 * a day stale (needs 1) makes the whole batch fetch 400. Grouping by how far back each needs keeps
 * the daily case a daily fetch, which is the entire point of storing the series.
 *
 * Two buckets, not per-symbol precision: `full` for anything with no history or a gap wider than
 * the window, `incremental` for the rest, whose start is the OLDEST last-date in the batch. A
 * security a few days fresher than its batch-mate over-fetches by those few days and the upsert
 * discards the overlap — cheaper than one request per symbol against a rate-limited provider.
 */
export function planPriceFetches(
  rows: { symbol: string; fetchSymbol: string; lastDate: string | null }[],
  now: Date,
  batchSize: number,
  windowDays = PRICE_WINDOW_DAYS,
): { symbols: { symbol: string; fetchSymbol: string }[]; startDate: string }[] {
  const windowStart = daysBefore(now, windowDays)
  const full: typeof rows = []
  const incremental: typeof rows = []
  for (const r of rows) {
    // A gap wider than the window cannot be closed by appending — refetch the whole thing.
    if (!r.lastDate || r.lastDate < windowStart) full.push(r)
    else incremental.push(r)
  }
  const out: { symbols: { symbol: string; fetchSymbol: string }[]; startDate: string }[] = []

  for (let i = 0; i < full.length; i += batchSize) {
    out.push({
      symbols: full.slice(i, i + batchSize).map((r) => ({ symbol: r.symbol, fetchSymbol: r.fetchSymbol })),
      startDate: windowStart,
    })
  }
  // Oldest first, so a batch's shared start date is as recent as its members allow.
  incremental.sort((a, b) => (a.lastDate ?? '').localeCompare(b.lastDate ?? ''))
  for (let i = 0; i < incremental.length; i += batchSize) {
    const chunk = incremental.slice(i, i + batchSize)
    out.push({
      symbols: chunk.map((r) => ({ symbol: r.symbol, fetchSymbol: r.fetchSymbol })),
      // The oldest member's last date. Not +1 day: the provider's range is inclusive and re-reading
      // one known bar is how a revised close (a late correction) actually reaches us.
      startDate: chunk[0].lastDate as string,
    })
  }
  return out
}

// ── macro series: one shape per provider, and none of them agree ─────────────
//
// FIVE response shapes reach this function, which is why the extraction is a named, tested helper
// rather than an inline `r.value` at the call site. Measured against the deployed openbb-api:
//
//   oecd cpi / gdp / unemployment   { date, country, value, expenditure }
//   federal_reserve yield_curve     { date, maturity, rate, maturity_years }   <- TERM STRUCTURE
//   federal_reserve effr / sofr     { date, rate }
//   yfinance futures / crypto / index { date, open, high, low, close, volume }
//   fred fred_series                { date, "<SYMBOL>": value }                <- key IS the symbol
//
// The FRED one is the trap: the value is under a key named after the series, so there is no fixed
// field to read and `r.value` returns undefined for every row — which would look exactly like a
// series the provider has nothing for.
export interface MacroPoint {
  as_of: string
  /** The term-structure axis (a yield curve's maturity); '' for a scalar series. */
  dimension: string
  value: number
}

export function extractMacroPoints(rows: Record<string, unknown>[], code: string): MacroPoint[] {
  const out: MacroPoint[] = []
  for (const r of rows ?? []) {
    const date = typeof r.date === 'string' ? r.date.slice(0, 10) : null
    if (!date) continue

    // A yield curve is (date, maturity) -> rate. Emitted as several points sharing a date.
    if (r.maturity !== undefined && r.rate !== undefined) {
      const v = Number(r.rate)
      if (Number.isFinite(v)) out.push({ as_of: date, dimension: String(r.maturity), value: v })
      continue
    }

    // Scalar shapes, in precedence order. `close` last so an OHLC row is read as its close rather
    // than its open.
    let v: unknown =
      r.value !== undefined ? r.value
      : r.rate !== undefined ? r.rate
      : r.close !== undefined ? r.close
      : undefined

    // FRED: the value hides under a key named after the series. Only reached when no known field
    // matched, so it cannot shadow a real `value` column.
    if (v === undefined) {
      for (const [k, val] of Object.entries(r)) {
        if (k === 'date' || typeof val !== 'number') continue
        v = val
        break
      }
    }

    const n = Number(v)
    if (v !== undefined && Number.isFinite(n)) out.push({ as_of: date, dimension: '', value: n })
  }

  // ONE POINT PER (date, dimension). OECD returns several `expenditure` breakdowns for the same
  // date and we keep the first; without this the upsert carries a key twice and Postgres fails the
  // WHOLE statement with 21000 — the documented `dedupeBy` trap, which costs the entire resource
  // rather than one row.
  const seen = new Set<string>()
  return out.filter((p) => {
    const k = `${p.as_of}|${p.dimension}`
    if (seen.has(k)) return false
    seen.add(k)
    return true
  })
}

/**
 * A stable key for a record whose source gives it none.
 *
 * SEC's Form 4 response carries no filing id, so the transaction's own facts ARE its identity —
 * owner, date, direction, share count, price. Hashing them makes a re-fetch idempotent instead of
 * inserting the same trade again every week, which matters because the insider resource re-reads
 * each filer on a cursor by design.
 *
 * Not a security boundary: this is a dedupe key, and SHA-256 is simply what the runtime offers.
 */
export async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}
