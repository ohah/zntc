/// Build determinism gate (#3564) — 같은 입력으로 N=10회 빌드 → bundle byte-identical.
/// 모든 케이스 `.skip` 으로 시작; 후속 PR 가 각자의 hotspot 을 fix 한 뒤 하나씩 활성화.

import { afterAll, describe, test, expect } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { runZntc, sha256OfFile } from './helpers';

const FIXTURE_ROOT = resolve(import.meta.dir, 'fixtures/determinism');
const REPEAT_COUNT = 10;

const tmpRoots: string[] = [];
afterAll(async () => {
  await Promise.all(tmpRoots.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function expectDeterministic(
  fixtureName: string,
  entryFile: string,
  extraArgs: string[] = [],
): Promise<void> {
  const fixtureDir = join(FIXTURE_ROOT, fixtureName);
  const tmpRoot = await mkdtemp(join(tmpdir(), `zntc-determinism-${fixtureName}-`));
  tmpRoots.push(tmpRoot);

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

  test.skip('dynamic-only — exec_index ties from import() only', async () => {
    await expectDeterministic('dynamic-only', 'index.js');
  });

  test.skip('barrel — export * from chain', async () => {
    await expectDeterministic('barrel', 'index.js');
  });

  test.skip('code-splitting — manualChunks + dynamic', async () => {
    await expectDeterministic('code-splitting', 'index.js', ['--code-splitting']);
  });
});
