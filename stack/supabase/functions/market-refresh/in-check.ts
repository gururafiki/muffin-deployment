/**
 * Offline checks for the NSE normaliser. No network, no database.
 *
 * The fixture reproduces the SHAPE measured on Reliance, HDFC Bank and Infosys rather than
 * embedding one of their instances, for the reason `dart-check` builds its own ZIP: a 100 KB
 * document cannot be committed, and a fixture that only reproduces ONE filer's quirks proves the
 * rule generalises to nothing. Each rule below is exercised by a case where the candidate
 * behaviours DISAGREE — if removing the rule left the fixture passing, it would be decoration.
 *
 * The real numbers are pinned in the comments so a future reader can re-derive them:
 *   Reliance  annual 11,094,900,000,000  quarter 2,916,250,000,000
 *   HDFC Bank annual  6,012,753,600,000  quarter 1,774,357,500,000
 *   Infosys   annual  1,536,700,000,000  quarter   379,230,000,000
 * Every one reconciles to its own undimensioned total, to the rupee.
 */
import { memberCodeFor, normalise, NOT_CONSOLIDATED, yearStartFor } from './in.ts'

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

/**
 * The Indian shape: two columns over ONE set of dates, anonymous members, names on the side.
 * `One*` is a quarter and `Four*` the year, and NOTHING in the dates says so.
 */
function instance(nature: string): string {
  const ctx = (id: string, member: string | null) =>
    `<xbrli:context id="${id}"><xbrli:entity><xbrli:identifier scheme="s">X</xbrli:identifier>` +
    (member
      ? `<xbrli:segment><xbrldi:explicitMember dimension="in-bse-fin:ReportableSegmentsAxis">${member}</xbrldi:explicitMember></xbrli:segment>`
      : '') +
    `</xbrli:entity><xbrli:period><xbrli:startDate>2024-01-01</xbrli:startDate>` +
    `<xbrli:endDate>2024-03-31</xbrli:endDate></xbrli:period></xbrli:context>`
  return `<?xml version="1.0"?><xbrli:xbrl xmlns:xbrli="http://www.xbrl.org/2003/instance" xmlns:xbrldi="http://xbrl.org/2006/xbrldi" xmlns:in-bse-fin="x">
<in-bse-fin:NatureOfReportStandaloneConsolidated contextRef="OneD">${nature}</in-bse-fin:NatureOfReportStandaloneConsolidated>
${ctx('OneD', null)}${ctx('FourD', null)}
${ctx('OneReportableSegmentRevenue01D', 'in-bse-fin:OneReportableSegmentRevenue01Member')}
${ctx('OneReportableSegmentRevenue02D', 'in-bse-fin:OneReportableSegmentRevenue02Member')}
${ctx('FourReportableSegmentRevenue01D', 'in-bse-fin:FourReportableSegmentRevenue01Member')}
${ctx('FourReportableSegmentRevenue02D', 'in-bse-fin:FourReportableSegmentRevenue02Member')}
<in-bse-fin:DescriptionOfReportableSegment contextRef="OneReportableSegmentRevenue01D">Digital Services</in-bse-fin:DescriptionOfReportableSegment>
<in-bse-fin:DescriptionOfReportableSegment contextRef="OneReportableSegmentRevenue02D">Oil to Chemicals (O2C)</in-bse-fin:DescriptionOfReportableSegment>
<in-bse-fin:DescriptionOfReportableSegment contextRef="FourReportableSegmentRevenue01D">Digital Services</in-bse-fin:DescriptionOfReportableSegment>
<in-bse-fin:DescriptionOfReportableSegment contextRef="FourReportableSegmentRevenue02D">Oil to Chemicals (O2C)</in-bse-fin:DescriptionOfReportableSegment>
<in-bse-fin:SegmentRevenue contextRef="OneD" unitRef="inr" decimals="0">100</in-bse-fin:SegmentRevenue>
<in-bse-fin:SegmentRevenue contextRef="FourD" unitRef="inr" decimals="0">400</in-bse-fin:SegmentRevenue>
<in-bse-fin:SegmentRevenue contextRef="OneReportableSegmentRevenue01D" unitRef="inr" decimals="0">30</in-bse-fin:SegmentRevenue>
<in-bse-fin:SegmentRevenue contextRef="OneReportableSegmentRevenue02D" unitRef="inr" decimals="0">70</in-bse-fin:SegmentRevenue>
<in-bse-fin:SegmentRevenue contextRef="FourReportableSegmentRevenue01D" unitRef="inr" decimals="0">120</in-bse-fin:SegmentRevenue>
<in-bse-fin:SegmentRevenue contextRef="FourReportableSegmentRevenue02D" unitRef="inr" decimals="0">280</in-bse-fin:SegmentRevenue>
</xbrli:xbrl>`
}

// ── a standalone filing is refused, and refused DISTINGUISHABLY ────────────────────────────────
// Every company files twice with the same One/Four structure inside each, so taking the wrong one
// silently reports the parent company as the group. It returns a sentinel rather than throwing:
// a standalone filing is a good document we do not want, and a caller counting failures must not
// count it as one.
{
  check(normalise(instance('Standalone')) === NOT_CONSOLIDATED,
    'a standalone filing is refused, not parsed')
  check(normalise(instance('Consolidated')) !== NOT_CONSOLIDATED,
    'and the consolidated one is accepted')
}

// ── the anonymous member is replaced by the filer's own name ───────────────────────────────────
{
  const r = normalise(instance('Consolidated'))
  if (r === NOT_CONSOLIDATED) throw new Error('unreachable')
  check(r.named === 4, 'every segment context resolves a name', `${r.named} of 4`)
  check(r.xml.includes('nse:DigitalServicesMember') && r.xml.includes('nse:OilToChemicalsO2CMember'),
    'members carry the segment name, not the positional slot')
  check(!r.xml.includes('OneReportableSegmentRevenue01Member'),
    'and the anonymous code is gone entirely')
}

// ── the `Four*` column is given the year it actually describes ─────────────────────────────────
// THE DATES CANNOT TELL THEM APART. Both columns and both undimensioned totals carry the same
// 90-day period, so `periodTypeFor` sees `quarter` for both and the parser unions them: measured on
// Reliance that is 14,011,150,000,000 against a true 11,094,900,000,000, a 26% overstatement with
// two competing totals for one key. The context ID is the only place the distinction exists.
{
  const r = normalise(instance('Consolidated'))
  if (r === NOT_CONSOLIDATED) throw new Error('unreachable')
  check(r.annualised === 3, 'every Four* context is annualised', `${r.annualised} of 3`)
  const four = /<xbrli:context id="FourD">[\s\S]*?<xbrli:startDate>([^<]+)</.exec(r.xml)
  check(four?.[1] === '2023-04-01', 'the year runs to the same end date', `got ${four?.[1]}`)
  const one = /<xbrli:context id="OneD">[\s\S]*?<xbrli:startDate>([^<]+)</.exec(r.xml)
  check(one?.[1] === '2024-01-01', 'and the quarter is left alone', `got ${one?.[1]}`)
}

// ── the member code is derived from the NAME, because the slot is not stable ───────────────────
// `…Revenue03Member` is Oil to Chemicals in one filing and could be anything in the next. Keying on
// it would make a company's history incoherent the first time a filer reorders its segments.
{
  check(memberCodeFor('Oil to Chemicals (O2C)') === 'nse:OilToChemicalsO2CMember',
    'punctuation is dropped and the name becomes the key')
  check(memberCodeFor('Energy, Utilities, Resources and Services')
    === 'nse:EnergyUtilitiesResourcesAndServicesMember', 'and a long real name survives it')
  check(memberCodeFor('  ') === 'nse:UnnamedMember', 'an empty name still yields a usable code')
  check(yearStartFor('2024-03-31') === '2023-04-01', 'the year is the twelve months ending at the period end')
}

console.log(failures === 0 ? '\nALL NSE CHECKS PASSED' : `\n${failures} NSE CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
