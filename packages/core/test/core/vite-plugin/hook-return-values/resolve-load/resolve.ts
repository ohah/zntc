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

describe('vitePlugin 어댑터 - 기본 훅 반환값: resolve', () => {
  let fixture: HookReturnFixture;

  beforeAll(() => {
    fixture = createHookReturnFixture();
  });

  afterAll(() => fixture.cleanup());

  test('resolveId 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-resolve-string',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(fixture.dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return 'export default "red";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [fixture.entry],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('red');
  });

  test('resolveId 훅 — { id } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-resolve-object',
      resolveId(source) {
        if (source.endsWith('.css')) return { id: resolve(fixture.dir, source) };
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return { code: 'export default "blue";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [fixture.entry],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('blue');
  });
});
