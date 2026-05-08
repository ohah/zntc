import { describe, test, expect, build, vitePlugin } from '../helpers';
import { useOutputHookFixture } from './fixture';

describe('renderChunk/generateBundle async/error 훅', () => {
  const fixture = useOutputHookFixture();

  test('async renderChunk', async () => {
    const result = await build({
      entryPoints: [fixture.entryPoint()],
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

  test('async generateBundle', async () => {
    let called = false;
    await build({
      entryPoints: [fixture.entryPoint()],
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
      entryPoints: [fixture.entryPoint()],
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
