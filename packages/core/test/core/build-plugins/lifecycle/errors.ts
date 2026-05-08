import {
  build,
  describe,
  diagText,
  expect,
  expectPluginDiagnostic,
  test,
  writeFileSync,
} from '../helpers';
import type { ZntcPlugin } from '../helpers';
import { useLifecycleFixture } from './fixture';

describe('@zntc/core build + plugins - lifecycle hooks', () => {
  const fixture = useLifecycleFixture();

  test('lifecycle hooks (#2156): plugin error 는 swallow 되고 다른 plugin 차단 안 함', async () => {
    const events: string[] = [];
    const throwingPlugin: ZntcPlugin = {
      name: 'thrower',
      setup(build) {
        const boom = () => {
          throw new Error('intentional');
        };
        build.onBuildEnd(boom);
        build.onCloseBundle(boom);
      },
    };
    const trackingPlugin: ZntcPlugin = {
      name: 'tracker',
      setup(build) {
        build.onBuildStart(() => events.push('start'));
        build.onBuildEnd(() => events.push('end'));
        build.onCloseBundle(() => events.push('close'));
      },
    };

    const result = await build({
      entryPoints: [fixture.path('lifecycle-entry.ts')],
      plugins: [throwingPlugin, trackingPlugin],
    });
    expectPluginDiagnostic(result, {
      plugin: 'thrower',
      hook: 'buildEnd',
      message: 'intentional',
    });
    expectPluginDiagnostic(result, {
      plugin: 'thrower',
      hook: 'closeBundle',
      message: 'intentional',
    });
    expect(events).toEqual(['start', 'end', 'close']);
  });

  test('plugin_error: buildEnd/closeBundle 실패는 기존 build error를 덮지 않고 secondary diagnostic으로 기록', async () => {
    const events: string[] = [];
    writeFileSync(fixture.path('entry-unresolved.ts'), 'import "missing-package-1902";');
    const lifecyclePlugin: ZntcPlugin = {
      name: 'lifecycle-failures',
      setup(build) {
        build.onBuildEnd(() => {
          events.push('buildEnd');
          throw new Error('buildEnd cleanup failed');
        });
        build.onCloseBundle(() => {
          events.push('closeBundle');
          throw new Error('closeBundle cleanup failed');
        });
      },
    };

    const result = await build({
      entryPoints: [fixture.path('entry-unresolved.ts')],
      plugins: [lifecyclePlugin],
    });
    expect(result.errors.some((diag) => diagText(diag).includes('Cannot resolve module'))).toBe(
      true,
    );
    expectPluginDiagnostic(result, {
      plugin: 'lifecycle-failures',
      hook: 'buildEnd',
      message: 'buildEnd cleanup failed',
    });
    expectPluginDiagnostic(result, {
      plugin: 'lifecycle-failures',
      hook: 'closeBundle',
      message: 'closeBundle cleanup failed',
    });
    expect(events).toEqual(['buildEnd', 'closeBundle']);
  });
});
