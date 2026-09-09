/**
 * China's segment split, read out of the annual report PDF.
 *
 * WHY A PDF PARSER EXISTS HERE AT ALL. China is the largest coverage gap in the universe — 2,311
 * equities — and CNINFO publishes only PDFs, which is why migration 183 recorded it NOT VIABLE for
 * segments. That was measured on the transport and not on the documents. Measured on the documents
 * 2026-09-06, the conclusion is different:
 *
 *   * the reports are TEXT PDFs, not scans;
 *   * the CSRC **mandates** `主营业务分行业/分产品/分地区情况` in every A-share annual report, so
 *     this is a standard form rather than per-company scraping;
 *   * China Yangtze Power's industry split reconciles to **99.7%** of its consolidated revenue
 *     (85,984,939,755.23 against 86,241,940,222 — the gap is 其他业务, incidental revenue, which
 *     is exactly the 主营业务 / 营业收入 distinction);
 *   * LONGi's five-member product split reconciles **exactly** to its industry total
 *     (129,497,674,192.20), and it discloses geography as well;
 *   * extraction costs **170-190 ms and under 170 MB** against a 90 s / 256 MB worker, because the
 *     table sits on page 13-23 and the page scan stops there.
 *
 * WHY POSITIONS AND NOT TEXT. Raw text extraction is not equivalent and the difference is silent.
 * Yangtze writes its first segment as `境内水电` on one visual line and `行业 75,661,563,315.43 …`
 * on the next, so a line-based regex reads the name as `行业` ("industry") with the right number
 * beside it — a wrong answer that looks entirely ordinary. Rows have to be rebuilt from item
 * COORDINATES, which is the part of a table extractor that matters.
 *
 * Everything downstream is reused unchanged: this produces `SegmentFact[]`, so `assignPartitions`,
 * the reconciliation, the retraction and the whole serving layer behave exactly as they do for
 * XBRL. The only thing new in China is bytes -> facts.
 */
import { getDocumentProxy } from 'https://esm.sh/unpdf@0.12.1'
import { cninfoArchives } from './origins.ts'
import type { SegmentFact } from './segments.ts'
import { assignPartitions } from './segments.ts'

/**
 * A report is refused above this, unread.
 *
 * `security-segments` learned the hard way that one oversized document is a PERMANENT head-of-line
 * block: American Electric Power's 2015 10-K is 127.72 MB, a JS string is UTF-16, and the worker
 * died in under two seconds on every firing for two days — with a page of ONE — because a killed
 * worker throws nothing and therefore stamps nothing.
 *
 * 24 MB WAS JUSTIFIED BY A RANGE THAT DID NOT HOLD, and China reproduced the same two-day silence
 * for it. The old reasoning was "the measured Chinese reports run 0.9-5.5 MB, so 24 MB is generous
 * while still bounding the worst case well inside 256 MB" — but a PDF's cost is not its file size.
 * Measured 2026-09-09 by driving this parser against real reports:
 *
 *   1.46 MB report ->  74 MB of RSS, parsed in 356 ms
 *   9.15 MB report -> 129 MB of RSS, parsed in 577 ms
 *
 * So RSS scales with the document while TIME barely moves, and a single 9.15 MB report plus the
 * worker's own baseline does not fit a 256 MB isolate. The isolate is now 384 MB (see
 * `functions/main/index.ts`), and this gate is set where the measurement supports rather than where
 * a file size felt generous: 12 MB admits every report seen so far, including the 9.15 MB one that
 * wedged the queue, and refuses anything whose cost is unknown.
 */
export const MAX_PDF_BYTES = 12 * 1024 * 1024

/** Returned instead of bytes when the report is too large to read — a refusal, not an absence. */
export const TOO_LARGE = Symbol('cninfo report exceeds MAX_PDF_BYTES')

/**
 * Download one report through http-cache.
 *
 * The stored `report_url` is the PUBLIC host, because it is a link a reader's browser opens. The
 * fetch rewrites it onto the configured origin so it goes through the cache — an annual report is
 * immutable and gets re-read on every parser-version bump. `origins.ts` defaults to the real host,
 * which is what keeps the cache removable without an outage.
 *
 * `content-length` is checked BEFORE the body is read, so an oversized document costs one round
 * trip rather than the worker.
 */
export async function fetchReport(
  url: string,
  timeoutMs: number,
): Promise<Uint8Array | null | typeof TOO_LARGE> {
  const target = url.replace(/^https?:\/\/static\.cninfo\.com\.cn/, cninfoArchives())
  const res = await fetch(target, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; muffin-market/1.0)' },
    signal: AbortSignal.timeout(timeoutMs),
  })
  if (!res.ok) {
    await res.body?.cancel()
    return null
  }
  const declared = Number(res.headers.get('content-length') ?? 0)
  if (declared > MAX_PDF_BYTES) {
    await res.body?.cancel()
    return TOO_LARGE
  }
  const bytes = new Uint8Array(await res.arrayBuffer())
  // A server that omitted `content-length` still must not be allowed past the bound.
  if (bytes.byteLength > MAX_PDF_BYTES) return TOO_LARGE
  // NOT A PDF. CNINFO answers some paths with an HTML error page and HTTP 200, which pdf.js would
  // reject with an opaque parse error attributed to the document rather than to the fetch.
  if (bytes.byteLength < 5 || String.fromCharCode(...bytes.subarray(0, 5)) !== '%PDF-') return null
  return bytes
}

/** A money cell: thousands-separated with one or two decimals, as every one of these tables uses. */
const NUM = /^-?[\d,]+\.\d{1,2}$/

/**
 * The three mandated tables, and the axis each becomes.
 *
 * `kind` matches `market.segment_axis.kind` so the serving layer treats these exactly like an XBRL
 * axis. The axis string is what lands in `security_segment.axis`, so it must be stable: it is the
 * Chinese heading, prefixed, rather than a translation that could drift.
 */
export const CN_TABLES = [
  { heading: '主营业务分行业情况', axis: 'cninfo:分行业' },
  { heading: '主营业务分产品情况', axis: 'cninfo:分产品' },
  { heading: '主营业务分地区情况', axis: 'cninfo:分地区' },
] as const

/** The header labels that define the columns. `营业收入` and `营业成本` are the two we store. */
const NAME_HDR = ['分行业', '分产品', '分地区']
const REV_HDR = '营业收入'
const COST_HDR = '营业成本'

/** One row of a mandated table, before it becomes facts. */
export interface CnSegmentRow {
  axis: string
  name: string
  revenue: number
  cost: number | null
}

export interface TextItem {
  s: string
  x: number
  y: number
}

/**
 * A member name, with the typesetting taken back out of it.
 *
 * JUSTIFIED CJK IS SET WITH SPACE BETWEEN THE CHARACTERS, and pdf.js reports what it sees:
 * Canadian Solar's FY2025 report yields `光 伏 组 件 产品收入` for what the filing calls
 * 光伏组件产品收入 (PV module product revenue). The name is the UPSERT KEY, so the same segment
 * typeset differently in next year's report would arrive as a SECOND member and both would survive
 * — the ASML defect, where `asml:EuvMember` became `asml:NXEMember` between two filings and the
 * two splits unioned into one that reconciled to nothing.
 *
 * ONLY BETWEEN TWO CJK CHARACTERS. Chinese does not space its words, so a gap there is always
 * typesetting; a gap beside a Latin character or a digit may be real (`A 股`, `H 股`, a unit), and
 * stripping it would corrupt a name rather than restore it.
 */
export function tidyMemberName(raw: string): string {
  const CJK = /[\u3400-\u9FFF\uF900-\uFAFF]/
  let out = ''
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]
    if (/\s/.test(ch) && CJK.test(raw[i - 1] ?? '') && CJK.test(raw[i + 1] ?? '')) continue
    out += ch
  }
  return out.trim()
}

/**
 * Rebuild the mandated tables from one page's positioned text.
 *
 * THE COLUMN BOUNDARIES COME FROM THE HEADER, as midpoints between its labels — not from the label
 * positions themselves. A money value is RIGHT-aligned and therefore begins to the LEFT of its own
 * header label, so using the label's x puts the revenue figure in the name column and shifts every
 * metric one place. That version found every member and reported all of them wrong.
 *
 * A ROW IS COMPLETE WHEN ITS REVENUE COLUMN FILLS, AND ITS NAME CAN ARRIVE ON EITHER SIDE OF THE
 * MONEY. Measured on Yangtze p13, one row occupies THREE visual lines:
 *
 *     境内水电@61        增加@505  3.28@529     name, first line — no money
 *     75,661,563,315.43@118  25,881,578,129.36@217   the money, on its own line, NO name
 *     行业@61            百分点@531             name, second line
 *
 * So a name-only line before the money is a PREFIX held until the row closes, and one after it is
 * a SUFFIX appended to the row just emitted. Handling only the suffix loses the row entirely (the
 * money line has no name of its own); handling only the prefix produced `境内水电` and
 * `行业其他行业` — two wrong names out of one right split. The suffix must also be ADJACENT, or the
 * rule keeps swallowing every name-only line after the table ends.
 */
export function parseSegmentPage(items: TextItem[]): CnSegmentRow[] {
  const buckets = new Map<number, TextItem[]>()
  for (const i of items) {
    // ~3pt buckets: two items on one printed line rarely differ by more than a couple, and
    // consecutive lines in these reports are ~11 apart.
    const k = Math.round(i.y / 3)
    if (!buckets.has(k)) buckets.set(k, [])
    buckets.get(k)!.push(i)
  }
  const lines = [...buckets.entries()]
    .sort((a, b) => b[0] - a[0])
    .map(([, v]) => v.sort((a, b) => a.x - b.x))

  const out: CnSegmentRow[] = []
  let axis = ''
  let nameEnd = 0
  let revEnd = 0
  let lastY = 0
  let pending: string[] = []

  for (const line of lines) {
    const joined = line.map((i) => i.s).join('')
    const table = CN_TABLES.find((t) => joined.includes(t.heading))
    if (table) {
      axis = table.axis
      nameEnd = revEnd = 0
      pending = []
      continue
    }
    if (!axis) continue

    const nameX = line.find((i) => NAME_HDR.includes(i.s.trim()))?.x
    const revX = line.find((i) => i.s.trim() === REV_HDR)?.x
    const costX = line.find((i) => i.s.trim() === COST_HDR)?.x
    if (nameX !== undefined && revX !== undefined && costX !== undefined) {
      nameEnd = (nameX + revX) / 2
      revEnd = (revX + costX) / 2
      // The header's own `分行业` cell would otherwise become the first data row's name prefix.
      pending = []
      continue
    }
    if (!revEnd) continue

    const names = line.filter((i) => i.x < nameEnd).map((i) => i.s.trim()).filter(Boolean)
    const rev = line.find((i) => i.x >= nameEnd && i.x < revEnd && NUM.test(i.s.trim()))
    const cost = line.find((i) => i.x >= revEnd && NUM.test(i.s.trim()))

    if (!rev) {
      if (names.length === 0) continue
      // A SUFFIX if it is adjacent to the row just emitted, a PREFIX otherwise. One printed line is
      // ~11pt here, so 16 admits a wrap and nothing else — without the bound the rule keeps
      // swallowing every name-only line after the table ends.
      if (out.length > 0 && lastY > 0 && lastY - line[0].y < 16) {
        out[out.length - 1].name = tidyMemberName(out[out.length - 1].name + names.join(''))
      } else {
        pending.push(...names)
      }
      continue
    }
    const name = tidyMemberName([...pending, ...names].join(''))
    pending = []
    if (!name) continue
    lastY = line[0].y
    out.push({
      axis,
      name,
      revenue: Number(rev.s.replace(/,/g, '')),
      cost: cost ? Number(cost.s.replace(/,/g, '')) : null,
    })
  }
  return out
}

/**
 * The period the report covers, from the document's own title.
 *
 * A-share fiscal years are calendar years, so `2025年年度报告` means the twelve months ending
 * 2025-12-31. Read from the DOCUMENT rather than derived from the announcement date, which is the
 * following April and would be a guess dressed as a fact.
 */
export function fiscalYearEndFrom(text: string): string | null {
  const m = /(\d{4})\s*年\s*年度报告/.exec(text)
  if (!m) return null
  const y = Number(m[1])
  if (!Number.isFinite(y) || y < 1990 || y > 2100) return null
  return `${y}-12-31`
}

/** `营业收入` and `营业成本` are the two metrics these tables carry. */
const METRICS: { key: 'revenue' | 'cost'; code: string }[] = [
  { key: 'revenue', code: 'revenue' },
  { key: 'cost', code: 'cost_of_revenue' },
]

/**
 * Rows -> facts, with each table partitioned against its own stated total.
 *
 * THE RECONCILIATION TARGET IS THE INDUSTRY TABLE'S OWN SUM, not the company's consolidated
 * revenue. The mandated tables cover 主营业务 (main business) while `营业收入` on the highlights
 * page is total operating revenue including 其他业务 — Yangtze's split is 99.7% of it, and treating
 * the 0.3% as a failure would reject a correct disclosure. The industry and product tables are two
 * views of the same main-business revenue and must agree, which is exactly what `assignPartitions`
 * tests.
 */
export function factsFromRows(rows: CnSegmentRow[], periodEnding: string): SegmentFact[] {
  const periodStart = `${Number(periodEnding.slice(0, 4))}-01-01`
  const byAxis = new Map<string, CnSegmentRow[]>()
  for (const r of rows) {
    if (!byAxis.has(r.axis)) byAxis.set(r.axis, [])
    byAxis.get(r.axis)!.push(r)
  }

  // Every table is a view of the same main-business revenue, so the largest table's total is the
  // figure they are all reconciled against. Using each table's own sum would make every split
  // reconcile with itself by construction, which asserts nothing.
  const totals = [...byAxis.values()].map((rs) => rs.reduce((a, r) => a + r.revenue, 0))
  const target = totals.length > 0 ? Math.max(...totals) : 0

  const out: SegmentFact[] = []
  for (const [axis, rs] of byAxis) {
    const parts = assignPartitions(
      rs.map((r) => ({ memberCode: `cninfo:${r.name}`, value: r.revenue })),
      target,
    )
    for (const r of rs) {
      const memberCode = `cninfo:${r.name}`
      const partitionId = parts.get(memberCode) ?? 0
      for (const m of METRICS) {
        const value = m.key === 'revenue' ? r.revenue : r.cost
        if (value === null || !Number.isFinite(value)) continue
        out.push({
          axis,
          memberCode,
          metricCode: m.code,
          periodType: 'annual',
          periodStart,
          periodEnding,
          value,
          // A-share reports are denominated in yuan, and these figures are in 元 rather than 万元 —
          // Yangtze's 75,661,563,315.43 against a company whose revenue is ~86bn yuan. Stated
          // rather than inferred, because a scale error here is wrong by four orders of magnitude
          // and entirely plausible-looking.
          currency: 'CNY',
          parentAxis: null,
          parentMember: null,
          reconciledTo: target > 0 ? target : null,
          partitionId,
        })
      }
    }
  }
  return out
}

/** Positioned text for one page. */
async function itemsFor(doc: unknown, page: number): Promise<TextItem[]> {
  // deno-lint-ignore no-explicit-any
  const c = await (await (doc as any).getPage(page)).getTextContent()
  // deno-lint-ignore no-explicit-any
  return (c.items as any[])
    .filter((i) => typeof i.str === 'string' && i.str.trim() !== '')
    .map((i) => ({ s: i.str as string, x: i.transform[4] as number, y: i.transform[5] as number }))
}

export interface CnParseResult {
  facts: SegmentFact[]
  /** The page the table was found on, or null. Reported so a miss can be told from a bad parse. */
  page: number | null
  periodEnding: string | null
}

/**
 * Read one annual report.
 *
 * `scanPages` bounds the search, and 45 WAS TOO LOW — measured against production rather than
 * guessed. The mandated table is in 管理层讨论与分析, section 3 of a standard report, and the two
 * documents this parser was built on put it on page **13** and **23**. Canadian Solar's 327-page
 * FY2025 report puts it on page **68**, so the resource read it, found nothing, and stamped it
 * parsed — a filing recorded as disclosing no segments while its split sat 23 pages past the bound.
 *
 * A BOUND IS STILL RIGHT, because the cost of not having one falls on every filing that genuinely
 * has no table. Measured per document, in isolation, which is how the worker runs them:
 *
 *     Canadian Solar 327p, table on p68   limit 90   298 ms   124 MB
 *     LONGi 320p, table on p23            limit 90   248 ms   140 MB
 *
 * against a 90 s / 256 MB worker. (Scanning several documents in one process reaches 234 MB at
 * limit 120, but that is the harness accumulating, not a worker.) 90 clears the measured range
 * with room; raising it further buys nothing until a filing is found beyond it.
 */
export async function segmentFactsFromPdf(
  bytes: Uint8Array,
  scanPages = 90,
): Promise<CnParseResult> {
  const doc = await getDocumentProxy(bytes)
  let period: string | null = null
  // deno-lint-ignore no-explicit-any
  const pages = Math.min(scanPages, (doc as any).numPages as number)
  for (let p = 1; p <= pages; p++) {
    const items = await itemsFor(doc, p)
    const text = items.map((i) => i.s).join('')
    if (period === null) period = fiscalYearEndFrom(text)
    if (!text.includes(CN_TABLES[0].heading)) continue
    const rows = parseSegmentPage(items)
    if (rows.length === 0) return { facts: [], page: p, periodEnding: period }
    if (period === null) return { facts: [], page: p, periodEnding: null }
    return { facts: factsFromRows(rows, period), page: p, periodEnding: period }
  }
  return { facts: [], page: null, periodEnding: period }
}
