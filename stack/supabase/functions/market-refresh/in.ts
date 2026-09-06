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
