/// #2217 회귀 가드:
/// `zntc file.ts -o out.js --sourcemap` 시 출력 파일에 `//# sourceMappingURL=` footer
/// 부착 + map.file 필드가 *생성된 파일* (not 원본) 가리킴.

import { describe, test, expect, afterEach } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { writeFileSync, readFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runZntc } from './helpers';

describe('#2217: sourcemap footer + map.file 필드', () => {
  let cleanup: (() => void) | undefined;

  afterEach(() => {
    cleanup?.();
    cleanup = undefined;
  });

  function setupFixture(source: string, ext: 'ts' | 'tsx' = 'ts') {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-sm-footer-'));
    const inFile = join(dir, `input.${ext}`);
    const outFile = join(dir, 'out.js');
    writeFileSync(inFile, source);
    cleanup = () => rmSync(dir, { recursive: true, force: true });
    return { dir, inFile, outFile };
  }

  test('footer 부착: //# sourceMappingURL=<basename>.map', async () => {
    const { inFile, outFile } = setupFixture('export const x = 1;\n');
    const r = await runZntc([inFile, '-o', outFile, '--sourcemap']);
    expect(r.exitCode).toBe(0);

    const code = readFileSync(outFile, 'utf-8');
    expect(code).toContain('//# sourceMappingURL=out.js.map');
    expect(existsSync(outFile + '.map')).toBe(true);
  });

  test('map.file 필드는 출력 파일 basename (원본 아님)', async () => {
    const { inFile, outFile } = setupFixture('export const x = 1;\n');
    const r = await runZntc([inFile, '-o', outFile, '--sourcemap']);
    expect(r.exitCode).toBe(0);

    const map = JSON.parse(readFileSync(outFile + '.map', 'utf-8'));
    expect(map.file).toBe('out.js');
    // sources 는 input 파일을 가리킴
    expect(map.sources?.[0]).toMatch(/input\.ts$/);
  });

  test('Node --enable-source-maps 가 stack trace 를 원본 .ts 위치로 매핑', async () => {
    const { inFile, outFile } = setupFixture(
      [
        "function level3() { throw new Error('boom'); }",
        'function level2() { level3(); }',
        'function level1() { level2(); }',
        'try { level1(); } catch (e) { console.log(e.stack); }',
      ].join('\n'),
    );
    const r = await runZntc([inFile, '-o', outFile, '--sourcemap']);
    expect(r.exitCode).toBe(0);

    const node = spawnSync('node', ['--enable-source-maps', outFile], {
      encoding: 'utf-8',
      timeout: 10000,
    });
    expect(node.status).toBe(0);
    // stack trace 의 첫 라인이 *원본 input.ts* 를 가리켜야 (out.js 가 아님).
    expect(node.stdout).toContain('input.ts');
    expect(node.stdout).not.toMatch(/at level3 .*out\.js/);
  });

  test('--sourcemap 없으면 footer 안 부착', async () => {
    const { inFile, outFile } = setupFixture('export const x = 1;\n');
    const r = await runZntc([inFile, '-o', outFile]);
    expect(r.exitCode).toBe(0);

    const code = readFileSync(outFile, 'utf-8');
    expect(code).not.toContain('sourceMappingURL');
    expect(existsSync(outFile + '.map')).toBe(false);
  });

  test('stdout 출력 모드는 footer 안 부착 (output filename 모름)', async () => {
    const { inFile } = setupFixture('export const x = 1;\n');
    const r = await runZntc([inFile, '--sourcemap']);
    expect(r.exitCode).toBe(0);
    // stdout 으로 코드만 출력. footer 안 부착 (어디로 쓰일지 모름).
    expect(r.stdout).not.toContain('sourceMappingURL');
  });
});
