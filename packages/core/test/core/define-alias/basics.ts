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

describe('@zntc/core define/alias > basics', () => {
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
