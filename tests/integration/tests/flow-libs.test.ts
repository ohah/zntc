import { describe, test, expect } from 'bun:test';
import { ZNTC_BIN } from './helpers';
import { join, resolve } from 'node:path';

/**
 * Flow를 적극 사용하는 유명 라이브러리(Metro / Relay / Draft.js)의 실제 소스 파일을
 * --flow --jsx-in-js로 트랜스파일하여 파서 호환성을 추적한다.
 * fixtures/flow-libs/{metro,relay,draft-js}/ 아래의 모든 .js 파일을 자동 수집.
 */

const FIXTURES_ROOT = resolve(import.meta.dir, 'fixtures/flow-libs');

const SKIPPED = new Set<string>([]);

function transpile(file: string): { exitCode: number | null; stderr: string } {
  const proc = Bun.spawnSync([ZNTC_BIN, '--flow', '--jsx-in-js', file]);
  return {
    exitCode: proc.exitCode,
    stderr: proc.stderr.toString(),
  };
}

function expectPass(file: string) {
  const result = transpile(file);
  expect(result.exitCode).toBe(0);
  expect(result.stderr).not.toContain('error:');
}

for (const lib of ['metro', 'relay', 'draft-js'] as const) {
  const libRoot = join(FIXTURES_ROOT, lib);
  const files = Array.from(new Bun.Glob('**/*.js').scanSync(libRoot)).sort();
  describe(`Flow libs: ${lib} (${files.length} files)`, () => {
    for (const rel of files) {
      const full = join(libRoot, rel);
      const key = `${lib}/${rel}`;
      if (SKIPPED.has(key)) {
        test.skip(rel, () => expectPass(full));
      } else {
        test(rel, () => expectPass(full));
      }
    }
  });
}
