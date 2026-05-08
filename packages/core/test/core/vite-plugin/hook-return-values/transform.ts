import { afterAll, beforeAll, build, describe, expect, test, vitePlugin } from '../helpers';
import type { RollupPlugin } from '../helpers';
import { createHookReturnFixture, type HookReturnFixture } from './fixture';

describe('vitePlugin 어댑터 - 기본 훅 반환값: transform', () => {
  let fixture: HookReturnFixture;

  beforeAll(() => {
    fixture = createHookReturnFixture();
  });

  afterAll(() => fixture.cleanup());

  test('transform 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-string',
      transform(code, _id) {
        return code.replace('Hello!', 'Transformed!');
      },
    };

    const result = await build({
      entryPoints: [fixture.app],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Transformed!');
  });

  test('transform 훅 — { code } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-object',
      transform(code, _id) {
        return { code: code.replace('Hello!', 'ObjectTransformed!') };
      },
    };

    const result = await build({
      entryPoints: [fixture.app],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ObjectTransformed!');
  });

  test('transform 훅 — null 반환 (통과)', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-null',
      transform() {
        return null;
      },
    };

    const result = await build({
      entryPoints: [fixture.app],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Hello!');
  });
});
