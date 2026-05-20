/// Build determinism gate (#3564) — 같은 입력으로 N=10회 빌드 → bundle byte-identical.

import { afterAll, describe, test, expect } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { dirContentsHash, runZntc, sha256OfFile } from './helpers';

const FIXTURE_ROOT = resolve(import.meta.dir, 'fixtures/determinism');
const REPEAT_COUNT = 10;

type Mode = 'file' | 'outdir';

const tmpRoots: string[] = [];
afterAll(async () => {
  await Promise.all(tmpRoots.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function expectDeterministic(
  fixtureName: string,
  entryFile: string,
  extraArgs: string[] = [],
  mode: Mode = 'file',
): Promise<void> {
  const fixtureDir = join(FIXTURE_ROOT, fixtureName);
  const tmpRoot = await mkdtemp(join(tmpdir(), `zntc-determinism-${fixtureName}-`));
  tmpRoots.push(tmpRoot);

  if (mode === 'outdir') {
    const allRuns: Array<Array<{ path: string; hash: string; size: number }>> = [];
    for (let i = 0; i < REPEAT_COUNT; i++) {
      const outDir = join(tmpRoot, `run-${i}`);
      const r = await runZntc([
        '--bundle',
        join(fixtureDir, entryFile),
        '--outdir',
        outDir,
        ...extraArgs,
      ]);
      if (r.exitCode !== 0) {
        throw new Error(`[${fixtureName}] run ${i} exited ${r.exitCode}\n${r.stderr}`);
      }
      allRuns.push(await dirContentsHash(outDir));
    }
    const first = allRuns[0];
    for (let i = 1; i < allRuns.length; i++) {
      expect(allRuns[i], `run ${i} outdir contents mismatch`).toEqual(first);
    }
    return;
  }

  const results: { hash: string; size: number; mapHash: string | null }[] = [];
  for (let i = 0; i < REPEAT_COUNT; i++) {
    const outFile = join(tmpRoot, `run-${i}`, 'bundle.js');
    const r = await runZntc(['--bundle', join(fixtureDir, entryFile), '-o', outFile, ...extraArgs]);
    if (r.exitCode !== 0) {
      throw new Error(`[${fixtureName}] run ${i} exited ${r.exitCode}\n${r.stderr}`);
    }
    const js = await sha256OfFile(outFile);
    const mapPath = `${outFile}.map`;
    const mapHash = existsSync(mapPath) ? (await sha256OfFile(mapPath)).hash : null;
    results.push({ hash: js.hash, size: js.size, mapHash });
  }

  const first = results[0];
  for (let i = 1; i < results.length; i++) {
    expect(
      results[i].hash,
      `run ${i} bundle.js SHA256 mismatch (size ${first.size}→${results[i].size})`,
    ).toBe(first.hash);
    if (first.mapHash) {
      expect(results[i].mapHash, `run ${i} bundle.js.map SHA256 mismatch`).toBe(first.mapHash);
    }
  }
}

describe('build determinism (#3564)', () => {
  test('small — 5 file ESM, no collisions', async () => {
    await expectDeterministic('small', 'index.js');
  });

  test('name-collision — same export name across 3 modules', async () => {
    await expectDeterministic('name-collision', 'index.js', ['--minify-identifiers']);
  });

  test('dynamic-only — exec_index ties from import() only', async () => {
    await expectDeterministic('dynamic-only', 'index.js');
  });

  test('barrel — export * from chain', async () => {
    await expectDeterministic('barrel', 'index.js');
  });

  test('code-splitting — manualChunks + dynamic', async () => {
    await expectDeterministic('code-splitting', 'index.js', ['--splitting'], 'outdir');
  });
});
