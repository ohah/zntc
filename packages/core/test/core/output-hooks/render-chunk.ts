import { describe, test, expect, build, vitePlugin } from '../helpers';
import { useOutputHookFixture } from './fixture';

describe('renderChunk 훅', () => {
  const fixture = useOutputHookFixture();

  test('renderChunk: 청크 코드 후처리', async () => {
    const result = await build({
      entryPoints: [fixture.entryPoint()],
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
      entryPoints: [fixture.entryPoint()],
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

  test('renderChunk 체이닝: 2개 플러그인 순차 적용', async () => {
    const result = await build({
      entryPoints: [fixture.entryPoint()],
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
});
