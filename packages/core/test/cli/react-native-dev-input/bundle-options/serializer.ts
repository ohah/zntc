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
