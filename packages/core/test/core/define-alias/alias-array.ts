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

describe('@zntc/core define/alias > alias array', () => {
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
});
