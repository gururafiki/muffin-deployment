/**
 * Offline checks for candidate symbol generation. No network, no database.
 *
 * The whole design rests on candidates being VERIFIED before adoption, so these assert two things:
 * that the known-good spellings are among the candidates, and that a working symbol is never
 * silently turned into a different one.
 */
import { candidateSymbols } from './symbol-repair.ts'

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

console.log('candidate symbols')

// 1. THE MEASURED PAIRS. Each left-hand spelling returns 0 bars from the provider and each
//    right-hand one returns 190 — so the candidate list must contain the right-hand one or the
//    security stays invisible.
for (const [bad, good] of [
  ['ATCOA.ST', 'ATCO-A.ST'],
  ['6.HK', '0006.HK'],
  ['BRK/B', 'BRK-B'],
  ['WALMEX*.MX', 'WALMEX.MX'],
  ['RR/.L', 'RR.L'],
] as const) {
  const cands = candidateSymbols(bad)
  check(cands.includes(good), `${bad} offers ${good}`, `got ${JSON.stringify(cands)}`)
}

// 2. A SYMBOL IS NEVER ITS OWN CANDIDATE. The caller adopts the first candidate that answers, so
//    including the original would mean "repairing" a symbol to itself and clearing its caches for
//    no reason, every run, for ever.
for (const s of ['AAPL', 'SAND.ST', '0700.HK', 'SAP.DE']) {
  check(!candidateSymbols(s).includes(s), `${s} is not its own candidate`)
}

// 3. A WORKING SYMBOL WITH NO REPAIRABLE SHAPE OFFERS NOTHING. `AAPL` and `SAP.DE` have no star,
//    no slash, no short HK number and no Nordic class letter — generating candidates for them
//    would spend a provider call per security on the entire universe.
for (const s of ['AAPL', 'SAP.DE', '7203.T', '005930.KS']) {
  check(candidateSymbols(s).length === 0, `${s} generates no candidates`,
    `got ${JSON.stringify(candidateSymbols(s))}`)
}

// 4. AND THE DANGEROUS CASE, STATED EXPLICITLY. `SAND.ST` is Sandvik — a complete company name
//    ending in D, not a class share. The pattern DOES match it, so a candidate IS generated; what
//    makes that safe is that `SAN-D.ST` will not answer and is therefore never adopted. This
//    asserts the candidate is merely offered, not that the rule is clever.
{
  const cands = candidateSymbols('SAND.ST')
  check(cands.includes('SAN-D.ST'),
    'SAND.ST does generate SAN-D.ST — the rule cannot tell a name from a class, which is why adoption requires the provider to answer',
    `got ${JSON.stringify(cands)}`)
  check(!cands.includes('SAND.ST'), 'and it never offers the original back')
}

console.log(failures === 0 ? '\nALL SYMBOL-REPAIR CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
