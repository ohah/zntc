import {
  describe,
  test,
  expect,
  build,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core define/alias', () => {
  test('define: 글로벌 상수 치환', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-define-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'console.log(process.env.NODE_ENV);\nconsole.log(__DEV__);',
    );

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      define: {
        'process.env.NODE_ENV': '"production"',
        __DEV__: 'false',
      },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('production');
    expect(result.outputFiles[0].text).toContain('false');
    expect(result.outputFiles[0].text).not.toContain('process.env.NODE_ENV');
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias: import 경로 치환', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-'));
    writeFileSync(join(dir, 'real.ts'), 'export const x = 42;');
    writeFileSync(join(dir, 'index.ts'), 'import { x } from "@alias/mod";\nconsole.log(x);');

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      alias: { '@alias/mod': join(dir, 'real.ts') },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('42');
    rmSync(dir, { recursive: true, force: true });
  });

  // ─── #2153 array-form alias (Vite 식 RegExp / 함수형 find) ──────────────────
  test('alias array: string find — exact 매칭', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-string-'));
    writeFileSync(join(dir, 'real.ts'), 'export const x = "ALIAS_ARRAY_STRING_VALUE";');
    writeFileSync(join(dir, 'index.ts'), 'import { x } from "virtual";\nconsole.log(x);');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      alias: [{ find: 'virtual', replacement: join(dir, 'real.ts') }],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_ARRAY_STRING_VALUE');
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias array: RegExp find — capture group 치환 ($1)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-regex-'));
    writeFileSync(join(dir, 'components.ts'), 'export const Btn = "ALIAS_REGEX_BTN";');
    writeFileSync(join(dir, 'index.ts'), 'import { Btn } from "@/components";\nconsole.log(Btn);');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      // `@/components` → `<dir>/components` (디렉토리는 index 자동 또는 .ts 추가 — 여기선 정확 path 매핑).
      alias: [{ find: /^@\/(.*)$/, replacement: join(dir, '$1.ts') }],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_REGEX_BTN');
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias array: 매칭 순서 — 첫번째 매치 적용', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-order-'));
    writeFileSync(join(dir, 'first.ts'), 'export const v = "ALIAS_FIRST_MATCH";');
    writeFileSync(join(dir, 'second.ts'), 'export const v = "ALIAS_SECOND_MATCH";');
    writeFileSync(join(dir, 'index.ts'), 'import { v } from "shared";\nconsole.log(v);');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      alias: [
        { find: 'shared', replacement: join(dir, 'first.ts') },
        { find: 'shared', replacement: join(dir, 'second.ts') },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_FIRST_MATCH');
    expect(result.outputFiles[0].text).not.toContain('ALIAS_SECOND_MATCH');
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias array: RegExp `g` flag 도 매 import 안전 적용 (lastIndex 부작용 없음)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-gflag-'));
    writeFileSync(join(dir, 'a.ts'), 'export const a = "ALIAS_GFLAG_A";');
    writeFileSync(join(dir, 'b.ts'), 'export const b = "ALIAS_GFLAG_B";');
    writeFileSync(
      join(dir, 'index.ts'),
      'import { a } from "@/a";\nimport { b } from "@/b";\nconsole.log(a, b);',
    );

    // `g` flag — find.test() 패턴이었다면 두 번째 호출에서 lastIndex 부작용으로 false 반환.
    // String.prototype.search 는 g flag 무시하므로 두 import 모두 매칭되어야 함.
    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      alias: [{ find: /^@\/(.*)$/g, replacement: join(dir, '$1.ts') }],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_GFLAG_A');
    expect(result.outputFiles[0].text).toContain('ALIAS_GFLAG_B');
    rmSync(dir, { recursive: true, force: true });
  });

  // ─── #2159 outputExports — Rollup output.exports 호환 ─────────────────────
  test("outputExports='auto' default-only → module.exports = X", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-default-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "AUTO_DEFAULT_ONLY";\nexport default x;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'auto',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('module.exports = ');
    expect(text).not.toContain('__esModule');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='auto' named-only → exports.X = X (no esModule flag)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-named-'));
    writeFileSync(join(dir, 'index.ts'), 'export const a = 1;\nexport const b = "AUTO_NAMED";');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'auto',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('exports.a = ');
    expect(text).toContain('exports.b = ');
    expect(text).not.toContain('__esModule');
    expect(text).not.toContain('module.exports = ');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='auto' mixed → exports.X + esModule flag", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-mixed-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'export const a = "AUTO_MIXED_NAMED";\nexport default { x: "AUTO_MIXED_DEFAULT" };',
    );

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'auto',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('exports.a = ');
    expect(text).toContain('exports.default = ');
    expect(text).toContain('__esModule');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='named' default-only → exports.default + esModule flag", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-named-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "NAMED_DEFAULT";\nexport default x;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'named',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('exports.default = ');
    expect(text).toContain('__esModule');
    expect(text).not.toContain('module.exports = ');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='default' default-only → module.exports = X", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-default-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "DEFAULT_MODE";\nexport default x;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'default',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('module.exports = ');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='default' + named 섞이면 result.errors 에 명시 진단", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-conflict-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'export const a = 1;\nexport default { x: "ALSO_HAS_DEFAULT" };',
    );

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'default',
    });
    // graph diagnostic 으로 emit — std.log.warn 임시방편 X.
    expect(result.errors.length).toBeGreaterThan(0);
    const errMsg = result.errors[0].text;
    expect(errMsg).toContain('output.exports');
    expect(errMsg).toContain('default-only');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='none' → 모든 export 출력 안 함", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-none-'));
    writeFileSync(join(dir, 'index.ts'), 'export const a = 1;\nexport default { x: 2 };');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'none',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).not.toContain('module.exports = ');
    expect(text).not.toContain('exports.a');
    expect(text).not.toContain('exports.default');
    rmSync(dir, { recursive: true, force: true });
  });

  // ─── #2158 logLevel / logLimit NAPI 필터링 ─────────────────────────────────
  // unresolved import 은 ZNTC 에서 errors 로 분류 (worker / optional 만 warnings).
  // 따라서 errors 검증 위주로 logLevel/logLimit 동작 확인.

  test("logLevel='silent': errors 도 빈 배열 (build 객체로만 결과 확인)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglevel-silent-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import * as r from "unresolved-pkg-zzz";\nconsole.log(r);',
    );

    const baseline = await build({ entryPoints: [join(dir, 'index.ts')] });
    expect(baseline.errors.length).toBeGreaterThan(0);

    const silent = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLevel: 'silent',
    });
    expect(silent.errors).toEqual([]);
    expect(silent.warnings).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });

  test("logLevel='warning' (default): errors 그대로 보존", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglevel-warning-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import * as r from "unresolved-pkg-yyy";\nconsole.log(r);',
    );

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLevel: 'warning',
    });
    expect(result.errors.length).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('logLimit=1: errors 가 여러 개여도 1개로 truncate', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglimit-'));
    writeFileSync(
      join(dir, 'index.ts'),
      [
        'import * as a from "unresolved-pkg-aaa";',
        'import * as b from "unresolved-pkg-bbb";',
        'import * as c from "unresolved-pkg-ccc";',
        'console.log(a, b, c);',
      ].join('\n'),
    );

    const baseline = await build({ entryPoints: [join(dir, 'index.ts')] });
    expect(baseline.errors.length).toBeGreaterThan(1);

    const limited = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLimit: 1,
    });
    expect(limited.errors.length).toBe(1);
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias array: buildSync 에서 sync dispatcher로 동작', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-sync-'));
    writeFileSync(join(dir, 'index.ts'), 'import { msg } from "@/aliased";\nconsole.log(msg);');
    writeFileSync(join(dir, 'aliased.ts'), 'export const msg = "ALIAS_ARRAY_SYNC";');

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      alias: [{ find: /^@\/(.*)$/, replacement: join(dir, '$1.ts') }],
    });

    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_ARRAY_SYNC');
    rmSync(dir, { recursive: true, force: true });
  });

  test('define: async build에서도 동작', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-define-async-'));
    writeFileSync(join(dir, 'index.ts'), 'console.log(VERSION);');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      define: { VERSION: '"1.0.0"' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('1.0.0');
    rmSync(dir, { recursive: true, force: true });
  });

  test('빈 define/alias 객체 → 무시', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-empty-define-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      define: {},
      alias: {},
    });
    expect(result.errors.length).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── Vite/Rollup 플러그인 어댑터 ───
