import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  vitePlugin,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('vitePlugin async 훅 지원', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-async-plugin-'));
    writeFileSync(join(dir, 'entry.ts'), 'import val from "./data.custom";\nconsole.log(val);');
    writeFileSync(join(dir, 'data.custom'), 'CUSTOM_DATA');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('async load 훅', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-loader',
          async load(id) {
            if (id.endsWith('.custom')) {
              await new Promise((r) => setTimeout(r, 10));
              return { code: 'export default "ASYNC_LOADED";' };
            }
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ASYNC_LOADED');
  });

  test('async resolveId 훅', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-resolver',
          async resolveId(source) {
            if (source.endsWith('.custom')) {
              await new Promise((r) => setTimeout(r, 10));
              return join(dir, 'data.custom');
            }
          },
          load(id) {
            if (id.endsWith('.custom')) {
              return { code: 'export default "RESOLVED";' };
            }
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('RESOLVED');
  });

  test('async transform 훅', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-transformer',
          async transform(code, id) {
            if (id.endsWith('.ts')) {
              await new Promise((r) => setTimeout(r, 10));
              return code.replace('console.log', 'console.info');
            }
          },
        }),
        vitePlugin({
          name: 'custom-loader',
          load(id) {
            if (id.endsWith('.custom')) return { code: 'export default "X";' };
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('console.info');
    expect(result.outputFiles[0].text).not.toContain('console.log');
  });

  test('동기 + 비동기 훅 혼합', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'sync-plugin',
          load(id) {
            if (id.endsWith('.custom')) return { code: 'export default "SYNC";' };
          },
        }),
        vitePlugin({
          name: 'async-plugin',
          async transform(code) {
            await new Promise((r) => setTimeout(r, 5));
            return code.replace('console.log', 'console.warn');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('SYNC');
    expect(result.outputFiles[0].text).toContain('console.warn');
  });
});

// ─── renderChunk/generateBundle 훅 테스트 (#1004) ───
