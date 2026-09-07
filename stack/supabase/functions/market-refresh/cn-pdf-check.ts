/**
 * Offline checks for the CNINFO PDF segment parser. No network, no database, no PDF.
 *
 * THE FIXTURE IS REAL GEOMETRY, NOT A REAL DOCUMENT. A 1.5 MB annual report cannot be committed,
 * so — as `in-check` does for NSE and `dart-check` does for a ZIP — this reproduces the coordinates
 * MEASURED on China Yangtze Power's FY2025 report, page 13:
 *
 *     境内水电@61        增加@505  3.28@529        name, first line — no money
 *     75,661,563,315.43@118  25,881,578,129.36@217   the money, on its own line, NO name
 *     行业@61            百分点@531                 name, second line
 *
 * That three-line row is the whole reason this parser reconstructs from positions rather than
 * text. Read as lines it yields the segment `行业` — "industry" — with the right number beside it,
 * which is a wrong answer that looks entirely ordinary. Each rule below is exercised by a case
 * where the candidate behaviours DISAGREE; a rule whose removal left the fixture passing would be
 * decoration.
 *
 * Pinned so a future reader can re-derive them, both verified against the real PDFs:
 *   Yangtze  境内水电行业 75,661,563,315.43 + 其他行业 10,323,376,439.80 = 85,984,939,755.23
 *   LONGi    five product members summing 129,497,674,192.20, exactly its industry total
 */
import { factsFromRows, fiscalYearEndFrom, parseSegmentPage, type TextItem } from './cn-pdf.ts'

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}
const it = (s: string, x: number, y: number): TextItem => ({ s, x, y })

/** Yangtze p13: the heading, the header row, and the two data rows — at their measured positions. */
const YANGTZE: TextItem[] = [
  it('主营业务分行业情况', 264.8, 617.7),
  it('分行业', 67.7, 596.8), it('营业收入', 138.6, 596.8), it('营业成本', 238.9, 596.8), it('毛利率', 312.1, 596.8),
  // Row 1 across three visual lines, money in the middle.
  it('境内水电', 61.2, 576.0), it('增加', 505.2, 576.0), it('3.28', 528.8, 576.0),
  it('75,661,563,315.43', 118.0, 570.0), it('25,881,578,129.36', 217.0, 570.0), it('65.79', 335.0, 570.0),
  it('行业', 61.2, 561.0), it('百分点', 531.0, 561.0),
  // Row 2 on one line, as most rows are.
  it('其他行业', 61.2, 546.0), it('10,323,376,439.80', 118.0, 546.0), it('7,067,072,381.81', 217.0, 546.0),
  // WHAT FOLLOWS THE TABLE, and it must not be absorbed into the last member. A real page continues
  // straight into the next section — `(2).产销量情况` and a cost-composition table whose columns
  // mean something else — and without the adjacency bound the continuation rule appends every one
  // of these to `其他行业`, which is how the earlier version produced a 60-character segment name.
  it('（2）产销量情况', 61.2, 512.0),
  it('单位：万千瓦时', 61.2, 498.0),
]

console.log('\ncninfo segment table — rebuilt from positions, not lines')
{
  const rows = parseSegmentPage(YANGTZE)
  check(rows.length === 2, 'both members are found', `${rows.length}`)
  check(rows[0]?.name === '境内水电行业',
    'the THREE-LINE row rejoins its name around the money line',
    `got ${JSON.stringify(rows[0]?.name)}`)
  check(rows[0]?.revenue === 75661563315.43 && rows[0]?.cost === 25881578129.36,
    'revenue and cost land in the right columns — a right-aligned figure begins LEFT of its own header label')
  check(rows[1]?.name === '其他行业' && rows[1]?.revenue === 10323376439.80,
    'an ordinary single-line row is unaffected',
    `got ${JSON.stringify(rows[1]?.name)}`)
  // The trailing text column (`增加 3.28 个百分点`) must not be mistaken for money.
  check(rows.every((r) => r.revenue > 1e9),
    'the trailing percentage column is not read as revenue',
    rows.map((r) => r.revenue).join(', '))
}

console.log('\nthe fiscal period comes from the document, not the announcement date')
{
  check(fiscalYearEndFrom('中国长江电力股份有限公司2025年年度报告 1 / 259') === '2025-12-31',
    'a title states its own year — the announcement lands the following April')
  check(fiscalYearEndFrom('隆基绿能科技股份有限公司2023 年年度报告') === '2023-12-31',
    '...with or without a space before 年')
  check(fiscalYearEndFrom('关于召开股东大会的通知') === null,
    'a document that states no year yields null rather than a guess')
}

console.log('\nfacts, partitions and the reconciliation target')
{
  const facts = factsFromRows(parseSegmentPage(YANGTZE), '2025-12-31')
  const rev = facts.filter((f) => f.metricCode === 'revenue')
  check(rev.length === 2 && rev.every((f) => f.partitionId === 1),
    'a split that reconciles is partition 1 — safe to aggregate',
    rev.map((f) => f.partitionId).join(','))
  check(rev.every((f) => f.reconciledTo === 85984939755.23),
    'the target is stored, so a later disagreement can be told from a double count')
  check(facts.every((f) => f.currency === 'CNY'),
    'the currency is stated, not inferred — a scale error here is four orders of magnitude')
  check(facts.every((f) => f.periodType === 'annual' && f.periodStart === '2025-01-01'),
    'an annual report is an annual period')
  check(facts.some((f) => f.metricCode === 'cost_of_revenue'),
    '营业成本 is carried as cost_of_revenue, not dropped')

  // A PARTIAL DISCLOSURE MUST NOT BE AGGREGATABLE. LONGi discloses geography covering 118.4bn of
  // its 129.5bn — real, and not a split of the whole — so it must land at partition 0 exactly as
  // an unreconciled XBRL split does.
  const partial = factsFromRows([
    { axis: 'cninfo:分行业', name: '光伏行业', revenue: 129497674192.20, cost: null },
    { axis: 'cninfo:分地区', name: '中国境内', revenue: 80960841085.85, cost: null },
    { axis: 'cninfo:分地区', name: '欧洲地区', revenue: 16816034208.79, cost: null },
    { axis: 'cninfo:分地区', name: '亚太地区', revenue: 20591381190.91, cost: null },
  ], '2023-12-31')
  const geo = partial.filter((f) => f.axis === 'cninfo:分地区')
  check(geo.length === 3 && geo.every((f) => f.partitionId === 0),
    'a partial geography disclosure is partition 0 — present, and never summed as the whole',
    geo.map((f) => f.partitionId).join(','))
  const ind = partial.filter((f) => f.axis === 'cninfo:分行业')
  check(ind.every((f) => f.partitionId === 1),
    '...while the split that does cover the whole stays aggregatable')
}

console.log(failures === 0 ? '\nALL CNINFO PDF CHECKS PASSED' : `\n${failures} CNINFO PDF CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
