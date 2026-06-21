import {
  describe,
  test,
  expect,
  transpile,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core ES2023/hashbang', () => {
  test('target es5: hashbang은 보존됨 (shebang 은 다운레벨 대상 아님)', () => {
    const result = transpile("#!/usr/bin/env node\nconsole.log('hello');", {
      target: 'es5',
    });
    // hashbang(#!)은 런타임(Node)이 스크립트 실행에 쓰는 shebang 이라 어떤 target 으로
    // 다운레벨해도 strip 하지 않는다 — 본문만 다운레벨된다.
    expect(result.code).toContain('#!/usr/bin/env node');
    expect(result.code).toContain('hello');
  });

  test('target es2022: hashbang은 보존됨 (shebang 은 target 무관 유지)', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      target: 'es2022',
    });
    expect(result.code).toContain('#!/usr/bin/env node');
    expect(result.code).toContain('x = 1');
  });

  test('target es2023: hashbang이 유지됨', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      target: 'es2023',
    });
    expect(result.code).toContain('#!/usr/bin/env node');
    expect(result.code).toContain('x = 1');
  });

  test('target esnext: hashbang이 유지됨', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      target: 'esnext',
    });
    expect(result.code).toContain('#!/usr/bin/env node');
  });

  test('hashbang 없는 파일에서 es2022 타겟 — 정상 동작', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts', target: 'es2022' });
    expect(result.code).toContain('const x = 1');
  });

  test('target 미지정: hashbang이 유지됨 (기본 esnext)', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;');
    expect(result.code).toContain('#!/usr/bin/env node');
  });

  test('es2023 타겟 번들링', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es2023-build-'));
    writeFileSync(join(dir, 'index.ts'), '#!/usr/bin/env node\nconsole.log(1);');
    // buildSync에 target 옵션이 없으므로 transpile로 테스트
    const result = transpile(readFileSync(join(dir, 'index.ts'), 'utf8'), {
      target: 'es2023',
    });
    expect(result.code).toContain('#!/usr/bin/env node');
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── define/alias 옵션 ───
