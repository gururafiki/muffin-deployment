// The market-refresh logic that can be checked with NO network and NO database.
//
// WHY THIS EXISTS SEPARATELY FROM `check.ts`. That file drives a real openbb-api, so it cannot run
// in CI and only runs when someone remembers to. Everything here is pure, so it runs on every PR —
// which is the difference between a rule that holds and a rule that held once.
//
// Every assertion below is a defect that REACHED PRODUCTION and returned HTTP 200 while doing so.
// None of them would have been caught by a floor, a count, or an error handler.
//
//   deno run stack/supabase/functions/market-refresh/logic-check.ts

import {
  dedupeBy,
  extractMacroPoints,
  fetchWithIsolation,
  symbolList,
} from './resources.ts'

// WHERE THE MIGRATION HISTORY LIVES, IN ONE PLACE.
//
// `migrations/` holds the BASELINE (Supabase's `<timestamp>_name.sql` convention) and anything
// generated since; `migrations-legacy/` holds the 204 historical files, retired from the deploy but
// still the only place a seed is written as TEXT — the baseline carries the same rows as a pg_dump
// COPY block, which no grep for an `insert into` can match.
//
// ONE DEFINITION BECAUSE THREE SEPARATE READERS EXISTED AND I FIXED ONE. The data_source seed check
// built its own `migText` in a different scope and reported `0 seeds found` while the checks above
// it were reading both directories perfectly — the "six call sites, four spellings" shape this repo
// keeps meeting. A shared helper is the only version that cannot drift.
const MIGRATION_DIRS = [
  new URL('../../migrations/', import.meta.url),
  new URL('../../migrations-legacy/', import.meta.url),
]

async function* migrationSql(): AsyncGenerator<string> {
  for (const dir of MIGRATION_DIRS) {
    for await (const entry of Deno.readDir(dir)) {
      if (!entry.isFile || !entry.name.endsWith('.sql')) continue
      yield await Deno.readTextFile(new URL(entry.name, dir))
    }
  }
}

let failures = 0
const check = (ok: boolean, label: string, detail = '') => {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

// ── symbols are not URL-safe ─────────────────────────────────────────────────
// Shipped: `BRK/B` 400s and takes its whole batch of 20 with it; `PE&OLES*.MX` unencoded ENDS the
// symbol parameter and silently truncates the request, which still returns 200.
console.log('\nsymbolList — real tickers are not URL-safe')
check(symbolList(['AAPL', 'MSFT']) === 'AAPL,MSFT', 'ordinary symbols are untouched')
check(symbolList(['BRK/B']) === 'BRK%2FB', 'a slash is encoded (it 400s the whole batch raw)')
check(symbolList(['PE&OLES*.MX']).indexOf('&') === -1,
  'an ampersand cannot terminate the parameter', symbolList(['PE&OLES*.MX']))
check(symbolList(['A', 'B']).split(',').length === 2, 'the comma SEPARATOR stays literal')
check(symbolList(['NESN.SW']) === 'NESN.SW', 'a dot suffix is not mangled')
check(symbolList(['005930.KS', 'BP/.L']) === '005930.KS,BP%2F.L',
  'a mixed batch encodes only what needs it')

// ── the same conflict key twice fails the WHOLE statement ────────────────────
// Shipped: `security-industries` returned a bare 502 on any page big enough to contain a security
// classified into two sectors. Postgres refuses `ON CONFLICT DO UPDATE` when one statement carries
// the same key twice (SQLSTATE 21000) — it fails the batch, not the row. Third occurrence of this
// shape in the pipeline: fund holdings and the sector views both had to dedupe already.
console.log('\ndedupeBy — one row per conflict key')
{
  const writes = [
    { security_id: 'a', node_id: 'n1', source_code: 'yfinance', v: 1 },
    { security_id: 'a', node_id: 'n1', source_code: 'yfinance', v: 2 },
    { security_id: 'b', node_id: 'n1', source_code: 'yfinance', v: 3 },
  ]
  const out = dedupeBy(writes, (w) => `${w.security_id}|${w.node_id}|${w.source_code}`)
  check(out.length === 2, 'a repeated conflict key collapses to one row', `got ${out.length}`)
  check(out.find((w) => w.security_id === 'a')?.v === 2, 'last write wins')
  check(dedupeBy([], (x: { id: string }) => x.id).length === 0, 'an empty list stays empty')
  const keys = out.map((w) => `${w.security_id}|${w.node_id}|${w.source_code}`)
  check(new Set(keys).size === keys.length, 'no duplicate key survives — the actual DB constraint')
}

// ── one dead symbol must not kill nineteen good ones ─────────────────────────
// The most repeated failure in this pipeline: group-performance on FM, security-profiles on foreign
// listings, and security-industries on the Bloomberg spellings that 400 even once encoded. Because
// the backlog is ordered by fund weight, that batch sat at the head of EVERY run.
console.log('\nfetchWithIsolation — a bad symbol costs only itself')
{
  const far = Date.now() + 60_000
  const path = (syms: string[]) => `/p?symbol=${syms.join(',')}`

  // The healthy case must cost exactly ONE call — isolation is for failures only.
  let calls = 0
  const ok = await fetchWithIsolation(
    async (_p) => { calls++; return [{ symbol: 'A' }, { symbol: 'B' }] },
    path, ['A', 'B'], 5_000, far,
  )
  check(calls === 1, 'a healthy batch makes exactly one request', `made ${calls}`)
  check(ok.rows.length === 2 && ok.dead.length === 0 && ok.error === null, 'and reports no failure')

  // One poison symbol: the other nineteen must still come back, and only the bad one is blamed.
  const bad = 'BRK/B'
  const isolated = await fetchWithIsolation(
    async (p: string) => {
      if (p.includes(encodeURIComponent(bad)) || p.includes(bad)) throw new Error('openbb 400')
      return [{ symbol: p.split('=')[1] }]
    },
    (syms) => `/p?symbol=${symbolList(syms)}`,
    ['GOOD1', bad, 'GOOD2'], 5_000, far,
  )
  check(isolated.rows.length === 2, 'the good symbols still return', `got ${isolated.rows.length}`)
  check(isolated.dead.length === 1 && isolated.dead[0] === bad,
    'only the failing symbol is marked dead', JSON.stringify(isolated.dead))
  check(isolated.error !== null, 'the original batch error is still reported')

  // EVERY symbol failing is an OUTAGE, not twenty bad symbols. Draining aggressively tripped
  // yfinance's rate limit and this negative-cached 1,369 securities for 30 days — including HTHT
  // and LEGN, ordinary Nasdaq tickers — while reporting `classified: 0, noIndustry: 200`, which
  // reads as healthy progress.
  const outage = await fetchWithIsolation(
    async () => { throw new Error('openbb 400') },
    path, ['A', 'B', 'C'], 5_000, far,
  )
  check(outage.dead.length === 0,
    'when NOTHING answers, no symbol is blamed', JSON.stringify(outage.dead))
  check((outage.error ?? '').includes('provider outage'),
    'and the reason says so, so the tally is not read as progress')

  // A THROTTLE IS STATED, NOT INFERRED — and it is the case the count rule cannot see.
  //
  // The count rule only fires when NOTHING in a batch answers. yfinance throttles progressively, so
  // it refuses some symbols while answering others: `rows.length > 0`, the rule stays silent, and
  // the refused ones are recorded as permanently unanswerable. Caused deliberately 2026-08-13 by
  // draining six resources back to back — the message said `YFRateLimitError: Too Many Requests`
  // the whole time and nothing was reading it, which is how this costs 1,369 negative-cached
  // securities while every count looks like healthy progress.
  const RATE_LIMITED =
    'openbb 400: {"detail":"Error getting data for WK -> YFRateLimitError: Too Many Requests."}'
  const partialThrottle = await fetchWithIsolation(
    async (p: string) => {
      // The BATCH carries the rate-limit message — that is how the provider actually reports it,
      // measured: `openbb 400 on …symbol=GPGI,ITGR,CNK,…: {"detail":"… -> YFRateLimitError …"}`.
      // Isolation then retries one at a time and some still get through, which is what makes the
      // count rule blind to this: `rows.length > 0`, so it never fires.
      if (p.includes(',')) throw new Error(RATE_LIMITED)
      if (p.includes('GOOD')) return [{ symbol: 'GOOD' }]
      throw new Error(RATE_LIMITED)
    },
    path, ['GOOD', 'RATELIMITED'], 5_000, far,
  )
  check(partialThrottle.dead.length === 0,
    'a rate-limited symbol is NOT blamed even when others answered',
    JSON.stringify(partialThrottle.dead))
  check((partialThrottle.error ?? '').includes('RATE-LIMITING'),
    'and the reason names the rate limit, not the symbol')
  check(partialThrottle.rows.length === 1, 'while the symbols that did answer are kept')

  // Out of budget: untried symbols must NOT be recorded as unanswerable. Negative-caching a symbol
  // we never asked about is how a backlog loses work permanently.
  const expired = await fetchWithIsolation(
    async () => { throw new Error('openbb 400') },
    path, ['A', 'B', 'C'], 5_000, Date.now() - 1,
  )
  check(expired.dead.length === 0, 'a blown deadline blames nobody', JSON.stringify(expired.dead))
}

// ── every resource the cron calls must be one the function ACCEPTS ───────────
// Adding a resource means touching TWO places: the handler block, and the `EXTRA` allow-list the
// request is validated against. Shipped 2026-08-12 with only the first — the handler was there, the
// migration was there, the warm-up cron called it, and the function answered
// `unknown resource 'security-yahoo-symbols'` with a 400. Nothing caught it: the constant IS
// referenced (by the guard), so `deno check` is happy, and no test connects the two lists.
//
// Read as TEXT on purpose. The names live in three files that cannot import each other — a YAML
// workflow, a Deno handler and a shell loop — so the only thing they share is the string.
// ── a throw and an empty answer must not share a branch ──────────────────────
// FIFTH instance of this shape, which is why it is asserted against the SOURCE rather than left to
// review: `figi_missing_at`, `security-fundamentals`, `security-industries`, the isolation
// empty-branch, and then `security-profiles` — where the two were merged behind a comment claiming
// they were "indistinguishable". They never are: the throw sets a flag, and OpenBB answers 204 NO
// CONTENT when a provider genuinely has nothing.
//
// Merging them costs a backlog. An unanswerable batch is counted failed AND skips its
// negative-cache write, so it returns every run forever; then the "all batches failed" guard fails
// the whole resource at exactly the moment the answerable work is done. Measured 2026-08-13:
// `pending_profile` fell 2,665 -> 2,437 and froze, while three sibling resources on the SAME
// endpoint reported ok.
//
// A behavioural test cannot reach this — the decision is inline in a 200-line resource handler with
// a live Supabase client. The shape is what recurs, so the shape is what is checked.
console.log('\nbatch outcomes — a failure and an empty answer are different branches')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  // `somethingFailed || rows.length === 0` — a throw flag OR'd with an empty result.
  const merged = [...index.matchAll(/\w*[Ff]ailed\s*\|\|\s*\w+\.length === 0/g)].map((m) => m[0])
  check(merged.length === 0,
    'no branch ORs a failure flag with an empty result',
    merged.length ? merged.join('; ') : 'none')
}

// ── marking on an empty answer must be EARNED ────────────────────────────────
// An empty answer is a legitimate "no data for these" — until the endpoint stops answering at all,
// when it becomes "no data for anyone" and the same branch records a provider hiccup as hundreds of
// permanently unanswerable securities.
//
// Measured 2026-08-13: draining hard enough to trip yfinance's rate limit made it return
// 200-with-no-rows instead of erroring, so `fetchWithIsolation`'s outage rule — which only sees
// THROWS — never fired, and `security-industries` marked 1,414 securities as having no industry.
// Among them INTC, PEP, XOM, TXN, EA and SCCO. The backlog went to zero and looked drained.
//
// So every `rows.length === 0` branch that writes a `*_missing_at` must gate on a success counter
// proving the endpoint answered for someone in this run. Checked against the source because there
// are three such branches in three different resources and the last two rounds of this were fixed
// one call site at a time.
console.log('\nempty-answer marking — gated on the endpoint having answered')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))

  // WHY A LIST OF EXACT GATES rather than an analysis of the branches.
  //
  // The first version of this check walked from each `… .length === 0` branch to its closing brace
  // and asked whether a gate appeared inside. It caught ONE of four deleted gates when tested by
  // mutation: brace depth counted braces in comments and template literals too, so most blocks
  // ended early and the write fell outside the window — the check reported "all six marking sites
  // gated" while three were not. It would have shipped as protection while protecting nothing,
  // which is the failure mode this whole file exists to prevent.
  //
  // A named list is brittle to refactoring and that is the acceptable trade: rewording a gate fails
  // here loudly and the list gets updated, whereas DELETING one — the thing that costs thousands of
  // securities — can never pass silently.
  //
  // Each entry is a site where a batch that produced nothing writes a `*_missing_at`, and the
  // string is the proof that the endpoint answered for someone in this run.
  const gates: [string, string][] = [
    ['security-statements',   'anyAnswer || (failed === 0 && written > 0)'],
    ['security-quarters',     'asked && anyAnswer'],
    // Marks only what isolation proved dead ALONE — never absence from a batched 200.
    // `iso.dead` IS the gate: fetchWithIsolation only populates it after asking each symbol alone
    // AND proving the provider is up with a control symbol. A run-level tally on top can never fire
    // once a backlog's answerable head has drained — measured, five identical stalled runs.
    ['security-profile-detail', 'iso.dead.length > 0'],
    ['security-industries',   'stillUnrecorded.length > 0 && classified > 0'],
    ['security-profiles',     'if (classified > 0) {'],
    ['security-fundamentals', 'if (written > 0) {'],
  ]
  for (const [resource, gate] of gates) {
    check(index.includes(gate), `${resource} still gates its empty-answer marking`, gate)
  }

  // PAGING MUST BE A PARTITION, NOT FOUR SAMPLES. Both multi-page backlog reads order by
  // `best_weight`, which is 0 for every security no tracked fund holds — most of the rows. Postgres
  // gives no stable order among ties, so successive `range()` calls can return one row twice and
  // another never. Found 2026-08-14 by making the same mistake in an audit query: paging
  // `security_current` without an order reported 1,935 duplicated company names and repeated ISINs,
  // all of which vanished under `order=security_id` — 12,000 rows, 12,000 distinct ids, 0 repeats.
  // The data was fine; the query was not. The resources had the same shape.
  // AN EARLY RETURN AFTER THE CLAIM MUST GIVE IT BACK. `begin_refresh` takes the lock before any
  // per-resource validation runs, so a `return json({error}, 400)` below it leaves `refresh_log`
  // with `finished_at: null` and refuses the resource for the whole in-flight TTL. Measured
  // 2026-08-15: a `promote-listing` call with no `figi` answered 400, and the next VALID call 45
  // seconds later was refused `{ skipped: true, reason: 'fresh or in flight' }`. It self-heals in
  // two minutes, so it is a short self-inflicted outage rather than a stuck resource — but it is
  // triggered by the already-malformed request, so one mistake costs two failures. Counted rather
  // than named, so a new validation path cannot be added without releasing.
  const validationReturns = index.match(/return json\(\{ error: '[^']*needs a/g)?.length ?? 0
  check(validationReturns === 0,
    'no post-claim validation returns without releasing the lock',
    validationReturns ? `${validationReturns} early return(s) still hold the claim` : 'all release')

  // AN ACTION MUST RECORD THE LISTING IT WAS SEEN ON. Tiingo is asked by US ticker; `security_price`
  // stores the PRIMARY listing; those differed for 33 of the first 45 securities ingested
  // (SSNLF vs 005930.KS, NONOF vs NOVO-B.CO, ASMLF vs ASML.AS). A dividend from the OTC line is in
  // USD against a KRW series — wrong by three orders of magnitude — and unverifiable after the fact
  // without this column, which is how it survived a full review and a green suite.
  check(index.includes('observed_symbol: item.symbol'),
    'a corporate action records the listing it was observed on',
    'observed_symbol')

  // A SPLIT FACTOR IS A FLOAT, so "no split" is not `=== 1`. Tiingo returns a 3-for-1 as
  // 3.0000000001 often enough to matter, and the inverse — comparing with `!==` — would record a
  // split on every ordinary bar of every security, which is 3 million phantom rows.
  const tiingo = await Deno.readTextFile(new URL('./tiingo.ts', import.meta.url))
  check(/Math\.abs\(factor - 1\) > 1e-9/.test(tiingo),
    'splitFactor is compared with a tolerance, not for exact equality',
    'Math.abs(factor - 1) > 1e-9')
  // A 404 from Tiingo is a FACT about the symbol (it does not carry local foreign listings), and a
  // 500 is not. Collapsing them is the throw-vs-empty shape that has cost this pipeline thousands
  // of securities; the typed error is what keeps the marking path narrow.
  check(tiingo.includes('export class TiingoNoSuchTicker'),
    'a Tiingo 404 is a distinct, typed outcome — not a generic failure',
    'TiingoNoSuchTicker')
  check(index.includes('e instanceof TiingoNoSuchTicker'),
    'and only that outcome marks the security',
    'instanceof check at the marking site')

  // A BACKLOG'S `remaining` MUST BE IN THE SAME UNIT AS WHAT IT COUNTS DOWN FROM. The first live
  // run of `security-corporate-actions` reported `remaining: 0` on 60 securities that had barely
  // been touched, because `written` counts ACTION ROWS (521 of them) and `wanted.length` counts
  // SECURITIES — the subtraction went negative and clamped. A drained backlog and a refused one
  // looked identical, which is the failure this whole file exists to prevent.
  // The expression now reports `unanswered` rather than `remaining` (see the scope guard below),
  // but the UNITS rule it encodes is unchanged and still worth pinning: `covered` counts
  // securities, `written` counts action rows.
  check(index.includes('wanted.length - covered - none - noTicker'),
    'corporate-actions counts SECURITIES, not rows, in its page arithmetic',
    'the expression uses `covered`, not `written`')
  const pageOrders = index.match(/\.range\(/g)?.length ?? 0
  const tiebreaks = index.match(/\.order\('security_id', \{ ascending: true \}\)/g)?.length ?? 0
  check(tiebreaks >= pageOrders,
    'every paged backlog read has a UNIQUE sort key, so its pages partition',
    `${pageOrders} range() reads, ${tiebreaks} unique tiebreaks`)
}

// ── NO LOOP MAY GATE ON A BARE DEADLINE ───────────────────────────────────────────────────────
//
// A loop written `while (Date.now() < deadline)` decides whether to START work, not whether it can
// FINISH. The batch that starts one millisecond under the deadline still has to fetch, write, mark
// and prune, and the deadline bounds none of it. Measured 2026-08-17: `security-performance` ran
// **89 seconds against a 90-second worker** and was killed once with `WorkerRequestCancelled` —
// which is strictly worse than a shorter run, because it loses the in-flight batch AND never calls
// `finish_refresh`, locking the resource out for the 2-minute in-flight TTL on top.
//
// FOUR resources had it, not one. Fixing the one that visibly failed would have left three.
console.log('\nworker budget — a loop must leave room to finish')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  // COMMENTS STRIPPED FIRST. Scanning the raw file matched the PROSE of the comment describing
  // this very defect — the third time today a pattern has matched a neighbouring string rather
  // than code (the sweep reserve matched `stoppedBecause`, the budget guard matched a counter name).
  // A guard that reports its own documentation as a violation is noise, and noise gets deleted.
  const code = index
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n').map((l) => l.replace(/(^|[^:])\/\/.*$/, '$1')).join('\n')
  // BOTH FORMS. A loop can gate in its condition (`for (…; Date.now() < deadline; …)`) or with an
  // early `if (Date.now() >= deadline) break` in the body, and they are equally unbounded. Matching
  // only the first left the performance loop's own guard unchecked — caught by mutating it.
  const bare = [
    ...code.matchAll(/(for|while) *\([^)]*Date\.now\(\) *< *deadline *[;)]/g),
    ...code.matchAll(/if *\( *Date\.now\(\) *>= *deadline *\)/g),
  ].map((m) => m[0].replace(/\s+/g, ' '))
  check(bare.length === 0,
    'no loop gates on the bare deadline — every one reserves time for its tail',
    bare.length ? bare.join(' | ') : '')

  // A VALUE CHECK against the REAL limit, not a shape check. The budget guard for the exchange
  // sweep taught this the hard way: it counted the right quantity, in the right place, against a
  // ceiling that was wrong by 7.5x, and two shape checks sat beside it and saw nothing.
  const main = await Deno.readTextFile(new URL('../main/index.ts', import.meta.url))
  const workerMs = Number(main.match(/workerTimeoutMs = (\d+) \* 1000/)?.[1] ?? NaN) * 1000
  check(Number.isFinite(workerMs) && workerMs > 0, 'found the real worker timeout', `${workerMs}ms`)

  // Every handler's own deadline, read off the source. The largest must leave the worker room to
  // finish the batch that starts just under it, which is what the reserve is for.
  const deadlines = [...index.matchAll(/const deadline = Date\.now\(\) \+ (\d+)_(\d+)/g)]
    .map((m) => Number(m[1] + m[2]))
  const reserve = Number(index.match(/const TAIL_RESERVE_MS = (\d+)_(\d+)/)?.slice(1).join('') ?? NaN)
  const longest = Math.max(...deadlines)
  check(deadlines.length > 0 && longest < workerMs,
    'every handler deadline is under the worker timeout',
    `${deadlines.length} deadlines, longest ${longest}ms vs worker ${workerMs}ms`)
  check(reserve >= 10_000,
    'the reserve is big enough for a batch tail to actually finish',
    `reserve ${reserve}ms`)
}

// ── THE VENUE OVERRULES THE PROVIDER ON CURRENCY ──────────────────────────────────────────────
//
// yfinance returns `currency: USD` for Jakarta-quoted securities. Found 2026-08-18 by building FX
// and looking at the result: `security_market_cap_usd` ranked PT Barito the largest company on
// earth at $442 TRILLION, ~4x world GDP. The response is internally inconsistent — `BREN.JK` comes
// back with `currency: USD`, `market_cap: 442810222247936` and `price_to_book: 662000`.
//
// MAGNITUDE CANNOT BE THE TEST, which is the trap this nearly fell into: NVDA is a real $5,464bn
// and sits BETWEEN two fakes (241560.KS $6,087bn, HCLT.NS $3,707bn). No threshold separates them.
// The venue does.
console.log('\ncurrency — the venue overrules a provider that contradicts it')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  check(/from\('venue_currency'\)/.test(index),
    'the fundamentals path reads the venue currency')

  // ── EVERY PATH THAT FETCHES FUNDAMENTALS MUST WRITE THE CURRENCY ──────────────────────────
  //
  // There are TWO: `security-fundamentals` (the batch backlog) and `security-refresh` (the
  // on-demand path a user's stock page triggers). Only the first ever wrote the currency.
  // Proven in production 2026-08-18 by corrupting Toyota's listing to USD and running
  // `security-refresh` — it reported `fundamentals: updated` and left the wrong value in place.
  //
  // "A rule written at one call site is not a rule." Counted rather than eyeballed, because this
  // is the recurring failure in this file: six marking sites, four `remaining` units, four
  // unbounded loops, three return sites.
  const fundFetches = [...index.matchAll(/fetchFundamentals\(|loadFundamentals\(/g)].length
  const currencyWrites = [...index.matchAll(/writeCurrencyFor\(/g)].length - 1 // minus the definition
  check(fundFetches > 0 && currencyWrites >= fundFetches,
    'every path that fetches fundamentals also writes the currency',
    `${fundFetches} fetch sites, ${currencyWrites} currency writes`)
  // ONE implementation, not two that drift. The helper exists precisely because the inline
  // versions diverged.
  check(/^async function writeCurrencyFor\(/m.test(index),
    'the currency write is a single shared function, not copied per call site')

  // ── THE OVERRULE MUST STAY NARROW ─────────────────────────────────────────────────────────
  //
  // These assert the SHARED helper, and they were briefly LOST when the logic moved into it —
  // a regex edit removed them without adding the replacements, and everything still passed.
  // Restored explicitly, because they are the assertions that stop the dangerous rule returning:
  // overruling on ANY disagreement would relabel 233 securities of which ~20 are wrong.
  check(/cur === 'USD' && Number\.isFinite\(cap\) && cap > IMPOSSIBLE_USD_CAP/.test(index),
    'the venue overrules ONLY a USD claim with an impossible market cap, not any disagreement')
  check(/const IMPOSSIBLE_USD_CAP = 2e12/.test(index),
    'the impossibility threshold is a named constant, above every real company')
  check(/venueCur && venueCur !== 'USD'/.test(index),
    'and it only ever replaces USD with a non-USD venue currency')
  // The normalized write: the claim lands on the listing the symbol names.
  check(/\.from\('listing'\)[\s\S]{0,80}\.update\(\{ currency_code: cur \}\)/.test(index),
    'the currency is written to the LISTING the fetched symbol names')
  check(/\.eq\('provider_symbol', providerSymbol\)/.test(index),
    'and it is matched on that exact provider symbol, not on the security alone')
  check(/currencyOverruled,/.test(index),
    'the override is reported — a climbing count is the provider degrading, and the corrected '
    + 'value looks perfectly ordinary once stored')
  // Read ONCE, not per batch: 59 rows that cannot change mid-run.
}

console.log('\nabsence classifier — a crash in the adapter is still an answer about the symbol')
{
  // THE MIRROR OF THE THROTTLE CLASSIFIER BELOW, and it failed the same way: a vocabulary that
  // knew one wording for a fact the provider states in two.
  //
  // Measured 2026-09-06 against the live openbb-api. `security-dividends` had returned
  // `ok: false, failed: 60, written: 0` on every run since 2026-09-05 with 9,221 securities
  // pending, because only "No dividend data found" was classified as an absence. A venue yfinance
  // does not cover crashes the adapter instead, and those securities — being the HEAVIEST holdings
  // in the backlog — were re-asked eight times a day for ever.
  //
  // Every string is quoted from a response on this deployment. AAPL and KO returned full dividend
  // histories in the same seconds, which is what proves these are statements about the SYMBOL.
  const mustMatch = [
    "Error getting data for TSLA: No dividend data found for TSLA",
    "Error getting data for ICT.PS: 'NoneType' object has no attribute 'empty'",
    "Error getting data for FAB.AE: 'NoneType' object has no attribute 'empty'",
    "Error getting data for WARBABAN.KW: 'NoneType' object has no attribute 'empty'",
    "Error getting data for ANDINAB.SN: 'NoneType' object has no attribute 'empty'",
    // SEC, via openbb, for a US OTC line absent from SEC's own ticker map. Both name the symbol.
    "openbb 500 on /api/v1/equity/fundamental/income?provider=sec&symbol=AIBRF: "
      + "Unexpected Error -> ContentTypeError -> 404, message='Attempt to decode JSON with unexpected mimetype: text/html'",
    "Could not find CIK for symbol: BRK/B",
  ]
  // A NEGATIVE CACHE EARNED ON ONE OF THESE WOULD BE THE 1,369-SECURITY INCIDENT AGAIN: a provider
  // refusing us, or a transport fault, recorded as thousands of permanently unanswerable companies.
  const mustNotMatch = [
    'YFRateLimitError: Too Many Requests',
    'Error: You have run over your hourly request limit',
    'our standard API rate limit is 25 requests per day',
    'Signal timed out.',
    'client error (Connect): tcp connection refused',
    'openbb 400 on /api/v1/equity/fundamental/dividends?provider=yfinance&symbol=BRK/B',
    // A 500 that is NOT a 404 is the provider being unwell, and must never mark a symbol.
    'openbb 500 on /api/v1/equity/fundamental/income?provider=sec&symbol=AAPL: Internal Server Error',
  ]
  const src = await Deno.readTextFile(new URL('./resources.ts', import.meta.url))
  const handlerSrc = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  const body = src.slice(src.indexOf('export function noDataForSymbol'))
  const terms = [...body.slice(0, body.indexOf('\n}')).matchAll(/includes\((?:'([^']+)'|"([^"]+)")\)/g)]
    .map((m) => m[1] ?? m[2])
  check(terms.length >= 4,
    'the absence classifier knows every wording, not just the tidy one',
    terms.join(' | '))

  // THE `no_currency` HALF OF THE STATEMENTS BACKLOG IS MARKED ON PER-SYMBOL EVIDENCE, NOT ON A
  // RUN-LEVEL TALLY. `secOk` says the endpoint answered for SOMEONE this run — the right guard
  // against an outage, and guaranteed false once the answerable head has drained, which is how
  // this resource sat at `written: 240, remaining: 5972` on six identical runs.
  check(/secNoSuchSymbol \|\| \(secAsked && secRows === 0 && secOk\)/.test(handlerSrc),
    'a named SEC 404 marks on its own evidence, without the run-level tally in front of it')
  check(/if \(noDataForSymbol\(msg\)\) \{ secNoSuchSymbol = true; continue \}/.test(handlerSrc),
    'a SEC 404 is classified as an absence rather than counted as a failure')

  const matches = (msg: string) => terms.some((t) => msg.toLowerCase().includes(t))
  const missed = mustMatch.filter((m) => !matches(m))
  check(missed.length === 0,
    'every "this symbol has no data" wording seen in production is classified',
    missed.length ? `NOT matched: ${missed.join(' | ')}` : `${mustMatch.length} wordings`)

  const wrong = mustNotMatch.filter((m) => matches(m))
  check(wrong.length === 0,
    'a refusal or a transport fault is NEVER mistaken for an absence',
    wrong.length ? `wrongly matched: ${wrong.join(' | ')}` : `${mustNotMatch.length} negatives`)

  // AND THE TWO CLASSIFIERS MUST NOT OVERLAP. If a wording were in both, the branch that runs
  // first decides, and marking a throttled symbol absent is the failure this whole file exists to
  // prevent — so assert it structurally rather than trusting the two lists to stay disjoint.
  const tbody = src.slice(src.indexOf('export function throttled'))
  const tterms = [...tbody.slice(0, tbody.indexOf('\n}')).matchAll(/includes\('([^']+)'\)/g)].map((m) => m[1])
  const overlap = terms.filter((t) => tterms.some((x) => t.includes(x) || x.includes(t)))
  check(overlap.length === 0,
    'the absence and throttle classifiers share no vocabulary',
    overlap.length ? `BOTH claim: ${overlap.join(', ')}` : `${terms.length} vs ${tterms.length} terms, disjoint`)

  // The handler must actually USE it — a classifier nothing calls is the `filing_form` defect.
  const handler = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  check(/if \(noDataForSymbol\(msg\)\)/.test(handler),
    'the dividends handler classifies with it rather than carrying its own regex')
  check(!/\/no dividend data found\/i\.test\(/.test(handler),
    'the old single-wording regex is GONE from the handler, not merely joined by the classifier')
}

console.log('\nthrottle classifier — the wordings providers ACTUALLY use')
{
  // A CLASSIFIER IS ONLY AS GOOD AS THE VOCABULARY IT KNOWS, and this one was a guess.
  // Measured 2026-08-28: `security-corporate-actions` was refused by Tiingo on six consecutive
  // runs and `throttledOut` was false every time, because Tiingo says "You have run over your
  // hourly request limit" — which contains neither "rate limit" nor "429". The panel showed a
  // clean provider while it refused us all day.
  //
  // Every string below is QUOTED FROM PRODUCTION, not invented. The negatives matter as much: a
  // classifier that returns true for an ordinary 400 would make every symbol failure look like a
  // rate limit and stop the run.
  const mustMatch = [
    'Error: You have run over your hourly request limit',
    'tiingo refused (HTTP 200): You have run over your hourly request limit',
    'YFRateLimitError: Too Many Requests',
    'our standard API rate limit is 25 requests per day',
  ]
  const mustNotMatch = [
    'openbb 400 on /api/v1/equity/fundamental/dividends?provider=yfinance&symbol=HUT.VN',
    'Signal timed out.',
    'tiingo has no ticker BBVXF',
  ]
  const src = await Deno.readTextFile(new URL('./resources.ts', import.meta.url))
  const body = src.slice(src.indexOf('export function throttled'))
  const terms = [...body.slice(0, body.indexOf('\n}')).matchAll(/includes\('([^']+)'\)/g)].map((m) => m[1])
  check(terms.length >= 5, 'the classifier knows more than the four terms it shipped with',
    terms.join(', '))

  const matches = (msg: string) => terms.some((t) => msg.toLowerCase().includes(t))
  const missed = mustMatch.filter((m) => !matches(m))
  check(missed.length === 0,
    'every rate-limit wording seen in production is classified',
    missed.length ? `NOT matched: ${missed.join(' | ')}` : `${mustMatch.length} wordings`)

  const wrong = mustNotMatch.filter((m) => matches(m))
  check(wrong.length === 0,
    'an ordinary provider error is NOT mistaken for a rate limit',
    wrong.length ? `wrongly matched: ${wrong.join(' | ')}` : `${mustNotMatch.length} negatives`)
}

console.log('\nresource registry — the cron and the function agree')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  // THE SCHEDULE MOVED INTO THE DATABASE (migration 133). It used to live in a
  // `RESOURCES=$(printf ...)` block in .github/workflows/market-warmup.yml, which GitHub was
  // running 6.8 times a day against a nominal 8, every run 19-127 minutes late. The source of
  // truth is now `market.cron_resource`, seeded in the migration.
  //
  // THIS PARSE IS NOT COSMETIC. Deleting that workflow would have silently deleted the two guards
  // below with it — including the one that caught `exchange-listings` being registered, deployed,
  // reachable and never invoked for three days while sixteen venues went un-enumerated.
  //
  // EVERY MIGRATION, NOT JUST 133. A resource may be registered by the migration that ADDS it —
  // `security-daily-history` is seeded in 136 — and reading only the scheduler's own file made
  // this guard report a correctly-scheduled resource as unscheduled. That is the "anchored on one
  // file" shape that has already cost this repo a guard reading the wrong `while` loop: the fix
  // for "the pattern matched somewhere else" is not a better pattern, it is the right SCOPE.
  const cronResources: string[] = []
  for await (const sql of migrationSql()) {
    for (const seed of sql.matchAll(
      /insert into market\.cron_resource \(position, resource\) values([\s\S]*?)on conflict/g,
    )) {
      for (const m of seed[0].matchAll(/\(\s*\d+,\s*'([a-z][a-z-]+)'\)/g)) cronResources.push(m[1])
    }
  }
  // RETIREMENT IS NOT ORPHANING, AND THE GUARD COULD NOT TELL THEM APART. A resource moved to
  // its own job is disabled-and-scheduled; a resource RETIRED by a family cutover is
  // disabled-and-gone, which is the intent rather than the bug. Without this the ten price and
  // performance resources failed a check that was working perfectly — and a guard that cries
  // wolf on correct data is one somebody deletes, taking the real case with it.
  //
  // The migration says which it is, in the migration, so the two cannot drift: a retirement
  // declares `-- RETIRES: <name>` beside the update that disables it. A retired name stays in the
  // cron seed (its row is disabled, not deleted), so every check below that compares the seed with
  // the function skips it.
  const retired = new Set<string>()
  for await (const sql of migrationSql()) {
    for (const m of sql.matchAll(/--\s*RETIRES:\s*([a-z][a-z0-9 ,-]*)/g)) {
      for (const name of m[1].split(',')) {
        const n = name.trim()
        if (n) retired.add(n)
      }
    }
  }
  // A RESOURCE REMOVED FROM THE ROTATION MUST HAVE ITS OWN JOB, OR IT SIMPLY STOPS RUNNING.
  // Migration 137 takes the four pure-SQL resources out of the provider-paced rotation
  // (`enabled = false`) because they spend no provider budget — but `enabled = false` and
  // "deleted" look identical from the rotation's side, and a resource that is never invoked
  // cannot fail. `exchange-listings` sat reachable-and-unscheduled for weeks precisely because
  // nothing checked the reverse direction.
  {
    const disabled = new Set<string>()
    for await (const sql of migrationSql()) {
      for (const m of sql.matchAll(
        /update market\.cron_resource set enabled = false[\s\S]*?in \(([^)]*)\)/g,
      )) {
        for (const q of m[1].matchAll(/'([a-z][a-z-]+)'/g)) disabled.add(q[1])
      }
    }
    const orphaned: string[] = []
    for (const name of disabled) {
      if (retired.has(name)) continue
      let scheduled = false
      for await (const sql of migrationSql()) {
        if (sql.includes(`cron_post('${name}')`)) { scheduled = true; break }
      }
      if (!scheduled) orphaned.push(name)
    }
    check(orphaned.length === 0,
      'a resource taken out of the rotation has its own pg_cron job',
      orphaned.length ? `disabled but never scheduled: ${orphaned.join(', ')}` : `${disabled.size} checked`)

    // …AND THE FUNCTION REFUSES EXACTLY WHAT THE MIGRATIONS RETIRED. A disabled cron row stops the
    // SCHEDULE and nothing else: until 2026-09-25 a direct call still reached every retired
    // handler, and `fx-rates` would have written `market.fx_rate` beside the Dagster lane that owns
    // it. The two lists live in different files, so they are held equal here in both directions —
    // a retirement the function still serves, and a refusal no migration declared.
    const retiredBlock = index.match(/const RETIRED: Record<string, string> = \{[\s\S]*?\n\}/)?.[0] ?? ''
    const refused = new Set([...retiredBlock.matchAll(/^\s{2}'([a-z][a-z0-9-]+)':/gm)].map((m) => m[1]))
    const stillServed = [...retired].filter((n) => !refused.has(n))
    const neverRetired = [...refused].filter((n) => !retired.has(n))
    check(refused.size > 0 && stillServed.length === 0 && neverRetired.length === 0,
      'the function refuses exactly the resources a migration retired',
      refused.size === 0
        ? 'no RETIRED map found in index.ts'
        : stillServed.length || neverRetired.length
        ? `retired but still served: ${stillServed.join(', ') || '-'}; refused but never retired: ${neverRetired.join(', ') || '-'}`
        : `${refused.size} refused`)

    // The refusal must come before anything that acts on the name: the admin gate (so the answer
    // does not depend on who asks) and `begin_refresh` (so a retired name takes no lock and records
    // no attempt as its own run). Positions are read inside `handle`, not the whole file.
    const handleSrc = index.slice(index.indexOf('async function handle('))
    const at = (needle: string) => handleSrc.indexOf(needle)
    const gate = at('Object.hasOwn(RETIRED, resource)')
    check(gate > 0 && gate < at('if (!isAdmin(req))') && gate < at("rpc('begin_refresh'"),
      'a retired resource is refused before the admin gate and the claim',
      gate > 0 ? `gate at ${gate}, admin at ${at('if (!isAdmin(req))')}, claim at ${at("rpc('begin_refresh'")}` : 'gate not found')
  }

  // `observability-sample` is scheduled by its OWN pg_cron job rather than the rotation (it costs
  // no provider quota, so it runs hourly), so it is added here to keep the reverse check honest.
  cronResources.push('observability-sample')
  check(cronResources.length > 10, 'found the cron resource seed', `${cronResources.length} names`)

  // What the function will accept: the EXTRA allow-list. (The `RESOURCES` registry in
  // resources.ts retired with the performance family.)
  const declared = new Set<string>(
    [...index.matchAll(/_RESOURCE = '([a-z][a-z-]+)'/g)].map((m) => m[1]),
  )
  // `EXTRA` is DERIVED from the TTL map (`Object.keys`), so the allow-list and the TTL table are
  // the same list and cannot drift. Parse the map.
  const extraBlock = index.match(/const EXTRA_TTL_MINUTES: Record<string, number> = \{[\s\S]*?\n  \}/)?.[0] ?? ''
  check(extraBlock.length > 0, 'found the TTL map that defines the extra resources')
  const accepted = new Set<string>(
    [...declared].filter((name) => {
      const constName = [...index.matchAll(/(\w+_RESOURCE) = '([a-z][a-z-]+)'/g)]
        .find((m) => m[2] === name)?.[1]
      // A resource is reachable if it is a declared RESOURCES entry, or its constant is in EXTRA.
      return !constName || extraBlock.includes(`[${constName}]`)
    }),
  )

  // ── EVERY RESOURCE DECLARES A TTL, AND NOTHING INHERITS ONE ────────────────────────────────
  //
  // This is the guard for the defect measured 2026-08-17. The TTL used to be a ternary chain
  // ending in `: PROFILE_TTL_MINUTES`, kept BESIDE a separate `EXTRA` array of known resources.
  // Three resources were in the array and not in the chain, so they silently inherited SEVEN DAYS
  // — and all three are incremental backlogs that must run every pass:
  // `security-prices` (frozen 08-14 to 08-21 while `pending_prices` grew 2,940 -> 11,348),
  // `security-yahoo-symbols`, `security-corporate-actions`.
  //
  // NOTHING COULD REPORT IT. The cron called them eight times a day and each answered
  // `{"skipped":true,"reason":"fresh or in flight"}`, which is a SUCCESS for a warm-up — green
  // workflow, `ok: true` in `refresh_log`, no error anywhere, and price ingestion stopped dead.
  //
  // Asserted against the SOURCE because it is the SHAPE that recurs: a default that silently
  // supplies a wrong answer is worse than no default, which would have 400'd on the first call.
  const ttlKeys = [...extraBlock.matchAll(/\[(\w+_RESOURCE)\]:\s*(\w+)/g)]
  const withoutTtl = [...index.matchAll(/(\w+_RESOURCE) = '([a-z][a-z-]+)'/g)]
    .map((m) => m[1])
    .filter((c) => !ttlKeys.some(([, key]) => key === c))
  check(withoutTtl.length === 0,
    'every declared resource constant has an explicit TTL',
    withoutTtl.length ? `no TTL declared for: ${withoutTtl.join(', ')}` : '')

  check(!/:\s*PROFILE_TTL_MINUTES\s*$/m.test(index.replace(/\[PROFILE_RESOURCE\]:.*/g, '')),
    'there is no fallback TTL for a resource that declares none')

  // The incremental backlogs specifically. A backlog resource drains a slice per run, so anything
  // longer than the cron interval stalls it for the length of the TTL rather than slowing it.
  const mustBeBacklog = [
    'ACTIONS_RESOURCE', 'STATEMENTS_RESOURCE', 'FUNDAMENTALS_RESOURCE', 'INDUSTRY_RESOURCE',
    'SEC_PROFILE_RESOURCE',
  ]
  const wrongTtl = mustBeBacklog.filter((c) =>
    !ttlKeys.some(([, key, ttl]) => key === c && ttl === 'BACKLOG_TTL_MINUTES'))
  check(wrongTtl.length === 0,
    'every incremental backlog runs on the backlog TTL, not a completion-shaped one',
    wrongTtl.length ? `wrong TTL: ${wrongTtl.join(', ')}` : '')

  // ── `remaining` COUNTS SECURITIES, AND A ROW IS NOT A SECURITY ──────────────────────────────
  //
  // `remaining` is subtracted from a count of SECURITIES (`wanted.length`). Subtract a count of
  // ROWS from it and it goes negative and clamps to zero, so the resource reports a drained
  // backlog on every run while thousands of securities are still pending. It is the one number an
  // operator reads to decide whether a backlog is progressing, and it fails in the believable
  // direction.
  //
  // FIVE instances, four of them found only by measuring production against the reported number:
  //   security-corporate-actions  written=521 rows vs 60 securities   -> fixed in #140
  //   security-statements         written=276 rows vs 60 asked, `pending_statements` 3,646
  //   security-performance        refreshed=2,751 rows (~306 securities), `pending_performance` 6,909
  //   security-prices             reported the PAGE SIZE, which never moves however much it does
  //   security-industries/-profiles  counted `writes` BEFORE `dedupeBy`, so a security in two
  //                               sectors counted twice
  //
  // The discriminator is the upsert's conflict key, which says how many rows a security may have:
  // `security_fundamentals` is keyed on `security_id` alone, so counting its rows IS counting
  // securities and `written` is correct there. `security_taxonomy` is keyed on
  // (security_id, node_id, source_code) and `security_price` on (security_id, date), so counting
  // theirs is not. Rather than re-derive that per site — which is how this survived five times —
  // every other site now counts distinct securities in a Set, and this asserts it.
  // THIS IS A WHITELIST PER RESOURCE, and both of those words were arrived at by watching weaker
  // versions fail:
  //
  // - INFERRING the unit (walk back from `counter += arr.length` to the nearest `onConflict`)
  //   cannot tell whether that upsert is the one that wrote `arr`. It raised three false positives
  //   on counters that are correct — `emptyIds`, `deadIds` and `batch` are arrays of SECURITIES,
  //   so their `.length` IS a security count. A guard that cries wolf on correct code gets deleted.
  //
  // - A BLACKLIST OF COUNTER NAMES cannot express "legal here, illegal there", and that is exactly
  //   the situation: `written` is a security count in security-fundamentals (keyed on `security_id`
  //   alone) and a row count in every other resource. Allow-listing the NAME re-permitted the
  //   original bug — proven by mutation, which put `written` back into the statements expression
  //   and passed. It also could not see `classified`, whose increment had changed shape.
  //
  // So: each resource declares the exact identifiers its `remaining` may mention. Anything else
  // fails, including a NEW name. Brittle to refactoring on purpose — renaming a counter fails
  // loudly and is a two-second fix, while a row count silently replacing a security count is a
  // backlog that reports itself drained for ever.
  const REMAINING_MAY_USE: Record<string, string[]> = {
    ACTIONS_RESOURCE: ['wanted', 'covered', 'none', 'noTicker'],
    // Both of these report the BACKLOG via `backlogSize`, which the loop exempts from the
    // arithmetic rules — there are no units to confuse in a `content-range` count. They are still
    // listed so the "has the list rotted" tally keeps meaning "every resource was looked at".
    STATEMENTS_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the two above.
    QUARTERS_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the others above.
    PROFILE_DETAIL_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the others above.
    INSIDER_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the others above.
    FILINGS_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the others above.
    SEGMENTS_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the others above.
    FILING_HISTORY_RESOURCE: [],
    // Korea. `security-kr-segments` reports `pending_kr_segments`; `kr-filings` reports
    // `pending_kr_history`, which is ITS OWN backlog — the companies whose filing history is
    // unwalked — and deliberately not the parse queue, which belongs to the other resource.
    KR_SEGMENTS_RESOURCE: [],
    KR_FILINGS_RESOURCE: [],
    // India, the same split: `security-in-segments` reports `pending_in_segments` and `in-filings`
    // reports `pending_in_history`, its own backlog of companies whose filing history is unwalked.
    IN_SEGMENTS_RESOURCE: [],
    IN_FILINGS_RESOURCE: [],
    // China, the same split as Korea and India. `cn-filings` walks companies and reports its own
    // `pending_cn_filings`; `security-cn-segments` parses and reports `pending_cn_segments`.
    //
    // The comment that stood here said "filing LINKS only — every CNINFO filing is a PDF", which
    // was migration 183's conclusion and is no longer the whole truth: the PDFs are TEXT, the CSRC
    // mandates the breakdown table, and migration 195 reads it. PDF is still why China needs its
    // own parser rather than the XBRL one.
    CN_FILINGS_RESOURCE: [],
    CN_SEGMENTS_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the others above.
    WIKIDATA_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the others above.
    MANAGEMENT_RESOURCE: [],
    // Reports the backlog via `backlogSize`, like the others above.
    EPS_HISTORY_RESOURCE: [],
    // Analyst actions. Reports `pending_price_targets` via `backlogSize`; `actions` counts ROWS
    // (one per analyst action) and `advanced` counts SECURITIES whose cursor moved, which are
    // deliberately different units and named so.
    PRICE_TARGETS_RESOURCE: [],
    METRICS_RESOURCE: [],
    // A SWEEP, NOT A BACKLOG: `remaining` is DAYS still to walk, computed from the cursor
    // against its floor. `walkedTo` and `stopAt` are the only identifiers involved, and
    // the units are days rather than securities — which is exactly why this list exists.
    EARNINGS_HISTORY_RESOURCE: ['walkedTo', 'stopAt', 'getTime'],
    XBRL_RESOURCE: [],
    SHARE_STATS_RESOURCE: [],
    NEWS_RESOURCE: [],
    // `written` is legitimate here and ONLY here: `security_fundamentals` is keyed on
    // `security_id` alone, so one row is one security.
    FUNDAMENTALS_RESOURCE: ['wanted', 'written', 'missing'],
    INDUSTRY_RESOURCE: ['wanted', 'classifiedSecurities', 'noIndustry'],
    SEC_PROFILE_RESOURCE: ['wanted', 'classifiedSecurities', 'unmapped', 'noProfile'],
  }
  const idxLines = index.split('\n')
  const resourceAt = (line: number): string | null => {
    let owner: string | null = null
    idxLines.forEach((l, i) => {
      const m = l.match(/resource === (\w+_RESOURCE)\)/)
      if (m && i + 1 <= line) owner = m[1]
    })
    return owner
  }
  const offenders: string[] = []
  let checkedExpressions = 0
  idxLines.forEach((l, i) => {
    if (!/^\s*remaining:/.test(l)) return
    checkedExpressions++
    const owner = resourceAt(i + 1)
    // THE BACKLOG COUNT IS EXEMPT, BECAUSE IT IS THE BETTER ANSWER TO THE SAME QUESTION.
    //
    // This guard exists for arithmetic `remaining` expressions, which kept confusing rows with
    // securities and page-with-backlog. `backlogSize(market, 'pending_x')` is not arithmetic at
    // all: it asks Postgres for the true total via `content-range`, so there are no units to
    // confuse and nothing to subtract. Requiring the subtraction here would forbid the one form
    // that cannot get this wrong.
    //
    // Narrow on purpose — it must be a call to THIS helper against a `pending_` view, so
    // `remaining: someOtherThing()` is still an offence.
    if (/^\s*remaining:\s*await backlogSize\(market, 'pending_\w+'\),\s*$/.test(l)) return
    const allowed = owner ? REMAINING_MAY_USE[owner] : undefined
    if (!allowed) {
      offenders.push(`line ${i + 1}: no declared identifier list for ${owner ?? 'unknown resource'}`)
      return
    }
    // Base identifiers only — a trailing `.length` / `.size` is a property of one of them, not a
    // separate name, and counting it as one made every line look undeclared.
    const used = [...l.matchAll(/(?<![.\w])([a-z]\w*)\b/gi)]
      .map((m) => m[1])
      .filter((n) => !['remaining', 'Math', 'max'].includes(n))
    const undeclared = [...new Set(used)].filter((n) => !allowed.includes(n))
    if (undeclared.length) {
      offenders.push(`line ${i + 1} (${owner}): undeclared in remaining: ${undeclared.join(', ')}`)
    }
    // AND IT MUST ACTUALLY SUBTRACT THE RUN'S PROGRESS. `security-prices` reported
    // `remaining: wanted.length` — the page it was handed, which is the same number whether the
    // run priced everything or nothing. That is not caught by the whitelist, because the page size
    // is a legitimately declared identifier; the defect is the ABSENCE of the subtraction.
    if (!l.includes(' - ')) {
      offenders.push(`line ${i + 1} (${owner}): remaining subtracts nothing — it reports the page size`)
    }
  })
  check(offenders.length === 0,
    'every `remaining` uses only the identifiers its resource declares (rows are not securities)',
    offenders.join(' | '))


  // ── `remaining` IS THE BACKLOG, NOT WHAT IS LEFT OF THIS PAGE ────────────────────────────────
  //
  // The whitelist above enforces UNITS — securities versus rows — and is blind to SCOPE. A page
  // arithmetic like `wanted.length - covered - none` is made of perfectly good security counts and
  // still answers the wrong question: it reads ~0 after any successful run, however deep the queue
  // is. Measured 2026-09-01 against the true depths:
  //
  //   security-prices             reported remaining 0   against pending_prices             9,013
  //   security-corporate-actions  reported remaining 60  against pending_corporate_actions  2,533
  //
  // The other seven agreed only because their backlogs happened to be drained — the defect was
  // invisible until one of them had real work. CLAUDE.md has recorded the rule since
  // `security-statements` was fixed ("`remaining` MUST MEAN THE SAME THING IN EVERY RESOURCE, AND
  // PAGE-SCOPED IS THE WRONG ONE"); it was never propagated to the other nine, and nothing could
  // see that because the existing guard only ever asked about units.
  //
  // THE RULE: a resource that READS a `pending_*` view must report THAT view's size as `remaining`.
  // The page-scoped number keeps its own name, `unanswered`. A resource driven by a cursor rather
  // than a backlog reads no `pending_` view and is therefore untouched by this — which is why the
  // test is "reads a pending view", not a list of exemptions that would rot.
  {
    const scopeOffenders: string[] = []
    let scopeChecked = 0
    const blocks: { name: string; start: number; end: number }[] = []
    idxLines.forEach((l, i) => {
      const m = l.match(/resource === ([A-Z_]+_RESOURCE)/)
      if (m) {
        if (blocks.length > 0) blocks[blocks.length - 1].end = i
        blocks.push({ name: m[1], start: i, end: idxLines.length })
      }
    })
    for (const b of blocks) {
      const body = idxLines.slice(b.start, b.end)
      const views = [...new Set(
        body.flatMap((l) => [...l.matchAll(/\.from\('(pending_\w+)'\)/g)].map((m) => m[1])),
      )]
      if (views.length === 0) continue
      const remainingLine = body.find((l) => /^\s*remaining:/.test(l))
      if (remainingLine === undefined) continue
      scopeChecked++
      const declared = remainingLine.match(/backlogSize\(market, '(pending_\w+)'\)/)?.[1]
      if (declared === undefined) {
        scopeOffenders.push(`${b.name} reads ${views.join('/')} but reports a page-scoped remaining`)
      } else if (!views.includes(declared)) {
        scopeOffenders.push(`${b.name} reports ${declared} but drives ${views.join('/')}`)
      }
    }
    check(scopeOffenders.length === 0 && scopeChecked >= 15,
      `every backlog-driven resource reports its BACKLOG as remaining — ${scopeChecked} checked`,
      scopeOffenders.join('; ') || `${scopeChecked} backlog-driven resources, all reporting their own pending view`)
  }

  // The exempted backlog-count lines still increment `checkedExpressions`, so this tally keeps
  // meaning "every resource's remaining was looked at" rather than silently shrinking as
  // resources move to the count.
  check(checkedExpressions === Object.keys(REMAINING_MAY_USE).length,
    'every declared resource was actually checked — the list has not rotted',
    `${checkedExpressions} expressions vs ${Object.keys(REMAINING_MAY_USE).length} declared`)

  // ── TWO WRITERS TO ONE TABLE MUST NOT DISAGREE ABOUT ITS KEY ────────────────────────────────
  //
  // `security_segment` is written by the SEC path and the DART path. The Korean one shipped with
  // `security_id,axis,member_code,metric_code,period_type,period_ending` — the SEC target minus
  // `parent_key` — and that does not merely mis-dedupe: it names a constraint that does not exist,
  // so every write failed with `no unique or exclusion constraint matching the ON CONFLICT
  // specification`. Nothing offline could see it. The behaviour tests insert rows directly rather
  // than through a resource, `deno check` cannot know the table's key, and the migration suite
  // never runs a resource — it took the first live parse.
  //
  // `parent_key` is a STORED GENERATED column (`coalesce(parent_member, '')`) because a primary key
  // admits no NULLs and the flat case must keep working, which is exactly why it is easy to leave
  // out of a hand-copied target.
  {
    // Anchored on the TARGET's own shape, not on distance from `.from('security_segment')`: the
    // SEC call site carries a nine-line comment between the two, so a windowed match found one
    // writer and reported the pair as consistent — a guard that cannot see the second thing it is
    // comparing.
    const targets = [...index.matchAll(/onConflict: '(security_id,axis,member_code[^']*)'/g)]
      .map((m) => m[1])
    const distinct = [...new Set(targets)]
    check(targets.length >= 2 && distinct.length === 1,
      'every security_segment writer uses the SAME conflict target',
      distinct.length === 1
        ? `${targets.length} writers, all on ${distinct[0]}`
        : `writers disagree: ${distinct.join('  vs  ')}`)
    check(distinct.length === 1 && distinct[0].includes('parent_key'),
      'and that target names parent_key, which is part of the primary key',
      distinct[0] ?? '(none found)')
  }

  const unreachable = cronResources.filter((r) => !accepted.has(r) && !retired.has(r))
  check(unreachable.length === 0,
    'every resource the warm-up calls is accepted by the function',
    unreachable.length ? `unreachable: ${unreachable.join(', ')}` : '')

  // AND THE OTHER DIRECTION, WHICH IS THE ONE THAT ACTUALLY FAILED.
  //
  // The check above asks "does everything the cron calls exist?" — it cannot see a resource that
  // exists and is never called. `exchange-listings` was in exactly that state: written, deployed,
  // reachable, and absent from the schedule, so the ONLY thing that grows the universe beyond what
  // the tracked funds happen to hold ran when a human remembered. Measured 2026-08-14: it had last
  // run on 08-11, three days earlier, with **16 venues never enumerated at all** — Australia,
  // Japan, China, Indonesia, Sweden, Greece, Peru — and the US sweep parked on prefix `A`.
  //
  // Nothing reported it. Every backlog it feeds was drained, every count was plausible, and a
  // resource that is never invoked cannot fail. That is the same shape as the inert column in
  // migration 56: the failure is an ABSENCE, and absences do not raise.
  //
  // On-demand resources are named explicitly rather than pattern-matched, so adding one is a
  // deliberate act. `security-refresh` fires when a user opens a stock page; it has no backlog to
  // drain, so it does not belong on a timer — everything else does.
  const ON_DEMAND = new Set(['security-refresh'])
  const unscheduled = [...accepted].filter((r) => !ON_DEMAND.has(r) && !cronResources.includes(r))
  check(unscheduled.length === 0,
    'every backlog resource is actually SCHEDULED, not merely reachable',
    unscheduled.length ? `absent from market.cron_resource: ${unscheduled.join(', ')}` : '')
}

// ── extractMacroPoints — five providers, five shapes, none of them agree ─────
//
// WHY THIS IS CHECKED OFFLINE. Every shape below was measured against the deployed openbb-api, and
// getting one wrong is SILENT: the extractor returns no points, the resource reports "no data",
// and the series looks like one the provider has retired. The FRED shape is the trap — its value
// sits under a key NAMED AFTER THE SERIES, so a fixed `r.value` read returns undefined for every
// row and a working series reads as a dead one.
console.log('\nextractMacroPoints — one shape per provider')
{
  const oecd = extractMacroPoints(
    [{ date: '2026-01-01', country: 'united_states', value: 0.0239, expenditure: 'total' }], 'us-cpi')
  check(oecd.length === 1 && oecd[0].value === 0.0239, 'oecd cpi -> value', JSON.stringify(oecd))
  check(oecd[0]?.dimension === '', 'oecd cpi has no dimension', JSON.stringify(oecd[0]))

  const curve = extractMacroPoints([
    { date: '2026-08-17', maturity: 'month_1', rate: 0.0379, maturity_years: 0.083 },
    { date: '2026-08-17', maturity: 'year_10', rate: 0.0422, maturity_years: 10 },
  ], 'us-yield-curve')
  check(curve.length === 2, 'yield curve keeps BOTH maturities', JSON.stringify(curve))
  check(curve.map((p) => p.dimension).join(',') === 'month_1,year_10', 'maturity becomes the dimension', JSON.stringify(curve))
  check(new Set(curve.map((p) => p.as_of)).size === 1, 'a curve shares one date')

  const effr = extractMacroPoints([{ date: '2026-08-15', rate: 0.0433 }], 'us-effr')
  check(effr.length === 1 && effr[0].value === 0.0433, 'effr -> rate', JSON.stringify(effr))

  const ohlc = extractMacroPoints(
    [{ date: '2026-08-15', open: 3400, high: 3450, low: 3380, close: 3421, volume: 12 }], 'gold')
  check(ohlc.length === 1 && ohlc[0].value === 3421, 'yfinance -> CLOSE, not open', JSON.stringify(ohlc))

  // THE FRED TRAP: the value key is the series id.
  const fred = extractMacroPoints([{ date: '2026-06-01', LRHUTTTTDEM156S: 3.9 }], 'de-unemployment-fred')
  check(fred.length === 1 && fred[0].value === 3.9, 'fred -> the value under its SERIES-NAMED key', JSON.stringify(fred))

  // …and it must not hijack a shape that HAS a real value field.
  // THE STRAY NUMBER COMES FIRST, deliberately: the fallback walks Object.entries in insertion
  // order, so putting `value` first makes the assertion pass whether or not the precedence exists.
  const both = extractMacroPoints([{ date: '2026-01-01', some_other_number: 99, value: 1.5 }], 'x')
  check(both[0]?.value === 1.5, 'a real `value` field wins over a stray number', JSON.stringify(both))
}

console.log('\nextractMacroPoints — the duplicate key that would fail the WHOLE upsert')
{
  // OECD returns several `expenditure` breakdowns per date. Carrying a key twice makes Postgres
  // fail the statement with 21000 and take the resource with it — the documented dedupeBy trap.
  const dupes = extractMacroPoints([
    { date: '2026-01-01', value: 1, expenditure: 'total' },
    { date: '2026-01-01', value: 2, expenditure: 'food' },
  ], 'us-cpi')
  check(dupes.length === 1, 'one point per (date, dimension)', JSON.stringify(dupes))

  const curveDupes = extractMacroPoints([
    { date: '2026-08-17', maturity: 'year_10', rate: 0.04 },
    { date: '2026-08-17', maturity: 'year_10', rate: 0.05 },
  ], 'c')
  check(curveDupes.length === 1, 'a repeated maturity is deduped too', JSON.stringify(curveDupes))
}

console.log('\nextractMacroPoints — junk is dropped, not coerced')
{
  check(extractMacroPoints([{ value: 5 }], 'x').length === 0, 'a row with no date is dropped')
  check(extractMacroPoints([{ date: '2026-01-01', note: 'n/a' }], 'x').length === 0, 'a row with no numeric value is dropped')
  check(extractMacroPoints([{ date: '2026-01-01', value: 'abc' }], 'x').length === 0, 'a non-finite value is dropped')
  check(extractMacroPoints([], 'x').length === 0, 'an empty response yields no points')
}


// ── security-dividends — a non-payer is an HTTP 400, not an empty answer ─────
//
// Source checks, because the behaviour that matters is a CLASSIFICATION of an error string and the
// cheap way to exercise it is to call a live provider. Measured: `equity/fundamental/dividends`
// answers a company with no dividends with `400 ... No dividend data found for TSLA`. Treating
// that as a failure would never mark, so every non-payer is re-asked forever and crowds out the
// payers; treating every 400 as a non-payer would mark securities during an outage, which is the
// mechanism that once negative-cached 1,369 answerable ones.
console.log('\nsecurity-dividends — the 400 that means "this company pays none"')
{
  const idx = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  const fn = idx.slice(idx.indexOf("resource === DIVIDENDS_RESOURCE"))
  const withComments = fn.slice(0, fn.indexOf('if (resource === PROMOTE_WAVE_RESOURCE)'))
  // STRIP THE COMMENTS FIRST. Every string these guards look for also appears in the prose above
  // the code that explains it, so asserting against the raw text matches the COMMENT — two of
  // these passed a mutation that had deleted the code entirely.
  const body = withComments.replace(/\/\/[^\n]*/g, '')

  // A non-payer is still recognised by the provider MESSAGE (it arrives as a 400, not as an empty
  // array) — but the VOCABULARY now lives in `noDataForSymbol`, because the provider states that
  // fact in two wordings and this handler only knew the tidy one. The guard follows the rule to
  // where it moved rather than being relaxed: the classifier's own wordings are pinned in the
  // "absence classifier" block above, and what must be true HERE is that the handler consults it.
  check(
    /noDataForSymbol\(msg\)/.test(body),
    'a non-payer is recognised by the provider MESSAGE, via the shared absence classifier',
  )
  // Match the WRITE, not the name. `dividends_missing_at` also appears in the error-message string
  // two lines below it, so `includes(name)` passed a mutation that had deleted the update entirely.
  check(
    /update\(\{\s*dividends_missing_at:/.test(body),
    'the non-payer branch actually WRITES the negative cache, or every dividend-less security is re-asked forever',
  )
  check(
    body.search(/update\(\{\s*dividends_missing_at:/) > body.indexOf('no dividend data found'),
    'ONLY the recognised message marks — a generic 400 must not negative-cache a security',
  )
  check(
    body.includes('!anyAnswer') && body.includes('p_ok: false'),
    'a run where NOTHING answered reports ok:false — that is a provider event, not 60 dividend-less securities',
  )
  check(
    body.includes('observed_symbol'),
    'the listing the dividend was seen on is stored — an action that cannot be tied to a series cannot be checked against it',
  )
  check(
    body.includes('fetch_symbol'),
    'asked with the PRICED symbol, which is what removes Tiingo\'s US-ticker constraint and takes coverage past 4.5%',
  )
  check(
    body.includes('dedupeBy('),
    'the upsert is deduped — the same key twice fails the WHOLE statement with 21000',
  )
  check(
    /throttled\(msg\)/.test(body),
    'a throttle signature stops the run rather than burning the rest of the page against a refusing provider',
  )
}


// ── security-statements — the filing is the better record ────────────────────
//
// 0 of 104,972 statement rows carried a reporting currency, while the `currency` column and the
// code that reads `reported_currency` had both existed since migration 29 — yfinance simply never
// sends it. SEC does, along with 18 annual periods against yfinance's 4. Both properties are
// silent when lost: the rows still arrive, just shallower and unlabelled.
console.log('\nsecurity-statements — SEC first, yfinance as the fallback')
{
  const idx = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  const seg = idx.slice(idx.indexOf('resource === STATEMENTS_RESOURCE'))
  const withComments = seg.slice(0, seg.indexOf('if (resource === FUNDAMENTALS_RESOURCE)'))
  // Comments stripped: every string below also appears in the prose explaining it, and matching
  // the prose is how three guards passed a mutation earlier in this session.
  const body = withComments.replace(/\/\/[^\n]*/g, '')

  check(
    /provider=sec/.test(body),
    'SEC is called at all — it is the only provider here that returns reported_currency',
  )
  check(
    /period=annual/.test(body),
    'SEC is asked for ANNUAL periods — period=quarter answers 422, measured',
  )
  // BOTH indexes must exist. `indexOf` returns -1 for a missing needle and -1 is less than any
  // real index, so a bare `sec < yfinance` PASSES when SEC is gone — an ordering guard that is
  // satisfied by absence of the thing being ordered.
  check(
    body.indexOf('provider=sec') > -1 &&
      body.indexOf('provider=yfinance') > -1 &&
      body.indexOf('provider=sec') < body.indexOf('provider=yfinance'),
    'SEC is tried BEFORE yfinance — the filing carries the currency and 18 periods, the fallback carries 4 and none',
  )
  // SCOPED TO THE SEC HALF, and that is the whole point of the guard. The yfinance branch below
  // writes the identical line, so an unscoped `/currency: r.reported_currency/` matched even with
  // the SEC write deleted — it passed a mutation and certified nothing. Position is what
  // distinguishes them: the SEC write must land BEFORE the fallback's call.
  check(
    body.indexOf('currency: r.reported_currency') > -1 &&
      body.indexOf('currency: r.reported_currency') < body.indexOf('provider=yfinance'),
    'reported_currency is written to the currency COLUMN IN THE SEC BRANCH — the column has existed since migration 29 and is 0 of 104,972 because the fallback provider never sends it',
  )
  check(
    /source_code:\s*'sec'/.test(body),
    "rows from the filing are attributed to 'sec', so a later disagreement can be resolved by source priority",
  )
  check(
    /item\.usTicker/.test(body) && /if \(!item\.usTicker\) continue/.test(body),
    'SEC is skipped when there is no US ticker rather than asked with a symbol it cannot resolve (SAP works, SAP.DE does not)',
  )
  check(
    /group\.every\(\(g\) => rowsFor\.has/.test(body),
    'yfinance is not called when the filing already answered — a 4-period series must not overwrite an 18-period one',
  )
  check(
    /secFailed\+\+/.test(body) && !/usTicker[\s\S]{0,400}statements_missing_at/.test(body),
    'a SEC failure is counted, NOT marked — yfinance is the fallback, and a foreign filer legitimately has nothing there',
  )
  // A THROTTLE MUST STILL TAKE THE FAILURE PATH, or the classifier's new SEC wordings could let a
  // rate limit mark a page. Ordering is load-bearing: `throttled` is tested BEFORE the absence
  // classifier, so a refusal can never reach it.
  check(
    /throttled\(msg\)[\s\S]{0,120}throttledOut = true; break \}[\s\S]{0,1200}?noDataForSymbol\(msg\)/.test(body),
    'a throttle is classified BEFORE the absence wordings, so a refusal can never mark a symbol',
  )
  // The widening needs its own exit, or the `no_currency` half re-asks for ever — the shape that
  // has now cost this pipeline five separate resources.
  check(
    /update\(\{\s*statement_currency_missing_at:/.test(body),
    'a company SEC has no filings for is recorded, so the no_currency half of the backlog can drain',
  )
  // THE RULE MOVED RATHER THAN RELAXED. The EMPTY-ANSWER path still carries all three conditions —
  // asked to completion, produced nothing, and the endpoint answered for someone this run — which
  // is the right guard against an outage being recorded as a page of dead securities. What was
  // added beside it is a path for a 404 that NAMES the symbol, which is evidence about that symbol
  // and needs no tally in front of it. Requiring the tally there is what kept 2,432 securities at
  // the head of a weight-ordered backlog for ever: with `fromSec: 0` the whole page is
  // unanswerable, so `secOk` can never become true.
  check(
    /\(secAsked && secRows === 0 && secOk\)/.test(body),
    'the EMPTY-ANSWER mark still requires the security to have been asked to completion AND the endpoint to have answered for someone — a failure, a throttle or a deadline is not evidence it does not file',
  )
  check(
    /secOk = true/.test(body),
    'secOk is actually set when SEC returns rows — an success flag that is never raised marks nothing, and one that is never checked marks everything',
  )
}


// ── every source a function WRITES must be a source some migration CREATED ───────────────────
//
// `security_statement.source_code` and its siblings are foreign keys to `market.data_source`.
// Migration 88 shipped a resource writing `source_code: 'sec'` with no migration creating that
// row, and the FIRST REAL RUN in production died with
// `violates foreign key constraint "security_statement_source_code_fkey"` — taking the whole
// resource with it, including rows from the provider that WAS registered.
//
// Nothing could have caught it downstream: the migration tests apply to a database where no
// resource runs, so the constraint is never exercised, and every offline check passed.
// Migration 67 got it right for Tiingo by seeding the source alongside the resource; this makes
// that a rule instead of a habit.
console.log('\nevery source_code written by a function is seeded by a migration')
{
  const dir = new URL('../', import.meta.url)
  let fnText = ''
  for await (const e of Deno.readDir(dir)) {
    if (!e.isDirectory) continue
    for await (const f of Deno.readDir(new URL(e.name + '/', dir))) {
      if (f.isFile && f.name.endsWith('.ts') && f.name !== 'logic-check.ts') {
        fnText += await Deno.readTextFile(new URL(`${e.name}/${f.name}`, dir))
      }
    }
  }
  const written = new Set(
    [...fnText.matchAll(/source_code:\s*'([a-z0-9_-]+)'/g)].map((m) => m[1]),
  )

  let migText = ''
  for await (const sql of migrationSql()) migText += sql
  // Only the data_source inserts, so a source merely MENTIONED in a comment cannot vouch for itself.
  const seeded = new Set<string>()
  for (const m of migText.matchAll(/insert\s+into\s+market\.data_source[\s\S]{0,2000}?;/gi)) {
    for (const v of m[0].matchAll(/\(\s*'([a-z0-9_-]+)'\s*,/g)) seeded.add(v[1])
  }

  check(written.size > 0, `at least one source_code literal was found (${written.size})`)
  check(seeded.size > 0, `at least one data_source seed was found (${seeded.size})`)
  for (const code of [...written].sort()) {
    check(
      seeded.has(code),
      `'${code}' is written by a function AND seeded by a migration — an unseeded source is a foreign key violation on the resource's first real run, not a typecheck error`,
    )
  }
}



// ── security-share-stats ─────────────────────────────────────────────────────────────────────
console.log('\nsecurity-share-stats')
{
  const idx = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  const seg = idx.slice(idx.indexOf('resource === SHARE_STATS_RESOURCE'))
  // Bounded by the NEXT handler, whichever it is, so deleting a neighbour cannot stretch the
  // window over the rest of the file.
  const body = seg.slice(0, seg.indexOf('\n    if (resource === ', 1)).replace(/\/\/[^\n]*/g, '')

  check(
    /share_statistics/.test(body) && /estimates\/consensus/.test(body),
    'one batch of symbols answers BOTH endpoints — splitting them doubles the requests for two halves of one row',
  )
  check(
    /as_of: String\(r\.date \?\? ''\)/.test(body),
    "share statistics are keyed on the PROVIDER's date — keying on the fetch date mints a row per run and calls it history",
  )
  check(
    /from\('currency'\)[\s\S]{0,200}upsert/.test(body),
    'currency codes are LEARNED before the estimate write — currency_code is a foreign key, so an unseen code fails the STATEMENT and takes the batch with it',
  )
  check(
    /const batchClean = !statIso\.error && statRows\.length > 0/.test(body),
    "a security is marked missing only when THIS batch answered — a run-wide tally is the 'if any of the 40 answered, blame the rest' rule yfinance defeats by omitting symbols from a 200",
  )
  // ONE BAD SYMBOL KILLS A BATCHED CALL, and this backlog is ordered by fund weight — so an
  // unisolated 400 brings the SAME poisoned head back every run and the resource stalls for ever.
  // Observed live: `openbb 400 on /equity/estimates/consensus?symbol=HUMANSFT.KW,ROST,...` took
  // all 40 symbols with it and `remaining` sat at 11,136 across eight consecutive runs.
  check(
    (body.match(/fetchWithIsolation/g) ?? []).length >= 2,
    'BOTH batched calls are isolated — an unisolated 400 stalls a weight-ordered backlog on its own head',
  )
  check(
    /dead\.has\(g\.fetchSymbol\.toUpperCase\(\)\)/.test(body),
    'a symbol the provider rejects ALONE is marked, which is what lets the weight-ordered head advance past it rather than re-poisoning every future batch',
  )
  check(
    !/\* 100/.test(body) && !/\/ 100/.test(body),
    'no unit conversion on write — these fields are fractions and stay fractions, because converting here hides the convention from every reader',
  )
}


// ── migration filenames must sort numerically under a STRING sort ────────────────────────────
//
// Every place that enumerates migrations sorts them as strings: Ansible's Jinja `| sort`, which
// has no numeric option at all; CI's `ls | sort`; the local harness. Invisible for 99 migrations
// and wrong on the hundredth — measured, jinja sorts
// ['02-market.sql', '100-news.sql', '29-x.sql', '99-ifrs.sql'], so `100-` runs before the schema
// it depends on and the deploy fails on a file that is entirely correct.
//
// Zero-padding to three digits makes lexicographic order BE numeric order, needing no `sort -V`
// (absent from some busybox builds) and no Jinja gymnastics.
//
// This lives here rather than in a SQL test because it is a fact about FILENAMES. The SQL version
// used `pg_ls_dir` and passed locally only because the repo happened to be mounted into the
// database container; in CI Postgres is a service container that cannot see the repo at all.
console.log('\nmigration filenames sort numerically')
{
  // THE LEGACY DIRECTORY, because that is where the zero-padded convention lives and where the
  // defect it guards against happened. `migrations/` uses Supabase's `<timestamp>_name.sql`
  // convention, which the CLI orders and which is checked separately below — asserting `^\d{3}-`
  // there would fail on the baseline for being correctly named.
  const dir = new URL('../../migrations-legacy/', import.meta.url)
  const names: string[] = []
  for await (const e of Deno.readDir(dir)) {
    if (e.isFile && e.name.endsWith('.sql')) names.push(e.name)
  }
  check(names.length > 50, `the legacy migrations directory was found (${names.length} files)`)

  const bad = names.filter((n) => !/^\d{3}-/.test(n))
  check(
    bad.length === 0,
    'every legacy migration filename starts with a THREE-DIGIT zero-padded number',
    bad.length ? `not padded: ${bad.slice(0, 5).join(', ')}` : '',
  )

  // AND THE NEW CONVENTION GETS THE SAME TREATMENT. `supabase db push` orders by the leading
  // timestamp, so a file that does not carry one is applied in an order nobody chose — the same
  // class of defect as the unpadded prefix, in the naming scheme that replaces it.
  const newNames: string[] = []
  for await (const e of Deno.readDir(new URL('../../migrations/', import.meta.url))) {
    if (e.isFile && e.name.endsWith('.sql')) newNames.push(e.name)
  }
  check(newNames.length > 0, `the migrations directory was found (${newNames.length} files)`)
  const misnamed = newNames.filter((n) => !/^\d{14}_/.test(n))
  check(
    misnamed.length === 0,
    'every migration filename carries a 14-digit timestamp, as the Supabase CLI expects',
    misnamed.length ? `not timestamped: ${misnamed.slice(0, 5).join(', ')}` : '',
  )

  // The property itself, asserted rather than inferred from the naming rule: sorting the names as
  // STRINGS must give the same order as sorting them by their number.
  const numOf = (n: string) => Number(n.slice(0, n.indexOf('-')))
  const lexical = [...names].sort()
  const numeric = [...names].sort((a, b) => numOf(a) - numOf(b))
  const firstDiff = lexical.findIndex((n, i) => n !== numeric[i])
  check(
    firstDiff === -1,
    'a plain string sort of the migrations equals a numeric sort',
    firstDiff === -1 ? '' : `diverges at ${firstDiff}: string sort has ${lexical[firstDiff]}, numeric has ${numeric[firstDiff]}`,
  )
}



// ── THE EPS SURPRISE UNIT IS DECIDED IN ONE PLACE, AND THE SOURCE DECIDES IT ───────────────────
//
// Two spellings of the same number exist and they differ by 100x:
//
//   openbb's wrapper   `surprise_percent`     0.125891   a FRACTION
//   the raw provider   `surprisePercentage`   12.5891    a PERCENT
//
// The resource calls the provider DIRECTLY — it has to, because a rate-limited response arrives as
// a 200 that openbb turns into a 204 indistinguishable from "no data" — so it must NOT multiply.
// Multiplying would report a 12.59% beat as 1,259% and dividing would report it as 0.13%; both are
// plausible enough to survive a glance, which is why this is pinned rather than left to a comment.
//
// SETTLED BY MEASUREMENT, 2026-08-22. The raw payload was read directly once the quota reset:
// MSFT's 2026-06-30 quarter reports 4.74 against an estimated 4.21, and `surprisePercentage` is
// 12.5891 — which is (4.74 - 4.21) / 4.21 as a PERCENT, not a fraction. openbb's wrapper sends
// 0.125891 for the same quarter, so it is the wrapper that divides. The earlier note here recorded
// this as inferred-but-unverified; it is now arithmetic against a known beat.
{
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  const av = await Deno.readTextFile(new URL('./alpha-vantage.ts', import.meta.url))
  check(/surprisePct:\s*num\(r\.surprisePercentage\)/.test(av),
    'the surprise percent is read from the raw provider field',
    'alpha-vantage.ts must map `surprisePercentage`, not the wrapper\'s `surprise_percent`')
  check(/surprise_pct:\s*q\.surprisePct,/.test(src) && !/q\.surprisePct\s*\*\s*100/.test(src),
    'the raw provider percent is stored unscaled — it is already a percent',
    'multiplying would report a 12.59% beat as 1,259%')

  // ── AN EMPTY BODY IS AN ANSWER ABOUT THE SYMBOL; AN EMPTY ARRAY IS NOT ───────────────────────
  //
  // Measured 2026-08-22: `ASMLF` returns `{}` with ZERO keys while `ASML` returns 108 quarters in
  // the same minute. That zero-key test is the whole discriminator — a renamed field would leave
  // `symbol` and `annualEarnings` behind, so it can never be mistaken for a symbol the provider
  // does not carry. Pinned on the KEY COUNT specifically: relaxing it to "no quarterlyEarnings"
  // would let a renamed field mark every security in the page as uncovered.
  check(/Object\.keys\(body\)\.length === 0/.test(av) && /notCovered: true/.test(av),
    'an empty provider body is classified as "does not carry this symbol", by key count',
    'alpha-vantage.ts must distinguish a zero-key body from a shape it did not expect')

  // And the caller may mark ONLY on that flag. The backlog is ordered by fund weight, so a symbol
  // the provider cannot answer sits at the head and is re-asked every run until something records
  // that we asked — the fifth stall of this shape in this schema. Marking on `quarters.length === 0`
  // instead would re-introduce the defect the flag exists to prevent, because a throttled or
  // renamed response is empty too.
  //
  // Anchored on the LOOP, not on the handler's first `finish_refresh` — this handler calls that
  // three times (the missing-key return, the drained-backlog return, and the tail), so the obvious
  // window ends 290 characters in, before the loop it is meant to cover. Written that way first,
  // and it failed rather than passing vacuously only because the branch it looks for sits after
  // the cut. That is the same "anchored on the first match in the file" trap logic-check already
  // records one level down.
  const eps = src.slice(src.indexOf('resource === EPS_HISTORY_RESOURCE'))
  const loopAt = eps.indexOf('for (const [i, item] of wanted.entries())')
  const marking = eps.slice(loopAt, eps.indexOf('p_ok: !rateLimited'))
  check(loopAt > 0 && marking.length > 500,
    'the EPS marking window covers the loop',
    `window is ${marking.length} chars — the anchors have moved`)
  check(/if \(got\.notCovered\) \{/.test(marking) &&
        !/quarters\.length === 0[\s\S]{0,200}eps_history_fetched_at/.test(marking),
    'the EPS backlog marks a symbol only when the provider said it does not carry it',
    'marking on an empty result would mark every security in a throttled page')
}

// ── `adj_price_target` IS THE NEW TARGET AND `price_target` IS THE PREVIOUS ONE ────────────────
//
// The names invite the opposite reading, which is why this is pinned rather than left to a comment.
// Measured 2026-09-07 over 160 rows across eight symbols:
//
//   both fields present        90
//   `adj_price_target` alone   55     Initiated / Resumed — there IS no previous target
//   `price_target` alone        0     never happens
//   neither                    15
//
// and where both appear they ALWAYS differ (48 of 48), which rules out `adj` meaning
// split-adjusted. So `adj_price_target` is the target the analyst has just set. Reading
// `price_target` as "the price target" would store the SUPERSEDED number and be null 40% of the
// time, while looking entirely reasonable on a page — this schema's signature failure.
{
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  // BOUNDED AT BOTH ENDS. Sliced only from the start, this window ran to the end of the file and
  // the "no flat headroom" check below matched FOUR other handlers that legitimately use
  // `deadline - 8_000` — a guard failing for a reason unrelated to what it tests. That is the
  // "anchored on the first match in the file" trap this file already records one level down, and
  // it was committed here anyway; the fix for it is a real end marker, not a cleverer pattern.
  const ptStart = src.indexOf('resource === PRICE_TARGETS_RESOURCE')
  const ptEnd = src.indexOf("remaining: await backlogSize(market, 'pending_price_targets')", ptStart)
  const pt = ptStart >= 0 && ptEnd > ptStart ? src.slice(ptStart, ptEnd) : ''
  check(pt.length > 500, 'the price-target handler is findable and bounded',
    'an anchor has moved and every check below would pass vacuously or match a neighbour')
  check(/target_to:\s*num\(r\.adj_price_target\)/.test(pt),
    'the CURRENT target is read from `adj_price_target`',
    'reading `price_target` stores the superseded number and is null 40% of the time')
  check(/target_from:\s*num\(r\.price_target\)/.test(pt),
    'the PREVIOUS target is read from `price_target`',
    'the two fields are the opposite way round from what their names suggest')

  // THE CURSOR ADVANCES ON A SUCCESSFUL ASK, NOT ON ROWS. A US small cap with no analyst coverage
  // legitimately returns nothing; advancing only on rows would leave it at the head of a
  // weight-ordered backlog for ever — the stall this schema has hit in five separate resources.
  // `fetchWithIsolation` returns a null error only when the provider demonstrably answered, so it
  // is the honest gate. Anchored inside the handler, because `!iso.error` appears elsewhere.
  check(/if \(!iso\.error\) \{[\s\S]{0,400}price_targets_fetched_at/.test(pt),
    'the price-target cursor advances for the whole group on a successful ask',
    'advancing only on answered symbols stalls every uncovered US small cap at the head')
  check(!/answered\.has[\s\S]{0,200}price_targets_fetched_at/.test(pt),
    'the cursor is not gated on a per-symbol answer',
    'that is the five-times-repeated stall in this schema')

  // THE BATCH BUDGET IS LEARNED, NOT A CONSTANT. The first version gated on a flat
  // `deadline - 8_000`; a batch of 40 measured ~15s against finviz, so the last batch of EVERY run
  // was started with 8s left and cut short, reporting `lastError: "Signal timed out."` on every
  // run for ever. Nothing was corrupted — the cursor correctly did not advance those securities —
  // but it poisons the one field an operator reads to tell whether anything is wrong. A bigger
  // constant would only re-tune the magic number to one afternoon's measurement.
  check(/lastBatchMs/.test(pt) && /Date\.now\(\) \+ lastBatchMs [\s\S]{0,40}> deadline/.test(pt),
    'a batch is started only if the LAST batch\'s measured duration still fits',
    'a flat headroom re-tunes a magic number and times out the final batch of every run')
  check(!/Date\.now\(\) < deadline - 8_000/.test(pt),
    'the flat 8s headroom is gone',
    'it guaranteed a timed-out final batch, because a batch costs about twice that')
  // AND A BATCH THAT ERRORED IS A FAILED BATCH. `fetchWithIsolation` RETURNS its error rather than
  // throwing, so the catch never sees it and the tally read `batchesFailed: 0` beside a batch that
  // answered nothing.
  check(/if \(iso\.error\) \{[\s\S]{0,120}batchesFailed\+\+/.test(pt),
    'an isolation error counts as a failed batch',
    'otherwise a run that answered nothing reports a clean tally')
}

// ── A WHOLE-TABLE SELECT IS SILENTLY CAPPED AT `PGRST_DB_MAX_ROWS` ─────────────────────────────
//
// This cap has now cost three separate defects: a `market-verify` guard that reported "1000" for
// ever as a measurement; the FX history probe that re-fetched the same four currencies because it
// could not see past its own page; and the earnings resource, which loaded `symbol_security`
// (12,090 rows) in ONE select and matched 22 of 753 companies — NVDA and CRM landing unresolved
// while both are tracked. None of them errored. A short answer is not an error, it is a shorter
// answer, and it reads as a fact about coverage.
//
// So a select from one of the LARGE tables must NARROW: `.in(`, `.eq(`, `.limit(`, a range filter,
// or a `head: true` count. Deliberately a named list rather than every table — the point is the
// tables big enough for the cap to bite in silence.
{
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  const BIG = ['symbol_security', 'security_metric', 'security_statement', 'security_price',
               'exchange_listing', 'fund_holding']
  const offenders: string[] = []
  const lines = src.split('\n')
  lines.forEach((l: string, i: number) => {
    const m = /\.from\('([a-z_]+)'\)/.exec(l)
    if (!m || !BIG.includes(m[1])) return
    // The whole chained statement, not one line: the narrowing is usually on the next.
    const stmt = lines.slice(i, i + 6).join(' ')
    // WRITES ARE NOT READS. `.upsert(`/`.delete(`/`.update(` carry their own rows or their own
    // filter and are not subject to the row cap at all — the first version of this guard matched
    // any `.from(` and reported eight upserts, which is the shape that gets a guard disabled.
    if (!/\.select\(/.test(stmt)) return
    if (/\.in\(|\.eq\(|\.limit\(|head:\s*true|\.lt\(|\.gt\(|\.gte\(|\.lte\(/.test(stmt)) return
    offenders.push(`line ${i + 1}: unnarrowed select from ${m[1]}`)
  })
  check(offenders.length === 0,
    'no select from a large table is left unnarrowed — PGRST_DB_MAX_ROWS truncates it silently',
    offenders.join(' | '))
}


// ── every invocation is recorded, in ONE place ───────────────────────────────
// `market.refresh_log` is keyed `resource text PRIMARY KEY`, so it holds the latest run and
// nothing else — no history, by construction. `market.refresh_run` is the history, and it is
// written by a wrapper around the handler rather than at the ~40 `return json(...)` sites, so that
// a resource added below one of them cannot be silently unrecorded.
//
// That design only holds while the wrapper is the ONLY entrypoint. These assertions are what stops
// someone reinstating an inline `Deno.serve(async (req) => { ...5,200 lines... })` and quietly
// ending the record.
console.log('\nrefresh_run — every invocation is recorded')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))

  const serves = [...index.matchAll(/Deno\.serve\(/g)].length
  check(serves === 1, 'exactly one Deno.serve entrypoint', `found ${serves}`)
  check(/async function handle\(req: Request\): Promise<Response>/.test(index),
    'the handler is a named function the wrapper can call')

  const wrapper = index.slice(index.lastIndexOf('Deno.serve('))
  check(/const res = await handle\(req\)/.test(wrapper),
    'the wrapper delegates to handle()')
  // AWAITED, not fire-and-forget. `void recordRun(...)` returns before the insert lands and the
  // edge worker can be torn down underneath it — a record that is usually there is not a record.
  check(/await recordRun\(res\.clone\(\), /.test(wrapper),
    'recordRun is AWAITED and reads a CLONE (the original response still has to reach the caller)')
  check(!/void\s+recordRun/.test(index),
    'recordRun is never fire-and-forget')

  // The request body is read from a clone too: a Request body can be read once, and `handle`
  // reads it itself. Without this every resource silently falls back to the default.
  check(/await req\.clone\(\)\.json\(\)/.test(wrapper),
    'the wrapper reads the resource from a CLONED request')

  const body = index.slice(index.indexOf('async function recordRun'))
  // A metrics write that can break a refresh is strictly worse than no metrics.
  check(/abortSignal\(AbortSignal\.timeout\(/.test(body.slice(0, body.indexOf('Deno.serve('))),
    'the insert is bounded by a timeout, so an unreachable database cannot eat the worker budget')

  // `written`, `remaining` and `failed` are GENERATED ALWAYS columns (migration 127). Postgres
  // rejects an INSERT that supplies one — `cannot insert a non-DEFAULT value into column` — so
  // adding them here would fail EVERY run, not just an edge case.
  // Sliced FORWARD from the insert. `indexOf('} catch')` from the top of the function finds the
  // INNER catch around `res.json()`, which sits before the insert — the slice came back empty and
  // the last assertion below failed against code that was perfectly correct. Same shape as the
  // sweep-deadline guard that matched the wrong `while (Date.now()...)`.
  const from = body.indexOf(".from('refresh_run')")
  const insert = body.slice(from, body.indexOf('} catch', from))
  const generated = ['written', 'remaining', 'failed'].filter((c) =>
    new RegExp(`^\\s*${c}\\s*[,:]`, 'm').test(insert))
  check(generated.length === 0,
    'the insert does not supply the generated columns',
    generated.length ? `supplies ${generated.join(', ')}` : 'none')

  // A skip is a SUCCESS and must stay distinguishable from a run that did work.
  check(/skipped/.test(insert), 'a skipped run is recorded as such, not as a failure')
}

// ── the member-role table is READ, not merely created ──────────────────────────────────────────
// A CONTROL TABLE NOTHING READS IS DECORATION, and this repo has shipped that twice: migration 163
// created `filing_form` and left the hardcoded form list in place, and `exchange-listings` was
// deployed, reachable and absent from the cron. `segment_member_class` decides which members are a
// subtotal (dropped) and which are a residual (kept, but never a split on their own) — wired up it
// is the fix for Chevron's 581m "breakdown", and unwired it is a table with six rows in it.
{
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  check(/from\('segment_member_class'\)/.test(src),
    'the resource reads market.segment_member_class')
  const calls = [...src.matchAll(/segmentFactsFrom\(([^)]*)\)/g)].map((m) => m[1])
  check(calls.length > 0 && calls.every((a) => a.split(',').length === 4),
    'every segmentFactsFrom call passes the member roles',
    `${calls.length} call(s): ${calls.map((c) => c.split(',').length).join(', ')} args`)
}

// ── a retraction fires only on a document that was READ ────────────────────────────────────────
// A DELETE keyed on a filing is the one operation here that destroys data, and `facts.length === 0`
// has FOUR causes: no index entry, a null fetch, a size refusal, and a filing that genuinely
// discloses no segments. Only the last is evidence. The first version of this retraction ran
// unconditionally behind a comment asserting "a fetch that THREW never reaches here" — true of a
// throw, false of a null — and 281 filings took that path in three hours while `security_segment`
// fell by 91 rows during an active re-parse. Seventh instance of throw-vs-empty in this pipeline.
//
// The guard is on the GATE, not on the delete: a delete with no condition in front of it is the
// defect, so the assertion is that each retraction sits inside a test of the parsed document.
{
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  // FIFTEEN LINES OF LOOKBACK, not two. The gate is not always the line directly above the delete —
  // the NSE writer has an explanatory comment between them, and a two-line window reported a
  // correctly-gated retraction as ungated. A window that is too NARROW fails safe (it cries wolf)
  // while one that is too wide fails open, so this is deliberately generous and the gate
  // expressions below stay specific.
  const retractions = [...src.matchAll(/((?:[^\n]*\n){15})[ ]*const \{ error: rtErr \}/g)]
  // FOUR writers now — SEC, DART, NSE and CNINFO. The number is asserted rather than counted
  // loosely so that adding another is a deliberate act that comes here and reads this comment.
  check(retractions.length === 4,
    'every segment writer retracts per accession', `found ${retractions.length}`)
  // THREE LEGAL SHAPES, because the sources fail differently. SEC and DART can return an oversize
  // document, so they gate on `xml !== null && !oversize`. NSE cannot — its instances are 77-109 KB
  // and there is no size gate — but it CAN return the standalone filing rather than the
  // consolidated one, so its retraction sits inside the branch where `normalise` returned a
  // document. CNINFO downloads a 1-6 MB PDF that can be absent, oversized or not a PDF at all, so
  // its retraction sits inside the branch where `fetchReport` returned BYTES and the parse ran.
  // All three are a test of the parsed document, which is what this guard is really asserting;
  // what it must never accept is a delete with nothing in front of it.
  const gated = (before: string) =>
    (/if \((typeof )?xml (!==|===) /.test(before) && /!oversize/.test(before)) ||
    /NOT_CONSOLIDATED/.test(before) || /segmentFactsFrom\(norm\.xml/.test(before) ||
    /segmentFactsFromPdf\(bytes\)/.test(before)
  check(retractions.every((m) => gated(m[1])),
    'every retraction is gated on the document having been read',
    retractions.map((m) => m[1].trim().split('\n')[0].slice(0, 40)).join(' | '))

  // AND KEYED ON THE ACCESSION. Found by mutation: dropping `.eq('accession_number', …)` passed
  // every check above, and it is the worst defect available here — the delete would take a
  // company's ENTIRE segment history instead of one filing's, on every re-parse, silently. The
  // accession is what makes the retraction the filing's own statement of itself; without it this
  // is not a retraction, it is a purge.
  const keyed = [...src.matchAll(
    /const \{ error: rtErr \}[\s\S]{0,220}?security_segment'\)\.delete\(\)([\s\S]{0,200}?)(?:\n\s*if|\n\s*\n)/g,
  )]
  check(keyed.length === retractions.length && keyed.every((m) => /accession_number/.test(m[1])),
    'and every retraction is keyed on the ACCESSION, not just the security',
    `${keyed.filter((m) => /accession_number/.test(m[1])).length} of ${keyed.length}`)
}


console.log(failures === 0 ? '\nALL LOGIC CHECKS PASSED' : `\n${failures} LOGIC CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
