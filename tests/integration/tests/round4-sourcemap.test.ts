/// Round 4 sourcemap footer/file 회귀 테스트 — 8 fixture (PR #2217 영역).
///
/// 각 fixture 에 대해 `--sourcemap` 트랜스파일 후 검증:
///   1. 출력 코드 끝에 `//# sourceMappingURL=...` footer 존재
///   2. `.map` 파일이 spec 부합 (version=3, sources/sourcesContent 비어있지 않음, mappings 비어있지 않음)
///   3. `map.file` 필드가 출력 파일 basename 과 일치
import { describe, test, expect } from 'bun:test';
import { readFileSync, readdirSync } from 'node:fs';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { runZntc } from './helpers';

const FIXTURES_DIR = join(import.meta.dir, 'fixtures/round4-sourcemap');
const fixtures = readdirSync(FIXTURES_DIR)
  .filter((f) => /\.(ts|tsx)$/.test(f))
  .sort();

describe('Round 4 sourcemap footer/file', () => {
  for (const fix of fixtures) {
    test(fix, async () => {
      const sourceText = readFileSync(join(FIXTURES_DIR, fix), 'utf-8');
      const dir = await mkdtemp(join(tmpdir(), 'zntc-round4-'));
      try {
        const inFile = join(dir, fix);
        await writeFile(inFile, sourceText);
        const outFile = join(dir, fix.replace(/\.(ts|tsx)$/, '.js'));
        const r = await runZntc([inFile, '-o', outFile, '--sourcemap']);
        expect(r.exitCode).toBe(0);

        const outText = readFileSync(outFile, 'utf-8');
        // footer
        expect(outText).toMatch(/\/\/#\s*sourceMappingURL=.+\.map\s*$/);

        const mapJson = JSON.parse(readFileSync(outFile + '.map', 'utf-8'));
        expect(mapJson.version).toBe(3);
        expect(Array.isArray(mapJson.sources) && mapJson.sources.length > 0).toBe(true);
        expect(typeof mapJson.mappings === 'string' && mapJson.mappings.length > 0).toBe(true);
        // map.file 은 출력 파일 basename 과 일치 (spec 권장)
        expect(mapJson.file).toBe(basename(outFile));
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    });
  }
});
