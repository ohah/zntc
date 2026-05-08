import { describe, test, expect } from '../helpers';
import { captureStderr, loadBuildRnDevServerInput } from './helpers';

describe('buildRnDevServerInput — Metro compatible config 추출 (#2605)', () => {
  test('config.serializer.prelude → bundle.extra.prelude 매핑 (warning 없음)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const { result: input, output } = captureStderr(() =>
      buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        { serializer: { prelude: ['./shims/prelude.js'] } },
      ),
    );
    expect(input?.bundle.extra?.prelude).toEqual(['./shims/prelude.js']);
    expect(output).not.toContain('serializer.prelude');
  });

  test('config.transformer.babel → bundle.extra.babel 매핑 (warning 없음)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const inlineBabel = {
      presets: ['@ohah/react-native-mcp-server/babel-preset'],
      plugins: [['@babel/plugin-proposal-decorators', { legacy: true }] as [string, object]],
    };
    const { result: input, output } = captureStderr(() =>
      buildRnDevServerInput({ entryPoints: ['i.js'] }, { transformer: { babel: inlineBabel } }),
    );
    expect(input?.bundle.extra?.babel).toEqual(inlineBabel);
    expect(output).not.toContain('transformer.babel');
  });

  test('config.serializer.inlineSourceMap → bundle.extra.inlineSourceMap 매핑 (warning 없음, #2605 audit P1)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const { result: input, output } = captureStderr(() =>
      buildRnDevServerInput({ entryPoints: ['i.js'] }, { serializer: { inlineSourceMap: true } }),
    );
    expect(input?.bundle.extra?.inlineSourceMap).toBe(true);
    expect(output).not.toContain('serializer.inlineSourceMap');
  });

  test('config.sourcemapSourcesRoot → bundle.extra.sourceRoot 매핑 (Metro 호환)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { sourcemapSourcesRoot: '/abs/proj' },
    );
    expect(input?.bundle.extra?.sourceRoot).toBe('/abs/proj');
  });

  test('config.server.silentConsoleErrorPatterns → bundle.extra.silentConsoleErrorPatterns 매핑 (Metro 호환, withExpo)', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const { result: input, output } = captureStderr(() =>
      buildRnDevServerInput(
        { entryPoints: ['i.js'] },
        {
          server: {
            silentConsoleErrorPatterns: [
              '^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$',
            ],
          },
        },
      ),
    );
    expect(input?.bundle.extra?.silentConsoleErrorPatterns).toEqual([
      '^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$',
    ]);
    expect(output).not.toContain('server.silentConsoleErrorPatterns');
  });
});
