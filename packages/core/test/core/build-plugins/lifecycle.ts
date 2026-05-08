import {
  afterAll,
  beforeAll,
  build,
  describe,
  diagText,
  expect,
  expectPluginDiagnostic,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  vitePlugin,
  writeFileSync,
} from './helpers';
import type { ZntcPlugin } from './helpers';

describe('@zntc/core build + plugins - lifecycle hooks', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-lifecycle-'));
    writeFileSync(join(dir, 'lifecycle-entry.ts'), 'console.log("hi");');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

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
      entryPoints: [join(dir, 'lifecycle-entry.ts')],
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
      entryPoints: [join(dir, 'lifecycle-entry.ts')],
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
    writeFileSync(join(dir, 'entry-unresolved.ts'), 'import "missing-package-1902";');
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
      entryPoints: [join(dir, 'entry-unresolved.ts')],
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
      entryPoints: [join(dir, 'lifecycle-entry.ts')],
      plugins: [rollupAdapter],
    });
    expect(result.errors.length).toBe(0);
    expect(events).toEqual(['rollup-buildStart', 'rollup-buildEnd:ok', 'rollup-closeBundle']);
  });
});
