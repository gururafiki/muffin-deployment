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
  unit: string
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
  const gaap = (payload as { facts?: Record<string, unknown> })?.facts?.['us-gaap']
  if (!gaap || typeof gaap !== 'object') return []

  // (metric, periodType, end) -> the best candidate seen so far.
  const best = new Map<string, { priority: number; filed: string; value: number; currency: string | null }>()

  for (const spec of concepts) {
    const node = (gaap as Record<string, unknown>)[spec.concept] as
      | { units?: Record<string, unknown[]> }
      | undefined
    const points = node?.units?.[spec.unit]
    if (!Array.isArray(points)) continue

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
      // A DURATION FACT MUST MATCH ITS LABEL. An income statement fact carries `start`, and a
      // 10-K's Q1 comparative can be tagged FY; trusting the label alone puts a three-month
      // revenue into the annual series, where it reads as a 75% collapse.
      if (typeof f.start === 'string') {
        const days = (Date.parse(end) - Date.parse(f.start)) / 86_400_000
        if (!Number.isFinite(days)) continue
        if (periodType === 'annual' && days < 300) continue
        if (periodType === 'quarter' && days > 200) continue
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
          currency: spec.unit === 'shares' ? null : 'USD',
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
