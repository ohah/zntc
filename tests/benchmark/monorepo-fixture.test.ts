import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, test } from 'bun:test';
import { makeSyntheticMonorepo, parseProfileOutput } from './monorepo-fixture';

describe('monorepo benchmark fixture', () => {
  test('workspace package graph를 결정론적으로 생성한다', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zts-monorepo-fixture-test-'));
    try {
      const fixture = makeSyntheticMonorepo(dir, { packageCount: 3, modulesPerPackage: 4 });

      expect(fixture.moduleCount).toBe(16);
      expect(fixture.packages).toEqual([
        '@zts-fixture/pkg-0',
        '@zts-fixture/pkg-1',
        '@zts-fixture/pkg-2',
      ]);
      expect(readFileSync(fixture.entry, 'utf8')).toContain(
        'import { pkgValue as pkg2 } from "@zts-fixture/pkg-2";',
      );
      expect(readFileSync(join(dir, 'packages', 'pkg-2', 'src', 'mod-0.ts'), 'utf8')).toContain(
        'from "@zts-fixture/pkg-1"',
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('profile text에서 dotted phase 이름까지 파싱한다', () => {
    const parsed = parseProfileOutput(
      'total                              123.456ms  100.00%\n' +
        'graph.discover.scan.worker         30.000ms   24.30%\n' +
        'link                               10.500ms    8.50%\n',
    );

    expect(parsed.totalMs).toBe(123.456);
    expect(parsed.phases['graph.discover.scan.worker']).toBe(30);
    expect(parsed.phases.link).toBe(10.5);
  });
});
