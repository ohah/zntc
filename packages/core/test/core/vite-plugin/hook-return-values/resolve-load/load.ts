import {
  afterAll,
  beforeAll,
  build,
  describe,
  expect,
  resolve,
  test,
  vitePlugin,
} from '../../helpers';
import type { RollupPlugin } from '../../helpers';
import { createHookReturnFixture, type HookReturnFixture } from '../fixture';

describe('vitePlugin 어댑터 - 기본 훅 반환값: load', () => {
  let fixture: HookReturnFixture;

  beforeAll(() => {
    fixture = createHookReturnFixture();
  });

  afterAll(() => fixture.cleanup());

  test('load 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-load-string',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(fixture.dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return 'export default "from-string";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [fixture.entry],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('from-string');
  });

  test('load 훅 — { code } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-load-object',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(fixture.dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return { code: 'export default "from-object";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [fixture.entry],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('from-object');
  });
});
