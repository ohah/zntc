import { build, describe, expect, test } from '../helpers';
import type { ZntcPlugin } from '../helpers';
import { useLifecycleFixture } from './fixture';

describe('@zntc/core build + plugins - lifecycle hooks', () => {
  const fixture = useLifecycleFixture();

  test('lifecycle hooks (#2156): buildStart → buildEnd → closeBundle 순서 + 1회씩', async () => {
    const events: string[] = [];
    const lifecyclePlugin: ZntcPlugin = {
      name: 'lifecycle-tracker',
      setup(build) {
        build.onBuildStart(() => events.push('buildStart'));
        build.onBuildEnd((err) => events.push(err ? 'buildEnd:error' : 'buildEnd:ok'));
        build.onCloseBundle(() => events.push('closeBundle'));
        build.onTransform({ filter: /lifecycle-entry\.ts$/ }, () => {
          events.push('transform');
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [fixture.path('lifecycle-entry.ts')],
      plugins: [lifecyclePlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(events[0]).toBe('buildStart');
    expect(events.indexOf('transform')).toBeGreaterThan(0);
    expect(events).toContain('buildEnd:ok');
    expect(events[events.length - 1]).toBe('closeBundle');
    expect(events.filter((e) => e === 'buildStart').length).toBe(1);
    expect(events.filter((e) => e.startsWith('buildEnd')).length).toBe(1);
    expect(events.filter((e) => e === 'closeBundle').length).toBe(1);
  });
});
