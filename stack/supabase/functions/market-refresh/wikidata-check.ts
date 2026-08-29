/**
 * Offline checks for the Wikidata industry parser. No network, no database.
 *
 * Wikidata is crowd-sourced and its shape is looser than any other source here, so the failures
 * this guards against are all shapes rather than values: an ISIN that matched a company but has no
 * industries, a duplicate label that would insert the same taxonomy node twice in one statement,
 * and a label that slugs to something a join key can never match.
 */
import { buildQuery, industriesFrom, slug } from './wikidata.ts'

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

const binding = (isin: string, name: string, industries: string) => ({
  isin: { value: isin }, name: { value: name }, industries: { value: industries },
})

console.log('wikidata industries')

// 1. MULTI-VALUED IS THE POINT. Every other source here gives one answer per security; this one
//    gives a list, and flattening it to the first entry would make the resource pointless.
{
  const out = industriesFrom({ results: { bindings: [
    binding('US0231351067', 'Amazon', 'retail|web service|e-commerce|web hosting service'),
  ] } })
  check(out.length === 1 && out[0].industries.length === 4,
    'a company with four industries yields four', JSON.stringify(out[0]?.industries))
}

// 2. A MATCH WITH NO INDUSTRIES IS AN ANSWER, NOT A ROW. `GROUP_CONCAT` over an OPTIONAL that
//    matched nothing returns the empty string; splitting it naively yields `['']`, which would
//    slug to '' and insert a nameless taxonomy node.
{
  const out = industriesFrom({ results: { bindings: [binding('X', 'Shell Co', '')] } })
  check(out.length === 1 && out[0].industries.length === 0,
    'an empty industry list is empty, not a list containing one blank',
    JSON.stringify(out[0]?.industries))
}

// 3. DUPLICATES ARE REMOVED BEFORE THEY REACH AN UPSERT. `DISTINCT` inside GROUP_CONCAT still
//    yields repeats when two labels differ only by whitespace, and the same node twice in one
//    statement is `ON CONFLICT DO UPDATE command cannot affect row a second time` — SQLSTATE
//    21000, which fails the whole batch. Fourth instance of that shape in this schema.
{
  const out = industriesFrom({ results: { bindings: [
    binding('X', 'Dupe Co', 'retail| retail |software industry|retail'),
  ] } })
  check(out[0].industries.length === 2,
    'labels differing only by whitespace collapse to one', JSON.stringify(out[0].industries))
}

// 4. A SLUG IS A JOIN KEY. `taxonomy_node.code` is joined on, so a code containing spaces,
//    punctuation or accents is one transcription away from never matching.
{
  check(slug('Fast-moving consumer goods') === 'fast-moving-consumer-goods', 'spaces and hyphens')
  check(slug('E-commerce') === 'e-commerce', 'a leading-letter hyphen survives')
  check(slug('  Retail  ') === 'retail', 'surrounding space is trimmed, not encoded')
  check(slug('Fabricação de café') === 'fabricacao-de-cafe', 'accents are folded, not dropped')
  check(!slug('Semiconductor industry').startsWith('-') && !slug('Retail!').endsWith('-'),
    'a slug never starts or ends with a separator')
  check(slug('x'.repeat(200)).length <= 80, 'a very long label is bounded')
}

// 5. THE QUERY IS BUILT FROM SANITISED ISINs. An ISIN reaches this from the database, but a SPARQL
//    string literal is still a string literal — a stray quote would end it and the rest of the
//    value would be executed as query text.
{
  const q = buildQuery(['US0378331005', 'X" } INJECTED {'])
  check(q.includes('"US0378331005"'), 'a real ISIN is quoted as a value')
  check(!q.includes('INJECTED {'), 'punctuation is stripped, so nothing escapes the literal',
    q.slice(q.indexOf('VALUES'), q.indexOf('VALUES') + 60))
}

// 6. A BINDING WITH NO ISIN IS SKIPPED rather than stored under an empty key, which would attach
//    every unmatched company's industries to one phantom security.
{
  const out = industriesFrom({ results: { bindings: [
    { name: { value: 'Nameless' }, industries: { value: 'retail' } },
  ] } })
  check(out.length === 0, 'a result with no ISIN is dropped')
  check(industriesFrom({}).length === 0, 'an empty payload yields nothing rather than throwing')
}

console.log(failures === 0 ? '\nALL WIKIDATA CHECKS PASSED' : `\n${failures} WIKIDATA CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
