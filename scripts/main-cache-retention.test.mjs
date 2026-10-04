import assert from 'node:assert/strict';
import { test } from 'node:test';
import { planMainCacheRetention, pruneMainCaches } from './main-cache-retention.mjs';

const now = Date.parse('2026-10-04T12:00:00Z');
const day = 24 * 60 * 60 * 1000;
const grace = 8 * 60 * 60 * 1000;
const mainRef = 'refs/heads/main';
const cacheRoute = '/repos/{owner}/{repo}/actions/caches';
const prefix =
  'setup-zig-cache-v2-prepare_cli-zig-x86_64-linux-0.16.0-cli-ubuntu-baseline-releasefast';
const repository = { id: 41, full_name: 'ohah/zntc', default_branch: 'main' };

const date = (age) => new Date(now - age).toISOString();
const ids = (caches) => caches.map((item) => item.id).sort((a, b) => a - b);
const sorted = (values) => [...values].sort((a, b) => a - b);

function cache(id, ageDays = 10 - id / 100, overrides = {}) {
  return {
    id,
    key: `${prefix}-${10_000 + id}-1`,
    version: 'archive-version-a',
    ref: mainRef,
    size_in_bytes: 1000 + id,
    created_at: date(ageDays * day),
    last_accessed_at: date(ageDays * day),
    ...overrides,
  };
}

const family = () => [cache(101, 8), cache(102, 7), cache(103, 6), cache(104, 5)];
const oneCandidate = () => [cache(101, 8), cache(102, 7), cache(103, 6)];

function sourceRun(id, overrides = {}) {
  return {
    id,
    repository: { ...repository },
    head_repository: { ...repository },
    head_branch: 'main',
    event: 'push',
    status: 'completed',
    conclusion: 'success',
    run_attempt: 1,
    ...overrides,
  };
}

function httpError(status) {
  return Object.assign(new Error(`GitHub fixture error ${status}`), { status });
}

// list() supplies complete API pagination, as the maintenance adapter does.
// api() deletes real fixture rows so mutating before page two loses records.
function fixture(options = {}) {
  const caches = structuredClone(options.caches ?? oneCandidate());
  const runs = new Map(caches.map((item) => [10_000 + item.id, sourceRun(10_000 + item.id)]));
  for (const item of options.runs ?? []) runs.set(item.id, structuredClone(item));
  const calls = [];
  const unexpected = [];
  const logs = [];

  async function api(route, params = {}) {
    calls.push({ kind: 'api', route, params: structuredClone(params) });
    const intercepted = await options.api?.({ route, params, calls, caches, runs });
    if (intercepted !== undefined) return structuredClone(intercepted);
    if (route === `GET ${cacheRoute}`) {
      let matches = caches;
      if (params.ref) matches = matches.filter((item) => item.ref === params.ref);
      if (params.key) matches = matches.filter((item) => item.key.startsWith(params.key));
      const size = params.per_page ?? 30;
      const page = params.page ?? 1;
      return {
        total_count: matches.length,
        actions_caches: structuredClone(matches.slice((page - 1) * size, page * size)),
      };
    }
    if (route === 'GET /repos/{owner}/{repo}/actions/runs') {
      let matches = [...runs.values()];
      if (params.status) matches = matches.filter((item) => item.status === params.status);
      if (params.branch) matches = matches.filter((item) => item.head_branch === params.branch);
      const size = params.per_page ?? 30;
      const page = params.page ?? 1;
      return {
        total_count: matches.length,
        workflow_runs: structuredClone(matches.slice((page - 1) * size, page * size)),
      };
    }
    if (route === `DELETE ${cacheRoute}/{cache_id}`) {
      const index = caches.findIndex((item) => item.id === params.cache_id);
      assert.notEqual(index, -1, 'the requested cache ID must exist');
      assert.equal(caches[index].ref, mainRef, 'never delete another ref');
      caches.splice(index, 1);
      return {};
    }
    unexpected.push({ route, params });
    throw new Error(`Unexpected fixture route: ${route}`);
  }

  async function list(route, field, params = {}) {
    calls.push({ kind: 'list', route, field, params: structuredClone(params) });
    const intercepted = await options.list?.({ route, field, params, calls, caches, runs });
    if (intercepted !== undefined) return structuredClone(intercepted);
    const records = [];
    for (let page = 1; page <= 100; page++) {
      const data = await api(route, { ...params, page, per_page: 100 });
      const rows = data[field];
      assert.ok(Array.isArray(rows), 'the fixture list helper requires an array');
      records.push(...rows);
      if (rows.length < 100) {
        if (records.length < data.total_count) {
          throw Object.assign(new Error('Incomplete pagination'), {
            code: 'INCOMPLETE_PAGINATION',
          });
        }
        return records;
      }
    }
    throw new Error('Pagination limit reached');
  }

  async function run(id) {
    calls.push({ kind: 'run', id });
    const intercepted = await options.run?.({ id, calls, caches, runs });
    if (intercepted !== undefined) return structuredClone(intercepted);
    if (!runs.has(id)) throw httpError(404);
    return structuredClone(runs.get(id));
  }

  return {
    api,
    list,
    run,
    caches,
    calls,
    logs,
    mutations: () =>
      calls.filter((call) => call.kind === 'api' && /^(DELETE|POST|PUT|PATCH) /.test(call.route)),
    deleted: () =>
      calls
        .filter((call) => call.kind === 'api' && call.route.startsWith('DELETE '))
        .map((call) => call.params.cache_id),
    async execute(dryRun = false) {
      try {
        return await pruneMainCaches({
          api,
          list,
          run,
          repository,
          dryRun,
          now,
          log: (message) => logs.push(message),
        });
      } finally {
        assert.deepEqual(unexpected, [], 'all operations must use the documented API boundary');
      }
    },
  };
}

test('keeps the two newest created records without relying on input order or run ID order', () => {
  const caches = family();
  const result = planMainCacheRetention([caches[2], caches[0], caches[3], caches[1]], { now });
  assert.deepEqual(ids(result.candidates), [101, 102]);
  assert.deepEqual(sorted(result.protectedCaches), [103, 104]);
  assert.deepEqual(result.ignoredCaches, []);
});

test('preserves every record tied with the second newest creation timestamp', () => {
  const result = planMainCacheRetention([...family(), cache(105, 6)], { now });
  assert.deepEqual(ids(result.candidates), [101, 102]);
  assert.deepEqual(sorted(result.protectedCaches), [103, 104, 105]);
});

test('two equally newest records satisfy retention without retaining a second timestamp group', () => {
  const result = planMainCacheRetention([...family(), cache(105, 5)], { now });
  assert.deepEqual(ids(result.candidates), [101, 102, 103]);
  assert.deepEqual(sorted(result.protectedCaches), [104, 105]);
});

test('one or two caches are kept even when very old', () => {
  for (const caches of [[cache(101, 80)], [cache(101, 80), cache(102, 70)]]) {
    const result = planMainCacheRetention(caches, { now });
    assert.deepEqual(result.candidates, []);
    assert.deepEqual(sorted(result.protectedCaches), ids(caches));
  }
});

test('cache archive version and the complete key prefix identify independent families', () => {
  const caches = [
    ...family(),
    cache(201, 8, { version: 'archive-version-b' }),
    cache(202, 7, { version: 'archive-version-b' }),
    cache(203, 8, { key: `${prefix}-another-custom-10203-1` }),
    cache(204, 7, { key: `${prefix}-another-custom-10204-1` }),
  ];
  const result = planMainCacheRetention(caches, { now });
  assert.deepEqual(ids(result.candidates), [101, 102]);
  assert.deepEqual(sorted(result.protectedCaches), [103, 104, 201, 202, 203, 204]);
});

for (const platform of ['linux', 'macos', 'windows']) {
  test(`recognizes the exact setup-zig ${platform} key family`, () => {
    const caches = family().map((item) => ({
      ...item,
      key: item.key.replace('-x86_64-linux-', `-aarch64-${platform}-`),
    }));
    const result = planMainCacheRetention(caches, { now });
    assert.deepEqual(ids(result.candidates), [101, 102]);
  });
}

test('all caches created within eight hours survive even when there are more than two', () => {
  const caches = [cache(101, 0.3), cache(102, 0.25), cache(103, 0.2), cache(104, 0.1)];
  const result = planMainCacheRetention(caches, { now });
  assert.deepEqual(result.candidates, []);
  assert.deepEqual(sorted(result.protectedCaches), [101, 102, 103, 104]);
});

test('recent generations retain the latest two mature caches as well', () => {
  const caches = [...oneCandidate(), cache(104, 0.2), cache(105, 0.1)];
  const result = planMainCacheRetention(caches, { now });
  assert.deepEqual(ids(result.candidates), [101]);
  assert.deepEqual(sorted(result.protectedCaches), [102, 103, 104, 105]);
});

test('recent generations cannot retire the only mature cache', () => {
  const caches = [cache(101, 8), cache(102, 0.3), cache(103, 0.2), cache(104, 0.1)];
  const result = planMainCacheRetention(caches, { now });
  assert.deepEqual(result.candidates, []);
  assert.deepEqual(sorted(result.protectedCaches), [101, 102, 103, 104]);
});

test('the second mature creation timestamp protects every tied cache', () => {
  const caches = [...family(), cache(105, 6), cache(106, 0.2), cache(107, 0.1)];
  const result = planMainCacheRetention(caches, { now });
  assert.deepEqual(ids(result.candidates), [101, 102]);
  assert.deepEqual(sorted(result.protectedCaches), [103, 104, 105, 106, 107]);
});

test('two generations exactly eight hours old provide the mature retention floor', () => {
  const caches = [cache(101, 8), cache(102, grace / day), cache(103, grace / day), cache(104, 0.1)];
  const result = planMainCacheRetention(caches, { now });
  assert.deepEqual(ids(result.candidates), [101]);
  assert.deepEqual(sorted(result.protectedCaches), [102, 103, 104]);
});

test('two generations just under eight hours old cannot retire a mature cache', () => {
  const caches = [cache(101, 8), cache(102, (grace - 1) / day), cache(103, (grace - 1) / day)];
  const result = planMainCacheRetention(caches, { now });
  assert.deepEqual(result.candidates, []);
  assert.deepEqual(sorted(result.protectedCaches), [101, 102, 103]);
});

test('the retention planner rejects a ref outside main', () => {
  assert.throws(() => planMainCacheRetention(family(), { now, ref: 'refs/heads/release' }));
});

for (const [label, age, protectedId] of [
  ['just inside eight hours', grace - 1, true],
  ['exactly eight hours', grace, true],
  ['just outside eight hours', grace + 1, false],
]) {
  test(`last access ${label} is ${protectedId ? 'protected' : 'eligible'}`, () => {
    const caches = oneCandidate();
    caches[0].last_accessed_at = date(age);
    const result = planMainCacheRetention(caches, { now });
    assert.deepEqual(ids(result.candidates), protectedId ? [] : [101]);
  });
}

for (const field of ['created_at', 'last_accessed_at']) {
  test(`a future ${field} never authorizes deletion`, () => {
    const caches = oneCandidate();
    caches[0][field] = date(-day);
    const result = planMainCacheRetention(caches, { now });
    assert.ok(!result.candidates.some((item) => item.id === 101));
  });
}

for (const [label, changes] of [
  ['missing creation time', { created_at: undefined }],
  ['invalid creation time', { created_at: 'not-a-date' }],
  ['missing access time', { last_accessed_at: null }],
  ['invalid access time', { last_accessed_at: 'not-a-date' }],
  ['missing size', { size_in_bytes: undefined }],
  ['negative size', { size_in_bytes: -1 }],
  ['string size', { size_in_bytes: '2048' }],
  ['nonfinite size', { size_in_bytes: Infinity }],
]) {
  test(`${label} protects the whole recognized family`, () => {
    const caches = family();
    Object.assign(caches[0], changes);
    const result = planMainCacheRetention(caches, { now });
    assert.deepEqual(result.candidates, []);
    assert.deepEqual(sorted(result.protectedCaches), [101, 102, 103, 104]);
  });
}

for (const [label, changes] of [
  ['PR ref', { ref: 'refs/pull/123/merge' }],
  ['another branch', { ref: 'refs/heads/release' }],
  ['Bun cache', { key: 'bun-cache-main-123' }],
  ['old cache format', { key: 'setup-zig-cache-v1-prepare-cli-10101-1' }],
  ['missing key', { key: undefined }],
  ['zero owner run ID', { key: `${prefix}-0-1` }],
  ['zero owner attempt', { key: `${prefix}-10101-0` }],
  ['unrecognized OS', { key: `${prefix.replace('-linux-', '-freebsd-')}-10101-1` }],
  ['missing archive version', { version: undefined }],
  ['empty archive version', { version: '' }],
]) {
  test(`${label} is outside the recognized retention inventory`, () => {
    const caches = oneCandidate();
    Object.assign(caches[0], changes);
    const result = planMainCacheRetention(caches, { now });
    assert.deepEqual(result.candidates, []);
    assert.ok(result.ignoredCaches.includes(101));
  });
}

test('an invalid cache ID never enters the deletion plan', () => {
  for (const id of [0, -1, '101', undefined, Number.MAX_SAFE_INTEGER + 1]) {
    const caches = oneCandidate();
    caches[0].id = id;
    const result = planMainCacheRetention(caches, { now });
    assert.ok(result.candidates.every((item) => Number.isSafeInteger(item.id) && item.id > 0));
  }
});

test('malformed data protects its family without affecting a healthy independent family', () => {
  const caches = [
    ...family(),
    cache(201, 8, { version: 'archive-version-b', created_at: 'not-a-date' }),
    cache(202, 7, { version: 'archive-version-b' }),
    cache(203, 6, { version: 'archive-version-b' }),
  ];
  const result = planMainCacheRetention(caches, { now });
  assert.deepEqual(ids(result.candidates), [101, 102]);
  assert.deepEqual(sorted(result.protectedCaches), [103, 104, 201, 202, 203]);
});

test('prunes only the exact old main cache ID and preserves the newest pair', async () => {
  const f = fixture();
  const result = await f.execute();
  assert.deepEqual(f.deleted(), [101]);
  assert.deepEqual(result.plannedCaches, [101]);
  assert.equal(result.plannedBytes, 1101);
  assert.deepEqual(result.deletedCaches, [101]);
  assert.equal(result.deletedBytes, 1101);
  assert.deepEqual(ids(f.caches), [102, 103]);
  const deletion = f.mutations()[0];
  assert.equal(deletion.route, `DELETE ${cacheRoute}/{cache_id}`);
  assert.deepEqual(deletion.params, { cache_id: 101 });
});

test('dry run reports eligible IDs and bytes without a mutating API call', async () => {
  const f = fixture();
  const result = await f.execute(true);
  assert.equal(result.dryRun, true);
  assert.deepEqual(result.plannedCaches, [101]);
  assert.equal(result.plannedBytes, 1101);
  assert.deepEqual(result.deletedCaches, []);
  assert.equal(result.deletedBytes, 0);
  assert.deepEqual(f.mutations(), []);
  assert.deepEqual(ids(f.caches), [101, 102, 103]);
});

for (const [label, changes] of [
  ['requested owner', { status: 'requested', conclusion: null }],
  ['queued owner', { status: 'queued', conclusion: null }],
  ['pending owner', { status: 'pending', conclusion: null }],
  ['waiting owner', { status: 'waiting', conclusion: null }],
  ['running owner', { status: 'in_progress', conclusion: null }],
  ['invalid owner attempt', { run_attempt: 0 }],
  ['another repository', { repository: { ...repository, id: 42 } }],
  ['another head repository', { head_repository: { ...repository, id: 42 } }],
  ['another branch', { head_branch: 'release' }],
]) {
  test(`${label} cannot authorize deletion of its old cache`, async () => {
    const f = fixture({ runs: [sourceRun(10101, changes)] });
    await f.execute();
    assert.deepEqual(f.mutations(), []);
    assert.deepEqual(ids(f.caches), [101, 102, 103]);
  });
}

test('an owner run that disappeared returns no permission to delete', async () => {
  const f = fixture({
    run() {
      throw httpError(404);
    },
  });
  await f.execute();
  assert.deepEqual(f.mutations(), []);
});

test('a completed rerun can authorize deletion of an older attempt cache', async () => {
  const f = fixture({ runs: [sourceRun(10101, { run_attempt: 2 })] });
  const result = await f.execute();
  assert.deepEqual(result.deletedCaches, [101]);
});

test('an owner attempt below the cache attempt cannot authorize deletion', async () => {
  const caches = oneCandidate();
  caches[0].key = `${prefix}-10101-2`;
  const f = fixture({ caches, runs: [sourceRun(10101, { run_attempt: 1 })] });
  await f.execute();
  assert.deepEqual(f.mutations(), []);
});

test('an owner lookup permission failure is not treated as a missing run', async () => {
  const f = fixture({
    run() {
      throw httpError(403);
    },
  });
  await assert.rejects(f.execute(), { status: 403 });
  assert.deepEqual(f.mutations(), []);
});

test('omitting dryRun defaults to a read-only plan', async () => {
  const f = fixture();
  const result = await pruneMainCaches({ api: f.api, list: f.list, run: f.run, repository, now });
  assert.equal(result.dryRun, true);
  assert.deepEqual(result.plannedCaches, [101]);
  assert.deepEqual(f.mutations(), []);
});

test('main retention never deletes PR, branch, or non-Zig cache records', async () => {
  const caches = [
    ...oneCandidate(),
    cache(201, 9, { ref: 'refs/pull/123/merge' }),
    cache(202, 9, { ref: 'refs/heads/release' }),
    cache(203, 9, { key: 'bun-cache-main-203' }),
  ];
  const f = fixture({ caches });
  await f.execute();
  assert.deepEqual(f.deleted(), [101]);
  assert.deepEqual(ids(f.caches), [102, 103, 201, 202, 203]);
});

test('a new cache during revalidation never expands the initially approved deletion set', async () => {
  let refreshed = false;
  const f = fixture({
    list({ route, params, caches, runs }) {
      if (route === `GET ${cacheRoute}` && params.key === `${prefix}-` && !refreshed) {
        refreshed = true;
        caches.push(cache(104, 0.1));
        runs.set(10104, sourceRun(10104));
      }
    },
  });
  const result = await f.execute();
  assert.ok(refreshed, 'revalidate the full key prefix before deleting');
  assert.deepEqual(result.deletedCaches, [101]);
  assert.deepEqual(ids(f.caches), [102, 103, 104]);
});

test('a cache accessed after the initial plan is preserved', async () => {
  let refreshed = false;
  const f = fixture({
    list({ route, params, caches }) {
      if (route === `GET ${cacheRoute}` && params.key === `${prefix}-`) {
        refreshed = true;
        caches.find((item) => item.id === 101).last_accessed_at = date(1000);
      }
    },
  });
  await f.execute();
  assert.ok(refreshed);
  assert.deepEqual(f.mutations(), []);
});

test('disappearance of newer caches makes the old candidate part of the retained pair', async () => {
  let refreshed = false;
  const f = fixture({
    list({ route, params, caches }) {
      if (route === `GET ${cacheRoute}` && params.key === `${prefix}-` && !refreshed) {
        refreshed = true;
        caches.splice(1);
      }
    },
  });
  await f.execute();
  assert.ok(refreshed);
  assert.deepEqual(f.mutations(), []);
  assert.deepEqual(ids(f.caches), [101]);
});

for (const [label, changes, rejects] of [
  ['key', { key: `${prefix}-changed-custom-10101-1` }, true],
  ['archive version', { version: 'archive-version-changed' }, true],
  ['creation time', { created_at: date(9 * day) }, true],
  ['old access time', { last_accessed_at: date(9 * day) }, false],
  ['size', { size_in_bytes: 12345 }, true],
  ['ref', { ref: 'refs/pull/123/merge' }, false],
]) {
  test(`a changed ${label} invalidates the exact cache selected for deletion`, async () => {
    let refreshed = false;
    const f = fixture({
      list({ route, params, caches }) {
        if (route === `GET ${cacheRoute}` && params.key === `${prefix}-`) {
          refreshed = true;
          Object.assign(
            caches.find((item) => item.id === 101),
            changes,
          );
        }
      },
    });
    if (rejects) await assert.rejects(f.execute(), /identity|metadata/i);
    else await f.execute();
    assert.ok(refreshed);
    assert.deepEqual(f.mutations(), []);
  });
}

for (const [label, changes] of [
  ['active rerun', { run_attempt: 2, status: 'in_progress', conclusion: null }],
  ['active owner', { status: 'in_progress', conclusion: null }],
  ['changed repository', { repository: { ...repository, id: 42 } }],
]) {
  test(`${label} after cache revalidation prevents deletion`, async () => {
    let lookups = 0;
    const f = fixture({
      run({ id }) {
        if (id !== 10101) return;
        lookups++;
        return sourceRun(id, lookups === 1 ? {} : changes);
      },
    });
    await f.execute();
    assert.ok(lookups >= 2, 'check the owner again immediately before mutation');
    assert.deepEqual(f.mutations(), []);
  });
}

test('cache deletion uses a refreshed owner and a complete refreshed family inventory', async () => {
  const f = fixture();
  await f.execute();
  const deletion = f.calls.findIndex(
    (call) => call.kind === 'api' && call.route.startsWith('DELETE '),
  );
  const before = f.calls.slice(0, deletion);
  const refresh = before.findLastIndex(
    (call) =>
      call.kind === 'list' &&
      call.route === `GET ${cacheRoute}` &&
      call.params.key === `${prefix}-`,
  );
  const owner = before.findLastIndex((call) => call.kind === 'run' && call.id === 10101);
  assert.ok(refresh > 0, 'initial planning precedes prefix revalidation');
  assert.ok(owner > refresh, 'owner revalidation follows the refreshed inventory');
  assert.equal(before[refresh].params.ref, mainRef);
});

test('a concurrent cache removal is idempotent and does not inflate deleted statistics', async () => {
  const f = fixture({
    api({ route, params, caches }) {
      if (route.startsWith('DELETE ')) {
        caches.splice(
          caches.findIndex((item) => item.id === params.cache_id),
          1,
        );
        throw httpError(404);
      }
    },
  });
  const result = await f.execute();
  assert.deepEqual(f.deleted(), [101]);
  assert.deepEqual(result.deletedCaches, []);
  assert.equal(result.deletedBytes, 0);
  assert.deepEqual(ids(f.caches), [102, 103]);
});

test('delete permission errors remain failures', async () => {
  const f = fixture({
    api({ route }) {
      if (route.startsWith('DELETE ')) throw httpError(403);
    },
  });
  await assert.rejects(f.execute(), { status: 403 });
  assert.deepEqual(f.deleted(), [101]);
  assert.deepEqual(ids(f.caches), [101, 102, 103]);
});

test('collects more than 100 main caches before any deletion and preserves the newest two', async () => {
  const caches = Array.from({ length: 102 }, (_, index) => cache(index + 1, 200 - index));
  const f = fixture({ caches });
  const result = await f.execute();
  assert.deepEqual(
    sorted(result.deletedCaches),
    Array.from({ length: 100 }, (_, index) => index + 1),
  );
  assert.deepEqual(ids(f.caches), [101, 102]);
  assert.equal(
    result.deletedBytes,
    caches.slice(0, 100).reduce((sum, item) => sum + item.size_in_bytes, 0),
  );
  const firstDelete = f.calls.findIndex(
    (call) => call.kind === 'api' && call.route.startsWith('DELETE '),
  );
  const pageTwo = f.calls.findIndex(
    (call) => call.kind === 'api' && call.route === `GET ${cacheRoute}` && call.params.page === 2,
  );
  assert.ok(
    pageTwo >= 0 && pageTwo < firstDelete,
    'complete the initial inventory before mutation',
  );
});

function incompleteInventory() {
  return Object.assign(new Error('Incomplete pagination: changing cache inventory'), {
    code: 'INCOMPLETE_PAGINATION',
  });
}

test('an incomplete initial main inventory fails without any mutation', async () => {
  const f = fixture({
    list() {
      throw incompleteInventory();
    },
  });
  await assert.rejects(f.execute(), { code: 'INCOMPLETE_PAGINATION' });
  assert.deepEqual(f.mutations(), []);
});

test('an incomplete family inventory preserves that family while an independent family proceeds', async () => {
  const other = [201, 202, 203].map((id, index) =>
    cache(id, 8 - index, {
      key: `${prefix}-other-custom-${10_000 + id}-1`,
    }),
  );
  const f = fixture({
    caches: [...family(), ...other],
    list({ params }) {
      if (params.key === `${prefix}-`) throw incompleteInventory();
    },
  });
  const result = await f.execute();
  assert.deepEqual(sorted(result.deferredCaches), [101, 102]);
  assert.deepEqual(result.deletedCaches, [201]);
  assert.equal(result.deletedBytes, 1201);
  assert.deepEqual(ids(f.caches), [101, 102, 103, 104, 202, 203]);
});

test('an incomplete recheck after one deletion preserves remaining caches and completed statistics', async () => {
  let familyReads = 0;
  const f = fixture({
    caches: family(),
    list({ params }) {
      if (params.key === `${prefix}-` && ++familyReads > 1) throw incompleteInventory();
    },
  });
  const result = await f.execute();
  assert.deepEqual(result.deletedCaches, [101]);
  assert.equal(result.deletedBytes, 1101);
  assert.deepEqual(result.deferredCaches, [102]);
  assert.deepEqual(ids(f.caches), [102, 103, 104]);
});

for (const [label, failure] of [
  ['permission failure', httpError(403)],
  ['malformed response', new Error('Incomplete response: actions_caches is missing')],
  ['pagination cap', new Error('Pagination limit reached')],
]) {
  test(`a family ${label} remains a failure rather than authorizing deletion`, async () => {
    const f = fixture({
      list({ params }) {
        if (params.key === `${prefix}-`) throw failure;
      },
    });
    await assert.rejects(f.execute(), (error) => error === failure);
    assert.deepEqual(f.mutations(), []);
  });
}

test('a cache returned outside the exact requested ref fails closed', async () => {
  const f = fixture({
    list({ params, caches }) {
      if (params.key === `${prefix}-`) {
        return caches.map((item) =>
          item.id === 101 ? { ...item, ref: 'refs/pull/123/merge' } : item,
        );
      }
    },
  });
  await assert.rejects(f.execute(), /ref|prefix/i);
  assert.deepEqual(f.mutations(), []);
});
