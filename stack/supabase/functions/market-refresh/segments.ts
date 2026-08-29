/**
 * Revenue and profit per business line, from a filing's own XBRL instance.
 *
 * WHY NOT THE ENDPOINT WE ALREADY CALL. `security-xbrl` reads `data.sec.gov`'s companyfacts API,
 * and **that API strips dimensions**: measured 2026-08-28, `companyconcept` for AAPL revenue
 * returns keys `accn,end,filed,form,fp,frame,fy,start,val` and exactly ONE value per period
 * ($416.16bn for FY2025). There is no iPhone in it, and no amount of paging will produce one.
 *
 * WHY NOT THE BULK DATASETS. SEC's quarterly "Financial Statement Data Sets" DO carry a `segments`
 * column (verified back to 2015q1, and this module's expected values were first proven against
 * them) — but they are 122 MB zipped and `num.txt` alone is **542 MB**, against a 90 s / 256 MB
 * worker. Processing them needs a second scheduler or a second executor, and this pipeline
 * deliberately has one of each.
 *
 * WHAT THIS USES INSTEAD. Every filing publishes its XBRL instance as a separate file, and it is
 * small enough to read in a worker: AAPL's 10-Q is **778 KB / 165 contexts**, AMZN's 10-K 1.98 MB,
 * and the largest measured — Diageo's 20-F, where a foreign private issuer tags its whole annual
 * report inline — is **10.92 MB**, which still downloads in 0.37 s and parses in 40 ms at 15 MB of
 * heap. The pre-inline-XBRL era is the same shape with a different name (AAPL's 2015 10-K is
 * `aapl-20150926.xml`, no `_htm` suffix). Contexts carry the dimensions the API drops, so one
 * ordinary backlog resource over filings we already hold in `market.security_filing` reads the
 * whole universe.
 *
 * FOREIGN FILERS WORK IDENTICALLY, AND THE AXIS NAME IS THE ONLY DIFFERENCE. Diageo's 20-F parses
 * to Spirits/Beer/Ready-to-Drink under `ifrs-full:ProductsAndServicesAxis` where Apple uses
 * `srt:ProductOrServiceAxis` — which is why the allowlist is `market.segment_axis`, a control
 * table, and not a literal in here. Adding a taxonomy is rows.
 */

/** One axis worth keeping, from `market.segment_axis`. */
export interface SegmentAxisSpec {
  axis: string
  /**
   * `product` / `business` / `geography` segment the company. `qualifier` does NOT — it narrows a
   * fact without sub-dividing it (`srt:ConsolidationItemsAxis = OperatingSegmentsMember`), and
   * Alphabet tags every segment figure with one. A fact carrying a qualifier alongside its segment
   * axis is still a segment fact; a fact carrying an unknown second axis is not.
   */
  kind: 'product' | 'business' | 'geography' | 'qualifier'
  priority: number
}

/** Which concepts express which metric, from `market.xbrl_concept` (reused, not duplicated). */
export interface SegmentConceptSpec {
  metricCode: string
  concept: string
  priority: number
}

export interface SegmentFact {
  axis: string
  memberCode: string
  metricCode: string
  periodType: 'annual' | 'quarter' | 'instant'
  periodStart: string
  periodEnding: string
  value: number
  currency: string | null
  /**
   * WHEN A FILING NESTS ONE SEGMENTATION INSIDE ANOTHER, the coarser member this fact sits under.
   *
   * Alphabet tags Search, YouTube, Network and Subscriptions with `ProductOrServiceAxis` **and**
   * `StatementBusinessSegmentsAxis = GoogleServices` at the same time — a cell in a cross-tab, not
   * a member of a flat split. Measured on the FY2025 10-K, those four sum to **342,721,000,000**,
   * which is exactly Google Services' own revenue, and `GoogleAdvertising` (294,691,000,000) is a
   * subtotal of the first three.
   *
   * Null for an ordinary single-axis fact. When set, this fact's siblings sum to the PARENT
   * member's value rather than to the company's consolidated figure — so a reader must never mix
   * the two levels, exactly as it must never mix partitions.
   */
  parentAxis: string | null
  parentMember: string | null
  /**
   * Which disclosed split this member belongs to. 1..n are partitions that reconcile to the
   * filing's own consolidated figure; **0 means the member is a subtotal or could not be placed**,
   * and nothing may aggregate it. See `assignPartitions`.
   */
  partitionId: number
}

interface Ctx {
  dims: Map<string, string>
  start: string | null
  end: string | null
  instant: string | null
}

/** Strip any namespace prefix: `xbrli:context` and `context` are the same element. */
const local = (tag: string): string => {
  const i = tag.indexOf(':')
  return i === -1 ? tag : tag.slice(i + 1)
}

/**
 * `unitRef` -> ISO currency, or null for anything that is not money.
 *
 * A filer reports in ITS OWN currency and the unit key is where that arrives — Diageo in GBP,
 * Novo Nordisk in DKK. Guessing USD would relabel kroner as dollars, which is the failure this
 * schema has already had once with `security_statement.currency`. A `divide` unit (a ratio) and
 * `shares` are deliberately not money and return null, so a per-share figure can never be stored
 * as an amount.
 */
export function parseUnits(xml: string): Map<string, string | null> {
  const out = new Map<string, string | null>()
  const re = /<[\w-]*:?unit\b[^>]*\bid="([^"]+)"[^>]*>([\s\S]*?)<\/[\w-]*:?unit>/g
  for (let m = re.exec(xml); m !== null; m = re.exec(xml)) {
    const [, id, body] = m
    if (/<[\w-]*:?divide\b/.test(body)) { out.set(id, null); continue }
    const measure = body.match(/<[\w-]*:?measure\b[^>]*>([\s\S]*?)<\/[\w-]*:?measure>/)?.[1]?.trim()
    const iso = measure?.match(/^iso4217:([A-Z]{3})$/)?.[1]
    out.set(id, iso ?? null)
  }
  return out
}

/**
 * `contextRef` -> its dimensions and period.
 *
 * The dimensions live in `<segment>` (and occasionally `<scenario>`) as `explicitMember` elements;
 * a `typedMember` is deliberately ignored, because a typed dimension's value is an arbitrary XML
 * fragment rather than a member this schema could ever map to a concept.
 */
export function parseContexts(xml: string): Map<string, Ctx> {
  const out = new Map<string, Ctx>()
  const re = /<[\w-]*:?context\b[^>]*\bid="([^"]+)"[^>]*>([\s\S]*?)<\/[\w-]*:?context>/g
  for (let m = re.exec(xml); m !== null; m = re.exec(xml)) {
    const [, id, body] = m
    const dims = new Map<string, string>()
    const dre = /<[\w-]*:?explicitMember\b[^>]*\bdimension="([^"]+)"[^>]*>([\s\S]*?)<\/[\w-]*:?explicitMember>/g
    for (let d = dre.exec(body); d !== null; d = dre.exec(body)) dims.set(d[1].trim(), d[2].trim())
    out.set(id, {
      dims,
      start: body.match(/<[\w-]*:?startDate\b[^>]*>([\s\S]*?)<\//)?.[1]?.trim() ?? null,
      end: body.match(/<[\w-]*:?endDate\b[^>]*>([\s\S]*?)<\//)?.[1]?.trim() ?? null,
      instant: body.match(/<[\w-]*:?instant\b[^>]*>([\s\S]*?)<\//)?.[1]?.trim() ?? null,
    })
  }
  return out
}

/**
 * A duration in days -> the period type this schema stores.
 *
 * Deliberately a WINDOW rather than an equality: a 52/53-week fiscal calendar makes a "quarter"
 * anything from 84 to 98 days and a "year" 358 to 372, and Apple's own Q3 above is 91 days while
 * its FY is 371. Anything else (a nine-month year-to-date figure, which 10-Qs are full of) is
 * REJECTED rather than rounded to the nearest — storing a 9-month revenue as a quarter is the
 * 4x error `security_statement`'s primary key already exists to prevent.
 */
export function periodTypeFor(start: string, end: string): 'annual' | 'quarter' | null {
  const days = (Date.parse(end) - Date.parse(start)) / 86_400_000
  if (!Number.isFinite(days)) return null
  if (days >= 84 && days <= 98) return 'quarter'
  if (days >= 358 && days <= 372) return 'annual'
  return null
}

interface RawFact {
  concept: string
  metricCode: string
  ctxRef: string
  unitRef: string | null
  value: number
}

/**
 * Every numeric fact whose concept is one this schema knows a metric for.
 *
 * A fact with no value, or a non-numeric one, is DROPPED rather than coerced. That is what handles
 * `xsi:nil` — which asserts the ABSENCE of a value, and would put a fabricated zero next to real
 * revenue if read as 0. An explicit `xsi:nil` test was written here first and then removed: it
 * could never fire, because a nil element is empty and the emptiness check had already rejected it.
 * A guard that cannot fail reads as protection without being it.
 */
export function parseFacts(xml: string, concepts: SegmentConceptSpec[]): RawFact[] {
  const byConcept = new Map<string, SegmentConceptSpec>()
  for (const c of concepts) {
    const prev = byConcept.get(c.concept)
    if (!prev || c.priority > prev.priority) byConcept.set(c.concept, c)
  }
  const out: RawFact[] = []
  const re = /<([\w-]+:[\w.-]+)\b([^>]*)>([^<]*)<\/\1>/g
  for (let m = re.exec(xml); m !== null; m = re.exec(xml)) {
    const [, tag, attrs, text] = m
    const spec = byConcept.get(local(tag))
    if (!spec) continue
    const ctxRef = attrs.match(/\bcontextRef="([^"]+)"/)?.[1]
    if (!ctxRef) continue
    const raw = text.trim()
    if (raw === '' || !/^-?\d+(\.\d+)?$/.test(raw)) continue
    out.push({
      concept: local(tag),
      metricCode: spec.metricCode,
      ctxRef,
      unitRef: attrs.match(/\bunitRef="([^"]+)"/)?.[1] ?? null,
      value: Number(raw),
    })
  }
  return out
}

/**
 * WHICH MEMBERS FORM ONE DISCLOSED SPLIT — the single hardest thing in this module, and the reason
 * a naive reader of this data is wrong by an integer multiple.
 *
 * MEASURED, Amazon H1-2025: the `ProductOrService` axis carries a SEVEN-member split (Online
 * Stores, AWS, Advertising, Physical Stores, Subscription, Third-Party Seller, Other) summing to
 * 323,369 **and** a TWO-member split (Product, Service) summing to 323,369, while
 * `BusinessSegments` carries a THREE-member split summing to 323,369. AWS appears twice with an
 * identical value, under `ProductOrService=AmazonWebServices` and
 * `BusinessSegments=AmazonWebServicesSegment`. Summing an axis therefore DOUBLES the company's
 * revenue and summing every member TRIPLES it — silently, in the right units, with no error.
 *
 * Apple shows the third shape: its product members decompose `ProductMember` only, so the split
 * that reconciles is {iPhone, iPad, Mac, Wearables, **Service**} — a mix of company extensions and
 * a standard member. Any rule that prefers extension members over standard ones drops Services and
 * is wrong; any rule that takes "the deepest members" is wrong for the same reason.
 *
 * THE RULE. The filing states its own consolidated figure in an UNDIMENSIONED context for the same
 * concept and period, so the answer is available locally: a partition is a maximal set of members
 * whose values sum to that figure. Partitions are numbered from 1 in the order found; anything
 * left over is a subtotal and gets **partition 0**, which nothing may aggregate.
 *
 * Enumeration is bounded at `MAX_MEMBERS` — beyond that the subset search is abandoned and every
 * member gets partition 0. That is the honest failure: a fact this function cannot place is still
 * STORED (an upsert cannot retract, and a coarse split may be all a filer gives), it is simply not
 * claimed to reconcile.
 */
const MAX_MEMBERS = 18
/**
 * How close a split must come to the consolidated figure — RELATIVE, and that is a correction.
 *
 * The first version demanded agreement to one currency unit, which is what a "split of a total"
 * sounds like it should mean. Measured against Alphabet's FY2025 10-K, it is wrong: Google Services
 * 342,721,000,000 + Google Cloud 58,705,000,000 + All Other 1,537,000,000 = **402,963,000,000**
 * against a consolidated **402,836,000,000** — a **127,000,000 reconciling item** (hedging gains
 * Alphabet reports between segment and consolidated revenue). Under an exact rule the whole split
 * is unplaceable and **Google Cloud disappears**, which is the single comparison this feature
 * exists to make possible.
 *
 * So segment REVENUE can carry a reconciling item too, not only segment profit. The tolerance is
 * sized for the error actually being guarded against, which is an INTEGER MULTIPLE: a doubled
 * split is 100% out and a subtotal counted beside its own children is ~70% out (Apple's
 * `ProductMember` on top of iPhone/iPad/Mac/Wearables), while a genuine reconciling item is
 * fractions of a percent — Alphabet's is 0.032%. Half a percent separates them by two orders of
 * magnitude.
 */
const TOLERANCE_FRACTION = 0.005
/** A floor, so a tiny total is not matched by anything. */
const TOLERANCE_FLOOR = 1
const toleranceFor = (total: number) =>
  Math.max(TOLERANCE_FLOOR, Math.abs(total) * TOLERANCE_FRACTION)

export function assignPartitions(
  members: { memberCode: string; value: number }[],
  total: number,
): Map<string, number> {
  const out = new Map<string, number>()
  for (const m of members) out.set(m.memberCode, 0)
  if (members.length === 0 || !Number.isFinite(total)) return out

  // The common case by far: the filing gives one clean split and no subtotals.
  const tol = toleranceFor(total)
  const sumAll = members.reduce((a, m) => a + m.value, 0)
  if (Math.abs(sumAll - total) <= tol) {
    for (const m of members) out.set(m.memberCode, 1)
    return out
  }
  if (members.length > MAX_MEMBERS) return out

  let remaining = members.slice()
  let partition = 0
  while (remaining.length > 0) {
    const best = maxSubsetSummingTo(remaining, total)
    if (best === null) break
    partition++
    for (const i of best) out.set(remaining[i].memberCode, partition)
    const chosen = new Set(best)
    remaining = remaining.filter((_, i) => !chosen.has(i))
  }
  return out
}

/** Indices of the largest subset summing to `target`, or null. Bounded by `MAX_MEMBERS` above. */
function maxSubsetSummingTo(
  members: { memberCode: string; value: number }[],
  target: number,
): number[] | null {
  const n = members.length
  let best: number[] | null = null
  for (let mask = 1; mask < 1 << n; mask++) {
    let sum = 0
    let count = 0
    for (let i = 0; i < n; i++) {
      if (mask & (1 << i)) { sum += members[i].value; count++ }
    }
    if (Math.abs(sum - target) > toleranceFor(target)) continue
    if (best === null || count > best.length) {
      const idx: number[] = []
      for (let i = 0; i < n; i++) if (mask & (1 << i)) idx.push(i)
      best = idx
    }
  }
  return best
}

/**
 * The whole pipeline for one filing: instance XML -> segment facts, partitioned.
 *
 * A fact is kept only when, after removing `qualifier` axes, EXACTLY ONE allowlisted segment axis
 * remains and no unknown axis does. That last clause is what keeps
 * `FairValueByFairValueHierarchyLevelAxis`, `StatementEquityComponentsAxis` and
 * `ConcentrationRiskByBenchmarkAxis` out — Apple's instance carries 206 dimensioned facts of which
 * only 44 are segmentations.
 */
export function segmentFactsFrom(
  xml: string,
  axes: SegmentAxisSpec[],
  concepts: SegmentConceptSpec[],
): SegmentFact[] {
  const units = parseUnits(xml)
  const contexts = parseContexts(xml)
  const facts = parseFacts(xml, concepts)

  const kindOf = new Map(axes.map((a) => [a.axis, a.kind]))
  const priorityOfAxis = new Map(axes.map((a) => [a.axis, a.priority]))
  const priorityOf = new Map<string, number>()
  for (const c of concepts) {
    const prev = priorityOf.get(c.concept)
    if (prev === undefined || c.priority > prev) priorityOf.set(c.concept, c.priority)
  }
  const isSegment = (a: string) => {
    const k = kindOf.get(a)
    return k !== undefined && k !== 'qualifier'
  }

  /**
   * key -> the undimensioned figure the filing states for it, and the PRIORITY of the concept it
   * came from.
   *
   * THE PRIORITY IS LOAD-BEARING, NOT TIDINESS. A filing can tag the same period under more than
   * one revenue concept — `Revenues` alongside `RevenueFromContractWithCustomerExcludingAssessedTax`
   * is common, and they need not be equal (one may include assessed tax). Taking whichever appears
   * LAST in document order makes the reconciliation target depend on the order a filer happened to
   * emit its facts, so an otherwise-correct split would be judged not to reconcile and demoted to
   * partition 0 — silently, and differently for different filers. `security-xbrl` resolves the
   * same ambiguity by `xbrl_concept.priority`, and this must agree with it or the guard in
   * market-verify compares a split against a total nothing else uses.
   */
  const totals = new Map<string, { value: number; priority: number }>()
  const key = (metric: string, pt: string, start: string, end: string) =>
    `${metric}|${pt}|${start}|${end}`

  interface Candidate {
    axis: string
    memberCode: string
    parentAxis: string | null
    parentMember: string | null
    metricCode: string
    periodType: 'annual' | 'quarter' | 'instant'
    periodStart: string
    periodEnding: string
    value: number
    currency: string | null
  }
  const candidates: Candidate[] = []

  for (const f of facts) {
    const ctx = contexts.get(f.ctxRef)
    if (!ctx) continue
    // AN INSTANT IS A STOCK, NOT A FLOW, and both belong here. Revenue and capex are measured over
    // a period; assets are measured AT a date. Rejecting instants — which this parser did until
    // segment assets were wanted — silently drops every balance-sheet segmentation.
    const isInstant = ctx.instant !== null
    const start = isInstant ? ctx.instant! : ctx.start
    const end = isInstant ? ctx.instant! : ctx.end
    if (!start || !end) continue
    const pt: 'annual' | 'quarter' | 'instant' | null =
      isInstant ? 'instant' : periodTypeFor(start, end)
    if (pt === null) continue
    const currency = f.unitRef === null ? null : units.get(f.unitRef) ?? null
    if (currency === null) continue

    const dims = [...ctx.dims.entries()]
    const segs = dims.filter(([a]) => isSegment(a))
    const unknown = dims.filter(([a]) => !kindOf.has(a))

    if (dims.length === 0) {
      // The filing's own consolidated figure — the target every partition must reconcile to.
      const k = key(f.metricCode, pt, start, end)
      const priority = priorityOf.get(f.concept) ?? 0
      const held = totals.get(k)
      if (held === undefined || priority > held.priority) totals.set(k, { value: f.value, priority })
      continue
    }
    if (unknown.length > 0 || segs.length < 1 || segs.length > 2) continue

    // TWO SEGMENT AXES IS A CROSS-TAB CELL, NOT A FLAT MEMBER. The FINER axis is the one being
    // enumerated and the coarser is the parent it sits inside — Alphabet lists product lines
    // WITHIN Google Services, never the reverse. `segment_axis.priority` already declares which is
    // finer (product 100, business 90), so the ordering is data rather than a guess about names.
    const ordered = segs.length === 2
      ? [...segs].sort((a, b) =>
        (priorityOfAxis.get(b[0]) ?? 0) - (priorityOfAxis.get(a[0]) ?? 0) ||
        a[0].localeCompare(b[0]))
      : segs
    candidates.push({
      axis: ordered[0][0],
      memberCode: ordered[0][1],
      parentAxis: ordered[1]?.[0] ?? null,
      parentMember: ordered[1]?.[1] ?? null,
      metricCode: f.metricCode,
      periodType: pt,
      periodStart: start,
      periodEnding: end,
      value: f.value,
      currency,
    })
  }

  // A filing can state the same fact twice with different `decimals`. Keep one, deterministically,
  // or the member would be counted twice inside its own partition.
  const seen = new Set<string>()
  const unique = candidates.filter((c) => {
    const k = `${c.axis}|${c.memberCode}|${c.parentMember ?? ''}|${c.metricCode}|` +
      `${c.periodType}|${c.periodEnding}`
    if (seen.has(k)) return false
    seen.add(k)
    return true
  })

  // THE SPLIT IS A PROPERTY OF (AXIS, PERIOD END), AND IS APPLIED MORE WIDELY THAN IT IS LEARNED.
  //
  // Which members a filing disclosed together is one fact per axis per reporting date. It is
  // LEARNED from whichever (metric, period type) bucket reconciles — in practice annual revenue —
  // and APPLIED to every bucket sharing that axis and date, because they are the same members
  // listed in the same table.
  //
  // That is what makes segment ASSETS usable at all. Assets are an instant, and segment assets
  // never sum to consolidated assets — corporate and eliminations sit outside the segments, exactly
  // as unallocated cost does for profit — so no instant bucket can ever reconcile on its own and
  // every one of them would be partition 0 for ever.
  const groups = new Map<string, Candidate[]>()
  for (const c of unique) {
    // A cross-tab cell is partitioned WITHIN its parent member, never beside the flat members of
    // its own axis: Alphabet's Search sits inside Google Services and sums to that, not to the
    // company. Mixing the two levels is the same double count as mixing two axes.
    const g = c.parentMember === null
      ? `${c.axis}|${c.periodEnding}`
      : `${c.parentAxis}=${c.parentMember}|${c.axis}|${c.periodEnding}`
    const arr = groups.get(g)
    if (arr) arr.push(c)
    else groups.set(g, [c])
  }

  // What each flat member is worth, so a cross-tab group knows the total it must reconcile to.
  const flatValue = new Map<string, number>()
  for (const c of unique) {
    if (c.parentMember !== null) continue
    flatValue.set(
      `${c.axis}|${c.memberCode}|${c.metricCode}|${c.periodType}|${c.periodStart}|${c.periodEnding}`,
      c.value,
    )
  }

  const out: SegmentFact[] = []
  for (const [, group] of groups) {
    // THE SPLIT IS LEARNED FROM WHICHEVER METRIC RECONCILES, THEN APPLIED TO THE REST.
    //
    // Segment PROFIT does not sum to consolidated profit and never will: ASC 280 (and IFRS 8)
    // require a reconciliation, and shared costs are deliberately left unallocated. Measured on
    // Apple's Q3-2025 10-Q, segment operating income sums to 38,949m against a consolidated
    // ~28,202m — an 11bn gap that is the disclosure working as intended, not a defect.
    //
    // So a rule that demands every metric reconcile marks all profit unaggregatable, which is
    // exactly the number this feature exists to serve. The split is a property of the AXIS AND THE
    // FILING — which members were disclosed together — so it is inferred from the metric that does
    // reconcile (revenue) and applied to every metric on the same axis and period.
    // Learning is still per (metric, period type, span): a quarter must never be reconciled
    // against a year, and two metrics have different totals.
    const byBucket = new Map<string, Candidate[]>()
    for (const c of group) {
      const b = `${c.metricCode}|${c.periodType}|${c.periodStart}|${c.periodEnding}`
      const arr = byBucket.get(b)
      if (arr) arr.push(c)
      else byBucket.set(b, [c])
    }

    let bestMap: Map<string, number> | null = null
    let bestPlaced = 0
    for (const [, cands] of byBucket) {
      const g0 = cands[0]
      // THE TARGET IS THE PARENT'S OWN VALUE FOR A CROSS-TAB, and the company's consolidated
      // figure for a flat split. Alphabet's four product lines inside Google Services sum to
      // 342,721,000,000 — Google Services itself — not to the 402,836,000,000 the company
      // reported. Reconciling them against the company would place none of them.
      const target = g0.parentMember === null
        ? totals.get(key(g0.metricCode, g0.periodType, g0.periodStart, g0.periodEnding))?.value
        : flatValue.get(
          `${g0.parentAxis}|${g0.parentMember}|${g0.metricCode}|${g0.periodType}|` +
          `${g0.periodStart}|${g0.periodEnding}`,
        )
      if (target === undefined) continue
      const map = assignPartitions(
        cands.map((c) => ({ memberCode: c.memberCode, value: c.value })),
        target,
      )
      const placed = [...map.values()].filter((v) => v > 0).length
      if (placed > bestPlaced) { bestPlaced = placed; bestMap = map }
    }

    for (const c of group) {
      out.push({ ...c, partitionId: bestMap?.get(c.memberCode) ?? 0 })
    }
  }
  return out
}

// ── Finding the instance ───────────────────────────────────────────────────────────────────────

import { secWww } from './origins.ts'

/** SEC's stated requirement: a real contact, not a browser string. Without it every call 403s. */
const SEC_UA = 'muffin-market-data admin@rafiki.guru'

async function secText(url: string, timeoutMs: number): Promise<string | null> {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': SEC_UA, 'Accept-Encoding': 'gzip' },
      signal: ctl.signal,
    })
    if (res.status === 404) return null
    if (!res.ok) throw new Error(`sec ${res.status} for ${url.slice(0, 90)}`)
    return await res.text()
  } finally {
    clearTimeout(timer)
  }
}

/** `0001018724-25-000086` -> `000101872425000086`, which is how the archive path spells it. */
const bare = (accession: string) => accession.replace(/-/g, '')

/**
 * Is this the instance document, rather than one of its linkbases?
 *
 * The instance is the `.xml` that is not `_cal` / `_def` / `_lab` / `_pre`, and not
 * `FilingSummary.xml` — which is present in every pre-2019 filing and is an index of the rendered
 * reports, not facts. Both eras are covered by this: `aapl-20250628_htm.xml` (inline XBRL, 2019+)
 * and `aapl-20150926.xml` (the standalone instance filings carried before it).
 */
function isInstanceName(name: string): boolean {
  if (!name.endsWith('.xml')) return false
  if (/_(cal|def|lab|pre|ref)\.xml$/.test(name)) return false
  if (/^FilingSummary\.xml$/i.test(name)) return false
  return /-\d{8}(_htm)?\.xml$/.test(name)
}

/**
 * The URL of a filing's XBRL instance, or null when it has none.
 *
 * TWO SOURCES, AND THE STRUCTURED ONE IS NOT RELIABLE. `index.json` is the obvious listing and is
 * INCOMPLETE for some filings — measured 2026-08-28 and reproducible: Diageo's FY2025 20-F and
 * Infosys's both report **4 items** (the xbrl zip and three zero-length index files) while the
 * HTML index for the same directory lists the full document set including `deo-20250630_htm.xml`.
 * Trusting `index.json` alone therefore concludes "this filing has no XBRL" for exactly the
 * foreign private issuers this feature exists to reach, and records that as a permanent fact.
 *
 * Returning null is a real answer — plenty of filings genuinely carry no XBRL — and is different
 * from throwing, which means SEC did not answer and the filing must be tried again.
 */
export async function findInstanceUrl(
  cik: number,
  accession: string,
  timeoutMs: number,
): Promise<string | null> {
  const dir = `${secWww()}/Archives/edgar/data/${cik}/${bare(accession)}`

  const listing = await secText(`${dir}/index.json`, timeoutMs)
  if (listing !== null) {
    try {
      const parsed = JSON.parse(listing) as { directory?: { item?: { name?: unknown }[] } }
      const names = (parsed.directory?.item ?? [])
        .map((i) => String(i.name ?? ''))
        .filter(isInstanceName)
      // Shortest wins: a filing occasionally carries an amended companion, and the base instance
      // is the one whose name is the bare `{ticker}-{date}` form.
      if (names.length > 0) return `${dir}/${names.sort((a, b) => a.length - b.length)[0]}`
    } catch { /* fall through to the HTML index */ }
  }

  const html = await secText(`${dir}/${accession}-index.htm`, timeoutMs)
  if (html === null) return null
  const found = [...html.matchAll(/href="[^"]*\/([A-Za-z0-9_-]+\.xml)"/g)]
    .map((m) => m[1])
    .filter(isInstanceName)
  if (found.length === 0) return null
  return `${dir}/${found.sort((a, b) => a.length - b.length)[0]}`
}

/** The instance itself. 0.8-2.3 MB in every filing measured; parsed one at a time by the caller. */
export async function fetchInstance(url: string, timeoutMs: number): Promise<string | null> {
  return await secText(url, timeoutMs)
}
