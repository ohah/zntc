import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runMaintenance } from './ci-maintenance.mjs';

const repository = {
  id: 41,
  name: 'zntc',
  full_name: 'ohah/zntc',
  default_branch: 'main',
  owner: { login: 'ohah' },
};
const workflow = { id: 71, name: 'CI', path: '.github/workflows/ci.yml', state: 'active' };
const headSha = 'a'.repeat(40);
const mergeSha = 'b'.repeat(40);
const unrelatedSha = 'c'.repeat(40);
const branch = 'fix/maintenance-fixture';
const repoRoute = '/repos/{owner}/{repo}';

function pull(overrides = {}) {
  return {
    id: 1000 + (overrides.number ?? 123),
    number: 123,
    state: 'closed',
    merged: true,
    draft: false,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-03T00:00:00Z',
    closed_at: '2026-01-03T00:00:00Z',
    merged_at: '2026-01-03T00:00:00Z',
    merge_commit_sha: mergeSha,
    base: { ref: 'main', sha: mergeSha, repo: structuredClone(repository) },
    head: {
      ref: branch,
      label: `ohah:${branch}`,
      sha: headSha,
      repo: structuredClone(repository),
    },
    ...overrides,
  };
}

function run(overrides = {}) {
  return {
    id: 201,
    name: 'CI',
    workflow_id: workflow.id,
    path: workflow.path,
    event: 'pull_request',
    status: 'in_progress',
    conclusion: null,
    run_attempt: 1,
    head_sha: headSha,
    head_branch: branch,
    repository: structuredClone(repository),
    head_repository: structuredClone(repository),
    pull_requests: [pull()],
    created_at: '2026-01-02T00:00:00Z',
    run_started_at: '2026-01-02T00:00:01Z',
    updated_at: '2026-01-03T00:01:00Z',
    ...overrides,
  };
}

function mainRun(overrides = {}) {
  return run({
    id: 202,
    event: 'push',
    head_sha: mergeSha,
    head_branch: 'main',
    pull_requests: [],
    created_at: '2026-01-03T00:00:01Z',
    run_started_at: '2026-01-03T00:00:02Z',
    ...overrides,
  });
}

function cache(id = 301, overrides = {}) {
  return {
    id,
    key: `fixture-cache-${id}`,
    ref: 'refs/pull/123/merge',
    version: `version-${id}`,
    size_in_bytes: id,
    created_at: '2026-01-02T00:00:00Z',
    last_accessed_at: '2026-01-02T00:00:00Z',
    ...overrides,
  };
}

function httpError(status) {
  return Object.assign(new Error(`GitHub fixture error ${status}`), { status });
}

// This is a stateful REST boundary: deletes really remove records, so deleting
// during pagination would skip the next page and fail the coverage assertion.
function fixture(options = {}) {
  const target = options.pull ?? pull();
  const pulls = options.pulls ?? [target];
  const runs = structuredClone(options.runs ?? [run(), mainRun()]);
  const caches = structuredClone(options.caches ?? []);
  const calls = [];
  const unexpected = [];
  const cachePages = new Set();
  const jobs = (
    options.jobs ?? [
      { id: 401, status: 'in_progress', conclusion: null, started_at: '2026-01-03T00:00:03Z' },
    ]
  ).map((job, index) => ({ id: 401 + index, ...job }));

  function page(items, params) {
    const size = params.per_page ?? 30;
    const number = params.page ?? 1;
    return items.slice((number - 1) * size, number * size);
  }

  const github = {
    async request(route, params = {}) {
      calls.push({ route, params: structuredClone(params) });
      if (params.owner !== 'ohah' || params.repo !== 'zntc') {
        unexpected.push({ route, params });
        throw new Error('request escaped the authorized repository');
      }
      const intercepted = await options.request?.({
        route,
        params,
        calls,
        runs,
        caches,
        cachePages,
      });
      if (intercepted !== undefined) return structuredClone(intercepted);

      let data;
      if (route === `GET ${repoRoute}`) {
        data = repository;
      } else if (route === `GET ${repoRoute}/actions/workflows/{workflow_id}`) {
        data = options.workflow ?? workflow;
      } else if (route === `GET ${repoRoute}/pulls/{pull_number}`) {
        data = pulls.find((item) => item.number === Number(params.pull_number));
        if (!data) throw httpError(404);
      } else if (route === `GET ${repoRoute}/pulls`) {
        let matches = pulls;
        if (params.state && params.state !== 'all') {
          matches = matches.filter((item) => item.state === params.state);
        }
        if (params.head) {
          matches = matches.filter(
            (item) => `${item.head.repo?.owner?.login}:${item.head.ref}` === params.head,
          );
        }
        data = page(matches, params);
      } else if (route === `GET ${repoRoute}/commits/{commit_sha}/pulls`) {
        const matches =
          options.commitPulls ??
          pulls.filter(
            (item) =>
              item.head.sha === params.commit_sha || item.merge_commit_sha === params.commit_sha,
          );
        data = page(matches, params);
      } else if (
        route === `GET ${repoRoute}/actions/runs` ||
        route === `GET ${repoRoute}/actions/workflows/{workflow_id}/runs`
      ) {
        let matches = runs;
        for (const [parameter, field] of [
          ['event', 'event'],
          ['status', 'status'],
          ['branch', 'head_branch'],
          ['head_sha', 'head_sha'],
        ]) {
          if (params[parameter])
            matches = matches.filter((item) => item[field] === params[parameter]);
        }
        data = { total_count: matches.length, workflow_runs: page(matches, params) };
      } else if (route === `GET ${repoRoute}/actions/runs/{run_id}`) {
        data = runs.find((item) => item.id === Number(params.run_id));
        if (!data) throw httpError(404);
      } else if (
        route === `GET ${repoRoute}/actions/runs/{run_id}/attempts/{attempt_number}/jobs`
      ) {
        data = { total_count: jobs.length, jobs: page(jobs, params) };
      } else if (route === `GET ${repoRoute}/actions/caches`) {
        if (!params.key) cachePages.add(params.page ?? 1);
        let matches = params.ref ? caches.filter((item) => item.ref === params.ref) : caches;
        if (params.key) matches = matches.filter((item) => item.key.startsWith(params.key));
        data = { total_count: matches.length, actions_caches: page(matches, params) };
      } else if (route === `POST ${repoRoute}/actions/runs/{run_id}/cancel`) {
        const found = runs.find((item) => item.id === Number(params.run_id));
        assert.ok(found, 'attempted to cancel a nonexistent run');
        found.status = 'completed';
        found.conclusion = 'cancelled';
        data = {};
      } else if (route === `DELETE ${repoRoute}/actions/caches/{cache_id}`) {
        const index = caches.findIndex((item) => item.id === Number(params.cache_id));
        assert.notEqual(index, -1, 'attempted to delete a nonexistent cache');
        caches.splice(index, 1);
        data = {};
      } else {
        unexpected.push({ route, params });
        throw new Error(`unexpected GitHub route: ${route}`);
      }
      return { data: structuredClone(data) };
    },
  };

  return {
    github,
    calls,
    runs,
    caches,
    cachePages,
    mutations: () => calls.filter((item) => /^(POST|DELETE|PATCH|PUT) /.test(item.route)),
    cancelled: () =>
      calls.filter((item) => item.route.endsWith('/cancel')).map((item) => item.params.run_id),
    deleted: () =>
      calls.filter((item) => item.route.startsWith('DELETE ')).map((item) => item.params.cache_id),
    async execute({ dryRun = false, eventName = 'pull_request_target', payload } = {}) {
      try {
        return await runMaintenance({
          github,
          context: {
            repo: { owner: 'ohah', repo: 'zntc' },
            eventName,
            payload: payload ?? { action: 'closed', pull_request: target },
          },
          dryRun,
        });
      } finally {
        assert.deepEqual(unexpected, [], 'all requests must use the documented REST boundary');
      }
    },
  };
}

test('cancels only the matching PR CI after the exact merged commit starts on main', async () => {
  const f = fixture();
  const result = await f.execute();
  assert.deepEqual(f.cancelled(), [201]);
  assert.deepEqual(result.cancelledRuns, [201]);
  assert.deepEqual(f.deleted(), []);
});

test('dry run reports intended work without any mutating request', async () => {
  const f = fixture({ caches: [cache()] });
  const result = await f.execute({ dryRun: true });
  assert.equal(result.dryRun, true);
  assert.deepEqual(result.plannedRuns, [201]);
  assert.deepEqual(result.cancelledRuns, []);
  assert.deepEqual(result.deletedCaches, []);
  assert.equal(result.deletedBytes, 0);
  assert.deepEqual(f.mutations(), []);
});

for (const [label, changes] of [
  ['another commit', { head_sha: unrelatedSha }],
  ['another branch', { head_branch: 'release' }],
  ['manual run', { event: 'workflow_dispatch' }],
  ['different workflow ID', { workflow_id: 72 }],
  ['different workflow path', { path: '.github/workflows/release.yml' }],
  ['failed run', { status: 'completed', conclusion: 'failure' }],
  ['cancelled run', { status: 'completed', conclusion: 'cancelled' }],
  ['another repository', { repository: { ...repository, id: 42, full_name: 'other/zntc' } }],
]) {
  test(`main replacement ${label} cannot authorize PR cancellation`, async () => {
    const f = fixture({ runs: [run(), mainRun(changes)] });
    await f.execute();
    assert.deepEqual(f.mutations(), []);
  });
}

for (const [label, jobs, shouldCancel] of [
  ['no jobs', [], false],
  ['queued jobs', [{ status: 'queued', conclusion: null }], false],
  ['skipped jobs', [{ status: 'completed', conclusion: 'skipped' }], false],
  ['cancelled jobs', [{ status: 'completed', conclusion: 'cancelled' }], false],
  ['missing completed-job result', [{ status: 'completed', conclusion: null }], false],
  ['started job', [{ status: 'in_progress', conclusion: null }], true],
  ['completed job', [{ status: 'completed', conclusion: 'success' }], true],
]) {
  test(`queued main replacement with ${label} ${shouldCancel ? 'allows' : 'prevents'} cancellation`, async () => {
    const f = fixture({ runs: [run(), mainRun({ status: 'queued' })], jobs });
    await f.execute();
    assert.deepEqual(f.cancelled(), shouldCancel ? [201] : []);
  });
}

for (const [label, changes] of [
  ['Release', { workflow_id: 72, path: '.github/workflows/release.yml', name: 'Release' }],
  ['Canary', { workflow_id: 73, path: '.github/workflows/build-canary.yml', name: 'Build Canary' }],
  ['Benchmark', { workflow_id: 74, path: '.github/workflows/benchmark.yml', name: 'Benchmark' }],
  ['same name with wrong workflow ID', { workflow_id: 72 }],
  ['same ID with wrong workflow path', { path: '.github/workflows/release.yml' }],
  ['manual run', { event: 'workflow_dispatch' }],
  ['push run', { event: 'push' }],
  ['rerun', { run_attempt: 2 }],
  ['different head SHA', { head_sha: unrelatedSha }],
  ['different head ref', { head_branch: 'another-branch' }],
  [
    'different head repository',
    { head_repository: { ...repository, id: 42, full_name: 'fork/zntc' } },
  ],
  ['different base repository', { repository: { ...repository, id: 42, full_name: 'fork/zntc' } }],
  ['different PR', { pull_requests: [pull({ number: 124 })] }],
  ['ambiguous PR association', { pull_requests: [pull(), pull({ number: 124 })] }],
  ['before PR creation', { created_at: '2025-12-31T23:59:59Z' }],
  ['after PR merge', { created_at: '2026-01-03T00:00:01Z' }],
]) {
  test(`never cancels ${label}`, async () => {
    const f = fixture({ runs: [run(changes), mainRun()] });
    await f.execute();
    assert.deepEqual(f.mutations(), []);
  });
}

test('empty run PR list requires unique commit association and unique branch ownership', async () => {
  const f = fixture({ runs: [run({ pull_requests: [] }), mainRun()] });
  await f.execute();
  assert.deepEqual(f.cancelled(), [201]);
  assert.ok(
    f.calls.some(
      ({ route, params }) =>
        route.endsWith('/commits/{commit_sha}/pulls') && params.commit_sha === headSha,
    ),
  );
  assert.ok(
    f.calls.some(
      ({ route, params }) =>
        route === `GET ${repoRoute}/pulls` &&
        params.state === 'all' &&
        params.head === `ohah:${branch}`,
    ),
  );
});

test('empty run PR list does not permit a reused branch even when the head commit is unique', async () => {
  const previous = pull({ number: 122, head: { ...pull().head, sha: unrelatedSha } });
  const f = fixture({
    runs: [run({ pull_requests: [] }), mainRun()],
    pulls: [pull(), previous],
    commitPulls: [pull()],
  });
  await f.execute();
  assert.deepEqual(f.mutations(), []);
});

test('empty run PR list does not permit ambiguous commit association', async () => {
  const f = fixture({
    runs: [run({ pull_requests: [] }), mainRun()],
    commitPulls: [pull(), pull({ number: 124 })],
  });
  await f.execute();
  assert.deepEqual(f.mutations(), []);
});

test('a successful completed main run also provides the replacement check', async () => {
  const f = fixture({ runs: [run(), mainRun({ status: 'completed', conclusion: 'success' })] });
  await f.execute();
  assert.deepEqual(f.cancelled(), [201]);
});

test('rechecks the main result immediately before cancelling a PR run', async () => {
  const f = fixture({
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/runs/{run_id}` && params.run_id === 202) {
        return { data: mainRun({ status: 'completed', conclusion: 'failure' }) };
      }
    },
  });
  await f.execute();
  assert.deepEqual(f.mutations(), []);
});

test('rechecks the PR run instead of cancelling a rerun from a stale list', async () => {
  const f = fixture({
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/runs/{run_id}` && params.run_id === 201) {
        return { data: run({ run_attempt: 2 }) };
      }
    },
  });
  await f.execute();
  assert.deepEqual(f.mutations(), []);
});

test('branch history is fully paginated before accepting an empty PR association', async () => {
  const foreignHistory = Array.from({ length: 99 }, (_, index) =>
    pull({
      number: 1000 + index,
      head: { ...pull().head, repo: { ...repository, id: 900 + index } },
    }),
  );
  const f = fixture({
    runs: [run({ pull_requests: [] }), mainRun()],
    pulls: [pull(), ...foreignHistory, pull({ number: 122 })],
    commitPulls: [pull()],
  });
  await f.execute();
  assert.deepEqual(f.mutations(), []);
  assert.ok(
    f.calls.some(({ route, params }) => route === `GET ${repoRoute}/pulls` && params.page === 2),
  );
});

for (const eventName of ['pull_request', 'push', 'issues']) {
  test(`ignores the unsupported ${eventName} event`, async () => {
    const f = fixture({ caches: [cache()] });
    await f.execute({ eventName });
    assert.deepEqual(f.calls, []);
  });
}

test('a main workflow event looks up the source run and the merged PR by commit', async () => {
  const f = fixture();
  await f.execute({
    eventName: 'workflow_run',
    payload: { action: 'in_progress', workflow_run: { id: 202 } },
  });
  assert.deepEqual(f.cancelled(), [201]);
  assert.ok(
    f.calls.some(
      ({ route, params }) =>
        route.endsWith('/commits/{commit_sha}/pulls') && params.commit_sha === mergeSha,
    ),
  );
});

for (const [label, changes] of [
  ['unmerged closed PR', { merged: false, merged_at: null }],
  ['open PR', { state: 'open', merged: false, merged_at: null }],
  ['different base repository', { base: { ...pull().base, repo: { ...repository, id: 42 } } }],
]) {
  test(`preserves caches for ${label}`, async () => {
    const f = fixture({ pull: pull(changes), runs: [mainRun()], caches: [cache()] });
    await f.execute({ eventName: 'schedule', payload: {} });
    assert.deepEqual(f.mutations(), []);
  });
}

test('a cache sweep deletes only exact merged PR merge refs', async () => {
  const preserved = [
    cache(302, { ref: 'refs/heads/main' }),
    cache(303, { ref: `refs/heads/${branch}` }),
    cache(304, { ref: 'refs/pull/123/head' }),
    cache(305, { ref: 'refs/pull/123/merge/extra' }),
    cache(306, { ref: 'refs/pull/0123/merge' }),
    cache(307, { ref: 'refs/pull/124/merge' }),
  ];
  const f = fixture({
    runs: [mainRun()],
    pulls: [pull(), pull({ number: 124, merged: false, merged_at: null })],
    caches: [cache(), ...preserved],
  });
  const result = await f.execute({ eventName: 'schedule', payload: {} });
  assert.deepEqual(f.deleted(), [301]);
  assert.deepEqual(result.plannedCaches, [301]);
  assert.deepEqual(result.deletedCaches, [301]);
  assert.equal(result.deletedBytes, 301);
  assert.deepEqual(
    f.caches.map((item) => item.id),
    preserved.map((item) => item.id),
  );
});

test('dry-run cache sweep reports IDs and leaves every cache intact', async () => {
  const f = fixture({ runs: [mainRun()], caches: [cache()] });
  const result = await f.execute({ eventName: 'workflow_dispatch', payload: {}, dryRun: true });
  assert.deepEqual(result.plannedCaches, [301]);
  assert.equal(result.plannedBytes, 301);
  assert.deepEqual(result.deletedCaches, []);
  assert.equal(result.deletedBytes, 0);
  assert.deepEqual(f.mutations(), []);
  assert.deepEqual(
    f.caches.map((item) => item.id),
    [301],
  );
});

for (const status of ['requested', 'queued', 'pending', 'waiting', 'in_progress']) {
  test(`preserves a cache while another workflow is ${status} on the PR branch`, async () => {
    const otherWorkflow = run({
      id: 203,
      workflow_id: 72,
      path: '.github/workflows/release.yml',
      event: 'workflow_dispatch',
      run_attempt: 2,
      head_sha: unrelatedSha,
      pull_requests: [],
      status,
    });
    const f = fixture({ runs: [mainRun(), otherWorkflow], caches: [cache()] });
    const result = await f.execute();
    assert.deepEqual(f.mutations(), []);
    assert.deepEqual(result.deferredPulls, [123]);
  });
}

for (const [label, changes] of [
  ['PR number despite a different branch', { head_branch: 'renamed-branch' }],
  ['full PR merge ref', { head_branch: 'refs/pull/123/merge', pull_requests: [] }],
  ['short PR merge ref', { head_branch: '123/merge', pull_requests: [] }],
  ['missing branch identity', { head_branch: null, pull_requests: [] }],
  ['missing PR identity', { head_branch: 'unrelated', pull_requests: null }],
]) {
  test(`preserves caches for active runs with ${label}`, async () => {
    const f = fixture({
      runs: [mainRun(), run({ id: 203, event: 'workflow_dispatch', ...changes })],
      caches: [cache()],
    });
    const result = await f.execute();
    assert.deepEqual(f.deleted(), []);
    assert.deepEqual(result.deferredPulls, [123]);
  });
}

test('an unrelated active run or a completed related run does not block cache cleanup', async () => {
  const f = fixture({
    runs: [
      mainRun(),
      run({ id: 203, head_branch: 'unrelated', pull_requests: [pull({ number: 124 })] }),
      run({ id: 204, status: 'completed', conclusion: 'success' }),
    ],
    caches: [cache()],
  });
  await f.execute();
  assert.deepEqual(f.cancelled(), []);
  assert.deepEqual(f.deleted(), [301]);
});

test('rechecks every active status before deletion and preserves a newly queued workflow', async () => {
  let activeScans = 0;
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route, params, runs }) {
      if (route === `GET ${repoRoute}/actions/runs` && params.status === 'requested') {
        activeScans += 1;
        if (activeScans === 2) {
          runs.push(
            run({ id: 203, event: 'workflow_dispatch', status: 'queued', pull_requests: [] }),
          );
        }
      }
    },
  });
  const result = await f.execute();
  assert.ok(activeScans >= 2, 'must query active runs again after initially observing no writer');
  assert.deepEqual(f.deleted(), []);
  assert.deepEqual(result.deferredPulls, [123]);
  for (const status of ['requested', 'queued', 'pending', 'waiting', 'in_progress']) {
    assert.ok(
      f.calls.filter(
        ({ route, params }) =>
          route === `GET ${repoRoute}/actions/runs` && params.status === status,
      ).length >= 2,
    );
  }
});

test('collects more than 100 caches before mutating pagination and deletes every selected ID', async () => {
  const caches = Array.from({ length: 137 }, (_, index) => cache(500 + index));
  const f = fixture({
    runs: [mainRun()],
    caches,
    request({ route, cachePages }) {
      if (route.startsWith('DELETE ')) {
        assert.ok(cachePages.has(2), 'deletion began before the final list page was collected');
      }
    },
  });
  const result = await f.execute();
  assert.deepEqual(
    f.deleted(),
    caches.map((item) => item.id),
  );
  assert.deepEqual(
    result.deletedCaches,
    caches.map((item) => item.id),
  );
  assert.equal(
    result.deletedBytes,
    caches.reduce((sum, item) => sum + item.size_in_bytes, 0),
  );
  assert.deepEqual(f.caches, []);
});

test('a cache disappearing during the final identity check is not deleted by key', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/caches` && params.key) {
        return { data: { total_count: 0, actions_caches: [] } };
      }
    },
  });
  await f.execute();
  assert.deepEqual(f.deleted(), []);
});

test('a final cache lookup returning the same ID under a different ref fails closed', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/caches` && params.key) {
        return {
          data: { total_count: 1, actions_caches: [cache(301, { ref: 'refs/heads/main' })] },
        };
      }
    },
  });
  await assert.rejects(f.execute(), /scope changed/i);
  assert.deepEqual(f.mutations(), []);
});

for (const [label, route, paramsMatch] of [
  [
    'replacement search',
    `GET ${repoRoute}/actions/workflows/{workflow_id}/runs`,
    (params) => params.event === 'push',
  ],
  [
    'active workflow search',
    `GET ${repoRoute}/actions/runs`,
    (params) => params.status === 'waiting',
  ],
]) {
  test(`a 1,000-result ${label} cap fails closed`, async () => {
    const f = fixture({
      runs: [mainRun()],
      caches: [cache()],
      request(request) {
        if (request.route === route && paramsMatch(request.params)) {
          return { data: { total_count: 1000, workflow_runs: [] } };
        }
      },
    });
    await assert.rejects(f.execute(), /1,000|limit/i);
    assert.deepEqual(f.mutations(), []);
  });
}

test('incomplete cache pagination does not turn a missing page into permission to delete', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route }) {
      if (route === `GET ${repoRoute}/actions/caches`) {
        return { data: { total_count: 101, actions_caches: [cache()] } };
      }
    },
  });
  await assert.rejects(f.execute(), /pagination/i);
  assert.deepEqual(f.mutations(), []);
});

test('failure on the second cache page leaves all caches untouched', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: Array.from({ length: 137 }, (_, index) => cache(500 + index)),
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/caches` && params.page === 2) throw httpError(503);
    },
  });
  await assert.rejects(f.execute(), { status: 503 });
  assert.deepEqual(f.mutations(), []);
});

test('exhausting the page budget for branch history fails closed', async () => {
  const f = fixture({
    runs: [run({ pull_requests: [] }), mainRun()],
    request({ route, params }) {
      if (route === `GET ${repoRoute}/pulls`) {
        return {
          data: Array.from({ length: 100 }, (_, index) => ({ id: params.page * 100 + index })),
        };
      }
    },
  });
  await assert.rejects(f.execute(), /pagination limit/i);
  assert.deepEqual(f.mutations(), []);
});

test('an API error while looking for active writers fails closed', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/runs` && params.status === 'pending')
        throw httpError(403);
    },
  });
  await assert.rejects(f.execute(), { status: 403 });
  assert.deepEqual(f.mutations(), []);
});

test('404 while deleting an already removed cache is a harmless terminal race', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route }) {
      if (route.startsWith('DELETE ')) throw httpError(404);
    },
  });
  const result = await f.execute();
  assert.deepEqual(f.deleted(), [301]);
  assert.deepEqual(result.deletedCaches, []);
  assert.equal(result.deletedBytes, 0);
});

test('409 cancelling a just-completed run is harmless only after refreshing its terminal state', async () => {
  const f = fixture({
    request({ route, params, runs }) {
      if (route.endsWith('/cancel')) {
        const current = runs.find((item) => item.id === params.run_id);
        current.status = 'completed';
        current.conclusion = 'success';
        throw httpError(409);
      }
    },
  });
  const result = await f.execute();
  assert.deepEqual(f.cancelled(), [201]);
  assert.deepEqual(result.cancelledRuns, []);
  const cancelIndex = f.calls.findIndex(({ route }) => route.endsWith('/cancel'));
  assert.ok(
    f.calls
      .slice(cancelIndex + 1)
      .some(
        ({ route, params }) => route.endsWith('/actions/runs/{run_id}') && params.run_id === 201,
      ),
  );
});

test('409 cancelling a still-active run is deferred and cannot authorize cache deletion', async () => {
  const f = fixture({
    caches: [cache()],
    request({ route }) {
      if (route.endsWith('/cancel')) throw httpError(409);
    },
  });
  const result = await f.execute();
  assert.deepEqual(f.cancelled(), [201]);
  assert.deepEqual(result.cancelledRuns, []);
  assert.deepEqual(result.deferredPulls, [123]);
  assert.deepEqual(f.deleted(), []);
});

for (const [label, changes] of [
  ['attempt 2', { run_attempt: 2 }],
  ['another SHA', { head_sha: unrelatedSha }],
  ['another ref', { head_branch: 'different-branch' }],
  ['another repository', { repository: { ...repository, id: 42 } }],
  ['another head repository', { head_repository: { ...repository, id: 42 } }],
  ['another workflow ID', { workflow_id: 72 }],
  ['another workflow path', { path: '.github/workflows/benchmark.yml' }],
  ['manual event', { event: 'workflow_dispatch' }],
  ['completed run', { status: 'completed', conclusion: 'success' }],
]) {
  test(`a run changing to ${label} during association checks cannot be cancelled`, async () => {
    const f = fixture({
      runs: [run({ pull_requests: [] }), mainRun()],
      request({ route, params, runs, calls }) {
        if (route === `GET ${repoRoute}/actions/runs/{run_id}` && params.run_id === 202) {
          assert.ok(
            calls.some((item) => item.route === `GET ${repoRoute}/pulls`),
            'race must occur after the fallback identity proof',
          );
          Object.assign(
            runs.find((item) => item.id === 201),
            changes,
          );
        }
      },
    });
    await f.execute();
    assert.deepEqual(f.mutations(), []);
    assert.ok(
      f.calls.filter(
        ({ route, params }) => route.endsWith('/actions/runs/{run_id}') && params.run_id === 201,
      ).length >= 2,
    );
  });
}

test('an active writer arriving during the final cache identity lookup prevents deletion', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route, params, runs }) {
      if (route === `GET ${repoRoute}/actions/caches` && params.key) {
        runs.push(
          run({ id: 203, event: 'workflow_dispatch', status: 'waiting', pull_requests: [] }),
        );
      }
    },
  });
  const result = await f.execute();
  assert.deepEqual(f.deleted(), []);
  assert.deepEqual(result.deferredPulls, [123]);
});

test('omitting dryRun defaults to a non-mutating plan', async () => {
  const f = fixture();
  const result = await runMaintenance({
    github: f.github,
    context: {
      repo: { owner: 'ohah', repo: 'zntc' },
      eventName: 'pull_request_target',
      payload: { action: 'closed', pull_request: pull() },
    },
  });
  assert.equal(result.dryRun, true);
  assert.deepEqual(result.plannedRuns, [201]);
  assert.deepEqual(f.mutations(), []);
});

test('a string dryRun value cannot silently enable mutations', async () => {
  const f = fixture();
  await assert.rejects(f.execute({ dryRun: 'false' }), /boolean/);
  assert.deepEqual(f.calls, []);
});

test('missing run PR association data cannot be treated as an empty association', async () => {
  const f = fixture({ runs: [run({ pull_requests: null }), mainRun()] });
  await assert.rejects(f.execute(), /associations/i);
  assert.deepEqual(f.mutations(), []);
});

test('unknown active status fails closed rather than allowing cache deletion', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/runs` && params.status === 'waiting') {
        return { data: { total_count: 1, workflow_runs: [run({ status: 'new-unknown-state' })] } };
      }
    },
  });
  await assert.rejects(f.execute(), /Unknown workflow status/);
  assert.deepEqual(f.mutations(), []);
});

test('a merged PR CI starting late triggers cleanup after its main replacement has started', async () => {
  const f = fixture({
    runs: [run({ run_started_at: '2026-01-03T00:00:20Z' }), mainRun()],
  });
  await f.execute({
    eventName: 'workflow_run',
    payload: { action: 'in_progress', workflow_run: { id: 201 } },
  });
  assert.deepEqual(f.cancelled(), [201]);
  assert.ok(
    f.calls.some(
      ({ route, params }) =>
        route.endsWith('/commits/{commit_sha}/pulls') && params.commit_sha === headSha,
    ),
  );
});

for (const [label, changes] of [
  ['another workflow', { workflow_id: 72, path: '.github/workflows/release.yml', name: 'Release' }],
  ['CI with a different workflow ID', { workflow_id: 72 }],
  ['CI with a different workflow path', { path: '.github/workflows/benchmark.yml' }],
  ['attempt 2', { run_attempt: 2 }],
  ['a manual event', { event: 'workflow_dispatch' }],
]) {
  test(`an in-progress PR lifecycle event for ${label} does not start maintenance`, async () => {
    const f = fixture({ runs: [run(changes), mainRun()], caches: [cache()] });
    await f.execute({
      eventName: 'workflow_run',
      payload: { action: 'in_progress', workflow_run: { id: 201 } },
    });
    assert.deepEqual(f.mutations(), []);
    assert.ok(!f.calls.some(({ route }) => route.endsWith('/commits/{commit_sha}/pulls')));
  });
}

test('completion of another PR workflow reconciles its late cache save', async () => {
  const completed = run({
    id: 203,
    workflow_id: 72,
    name: 'Benchmark',
    path: '.github/workflows/benchmark.yml',
    status: 'completed',
    conclusion: 'success',
  });
  const f = fixture({ runs: [mainRun(), completed], caches: [cache()] });
  await f.execute({
    eventName: 'workflow_run',
    payload: { action: 'completed', workflow_run: { id: 203 } },
  });
  assert.deepEqual(f.cancelled(), []);
  assert.deepEqual(f.deleted(), [301]);
});

test('a branch writer missed during a status transition still prevents cache deletion', async () => {
  const f = fixture({
    runs: [
      mainRun(),
      run({
        id: 203,
        event: 'workflow_dispatch',
        workflow_id: 72,
        path: '.github/workflows/benchmark.yml',
        head_sha: unrelatedSha,
        status: 'in_progress',
        pull_requests: [],
      }),
    ],
    caches: [cache()],
    request({ route, params }) {
      // A queued -> in_progress transition can evade separately timed queries.
      // The unfiltered branch query must independently detect this writer.
      if (route === `GET ${repoRoute}/actions/runs` && params.status) {
        return { data: { total_count: 0, workflow_runs: [] } };
      }
    },
  });
  const result = await f.execute();
  assert.deepEqual(f.deleted(), []);
  assert.deepEqual(result.deferredPulls, [123]);
  assert.ok(
    f.calls.some(
      ({ route, params }) =>
        route === `GET ${repoRoute}/actions/runs` && params.branch === branch && !params.status,
    ),
  );
});

test('the unfiltered branch query also fails closed at the GitHub search cap', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/runs` && params.branch === branch && !params.status) {
        return { data: { total_count: 1000, workflow_runs: [] } };
      }
    },
  });
  await assert.rejects(f.execute(), /1,000|limit/i);
  assert.deepEqual(f.mutations(), []);
});

test('an unknown status found only by the unfiltered branch query preserves caches', async () => {
  const f = fixture({
    runs: [mainRun()],
    caches: [cache()],
    request({ route, params }) {
      if (route === `GET ${repoRoute}/actions/runs` && params.branch === branch && !params.status) {
        return { data: { total_count: 1, workflow_runs: [run({ status: 'new-unknown-state' })] } };
      }
    },
  });
  await assert.rejects(f.execute(), /Unknown branch workflow status/);
  assert.deepEqual(f.mutations(), []);
});
