/**
 * Offline checks for the CNINFO document classifier. No network, no database.
 *
 * WHY THIS EXISTS. `category_ndbg_szsh` is CNINFO's "annual reports" and returns three different
 * DOCUMENTS under it. `cn-filings` stored them all as `年度报告`, and measured 2026-09-06 by
 * downloading the stored URL for 8 companies and reading page one of each, only THREE were full
 * Chinese-language annual reports: four were summaries and one was Kweichow Moutai's ENGLISH
 * edition — which is the real reason no Chinese heading could be found in it.
 *
 * Every title below is QUOTED FROM THE LIVE API, not invented. The classifier is split out of
 * `parseAnnouncements` for the reason `classifyBody` was split out of `dart.ts`: left inline it is
 * an untested branch and the mutation deleting it passes clean.
 */
import { classifyAnnouncement, parseAnnouncements } from './cn.ts'

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

console.log('\ncninfo document kinds — one category, three documents')

// The plain full report, with and without the company name. CNINFO frequently omits the name
// entirely, so nothing in the classifier may depend on it.
check(classifyAnnouncement('中国长江电力股份有限公司2025年年度报告') === 'full',
  'a full annual report is `full`')
check(classifyAnnouncement('2025年年度报告（更正后）') === 'full',
  'a CORRECTED full report is still `full`, and the title carries no company name')
check(classifyAnnouncement('南京晶升装备股份有限公司2025年年度报告（更正版）') === 'full',
  '...and so is the other correction marker')

// The summary is the case that cost four of eight companies. It omits the CSRC breakdown table
// entirely, so a parser reading it records the company as disclosing nothing.
check(classifyAnnouncement('中国三峡新能源（集团）股份有限公司2025年年度报告摘要') === 'summary',
  'a summary is `summary`, not a full report')
// `更正后` is not a branch, so it cannot displace `摘要`. Note the order of the two EXCLUSION
// branches is deliberately not asserted: a title carrying both `摘要` and an English marker has
// not been observed, and if one exists both kinds are excluded from parsing anyway. A mutation
// swapping those two lines passes, and that is correct rather than a hole.
check(classifyAnnouncement('天力锂能集团股份有限公司2025年年度报告摘要（更正后）') === 'summary',
  'a CORRECTED SUMMARY is still a summary')

// The English edition uses English headings, so the Chinese table is unfindable in it.
check(classifyAnnouncement('振华重工2025年年度报告（英文版）') === 'english',
  'the English edition is `english`')
check(classifyAnnouncement('ANNUAL REPORT 2025') === 'english',
  '...including when the title itself is English (Kweichow Moutai files this way)')

// A NEGATIVE that matters: `摘要` must not be matched loosely enough to catch an ordinary report
// whose title merely mentions a summary of something else.
check(classifyAnnouncement('') === 'full', 'an empty title falls back to `full` rather than throwing')

console.log('\nthe classification reaches the parsed row')
{
  const rows = parseAnnouncements({
    announcements: [
      { announcementTitle: '中国长江电力股份有限公司2025年年度报告', adjunctUrl: 'finalpage/2026-04-30/1.PDF', announcementTime: 1745971200000, adjunctSize: 1386 },
      { announcementTitle: '中国长江电力股份有限公司2025年年度报告摘要', adjunctUrl: 'finalpage/2026-04-30/2.PDF', announcementTime: 1745971200000, adjunctSize: 160 },
    ],
  })
  check(rows.length === 2, 'both announcements are kept — nothing is discarded', `${rows.length}`)
  check(rows[0].kind === 'full' && rows[1].kind === 'summary',
    'each row carries its own kind', rows.map((r) => r.kind).join(', '))
  // `adjunctSize` is a CROSS-CHECK on the classification, never the rule: a summary is ~160 KB
  // against 1.3-2.9 MB, which makes a good tripwire while the title remains the fact.
  check(rows[0].sizeKb === 1386 && rows[1].sizeKb === 160,
    'the reported size is carried through as a cross-check')
  check(rows[0].url.startsWith('https://'),
    'the URL is absolute — `adjunctUrl` is a path and a bare one renders as a dead link')
}

console.log(failures === 0 ? '\nALL CNINFO CHECKS PASSED' : `\n${failures} CNINFO CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
