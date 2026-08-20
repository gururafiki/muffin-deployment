/**
 * Offline checks for `fetchWithIsolation`. No network — the fetcher is a stub.
 *
 * This helper decides whether a security may be recorded as unanswerable, and getting it wrong has
 * cost this pipeline 1,369 negative-cached securities once already. The two failure directions are
 * opposite and both silent: too eager and a rate limit is written down as thousands of dead
 * companies; too cautious and a backlog stalls for ever on a batch it refuses to judge.
 */
import { fetchWithIsolation } from './resources.ts'

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

/** A fetcher driven by a map of symbol -> behaviour. `path` carries the symbols as `a,b,c`. */
function stub(behaviour: Record<string, 'rows' | 'empty' | 'throw'>) {
  const calls: string[][] = []
  const fn = async (path: string): Promise<Record<string, unknown>[]> => {
    const syms = path.split('=')[1].split(',')
    calls.push(syms)
    const out: Record<string, unknown>[] = []
    for (const s of syms) {
      const b = behaviour[s] ?? 'empty'
      if (b === 'throw') throw new Error(`provider 400 on ${s}`)
      if (b === 'rows') out.push({ symbol: s })
    }
    return out
  }
  return { fn, calls }
}

const build = (syms: string[]) => `/x?symbol=${syms.join(',')}`
const far = () => Date.now() + 60_000

console.log('fetchWithIsolation')

// 1. THE HAPPY PATH stays one call. Isolation is for batches that produced nothing.
{
  const { fn, calls } = stub({ A: 'rows', B: 'rows' })
  const r = await fetchWithIsolation(fn, build, ['A', 'B'], 5_000, far(), 'CTRL')
  check(r.rows.length === 2 && r.dead.length === 0 && r.error === null && calls.length === 1,
    'a batch that answers is returned as-is, in one call', `calls=${calls.length}`)
}

// 2. A 200 WITH NO ROWS IS ISOLATED. This is the case that stalled `security-price-history`: the
//    batch does not throw, so nothing was ever isolated, nothing marked, and the same symbols
//    returned every run for ever.
{
  const { fn } = stub({ A: 'empty', B: 'empty', CTRL: 'rows' })
  const r = await fetchWithIsolation(fn, build, ['A', 'B'], 5_000, far(), 'CTRL')
  check(r.dead.sort().join(',') === 'A,B',
    'a batch that answers with NO ROWS is isolated and its symbols reported dead',
    `dead=${JSON.stringify(r.dead)}`)
}

// 3. THE CONTROL DECIDES. Same empty batch, but the provider is down — nothing may be marked, or a
//    rate limit becomes thousands of permanently dead companies.
{
  const { fn } = stub({ A: 'empty', B: 'empty', CTRL: 'empty' })
  const r = await fetchWithIsolation(fn, build, ['A', 'B'], 5_000, far(), 'CTRL')
  check(r.dead.length === 0, 'when the control does NOT answer, no symbol is blamed',
    `dead=${JSON.stringify(r.dead)}`)
  check((r.error ?? '').includes('outage'), 'and the reason says outage', r.error ?? '')
}

// 4. A GENUINELY BAD SYMBOL among good ones is isolated without a control probe being decisive:
//    something answered, so the provider is plainly up.
{
  const { fn } = stub({ A: 'rows', B: 'throw', CTRL: 'rows' })
  const r = await fetchWithIsolation(fn, build, ['A', 'B'], 5_000, far(), 'CTRL')
  check(r.dead.join(',') === 'B' && r.rows.length === 1,
    'one bad symbol among good ones is isolated and the rest survive',
    `dead=${JSON.stringify(r.dead)} rows=${r.rows.length}`)
}

// 5. A THROTTLE IS NAMED BY THE PROVIDER and short-circuits before any of this. The message is
//    evidence; the counts are inference.
{
  const fn = async (): Promise<Record<string, unknown>[]> => {
    throw new Error('YFRateLimitError: Too Many Requests')
  }
  const r = await fetchWithIsolation(fn, build, ['A', 'B'], 5_000, far(), 'CTRL')
  check(r.dead.length === 0 && (r.error ?? '').includes('RATE-LIMITING'),
    'a stated rate limit blames no symbol', r.error ?? '')
}

// 6. A SINGLE-SYMBOL BATCH IS NOT ISOLATED — there is nothing to isolate it from, and re-asking
//    the same symbol alone would double every call for no information.
{
  const { fn, calls } = stub({ A: 'empty', CTRL: 'rows' })
  const r = await fetchWithIsolation(fn, build, ['A'], 5_000, far(), 'CTRL')
  check(calls.length === 1 && r.dead.length === 0,
    'a one-symbol batch is returned directly rather than re-probed', `calls=${calls.length}`)
}

// 7. NO CONTROL MEANS NO EVIDENCE, so nothing may be marked. The caller can opt out of the probe;
//    what it cannot do is get a verdict without one. Without this case `control` is always truthy
//    in these fixtures and deleting the check is undetectable.
{
  const { fn, calls } = stub({ A: 'empty', B: 'empty', CTRL: 'rows' })
  const r = await fetchWithIsolation(fn, build, ['A', 'B'], 5_000, far(), null)
  check(r.dead.length === 0,
    'with no control symbol, an all-empty batch blames nobody — there is no evidence either way',
    `dead=${JSON.stringify(r.dead)}`)
  // ON THE CALL COUNT, because `dead` alone cannot see it: dropping the `control &&` guard makes
  // the code probe the literal string "null", which answers nothing and falls through to the same
  // verdict. One batch call plus two per-symbol probes, and nothing else.
  check(calls.length === 3, 'and it does not probe a control it was told not to use',
    `calls=${calls.length}: ${JSON.stringify(calls)}`)
}

// 8. OUT OF BUDGET MARKS NOTHING, AND DOES NOT EVEN ASK. A symbol we never got to is not a symbol
//    without data. Asserted on the CALL COUNT, not just on `dead`: with the deadline guard removed
//    the per-symbol probes still run and the control probe is skipped for the same lack of budget,
//    so `dead` comes back empty either way and the guard looks fine while doing the opposite.
{
  const { fn, calls } = stub({ A: 'empty', B: 'empty', CTRL: 'rows' })
  const r = await fetchWithIsolation(fn, build, ['A', 'B'], 5_000, Date.now() + 500, 'CTRL')
  check(r.dead.length === 0, 'a deadline reached before probing marks nothing',
    `dead=${JSON.stringify(r.dead)}`)
  check(calls.length === 1, 'and it does not spend calls it has no budget for',
    `calls=${calls.length}`)
}

console.log(failures === 0 ? '\nALL ISOLATION CHECKS PASSED' : `\n${failures} ISOLATION CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
