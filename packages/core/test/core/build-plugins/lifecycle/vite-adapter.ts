import { build, describe, expect, test, vitePlugin } from '../helpers';
import { useLifecycleFixture } from './fixture';

describe('@zntc/core build + plugins - lifecycle hooks', () => {
  const fixture = useLifecycleFixture();

  test('lifecycle hooks (#2156): vitePlugin 어댑터가 buildStart/buildEnd/closeBundle 을 forward', async () => {
    const events: string[] = [];
    const rollupAdapter = vitePlugin({
      name: 'rollup-style',
      buildStart() {
        events.push('rollup-buildStart');
      },
      buildEnd(err) {
        events.push(err ? 'rollup-buildEnd:error' : 'rollup-buildEnd:ok');
      },
      closeBundle() {
        events.push('rollup-closeBundle');
      },
    });

    const result = await build({
      entryPoints: [fixture.path('lifecycle-entry.ts')],
      plugins: [rollupAdapter],
    });
    expect(result.errors.length).toBe(0);
    expect(events).toEqual(['rollup-buildStart', 'rollup-buildEnd:ok', 'rollup-closeBundle']);
  });
});
