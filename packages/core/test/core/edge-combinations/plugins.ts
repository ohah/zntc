import { afterAll, beforeAll, build, describe, expect, test, vitePlugin } from '../helpers';
import { createEdgeCombinationFixture, type EdgeCombinationFixture } from './fixture';

describe('엣지 케이스 + 조합 보강: plugins', () => {
  let fixture: EdgeCombinationFixture;

  beforeAll(() => {
    fixture = createEdgeCombinationFixture();
  });

  afterAll(() => fixture.cleanup());

  test('플러그인 onTransform + target', async () => {
    const result = await build({
      entryPoints: [fixture.hasConsole],
      target: 'es2020',
      plugins: [
        vitePlugin({
          name: 'replacer',
          transform(code) {
            return code.replace('hello', 'TRANSFORMED');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('TRANSFORMED');
  });

  test('플러그인 renderChunk + format: umd', async () => {
    const result = await build({
      entryPoints: [fixture.simple],
      format: 'umd',
      globalName: 'T',
      plugins: [
        vitePlugin({
          name: 'chunk-stamp',
          renderChunk(code) {
            return `/* stamped */\n${code}`;
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* stamped */');
    expect(result.outputFiles[0].text).toContain('typeof define');
  });
});
