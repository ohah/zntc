import {
  describe,
  test,
  expect,
  watch,
  vitePlugin,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';
import type { RollupPlugin, ZntcPlugin } from './helpers';

describe('watch() > basic lifecycle', () => {
  test('초기 빌드 후 onReady 콜백 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise, resolve: done } = Promise.withResolvers<{ files: number; bytes: number }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady(event) {
        done(event);
      },
    });

    const event = await promise;
    expect(event.files).toBeGreaterThan(0);
    expect(event.bytes).toBeGreaterThan(0);
    handle.stop();
    rmSync(dir, { recursive: true });
  });

  test('파일 변경 시 onRebuild 콜백 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      success: boolean;
      bytes?: number;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    // 파일 수정 (mtime polling 500ms 대기)
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

    const event = await rebuildP;
    expect(event.success).toBe(true);
    expect(event.bytes).toBeGreaterThan(0);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('plugin lifecycle hooks: 초기 build 와 rebuild 마다 buildStart → buildEnd → callback → closeBundle 순서', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle',
      setup(build) {
        build.onBuildStart(() => {
          events.push('buildStart');
        });
        build.onBuildEnd((err) => {
          events.push(err ? `buildEnd:${err.message}` : 'buildEnd');
        });
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
        onReady() {
          events.push('onReady');
        },
        onRebuild(event) {
          events.push(`onRebuild:${event.success ? 'ok' : 'err'}`);
        },
      });

      await initialCloseP;
      expect(events).toEqual(['buildStart', 'buildEnd', 'onReady', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'onReady',
        'closeBundle',
        'buildStart',
        'buildEnd',
        'onRebuild:ok',
        'closeBundle',
      ]);
      expect(events.filter((event) => event === 'buildStart').length).toBe(2);
      expect(events.filter((event) => event === 'buildEnd').length).toBe(2);
      expect(events.filter((event) => event === 'closeBundle').length).toBe(2);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('vitePlugin watch lifecycle: Rollup buildStart / buildEnd / closeBundle 을 초기 build 와 rebuild 에서 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-vite-lifecycle-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const rollupPlugin: RollupPlugin = {
      name: 'rollup-watch-lifecycle',
      buildStart() {
        events.push('rollup-buildStart');
      },
      buildEnd(err) {
        events.push(err ? `rollup-buildEnd:${err.message}` : 'rollup-buildEnd');
      },
      closeBundle() {
        events.push('rollup-closeBundle');
        closeCount++;
        if (closeCount === 1) initialCloseDone();
        if (closeCount === 2) rebuildCloseDone();
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [vitePlugin(rollupPlugin)],
        onReady() {
          events.push('onReady');
        },
        onRebuild(event) {
          events.push(`onRebuild:${event.success ? 'ok' : 'err'}`);
        },
      });

      await initialCloseP;
      expect(events).toEqual([
        'rollup-buildStart',
        'rollup-buildEnd',
        'onReady',
        'rollup-closeBundle',
      ]);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'rollup-buildStart',
        'rollup-buildEnd',
        'onReady',
        'rollup-closeBundle',
        'rollup-buildStart',
        'rollup-buildEnd',
        'onRebuild:ok',
        'rollup-closeBundle',
      ]);
      expect(events.filter((event) => event === 'rollup-buildStart').length).toBe(2);
      expect(events.filter((event) => event === 'rollup-buildEnd').length).toBe(2);
      expect(events.filter((event) => event === 'rollup-closeBundle').length).toBe(2);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('plugin lifecycle hooks: watch 사용자 콜백 실패 후에도 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-error-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-error',
      setup(build) {
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
        onReady() {
          events.push('onReady');
          throw new Error('ready failed');
        },
        async onRebuild() {
          events.push('onRebuild');
          throw new Error('rebuild failed');
        },
      });

      await initialCloseP;
      expect(events).toEqual(['onReady', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual(['onReady', 'closeBundle', 'onRebuild', 'closeBundle']);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('plugin lifecycle hooks: watch 사용자 콜백이 없어도 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-no-callback-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-no-callback',
      setup(build) {
        build.onBuildStart(() => events.push('buildStart'));
        build.onBuildEnd(() => events.push('buildEnd'));
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
      });

      await initialCloseP;
      expect(events).toEqual(['buildStart', 'buildEnd', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'closeBundle',
        'buildStart',
        'buildEnd',
        'closeBundle',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('plugin lifecycle hooks: watch rebuild diagnostic 은 buildEnd error 후 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-diagnostic-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-diagnostic',
      setup(build) {
        build.onBuildStart(() => events.push('buildStart'));
        build.onBuildEnd((err) => {
          events.push(err ? 'buildEnd:error' : 'buildEnd');
        });
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
        onReady() {
          events.push('onReady');
        },
        onRebuild(event) {
          events.push(`onRebuild:${event.success ? 'ok' : 'err'}`);
        },
      });

      await initialCloseP;
      expect(events).toEqual(['buildStart', 'buildEnd', 'onReady', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), "import value from './missing';\nconsole.log(value);");

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'onReady',
        'closeBundle',
        'buildStart',
        'buildEnd:error',
        'onRebuild:ok',
        'closeBundle',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('plugin lifecycle hooks: watch closeBundle throw 는 다른 plugin 과 watch 를 막지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-close-throw-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let trackingCloseCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const throwingPlugin: ZntcPlugin = {
      name: 'watch-close-thrower',
      setup(build) {
        build.onCloseBundle(() => {
          events.push('throwing-close');
          throw new Error('close failed');
        });
      },
    };
    const trackingPlugin: ZntcPlugin = {
      name: 'watch-close-tracker',
      setup(build) {
        build.onCloseBundle(() => {
          events.push('tracking-close');
          trackingCloseCount++;
          if (trackingCloseCount === 1) initialCloseDone();
          if (trackingCloseCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [throwingPlugin, trackingPlugin],
      });

      await initialCloseP;
      expect(events).toEqual(['throwing-close', 'tracking-close']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'throwing-close',
        'tracking-close',
        'throwing-close',
        'tracking-close',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);
});
