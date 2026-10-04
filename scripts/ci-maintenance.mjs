// This module only consumes GitHub API metadata. The privileged workflow loads
// it from its own trusted commit, never from a PR checkout or an artifact.
const CI_PATH = '.github/workflows/ci.yml';
const ACTIVE = ['requested', 'queued', 'pending', 'waiting', 'in_progress'];
const PR_REF = /^refs\/pull\/([1-9][0-9]*)\/merge$/;

function positiveId(value) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error('Invalid GitHub ID');
  return value;
}

function sameRepo(a, b) {
  return Number.isSafeInteger(a?.id) && a.id === b?.id;
}

function time(value) {
  const result = Date.parse(value);
  if (!Number.isFinite(result)) throw new Error('Missing GitHub timestamp');
  return result;
}

export async function runMaintenance({ github, context, dryRun = true, log = () => {} }) {
  if (typeof dryRun !== 'boolean') throw new Error('dryRun must be boolean');
  const result = {
    dryRun,
    plannedRuns: [],
    cancelledRuns: [],
    plannedCaches: [],
    plannedBytes: 0,
    deletedCaches: [],
    deletedBytes: 0,
    deferredPulls: [],
  };
  const supported = ['workflow_run', 'pull_request_target', 'workflow_dispatch', 'schedule'];
  if (!supported.includes(context.eventName)) return result;
  const { owner, repo } = context.repo;
  const api = async (route, params = {}) =>
    (await github.request(route, { owner, repo, ...params })).data;
  // Collect every page before mutating. A filtered runs query is capped at
  // 1,000 by GitHub; reaching that cap is uncertainty, never an empty result.
  async function list(route, field, params = {}) {
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        return await listSnapshot(route, field, params);
      } catch (error) {
        if (error.code !== 'INCOMPLETE_PAGINATION' || attempt === 3) throw error;
        // Status counts and rows can briefly disagree while workflows start or
        // finish. Restart at page one; never accept the partial snapshot.
        log(`Retrying changing GitHub inventory (${attempt}/3): ${route}`);
        await new Promise((resolve) => setTimeout(resolve, attempt * 500));
      }
    }
  }

  async function listSnapshot(route, field, params) {
    const items = [];
    let total = 0;
    for (let page = 1; page <= 100; page++) {
      const data = await api(route, { ...params, per_page: 100, page });
      const rows = field ? data[field] : data;
      if (!Array.isArray(rows)) throw new Error(`Incomplete response: ${route}`);
      if (field === 'workflow_runs' && data.total_count >= 1000) {
        throw new Error('Workflow search reached the 1,000 run limit; cleanup deferred');
      }
      total = Math.max(total, data.total_count ?? 0);
      items.push(...rows);
      if (rows.length < 100) {
        const unique = [...new Map(items.map((item) => [positiveId(item.id), item])).values()];
        if (unique.length < total) {
          throw Object.assign(
            new Error(`Incomplete pagination: ${route} (${unique.length}/${total})`),
            { code: 'INCOMPLETE_PAGINATION' },
          );
        }
        return unique;
      }
    }
    throw new Error(`Pagination limit reached: ${route}`);
  }

  const repository = await api('GET /repos/{owner}/{repo}');
  positiveId(repository.id);
  if (typeof repository.default_branch !== 'string' || !repository.default_branch) {
    throw new Error('Missing default branch');
  }
  const workflow = await api('GET /repos/{owner}/{repo}/actions/workflows/{workflow_id}', {
    workflow_id: 'ci.yml',
  });
  positiveId(workflow.id);
  if (workflow.path !== CI_PATH) throw new Error('Unexpected CI workflow path');
  const pull = async (pull_number) => {
    const data = await api('GET /repos/{owner}/{repo}/pulls/{pull_number}', {
      pull_number: positiveId(pull_number),
    });
    if (data.number !== pull_number) throw new Error('Unexpected PR identity');
    return data;
  };
  const run = async (run_id) => {
    const data = await api('GET /repos/{owner}/{repo}/actions/runs/{run_id}', {
      run_id: positiveId(run_id),
    });
    if (data.id !== run_id) throw new Error('Unexpected run identity');
    return data;
  };
  const mergedHere = (pr) =>
    pr.merged === true &&
    pr.state === 'closed' &&
    sameRepo(pr.base?.repo, repository) &&
    Boolean(pr.merged_at);
  const isCi = (r) =>
    r.workflow_id === workflow.id && r.path === CI_PATH && sameRepo(r.repository, repository);
  async function associated(sha) {
    if (!/^[a-f0-9]{40}$/i.test(sha ?? '')) throw new Error('Invalid commit SHA');
    return list('GET /repos/{owner}/{repo}/commits/{commit_sha}/pulls', null, { commit_sha: sha });
  }

  const candidates = new Set();
  const sweep = ['schedule', 'workflow_dispatch'].includes(context.eventName);
  if (sweep) {
    const caches = await list('GET /repos/{owner}/{repo}/actions/caches', 'actions_caches');
    for (const cache of caches) {
      const match = PR_REF.exec(cache.ref);
      if (match) candidates.add(positiveId(Number(match[1])));
    }
  } else if (context.eventName === 'pull_request_target') {
    if (context.payload.action !== 'closed' || context.payload.pull_request?.merged !== true)
      return result;
    candidates.add(positiveId(context.payload.pull_request.number));
  } else {
    const source = await run(context.payload.workflow_run?.id);
    const mainEvent =
      isCi(source) &&
      source.event === 'push' &&
      source.head_branch === repository.default_branch &&
      sameRepo(source.head_repository, repository);
    const prEvent =
      source.event === 'pull_request' &&
      (context.payload.action === 'completed' ||
        (isCi(source) && context.payload.action === 'in_progress' && source.run_attempt === 1));
    if (!mainEvent && !prEvent) return result;
    for (const pr of await associated(source.head_sha)) candidates.add(positiveId(pr.number));
  }

  async function activeRuns() {
    const pages = await Promise.all(
      ACTIVE.map((status) =>
        list('GET /repos/{owner}/{repo}/actions/runs', 'workflow_runs', { status }),
      ),
    );
    const all = [...new Map(pages.flat().map((r) => [positiveId(r.id), r])).values()];
    if (all.some((r) => ![...ACTIVE, 'completed'].includes(r.status))) {
      throw new Error('Unknown workflow status; cleanup deferred');
    }
    return all.filter((r) => r.status !== 'completed');
  }

  async function replacementStarted(r, pr) {
    if (
      !isCi(r) ||
      r.event !== 'push' ||
      r.head_branch !== repository.default_branch ||
      !sameRepo(r.head_repository, repository) ||
      r.head_sha !== pr.merge_commit_sha
    )
      return false;
    if (r.status === 'completed') return r.conclusion === 'success';
    if (!ACTIVE.includes(r.status) || r.conclusion) return false;
    if (r.status === 'in_progress') return true;
    // A matrix can report queued while some jobs have already started.
    const jobs = await list(
      'GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt_number}/jobs',
      'jobs',
      { run_id: positiveId(r.id), attempt_number: positiveId(r.run_attempt) },
    );
    return jobs.some(
      (j) =>
        j.status === 'in_progress' ||
        (j.status === 'completed' &&
          ['success', 'failure', 'timed_out', 'action_required', 'neutral', 'stale'].includes(
            j.conclusion,
          )),
    );
  }

  function matchesPullRun(r, pr) {
    if (
      !isCi(r) ||
      r.event !== 'pull_request' ||
      r.run_attempt !== 1 ||
      !ACTIVE.includes(r.status) ||
      r.head_sha !== pr.head?.sha ||
      r.head_branch !== pr.head?.ref ||
      !sameRepo(r.head_repository, pr.head?.repo) ||
      time(r.created_at) < time(pr.created_at) ||
      time(r.created_at) > time(pr.merged_at)
    )
      return false;
    if (!Array.isArray(r.pull_requests)) throw new Error('Missing run PR associations');
    return (
      r.pull_requests.length === 0 ||
      (r.pull_requests.length === 1 && r.pull_requests[0].number === pr.number)
    );
  }

  async function belongsToPull(r, pr) {
    if (!matchesPullRun(r, pr)) return false;
    if (r.pull_requests.length) return true;
    // GitHub often empties pull_requests after merge. Require both commit
    // association and a historically unique head branch; never guess by name.
    const linked = await associated(r.head_sha);
    if (linked.length !== 1 || linked[0].number !== pr.number) return false;
    const headOwner = pr.head.repo?.owner?.login;
    if (!headOwner) return false;
    const history = await list('GET /repos/{owner}/{repo}/pulls', null, {
      state: 'all',
      head: `${headOwner}:${pr.head.ref}`,
    });
    if (history.some((p) => !p.head?.repo || !p.head?.ref)) return false;
    const matching = history.filter(
      (p) => sameRepo(p.head?.repo, pr.head.repo) && p.head?.ref === pr.head.ref,
    );
    return matching.length === 1 && matching[0].number === pr.number;
  }

  // Busy detection is deliberately broader than cancellation. Any workflow,
  // old head, rerun, or ambiguous identity can still write this PR's cache.
  function busy(runs, pr) {
    if (!pr.head?.ref) return true;
    return runs.some((r) => {
      if (!r.head_branch || !Array.isArray(r.pull_requests)) return true;
      if (r.pull_requests.some((p) => p.number === pr.number)) return true;
      return [pr.head?.ref, `refs/pull/${pr.number}/merge`, `${pr.number}/merge`].includes(
        r.head_branch,
      );
    });
  }

  async function busyNow(pr) {
    if (!pr.head?.ref) return true;
    const active = await activeRuns();
    // A queued -> in_progress transition can fall between two status-filtered
    // snapshots. Also query this branch without a status filter before deleting.
    const branchRuns = await list('GET /repos/{owner}/{repo}/actions/runs', 'workflow_runs', {
      branch: pr.head.ref,
    });
    if (branchRuns.some((r) => ![...ACTIVE, 'completed'].includes(r.status))) {
      throw new Error('Unknown branch workflow status; cleanup deferred');
    }
    return busy([...active, ...branchRuns.filter((r) => r.status !== 'completed')], pr);
  }

  async function maintainPull(number) {
    const pr = await pull(number);
    if (!mergedHere(pr)) return;
    if (pr.base.ref === repository.default_branch) {
      const replacements = await list(
        'GET /repos/{owner}/{repo}/actions/workflows/{workflow_id}/runs',
        'workflow_runs',
        {
          workflow_id: workflow.id,
          event: 'push',
          branch: repository.default_branch,
          head_sha: pr.merge_commit_sha,
        },
      );
      let replacement;
      for (const r of replacements) {
        if (await replacementStarted(r, pr)) {
          replacement = r;
          break;
        }
      }
      if (replacement) {
        const possible = await list(
          'GET /repos/{owner}/{repo}/actions/workflows/{workflow_id}/runs',
          'workflow_runs',
          { workflow_id: workflow.id, event: 'pull_request', head_sha: pr.head?.sha },
        );
        for (const entry of possible) {
          if (!ACTIVE.includes(entry.status)) continue;
          const current = await run(entry.id);
          if (!(await belongsToPull(current, pr))) continue;
          if (!(await replacementStarted(await run(replacement.id), pr))) break;
          // A manual rerun keeps the run ID. Do not cancel a new attempt that
          // started while commit/history/replacement metadata was being read.
          if (!matchesPullRun(await run(current.id), pr)) continue;
          result.plannedRuns.push(current.id);
          log(
            `${dryRun ? 'Would cancel' : 'Cancelling'} merged PR #${number} CI run ${current.id}`,
          );
          if (!dryRun) {
            try {
              await api('POST /repos/{owner}/{repo}/actions/runs/{run_id}/cancel', {
                run_id: current.id,
              });
              result.cancelledRuns.push(current.id);
            } catch (error) {
              if (error.status !== 409) throw error;
              if ((await run(current.id)).status !== 'completed') {
                result.deferredPulls.push(number);
                log(
                  `Cancellation of run ${current.id} raced another request; retry on the next event`,
                );
              }
            }
          }
        }
      }
    }

    const ref = `refs/pull/${number}/merge`;
    const caches = await list('GET /repos/{owner}/{repo}/actions/caches', 'actions_caches', {
      ref,
    });
    if (caches.some((c) => c.ref !== ref)) throw new Error('Cache query returned a different ref');
    if (!caches.length) return;
    if (await busyNow(pr)) {
      result.deferredPulls.push(number);
      log(`Preserving PR #${number} caches while a related workflow is active`);
      return;
    }
    if (!mergedHere(await pull(number))) throw new Error('PR merge state changed');
    for (const cache of caches) {
      const fresh = await api('GET /repos/{owner}/{repo}/actions/caches', {
        ref,
        key: cache.key,
        per_page: 100,
      });
      if (!Array.isArray(fresh.actions_caches)) throw new Error('Incomplete cache recheck');
      const exact = fresh.actions_caches.find((c) => c.id === cache.id);
      if (!exact) continue;
      if (exact.ref !== ref) throw new Error('Cache scope changed');
      // Check activity last, including reruns that began during the ID lookup.
      // A later save is handled by the completed event and the daily sweep.
      if (await busyNow(pr)) {
        result.deferredPulls.push(number);
        break;
      }
      result.plannedCaches.push(cache.id);
      result.plannedBytes += exact.size_in_bytes;
      log(
        `${dryRun ? 'Would delete' : 'Deleting'} PR #${number} cache ${cache.id} (${cache.size_in_bytes} bytes)`,
      );
      if (!dryRun) {
        try {
          await api('DELETE /repos/{owner}/{repo}/actions/caches/{cache_id}', {
            cache_id: cache.id,
          });
          result.deletedCaches.push(cache.id);
          result.deletedBytes += cache.size_in_bytes;
        } catch (error) {
          if (error.status !== 404) throw error;
        }
      }
    }
  }
  for (const number of candidates) {
    try {
      await maintainPull(number);
    } catch (error) {
      if (error.code !== 'INCOMPLETE_PAGINATION') throw error;
      // A persistently changing inventory cannot authorize another mutation
      // for this PR. Keep its remaining caches and retry on the next event,
      // while allowing independently verified PRs in a sweep to make progress.
      result.deferredPulls.push(number);
      log(`Deferring PR #${number} until the next maintenance event: ${error.message}`);
    }
  }
  result.deferredPulls = [...new Set(result.deferredPulls)];
  return result;
}
