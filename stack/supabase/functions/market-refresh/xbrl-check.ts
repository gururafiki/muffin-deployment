/**
 * Offline checks for the XBRL fact resolver. No network, no database.
 *
 * The resolver is where every XBRL subtlety lives, and every one of them fails SILENTLY — a wrong
 * choice yields a shorter series or a plausible-looking wrong number, never an error. So it is
 * driven over synthetic payloads shaped exactly like companyfacts.
 */
import { factsFromCompanyFacts, pickUnitKey, submissionsFrom, type ConceptSpec } from './xbrl.ts'

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


// 12. A YEAR-TO-DATE FACT TAGGED AS A QUARTER IS NOT A QUARTER. This is the defect that reached
//     production: XBRL Q2/Q3 duration facts are frequently 6- and 9-month YTD figures and still
//     carry `fp: "Q2"`. A filter that only rejected `days > 200` dropped the 9-month one and
//     ADMITTED the 6-month one, so AAPL's 2026-03-28 "quarter" was 254,940M against a full year of
//     416,161M — 61% of a year in one quarter, spiking the chart every Q2, invisible in every count.
{
  const payload = facts({ USD: [
    // A real discrete quarter: 91 days.
    { end: '2024-03-31', val: 25, fp: 'Q1', filed: '2024-05-01', start: '2024-01-01' },
    // The same filing's HALF-YEAR figure, also tagged Q2 — six months, and the one that got through.
    { end: '2024-06-30', val: 55, fp: 'Q2', filed: '2024-08-01', start: '2024-01-01' },
    // And the nine-month YTD, tagged Q3.
    { end: '2024-09-30', val: 90, fp: 'Q3', filed: '2024-11-01', start: '2024-01-01' },
    // A one-month stub period, also tagged as a quarter — a transition period after a fiscal-year
    // change. Without a LOWER bound this enters the series as a quarter a third of the right size,
    // which reads as a collapse rather than as a partial period.
    { end: '2024-12-31', val: 8, fp: 'Q4', filed: '2025-02-01', start: '2024-12-01' },
  ] })
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.periodType === 'quarter')
  check(out.length === 1 && out[0].value === 25,
    'a 6-month and a 9-month YTD fact tagged Q2/Q3 are both rejected from the quarterly series',
    `got ${JSON.stringify(out)}`)
}

// 13. AND A DISCRETE QUARTER STILL LANDS whatever its exact length. Fiscal quarters are not all 91
//     days — a 4-4-5 retail calendar gives 84 and 98 — so the band has to admit them or the fix
//     for the above becomes "we have no quarterly data".
{
  const payload = facts({ USD: [
    { end: '2024-03-30', val: 10, fp: 'Q1', filed: '2024-05-01', start: '2024-01-07' }, // 83 days
    { end: '2024-07-06', val: 12, fp: 'Q2', filed: '2024-08-01', start: '2024-03-31' }, // 97 days
  ] })
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.periodType === 'quarter')
  check(out.length === 2, 'an 83-day and a 97-day fiscal quarter both survive the band',
    `got ${JSON.stringify(out)}`)
}

// 14. A MULTI-YEAR FACT IS NOT AN ANNUAL ONE. Some filings carry cumulative or 2-year comparatives
//     with `fp: FY`; unbounded above, those enter the annual series as an enormous outlier.
{
  const payload = facts({ USD: [
    // THE CUMULATIVE ONE FIRST. Both share a key, priority and filing date, so the first survivor
    // wins — listed second it would be discarded by ordering rather than by the bound, and a
    // mutation removing the bound would pass clean.
    { end: '2024-12-31', val: 300, fp: 'FY', filed: '2025-02-01', start: '2022-01-01' },
    { end: '2024-12-31', val: 100, fp: 'FY', filed: '2025-02-01', start: '2024-01-01' },
  ] })
  const out = factsFromCompanyFacts(payload, SPECS).filter((f) => f.periodType === 'annual')
  check(out.length === 1 && out[0].value === 100,
    'a 3-year cumulative fact tagged FY is rejected from the annual series',
    `got ${JSON.stringify(out)}`)
}

// ── The submissions document, which is where the filing HISTORY and the SIC come from ─────────

// 15. TWO SHAPES. The main document nests its parallel arrays under `filings.recent`; an older
//     page is the same arrays at the TOP level with no wrapper. Reading only the first shape
//     returns nothing for every historical page, which is indistinguishable from a filer that has
//     never filed — and the historical pages are the entire point of using this endpoint.
{
  const nested = {
    sic: '3571', sicDescription: 'Electronic Computers',
    filings: {
      recent: {
        accessionNumber: ['0000320193-25-000079'], form: ['10-K'],
        filingDate: ['2025-10-31'], reportDate: ['2025-09-27'], isXBRL: [1],
      },
      files: [{ name: 'CIK0000320193-submissions-001.json' }],
    },
  }
  const a = submissionsFrom(nested, ['10-K', '10-Q'])
  check(a.filings.length === 1 && a.filings[0].accession === '0000320193-25-000079',
    'the nested `filings.recent` shape is read', JSON.stringify(a.filings))
  check(a.sic === '3571' && a.sicDescription === 'Electronic Computers',
    'the SIC rides along on the same response — no extra request for the classification')
  check(a.olderPages.length === 1, 'the older pages are reported so the walk can continue')

  const older = {
    accessionNumber: ['0001193125-14-383437'], form: ['10-K'],
    filingDate: ['2014-10-27'], reportDate: ['2014-09-27'], isXBRL: [1],
  }
  const b = submissionsFrom(older, ['10-K', '10-Q'])
  check(b.filings.length === 1 && b.filings[0].filingDate === '2014-10-27',
    'the FLAT older-page shape is read too', JSON.stringify(b.filings))
  check(b.olderPages.length === 0, 'an older page reports no further pages')
}

// 16. `isXBRL` IS 1/0, NOT true/false, AND THE COERCION MATTERS. `Boolean("0")` is TRUE, so a
//     string-truthiness read would mark every pre-2009 filing as carrying XBRL and send the
//     segment resource after two requests each to find a 404.
{
  const payload = {
    accessionNumber: ['a', 'b', 'c'], form: ['10-K', '10-K', '10-K'],
    filingDate: ['2020-01-01', '2005-01-01', '2006-01-01'],
    reportDate: [null, null, null], isXBRL: [1, 0, '0'],
  }
  const out = submissionsFrom(payload, ['10-K'])
  check(out.filings.length === 3, 'every matching form is returned')
  check(out.filings[0].isXbrl === true && out.filings[1].isXbrl === false && out.filings[2].isXbrl === false,
    'isXBRL is read numerically — "0" is NOT xbrl',
    JSON.stringify(out.filings.map((f) => f.isXbrl)))
  check(out.filings[0].reportDate === null, 'a null reportDate stays null rather than becoming ""')
}

// 17. FORMS ARE FILTERED, AND A FOREIGN PRIVATE ISSUER FILES DIFFERENT ONES. A filer's history is
//     dominated by Form 4s and 8-Ks; asking for the accounts forms is what keeps the walk cheap.
{
  const payload = {
    accessionNumber: ['a', 'b', 'c', 'd'], form: ['4', '8-K', '20-F', '10-Q'],
    filingDate: ['2024-01-01', '2024-01-02', '2024-01-03', '2024-01-04'],
    reportDate: [null, null, '2023-12-31', '2024-03-31'], isXBRL: [0, 0, 1, 1],
  }
  const out = submissionsFrom(payload, ['10-K', '10-Q', '20-F', '40-F'])
  check(out.filings.length === 2 && out.filings.every((f) => ['20-F', '10-Q'].includes(f.form)),
    'only the accounts forms are kept — a 20-F counts, a Form 4 does not',
    JSON.stringify(out.filings.map((f) => f.form)))
}

// 18. THE REGISTRANT'S OWN IDENTITY RIDES ON THE SAME RESPONSE, and two of its fields are traps.
{
  const payload = {
    cik: '0000320193', name: 'Apple Inc.', entityType: 'operating',
    sic: '3571', sicDescription: 'Electronic Computers',
    tickers: ['AAPL', 'APC'], exchanges: ['Nasdaq', 'Frankfurt'],
    ein: '942404110', lei: '', category: 'Large accelerated filer',
    fiscalYearEnd: '0926', stateOfIncorporation: 'CA',
    website: '', phone: '(408) 996-1010',
    addresses: {
      business: { street1: 'ONE APPLE PARK WAY', city: 'CUPERTINO', stateOrCountry: 'CA',
                  zipCode: '95014', stateOrCountryDescription: 'CA' },
      mailing: { street1: 'A LAWYERS OFFICE', city: 'NOWHERE' },
    },
    formerNames: [
      { name: 'APPLE COMPUTER INC', from: '1994-01-26T05:00:00.000Z', to: '2007-01-04T05:00:00.000Z' },
    ],
    filings: { recent: { accessionNumber: [], form: [], filingDate: [], reportDate: [], isXBRL: [] } },
  }
  const p = submissionsFrom(payload, ['10-K']).profile
  check(p.usTicker === 'AAPL' && p.usExchange === 'Nasdaq',
    'the US ticker and its exchange are read PAIRWISE from the first entry',
    `${p.usTicker}/${p.usExchange}`)
  // AN EMPTY STRING IS AN ABSENCE. SEC returns "" for a field it does not hold, and storing that
  // makes "no website" indistinguishable from "the website is the empty string" — the same defect
  // as rendering nasdaq's literal `not-supplied` to a reader.
  check(p.lei === null && p.website === null,
    'an empty string is stored as NULL, not as a value', `lei=${p.lei} website=${p.website}`)
  check(p.hqStreet === 'ONE APPLE PARK WAY' && p.hqCity === 'CUPERTINO',
    'the BUSINESS address is used, not the mailing one (often a registered agent)')
  check(p.formerNames.length === 1 && p.formerNames[0].from === '1994-01-26',
    'a former name keeps its dates, truncated to the DATE — a name change has no time of day',
    JSON.stringify(p.formerNames))
  check(p.fiscalYearEnd === '0926' && p.category === 'Large accelerated filer',
    'the fiscal year end and filer category are captured')
}

// 19. `000000000` IS SEC'S PLACEHOLDER FOR "NO EIN", NOT AN EIN. Measured on TSMC, a foreign
//     private issuer. It is exactly the shape of `<cusip>000000000</cusip>`, which this pipeline
//     once treated as an identifier and thereby collapsed Accenture, Seagate, TE Connectivity and
//     NXP into a SINGLE security with no error anywhere.
{
  const base = { filings: { recent: { accessionNumber: [], form: [], filingDate: [], reportDate: [], isXBRL: [] } } }
  check(submissionsFrom({ ...base, ein: '000000000' }, []).profile.ein === null,
    'a placeholder EIN is rejected rather than stored as an identifier')
  check(submissionsFrom({ ...base, ein: '942404110' }, []).profile.ein === '942404110',
    'a real EIN still comes through')
}

// 20. A FILER WITH NO US LISTING MUST NOT INVENT ONE. `tickers` is often absent entirely for a
//     shell or a fund, and `[0]` of nothing must be null rather than "undefined".
{
  const base = { filings: { recent: { accessionNumber: [], form: [], filingDate: [], reportDate: [], isXBRL: [] } } }
  const p = submissionsFrom(base, []).profile
  check(p.usTicker === null && p.usExchange === null,
    'no tickers array means no ticker, not a string', `${p.usTicker}`)
  check(p.formerNames.length === 0, 'no formerNames array means an empty list')
}

console.log(failures === 0 ? '\nALL XBRL CHECKS PASSED' : `\n${failures} XBRL CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
