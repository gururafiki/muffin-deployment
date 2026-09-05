/**
 * Offline checks for the segment parser. No network, no database.
 *
 * WHY THESE FIXTURES LOOK OVER-BUILT. Every defect this parser can have produces a plausible
 * number rather than an error — a doubled revenue, a subtotal counted beside its own children, a
 * nine-month figure filed as a quarter, pounds labelled dollars. So each fixture is built so that
 * the CANDIDATE RULES DISAGREE: if a mutation of the rule under test would still produce the same
 * answer on the fixture, the fixture proves nothing. That discipline is why the Amazon case below
 * carries three partitions rather than one, and why the profit figures deliberately do NOT sum to
 * the consolidated profit.
 */
import { assignPartitions, instanceIsTooLarge, periodTypeFor, segmentFactsFrom, type SegmentAxisSpec, type SegmentConceptSpec } from './segments.ts'

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

const AXES: SegmentAxisSpec[] = [
  { axis: 'srt:ProductOrServiceAxis', kind: 'product', priority: 100, requiredMember: null },
  { axis: 'us-gaap:StatementBusinessSegmentsAxis', kind: 'business', priority: 90, requiredMember: null },
  { axis: 'ifrs-full:ProductsAndServicesAxis', kind: 'product', priority: 100, requiredMember: null },
  { axis: 'srt:ConsolidationItemsAxis', kind: 'qualifier', priority: 0, requiredMember: null },
]
const CONCEPTS: SegmentConceptSpec[] = [
  { metricCode: 'revenue', concept: 'RevenueFromContractWithCustomerExcludingAssessedTax', priority: 100 },
  { metricCode: 'revenue', concept: 'Revenue', priority: 100 },
  { metricCode: 'operating_income', concept: 'OperatingIncomeLoss', priority: 100 },
]

// ── fixture builder ────────────────────────────────────────────────────────────────────────────
interface FixtureFact {
  concept: string
  value: number | null
  dims?: Record<string, string>
  start?: string
  end?: string
  /** A balance-sheet date. Emits an `<instant>` context rather than a start/end pair. */
  instant?: string
  unit?: string
  attrs?: string
}
const Q_START = '2025-04-01'
const Q_END = '2025-06-30'

function instance(facts: FixtureFact[], units: Record<string, string> = { usd: 'iso4217:USD' }): string {
  const ctxIds = new Map<string, string>()
  const ctxXml: string[] = []
  const factXml: string[] = []
  for (const f of facts) {
    const start = f.start ?? Q_START
    const end = f.end ?? Q_END
    const dims = f.dims ?? {}
    const key = JSON.stringify([f.instant ?? start, f.instant ?? end, f.instant ?? '', dims])
    let id = ctxIds.get(key)
    if (!id) {
      id = `c${ctxIds.size}`
      ctxIds.set(key, id)
      const members = Object.entries(dims)
        .map(([a, m]) => `<xbrldi:explicitMember dimension="${a}">${m}</xbrldi:explicitMember>`)
        .join('')
      ctxXml.push(
        `<xbrli:context id="${id}"><xbrli:entity><xbrli:identifier scheme="s">1</xbrli:identifier>` +
        (members ? `<xbrli:segment>${members}</xbrli:segment>` : '') +
        `</xbrli:entity><xbrli:period>` +
        (f.instant
          ? `<xbrli:instant>${f.instant}</xbrli:instant>`
          : `<xbrli:startDate>${start}</xbrli:startDate><xbrli:endDate>${end}</xbrli:endDate>`) +
        `</xbrli:period></xbrli:context>`,
      )
    }
    factXml.push(
      `<us-gaap:${f.concept} contextRef="${id}" unitRef="${f.unit ?? 'usd'}"${f.attrs ?? ''}>` +
      `${f.value ?? ''}</us-gaap:${f.concept}>`,
    )
  }
  const unitXml = Object.entries(units)
    .map(([id, m]) => `<xbrli:unit id="${id}"><xbrli:measure>${m}</xbrli:measure></xbrli:unit>`)
    .join('')
  return `<?xml version="1.0"?><xbrli:xbrl>${unitXml}${ctxXml.join('')}${factXml.join('')}</xbrli:xbrl>`
}

const REV = 'RevenueFromContractWithCustomerExcludingAssessedTax'
const PROD = 'srt:ProductOrServiceAxis'
const BIZ = 'us-gaap:StatementBusinessSegmentsAxis'
const prod = (m: string) => ({ [PROD]: m })

console.log('segment parsing')

// 1. THE HEADLINE CASE. Amazon Q2-2025 discloses THREE splits that each sum to the same
//    167,702: seven product lines, Product+Service, and three business segments. AWS appears
//    twice with a different value under each axis. A reader that sums the ProductOrService axis
//    reports 335,404; one that sums every member reports 503,106. Both are plausible and wrong.
{
  const xml = instance([
    { concept: REV, value: 167702 },
    { concept: REV, value: 61485, dims: prod('amzn:OnlineStoresMember') },
    { concept: REV, value: 40348, dims: prod('amzn:ThirdPartySellerServicesMember') },
    { concept: REV, value: 30873, dims: prod('amzn:AmazonWebServicesMember') },
    { concept: REV, value: 15694, dims: prod('amzn:AdvertisingServicesMember') },
    { concept: REV, value: 12208, dims: prod('amzn:SubscriptionServicesMember') },
    { concept: REV, value: 5595, dims: prod('amzn:PhysicalStoresMember') },
    { concept: REV, value: 1499, dims: prod('amzn:OtherServicesMember') },
    { concept: REV, value: 68246, dims: prod('us-gaap:ProductMember') },
    { concept: REV, value: 99456, dims: prod('us-gaap:ServiceMember') },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  const byPart = new Map<number, number>()
  for (const f of out) byPart.set(f.partitionId, (byPart.get(f.partitionId) ?? 0) + f.value)
  const sizes = new Map<number, number>()
  for (const f of out) sizes.set(f.partitionId, (sizes.get(f.partitionId) ?? 0) + 1)

  check(out.length === 9, 'every disclosed member is stored', `got ${out.length}`)
  check(sizes.get(1) === 7 && byPart.get(1) === 167702,
    'the SEVEN-member split is one partition and reconciles',
    `size ${sizes.get(1)} sum ${byPart.get(1)}`)
  check(sizes.get(2) === 2 && byPart.get(2) === 167702,
    'Product+Service is a SEPARATE partition, not merged into the first',
    `size ${sizes.get(2)} sum ${byPart.get(2)}`)
  check((sizes.get(0) ?? 0) === 0, 'nothing is left unplaced in this filing')
  // The mutation this defends against: aggregating the AXIS rather than the PARTITION.
  const axisSum = out.reduce((a, f) => a + f.value, 0)
  check(axisSum === 335404 && byPart.get(1) === 167702,
    'summing the axis would DOUBLE revenue — the partition is what makes it right',
    `axis ${axisSum}`)
}

// 1b. PARTITION 1 IS THE FINEST SPLIT, WHATEVER ORDER THE FILING USED.
//     The fixture above could not tell "largest subset" from "first subset found": the detailed
//     members happened to be tagged first, so both rules picked them and a mutation dropping the
//     maximality test passed clean. Here the COARSE pair is stated first, which is the only
//     arrangement in which the two rules disagree — first-found gives {Product, Service} and
//     maximal gives the seven lines. The app reads partition 1, so getting this backwards would
//     serve "Amazon has two revenue streams: products and services".
{
  const xml = instance([
    { concept: REV, value: 167702 },
    { concept: REV, value: 68246, dims: prod('us-gaap:ProductMember') },
    { concept: REV, value: 99456, dims: prod('us-gaap:ServiceMember') },
    { concept: REV, value: 61485, dims: prod('amzn:OnlineStoresMember') },
    { concept: REV, value: 40348, dims: prod('amzn:ThirdPartySellerServicesMember') },
    { concept: REV, value: 30873, dims: prod('amzn:AmazonWebServicesMember') },
    { concept: REV, value: 15694, dims: prod('amzn:AdvertisingServicesMember') },
    { concept: REV, value: 12208, dims: prod('amzn:SubscriptionServicesMember') },
    { concept: REV, value: 5595, dims: prod('amzn:PhysicalStoresMember') },
    { concept: REV, value: 1499, dims: prod('amzn:OtherServicesMember') },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  const p1 = out.filter((f) => f.partitionId === 1)
  check(p1.length === 7 && p1.reduce((a, f) => a + f.value, 0) === 167702,
    'partition 1 is the FINEST reconciling split even when a coarser one is tagged first',
    `${p1.length} members`)
  check(p1.some((f) => f.memberCode === 'amzn:AmazonWebServicesMember'),
    'AWS is a first-class stream, not folded into "Service"')
}

// 2. A SUBTOTAL IS NOT A MEMBER OF THE SPLIT. Apple's product members decompose ProductMember
//    only, so the split that reconciles MIXES company extensions with a standard member:
//    {iPhone, iPad, Mac, Wearables, Service}. Two plausible rules are wrong here and the fixture
//    makes them disagree — "prefer extension members" drops Service (66,613, not the total), and
//    "take every member" gives 160,649.
{
  const xml = instance([
    { concept: REV, value: 94036 },
    { concept: REV, value: 44582, dims: prod('aapl:IPhoneMember') },
    { concept: REV, value: 8046, dims: prod('aapl:MacMember') },
    { concept: REV, value: 6581, dims: prod('aapl:IPadMember') },
    { concept: REV, value: 7404, dims: prod('aapl:WearablesHomeandAccessoriesMember') },
    { concept: REV, value: 27423, dims: prod('us-gaap:ServiceMember') },
    { concept: REV, value: 66613, dims: prod('us-gaap:ProductMember') },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  const p1 = out.filter((f) => f.partitionId === 1)
  const sub = out.find((f) => f.memberCode === 'us-gaap:ProductMember')
  check(p1.length === 5 && p1.reduce((a, f) => a + f.value, 0) === 94036,
    'the reconciling split mixes extension members with a standard one',
    `${p1.length} members, ${p1.reduce((a, f) => a + f.value, 0)}`)
  check(sub?.partitionId === 0, 'ProductMember is a SUBTOTAL and is excluded from every partition',
    `got p${sub?.partitionId}`)
  check(p1.some((f) => f.memberCode === 'us-gaap:ServiceMember'),
    'Services is IN the split — a rule preferring company extensions would drop it')
}

// 3. SEGMENT PROFIT DOES NOT RECONCILE, BY DESIGN, AND MUST STILL BE AGGREGATABLE.
//    ASC 280 leaves shared costs unallocated: Apple's segment operating income sums to 38,949
//    against a consolidated 28,202. A rule that demands every metric reconcile marks all profit
//    unusable — which is the number this whole feature exists to serve. The split is learned from
//    revenue and applied. The fixture makes the two rules disagree by construction: the profit
//    members sum to something that is NOT the consolidated profit.
{
  const xml = instance([
    { concept: REV, value: 94036 },
    { concept: REV, value: 41198, dims: { [BIZ]: 'aapl:AmericasSegmentMember' } },
    { concept: REV, value: 52838, dims: { [BIZ]: 'aapl:EuropeSegmentMember' } },
    { concept: 'OperatingIncomeLoss', value: 28202 },
    { concept: 'OperatingIncomeLoss', value: 16511, dims: { [BIZ]: 'aapl:AmericasSegmentMember' } },
    { concept: 'OperatingIncomeLoss', value: 22438, dims: { [BIZ]: 'aapl:EuropeSegmentMember' } },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  const profit = out.filter((f) => f.metricCode === 'operating_income')
  check(profit.length === 2 && profit.every((f) => f.partitionId === 1),
    'segment profit inherits the split from revenue even though it does not reconcile',
    JSON.stringify(profit.map((f) => f.partitionId)))
  check(profit.reduce((a, f) => a + f.value, 0) !== 28202,
    'the fixture genuinely makes the two rules disagree (profit does NOT sum to consolidated)')
}

// 4. A QUALIFIER AXIS NARROWS A FACT; AN UNKNOWN AXIS DISQUALIFIES IT. Alphabet tags every
//    segment figure with ConsolidationItems=OperatingSegments, so rejecting two-dimension facts
//    outright would lose all of it. Apple's instance carries 206 dimensioned facts of which only
//    44 are segmentations — fair-value levels and equity components must not become "segments".
{
  const xml = instance([
    { concept: REV, value: 100 },
    { concept: REV, value: 60, dims: { [BIZ]: 'goog:GoogleCloudMember', 'srt:ConsolidationItemsAxis': 'us-gaap:OperatingSegmentsMember' } },
    { concept: REV, value: 40, dims: { [BIZ]: 'goog:GoogleServicesMember', 'srt:ConsolidationItemsAxis': 'us-gaap:OperatingSegmentsMember' } },
    // A DISTINCT member on purpose. Reusing GoogleCloud here made the fixture useless: the fact
    // was discarded by the duplicate rule rather than by the unknown-axis rule, so removing the
    // rule under test still passed. Found by mutation, not by reading.
    { concept: REV, value: 999, dims: { [BIZ]: 'goog:OtherBetsMember', 'us-gaap:FairValueByFairValueHierarchyLevelAxis': 'us-gaap:FairValueInputsLevel2Member' } },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  check(out.length === 2 && out.every((f) => f.partitionId === 1),
    'a qualifier axis alongside the segment axis is kept', `got ${out.length}`)
  check(!out.some((f) => f.value === 999),
    'a fact carrying an UNKNOWN second axis is rejected, not treated as a segment')
}

// 5. A YEAR-TO-DATE FIGURE IS NOT A QUARTER. A 10-Q states both the 3-month and the 9-month
//    figure for the same concept and end date. Storing the 9-month one as a quarter is the exact
//    4x error `security_statement`'s primary key already exists to prevent.
{
  check(periodTypeFor('2025-03-30', '2025-06-28') === 'quarter', 'a 91-day period is a quarter')
  check(periodTypeFor('2024-09-29', '2025-09-27') === 'annual', 'a 363-day period is annual')
  check(periodTypeFor('2025-01-01', '2025-06-30') === null, 'a half-year is REJECTED, not rounded')
  check(periodTypeFor('2024-10-01', '2025-06-28') === null, 'a nine-month YTD figure is REJECTED')
}

// 6. THE CURRENCY COMES FROM THE UNIT. A foreign private issuer reports in its own currency, and
//    Diageo's 20-F is measured proof that the reporting currency cannot be assumed from the
//    country — it files in USD. A default would relabel one as the other.
{
  const xml = instance([
    { concept: REV, value: 100, unit: 'gbp' },
    { concept: REV, value: 60, dims: prod('x:AMember'), unit: 'gbp' },
    { concept: REV, value: 40, dims: prod('x:BMember'), unit: 'gbp' },
  ], { gbp: 'iso4217:GBP' })
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  check(out.length === 2 && out.every((f) => f.currency === 'GBP'),
    'the reporting currency is read from the unit, never defaulted',
    JSON.stringify(out.map((f) => f.currency)))
}

// 7. AN EMPTY VALUE IS AN ABSENCE. `xsi:nil` is how a filing says "no value here"; read as 0 it
//    puts a fabricated zero beside real revenue and breaks the partition arithmetic silently.
{
  const xml = instance([
    { concept: REV, value: 100 },
    { concept: REV, value: 60, dims: prod('x:AMember') },
    { concept: REV, value: 40, dims: prod('x:BMember') },
    { concept: REV, value: null, dims: prod('x:CMember'), attrs: ' xsi:nil="true"' },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  check(out.length === 2 && !out.some((f) => f.memberCode === 'x:CMember'),
    'a valueless (nil) fact is an absence, not a zero', `got ${out.length}`)
}

// 8. THE SAME FACT TWICE MUST COUNT ONCE. A filing may state a value at two `decimals`. Counted
//    twice the member's own partition stops reconciling, which would silently demote a correct
//    split to partition 0.
{
  const xml = instance([
    { concept: REV, value: 100 },
    { concept: REV, value: 60, dims: prod('x:AMember') },
    { concept: REV, value: 60, dims: prod('x:AMember'), attrs: ' decimals="-3"' },
    { concept: REV, value: 40, dims: prod('x:BMember') },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  check(out.length === 2 && out.every((f) => f.partitionId === 1),
    'a duplicated fact is stored once and the split still reconciles', `got ${out.length}`)
}

// 9. NO CONSOLIDATED FIGURE MEANS NO CLAIM. When the filing states no undimensioned total for a
//    concept, the members are still STORED — a coarse split may be all a filer gives, and an
//    upsert cannot retract — but nothing claims they reconcile.
{
  const xml = instance([
    { concept: REV, value: 60, dims: prod('x:AMember') },
    { concept: REV, value: 40, dims: prod('x:BMember') },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  check(out.length === 2 && out.every((f) => f.partitionId === 0),
    'with no consolidated figure the members are stored but unplaced',
    JSON.stringify(out.map((f) => f.partitionId)))
}

// 10. THE SUBSET SEARCH IS BOUNDED. Beyond the cap the honest answer is "unplaced", never a
//     half-finished partition and never a hung worker.
{
  const many = Array.from({ length: 24 }, (_, i) => ({ memberCode: `m${i}`, value: 1 }))
  const out = assignPartitions(many, 999)
  check([...out.values()].every((v) => v === 0),
    'an unreasonably wide axis is left unplaced rather than searched exhaustively')
  const exact = Array.from({ length: 24 }, (_, i) => ({ memberCode: `m${i}`, value: 1 }))
  check([...assignPartitions(exact, 24).values()].every((v) => v === 1),
    'but the common case — every member in one split — still works at any width')
}

// 11. THE RECONCILIATION TARGET IS CHOSEN BY CONCEPT PRIORITY, NOT BY DOCUMENT ORDER.
//     A filing can state the same period under more than one revenue concept — `Revenues`
//     alongside `RevenueFromContractWithCustomerExcludingAssessedTax` — and they need not agree
//     (one may include assessed tax). Taking whichever appeared LAST makes the target depend on
//     the order a filer happened to emit facts, so a correct split gets demoted to partition 0 for
//     one company and not another. `security-xbrl` resolves the same ambiguity by
//     `xbrl_concept.priority` and this must agree with it.
//
//     THE FIXTURE PUTS THE LOW-PRIORITY CONCEPT LAST, which is the only arrangement where
//     "highest priority" and "last seen" disagree — with it first, both rules give the same answer
//     and a mutation removing the priority test passes clean.
{
  // THE MEMBERS' OWN CONCEPT HAS NO UNDIMENSIONED FACT, which is the only arrangement where the
  // priority fallback decides anything — Alphabet's real shape. Two other concepts ARE stated
  // undimensioned, with the LOW-priority one last, so "highest priority" and "last seen" disagree.
  const xml = instance([
    { concept: 'Revenues', value: 100 },              // priority 120 below — the right answer
    { concept: REV, value: 60, dims: prod('x:AMember') },
    { concept: REV, value: 40, dims: prod('x:BMember') },
    { concept: 'SalesRevenueNet', value: 137 },       // priority 70, stated LAST
  ])
  const out = segmentFactsFrom(xml, AXES, [
    { metricCode: 'revenue', concept: REV, priority: 100 },
    { metricCode: 'revenue', concept: 'Revenues', priority: 120 },
    { metricCode: 'revenue', concept: 'SalesRevenueNet', priority: 70 },
    { metricCode: 'operating_income', concept: 'OperatingIncomeLoss', priority: 100 },
  ])
  const members = out.filter((f) => f.memberCode.startsWith('x:'))
  check(members.length === 2 && members.every((f) => f.partitionId === 1),
    'with no same-concept total, the HIGHEST-PRIORITY one is used — not the last seen',
    JSON.stringify(members.map((f) => `${f.memberCode}=p${f.partitionId}`)))
}

// 12. A SPLIT NEED NOT SUM EXACTLY, BECAUSE SEGMENT REVENUE CARRIES A RECONCILING ITEM TOO.
//     Alphabet's REAL FY2025 numbers: Google Services 342,721,000,000 + Google Cloud
//     58,705,000,000 + All Other 1,537,000,000 = 402,963,000,000 against a consolidated
//     402,836,000,000 — 127,000,000 of hedging gains reported between the two. Under the exact
//     rule this file first shipped, the whole split is unplaceable and **Google Cloud disappears**,
//     which is the one comparison the feature exists to make.
//
//     THE FIXTURE MAKES THE TWO RULES DISAGREE by using the real figures: exact matching gives
//     three partition-0 members, the relative tolerance gives one partition of three.
{
  const xml = instance([
    { concept: REV, value: 402836000000 },
    { concept: REV, value: 342721000000, dims: { [BIZ]: 'goog:GoogleServicesMember' } },
    { concept: REV, value: 58705000000, dims: { [BIZ]: 'goog:GoogleCloudMember' } },
    { concept: REV, value: 1537000000, dims: { [BIZ]: 'goog:AllOtherSegmentsMember' } },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  check(out.length === 3 && out.every((f) => f.partitionId === 1),
    'a 0.03% reconciling item does not sink the split — Google Cloud stays visible',
    JSON.stringify(out.map((f) => `${f.memberCode.split(':')[1]}=p${f.partitionId}`)))
}

// 13. …BUT THE TOLERANCE MUST STILL REJECT A DOUBLE COUNT, which is the error it exists for. A
//     doubled split is 100% out and a subtotal beside its children ~70% — two orders of magnitude
//     above a real reconciling item, which is how one threshold can serve both.
{
  const xml = instance([
    { concept: REV, value: 100000000000 },
    { concept: REV, value: 60000000000, dims: prod('x:AMember') },
    { concept: REV, value: 40000000000, dims: prod('x:BMember') },
    // A subtotal 60% of the total: including it makes the sum 160% and it must be excluded.
    { concept: REV, value: 60000000000, dims: prod('x:SubtotalMember') },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  const p1 = out.filter((f) => f.partitionId === 1)
  check(p1.length === 2 && p1.reduce((a, f) => a + f.value, 0) === 100000000000,
    'a relative tolerance still rejects a subtotal counted beside its own children',
    `${p1.length} members`)
}

// 14. AN INSTANT INHERITS THE SPLIT, BECAUSE IT CAN NEVER EARN ONE.
//     Segment ASSETS never sum to consolidated assets — corporate assets and eliminations sit
//     outside the segments, exactly as unallocated cost does for segment profit. So no instant
//     bucket can reconcile on its own, and a rule that requires it leaves every balance-sheet
//     segmentation in partition 0 for ever, where nothing may aggregate it.
//
//     THE FIXTURE MAKES THE RULES DISAGREE: the assets deliberately sum to 900 against a
//     consolidated 1000 (100 of corporate assets), so a self-reconciling rule places none of them,
//     while inheriting from the revenue split on the same axis and date places both.
{
  const xml = instance([
    { concept: REV, value: 100 },
    { concept: REV, value: 60, dims: { [BIZ]: 'x:CloudMember' } },
    { concept: REV, value: 40, dims: { [BIZ]: 'x:RetailMember' } },
    { concept: 'Assets', value: 1000, instant: Q_END },
    { concept: 'Assets', value: 500, dims: { [BIZ]: 'x:CloudMember' }, instant: Q_END },
    { concept: 'Assets', value: 400, dims: { [BIZ]: 'x:RetailMember' }, instant: Q_END },
  ])
  const out = segmentFactsFrom(xml, AXES, [
    ...CONCEPTS,
    { metricCode: 'total_assets', concept: 'Assets', priority: 100 },
  ])
  const assets = out.filter((f) => f.metricCode === 'total_assets')
  check(assets.length === 2 && assets.every((f) => f.periodType === 'instant'),
    'a balance-sheet fact is stored as an INSTANT, not rejected and not mislabelled a quarter',
    JSON.stringify(assets.map((f) => f.periodType)))
  check(assets.every((f) => f.partitionId === 1),
    'segment assets inherit the split from revenue on the same axis and date, though they sum to 900 against 1000',
    JSON.stringify(assets.map((f) => f.partitionId)))
}

// 15. …BUT AN INSTANT WITH NO DURATION TO LEARN FROM STAYS UNPLACED. A balance-sheet comparative
//     sits at a date the income statement does not cover, and asserting a split there would be a
//     guess. Measured on Amazon's real 10-Q: 2025-06-30 is placed and the 2024-12-31 comparative
//     is not.
{
  const xml = instance([
    { concept: REV, value: 100 },
    { concept: REV, value: 60, dims: { [BIZ]: 'x:CloudMember' } },
    { concept: REV, value: 40, dims: { [BIZ]: 'x:RetailMember' } },
    { concept: 'Assets', value: 500, dims: { [BIZ]: 'x:CloudMember' }, instant: '2024-12-31' },
    { concept: 'Assets', value: 400, dims: { [BIZ]: 'x:RetailMember' }, instant: '2024-12-31' },
  ])
  const out = segmentFactsFrom(xml, AXES, [
    ...CONCEPTS,
    { metricCode: 'total_assets', concept: 'Assets', priority: 100 },
  ])
  const assets = out.filter((f) => f.metricCode === 'total_assets')
  check(assets.length === 2 && assets.every((f) => f.partitionId === 0),
    'an instant at a date with no duration bucket is stored but left unplaced',
    JSON.stringify(assets.map((f) => f.partitionId)))
}

// 16. A CROSS-TAB CELL RECONCILES TO ITS PARENT, NOT TO THE COMPANY.
//     Alphabet tags Search, YouTube, Network and Subscriptions with BOTH the product axis and
//     `StatementBusinessSegments = GoogleServices` — product lines listed inside a reportable
//     segment. Measured on the FY2025 10-K they sum to 342,721,000,000, which is Google Services
//     itself, while the company reported 402,836,000,000. Reconciling them against the company
//     places none of them, and **YouTube's revenue was simply absent from the database** until
//     these facts were kept.
//
//     THE FIXTURE USES THE REAL FIGURES, including `GoogleAdvertising` — a subtotal of the first
//     three that must land in partition 0 exactly as `ProductMember` does one level up.
{
  const GS = { [BIZ]: 'goog:GoogleServicesMember' }
  const xml = instance([
    { concept: REV, value: 402836000000 },
    { concept: REV, value: 342721000000, dims: GS },
    { concept: REV, value: 58705000000, dims: { [BIZ]: 'goog:GoogleCloudMember' } },
    { concept: REV, value: 1537000000, dims: { [BIZ]: 'goog:AllOtherSegmentsMember' } },
    { concept: REV, value: 224532000000, dims: { ...GS, [PROD]: 'goog:GoogleSearchOtherMember' } },
    { concept: REV, value: 48030000000, dims: { ...GS, [PROD]: 'goog:SubscriptionsPlatformsAndDevicesRevenueMember' } },
    { concept: REV, value: 40367000000, dims: { ...GS, [PROD]: 'goog:YouTubeAdvertisingRevenueMember' } },
    { concept: REV, value: 29792000000, dims: { ...GS, [PROD]: 'goog:GoogleNetworkMember' } },
    { concept: REV, value: 294691000000, dims: { ...GS, [PROD]: 'goog:GoogleAdvertisingRevenueMember' } },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  const flat = out.filter((f) => f.parentMember === null)
  const nested = out.filter((f) => f.parentMember !== null)

  check(flat.length === 3 && flat.every((f) => f.partitionId === 1),
    'the three reportable segments are still a flat, reconciling split', `${flat.length}`)
  check(nested.length === 5, 'the cross-tab cells are KEPT, not rejected', `${nested.length}`)
  const p1 = nested.filter((f) => f.partitionId === 1)
  check(p1.length === 4 && p1.reduce((a, f) => a + f.value, 0) === 342721000000,
    'the nested split reconciles to its PARENT (342,721,000,000), not to the company',
    `${p1.length} members, ${p1.reduce((a, f) => a + f.value, 0)}`)
  check(nested.find((f) => f.memberCode.includes('GoogleAdvertising'))?.partitionId === 0,
    'GoogleAdvertising is a SUBTOTAL of Search+YouTube+Network and is excluded')
  check(p1.some((f) => f.memberCode.includes('YouTube')),
    'YouTube advertising revenue is now in the data at all')
  // The finer axis is the member and the coarser is the parent — never the reverse.
  check(nested.every((f) => f.axis === PROD && f.parentAxis === BIZ),
    'the FINER axis is enumerated and the coarser is the parent',
    JSON.stringify(nested.map((f) => `${f.axis.split(':')[1]}<${f.parentAxis?.split(':')[1]}`)[0]))
}

// ── The four rules the Korean spike forced out, each measured on a real DART filing ───────────

const CS = 'ifrs-full:ConsolidatedAndSeparateFinancialStatementsAxis'
const KR_AXES: SegmentAxisSpec[] = [
  ...AXES,
  { axis: 'ifrs-full:ProductsAndServicesAxis', kind: 'product', priority: 100, requiredMember: null },
  // Pinned: `SeparateMember` is parent-only accounts, a different set of numbers entirely.
  { axis: CS, kind: 'qualifier', priority: 0, requiredMember: 'ifrs-full:ConsolidatedMember' },
]
const IPROD = 'ifrs-full:ProductsAndServicesAxis'

// 17. A PINNED QUALIFIER REJECTS THE WRONG MEMBER. Korean filings tag EVERY fact consolidated or
//     separate — measured, 1,538 against 1,213 on one filing — so an open qualifier would store a
//     parent-only split beside a consolidated one, or reconcile one against the other.
{
  const xml = instance([
    { concept: REV, value: 100, dims: { [CS]: 'ifrs-full:ConsolidatedMember' } },
    { concept: REV, value: 60, dims: { [CS]: 'ifrs-full:ConsolidatedMember', [IPROD]: 'x:AMember' } },
    { concept: REV, value: 40, dims: { [CS]: 'ifrs-full:ConsolidatedMember', [IPROD]: 'x:BMember' } },
    // The SAME company's parent-only accounts, on a member the consolidated split does NOT have —
    // otherwise the duplicate rule discards it and the fixture cannot tell the two rules apart.
    { concept: REV, value: 30, dims: { [CS]: 'ifrs-full:SeparateMember', [IPROD]: 'x:ParentOnlyMember' } },
  ])
  const out = segmentFactsFrom(xml, KR_AXES, CONCEPTS)
  check(out.length === 2 && out.every((f) => f.partitionId === 1),
    'a pinned qualifier keeps only the consolidated split', `${out.length} facts`)
  check(!out.some((f) => f.value === 30), 'the parent-only (separate) figure is rejected outright')
}

// 18. "NO SEGMENT DIMENSIONS" IS THE TOTAL, NOT "NO DIMENSIONS AT ALL". Nothing in a Korean filing
//     is ever literally undimensioned, so the older test found no target, left every split
//     unplaced, and produced partition 0 for a whole jurisdiction while parsing cleanly.
{
  const xml = instance([
    { concept: REV, value: 100, dims: { [CS]: 'ifrs-full:ConsolidatedMember' } },
    { concept: REV, value: 60, dims: { [CS]: 'ifrs-full:ConsolidatedMember', [IPROD]: 'x:AMember' } },
    { concept: REV, value: 40, dims: { [CS]: 'ifrs-full:ConsolidatedMember', [IPROD]: 'x:BMember' } },
  ])
  const out = segmentFactsFrom(xml, KR_AXES, CONCEPTS)
  check(out.length === 2 && out.every((f) => f.partitionId === 1),
    'a fact carrying only qualifiers IS the consolidated total',
    JSON.stringify(out.map((f) => f.partitionId)))
}

// 19. THE TARGET IS THE MEMBERS' OWN CONCEPT FIRST. SK Gas states BOTH `Revenue` 7,095,902,060,317
//     and `RevenueFromContractsWithCustomers` 7,050,068,258,000 for FY2024, and tags its product
//     split with the second. Reconciling against the higher-priority `Revenue` leaves it 0.65%
//     short — just outside tolerance — and the split is lost. The fixture uses those real figures.
{
  const xml = instance([
    { concept: 'Revenues', value: 7095902060317 },
    { concept: REV, value: 7050068258000 },
    { concept: REV, value: 6517517172000, dims: prod('x:LpgMember') },
    { concept: REV, value: 347127843000, dims: prod('x:OtherMember') },
    { concept: REV, value: 185423243000, dims: prod('x:ElectricityMember') },
  ])
  // `Revenues` at a HIGHER priority than the members' own concept, which is the arrangement that
  // makes the two rules disagree.
  const out = segmentFactsFrom(xml, AXES, [
    ...CONCEPTS,
    { metricCode: 'revenue', concept: 'Revenues', priority: 120 },
  ])
  const p1 = out.filter((f) => f.partitionId === 1)
  check(p1.length === 3 && p1.reduce((a, f) => a + f.value, 0) === 7050068258000,
    'the split reconciles against ITS OWN concept, not the highest-priority one',
    `${p1.length} members`)
}

// 20. AMONG TIED SPLITS, THE ONE A HUMAN CAN READ WINS. Korean filers emit a generated
//     `udf_NOTE_<timestamp>Member` beside a named member for the same line and the same value —
//     two complete, equally valid splits. Partition 1 is what the app serves, and "LPG sales"
//     beats a timestamp. A PREFERENCE AMONG EQUALS: nothing is renamed or dropped.
{
  const xml = instance([
    { concept: REV, value: 100 },
    { concept: REV, value: 60, dims: prod('x:udf_NOTE_20231114182510391Member') },
    { concept: REV, value: 40, dims: prod('x:udf_NOTE_20231114182516257Member') },
    { concept: REV, value: 60, dims: prod('x:LpgSalesMember') },
    { concept: REV, value: 40, dims: prod('x:OtherSalesMember') },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS)
  const p1 = out.filter((f) => f.partitionId === 1)
  check(p1.length === 2 && p1.every((f) => !f.memberCode.includes('udf_')),
    'the readable split is partition 1 and the generated one is not',
    JSON.stringify(p1.map((f) => f.memberCode)))
  check(out.filter((f) => f.partitionId === 2).length === 2,
    'the generated split is still STORED, as a second partition')
}

// ── The size gate that unwedged the queue ────────────────────────────────────────────────────
//
// A 128 MB instance is ~256 MB as a UTF-16 string against a 256 MB worker, and the supervisor
// KILLS rather than throwing — so nothing is stamped and the same filing returns at the head of
// every run. `security-segments` parsed nothing for two days that way.
//
// The boundaries matter more than the middle: the largest document known to PARSE is Diageo's
// 20-F at 10.92 MB, and the one that killed the worker was AEP's 2015 10-K at 127.72 MB. A gate
// that rejected Diageo would lose exactly the foreign private issuers this feature exists to
// reach, so both ends are asserted rather than one.
{
  const MB = 1024 * 1024
  check(instanceIsTooLarge(127.72 * MB), 'AEP 2015 10-K (127.72 MB) is refused — it killed the worker')
  check(!instanceIsTooLarge(10.92 * MB), 'Diageo 20-F (10.92 MB) is ACCEPTED — the largest that parses')
  check(!instanceIsTooLarge(6.53 * MB), 'Cemex 20-F (6.53 MB) is accepted')
  check(!instanceIsTooLarge(0.74 * MB), 'AAPL 10-Q (0.74 MB) is accepted')
  // UNKNOWN IS NOT TOO LARGE. The HTML-index fallback carries no size, and `index.json` is the
  // listing that is unreliable for foreign private issuers — refusing on a null would silently
  // drop every filing that fell back, which is the path Diageo and Infosys take.
  check(!instanceIsTooLarge(null), 'an unknown size is NOT refused — the HTML fallback has no size')
}

// N. A TARGET BELONGS TO ITS OWN BUCKET. The group key is `axis|periodEnding`, so ONE group holds
//    every metric AND both period types that share a reporting date — and a fiscal-year end is
//    also Q4's end. `bestMap` (which members belong together) is deliberately shared across the
//    group; `reconciled_to` is not, because it is the consolidated figure for ONE metric over ONE
//    span. Stamping the winning bucket's target on the whole group handed a quarter the YEAR's
//    revenue.
//
//    Measured on the live data 2026-09-04, before the fix: 3,021 of 11,211 flat revenue splits did
//    not sum to the target stored beside them, and the damage tracked the shape — 47% of older
//    comparatives wrong against 24% of quarters, with the largest ratio bucket below 0.5, which is
//    a quarter's split against a year's total.
//
//    THE FIXTURE MAKES THE TWO RULES DISAGREE: the annual and quarterly splits share a period end
//    and have DIFFERENT totals (1000 vs 250), so a shared target is visibly the wrong one.
{
  const Y_START = '2024-07-01'
  const xml = instance([
    // The year, ending on the same date as the quarter.
    { concept: REV, value: 1000, start: Y_START, end: Q_END },
    { concept: REV, value: 600, start: Y_START, end: Q_END, dims: prod('x:AlphaMember') },
    { concept: REV, value: 400, start: Y_START, end: Q_END, dims: prod('x:BetaMember') },
    // The quarter, same axis, same members, same end date, a quarter of the size.
    { concept: REV, value: 250, dims: {} },
    { concept: REV, value: 150, dims: prod('x:AlphaMember') },
    { concept: REV, value: 100, dims: prod('x:BetaMember') },
  ])
  const out = segmentFactsFrom(xml, AXES, CONCEPTS).filter((f) => f.partitionId > 0)
  const annual = out.filter((f) => f.periodType === 'annual')
  const quarter = out.filter((f) => f.periodType === 'quarter')

  check(annual.length === 2 && quarter.length === 2,
    'both period types are placed in a partition',
    `annual ${annual.length}, quarter ${quarter.length}`)
  check(annual.every((f) => f.reconciledTo === 1000),
    "the annual split carries the YEAR's total",
    `got ${[...new Set(annual.map((f) => f.reconciledTo))].join(',')}`)
  check(quarter.every((f) => f.reconciledTo === 250),
    "the quarterly split carries the QUARTER's total, not the year's",
    `got ${[...new Set(quarter.map((f) => f.reconciledTo))].join(',')} (1000 was the bug)`)
  // And the property the whole thing exists for: a split sums to the figure stored beside it.
  for (const [label, rows] of [['annual', annual], ['quarter', quarter]] as const) {
    const sum = rows.reduce((a, f) => a + f.value, 0)
    check(rows.length > 0 && sum === rows[0].reconciledTo,
      `the ${label} split sums to its own target`,
      `${sum} vs ${rows[0]?.reconciledTo}`)
  }
}

// N. A TOTAL BELONGS TO A QUALIFIER CONTEXT, AND SEVERAL CAN LOOK UNDIMENSIONED AT ONCE.
//    A qualifier narrows a fact without sub-dividing it, so it is correctly ignored when deciding
//    WHETHER something is a segment fact — and must NOT be ignored when deciding what that fact
//    reconciles TO. Measured on Samsung's FY2024 filing, four Revenue facts carry no segment axis
//    and so all look like "the consolidated total":
//
//        300.87T  Consolidated                              <- geography sums to this
//        329.39T  Consolidated + OperatingSegments          <- the four divisions sum to this
//        -28.52T  Consolidated + MaterialReconcilingItems
//        209.05T  Separate
//
//    Collapsed into one slot the winner is arbitrary, and it picked the ELIMINATION: Samsung's
//    divisions were reconciled against -28.52T and left unplaced.
//
//    THE FIXTURE MAKES EVERY WRONG ANSWER AVAILABLE, at the real proportions. Two splits in ONE
//    filing must reach DIFFERENT targets — that is the property, and a rule that picks a single
//    "best" total for the period cannot satisfy it however it chooses.
{
  const CONS = 'ifrs-full:ConsolidatedAndSeparateFinancialStatementsAxis'
  const ITEMS = 'ifrs-full:SegmentConsolidationItemsAxis'
  const SEGS = 'ifrs-full:SegmentsAxis'
  const GEO = 'ifrs-full:GeographicalAreasAxis'
  const C = 'ifrs-full:ConsolidatedMember'
  const OPS = 'ifrs-full:OperatingSegmentsMember'
  const axes: SegmentAxisSpec[] = [
    ...AXES,
    { axis: CONS, kind: 'qualifier', priority: 0, requiredMember: C },
    { axis: ITEMS, kind: 'qualifier', priority: 0, requiredMember: null },
    { axis: SEGS, kind: 'business', priority: 90, requiredMember: null },
    { axis: GEO, kind: 'geography', priority: 80, requiredMember: null },
  ]
  const xml = instance([
    // The four facts that all look undimensioned, at Samsung's real FY2024 proportions (in bn).
    { concept: 'Revenue', value: 300870, dims: { [CONS]: C } },
    // DIMS IN THE OPPOSITE ORDER to the divisions below, deliberately: XBRL does not promise a
    // context lists its dimensions in any particular order, so the qualifier key has to be sorted.
    // Written in matching order, dropping the sort is undetectable.
    { concept: 'Revenue', value: 329390, dims: { [ITEMS]: OPS, [CONS]: C } },
    { concept: 'Revenue', value: -28520, dims: { [CONS]: C, [ITEMS]: 'ifrs-full:MaterialReconcilingItemsMember' } },
    { concept: 'Revenue', value: 209050, dims: { [CONS]: 'ifrs-full:SeparateMember' } },
    // The divisions — qualified by OperatingSegments, summing to 329,390.
    { concept: 'Revenue', value: 174890, dims: { [CONS]: C, [ITEMS]: OPS, [SEGS]: 'x:DxMember' } },
    { concept: 'Revenue', value: 111070, dims: { [CONS]: C, [ITEMS]: OPS, [SEGS]: 'x:DsMember' } },
    { concept: 'Revenue', value: 29160, dims: { [CONS]: C, [ITEMS]: OPS, [SEGS]: 'x:SdcMember' } },
    { concept: 'Revenue', value: 14270, dims: { [CONS]: C, [ITEMS]: OPS, [SEGS]: 'x:HarmanMember' } },
    // Geography — NOT operating-segment qualified, and sums to the consolidated 300,870 instead.
    { concept: 'Revenue', value: 46640, dims: { [CONS]: C, [GEO]: 'x:KoreaMember' } },
    { concept: 'Revenue', value: 133270, dims: { [CONS]: C, [GEO]: 'x:UsMember' } },
    { concept: 'Revenue', value: 120960, dims: { [CONS]: C, [GEO]: 'x:OtherMember' } },
  ])
  const out = segmentFactsFrom(xml, axes, CONCEPTS).filter((f) => f.partitionId > 0)
  const seg = out.filter((f) => f.axis === SEGS)
  const geo = out.filter((f) => f.axis === GEO)

  check(seg.length === 4, 'the four divisions are placed', `${seg.length}`)
  check(
    seg.every((f) => f.reconciledTo === 329390) &&
      seg.reduce((a, f) => a + f.value, 0) === 329390,
    '…and reconcile to the OPERATING-SEGMENTS subtotal, not the consolidated figure',
    `target ${seg[0]?.reconciledTo} (-28520 was the bug, 300870 the plausible wrong answer)`)

  check(geo.length === 3, 'geography is placed too', `${geo.length}`)
  check(
    geo.every((f) => f.reconciledTo === 300870) &&
      geo.reduce((a, f) => a + f.value, 0) === 300870,
    '…and reconciles to the CONSOLIDATED figure — a different target in the same filing',
    `target ${geo[0]?.reconciledTo}`)

  check(out.every((f) => f.reconciledTo !== 209050),
    'the parent-only (Separate) figure is never a target')
  check(out.every((f) => f.reconciledTo !== -28520),
    'nor is the reconciling-items elimination')

  // A SPLIT WHOSE MEMBERS DISAGREE ABOUT THEIR CONTEXT HAS NO CONTEXT OF ITS OWN, and must not
  // borrow one member's. These two sum to 329,390 exactly, so taking the first member's qualifier
  // would match the operating-segments total and place a split that was never disclosed together.
  const mixed = instance([
    { concept: 'Revenue', value: 300870, dims: { [CONS]: C } },
    { concept: 'Revenue', value: 329390, dims: { [CONS]: C, [ITEMS]: OPS } },
    { concept: 'Revenue', value: 200000, dims: { [CONS]: C, [ITEMS]: OPS, [SEGS]: 'x:AMember' } },
    { concept: 'Revenue', value: 129390, dims: { [CONS]: C, [SEGS]: 'x:BMember' } },
  ])
  const m = segmentFactsFrom(mixed, axes, CONCEPTS).filter((f) => f.partitionId > 0)
  check(m.every((f) => f.reconciledTo !== 329390),
    'a split whose members disagree about their qualifier borrows no total',
    `${m.length} placed, targets ${[...new Set(m.map((f) => f.reconciledTo))].join(',')}`)
}

// ── AN ELIMINATION COLUMN IS NOT A SEGMENT SPLIT ───────────────────────────────────────────────
//
// Found on the first live Korean parse. Hyundai Mobis tags its segment table's TWO COLUMNS on one
// axis: `OperatingSegments` (gross, 76,544,947) and `Elimination` (-15,426,820), which differ by
// exactly the consolidated 61,118,127. With the qualifier open, both are admitted as segment facts
// and the parser stored the ELIMINATION column — a served split summing to MINUS 15.4 trillion won
// for a company with 61 trillion of revenue. Every number was correct; the wrong column was chosen.
//
// The fix is one control-table row (`required_member = OperatingSegmentsMember`), so this asserts
// the PARSER honours it — and, more importantly, that the rule stays inert for a filer that does
// not use the axis at all, which is what makes it safe to pin globally.
{
  const CONS = 'ifrs-full:ConsolidatedAndSeparateFinancialStatementsAxis'
  const ITEMS = 'ifrs-full:SegmentConsolidationItemsAxis'
  const SEGS = 'ifrs-full:SegmentsAxis'
  const C = 'ifrs-full:ConsolidatedMember'
  const OPS = 'ifrs-full:OperatingSegmentsMember'
  const ELIM = 'ifrs-full:EliminationOfIntersegmentAmountsMember'
  // Production's shape after migration 173.
  const pinned: SegmentAxisSpec[] = [
    ...AXES,
    { axis: CONS, kind: 'qualifier', priority: 0, requiredMember: C },
    { axis: ITEMS, kind: 'qualifier', priority: 0, requiredMember: OPS },
    { axis: SEGS, kind: 'business', priority: 90, requiredMember: null },
  ]
  // Mobis's real numbers, in millions.
  const mobis: FixtureFact[] = [
    { concept: 'Revenue', value: 61118127, dims: { [CONS]: C } },
    { concept: 'Revenue', value: 76544947, dims: { [CONS]: C, [ITEMS]: OPS } },
    { concept: 'Revenue', value: -15426820, dims: { [CONS]: C, [ITEMS]: ELIM } },
    { concept: 'Revenue', value: 58702105, dims: { [CONS]: C, [ITEMS]: OPS, [SEGS]: 'x:AutoPartsMember' } },
    { concept: 'Revenue', value: 17842842, dims: { [CONS]: C, [ITEMS]: OPS, [SEGS]: 'x:AfterSalesMember' } },
    { concept: 'Revenue', value: -10901986, dims: { [CONS]: C, [ITEMS]: ELIM, [SEGS]: 'x:AutoPartsMember' } },
    { concept: 'Revenue', value: -4524834, dims: { [CONS]: C, [ITEMS]: ELIM, [SEGS]: 'x:AfterSalesMember' } },
    // THE ZERO MEMBER IS LOAD-BEARING, AND LEAVING IT OUT MADE THE FIXTURE MISS THE DEFECT.
    // Mobis reports an empty `CommonSegment` in BOTH columns. With it, the two qualifier groups
    // offer the same THREE member codes and the parser — which collapses per member code, the
    // qualifier not being part of a member's identity — picks one fact per member arbitrarily and
    // took the elimination. Without it the operating pair simply won and the open config looked
    // correct: the first version of this fixture asserted the defect was reachable and it was not.
    // Verified against the real instance both ways before this line was added.
    { concept: 'Revenue', value: 0, dims: { [CONS]: C, [ITEMS]: OPS, [SEGS]: 'x:CommonMember' } },
    { concept: 'Revenue', value: 0, dims: { [CONS]: C, [ITEMS]: ELIM, [SEGS]: 'x:CommonMember' } },
  ]
  const placed = segmentFactsFrom(instance(mobis), pinned, CONCEPTS).filter((f) => f.partitionId > 0)
  const total = placed.reduce((a, f) => a + f.value, 0)
  check(placed.length === 3 && total === 76544947,
    'the operating column is the split, and the elimination column is rejected',
    `${placed.length} members summing ${total.toLocaleString()} (want 3 summing 76,544,947)`)
  check(placed.every((f) => f.value >= 0),
    'so no served member carries a negative revenue',
    placed.map((f) => f.value).join(', '))

  // THIS FIXTURE DOES NOT REPRODUCE THE DEFECT, AND SAYING SO IS THE POINT.
  //
  // Swapping `requiredMember` back to null here yields the CORRECT split, so this file cannot
  // demonstrate the bug it was written for — three attempts (two members, then Mobis's zero-valued
  // `CommonSegment` in both columns, then the elimination facts in document order first) each
  // produced a different answer and none of them the production one. The real mechanism needs more
  // of the instance than a fixture reconstructs: the geography facts in both columns, the
  // major-customer and parent-only facts, and a partition search over all of them.
  //
  // It was verified against the REAL DOCUMENT instead — `segmentFactsFrom` run on Hyundai Mobis's
  // FY2025 instance (rcept 20260309001878) with the live `segment_axis` rows, both ways:
  //
  //   qualifier OPEN    SegmentsAxis  -15,426,820,000,000   Geography  71,697,297,000,000
  //   qualifier PINNED  SegmentsAxis   76,544,947,000,000   Geography  76,544,947,000,000
  //
  // — the open figures matching what production had stored, exactly, and the pinned ones matching
  // the filing's own target. Asserting a synthetic "the defect is reachable" that passes for a
  // reason unrelated to the real cause would be worse than recording this, so the assertion was
  // deleted rather than tuned until it went green.

  // INERT FOR A FILER THAT NEVER USES THE AXIS. `requiredMember` rejects only when the axis is
  // PRESENT with a different member, which is what makes pinning it safe for everyone else.
  const noQualifier: FixtureFact[] = [
    { concept: 'Revenue', value: 1000, dims: { [CONS]: C } },
    { concept: 'Revenue', value: 600, dims: { [CONS]: C, [SEGS]: 'x:OneMember' } },
    { concept: 'Revenue', value: 400, dims: { [CONS]: C, [SEGS]: 'x:TwoMember' } },
  ]
  const untouched = segmentFactsFrom(instance(noQualifier), pinned, CONCEPTS)
    .filter((f) => f.partitionId > 0)
  check(untouched.length === 2 && untouched.reduce((a, f) => a + f.value, 0) === 1000,
    'a filer that omits the qualifier axis is untouched by the pin',
    `${untouched.length} members summing ${untouched.reduce((a, f) => a + f.value, 0)}`)
}

// ── a residual alone is not a split (Chevron FY2025) ───────────────────────────────────────────
//
// EVERY CANDIDATE RULE MUST DISAGREE ON THIS FIXTURE, because three plausible repairs each look
// right in isolation and each destroys correct data on Chevron's own filing:
//
//   drop residuals outright      -> breaks `depreciation`,  which needs AllOther to reconcile
//   require the inherited split
//     to be COMPLETE             -> breaks `total_assets`,  which reconciles WITHOUT the residual
//   require it to RECONCILE      -> breaks `operating_income`, which never sums (ASC 280 / IFRS 8)
//   the shipped rule             -> drops only `revenue`, whose sole member is the residual
//
// `bestMap` is learned from `depreciation` (3 members placed, the most of any bucket) and applied
// to all four, which is what puts the residual alone into revenue's bucket in the first place.
{
  const SEG = 'us-gaap:StatementBusinessSegmentsAxis'
  const UP = 'cvx:UpstreamSegmentMember'
  const DOWN = 'cvx:DownstreamSegmentMember'
  const OTHER = 'us-gaap:AllOtherSegmentsMember'
  const Y = { start: '2025-01-01', end: '2025-12-31' }
  const AT = { instant: '2025-12-31' }
  const ROLES = [{ memberCode: OTHER, class: 'residual' }]
  const CVX_CONCEPTS: SegmentConceptSpec[] = [
    ...CONCEPTS,
    { metricCode: 'depreciation', concept: 'DepreciationDepletionAndAmortization', priority: 100 },
    { metricCode: 'total_assets', concept: 'Assets', priority: 100 },
  ]
  const D = 'DepreciationDepletionAndAmortization'
  const R = 'RevenueFromContractWithCustomerExcludingAssessedTax'
  const chevron: FixtureFact[] = [
    // depreciation — three members, reconciles exactly. This is where `bestMap` comes from.
    { concept: D, value: 20132, ...Y },
    { concept: D, value: 18445, dims: { [SEG]: UP }, ...Y },
    { concept: D, value: 1404, dims: { [SEG]: DOWN }, ...Y },
    { concept: D, value: 283, dims: { [SEG]: OTHER }, ...Y },
    // revenue — the residual and nothing else, against a consolidated 231,370. THE DEFECT.
    { concept: R, value: 231370, ...Y },
    { concept: R, value: 581, dims: { [SEG]: OTHER }, ...Y },
    // total_assets — reconciles exactly with NO residual, so it is incomplete against `bestMap`.
    { concept: 'Assets', value: 312218, ...AT },
    { concept: 'Assets', value: 256975, dims: { [SEG]: UP }, ...AT },
    { concept: 'Assets', value: 55243, dims: { [SEG]: DOWN }, ...AT },
    // operating_income — real members that deliberately do NOT sum to the consolidated figure.
    { concept: 'OperatingIncomeLoss', value: 120, ...Y },
    { concept: 'OperatingIncomeLoss', value: 100, dims: { [SEG]: UP }, ...Y },
    { concept: 'OperatingIncomeLoss', value: 50, dims: { [SEG]: DOWN }, ...Y },
  ]
  const served = segmentFactsFrom(instance(chevron), AXES, CVX_CONCEPTS, ROLES)
    .filter((f) => f.partitionId > 0)
  const of = (m: string) => served.filter((f) => f.metricCode === m)
  const sum = (m: string) => of(m).reduce((a, f) => a + f.value, 0)

  check(of('revenue').length === 0,
    'a split whose only member is a residual is not served',
    `${of('revenue').length} member(s) summing ${sum('revenue')} against a consolidated 231370`)
  check(of('depreciation').length === 3 && sum('depreciation') === 20132,
    'a residual IS served beside real segments, and is needed to reconcile',
    `${of('depreciation').length} members summing ${sum('depreciation')}`)
  check(of('total_assets').length === 2 && sum('total_assets') === 312218,
    'a bucket missing the residual is still served — completeness is not the rule',
    `${of('total_assets').length} members summing ${sum('total_assets')}`)
  check(of('operating_income').length === 2 && sum('operating_income') === 150,
    'segment profit is served though it never reconciles — reconciliation is not the rule',
    `${of('operating_income').length} members summing ${sum('operating_income')} against 120`)
}

// ── a segment column's total, derived from the other columns (Southern Copper FY2018) ──────────
//
// Segment revenue INCLUDES intersegment sales that consolidation removes, so a split legitimately
// exceeds the consolidated figure by the elimination — an OVER-count, which this pipeline treats as
// a defect. Southern Copper states consolidated 7,096,700,000 and an elimination of -79,300,000 and
// no segment-column total at all, so the honest target is their difference.
//
// THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE, and both halves are load-bearing:
//   segments carry NO qualifier axis  -> a derivation keyed on the candidates' own qualifier is
//                                        never reached, and the target falls back to consolidated
//   one elimination, TWO member names -> summing every member double-counts it (7,200 not 7,100),
//                                        so only the distinct-VALUE sum matches
// The control asserts the opposite direction: a split that already reconciles to the consolidated
// figure must NOT be moved onto a derived target just because one is now offered.
{
  const CONS = 'srt:ConsolidationItemsAxis'
  const SEG = 'us-gaap:StatementBusinessSegmentsAxis'
  const R = 'RevenueFromContractWithCustomerExcludingAssessedTax'
  const Y = { start: '2025-01-01', end: '2025-12-31' }

  const scco: FixtureFact[] = [
    { concept: R, value: 7000, ...Y },                                        // consolidated
    // ONE elimination, stated under TWO member names — once in the segment table, once in the
    // geography table. Summing both derives 7,200 and matches nothing.
    { concept: R, value: -100, dims: { [CONS]: 'us-gaap:IntersegmentEliminationMember' }, ...Y },
    { concept: R, value: -100, dims: { [CONS]: 'x:CorporateAndEliminationsMember' }, ...Y },
    // The segments themselves, with NO qualifier axis, summing to 7,100 = 7,000 - (-100).
    { concept: R, value: 4000, dims: { [SEG]: 'x:NorthMember' }, ...Y },
    { concept: R, value: 3100, dims: { [SEG]: 'x:SouthMember' }, ...Y },
  ]
  const out = segmentFactsFrom(instance(scco), AXES, CONCEPTS).filter((f) => f.partitionId > 0)
  const sum = out.reduce((a, f) => a + f.value, 0)
  check(out.length === 2 && sum === 7100,
    'a split including intersegment sales is served whole', `${out.length} members summing ${sum}`)
  check(out[0]?.reconciledTo === 7100,
    'its target is the consolidated figure less the elimination, counted ONCE',
    `target ${out[0]?.reconciledTo} (7000 would be the consolidated figure, 7200 double-counts)`)

  // THE CONTROL. An offered candidate must never move a split that already reconciles.
  const plain: FixtureFact[] = [
    { concept: R, value: 1000, ...Y },
    { concept: R, value: -50, dims: { [CONS]: 'us-gaap:IntersegmentEliminationMember' }, ...Y },
    { concept: R, value: 600, dims: { [SEG]: 'x:NorthMember' }, ...Y },
    { concept: R, value: 400, dims: { [SEG]: 'x:SouthMember' }, ...Y },
  ]
  const kept = segmentFactsFrom(instance(plain), AXES, CONCEPTS).filter((f) => f.partitionId > 0)
  check(kept.length === 2 && kept[0]?.reconciledTo === 1000,
    'a split that already reconciles keeps the consolidated figure as its target',
    `${kept.length} members, target ${kept[0]?.reconciledTo}`)
}

console.log(failures === 0 ? '\nALL SEGMENT CHECKS PASSED' : `\n${failures} SEGMENT CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
