import {
  describe,
  test,
  expect,
  transpile,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('tsconfigPath', () => {
  test('tsconfigPath=<file>: verbatimModuleSyntax 가 적용되어 미사용 import 보존', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-file-'));
    writeFileSync(join(dir, 'tsconfig.json'), '{"compilerOptions":{"verbatimModuleSyntax":true}}');
    const r = transpile('import { foo } from "./bar";', {
      filename: 'input.ts',
      tsconfigPath: join(dir, 'tsconfig.json'),
    });
    expect(r.code).toContain('import { foo } from "./bar"');
    rmSync(dir, { recursive: true });
  });

  test('tsconfigPath=<dir>: 디렉토리 내 tsconfig.json 자동 탐지', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-dir-'));
    writeFileSync(join(dir, 'tsconfig.json'), '{"compilerOptions":{"verbatimModuleSyntax":true}}');
    const r = transpile('import { foo } from "./bar";', {
      filename: 'input.ts',
      tsconfigPath: dir,
    });
    expect(r.code).toContain('import { foo } from "./bar"');
    rmSync(dir, { recursive: true });
  });

  test('JS 옵션이 tsconfig 보다 우선 — 명시적 false 로 tsconfig true override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-prio-'));
    writeFileSync(join(dir, 'tsconfig.json'), '{"compilerOptions":{"verbatimModuleSyntax":true}}');
    const r = transpile('import { foo } from "./bar";', {
      filename: 'input.ts',
      tsconfigPath: dir,
      verbatimModuleSyntax: false,
    });
    expect(r.code).toBe('');
    rmSync(dir, { recursive: true });
  });

  test('tsconfigPath 없으면 기본 동작 (elide)', () => {
    const r = transpile('import { foo } from "./bar";', { filename: 'input.ts' });
    expect(r.code).toBe('');
  });

  test('build API 도 tsconfigPath 옵션을 받음 (no-throw)', () => {
    // 참고: build 의 verbatim 은 tree-shaker 와 상호작용하므로 표면 효과는 번들 구성에 따라
    // 다르다 — 여기서는 옵션 통과 경로만 검증 (no throw + 출력 생성).
    const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-build-'));
    writeFileSync(join(dir, 'tsconfig.json'), '{"compilerOptions":{"verbatimModuleSyntax":true}}');
    writeFileSync(join(dir, 'entry.ts'), 'console.log(42);');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      tsconfigPath: join(dir, 'tsconfig.json'),
    });
    expect(r.outputFiles[0].text).toContain('console.log(42)');
    rmSync(dir, { recursive: true });
  });
});
