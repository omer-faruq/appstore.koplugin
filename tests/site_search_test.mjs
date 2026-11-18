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
const html = readFileSync(join(root, 'docs', 'index.html'), 'utf8');

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
  const gh = { calls: 0, rejected: 0 };
  gh.fetch = async (query, page, perPage) => {
    gh.calls++;
    let sLo = 0;
    for (const m of query.matchAll(/stars:>=(\d+)/g)) sLo = Math.max(sLo, Number(m[1]));
    let cLo = -Infinity, cHi = Infinity;
    for (const m of query.matchAll(/created:(\S+)\.\.(\S+)/g)) {
      cLo = Math.max(cLo, SearchCore.parseIso(m[1]));
      cHi = Math.min(cHi, SearchCore.parseIso(m[2]));
    }
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
    return { total_count: total, items };
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
  const seen = new Set();
  let warnings = 0, err = null;
  try {
    await SearchCore.collect('in:name ".koplugin"', {
      fetch: opts.fetch ? opts.fetch(gh) : gh.fetch,
      append: repo => seen.add(repo.id),
      minStars: opts.minStars || 0,
      now: NOW,
      warn: () => { warnings++; },
    });
  } catch (e) {
    err = e;
  }
  return { err, unique: seen.size, seen, gh, warnings };
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

// ── Request cost (same limits as the plugin's test where the data is the same) ──
async function costCase(label, repos, limit, minStars = 0) {
  const r = await run(repos, { minStars });
  const want = repos.filter(x => x.stargazers_count >= minStars).length;
  check(`${label}: all collected`, r.unique, want);
  check(`${label}: never asked past 1000`, r.gh.rejected, 0);
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
    return {
      ok: r.status >= 200 && r.status < 300,
      status: r.status,
      statusText: String(r.status),
      headers: { get: k => headers.get(k.toLowerCase()) ?? null },
      json: async () => r.body || {},
    };
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
