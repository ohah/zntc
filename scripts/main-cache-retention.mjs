const MAIN_REF = 'refs/heads/main';
const PREFIX = 'setup-zig-cache-v2-';
const CACHE_ROUTE = 'GET /repos/{owner}/{repo}/actions/caches';
// Hosted jobs can run for at most six hours. Keep two extra hours of margin,
// and retain two generations that already existed before that whole window.
const GRACE_MS = 8 * 60 * 60 * 1000;
const KEY =
  /^(setup-zig-cache-v2-[A-Za-z0-9_]+-zig-[a-z0-9_]+-(?:linux|macos|windows)-\d+\.\d+\.\d+(?:-dev\.\d+\+[a-f0-9]+)?-[A-Za-z0-9_.+-]*-)([1-9][0-9]*)-([1-9][0-9]*)$/;

function validId(id) {
  return Number.isSafeInteger(id) && id > 0;
}

function family(cache) {
  if (!validId(cache.id) || typeof cache.key !== 'string') return null;
  const match = KEY.exec(cache.key);
  if (!match || typeof cache.version !== 'string' || !cache.version) return null;
  const runId = Number(match[2]);
  const attempt = Number(match[3]);
  if (!validId(runId) || !validId(attempt)) return null;
  return {
    prefix: match[1],
    group: JSON.stringify([match[1], cache.version]),
    runId,
    attempt,
  };
}

function timestamp(value) {
  return typeof value === 'string' ? Date.parse(value) : NaN;
}

export function planMainCacheRetention(caches, { now = Date.now(), ref = MAIN_REF } = {}) {
  if (ref !== MAIN_REF) throw new Error('Only main Zig cache retention is supported');
  if (!Number.isFinite(now)) throw new Error('Invalid retention time');
  const result = { candidates: [], protectedCaches: [], ignoredCaches: [] };
  const groups = new Map();
  for (const cache of caches) {
    const parsed = cache.ref === MAIN_REF ? family(cache) : null;
    if (!parsed) {
      if (validId(cache.id)) result.ignoredCaches.push(cache.id);
      continue;
    }
    if (!groups.has(parsed.group)) groups.set(parsed.group, []);
    groups.get(parsed.group).push(cache);
  }

  const cutoff = now - GRACE_MS;
  for (const group of groups.values()) {
    // Missing metadata must not promote a partial inventory into a deletion
    // plan, or count an unclassifiable generation as one of the retained two.
    if (
      group.some(
        (cache) =>
          !Number.isFinite(timestamp(cache.created_at)) ||
          !Number.isFinite(timestamp(cache.last_accessed_at)) ||
          !Number.isSafeInteger(cache.size_in_bytes) ||
          cache.size_in_bytes < 0,
      )
    ) {
      result.protectedCaches.push(...group.map((cache) => cache.id));
      continue;
    }
    const mature = group
      .filter((cache) => timestamp(cache.created_at) <= cutoff)
      .sort((a, b) => timestamp(b.created_at) - timestamp(a.created_at));
    const boundary = mature.length >= 2 ? timestamp(mature[1].created_at) : -Infinity;
    for (const cache of group) {
      if (timestamp(cache.created_at) >= boundary || timestamp(cache.last_accessed_at) >= cutoff) {
        // Preserve ties too; an ID is not evidence of creation order.
        result.protectedCaches.push(cache.id);
      } else {
        result.candidates.push(cache);
      }
    }
  }
  return result;
}

export async function pruneMainCaches({
  api,
  list,
  run,
  repository,
  dryRun = true,
  now = Date.now(),
  log = () => {},
}) {
  if (typeof dryRun !== 'boolean') throw new Error('dryRun must be boolean');
  if (!validId(repository.id) || repository.default_branch !== 'main') {
    throw new Error('Main cache retention requires the main default branch');
  }
  const result = {
    dryRun,
    plannedCaches: [],
    plannedBytes: 0,
    deletedCaches: [],
    deletedBytes: 0,
    protectedCaches: [],
    deferredCaches: [],
  };
  async function inventory(prefix) {
    const caches = await list(CACHE_ROUTE, 'actions_caches', {
      ref: MAIN_REF,
      key: prefix,
      sort: 'created_at',
      direction: 'desc',
    });
    if (caches.some((cache) => cache.ref !== MAIN_REF || !cache.key?.startsWith(prefix))) {
      throw new Error('Main cache query escaped its ref or key prefix');
    }
    return caches;
  }

  async function finishedOwner(parsed) {
    let source;
    try {
      source = await run(parsed.runId);
    } catch (error) {
      if (error.status === 404) return false;
      throw error;
    }
    return (
      source.id === parsed.runId &&
      source.repository?.id === repository.id &&
      source.head_repository?.id === repository.id &&
      source.head_branch === 'main' &&
      source.status === 'completed' &&
      validId(source.run_attempt) &&
      source.run_attempt >= parsed.attempt
    );
  }

  const initial = planMainCacheRetention(await inventory(PREFIX), { now });
  result.protectedCaches.push(...initial.protectedCaches, ...initial.ignoredCaches);
  // The first owner lookup can be shared by caches saved by the same run.
  // Every actual deletion still rechecks that run after its cache lookup.
  const owners = new Map();
  for (const cache of initial.candidates) {
    const parsed = family(cache);
    if (!owners.has(parsed.runId)) owners.set(parsed.runId, await finishedOwner(parsed));
    if (!owners.get(parsed.runId)) {
      result.deferredCaches.push(cache.id);
      log(`Preserving main cache ${cache.id}: its saving run is active or unverifiable`);
      continue;
    }
    let fresh;
    try {
      fresh = await inventory(parsed.prefix);
    } catch (error) {
      if (error.code !== 'INCOMPLETE_PAGINATION') throw error;
      result.deferredCaches.push(cache.id);
      log(`Deferring main cache ${cache.id}: ${error.message}`);
      continue;
    }
    const exact = fresh.find((item) => item.id === cache.id);
    if (!exact) continue;
    if (
      exact.key !== cache.key ||
      exact.version !== cache.version ||
      exact.created_at !== cache.created_at ||
      exact.size_in_bytes !== cache.size_in_bytes
    ) {
      throw new Error('Main cache identity changed');
    }
    if (exact.last_accessed_at !== cache.last_accessed_at) {
      result.protectedCaches.push(cache.id);
      continue;
    }
    if (!planMainCacheRetention(fresh, { now }).candidates.some((item) => item.id === cache.id)) {
      result.protectedCaches.push(cache.id);
      continue;
    }
    if (!(await finishedOwner(parsed))) {
      result.deferredCaches.push(cache.id);
      continue;
    }
    result.plannedCaches.push(cache.id);
    result.plannedBytes += exact.size_in_bytes;
    log(
      `${dryRun ? 'Would delete' : 'Deleting'} old main Zig cache ${cache.id} (${exact.size_in_bytes} bytes)`,
    );
    if (dryRun) continue;
    try {
      await api('DELETE /repos/{owner}/{repo}/actions/caches/{cache_id}', { cache_id: cache.id });
      result.deletedCaches.push(cache.id);
      result.deletedBytes += exact.size_in_bytes;
    } catch (error) {
      if (error.status !== 404) throw error;
    }
  }
  result.protectedCaches = [...new Set(result.protectedCaches)];
  return result;
}
