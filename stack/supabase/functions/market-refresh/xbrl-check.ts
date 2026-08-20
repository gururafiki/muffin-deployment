/**
 * Offline checks for the XBRL fact resolver. No network, no database.
 *
 * The resolver is where every XBRL subtlety lives, and every one of them fails SILENTLY — a wrong
 * choice yields a shorter series or a plausible-looking wrong number, never an error. So it is
 * driven over synthetic payloads shaped exactly like companyfacts.
 */
import { factsFromCompanyFacts, pickUnitKey, type ConceptSpec } from './xbrl.ts'

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

const SPECS: ConceptSpec[] = [
  { metricCode: 'revenue', concept: 'RevenueFromContractWithCustomerExcludingAssessedTax', priority: 100, unit: 'USD', taxonomy: 'us-gaap' },
  { metricCode: 'revenue', concept: 'Revenues', priority: 80, unit: 'USD', taxonomy: 'us-gaap' },
  { metricCode: 'shares_basic', concept: 'WeightedAverageNumberOfSharesOutstandingBasic', priority: 100, unit: 'shares', taxonomy: 'us-gaap' },
  // The IFRS spelling of the same metric. A foreign private issuer's companyfacts has NO us-gaap
  // node at all, so without this the filer yields nothing and is marked absent for 30 days.
  { metricCode: 'revenue', concept: 'Revenue', priority: 100, unit: 'USD', taxonomy: 'ifrs-full' },
]

const facts = (units: Record<string, unknown[]>, concept = 'Revenues') => ({
  facts: { 'us-gaap': { [concept]: { units } } },
})

console.log('xbrl fact resolution')

// 1. PER-PERIOD RESOLUTION. Caterpillar reports one concept for its early years and another
//    afterwards. Choosing per COMPANY — "the first concept with any data" — returns a series
//    covering three years of seventeen, which reads as a company that stopped reporting.
{
  const payload = {
    facts: {
      'us-gaap': {
        Revenues: { units: { USD: [
          { end: '2010-12-31', val: 10, fp: 'FY', filed: '2011-02-01', start: '2010-01-01' },
        ] } },
        RevenueFromContractWithCustomerExcludingAssessedTax: { units: { USD: [
          { end: '2020-12-31', val: 50, fp: 'FY', filed: '2021-02-01', start: '2020-01-01' },
        ] } },
      },
    },
  }
  const out = factsFromCompanyFacts(payload, SPECS)
  const years = out.filter((f) => f.metricCode === 'revenue').map((f) => f.periodEnding).sort()
  check(
    years.length === 2 && years[0] === '2010-12-31' && years[1] === '2020-12-31',
    'a company that switches concepts keeps ONE continuous series',
    `got ${JSON.stringify(years)}`,
  )
}

// 2. WITHIN A PERIOD, PRIORITY WINS. Both concepts cover 2020; the catalogue says which is the
//    company's revenue line, and the answer must not depend on object key order.
{
  const payload = {
    facts: {
      'us-gaap': {
        Revenues: { units: { USD: [
          { end: '2020-12-31', val: 999, fp: 'FY', filed: '2021-02-01', start: '2020-01-01' },
        ] } },
        RevenueFromContractWithCustomerExcludingAssessedTax: { units: { USD: [
          { end: '2020-12-31', val: 50, fp: 'FY', filed: '2021-02-01', start: '2020-01-01' },
        ] } },
      },
    },
  }
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.metricCode === 'revenue')
  check(out.length === 1 && out[0].value === 50,
    'the higher-priority concept wins within a period', `got ${JSON.stringify(out)}`)
}

// 3. THE LATEST FILING WINS within one concept. A period is repeated by later filings and
//    restated by amendments; the newest is the company's current answer.
{
  const payload = facts({ USD: [
    { end: '2020-12-31', val: 10, fp: 'FY', filed: '2021-02-01', start: '2020-01-01' },
    { end: '2020-12-31', val: 12, fp: 'FY', filed: '2022-02-01', start: '2020-01-01' },
  ] })
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.metricCode === 'revenue')
  check(out.length === 1 && out[0].value === 12,
    'a restated period takes the value from the latest filing', `got ${JSON.stringify(out)}`)
}

// 4. A DURATION FACT MUST MATCH ITS LABEL. A 10-K carries quarterly comparatives, and a
//    three-month revenue landing in the annual series reads as a ~75% collapse — a plausible
//    number in the right shape, which is the worst kind of wrong.
{
  const payload = facts({ USD: [
    { end: '2020-12-31', val: 100, fp: 'FY', filed: '2021-02-01', start: '2020-01-01' },
    { end: '2020-12-31', val: 25, fp: 'FY', filed: '2021-02-01', start: '2020-10-01' },
  ] })
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.metricCode === 'revenue')
  check(out.length === 1 && out[0].value === 100,
    'a 3-month fact tagged FY is rejected from the annual series', `got ${JSON.stringify(out)}`)
}

// 5. AND THE CONVERSE: a twelve-month fact must not land in the quarterly series.
{
  const payload = facts({ USD: [
    { end: '2020-12-31', val: 100, fp: 'Q3', filed: '2021-02-01', start: '2020-01-01' },
  ] })
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.metricCode === 'revenue')
  check(out.length === 0, 'a 12-month fact tagged Q3 is rejected from the quarterly series',
    `got ${JSON.stringify(out)}`)
}

// 6. AN INSTANT FACT HAS NO START and must still be classified. A balance sheet cannot be
//    measured by duration, so `fp` is the only signal — rejecting it for lack of `start` would
//    drop every balance-sheet metric.
{
  const payload = facts({ USD: [
    { end: '2020-12-31', val: 500, fp: 'FY', filed: '2021-02-01' },
    { end: '2020-09-30', val: 480, fp: 'Q3', filed: '2020-11-01' },
  ] })
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.metricCode === 'revenue')
  const types = out.map((f) => f.periodType).sort()
  check(out.length === 2 && types[0] === 'annual' && types[1] === 'quarter',
    'instant facts (no start date) are classified by fp, not discarded',
    `got ${JSON.stringify(out)}`)
}

// 7. A SHARE COUNT CARRIES NO CURRENCY. Money must carry its currency; a count that claims one
//    would be formatted as money, which is how a share count renders as "$16.4B".
{
  const payload = {
    facts: { 'us-gaap': { WeightedAverageNumberOfSharesOutstandingBasic: { units: {
      shares: [{ end: '2020-12-31', val: 16_400_000_000, fp: 'FY', filed: '2021-02-01', start: '2020-01-01' }],
    } } } },
  }
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.metricCode === 'shares_basic')
  check(out.length === 1 && out[0].currency === null,
    'a share count carries no currency', `got ${JSON.stringify(out)}`)
}

// 8. A FILER WITH NONE OF THE CATALOGUED CONCEPTS YIELDS NOTHING, rather than throwing. It is an
//    ordinary outcome — the resource records that it asked and moves on.
{
  const payload = { facts: { 'us-gaap': { SomethingElseEntirely: { units: { USD: [
    { end: '2020-12-31', val: 1, fp: 'FY', filed: '2021-02-01' },
  ] } } } } }
  check(factsFromCompanyFacts(payload, SPECS).length === 0,
    'an uncatalogued filer yields no facts and no exception')
  check(factsFromCompanyFacts({}, SPECS).length === 0, 'an empty payload yields no facts')
  check(factsFromCompanyFacts(null, SPECS).length === 0, 'a null payload yields no facts')
}


// 9. AN IFRS FILER IS READ AT ALL. The first real run returned `noFacts: 10` of 20 filers, every
//    one a foreign private issuer — AB InBev's companyfacts has only `['dei', 'ifrs-full']`, with
//    no us-gaap node. Reading one taxonomy marks them absent for 30 days, silently.
{
  const payload = {
    facts: { 'ifrs-full': { Revenue: { units: { EUR: [
      { end: '2024-12-31', val: 22300, fp: 'FY', filed: '2025-02-01', start: '2024-01-01' },
    ] } } } },
  }
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.metricCode === 'revenue')
  check(out.length === 1 && out[0].value === 22300,
    'an IFRS filer with no us-gaap node still yields facts', `got ${JSON.stringify(out)}`)
  // 10. AND THE UNIT KEY IS THE REPORTING CURRENCY. Novo Nordisk files in DKK and Nokia in EUR;
  //     labelling either "USD" is the Alibaba bug with a different company.
  check(out.length === 1 && out[0].currency === 'EUR',
    "the reporting currency comes from the unit key, not a constant", `got ${JSON.stringify(out)}`)
}

// 11. A FILER PUBLISHING TWO CURRENCIES PICKS ITS PRIMARY. TSMC reports in TWD and USD, the second
//     a convenience translation with less history. Most data points wins; picking USD by habit
//     would relabel the primary series.
{
  // USD FIRST on purpose. With the primary currency listed first, "most data points wins" and
  // "the first key wins" give the same answer and a mutation swapping them passes clean — the
  // convenience translation has to come first for the two rules to disagree.
  const units = {
    USD: [1, 2],
    TWD: [1, 2, 3, 4, 5],
  } as Record<string, unknown>
  check(pickUnitKey(units, 'USD') === 'TWD',
    'the currency with the most data points is the primary reporting currency',
    `got ${pickUnitKey(units, 'USD')}`)
  check(pickUnitKey({ shares: [1] }, 'shares') === 'shares', 'a share count finds its own unit key')
  check(pickUnitKey({ 'DKK/shares': [1] }, 'USD/shares') === 'DKK/shares',
    'a per-share figure is found in the filer\'s own currency')
  check(pickUnitKey({ pure: [1], TWD: [1] }, 'shares') === null,
    'a non-currency unit is not mistaken for one')
}

console.log(failures === 0 ? '\nALL XBRL CHECKS PASSED' : `\n${failures} XBRL CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
