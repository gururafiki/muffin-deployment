// Verification for the EDGAR client. Hits LIVE SEC and needs nothing else — no database, no
// OpenBB, no credentials (just a User-Agent, which SEC requires).
//
//   docker run --rm --network host -v "$PWD:/w" -w /w \
//     -e SEC_USER_AGENT="muffin-market-data/1.0 (you@example.com)" \
//     denoland/deno:alpine run --allow-net --allow-env \
//     stack/supabase/functions/market-refresh/edgar-check.ts
//
// WHY: the failure modes here are silent. Reading <isin> as element TEXT returns empty for every
// holding (the value is an ATTRIBUTE), and matching the wrong series returns a real filing full of
// the wrong fund's holdings — both look like success.
import { fetchFundHoldings, loadFundDirectory, parseHoldings } from './edgar.ts'

let f = 0
const check = (l: string, ok: boolean, d = '') => { if (!ok) f++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${l}${d ? ` — ${d}` : ''}`) }

console.log('fund directory')
const dir = await loadFundDirectory()
check('directory loaded', dir.size > 10000, `${dir.size} fund tickers`)
for (const s of ['XLK', 'EWJ', 'IVV', 'MCHI']) {
  const r = dir.get(s)
  check(`${s} resolves to a series`, !!r?.seriesId?.startsWith('S'),
    r ? `cik=${r.cik} series=${r.seriesId}` : 'missing')
}
// EWJ and EWG share a CIK: proof that the CIK alone cannot identify a fund.
check('one CIK covers many funds — series is the key',
  dir.get('EWJ')?.cik === dir.get('EWG')?.cik && dir.get('EWJ')?.seriesId !== dir.get('EWG')?.seriesId)

console.log('\nXLK holdings via N-PORT')
const res = await fetchFundHoldings(dir.get('XLK')!)
if (!res) { console.log('  FAIL  no filing found'); Deno.exit(1) }
const h = res.holdings
check('filing found', !!res.filing.accession, `${res.filing.accession} report=${res.filing.reportDate}`)
check('holdings parsed', h.length > 20, `${h.length} holdings`)
check('CUSIPs present', h.filter((x) => x.cusip).length > h.length * 0.8)
check('ISINs present (attribute parsing works)', h.filter((x) => x.isin).length > 0,
  `${h.filter((x) => x.isin).length}/${h.length}`)
const sum = h.reduce((a, x) => a + (x.weight ?? 0), 0)
check('weights sum to ~100%', sum > 95 && sum < 105, `${sum.toFixed(2)}%`)
// The series-matching guard: XLK is the technology fund, so these must be in it.
check('it is the RIGHT fund', /APPLE|MICROSOFT|NVIDIA/.test(h.map((x) => x.name.toUpperCase()).join('|')))
check('countries present', h.filter((x) => x.country).length > 0)

console.log('\nparser edge cases')
check('empty input yields nothing', parseHoldings('<x/>').length === 0)
check('a block without a name is skipped', parseHoldings('<invstOrSec><cusip>1</cusip></invstOrSec>').length === 0)
check('N/A is treated as absent', parseHoldings('<invstOrSec><name>X</name><lei>N/A</lei></invstOrSec>')[0].lei === undefined)

console.log(f === 0 ? '\nOK' : `\n${f} FAILED`)
Deno.exit(f ? 1 : 0)
