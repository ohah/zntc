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

describe('renderChunk/generateBundle 훅', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-chunk-hooks-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('renderChunk: 청크 코드 후처리', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        {
          name: 'chunk-banner',
          setup(build) {
            build.onRenderChunk({ filter: /.*/ }, (args) => {
              return { code: `/* CHUNK: ${args.chunk} */\n${args.code}` };
            });
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* CHUNK:');
    expect(result.outputFiles[0].text).toContain('x = 1');
  });

  test('renderChunk via vitePlugin', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-chunk',
          renderChunk(code) {
            return code.replace('x = 1', 'x = 42');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 42');
  });

  test('async renderChunk', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-chunk',
          async renderChunk(code) {
            await new Promise((r) => setTimeout(r, 5));
            return `/* ASYNC */\n${code}`;
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* ASYNC */');
  });

  test('generateBundle: 번들 완료 콜백', async () => {
    const collected: string[] = [];
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        {
          name: 'bundle-inspector',
          setup(build) {
            build.onGenerateBundle((outputs) => {
              for (const f of outputs) {
                collected.push(f.path);
              }
            });
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(collected.length).toBeGreaterThan(0);
  });

  test('generateBundle via vitePlugin', async () => {
    let called = false;
    await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-generate',
          generateBundle(outputs) {
            called = true;
            expect(outputs.length).toBeGreaterThan(0);
          },
        }),
      ],
    });
    expect(called).toBe(true);
  });

  test('renderChunk 체이닝: 2개 플러그인 순차 적용', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'chunk-step1',
          renderChunk(code) {
            return code.replace('x = 1', 'x = 10');
          },
        }),
        vitePlugin({
          name: 'chunk-step2',
          renderChunk(code) {
            return code.replace('x = 10', 'x = 100');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 100');
    expect(result.outputFiles[0].text).not.toContain('x = 1;');
  });

  test('async generateBundle', async () => {
    let called = false;
    await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-generate',
          async generateBundle(outputs) {
            await new Promise((r) => setTimeout(r, 5));
            called = true;
            expect(outputs.length).toBeGreaterThan(0);
          },
        }),
      ],
    });
    expect(called).toBe(true);
  });

  test('generateBundle: 에러가 throw되어도 빌드 성공', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'error-generate',
          generateBundle() {
            throw new Error('intentional error');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });
});
