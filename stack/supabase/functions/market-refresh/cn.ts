/**
 * China, via CNINFO — filing LINKS only, deliberately.
 *
 * China is the largest coverage gap in the universe at 2,311 equities, and it was spiked and found
 * NOT VIABLE for segments (migration 183): CNINFO has a perfectly good machine-readable search and
 * is reachable from the node, but **every filing is a PDF** — 2,771 announcements for China Yangtze
 * Power, all `adjunctType: PDF`, including all 61 annual reports, the FY2025 one beginning
 * `%PDF-1.7`.
 *
 * A PDF cannot give us a segment split. It can give a reader the annual report, which is better
 * than the nothing those 2,311 securities have today — and it costs no new schema and no UI work,
 * because `security_filing` already carries `report_url` and the Filings section already renders it
 * as a link.
 *
 * `is_xbrl = false` ON EVERY ROW IS LOAD-BEARING. `pending_segments` and its siblings select
 * filings to PARSE; a PDF that looked parseable would send the segment resources to spend their
 * budget fetching documents they cannot read, against a provider budget four other backlogs share.
 */
import { CNINFO_STATIC, cninfo as cninfoOrigin } from './origins.ts'

/** CNINFO answers 411 to a POST with no body, so every call sends form-encoded parameters. */
const FORM = { 'Content-Type': 'application/x-www-form-urlencoded' }
const UA = 'Mozilla/5.0 (compatible; muffin-market/1.0)'

export interface CnFiling {
  title: string
  /** Absolute URL of the PDF, resolved against CNINFO's static host. */
  url: string
  /** Announcement date as an ISO date, or null when CNINFO omits it. */
  date: string | null
  /** What KIND of document this is — see `classifyAnnouncement`. */
  kind: CnDocKind
  /** Size in KB as CNINFO reports it, or null. A cross-check on `kind`, never the rule. */
  sizeKb: number | null
}

/**
 * The three documents CNINFO files under one annual-report category.
 *
 * `full` is the only one a segment parser can read: the summary omits the breakdown table entirely
 * and the English edition uses English headings, so a parser looking for `主营业务分行业情况` finds
 * nothing in either and records the company as disclosing nothing.
 */
export type CnDocKind = 'full' | 'summary' | 'english'

/**
 * CNINFO's own internal id for a company, which its filing search REQUIRES.
 *
 * The search is keyed `stock=<code>,<orgId>` and returns ZERO announcements for a bare code — a
 * 200 with an empty list, not an error, which reads exactly like a company that has never filed.
 * `600900` resolves to `gssh0600900`.
 */
export async function orgIdFor(code: string, timeoutMs: number): Promise<string | null> {
  const res = await fetch(`${cninfoOrigin()}/new/information/topSearch/query`, {
    method: 'POST',
    headers: { ...FORM, 'User-Agent': UA },
    body: `keyWord=${encodeURIComponent(code)}&maxNum=10`,
    signal: AbortSignal.timeout(timeoutMs),
  })
  if (!res.ok) throw new Error(`cninfo topSearch ${res.status} for ${code}`)
  const body = await res.json()
  if (!Array.isArray(body)) return null
  const hit = body.find((r) => r && typeof r === 'object' && String((r as { code?: unknown }).code) === code)
  const org = hit && typeof hit === 'object' ? (hit as { orgId?: unknown }).orgId : null
  return typeof org === 'string' && org ? org : null
}

/** Annual reports for one company. `category_ndbg_szsh` is CNINFO's annual-report category. */
export async function annualReports(
  code: string,
  orgId: string,
  timeoutMs: number,
): Promise<CnFiling[]> {
  const res = await fetch(`${cninfoOrigin()}/new/hisAnnouncement/query`, {
    method: 'POST',
    headers: { ...FORM, 'User-Agent': UA },
    body: `stock=${encodeURIComponent(code)},${encodeURIComponent(orgId)}` +
      `&tabName=fulltext&pageSize=30&pageNum=1&category=category_ndbg_szsh`,
    signal: AbortSignal.timeout(timeoutMs),
  })
  if (!res.ok) throw new Error(`cninfo query ${res.status} for ${code}`)
  return parseAnnouncements(await res.json())
}

/**
 * Pulled out so the shape can be asserted with no network call.
 *
 * `adjunctUrl` is a PATH (`finalpage/2026-04-30/1225262036.PDF`) and must be resolved against the
 * STATIC host, which is a different origin from the API — a row stored with the bare path would
 * render as a dead link and nothing downstream could tell.
 */
export function parseAnnouncements(body: unknown): CnFiling[] {
  const rows = body && typeof body === 'object'
    ? (body as { announcements?: unknown }).announcements
    : null
  if (!Array.isArray(rows)) return []
  const out: CnFiling[] = []
  for (const r of rows) {
    if (!r || typeof r !== 'object') continue
    const rec = r as Record<string, unknown>
    const path = typeof rec.adjunctUrl === 'string' ? rec.adjunctUrl : ''
    if (!path) continue
    const title = String(rec.announcementTitle ?? '').slice(0, 300)
    out.push({
      title,
      url: `${CNINFO_STATIC}/${path.replace(/^\/+/, '')}`,
      date: isoFromEpochMs(rec.announcementTime),
      kind: classifyAnnouncement(title),
      sizeKb: typeof rec.adjunctSize === 'number' && Number.isFinite(rec.adjunctSize)
        ? rec.adjunctSize
        : null,
    })
  }
  return out
}

/**
 * Which document is this, from its own title?
 *
 * CNINFO's `category_ndbg_szsh` is "annual reports" and returns FIVE shapes under it. Measured
 * against the live API 2026-09-06:
 *
 *   中国长江电力…2025年年度报告              full report          259 pages
 *   …2025年年度报告摘要                     SUMMARY              11-16 pages, ~160 KB
 *   …2025年年度报告（更正后） / （更正版）      corrected full report
 *   振华重工2025年年度报告（英文版）           ENGLISH edition
 *   …2025年年度报告摘要（更正版）              corrected summary
 *
 * `cn-filings` stored all of them under one `report_type`, so of 8 companies sampled only 3 held a
 * full Chinese-language report: FOUR were summaries and one was Kweichow Moutai's English edition —
 * which is the real reason no Chinese heading could be found in it, not that Moutai discloses
 * nothing.
 *
 * SPLIT OUT SO IT IS TESTABLE WITH NO NETWORK, for the same reason `classifyBody` was split out of
 * `dart.ts`: left inline it is an untested branch, and the mutation that deletes it passes clean.
 *
 * THE ORDER OF THE TWO EXCLUSIONS IS NOT LOAD-BEARING, and saying so is the honest version. A
 * title carrying BOTH `摘要` and an English marker has not been observed, and if one exists both
 * branches reach the same place: neither kind is ever parsed, because both lack the mandated
 * Chinese table. What IS demonstrated is that a CORRECTED summary stays a summary — `更正后` is not
 * a branch, so it cannot displace `摘要`. A mutation swapping the two exclusion lines passes, and
 * that is correct rather than a gap.
 *
 * The title frequently omits the company name altogether (`2024年年度报告（更正后）`), so nothing
 * here may depend on it.
 */
export function classifyAnnouncement(title: string): CnDocKind {
  const t = title ?? ''
  if (t.includes('摘要')) return 'summary'
  if (t.includes('英文') || /annual\s+report/i.test(t)) return 'english'
  return 'full'
}

/** CNINFO dates are epoch milliseconds. A non-number is an absence, not a zero. */
export function isoFromEpochMs(v: unknown): string | null {
  if (typeof v !== 'number' || !Number.isFinite(v) || v <= 0) return null
  return new Date(v).toISOString().slice(0, 10)
}
