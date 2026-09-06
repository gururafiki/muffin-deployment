/**
 * India, via NSE — the client and, more importantly, the NORMALISER.
 *
 * DART needed no parser change: its instances carry standard IFRS axes whose member codes ARE the
 * segment names, so `segmentFactsFrom` handled Korea unmodified. India does not, in three separate
 * ways, and each would produce a confident wrong number rather than an error. All three were
 * measured on Reliance, HDFC Bank and Infosys — three filers, not one, because a rule inferred from
 * a single instance is a coincidence.
 *
 *  1. MEMBERS ARE ANONYMOUS POSITIONAL SLOTS. `OneReportableSegmentRevenue03Member` says nothing
 *     about what segment it is. The name lives in a SIBLING fact,
 *     `in-bse-fin:DescriptionOfReportableSegment`, on the same context — Infosys resolves to
 *     "Financial Services", "Hi Tech", "Energy, Utilities, Resources and Services". Measured
 *     complete: 10/10, 14/14 and 16/16 members named.
 *
 *  2. THE PERIOD IS NOT IN THE CONTEXT'S DATES. Every fact in the file — both columns AND both
 *     undimensioned totals — carries the identical 90-day period. A Q4 filing reports the quarter
 *     and the full year, and the filer tags both against the same dates. `periodTypeFor` therefore
 *     sees `quarter` for both, the parser unions them into one bucket, and Reliance's revenue split
 *     comes to 14,011,150,000,000 against a true 11,094,900,000,000 — a 26% overstatement, with two
 *     competing undimensioned totals for one key. What DOES distinguish them is the `One`/`Four`
 *     prefix on the CONTEXT ID (`OneD`, `FourD`, `OneReportableSegmentRevenue01D`): one quarter
 *     versus four. Measured ratios 3.80 / 3.39 / 4.05, and each column reconciles to its own
 *     undimensioned total to the rupee.
 *
 *  3. EVERY COMPANY FILES TWICE, standalone and consolidated, with the same One/Four structure
 *     inside each. `NatureOfReportStandaloneConsolidated` is the discriminator; taking the wrong
 *     file silently reports the parent company as the group.
 *
 * The normalisation is deliberately OUTSIDE `segmentFactsFrom`. That function is the most heavily
 * guarded code here — partitions, subtotals, residuals, qualifiers, cross-tab marginals — and a
 * filer-specific rule inside it would be a liability for every other jurisdiction. `normalise`
 * rewrites the instance into ordinary XBRL that the existing parser reads unchanged.
 */

/** A filing that is not the consolidated one, so the caller can say so rather than guess. */
import { nse as nseOrigin, nseArchives as nseArchivesOrigin } from './origins.ts'

export const NOT_CONSOLIDATED = Symbol('nse filing is standalone')

export interface NseFiling {
  /** NSE's own XBRL URL on nsearchives.nseindia.com. */
  xbrlUrl: string
  /** The period end NSE reports for the filing, e.g. `31-Mar-2024`. */
  toDate: string
}

/**
 * A stable, readable member code from the filer's own segment name.
 *
 * The positional slot cannot be the key: `…Revenue03Member` is Oil to Chemicals in one filing and
 * could be anything in the next, so keying on it would make a company's history incoherent the
 * first time a filer reorders its segments. The NAME is what is stable, so it becomes the code.
 */
export function memberCodeFor(name: string): string {
  const slug = name
    .replace(/[^A-Za-z0-9]+/g, ' ')
    .trim()
    .split(' ')
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join('')
  return `nse:${slug || 'Unnamed'}Member`
}

/** Twelve months ending at `end`, as an ISO date. Used to give the `Four*` column a real year. */
export function yearStartFor(end: string): string {
  const [y, m, d] = end.split('-').map(Number)
  const start = new Date(Date.UTC(y - 1, m - 1, d))
  start.setUTCDate(start.getUTCDate() + 1)
  return start.toISOString().slice(0, 10)
}

export interface NormaliseResult {
  xml: string
  /** Segment members whose name was resolved — for the report, so a silent regression is visible. */
  named: number
  /** Contexts whose period was rewritten from a quarter to the year. */
  annualised: number
}

/**
 * Rewrites an NSE instance into XBRL the existing parser can read.
 *
 * Returns `NOT_CONSOLIDATED` rather than throwing: a standalone filing is a perfectly good document
 * that we simply do not want, and a caller counting failures must not count it as one.
 */
export function normalise(xml: string): NormaliseResult | typeof NOT_CONSOLIDATED {
  const nature = /NatureOfReportStandaloneConsolidated[^>]*>([^<]+)</.exec(xml)
  if (!nature || nature[1].trim().toLowerCase() !== 'consolidated') return NOT_CONSOLIDATED

  // context id -> the segment member it carries, and its dates.
  const ctxMember = new Map<string, string>()
  const ctxEnd = new Map<string, string>()
  const contextRe = /<xbrli:context id="([^"]+)"([\s\S]*?)<\/xbrli:context>/g
  for (let m = contextRe.exec(xml); m !== null; m = contextRe.exec(xml)) {
    const [, id, body] = m
    const mem = /ReportableSegment[A-Za-z]*Axis">([^<]+)</.exec(body)
    if (mem) ctxMember.set(id, mem[1])
    const end = /<xbrli:endDate>([^<]+)</.exec(body)
    if (end) ctxEnd.set(id, end[1].trim())
  }

  // The name lives on the same context as the value it names.
  const nameByContext = new Map<string, string>()
  const nameRe = /<in-bse-fin:DescriptionOfReportableSegment\b[^>]*contextRef="([^"]+)"[^>]*>([^<]+)</g
  for (let m = nameRe.exec(xml); m !== null; m = nameRe.exec(xml)) {
    nameByContext.set(m[1], m[2].trim())
  }

  let out = xml
  let named = 0
  let annualised = 0

  // 1. Rename every anonymous member to its own segment name.
  for (const [ctx, member] of ctxMember) {
    const name = nameByContext.get(ctx)
    if (!name) continue
    named++
    out = out.split(`>${member}<`).join(`>${memberCodeFor(name)}<`)
  }

  // 2. Give the `Four*` contexts the twelve-month period they actually describe. Keyed on the
  //    CONTEXT ID, which is where the distinction lives — `FourD`, `FourReportableSegmentRevenue01D`
  //    — because the dates themselves are identical for both columns.
  out = out.replace(
    /<xbrli:context id="(Four[^"]*)"([\s\S]*?)<\/xbrli:context>/g,
    (whole, id: string, body: string) => {
      const end = ctxEnd.get(id)
      if (!end) return whole
      annualised++
      return `<xbrli:context id="${id}"${
        body.replace(/<xbrli:startDate>[^<]+</, `<xbrli:startDate>${yearStartFor(end)}<`)
      }</xbrli:context>`
    },
  )

  return { xml: out, named, annualised }
}

// ── the client ──────────────────────────────────────────────────────────────────────────────────

/**
 * NSE refuses an unknown caller, and the handshake that fixes it ANSWERS 403.
 *
 * `nseindia.com` sets a session cookie on the landing page and its JSON API rejects any request
 * without it. Measured 2026-09-06: the landing request itself returns **403 while still returning
 * the `Set-Cookie` the API then accepts**, so a handshake step written as "throw unless ok" throws
 * away a working session. Deno's fetch does not manage a cookie jar, so the header is carried by
 * hand.
 */
async function handshake(base: string, timeoutMs: number): Promise<string> {
  const res = await fetch(base + '/', {
    headers: { 'User-Agent': NSE_UA, 'Accept': 'text/html' },
    signal: AbortSignal.timeout(timeoutMs),
  })
  // Deliberately not checking res.ok — see above.
  await res.body?.cancel()
  const raw = res.headers.get('set-cookie') ?? ''
  return raw.split(/,(?=[^;]+=)/).map((c) => c.split(';')[0].trim()).filter(Boolean).join('; ')
}

/** A browser UA is required; the API answers 403 to anything that looks automated. */
const NSE_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/124.0.0.0 Safari/537.36'

export async function listFilings(symbol: string, timeoutMs: number): Promise<NseFiling[]> {
  const base = nseOrigin()
  const cookie = await handshake(base, Math.min(15_000, timeoutMs))
  const url = `${base}/api/corporates-financial-results?index=equities` +
    `&symbol=${encodeURIComponent(symbol)}&period=Annual`
  const res = await fetch(url, {
    headers: {
      'User-Agent': NSE_UA,
      'Accept': 'application/json',
      'Referer': `${base}/companies-listing/corporate-filings-financial-results`,
      ...(cookie ? { Cookie: cookie } : {}),
    },
    signal: AbortSignal.timeout(timeoutMs),
  })
  if (!res.ok) throw new Error(`nse results ${res.status} for ${symbol}`)
  return parseFilings(await res.json())
}

/**
 * Pulled out so the shape can be asserted without a network call. NSE returns either a bare array
 * or `{ data: [...] }` depending on the endpoint version, and a filing with no `xbrl` is a real
 * row we simply cannot read — dropped here rather than failing the company.
 */
export function parseFilings(body: unknown): NseFiling[] {
  const rows = Array.isArray(body)
    ? body
    : (body && typeof body === 'object' && Array.isArray((body as { data?: unknown }).data)
      ? (body as { data: unknown[] }).data
      : [])
  const out: NseFiling[] = []
  for (const r of rows) {
    if (!r || typeof r !== 'object') continue
    const rec = r as Record<string, unknown>
    const xbrl = typeof rec.xbrl === 'string' ? rec.xbrl : ''
    if (!xbrl.startsWith('http')) continue
    out.push({ xbrlUrl: xbrl, toDate: String(rec.toDate ?? rec.to_date ?? '') })
  }
  return out
}

/**
 * The instance itself. 77-109 KB measured across the three filers — trivial beside SEC's
 * multi-megabyte documents or DART's 73-second ZIP, so there is no size gate and no warm-up dance.
 */
export async function fetchInstance(url: string, timeoutMs: number): Promise<string | null> {
  // THE ARCHIVES ORIGIN, so the fetch goes through http-cache. NSE returns absolute URLs on
  // nsearchives.nseindia.com; rewriting the host onto the configured origin is what keeps an
  // immutable document cacheable — and `origins.ts` defaults to the real host, so the cache
  // remains removable without an outage.
  const archives = nseArchivesOrigin()
  const target = url.replace(/^https?:\/\/nsearchives\.nseindia\.com/, archives)
  const referer = nseOrigin() + '/'
  // THE REFERER IS PASSED IN, not written here. NSE wants one, but a provider host spelled inside
  // this file is exactly what `http-cache-covers-every-provider` fails a PR for — and it is right
  // to: a hardcoded host is how a call silently stops going through the cache, and nothing in
  // production can report it. It caught this line the first time it ran.
  const res = await fetch(target, {
    headers: { 'User-Agent': NSE_UA, 'Referer': referer },
    signal: AbortSignal.timeout(timeoutMs),
  })
  if (!res.ok) {
    await res.body?.cancel()
    return null
  }
  return await res.text()
}

/**
 * NSE's `toDate` is `31-Mar-2024`. Returned as an ISO date so `security_filing.report_date` is
 * comparable with every other source's.
 */
export function isoFromNseDate(s: string): string | null {
  const m = /^(\d{2})-([A-Za-z]{3})-(\d{4})$/.exec(s.trim())
  if (!m) return null
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
  const mi = months.indexOf(m[2])
  if (mi < 0) return null
  return `${m[3]}-${String(mi + 1).padStart(2, '0')}-${m[1]}`
}

/**
 * NSE's own equity list: the ISIN -> trading-symbol map, and the reason India works at all.
 *
 * WHY THIS EXISTS. `pending_in_history` originally asked NSE using `market.listing.symbol`, on the
 * strength of a planning probe against RELIANCE, HDFCBANK and INFY — three symbols that happen to
 * match. Measured 2026-09-06 against this very file, only **239 of 645** Indian equities carry a
 * listing symbol NSE recognises. The rest hold a vendor abbreviation:
 *
 *     SUEL -> SUZLON      HUVR -> HINDUNILVR    MSIL -> MARUTI
 *     BAF  -> BAJFINANCE  KMB  -> KOTAKBANK     HNDL -> HINDALCO
 *
 * NSE answers an unknown symbol with an EMPTY ARRAY and HTTP 200, so `in-filings` reported
 * `walked: 6, mapped: 0, failed: 0` with no error at all — a resource succeeding at asking the
 * wrong question. That is this repo's oldest lesson (probe an endpoint with symbols you expect to
 * FAIL, not the obvious ones) reproduced while implementing it.
 *
 * Joining on ISIN recovers **389** of the 389 remaining, taking coverage from 37% to 97%. The list
 * is 2,570 rows with 2,570 DISTINCT ISINs and no blanks — measured, which is what makes the ISIN a
 * safe key here rather than an assumption.
 */
export async function equityList(timeoutMs: number): Promise<{ symbol: string; isin: string }[]> {
  // The archives origin, so this goes through http-cache like every other provider call.
  const res = await fetch(`${nseArchivesOrigin()}/content/equities/EQUITY_L.csv`, {
    headers: { 'User-Agent': NSE_UA, 'Referer': nseOrigin() + '/' },
    signal: AbortSignal.timeout(timeoutMs),
  })
  if (!res.ok) {
    await res.body?.cancel()
    throw new Error(`nse equity list failed: HTTP ${res.status}`)
  }
  return parseEquityList(await res.text())
}

/**
 * Split out so the parse is testable without the network. NSE's header is
 * `SYMBOL,NAME OF COMPANY, SERIES, DATE OF LISTING, PAID UP VALUE, MARKET LOT, ISIN NUMBER, ...`
 * — note the LEADING SPACES on every column after the first, which is why the header is matched
 * on a trimmed name rather than by position: a column inserted upstream would otherwise shift the
 * ISIN silently and map every company to the wrong symbol.
 */
export function parseEquityList(csv: string): { symbol: string; isin: string }[] {
  const lines = csv.split(/\r?\n/).filter((l) => l.trim().length > 0)
  if (lines.length < 2) return []
  const header = lines[0].split(',').map((h) => h.trim().toUpperCase())
  const iSym = header.indexOf('SYMBOL')
  const iIsin = header.indexOf('ISIN NUMBER')
  if (iSym < 0 || iIsin < 0) {
    throw new Error(`nse equity list header changed: ${header.join('|')}`)
  }
  const out: { symbol: string; isin: string }[] = []
  for (const line of lines.slice(1)) {
    const cells = line.split(',')
    const symbol = (cells[iSym] ?? '').trim()
    const isin = (cells[iIsin] ?? '').trim().toUpperCase()
    // An ISIN is 12 characters; anything else is a truncated or shifted row, and a bad key here
    // maps one company's filings onto another.
    if (symbol && /^[A-Z0-9]{12}$/.test(isin)) out.push({ symbol, isin })
  }
  return out
}
