import {
  afterAll,
  beforeAll,
  build,
  buildSync,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  readFileSync,
  removeOptionCombinationFixture,
  rmSync,
  test,
  writeFileSync,
} from './helpers';

describe('옵션 조합 통합 테스트 - core options', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('minify + target + dropLabels 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'app.ts')],
      minify: true,
      target: 'es2020',
      dropLabels: ['DEV'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('debug');
    expect(result.outputFiles[0].text).toContain('42');
  });

  test('sourcemap + sourceRoot + outfile 조합', () => {
    const outfile = join(dir, 'combo-out', 'bundle.js');
    buildSync({
      entryPoints: [join(dir, 'app.ts')],
      sourcemap: true,
      sourceRoot: '/src',
      outfile,
      dropLabels: ['DEV'],
    });
    const map = readFileSync(outfile + '.map', 'utf-8');
    expect(map).toContain('/src');
    expect(map).toContain('mappings');
    rmSync(join(dir, 'combo-out'), { recursive: true, force: true });
  });

  test('loader + packagesExternal 조합', () => {
    writeFileSync(
      join(dir, 'asset-entry.ts'),
      'import logo from "./logo.txt";\nimport React from "react";\nexport { logo, React };',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'asset-entry.ts')],
      loader: { '.txt': 'text' },
      packagesExternal: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('LOGO_TEXT');
    expect(result.outputFiles[0].text).toMatch(/import.*react|require.*react/);
  });

  test('splitting + entryNames + chunkNames 조합', async () => {
    writeFileSync(join(dir, 'dyn-entry.ts'), 'export const lazy = () => import("./lib");');
    const result = await build({
      entryPoints: [join(dir, 'dyn-entry.ts')],
      splitting: true,
      entryNames: '[name]',
      chunkNames: 'chunks/[name]-[hash]',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test('legalComments: none + minify 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'with-license.ts')],
      legalComments: 'none',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('@license');
  });

  test('define + alias + inject 조합', () => {
    writeFileSync(join(dir, 'shim.ts'), 'globalThis.__INJECTED__ = true;');
    writeFileSync(
      join(dir, 'define-entry.ts'),
      'import { foo } from "@alias/mod";\nconsole.log(__DEV__, foo);',
    );
    writeFileSync(join(dir, 'real.ts'), 'export const foo = "real";');
    const result = buildSync({
      entryPoints: [join(dir, 'define-entry.ts')],
      define: { __DEV__: 'false' },
      alias: { '@alias/mod': join(dir, 'real.ts') },
      inject: [join(dir, 'shim.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('false');
    expect(result.outputFiles[0].text).toContain('real');
    expect(result.outputFiles[0].text).toContain('__INJECTED__');
  });

  test('write + outdir + metafile 조합', () => {
    const outdir = join(dir, 'meta-out');
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      outdir,
      metafile: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.metafile).toBeDefined();
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written.length).toBeGreaterThan(0);
    rmSync(outdir, { recursive: true, force: true });
  });

  test('allowOverwrite: false → 입력=출력 시 에러', () => {
    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'lib.ts')],
        outfile: join(dir, 'lib.ts'),
      }),
    ).toThrow('overwrite');
  });

  test('allowOverwrite: true → 입력=출력 허용', () => {
    const outfile = join(dir, 'overwrite-test.ts');
    writeFileSync(outfile, 'export const z = 1;');
    const result = buildSync({
      entryPoints: [outfile],
      outfile,
      allowOverwrite: true,
    });
    expect(result.errors.length).toBe(0);
    rmSync(outfile, { force: true });
  });
});
