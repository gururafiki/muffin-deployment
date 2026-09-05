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
  /**
   * A member this axis MUST carry for the fact to be kept. Null means any member is acceptable.
   *
   * WHY A QUALIFIER SOMETIMES HAS TO PIN ONE. `srt:ConsolidationItemsAxis = OperatingSegments`
   * narrows a fact without changing what it measures, so any member is fine. Korean filings tag
   * **every** fact with `ifrs-full:ConsolidatedAndSeparateFinancialStatementsAxis`, and that one is
   * not harmless: measured on a DART filing, 1,538 facts are `ConsolidatedMember` and 1,213 are
   * `SeparateMember` — parent-company-only accounts, a different set of numbers for the same
   * company and period. Treating it as an open qualifier would let a separate-statement product
   * split be reconciled against a consolidated total, or worse, stored beside one.
   */
  requiredMember: string | null
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
   * The figure this member's split was reconciled AGAINST — the filing's own consolidated value
   * for a flat split, or the parent member's value for a nested one.
   *
   * Stored because otherwise nothing downstream can tell a DOUBLE COUNT from a DISAGREEMENT
   * BETWEEN SOURCES. A guard comparing the split against `security_metric` is comparing two
   * independently-derived totals: companyfacts merges every filing and resolves a concept across
   * all of them, while this parser reads one document. When they differ the split looks broken and
   * is not. With the target stored, "does this split still add up to what it was accepted against"
   * is exact and needs no second source.
   */
  reconciledTo: number | null
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
/**
 * A member code a filing generated rather than named.
 *
 * Korean filers emit `entity00144164:udf_NOTE_20231114182510391Member` ALONGSIDE
 * `entity00144164:LpgSalesMemberOfProductsAndServices` for the same line and the same value — two
 * complete, equally valid splits of one total. The partition logic already handles that correctly
 * (one becomes partition 1, the other partition 2), so this is not about correctness: it decides
 * which of two TIED splits a reader sees, and "LPG sales" is worth more than a timestamp.
 *
 * A PREFERENCE AMONG EQUALS, NOT A REWRITE. `security-symbol-repair` records why pattern-matching
 * a code and changing it is dangerous — the rule matches names it should not. Nothing is renamed or
 * dropped here; both splits are stored, and this only breaks a tie in cardinality.
 */
const isGenerated = (memberCode: string) => /:udf_/i.test(memberCode)

function maxSubsetSummingTo(
  members: { memberCode: string; value: number }[],
  target: number,
): number[] | null {
  const n = members.length
  let best: number[] | null = null
  let bestGenerated = 0
  for (let mask = 1; mask < 1 << n; mask++) {
    let sum = 0
    let count = 0
    let generated = 0
    for (let i = 0; i < n; i++) {
      if (mask & (1 << i)) {
        sum += members[i].value
        count++
        if (isGenerated(members[i].memberCode)) generated++
      }
    }
    if (Math.abs(sum - target) > toleranceFor(target)) continue
    // More members wins; among equals, the split a human can read wins.
    if (best === null || count > best.length ||
        (count === best.length && generated < bestGenerated)) {
      const idx: number[] = []
      for (let i = 0; i < n; i++) if (mask & (1 << i)) idx.push(i)
      best = idx
      bestGenerated = generated
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
  /**
   * Members that cannot be a business line, from `market.segment_member_class`. The two roles need
   * OPPOSITE treatment, which is why this carries a class rather than being a list.
   *
   * `subtotal` is dropped outright: a split containing one double-counts by construction — Chevron
   * publishes an "aggregation before other operating segments" (230,789m) beside `AllOtherSegments`
   * (581m), the two reconcile exactly, and the result was served as its business breakdown.
   *
   * `residual` is KEPT — it is a genuine part of any split that also names real segments, and
   * Chevron's own `depreciation` partition needs it to reconcile — but may never be the whole of
   * one. See the residual-only rule at the emit below.
   */
  memberRoles: Iterable<{ memberCode: string; class: string }> = [],
): SegmentFact[] {
  const subtotals = new Set(
    [...memberRoles].filter((m) => m.class === 'subtotal').map((m) => m.memberCode),
  )
  const residuals = new Set(
    [...memberRoles].filter((m) => m.class === 'residual').map((m) => m.memberCode),
  )
  const units = parseUnits(xml)
  const contexts = parseContexts(xml)
  const facts = parseFacts(xml, concepts)

  const kindOf = new Map(axes.map((a) => [a.axis, a.kind]))
  const priorityOfAxis = new Map(axes.map((a) => [a.axis, a.priority]))
  const requiredMemberOf = new Map(axes.map((a) => [a.axis, a.requiredMember ?? null]))
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
  /**
   * The same totals keyed by the CONCEPT that stated them, so a split can reconcile against its
   * OWN concept before falling back to the highest-priority one.
   *
   * MEASURED ON A KOREAN FILING, where it decides the outcome. SK Gas states both
   * `Revenue` = 7,095,902,060,317 and `RevenueFromContractsWithCustomers` = 7,050,068,258,000 for
   * FY2024, and its product split is tagged with the SECOND. Reconciling against the
   * higher-priority `Revenue` leaves it 0.65% short — just outside tolerance — so the whole split
   * was unplaced and Korea produced nothing while parsing perfectly. Alphabet needs the fallback
   * for the opposite reason: its members use a concept that has no undimensioned fact at all.
   */
  const totalsByConcept = new Map<string, number>()
  /**
   * (concept, metric, period) keys where MORE THAN ONE distinct value was stated with no segment
   * axis — so the concept alone cannot identify a target.
   *
   * Samsung states Revenue four times under four qualifier contexts. The qualifier-matched lookup
   * resolves that, but a split whose own members DISAGREE about their context has no context to
   * match with, and falling back to "the total for this concept" would hand it whichever fact
   * happened to be parsed last. Refusing is the honest answer: the split is left in partition 0
   * rather than reconciled against a figure it was never disaggregated from.
   */
  const ambiguousConcept = new Set<string>()
  const key = (metric: string, pt: string, start: string, end: string) =>
    `${metric}|${pt}|${start}|${end}`

  interface Candidate {
    axis: string
    memberCode: string
    parentAxis: string | null
    parentMember: string | null
    /** The XBRL concept this fact was tagged with — see `totalsByConcept`. */
    concept: string
    metricCode: string
    periodType: 'annual' | 'quarter' | 'instant'
    periodStart: string
    periodEnding: string
    value: number
    currency: string | null
    /**
     * The qualifier axes this fact carries, canonicalised — see `qualifierKey`. It is what tells a
     * split which of several "undimensioned" totals it was actually disaggregated from.
     */
    qualifier: string
  }
  const candidates: Candidate[] = []

  /**
   * The qualifier axes of a fact, sorted and joined — its "which version of the company is this"
   * context.
   *
   * A QUALIFIER NARROWS A FACT WITHOUT SUB-DIVIDING IT, so it is correctly ignored when deciding
   * WHETHER something is a segment fact. It must NOT be ignored when deciding what that segment
   * fact reconciles TO. Measured on Samsung's FY2024 filing, four Revenue facts have no segment
   * axis and therefore all look like "the consolidated total":
   *
   *     300.87T  Consolidated
   *     329.39T  Consolidated + OperatingSegments      <- the divisions sum to exactly this
   *     -28.52T  Consolidated + MaterialReconcilingItems
   *     209.05T  Separate
   *
   * Keyed on (metric, period) alone they collapse into one slot and the winner is arbitrary — it
   * picked the ELIMINATION, so Samsung's four divisions were measured against -28.52T. Keyed on the
   * qualifier context as well, the split's own context ({Consolidated, OperatingSegments}) selects
   * the only candidate that can be right. Exact, not a heuristic.
   *
   * This is not a Korea special case: Alphabet tags every segment figure with
   * `srt:ConsolidationItemsAxis = OperatingSegmentsMember` too, and has simply never had a second
   * candidate to be confused by.
   */
  const qualifierKey = (dims: [string, string][]): string =>
    dims.filter(([a]) => kindOf.get(a) === 'qualifier')
      .map(([a, m]) => `${a}=${m}`).sort().join('|')

  /** (qualifier context, metric, period) -> the figure stated under exactly that context. */
  const totalsByQualifier = new Map<string, { value: number; priority: number }>()
  /** (concept, qualifier context, metric, period) — the most specific match there is. */
  const totalsByConceptQualifier = new Map<string, number>()
  /** `axis|metric|periodType|start|end` -> (qualifier member -> value), for facts with NO segment
   *  dimension. Nested so the members of one axis can be summed without parsing a flat key. */
  const qualifierMemberTotals = new Map<string, Map<string, number>>()

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
    // A SUBTOTAL IS NOT A SEGMENT. Dropped here rather than after partitioning, because a
    // subtotal plus a residual can reconcile perfectly and would then BE the chosen partition.
    if (segs.some(([, m]) => subtotals.has(m))) continue
    const unknown = dims.filter(([a]) => !kindOf.has(a))
    // A PINNED QUALIFIER REJECTS THE FACT WHEN ITS MEMBER IS WRONG — see `requiredMember`. This is
    // what keeps a Korean filer's parent-only accounts out of its consolidated segment split.
    const wrongMember = dims.some(([a, m]) => {
      const req = requiredMemberOf.get(a)
      return req !== undefined && req !== null && req !== m
    })
    // RECORDED BEFORE THE PIN REJECTS IT, because an elimination fact is exactly what a gross
    // target is derived from — and migration 173 pins this axis to `OperatingSegmentsMember` so
    // that eliminations can never become segment MEMBERS. Both are wanted: the fact must not be a
    // member, and it must still be available as arithmetic. Equinor states no operating-segments
    // total for `Revenue`, only the consolidated 106,462m and this elimination of -42,421m, and
    // 106,462 - (-42,421) = 148,883m is exactly what its six segments sum to.
    if (segs.length === 0 && dims.length === 1 && kindOf.get(dims[0][0]) === 'qualifier') {
      const [ax, mem] = dims[0]
      const kk = key(f.metricCode, pt, start, end)
      const bucket = qualifierMemberTotals.get(`${ax}|${kk}`) ?? new Map<string, number>()
      bucket.set(mem, f.value)
      qualifierMemberTotals.set(`${ax}|${kk}`, bucket)
    }

    if (wrongMember) continue

    // AN UNKNOWN AXIS DISQUALIFIES THE FACT, whatever else is true of it — checked first so a
    // fact carrying one can never be mistaken for the consolidated total below.
    if (unknown.length > 0) continue

    if (segs.length === 0) {
      // The filing's own consolidated figure — the target every partition must reconcile to.
      //
      // "NO SEGMENT DIMENSIONS", NOT "NO DIMENSIONS AT ALL", and that distinction is what makes
      // this work outside the US. A Korean filing tags EVERY fact with
      // `ConsolidatedAndSeparateFinancialStatementsAxis`, so nothing in it is ever literally
      // undimensioned — the earlier test found no total, every split was left unplaced, and a
      // whole jurisdiction silently produced partition 0 for everything while parsing cleanly.
      const k = key(f.metricCode, pt, start, end)
      const priority = priorityOf.get(f.concept) ?? 0
      const held = totals.get(k)
      if (held === undefined || priority > held.priority) totals.set(k, { value: f.value, priority })
      const ck = `${f.concept}|${k}`
      const prior = totalsByConcept.get(ck)
      if (prior !== undefined && prior !== f.value) ambiguousConcept.add(ck)
      totalsByConcept.set(ck, f.value)
      // KEPT SEPARATELY, NOT INSTEAD. The unqualified map stays the fallback for a filing whose
      // split carries a qualifier its total does not — the ordinary SEC shape — so nothing that
      // reconciles today stops reconciling.
      const qual = qualifierKey(dims)
      // PER QUALIFIER MEMBER, so a total the filing does not state can be DERIVED from the ones it
      // does. Equinor publishes no operating-segments total for `Revenue`; it publishes the plain
      // consolidated figure (106,462m) and the elimination (-42,421m) on the same axis, and
      // 106,462 - (-42,421) = 148,883 is exactly what its six segments sum to.
      const qk = `${qual}|${k}`
      const heldQ = totalsByQualifier.get(qk)
      if (heldQ === undefined || priority > heldQ.priority) {
        totalsByQualifier.set(qk, { value: f.value, priority })
      }
      totalsByConceptQualifier.set(`${f.concept}|${qual}|${k}`, f.value)
      continue
    }
    // BOTH BOUNDS, and the lower one is not dead code. Every `segs.length === 0` fact is taken by
    // the total branch above today, so this can only fire if that branch changes — which is
    // exactly when it matters: without it the candidate push reads `ordered[0][0]` of an empty
    // array and the whole run dies with a TypeError instead of skipping one fact. Found by a
    // mutation that crashed the harness rather than failing an assertion.
    if (segs.length < 1 || segs.length > 2) continue

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
      concept: f.concept,
      metricCode: f.metricCode,
      periodType: pt,
      periodStart: start,
      periodEnding: end,
      value: f.value,
      currency,
      qualifier: qualifierKey(dims),
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

  // ── A CROSS-TAB IS ALSO A FLAT SPLIT, SUMMED THE OTHER WAY ────────────────────────────────────
  //
  // A cross-tab cell reconciles to its PARENT's value, so a filer that publishes the grid without
  // stating the parent's own total leaves every cell unplaceable: Chevron FY2025 discloses
  // US/non-US x upstream/downstream revenue and no flat regional revenue at all, so all four cells
  // sat at partition 0 and its business-line revenue — a complete, exactly-reconciling split — was
  // in the database and on no page. Measured 2026-09-05: 19,990 such cells across 153 securities,
  // 93 of them with nothing served on that axis.
  //
  // Summing the grid over the parent axis recovers the split the filer did publish, just not
  // flatly. It is arithmetic on the filer's own facts, and the EXISTING partition search is what
  // keeps it honest: the marginal is offered as an ordinary flat candidate and survives only if it
  // reconciles to the filing's own undimensioned total, exactly like a filed member.
  //
  // WHY THAT TEST IS THE WHOLE DESIGN, measured on the two poles:
  //   Chevron   Upstream 88,379 + Downstream 142,410 (marginal) + AllOther 581 (FILED)
  //             = 231,370 = the filing's own revenue total          -> served
  //   Novo      its members are a NESTED HIERARCHY — Ozempic inside TotalGLP1 inside
  //             TotalDiabetesCare — and its regions likewise (EUCAN, CN, APAC and Emerging
  //             Markets all sit inside International Operations). Summed flat the cells reach
  //             DKK 1,307,626m against revenue of 309,064m, 4.2x.                -> not served
  // No rule about grids or completeness separates those two; reconciliation does, and it is the
  // rule already relied on everywhere else here.
  //
  // A MEMBER THE FILER STATES FLATLY IS NEVER OVERWRITTEN. Chevron's `AllOther` has a filed flat
  // value and keeps it; only members with no flat fact of their own are synthesised. Otherwise a
  // sum of ours would silently replace a number the filing states.
  const marginals: Candidate[] = (() => {
    const flatSeen = new Set<string>()
    for (const c of unique) {
      if (c.parentMember === null) {
        flatSeen.add(`${c.axis}|${c.memberCode}|${c.metricCode}|${c.periodType}|${c.periodEnding}`)
      }
    }
    const rolled = new Map<string, Candidate>()
    for (const c of unique) {
      if (c.parentMember === null) continue
      const flatKey = `${c.axis}|${c.memberCode}|${c.metricCode}|${c.periodType}|${c.periodEnding}`
      if (flatSeen.has(flatKey)) continue
      const existing = rolled.get(flatKey)
      if (existing) existing.value += c.value
      else {
        rolled.set(flatKey, {
          ...c,
          parentAxis: null,
          parentMember: null,
          // THE QUALIFIER IS KEPT, and dropping it was wrong. A qualifier says which of several
          // "undimensioned" totals a fact was disaggregated from, and the cells carry the filer's
          // — Chevron tags its grid `ConsolidationItemsAxis = OperatingSegmentsMember`, whose
          // total is 231,370m, while the bare undimensioned revenue is 184,432m. Blanking it put
          // the marginal in the unqualified bucket, where it summed to 231,370 against a target of
          // 184,432 and reconciled to nothing. It also has to match the FILED members it will be
          // partitioned beside — Chevron's `AllOther` carries the same qualifier.
          value: c.value,
        })
      }
    }
    return [...rolled.values()]
  })()
  const synthetic = new Set(marginals)
  for (const m of marginals) unique.push(m)


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
    // THE SPLIT IS SHARED ACROSS THE GROUP; THE TARGET IS NOT.
    //
    // `bestMap` — which members belong together — is one fact per axis per reporting date and is
    // deliberately applied to every bucket (see the note above; it is what makes segment ASSETS
    // usable at all). `reconciled_to` is a different kind of fact: it is the consolidated figure
    // for ONE metric over ONE span. Stamping the winning bucket's target on the whole group hands
    // a quarter the year's revenue and an older comparative the newest year's.
    //
    // The group is keyed `axis|periodEnding`, so it spans BOTH period types and every metric — and
    // a fiscal-year end is also Q4's end, the same collision migration 106 had to put into
    // `security_statement`'s primary key. Measured 2026-09-04 on the live data: 3,021 of 11,211
    // flat revenue splits did not sum to the target stored beside them, and the damage tracks the
    // shape exactly — 47% of older comparatives wrong against 24% of quarters and 26% of newest
    // annuals, with the largest ratio bucket below 0.5 (a quarter's split against a year's total).
    const targetByBucket = new Map<string, number>()
    for (const [bucketKey, cands] of byBucket) {
      const g0 = cands[0]
      // THE TARGET IS THE PARENT'S OWN VALUE FOR A CROSS-TAB, and the company's consolidated
      // figure for a flat split. Alphabet's four product lines inside Google Services sum to
      // 342,721,000,000 — Google Services itself — not to the 402,836,000,000 the company
      // reported. Reconciling them against the company would place none of them.
      const flatKey = key(g0.metricCode, g0.periodType, g0.periodStart, g0.periodEnding)
      // SAME CONCEPT FIRST. The members of a split carry a concept of their own; the company's
      // total under THAT concept is what they were disaggregated from. Priority is the fallback
      // for a filing whose members use a concept it never states undimensioned.
      const ownConcept = [...new Set(cands.map((c) => c.concept))]
      const sameConcept = ownConcept.length === 1
        ? (ambiguousConcept.has(`${ownConcept[0]}|${flatKey}`)
          ? undefined
          : totalsByConcept.get(`${ownConcept[0]}|${flatKey}`))
        : undefined
      // THE SPLIT'S OWN QUALIFIER CONTEXT FIRST. Several facts can look undimensioned for one
      // (metric, period) and differ only by qualifier — the consolidated figure, the
      // operating-segments subtotal the divisions actually sum to, and the reconciling-items
      // elimination. The split was disaggregated from the one sharing its context, and nothing
      // else can be right. Falls back to the concept-specific and then the unqualified total, so a
      // filing whose split carries a qualifier its total does not is unaffected.
      // FOUR LEVELS, MOST SPECIFIC FIRST. Concept and qualifier are independent narrowings and both
      // matter: pinning only the qualifier let a same-qualifier total of the WRONG concept beat the
      // concept-specific one, which regressed an existing fixture the moment it was tried.
      const ownQualifier = [...new Set(cands.map((c) => c.qualifier))]
      const oneQualifier = ownQualifier.length === 1 ? ownQualifier[0] : null
      const conceptQualified = ownConcept.length === 1 && oneQualifier !== null
        ? totalsByConceptQualifier.get(`${ownConcept[0]}|${oneQualifier}|${flatKey}`)
        : undefined
      const qualified = oneQualifier === null
        ? undefined
        : totalsByQualifier.get(`${oneQualifier}|${flatKey}`)?.value

      // DERIVED FROM THE FILING'S OWN RECONCILIATION, when it states no total for this qualifier.
      //
      // A gross split needs a gross target. Where the filer publishes one (Samsung, Hyundai Mobis,
      // Chevron) `qualified` finds it. Equinor publishes only the CONSOLIDATED figure and the
      // elimination, both on the same qualifier axis and both undimensioned by segment — so the
      // operating-segments total is the consolidated figure less every OTHER member of that axis:
      //
      //   106,462,000,000 - (-42,421,000,000) = 148,883,000,000
      //
      // which is exactly what its six segments sum to. That is arithmetic over facts the filing
      // states, not an inference about what it meant: without it the split is judged against the
      // consolidated figure it was never meant to equal, and a correct disclosure reads as a defect.
      // THE SEGMENT COLUMN'S TOTAL, DERIVED FROM THE OTHER COLUMNS.
      //
      // A filer often states no total for the operating-segments column at all: Southern Copper's
      // FY2018 10-K publishes consolidated revenue 7,096,700,000 and an intersegment elimination of
      // -79,300,000, and nothing in between. The segments themselves sum to 7,176,000,000 — which
      // is CORRECT, because segment revenue includes intersegment sales that consolidation removes.
      // Reconciling them against the consolidated figure reports a 1.01x over-count on data that is
      // right, and an over-count is the half this pipeline treats as a defect.
      //
      // TWO VARIANTS, BECAUSE A FILER CAN TAG ONE ADJUSTMENT UNDER TWO MEMBER NAMES. Southern
      // Copper states the same -79,300,000 as BOTH `us-gaap:IntersegmentEliminationMember` and
      // `scco:CorporateAndEliminationsMember` — the same line, once in the segment table and once
      // in the geography table — so summing every other member double-counts it and derives
      // 7,255,300,000, which matches nothing. Deduplicating by VALUE derives 7,176,000,000.
      //
      // Both are offered rather than one replacing the other, and that is what makes the guess
      // safe: `reconciling` below accepts a candidate ONLY if the members' own sum already matches
      // it, so an extra candidate can never select a wrong target — it can only rescue a split that
      // would otherwise fall back to one. Neither is fitted to the answer: both are arithmetic over
      // figures the filing states.
      // THE SEGMENT COLUMN'S TOTAL, DERIVED FROM THE OTHER COLUMNS.
      //
      // A filer often states no total for the operating-segments column at all. Southern Copper's
      // FY2018 10-K publishes consolidated revenue 7,096,700,000 and an intersegment elimination of
      // -79,300,000, and nothing in between; its three segments sum to 7,176,000,000, which is
      // CORRECT, because segment revenue includes intersegment sales that consolidation removes.
      // Reconciled against the consolidated figure that is a 1.01x OVER-count — the half this
      // pipeline treats as a defect — on data that is right.
      //
      // TWO REASONS THE NARROW FORM COULD NOT REACH IT. Its candidates carry NO qualifier axis (the
      // filer tags the plain `StatementBusinessSegmentsAxis` facts as well as the qualified ones),
      // so a derivation keyed on the candidates' own qualifier never ran. And the same
      // -79,300,000 is tagged under BOTH `us-gaap:IntersegmentEliminationMember` and
      // `scco:CorporateAndEliminationsMember` — one line, stated once in the segment table and once
      // in the geography table — so summing every member of the axis double-counts it and derives
      // 7,255,300,000, which matches nothing.
      //
      // So: walk every qualifier axis that has totals for this metric and period, and offer both
      // the every-member and the distinct-VALUE sum. Offering rather than choosing is what makes
      // this safe — `reconciling` below accepts a candidate ONLY if the members' own sum already
      // matches it, so an extra candidate can never select a wrong target, it can only rescue a
      // split that would otherwise fall back to one. Neither figure is fitted to the answer: both
      // are arithmetic over totals the filing itself states.
      const derivedTargets = (() => {
        const plain = totals.get(flatKey)?.value
        if (plain === undefined) return []
        let ownAxis: string | null = null
        let ownMember: string | null = null
        if (oneQualifier !== null && oneQualifier !== '' && !oneQualifier.includes('|')) {
          const eq = oneQualifier.indexOf('=')
          if (eq >= 0) {
            ownAxis = oneQualifier.slice(0, eq)
            ownMember = oneQualifier.slice(eq + 1)
          }
        }
        const out: number[] = []
        const suffix = `|${flatKey}`
        for (const [k, bucket] of qualifierMemberTotals) {
          if (!k.endsWith(suffix)) continue
          const axis = k.slice(0, k.length - suffix.length)
          const others: number[] = []
          for (const [m, v] of bucket) {
            if (axis === ownAxis && m === ownMember) continue
            others.push(v)
          }
          if (others.length === 0) continue
          const all = others.reduce((a, v) => a + v, 0)
          const distinct = [...new Set(others)].reduce((a, v) => a + v, 0)
          out.push(plain - all)
          if (distinct !== all) out.push(plain - distinct)
        }
        return out
      })()

      // THE FALLBACK IS DELIBERATELY THE OLD, NARROWER FORM. A split that reconciles to nothing
      // must be described exactly as it was before these candidates existed, or widening the search
      // would quietly change the target of every split it fails to rescue.
      const derived = (() => {
        if (oneQualifier === null) return undefined
        const plain = totals.get(flatKey)?.value
        if (plain === undefined) return undefined
        const eq = oneQualifier.indexOf('=')
        if (eq < 0 || oneQualifier.includes('|')) return undefined   // exactly one qualifier axis
        const axis = oneQualifier.slice(0, eq)
        const member = oneQualifier.slice(eq + 1)
        const bucket = qualifierMemberTotals.get(`${axis}|${flatKey}`)
        if (bucket === undefined) return undefined
        let others = 0
        let found = false
        for (const [m, v] of bucket) {
          if (m === member) continue
          others += v
          found = true
        }
        return found ? plain - others : undefined
      })()

      // THE TARGET IS THE STATED FIGURE THE MEMBERS ACTUALLY ADD UP TO.
      //
      // Precedence alone picks the most SPECIFIC total, which is usually right and is wrong for a
      // gross split whose gross total the filer never states. Equinor's six segments sum to
      // 148,883m; the filing states the consolidated 106,462m and, on the same qualifier axis, the
      // elimination of -42,421m — and 106,462 - (-42,421) = 148,883 exactly. Precedence took the
      // consolidated figure and a correct disclosure read as a defect.
      //
      // So: if one of the candidate totals is the one the members reconcile to, that is the target.
      // Otherwise fall back to precedence unchanged — which is what keeps Chevron honest, where NO
      // candidate reconciles (its business axis carries only cross-tab halves and a residual) and
      // the partition search is then left to reject it rather than being handed a total to match.
      const candidateSum = cands.reduce((a, c) => a + c.value, 0)
      const reconciling = [conceptQualified, sameConcept, qualified, ...derivedTargets,
        totals.get(flatKey)?.value]
        .find((t) => t !== undefined && Math.abs(candidateSum - t) <= toleranceFor(t))

      const target = g0.parentMember === null
        ? reconciling ?? conceptQualified ?? sameConcept ?? qualified ?? derived ?? totals.get(flatKey)?.value
        : flatValue.get(
          `${g0.parentAxis}|${g0.parentMember}|${g0.metricCode}|${g0.periodType}|` +
          `${g0.periodStart}|${g0.periodEnding}`,
        )
      if (target === undefined) continue
      const map = assignPartitions(
        cands.map((c) => ({ memberCode: c.memberCode, value: c.value })),
        target,
      )
      targetByBucket.set(bucketKey, target)
      const placed = [...map.values()].filter((v) => v > 0).length
      if (placed > bestPlaced) { bestPlaced = placed; bestMap = map }
    }

    // A RESIDUAL ALONE IS NOT A SPLIT.
    //
    // `bestMap` is learned from the bucket that places the most members and applied to every metric
    // on the axis — deliberately, since segment ASSETS and PROFIT never reconcile and could not
    // otherwise be placed at all. The cost is that a bucket holding only SOME of those members
    // inherits the partition anyway, and when the ones it holds are all residual the result is the
    // leftovers wearing the company's name: Chevron served `AllOtherSegments 581m` as its FY2025
    // revenue breakdown, against a consolidated 231,370,000,000.
    //
    // The narrow rule is the only one that survives its own filing. Demanding the inherited
    // partition be COMPLETE would discard Chevron's `total_assets`, which reconciles exactly on
    // Upstream + Downstream with no residual; demanding it RECONCILE in its own bucket would reject
    // segment profit everywhere, which ASC 280 and IFRS 8 guarantee will never sum. So: a partition
    // must contain at least one member that is not a residual. The residual keeps its place beside
    // real segments and loses only the ability to be a split by itself.
    const realMembers = new Set<string>()
    for (const c of group) {
      const p = bestMap?.get(c.memberCode) ?? 0
      if (p > 0 && !residuals.has(c.memberCode)) {
        realMembers.add(`${c.metricCode}|${c.periodType}|${c.periodStart}|${c.periodEnding}|${p}`)
      }
    }

    for (const c of group) {
      const inherited = bestMap?.get(c.memberCode) ?? 0
      const partitionId = inherited > 0 &&
          !realMembers.has(
            `${c.metricCode}|${c.periodType}|${c.periodStart}|${c.periodEnding}|${inherited}`,
          )
        ? 0
        : inherited
      // ITS OWN BUCKET'S TARGET, or NOTHING. A bucket whose metric and span the filing never
      // states undimensioned has no consolidated figure to have been reconciled against, and
      // saying so is the honest answer — `check_segments_reconcile` skips a null target rather
      // than asserting against a borrowed one, which is how 3,021 false disagreements arose.
      const own = targetByBucket.get(
        `${c.metricCode}|${c.periodType}|${c.periodStart}|${c.periodEnding}`,
      )
      // A MARGINAL THAT EARNS NO PARTITION IS DELETED, NOT STORED AT 0.
      //
      // A filed member at partition 0 is a fact the filing states and we could not place — worth
      // keeping, and the raw table's job. A marginal is OURS: it exists only to be reconciled, and
      // unplaced it is a duplicate of the cells it was summed from. Alphabet shows why it matters —
      // its product cells sum to Google Services (342,721,000,000), not to the company, so the
      // marginal correctly places nothing, and storing it anyway would add five rows that say
      // exactly what the five cells already say while looking like a flat split the filer never
      // made.
      if (synthetic.has(c) && partitionId === 0) continue
      out.push({ ...c, partitionId, reconciledTo: partitionId > 0 ? own ?? null : null })
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

/**
 * THE LARGEST INSTANCE THIS WORKER CAN SURVIVE.
 *
 * MEASURED, AFTER A TWO-DAY OUTAGE. `security-segments` parsed nothing between 2026-08-30 08:22
 * and 2026-09-01: the supervisor killed the worker on every firing, in under two seconds, even
 * with a page of ONE. The filing at the head of the queue was American Electric Power's 2015 10-K
 * — `aep-20151231.xml`, **127.72 MB**. A JS string is UTF-16, so the text alone is ~256 MB against
 * a 256 MB worker, before a byte is parsed. Utilities tag every subsidiary and sit far outside the
 * range this parser was measured on (AAPL 0.74 MB, AMZN 1.98 MB, Cemex 6.53, Yandex 4.90,
 * Diageo's 20-F 10.92 — the largest previously seen).
 *
 * IT WAS A PERMANENT HEAD-OF-LINE BLOCK, which is the part worth remembering. A filing is stamped
 * `segments_parsed_at` only after a successful parse, and a KILLED WORKER STAMPS NOTHING — it does
 * not throw, it dies — so the same document returned at the head of every run for ever. Second
 * head-of-line block in this resource after the depth-first ordering, and the shape is the same:
 * one row nothing can retire.
 *
 * 32 MB leaves ~3x headroom over the largest document known to parse, and roughly 4x its own size
 * in peak heap. Skipping is the right answer rather than streaming: an instance this large is a
 * utility holding company tagging hundreds of subsidiaries, and its segment note is not worth the
 * whole worker.
 */
const MAX_INSTANCE_BYTES = 32 * 1024 * 1024

/** Where a filing's instance is, and how big — `null` bytes when only the HTML index knew. */
export type InstanceRef = { url: string; bytes: number | null }

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
): Promise<InstanceRef | null> {
  const dir = `${secWww()}/Archives/edgar/data/${cik}/${bare(accession)}`

  const listing = await secText(`${dir}/index.json`, timeoutMs)
  if (listing !== null) {
    try {
      const parsed = JSON.parse(listing) as
        { directory?: { item?: { name?: unknown; size?: unknown }[] } }
      // THE SIZE IS IN A RESPONSE WE ALREADY FETCH, and it was being discarded — the seventh time
      // that has been true in this pipeline. Gating on it costs no extra request and is what stops
      // a 128 MB filing killing the worker before it can be stamped.
      const items = (parsed.directory?.item ?? [])
        .map((i) => ({ name: String(i.name ?? ''), bytes: Number(i.size ?? 0) || null }))
        .filter((i) => isInstanceName(i.name))
      // Shortest wins: a filing occasionally carries an amended companion, and the base instance
      // is the one whose name is the bare `{ticker}-{date}` form.
      items.sort((a, b) => a.name.length - b.name.length)
      if (items.length > 0) return { url: `${dir}/${items[0].name}`, bytes: items[0].bytes }
    } catch { /* fall through to the HTML index */ }
  }

  const html = await secText(`${dir}/${accession}-index.htm`, timeoutMs)
  if (html === null) return null
  const found = [...html.matchAll(/href="[^"]*\/([A-Za-z0-9_-]+\.xml)"/g)]
    .map((m) => m[1])
    .filter(isInstanceName)
  if (found.length === 0) return null
  // The HTML index carries no size, so this one is gated at fetch time on `Content-Length`.
  return { url: `${dir}/${found.sort((a, b) => a.length - b.length)[0]}`, bytes: null }
}

/** Is this instance small enough to read into a 256 MB worker? See MAX_INSTANCE_BYTES. */
export function instanceIsTooLarge(bytes: number | null): boolean {
  return bytes !== null && bytes > MAX_INSTANCE_BYTES
}

/**
 * The instance itself, refused if it is too large to hold.
 *
 * A SECOND GATE, because the first one cannot always fire: the HTML-index fallback carries no
 * size, and `index.json` is the listing that is unreliable for exactly the foreign private issuers
 * this feature exists to reach. Checking `Content-Length` before reading the body costs nothing
 * and closes that path — `res.text()` is where the 256 MB allocation happens, so refusing after it
 * would be refusing too late.
 *
 * Returns `TOO_LARGE` rather than null so the caller can count it separately: "this filing has no
 * XBRL" and "we declined to read 128 MB" are different facts, and conflating an absence with a
 * refusal is the mistake this pipeline has made in six other places.
 */
export const TOO_LARGE = Symbol('instance too large')

export async function fetchInstance(
  url: string,
  timeoutMs: number,
): Promise<string | null | typeof TOO_LARGE> {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': SEC_UA, 'Accept-Encoding': 'gzip' },
      signal: ctl.signal,
    })
    if (res.status === 404) return null
    if (!res.ok) throw new Error(`sec ${res.status} for ${url.slice(0, 90)}`)
    // `Content-Length` is the COMPRESSED size when the response is gzipped, so this is a floor on
    // the decompressed document rather than an exact bound — which is the safe direction: anything
    // it rejects is certainly too big, and the `index.json` gate above catches the rest.
    const declared = Number(res.headers.get('content-length') ?? 0)
    if (declared > MAX_INSTANCE_BYTES) {
      await res.body?.cancel()
      return TOO_LARGE
    }
    return await res.text()
  } finally {
    clearTimeout(timer)
  }
}
