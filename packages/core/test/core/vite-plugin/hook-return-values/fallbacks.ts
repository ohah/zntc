import { afterAll, beforeAll, build, describe, expect, test, vitePlugin } from '../helpers';
import type { RollupPlugin } from '../helpers';
import { createHookReturnFixture, type HookReturnFixture } from './fixture';

describe('vitePlugin 어댑터 - 기본 훅 반환값: fallbacks', () => {
  let fixture: HookReturnFixture;

  beforeAll(() => {
    fixture = createHookReturnFixture();
  });

  afterAll(() => fixture.cleanup());

  test('resolveId에서 undefined/void 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'void-return',
      resolveId() {
        // void — 아무것도 반환하지 않음
      },
    };
    const result = await build({
      entryPoints: [fixture.app],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
  });
});
