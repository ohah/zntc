import {
  afterAll,
  beforeAll,
  build,
  describe,
  expect,
  resolve,
  test,
  vitePlugin,
} from '../helpers';
import type { RollupPlugin, ZntcPlugin } from '../helpers';
import { createHookReturnFixture, type HookReturnFixture } from './fixture';

describe('vitePlugin 어댑터 - 기본 훅 반환값: composition', () => {
  let fixture: HookReturnFixture;

  beforeAll(() => {
    fixture = createHookReturnFixture();
  });

  afterAll(() => fixture.cleanup());

  test('여러 Rollup 플러그인 조합', async () => {
    const resolverPlugin: RollupPlugin = {
      name: 'resolver',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(fixture.dir, source);
        return null;
      },
    };

    const loaderPlugin: RollupPlugin = {
      name: 'loader',
      load(id) {
        if (id.endsWith('.css')) return 'export default "multi-plugin";';
        return null;
      },
    };

    const transformerPlugin: RollupPlugin = {
      name: 'transformer',
      transform(code, _id) {
        return code.replace('multi-plugin', 'MULTI-TRANSFORMED');
      },
    };

    const result = await build({
      entryPoints: [fixture.entry],
      plugins: [
        vitePlugin(resolverPlugin),
        vitePlugin(loaderPlugin),
        vitePlugin(transformerPlugin),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('MULTI-TRANSFORMED');
  });

  test('ZNTC 플러그인과 Vite 플러그인 혼합', async () => {
    const nativePlugin: ZntcPlugin = {
      name: 'native-resolve',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(fixture.dir, args.path),
        }));
      },
    };

    const rollupLoader: RollupPlugin = {
      name: 'rollup-loader',
      load(id) {
        if (id.endsWith('.css')) return 'export default "mixed";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [fixture.entry],
      plugins: [nativePlugin, vitePlugin(rollupLoader)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('mixed');
  });

  test('훅이 없는 빈 Rollup 플러그인', async () => {
    const emptyPlugin: RollupPlugin = { name: 'empty' };
    const result = await build({
      entryPoints: [fixture.app],
      plugins: [vitePlugin(emptyPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Hello!');
  });
});
