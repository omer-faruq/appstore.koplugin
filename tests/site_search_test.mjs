// site_search_test.mjs -- the website's copy of the search (docs/index.html).
// Run with Node 18+, from the plugin folder:
//   node tests/site_search_test.mjs
//
// The page's SearchCore block and GitHub client are cut out of index.html and run
// here against the same kind of fake GitHub search as tests/appstore_search_test.lua
// (the 1000-result ceiling, 422 past it, sort=stars) and the same live snapshot, so
// the site is held to the plugin's request counts.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
// Line endings normalised: a Windows checkout (core.autocrlf) has CRLF, and the cuts below
// look for "\n};\n".
const html = readFileSync(join(root, 'docs', 'index.html'), 'utf8').replace(/\r\n/g, '\n');

function cut(startMarker, endMarker) {
  const a = html.indexOf(startMarker);
  const b = html.indexOf(endMarker, a);
  if (a < 0 || b < 0) throw new Error(`markers not found: ${startMarker}`);
  return html.slice(a, b);
}
const coreSrc = cut('const SearchCore = {', '// ─── search-core:end');
const SearchCore = new Function(`${coreSrc}\nreturn SearchCore;`)();

let failures = 0;
function check(label, got, expected) {
  if (got === expected) {
    console.log('PASS', label);
  } else {
    failures++;
    console.log('FAIL', label, 'expected=', expected, 'got=', got);
  }
}

// ── Fake GitHub search ─────────────────────────────────────────────────────
function newFakeGitHub(repos) {
  for (const r of repos) r.created_at = r.created_at || SearchCore.isoTime(r.created_ts);
  repos.sort((a, b) => (b.stargazers_count - a.stargazers_count) || (a.tie - b.tie));
  const gh = { calls: 0, rejected: 0, queries: [] };
  gh.fetch = async (query, page, perPage) => {
    gh.calls++;
    if (gh.calls > 5000) throw new Error('runaway: over 5000 requests');
    gh.queries.push(query);
    let sLo = 0;
    for (const m of query.matchAll(/stars:>=(\d+)/g)) sLo = Math.max(sLo, Number(m[1]));
    let cLo = -Infinity, cHi = Infinity;
    for (const m of query.matchAll(/created:(\S+)\.\.(\S+)/g)) {
      cLo = Math.max(cLo, SearchCore.parseIso(m[1]));
      cHi = Math.min(cHi, SearchCore.parseIso(m[2]));
    }
    for (const m of query.matchAll(/created:>=(\S+)/g)) cLo = Math.max(cLo, SearchCore.parseIso(m[1]));
    if ((page - 1) * perPage >= 1000) {
      gh.rejected++;
      throw new Error('GitHub API 422: Only the first 1000 search results are available');
    }
    const first = (page - 1) * perPage, last = page * perPage;
    const items = [];
    let total = 0;
    for (const r of repos) {
      if (r.stargazers_count >= sLo && r.created_ts >= cLo && r.created_ts <= cHi) {
        if (total >= first && total < last) items.push(r);
        total++;
      }
    }
    // `serverClock`: GitHub's time moving on, two seconds a request, as a real Date
    // header does over a long search. (The page cannot read Date; SearchCore takes
    // `server_time` all the same, so the behaviour is held to the plugin's.)
    const response = { total_count: total, items };
    if (gh.serverClock) response.server_time = gh.serverClock + 2 * gh.calls;
    // Hooks for a GitHub that does not stand still: `tamper` edits the answer, `after`
    // changes the data between requests.
    if (gh.tamper) gh.tamper(response, query, page);
    if (gh.after) gh.after(repos);
    return response;
  };
  return gh;
}

// Seeded, so a failure reproduces (mulberry32).
function rng(seed) {
  let a = seed >>> 0;
  return n => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return Math.floor((((t ^ (t >>> 14)) >>> 0) / 4294967296) * n);
  };
}

const FROM = Date.UTC(2008, 3, 1) / 1000;
const NOW = Date.UTC(2026, 10, 18, 12) / 1000;

function makeRepos(n, zeroShare, seed, skew = 1, oldStars = false) {
  const rand = rng(seed);
  const repos = [];
  for (let i = 1; i <= n; i++) {
    let stars = 0;
    if (rand(1000) >= zeroShare * 1000) stars = 1 + Math.floor(2 ** (rand(1400) / 100));
    const age = (rand(1000000) / 1000000) ** skew;
    if (oldStars) stars = Math.floor(stars * 4 * age);
    repos.push({ id: i, stargazers_count: stars, created_ts: NOW - Math.floor((NOW - FROM) * age), tie: rand(2147483647) });
  }
  return repos;
}

function loadSnapshot(branch) {
  const rand = rng(99);
  const repos = [];
  for (const line of readFileSync(join(root, 'tests', 'fixtures', 'koplugin_search_snapshot.txt'), 'utf8').split(/\r?\n/)) {
    const m = line.match(/^(\w+) (\d+) (\d+)/);
    if (m && m[1] === branch) {
      repos.push({ id: repos.length + 1, created_ts: Number(m[2]), stargazers_count: Number(m[3]), tie: rand(2147483647) });
    }
  }
  if (repos.length <= 1000) throw new Error(`snapshot has too few ${branch} rows`);
  return repos;
}

async function run(repos, opts = {}) {
  const gh = newFakeGitHub(repos);
  gh.tamper = opts.tamper;
  gh.after = opts.after;
  gh.serverClock = opts.serverClock;
  const seen = new Set();
  let warnings = 0, err = null, partial = false;
  try {
    ({ partial } = await SearchCore.collect('in:name ".koplugin"', {
      fetch: opts.fetch ? opts.fetch(gh) : gh.fetch,
      append: repo => seen.add(repo.id),
      minStars: opts.minStars || 0,
      now: opts.now || NOW,
      warn: () => { warnings++; },
    }));
  } catch (e) {
    err = e;
  }
  return { err, partial: partial === true, unique: seen.size, seen, gh, warnings };
}

// ── Correctness ────────────────────────────────────────────────────────────
for (const [label, repos] of [
  ['250 repos', makeRepos(250, 0.3, 11)],
  ['1000 repos', makeRepos(1000, 0.3, 12)],
  ['1076 repos', makeRepos(1076, 0.42, 13)],
  ['5000 repos', makeRepos(5000, 0.5, 14)],
  ['3000 repos all at 0 stars', makeRepos(3000, 1.0, 16)],
]) {
  const r = await run(repos);
  check(`${label}: no error`, r.err, null);
  check(`${label}: all collected`, r.unique, repos.length);
  check(`${label}: never asked past 1000`, r.gh.rejected, 0);
}
{
  const r = await run(makeRepos(250, 0.3, 11));
  check('250 repos: three pages, no extra queries', r.gh.calls, 3);
}
{
  const repos = makeRepos(3000, 0.5, 17);
  const r = await run(repos, { minStars: 1 });
  const want = repos.filter(x => x.stargazers_count >= 1).length;
  check('minStars=1: every starred repo collected', r.unique, want);
  check('minStars=1: no 0-star repo fetched', repos.some(x => x.stargazers_count === 0 && r.seen.has(x.id)), false);
}
{
  const repos = [];
  for (let i = 1; i <= 1500; i++) repos.push({ id: i, stargazers_count: 0, created_ts: Date.UTC(2024, 0, 1, 10) / 1000, tie: i });
  const r = await run(repos);
  check('1500 in one second: no error', r.err, null);
  check('1500 in one second: the reachable 1000 collected', r.unique, 1000);
  check('1500 in one second: warned', r.warnings > 0, true);
  check('1500 in one second: reported partial', r.partial, true);
  check('1500 in one second: never asked past 1000', r.gh.rejected, 0);
}
{
  const r = await run(makeRepos(2500, 0.3, 18), {
    fetch: gh => async (q, page, pp) => {
      if (gh.calls === 4) { gh.calls++; throw new Error('GitHub API 502: bad gateway'); }
      return gh.fetch(q, page, pp);
    },
  });
  check('failed request: error handed back', r.err && r.err.message, 'GitHub API 502: bad gateway');
  check('failed request: stopped right there', r.gh.calls, 5);
}

// ── The device clock is not GitHub's ───────────────────────────────────────
function withRecent(n, recent, seed) {
  const repos = makeRepos(n, 0.4, seed);
  for (let i = 1; i <= recent; i++) {
    repos.push({ id: n + i, stargazers_count: i % 3, tie: i, created_ts: NOW - 7200 + Math.floor(i * 7200 / recent) });
  }
  return repos;
}
for (const [label, repos, opts] of [
  ['clock 2 h behind, 300 repos', withRecent(250, 50, 31), { now: NOW - 7200 }],
  ['clock 2 h behind, 3000 repos', withRecent(2950, 50, 32), { now: NOW - 7200 }],
  ['clock reset to 2000, 300 repos', withRecent(250, 50, 33), { now: Date.UTC(2000, 0, 1) / 1000 }],
  ['clock reset to 2000, 3000 repos', withRecent(2950, 50, 34), { now: Date.UTC(2000, 0, 1) / 1000 }],
  ['clock a year ahead, 3000 repos', withRecent(2950, 50, 35), { now: NOW + 365 * 86400 }],
]) {
  const r = await run(repos, opts);
  check(`${label}: no error`, r.err, null);
  check(`${label}: all collected`, r.unique, repos.length);
  check(`${label}: never asked past 1000`, r.gh.rejected, 0);
}

// ── GitHub's answers change under the search ───────────────────────────────
function byStars(a, b) { return (b.stargazers_count - a.stargazers_count) || (a.tie - b.tie); }
{
  let missedRuns = 0;
  for (let seed = 1; seed <= 20; seed++) {
    const repos = makeRepos(3000, 0.3, 100 + seed);
    const all = repos.slice();
    const deleted = new Set();
    const pick = rng(500 + seed);
    let calls = 0;
    const r = await run(repos, {
      after: list => {
        calls++;
        if (calls % 2 === 0 && list.length > 0) deleted.add(list.splice(pick(list.length), 1)[0].id);
      },
    });
    const missed = all.filter(x => !deleted.has(x.id) && !r.seen.has(x.id)).length;
    if (missed > 0 || r.err) missedRuns++;
  }
  check('deletions mid-search: no surviving repo missed (20 seeds)', missedRuns, 0);
}
{
  let missedRuns = 0;
  for (let seed = 1; seed <= 20; seed++) {
    const repos = makeRepos(3000, 0.3, 200 + seed);
    const pick = rng(600 + seed);
    const r = await run(repos, {
      after: list => {
        list[pick(list.length)].stargazers_count += 50;
        list.sort(byStars);
      },
    });
    if (r.unique !== repos.length || r.err) missedRuns++;
  }
  check('stars moving mid-search: nothing missed (20 seeds)', missedRuns, 0);
}
{
  const repos = makeRepos(2500, 0.3, 41);
  const tampered = new Set();
  const r = await run(repos, {
    tamper: (response, query, page) => {
      if (page === 1 && !tampered.has(query)) {
        tampered.add(query);
        response.incomplete_results = true;
        response.items.pop();
      }
    },
  });
  check('incomplete_results once: no error', r.err, null);
  check('incomplete_results once: all collected', r.unique, 2500);
}
{
  // Flagged every time though nothing is missing: taken with a warning, not a failure.
  const r = await run(makeRepos(2500, 0.3, 42), { tamper: response => { response.incomplete_results = true; } });
  check('incomplete_results every time: no error', r.err, null);
  check('incomplete_results every time: all collected', r.unique, 2500);
  check('incomplete_results every time: warned', r.warnings > 0, true);
  check('incomplete_results every time: reported partial', r.partial, true);
  check(`incomplete_results every time: bounded cost (${r.gh.calls})`, r.gh.calls <= 120, true);
}

// ── Ties in a different order on every request ────────────────────────────
for (const zeroShare of [0.6, 0.95]) {
  const repos = makeRepos(3000, zeroShare, 43);
  const pick = rng(44);
  const r = await run(repos, {
    after: list => {
      for (const repo of list) repo.tie = pick(2147483647);
      list.sort(byStars);
    },
  });
  const label = `unstable tie order (${zeroShare * 100}% at 0 stars)`;
  check(`${label}: no error`, r.err, null);
  check(`${label}: all collected`, r.unique, 3000);
  check(`${label}: not partial (one-page pieces settle it)`, r.partial, false);
}

// ── A count GitHub never makes good ────────────────────────────────────────
{
  const plain = await run(makeRepos(3000, 0.3, 45));
  const r = await run(makeRepos(3000, 0.3, 45), { tamper: response => { response.total_count += 1; } });
  check('count one too high: no error', r.err, null);
  check('count one too high: all collected', r.unique, 3000);
  check('count one too high: reported partial (no way to tell)', r.partial, true);
  check(`count one too high: at most 2.5x the requests (${r.gh.calls} vs ${plain.gh.calls})`, r.gh.calls <= plain.gh.calls * 2.5, true);
}

// ── The newest window counted far over what the windows hold ───────────────
for (const [suffix, serverClock] of [['', null], [", GitHub's clock moving", NOW]]) {
  const r = await run(makeRepos(3000, 0.3, 46), {
    serverClock,
    tamper: (response, query) => {
      if (query.includes('created:>=') && response.total_count > 0) response.total_count += 1000;
    },
  });
  const label = `inflated open window${suffix}`;
  check(`${label}: stops (${r.gh.calls} requests)`, r.gh.calls <= 80, true);
  check(`${label}: no error, reported partial`, r.err === null && r.partial, true);
  check(`${label}: everything there is collected`, r.unique, 3000);
  const bad = r.gh.queries.filter(q => {
    const m = q.match(/created:>?=?(\d{4}-\d{2}-\d{2})/);
    return /NaN|Invalid|null|undefined/.test(q) || (m && Date.parse(m[1]) / 1000 > NOW + 2 * 86400);
  }).length;
  check(`${label}: no window in the future`, bad, 0);
}

// ── Every count inflated: the whole search has a request limit ─────────────
{
  const r = await run(makeRepos(3000, 0.3, 47), {
    tamper: response => { if (response.total_count > 0) response.total_count += 500; },
  });
  check('every count +500: no error', r.err, null);
  check(`every count +500: bounded (${r.gh.calls} requests)`, r.gh.calls <= 300, true);
  check('every count +500: reported partial', r.partial, true);
}

// ── The give-up paths report partial ───────────────────────────────────────
function dropOnMultiPage(response) {
  if (response.total_count > SearchCore.PER_PAGE && response.items.length > 0) response.items.pop();
}
{
  const r = await run(makeRepos(2500, 0.3, 48), { tamper: dropOnMultiPage });
  check('multi-page answers short: pieces settle it', r.unique, 2500);
  check('multi-page answers short: not partial', r.partial, false);
}
{
  const saved = SearchCore.MAX_DEPTH;
  SearchCore.MAX_DEPTH = 0;
  const r = await run(makeRepos(2500, 0.3, 48), { tamper: dropOnMultiPage });
  SearchCore.MAX_DEPTH = saved;
  check('no cutting allowed: reported partial', r.partial, true);
  check('no cutting allowed: no error', r.err, null);
}
{
  const saved = SearchCore.PIECE_BUDGET;
  SearchCore.PIECE_BUDGET = 0;
  const plain = await run(makeRepos(2500, 0.3, 48), { tamper: dropOnMultiPage });
  SearchCore.PIECE_BUDGET = saved;
  const full = await run(makeRepos(2500, 0.3, 48), { tamper: dropOnMultiPage });
  check('piece budget spent: reported partial', plain.partial, true);
  check(`piece budget spent: fewer requests (${plain.gh.calls} vs ${full.gh.calls})`, plain.gh.calls < full.gh.calls, true);
}

// ── Cutting a window never makes more pieces than a full window needs ──────
{
  const stops = SearchCore.pieceStops([], 0, 1e8, false, 1e6);
  check(`absurd count: pieces capped (${stops.length + 1})`, stops.length + 1 <= Math.ceil(SearchCore.RESULT_LIMIT / SearchCore.PIECE), true);
}

// ── Request cost (same limits as the plugin's test where the data is the same) ──
async function costCase(label, repos, limit, minStars = 0) {
  const r = await run(repos, { minStars });
  const want = repos.filter(x => x.stargazers_count >= minStars).length;
  check(`${label}: all collected`, r.unique, want);
  check(`${label}: never asked past 1000`, r.gh.rejected, 0);
  check(`${label}: not partial`, r.partial, false);
  check(`${label}: at most ${limit} requests (floor ${Math.ceil(want / 100)}, took ${r.gh.calls})`, r.gh.calls <= limit, true);
}
await costCase('snapshot non-fork', loadSnapshot('nonfork'), 13);
await costCase('snapshot forks incl. 0-star', loadSnapshot('fork'), 17);
await costCase('snapshot forks, starred only', loadSnapshot('fork'), 2, 1);
await costCase('20k evenly spread', makeRepos(20000, 0.5, 22, 1), 216);
await costCase('20k skewed, stars with the old', makeRepos(20000, 0.5, 24, 3, true), 222);
await costCase('100k skewed to recent years', makeRepos(100000, 0.6, 21, 3), 1085);

// ── GitHub.request: retries and rate-limit waits ───────────────────────────
const githubSrc = cut('const GitHub = {', '\n};\n') + '\n};';
function loadGitHub(responses) {
  const calls = [], sleeps = [], waits = [];
  const Storage = { get: () => '' };
  const fetchStub = async url => {
    calls.push(url);
    const r = responses.shift();
    if (!r) throw new Error('no canned response left');
    const headers = new Map(Object.entries(r.headers || {}).map(([k, v]) => [k.toLowerCase(), String(v)]));
    const make = () => ({
      ok: r.status >= 200 && r.status < 300,
      status: r.status,
      statusText: String(r.status),
      headers: { get: k => headers.get(k.toLowerCase()) ?? null },
      json: async () => r.body || {},
      text: async () => JSON.stringify(r.body || {}),
      clone: () => make(),
    });
    return make();
  };
  const GitHub = new Function('Storage', 'fetch', `${githubSrc}\nreturn GitHub;`)(Storage, fetchStub);
  GitHub.sleep = async ms => { sleeps.push(ms); };
  GitHub.onRateLimitWait = s => waits.push(s);
  return { GitHub, calls, sleeps, waits };
}
{
  const t = loadGitHub([{ status: 502 }, { status: 503 }, { status: 200, body: { ok: 1 } }]);
  const body = await t.GitHub.request('/x');
  check('5xx twice then 200: result returned', body.ok, 1);
  check('5xx twice then 200: three requests', t.calls.length, 3);
  check('5xx twice then 200: waits grow', t.sleeps.length === 2 && t.sleeps[0] < t.sleeps[1], true);
}
{
  const t = loadGitHub([{ status: 502 }, { status: 502 }, { status: 502, body: { message: 'Server Error' } }]);
  let err = null;
  try { await t.GitHub.request('/x'); } catch (e) { err = e; }
  check('5xx three times: gives up with the status', err && err.message, 'GitHub API 502: Server Error');
  check('5xx three times: three requests, no more', t.calls.length, 3);
}
{
  const t = loadGitHub([{ status: 404, body: { message: 'Not Found' } }]);
  let err = null;
  try { await t.GitHub.request('/x'); } catch (e) { err = e; }
  check('404: not retried', t.calls.length, 1);
  check('404: reported', err && err.message, 'GitHub API 404: Not Found');
}
{
  const reset = Math.floor(Date.now() / 1000) + 30;
  const t = loadGitHub([
    { status: 403, headers: { 'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': reset } },
    { status: 200, body: { ok: 1 } },
  ]);
  const body = await t.GitHub.request('/search/repositories');
  check('rate limit within a minute: waited out', body.ok, 1);
  check('rate limit within a minute: user told', t.waits.length === 1 && t.waits[0] >= 30 && t.waits[0] <= 32, true);
}
{
  const t = loadGitHub([{ status: 429, headers: { 'Retry-After': '20' } }, { status: 200, body: { ok: 1 } }]);
  await t.GitHub.request('/search/repositories');
  check('Retry-After honoured', t.sleeps[0], 20000);
}
{
  const t = loadGitHub([{ status: 429, headers: { 'Retry-After': '0' } }, { status: 200, body: { ok: 1 } }]);
  await t.GitHub.request('/search/repositories');
  check('Retry-After 0: still a second, as in the plugin', t.sleeps[0], 1000);
}
{
  // Out of requests, the reset already behind us: our clock is ahead of GitHub's.
  const reset = Math.floor(Date.now() / 1000) - 10;
  const t = loadGitHub([
    { status: 403, headers: { 'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': reset } },
    { status: 200, body: { ok: 1 } },
  ]);
  await t.GitHub.request('/search/repositories');
  check('reset already past: a full window, not a second', t.waits[0], 61);
}
{
  // The search limit resets every minute: a reset further off is a clock behind.
  const reset = Math.floor(Date.now() / 1000) + 90;
  const t = loadGitHub([
    { status: 403, headers: { 'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': reset, 'X-RateLimit-Resource': 'search' } },
    { status: 200, body: { ok: 1 } },
  ]);
  await t.GitHub.request('/search/repositories');
  check('search limit: never waits past its minute', t.waits[0], 61);
}
{
  const t = loadGitHub([
    { status: 403, headers: { 'X-RateLimit-Remaining': '27' }, body: { message: 'You have exceeded a secondary rate limit.' } },
    { status: 200, body: { ok: 1 } },
  ]);
  const body = await t.GitHub.request('/search/repositories');
  check('secondary limit: waited out', body.ok, 1);
  check('secondary limit: a minute', t.waits[0], 60);
}
{
  // Out of requests with no reset given: a minute, as the plugin does.
  const t = loadGitHub([{ status: 403, headers: { 'X-RateLimit-Remaining': '0' } }, { status: 200, body: { ok: 1 } }]);
  await t.GitHub.request('/search/repositories');
  check('403 out of requests, no reset: a minute', t.waits[0], 60);
}
{
  const t = loadGitHub([{ status: 403, headers: { 'X-RateLimit-Remaining': '27' }, body: { message: 'Resource not accessible' } }]);
  let err = null;
  try { await t.GitHub.request('/x'); } catch (e) { err = e; }
  check('403 with requests left: not waited for', t.calls.length, 1);
  check('403 with requests left: reported as what it is', err && err.message, 'GitHub API 403: Resource not accessible');
}
{
  const reset = Math.floor(Date.now() / 1000) + 3000;
  const t = loadGitHub([{ status: 403, headers: { 'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': reset } }]);
  let err = null;
  try { await t.GitHub.request('/x'); } catch (e) { err = e; }
  check('hourly limit: not waited for', t.calls.length, 1);
  check('hourly limit: fails with the message', !!(err && /Rate limit exceeded/.test(err.message)), true);
}

if (failures > 0) {
  console.log(`${failures} FAILED`);
  process.exit(1);
}
console.log('all passed');
