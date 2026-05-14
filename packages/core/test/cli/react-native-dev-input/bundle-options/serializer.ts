import { describe, expect, test } from '../../helpers';
import { loadBuildRnDevServerInput } from '../helpers';

describe('buildRnDevServerInput — serializer bundle option config 추출 (#2605)', () => {
  test('config.serializer.polyfills → bundle.extra.polyfills 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { serializer: { polyfills: ['./shims/myPolyfill.js'] } },
    );
    expect(input?.bundle.extra?.polyfills).toEqual(['./shims/myPolyfill.js']);
  });

  test('config.serializer.getPolyfills → Metro signature 로 bundle.extra.polyfills 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'], rnPlatform: 'android' },
      {
        serializer: {
          getPolyfills: ({ platform }: { platform: string }) => [`./shims/${platform}.js`],
        },
      },
    );
    expect(input?.bundle.extra?.polyfills).toEqual(['./shims/android.js']);
  });

  test('config.serializer.getPolyfills + polyfillModuleNames + polyfills 순서 보존', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      {
        serializer: {
          getPolyfills: () => ['./shims/from-getPolyfills.js'],
          polyfillModuleNames: ['./shims/from-polyfillModuleNames.js'],
          polyfills: ['./shims/from-polyfills.js'],
        },
      },
    );
    expect(input?.bundle.extra?.polyfills).toEqual([
      './shims/from-getPolyfills.js',
      './shims/from-polyfillModuleNames.js',
      './shims/from-polyfills.js',
    ]);
  });

  test('config.serializer.extraVars → bundle.extra.extraVars 매핑', async () => {
    const buildRnDevServerInput = await loadBuildRnDevServerInput();
    const input = buildRnDevServerInput(
      { entryPoints: ['i.js'] },
      { serializer: { extraVars: { __APP_VERSION__: '1.0.0', __FLAG__: true } } },
    );
    expect(input?.bundle.extra?.extraVars).toEqual({
      __APP_VERSION__: '1.0.0',
      __FLAG__: true,
    });
  });
});
