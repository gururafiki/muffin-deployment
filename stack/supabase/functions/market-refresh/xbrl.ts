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
import { secWww, secData } from './origins.ts'

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
  const d = await secJson(`${secWww()}/files/company_tickers.json`, timeoutMs)
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
  return await secJson(`${secData()}/api/xbrl/companyfacts/CIK${padded}.json`, timeoutMs)
}

// ── The submissions API: a filer's COMPLETE filing history, and its SIC, in one request ────────

export interface FilingRow {
  accession: string
  form: string
  filingDate: string
  reportDate: string | null
  isXbrl: boolean
}

/** A dated former name. SEC gives ISO timestamps; only the date part is kept. */
export interface FormerName {
  name: string
  from: string | null
  to: string | null
}

/**
 * The registrant's own identity, as SEC holds it.
 *
 * ALL OF THIS ARRIVES IN THE SAME RESPONSE as the filing history — it is the seventh instance of
 * "the answer is already in a response you fetch", and none of it costs a request.
 *
 * `usTicker` / `usExchange` are the ones that matter most. This pipeline resolves a US ticker
 * through OpenFIGI, whose US lookup returns the thin OTC foreign-ordinary line for most foreign
 * companies — `ASMLF`, `TSMWF`, `BUDFF` — and that has cost real budget: 621 of 1,015 rows in the
 * EPS backlog, against a provider allowing 25 calls a DAY. SEC states the registrant's actual
 * listing, and it is authoritative rather than inferred.
 */
export interface FilerProfile {
  entityType: string | null
  ownerOrg: string | null
  ein: string | null
  lei: string | null
  category: string | null
  /** `0926` — the month and day the fiscal year ends. Explains 52/53-week calendars. */
  fiscalYearEnd: string | null
  stateOfIncorporation: string | null
  website: string | null
  investorWebsite: string | null
  phone: string | null
  usTicker: string | null
  usExchange: string | null
  hqStreet: string | null
  hqCity: string | null
  /**
   * SEC's field is `stateOrCountry` and it is exactly that — "CA" for Apple is California, and for
   * a foreign private issuer it is a country or nothing at all (TSMC's is null). Named for what it
   * holds rather than `hq_country`, which would read as a country for every US filer and be a
   * state. `security.country_iso2` and `provider_country_iso2` remain what anything joins on.
   */
  hqStateOrCountry: string | null
  hqZip: string | null
  formerNames: FormerName[]
}

export interface Submissions {
  sic: string | null
  sicDescription: string | null
  name: string | null
  profile: FilerProfile
  filings: FilingRow[]
  /** Names of the older pages, which hold everything before the 1,000 most recent filings. */
  olderPages: string[]
}

/**
 * Parse a submissions payload — either shape.
 *
 * TWO SHAPES, AND THEY DIFFER IN A WAY THAT IS EASY TO MISS. The main document nests its arrays
 * under `filings.recent`; an older page is the SAME column-oriented arrays at the TOP level, with
 * no wrapper (measured on `CIK0000320193-submissions-001.json`, 1,242 filings covering 1994-2015).
 * Reading only the first shape silently returns nothing for every historical page — which looks
 * exactly like a filer with no history.
 *
 * The arrays are PARALLEL, not a list of objects, so a filing is assembled by index. Any array
 * shorter than `accessionNumber` would silently shift every field after it, so the row is skipped
 * unless the index exists in the arrays that matter.
 */
export function submissionsFrom(payload: unknown, forms: string[]): Submissions {
  const d = (payload ?? {}) as Record<string, unknown>
  const wanted = new Set(forms)
  const filingsNode = (d.filings ?? {}) as Record<string, unknown>
  const table = ('accessionNumber' in d ? d : (filingsNode.recent ?? {})) as Record<string, unknown>

  const col = (name: string): unknown[] =>
    Array.isArray(table[name]) ? table[name] as unknown[] : []
  const accs = col('accessionNumber')
  const formCol = col('form')
  const filed = col('filingDate')
  const report = col('reportDate')
  const xbrl = col('isXBRL')

  const filings: FilingRow[] = []
  for (let i = 0; i < accs.length; i++) {
    const form = String(formCol[i] ?? '')
    if (!wanted.has(form)) continue
    const accession = String(accs[i] ?? '')
    const filingDate = String(filed[i] ?? '')
    if (!accession || !filingDate) continue
    const rd = report[i] === null || report[i] === undefined ? '' : String(report[i])
    filings.push({
      accession,
      form,
      filingDate,
      reportDate: rd === '' ? null : rd,
      // SEC sends 1/0 rather than true/false. `Boolean(0)` is false and `Boolean("0")` is TRUE, so
      // the comparison is numeric on purpose — a string "0" read as truthy would mark every
      // pre-2009 filing as carrying XBRL and send the segment resource after all of them.
      isXbrl: Number(xbrl[i] ?? 0) === 1,
    })
  }

  const files = Array.isArray(filingsNode.files) ? filingsNode.files as Record<string, unknown>[] : []

  // EMPTY STRING IS ABSENCE, NOT A VALUE. SEC returns `""` for a field it does not hold — Apple's
  // `lei`, `description` and `website` are all empty — and storing those would make "we have no
  // website" indistinguishable from "the website is the empty string", which is the same mistake
  // as rendering nasdaq's literal `not-supplied` to a user.
  const str = (v: unknown): string | null => {
    if (v === null || v === undefined) return null
    const t = String(v).trim()
    return t === '' ? null : t
  }
  const first = (v: unknown): string | null =>
    Array.isArray(v) && v.length > 0 ? str(v[0]) : null

  // `addresses.business` is the operating address; `mailing` is often a registered agent, which is
  // a lawyer's office rather than where the company is.
  const addr = ((d.addresses ?? {}) as Record<string, unknown>).business as
    Record<string, unknown> | undefined ?? {}

  const formerRaw = Array.isArray(d.formerNames) ? d.formerNames as Record<string, unknown>[] : []
  const formerNames: FormerName[] = formerRaw
    .map((f) => ({
      name: str(f.name) ?? '',
      // SEC sends a full ISO timestamp; only the date is meaningful for a name change.
      from: str(f.from)?.slice(0, 10) ?? null,
      to: str(f.to)?.slice(0, 10) ?? null,
    }))
    .filter((f) => f.name !== '')

  return {
    sic: str(d.sic),
    sicDescription: str(d.sicDescription),
    name: str(d.name),
    profile: {
      entityType: str(d.entityType),
      ownerOrg: str(d.ownerOrg),
      // `000000000` IS SEC'S PLACEHOLDER, NOT AN EIN — measured on TSMC, a foreign private issuer
      // with no US employer number. Exactly the shape of `<cusip>000000000</cusip>`, which once
      // collapsed Accenture, Seagate, TE Connectivity and NXP into a single security because the
      // placeholder was treated as an identifier. Rejected here rather than stored.
      ein: /^0+$/.test(str(d.ein) ?? '') ? null : str(d.ein),
      lei: str(d.lei),
      category: str(d.category),
      fiscalYearEnd: str(d.fiscalYearEnd),
      stateOfIncorporation: str(d.stateOfIncorporation),
      website: str(d.website),
      investorWebsite: str(d.investorWebsite),
      phone: str(d.phone),
      // FIRST of each array, and they are POSITIONALLY PAIRED — SEC lists a filer's tickers and
      // the exchange each trades on in matching order.
      usTicker: first(d.tickers),
      usExchange: first(d.exchanges),
      hqStreet: str(addr.street1),
      hqCity: str(addr.city),
      hqStateOrCountry: str(addr.stateOrCountry),
      hqZip: str(addr.zipCode),
      formerNames,
    },
    filings,
    olderPages: files.map((f) => String(f.name ?? '')).filter(Boolean),
  }
}

/** The filer's submissions document. `null` when SEC has no such CIK. */
export async function fetchSubmissions(cik: number, timeoutMs = 25_000): Promise<unknown> {
  const padded = String(cik).padStart(10, '0')
  return await secJson(`${secData()}/submissions/CIK${padded}.json`, timeoutMs)
}

/** One older page, named by `Submissions.olderPages`. */
export async function fetchSubmissionsPage(name: string, timeoutMs = 25_000): Promise<unknown> {
  return await secJson(`${secData()}/submissions/${name}`, timeoutMs)
}
