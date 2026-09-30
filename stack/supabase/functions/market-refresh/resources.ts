// Pure fetch+map logic for market-refresh, with NO Supabase dependency.
//
// Split out from index.ts on purpose: this is the part that breaks silently when a
// provider renames a field, changes a sector label, or switches fraction<->percent.
// Keeping it free of supabase-js means `check.ts` can drive it against a real
// openbb-api with nothing else running. index.ts owns HTTP, the refresh claim and
// the upsert; this file owns "what the numbers are".

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
    m.includes('429') ||
    // WORDINGS PROVIDERS ACTUALLY USE, not the ones we expected them to. Tiingo says
    // "Error: You have run over your hourly request limit" — which matches NONE of the four above,
    // so six consecutive `security-corporate-actions` runs were rate-limited without
    // `throttledOut` ever being set, leaving the throttle-pressure panel and its alert blind to
    // that provider. The list above was a guess at vocabulary rather than a classifier; every
    // entry below is quoted from a body seen in production.
    m.includes('run over your') ||
    m.includes('request limit') ||
    m.includes('quota')
}

/**
 * Does this provider error say THIS SYMBOL has no data, rather than that the provider is unwell?
 *
 * The counterpart to `throttled`, and the distinction this file keeps making: a request that
 * FAILED and a request that ANSWERED NOTHING are different facts. A symbol the provider genuinely
 * cannot serve must earn a negative cache, or a weight-ordered backlog re-asks the same head for
 * ever; a provider that is refusing us must mark nothing.
 *
 * Both wordings below are quoted from responses measured on this deployment 2026-09-06, and they
 * mean the same thing through two different code paths in openbb's yfinance adapter:
 *
 *   TSLA          -> "No dividend data found for TSLA"                    (a US non-payer)
 *   ICT.PS        -> "'NoneType' object has no attribute 'empty'"         (venue not covered)
 *   FAB.AE        -> "'NoneType' object has no attribute 'empty'"
 *   WARBABAN.KW   -> "'NoneType' object has no attribute 'empty'"
 *
 * The second is the adapter dereferencing a frame it never received. It reads like a bug in our
 * code and is a statement about the symbol — and because only the FIRST was classified, 60
 * securities of the Philippines, the UAE, Kuwait and Chile sat at the head of `pending_dividends`
 * failing eight times a day since 2026-09-05 with `written: 0`, against a backlog of 9,221.
 *
 * A THROTTLE IS NOT IN THIS LIST AND MUST NEVER BE. yfinance raises `YFRateLimitError` under rate
 * limiting, which `throttled` already catches and which breaks the loop before this is consulted —
 * that separation is what makes it safe to mark on per-symbol evidence here without stacking a
 * run-level tally on top of it (a tally that, once the answerable head has drained, can never
 * become true and guarantees the stall it was meant to prevent).
 */
export function noDataForSymbol(message: string): boolean {
  const m = message.toLowerCase()
  return m.includes('no dividend data found') ||
    m.includes("'nonetype' object has no attribute") ||
    // SEC, VIA openbb, SAYS THE SAME THING IN TWO MORE WORDINGS — measured 2026-09-06 against the
    // deployed openbb-api, with AAPL answering in the same seconds:
    //
    //   AIBRF  -> Unexpected Error -> ContentTypeError -> 404, message='Attempt to decode JSON …'
    //   BWAGF  -> the same
    //   BRK/B  -> Could not find CIK for symbol: BRK/B
    //
    // openbb's SEC provider resolves symbol -> CIK through SEC's own ticker map, so a US OTC
    // foreign-ordinary line that is not in that map cannot be served however valid the company is.
    // Both name the symbol and both are settled facts about it, not about the provider.
    m.includes('could not find cik for symbol') ||
    (m.includes('contenttypeerror') && m.includes('404'))
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

/** One instrument to fetch: our key (`scopeId`) and the symbol the provider knows it by. */
export interface UniverseEntry {
  scopeId: string
  symbol: string
}

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
 * TTL for the two SEC backlogs, which run on their OWN five-minute pg_cron schedules rather than
 * in the provider-paced rotation (migration 142).
 *
 * MEASURED IN PRODUCTION ON THE FIRST DAY, and it was the schedule fighting the TTL. With
 * `BACKLOG_TTL_MINUTES` at 10 and the job firing every 5, every OTHER run returned
 * `{"skipped": true, "reason": "fresh or in flight"}` — so `security-segments` drained at half the
 * rate the schedule implies, and its 30,060-filing backlog would take ~10 days instead of ~5. It
 * reports `ok: true` throughout, which is why nothing but reading the run records finds it.
 *
 * FOUR, not five: a TTL exactly equal to the interval is a coin flip on clock jitter, and losing a
 * run to rounding is the same defect in a quieter form. There is no cost to the shorter value —
 * a backlog resource with nothing to do returns without calling any provider, and at 20 filings a
 * run this is ~0.13 requests/second against SEC's documented 10.
 */
export const SEC_BACKLOG_TTL_MINUTES = 4

/**
 * How long an article is kept. The provider only reaches back about a month, so a weekly refresh
 * adds roughly a quarter of a fresh set each time — unbounded, that compounds for ever for data
 * whose value decays in days. 90 days is deep enough for a stock page and shallow enough that the
 * table settles rather than grows.
 */
export const NEWS_RETENTION_DAYS = 90
/**
 * A day, for a resource that re-reads its whole window each run rather than draining a backlog
 * (the earnings calendar). A TTL is about how often it is worth ASKING, not about how often the
 * data changes.
 */
export const DAILY_TTL_MINUTES = 24 * 60

/**
 * One instrument's profile, from `equity/profile`: `instrument-profile` writes it to
 * `market.instruments` (industry = the real sub-sector, country, market cap).
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
