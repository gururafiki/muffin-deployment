/**
 * SEC XBRL company facts — seventeen years of statements, quarterly, in one request per filer.
 *
 * WHY THIS BYPASSES openbb. `security-statements` costs three openbb calls per security and
 * returns 18 ANNUAL periods: measured on the deployed api, income 1.94s + balance 1.88s + cash
 * 1.77s = 5.58s, i.e. 16 securities per 90-second worker and no quarterly figure at all
 * (`period=quarter` answers 422). Concurrency does not help — three parallel calls for one
 * security also took 5.53s, because openbb-api serialises them. SEC's own endpoint answers in
 * 0.17s with every concept the filer has ever tagged.
 *
 * SEC REQUIRES A DECLARED USER-AGENT with contact details. Without one it returns 403, which
 * reads exactly like an IP block and is not — the same misreading that cost an afternoon on
 * econdb.
 */

/** SEC's stated requirement: a real contact. Not a browser string. */
const SEC_UA = 'muffin-market-data admin@rafiki.guru'

export interface XbrlFact {
  metricCode: string
  periodType: 'annual' | 'quarter'
  periodEnding: string
  value: number
  currency: string | null
}

export interface ConceptSpec {
  metricCode: string
  concept: string
  priority: number
  /**
   * A KIND, not a literal. `USD` means "whichever currency this filer reports in", `USD/shares`
   * per-share in that currency, `shares` a count. A US filer's facts sit under a `USD` unit key;
   * Novo Nordisk's under `DKK` and Nokia's under `EUR`.
   */
  unit: string
  /** `us-gaap` for domestic filers, `ifrs-full` for foreign private issuers filing 20-F. */
  taxonomy: string
}

/**
 * Which unit key inside a concept holds the filer's own figures.
 *
 * A filer may publish several: TSMC reports in TWD **and** USD, the second being a convenience
 * translation. The primary reporting currency carries the full history, so the key with the most
 * data points wins — choosing USD instead would relabel Novo Nordisk's kroner as dollars.
 */
export function pickUnitKey(units: Record<string, unknown>, kind: string): string | null {
  if (kind === 'shares') return 'shares' in units ? 'shares' : null
  const perShare = kind.includes('/shares')
  const re = perShare ? /^[A-Z]{3}\/shares$/ : /^[A-Z]{3}$/
  let best: string | null = null
  let bestLen = -1
  for (const [key, val] of Object.entries(units)) {
    if (!re.test(key)) continue
    const len = Array.isArray(val) ? val.length : 0
    // Ties break on the key so the answer does not depend on object order.
    if (len > bestLen || (len === bestLen && best !== null && key < best)) {
      best = key
      bestLen = len
    }
  }
  return best
}

async function secJson(url: string, timeoutMs: number): Promise<unknown> {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': SEC_UA, 'Accept-Encoding': 'gzip' },
      signal: ctl.signal,
    })
    if (res.status === 404) return null
    if (!res.ok) throw new Error(`sec ${res.status} for ${url.slice(0, 80)}`)
    return await res.json()
  } finally {
    clearTimeout(timer)
  }
}

/** ticker -> CIK, from the file SEC publishes for exactly this purpose (776 KB, ~10,400 filers). */
export async function fetchCikMap(timeoutMs = 30_000): Promise<Map<string, number>> {
  const d = await secJson('https://www.sec.gov/files/company_tickers.json', timeoutMs)
  const out = new Map<string, number>()
  if (!d || typeof d !== 'object') return out
  for (const v of Object.values(d as Record<string, unknown>)) {
    const row = v as { cik_str?: unknown; ticker?: unknown }
    const cik = typeof row.cik_str === 'number' ? row.cik_str : Number(row.cik_str)
    const ticker = String(row.ticker ?? '').toUpperCase()
    if (ticker && Number.isFinite(cik)) out.set(ticker, cik)
  }
  return out
}

/**
 * A period's value for one metric, resolved across concepts.
 *
 * PER PERIOD, NOT PER COMPANY. Caterpillar reports `NetIncomeLoss` for fy 2009..2011 and something
 * else afterwards, so picking the first concept that has ANY data yields a series covering three
 * years of seventeen — and it looks like the company simply stopped reporting.
 *
 * Within a period, the fact from the LATEST FILING wins: a period is restated by amendments and
 * by later filings that repeat it, and the newest one is the company's current answer.
 */
export function factsFromCompanyFacts(
  payload: unknown,
  concepts: ConceptSpec[],
): XbrlFact[] {
  const facts = (payload as { facts?: Record<string, unknown> })?.facts
  if (!facts || typeof facts !== 'object') return []

  // (metric, periodType, end) -> the best candidate seen so far.
  const best = new Map<string, { priority: number; filed: string; value: number; currency: string | null }>()

  for (const spec of concepts) {
    // BOTH TAXONOMIES. Reading only `us-gaap` marked ten foreign private issuers as having no
    // facts — AB InBev's companyfacts has no us-gaap node at all, only `ifrs-full`.
    const tax = (facts as Record<string, unknown>)[spec.taxonomy]
    if (!tax || typeof tax !== 'object') continue
    const node = (tax as Record<string, unknown>)[spec.concept] as
      | { units?: Record<string, unknown[]> }
      | undefined
    if (!node?.units) continue
    const unitKey = pickUnitKey(node.units as Record<string, unknown>, spec.unit)
    if (!unitKey) continue
    const points = node.units[unitKey]
    if (!Array.isArray(points)) continue
    // The unit key IS the reporting currency, arriving free and per filer.
    const currency = spec.unit === 'shares' ? null : unitKey.slice(0, 3)

    for (const p of points) {
      const f = p as {
        end?: unknown; val?: unknown; fp?: unknown; form?: unknown; filed?: unknown; start?: unknown
      }
      const end = String(f.end ?? '').slice(0, 10)
      const val = typeof f.val === 'number' ? f.val : Number(f.val)
      if (!end || !Number.isFinite(val)) continue

      const fp = String(f.fp ?? '')
      // `fp` is the filer's own label and is the only thing that distinguishes an annual figure
      // from a quarterly one for an INSTANT concept (a balance sheet has no start date to measure).
      const periodType: 'annual' | 'quarter' =
        fp === 'FY' ? 'annual' : fp.startsWith('Q') ? 'quarter' : 'annual'
      // A DURATION FACT MUST MATCH ITS LABEL, AND `fp` DOES NOT MEAN WHAT IT LOOKS LIKE.
      //
      // XBRL duration facts for Q2 and Q3 are frequently YEAR-TO-DATE — six and nine months — and
      // they still carry `fp: "Q2"` / `"Q3"`. The first version of this filter rejected anything
      // over 200 days, which drops the 9-month YTD and ADMITS THE 6-MONTH ONE. Measured in
      // production: AAPL's `2026-03-28` "quarterly" revenue came out at 254,940M against a
      // full-year 416,161M — **61% of a year in a single quarter** — and the same for 2025-03-29
      // at 53%. The quarterly chart spiked every Q2 and nothing in any row count showed it.
      //
      // So a quarter is bounded on BOTH sides: a discrete three-month period is ~90 days, and
      // anything outside 80..100 is a different period wearing a quarterly label. A YTD fact is
      // simply skipped — the discrete quarter is derivable as `YTD(n) - YTD(n-1)` within a fiscal
      // year, but that is a separate change with its own failure modes, and a missing quarter is
      // honest where a six-month figure labelled as a quarter is not.
      // An INSTANT fact (a balance sheet) has no `start` and is classified by `fp` alone. That is
      // deliberate and must stay: rejecting it for lack of a duration drops every balance-sheet
      // metric, which a mutation already proved.
      if (typeof f.start === 'string') {
        const days = (Date.parse(end) - Date.parse(f.start)) / 86_400_000
        if (!Number.isFinite(days)) continue
        if (periodType === 'annual' && (days < 300 || days > 400)) continue
        if (periodType === 'quarter' && (days < 80 || days > 100)) continue
      }

      const key = `${spec.metricCode}|${periodType}|${end}`
      const filed = String(f.filed ?? '')
      const prev = best.get(key)
      // Higher-priority concept wins outright; within one concept, the later filing wins.
      if (
        !prev ||
        spec.priority > prev.priority ||
        (spec.priority === prev.priority && filed > prev.filed)
      ) {
        best.set(key, {
          priority: spec.priority,
          filed,
          value: val,
          currency,
        })
      }
    }
  }

  const out: XbrlFact[] = []
  for (const [key, v] of best) {
    const [metricCode, periodType, periodEnding] = key.split('|')
    out.push({
      metricCode,
      periodType: periodType as 'annual' | 'quarter',
      periodEnding,
      value: v.value,
      currency: v.currency,
    })
  }
  return out
}

export async function fetchCompanyFacts(cik: number, timeoutMs = 30_000): Promise<unknown> {
  const padded = String(cik).padStart(10, '0')
  return await secJson(`https://data.sec.gov/api/xbrl/companyfacts/CIK${padded}.json`, timeoutMs)
}
