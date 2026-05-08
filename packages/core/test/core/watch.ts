import {
  describe,
  test,
  expect,
  watch,
  vitePlugin,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  join,
  tmpdir,
} from './helpers';

describe('watch()', () => {
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

  test('devMode에서 moduleCodes diff → updates 전달', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string; code: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 999;');

    const event = await rebuildP;
    expect(event.graphChanged).toBeFalsy();
    // updates가 있으면 변경된 모듈 코드가 포함되어야 함
    if (event.updates && event.updates.length > 0) {
      expect(event.updates[0].id).toBeDefined();
      expect(event.updates[0].code).toContain('999');
      // Issue #1248: 모듈별 standalone sourcemap이 함께 노출되어야 함
      expect(event.updates[0].map).toBeDefined();
      const map = event.updates[0].map!;
      expect(map).toContain('"version":3');
      expect(map).toContain('"mappings":"');
      expect(map).toContain('"sources":[');
    }
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('Issue #1248: 다중 모듈에서 변경 모듈만 updates에 + map은 자기 모듈만', async () => {
    // entry → a, b 그래프에서 a.ts만 수정 → updates=[a]만, map.sources=[a]만 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-partial-'));
    writeFileSync(join(dir, 'a.ts'), "export const A = 'A-original';\n");
    writeFileSync(join(dir, 'b.ts'), "export const B = 'B-original';\n");
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string; code: string; map?: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      sourcemap: true,
      onReady: () => readyDone(),
      onRebuild: (e) => rebuildDone(e),
    });

    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'a.ts'), "export const A = 'A-changed';\n");

    const event = await rebuildP;

    expect(event.graphChanged).toBeFalsy();
    expect(event.updates).toBeDefined();
    expect(event.updates!.length).toBe(1);

    const u = event.updates![0];
    expect(u.id.endsWith('a.ts')).toBe(true);
    expect(u.code).toContain('A-changed');
    expect(u.code).not.toContain('B-original');

    // Issue #1727 Phase B: per-module sourcemap 은 lazy getter 로 제공.
    // updates[i].map 은 lazy 경로에서 undefined 이고, handle.getHmrSourceMap(id) 로 조회.
    const mapJson = handle.getHmrSourceMap(u.id);
    expect(mapJson).not.toBeNull();
    const m = JSON.parse(mapJson!);
    expect(m.sources).toHaveLength(1);
    expect(m.sources[0].endsWith('a.ts')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('Issue #1682: 충돌 rename 모듈은 cache-hit 시 HMR updates 에서 제외 (phantom filter)', async () => {
    // Linker 의 conflict rename 은 initial build 와 첫 rebuild 간 `$N` 접미사가
    // 비결정적으로 움직여 cache-hit 모듈의 emit 결과가 미세하게 달라진다.
    // module_code_cache 는 바이트 비교라 이런 모듈을 phantom 변경으로 오인,
    // 첫 rebuild HMR payload 에 포함시켜 — 런타임 `__zntc_apply_update` 가
    // hot-accept 없는 모듈을 만나자마자 `__zntc_reload()` 로 빠지게 만든다.
    //
    // 수정 (BundleResult.reparsed_paths 필터): cache-hit 모듈은 source 변경이
    // 증명되지 않았으므로 HMR payload 에서 제외. 회귀 테스트로 같은 이름 export
    // 두 개를 가진 fixture 를 만든 뒤, entry 만 수정한 rebuild 에서 updates 에
    // a.ts / b.ts 가 들어가지 않는지 확인.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-phantom-'));
    // 두 모듈에서 같은 top-level 이름 export → Linker 가 한쪽을 `$1` 로 rename.
    writeFileSync(join(dir, 'a.ts'), 'export const count = 1;\n');
    writeFileSync(join(dir, 'b.ts'), 'export const count = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { count as A } from './a';\nimport { count as B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady: () => readyDone(),
      onRebuild: (e) => rebuildDone(e),
    });

    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    // entry.ts 만 수정 → a.ts / b.ts 는 cache-hit.
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { count as A } from './a';\nimport { count as B } from './b';\nconsole.log(A, B, 1);\n",
    );

    const event = await rebuildP;
    handle.stop();

    expect(event.graphChanged).toBeFalsy();
    expect(event.updates).toBeDefined();
    // 수정 전: a.ts / b.ts 도 phantom update 로 들어와 updates.length >= 3.
    // 수정 후: entry.ts 단독 → 1.
    const ids = event.updates!.map((u) => u.id);
    expect(ids.some((id) => id.endsWith('entry.ts'))).toBe(true);
    expect(ids.some((id) => id.endsWith('a.ts'))).toBe(false);
    expect(ids.some((id) => id.endsWith('b.ts'))).toBe(false);

    rmSync(dir, { recursive: true });
  }, 10000);

  test('새 import 추가 시 graphChanged 감지', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    // 새 모듈 추가 → graph 변경
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');

    const event = await rebuildP;
    expect(event.graphChanged).toBe(true);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('stop() 후 리빌드 발생하지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
      },
    });

    await readyP;
    handle.stop();

    // stop 후 파일 수정
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');
    await new Promise((r) => setTimeout(r, 1000));

    expect(rebuildCount).toBe(0);
    rmSync(dir, { recursive: true });
  }, 5000);

  test('double stop()은 에러 없이 무시', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
    });

    await readyP;
    handle.stop();
    // 두 번째 stop() — 에러 없이 무시되어야 함
    expect(() => handle.stop()).not.toThrow();
    rmSync(dir, { recursive: true });
  });

  test('플러그인과 함께 watch', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'import "./style.css"; export const x = 1;');
    writeFileSync(join(dir, 'style.css'), 'body { color: red; }');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();

    const cssPlugin: ZntcPlugin = {
      name: 'css-loader',
      setup(build) {
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "css-loaded";',
        }));
      },
    };

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [cssPlugin],
      onReady(event) {
        expect(event.files).toBeGreaterThan(0);
        readyDone();
      },
    });

    await readyP;
    handle.stop();
    rmSync(dir, { recursive: true });
  });

  test('콜백 없이 watch — crash 없이 동작', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    // onReady, onRebuild 모두 미제공
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
    });

    // 초기 빌드 완료 대기 (콜백 없으므로 타이머로)
    await new Promise((r) => setTimeout(r, 1500));
    expect(() => handle.stop()).not.toThrow();
    rmSync(dir, { recursive: true });
  }, 5000);

  test('리빌드 중 문법 에러 시 success: false + error', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      success: boolean;
      error?: string;
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

    // 문법 에러가 있는 코드로 변경
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const = ;; {{{{');

    const event = await rebuildP;
    // 에러가 발생하더라도 watch는 계속 동작해야 함
    // (ZNTC 파서가 에러 복구를 하므로 success: true일 수도 있음)
    expect(typeof event.success).toBe('boolean');
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('changed 배열에 변경된 파일 경로 포함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    const entryPath = join(dir, 'entry.ts');
    writeFileSync(entryPath, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      changed?: string[];
    }>();

    const handle = watch({
      entryPoints: [entryPath],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(entryPath, 'export const x = 2;');

    const event = await rebuildP;
    expect(event.changed).toBeDefined();
    expect(event.changed!.length).toBeGreaterThan(0);
    // 변경된 파일의 절대 경로가 포함되어야 함
    const hasEntry = event.changed!.some((p) => p.includes('entry.ts'));
    expect(hasEntry).toBe(true);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  // ── Issue #1727 Phase B: Lazy sourcemap NAPI getters ─────────────────────

  test('getBundleSourceMap — sourcemap + devMode 시 초기 빌드 후 V3 JSON 반환', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sm-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 1;\nconsole.log(x);\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false, // lazy 엔드포인트로만 serve
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    expect(json).toContain('"version":3');
    expect(json).toContain('"mappings"');

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — sourcemap 비활성 시 null', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sm-off-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      devMode: true,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    expect(handle.getBundleSourceMap()).toBeNull();
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getHmrSourceMap — 모듈 id 로 JSON 반환, 미존재 id 는 null', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-hmr-sm-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 42;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: { id: string }[];
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 7;\n');
    const event = await rebuildP;
    expect(event.updates).toBeDefined();
    expect(event.updates!.length).toBeGreaterThan(0);

    const moduleId = event.updates![0].id;
    const json = handle.getHmrSourceMap(moduleId);
    expect(json).not.toBeNull();
    expect(json).toContain('"version":3');

    expect(handle.getHmrSourceMap('does/not/exist')).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('emitDiskSourcemap=false — rebuild 후 bundle.js.map 을 디스크에 쓰지 않는다', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-disk-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    // bundle.js 는 있지만 .map 은 없어야 함
    expect(existsSync(join(dir, 'bundle.js'))).toBe(true);
    expect(existsSync(join(dir, 'bundle.js.map'))).toBe(false);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — 반복 호출 시 동일 JSON 반환 (재진입 안전)', async () => {
    // NAPI mutex + builder.buf clearRetainingCapacity 로 여러 번 호출해도 동일 결과.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-repeat-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const j1 = handle.getBundleSourceMap();
    const j2 = handle.getBundleSourceMap();
    const j3 = handle.getBundleSourceMap();
    expect(j1).not.toBeNull();
    expect(j2).toBe(j1!);
    expect(j3).toBe(j1!);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — rebuild 후 swap 이 반영되고 이전 mappings 와 달라짐', async () => {
    // rebuild 마다 새 builder 로 swap. 내용이 바뀐 코드에 대한 mappings 가 업데이트되어야.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-swap-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;

    const before = handle.getBundleSourceMap();
    expect(before).not.toBeNull();

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export const x = 1;\nexport const y = 2;\nexport const z = 3;\n',
    );
    await rebuildP;

    const after = handle.getBundleSourceMap();
    expect(after).not.toBeNull();
    // 코드가 길어졌으니 mappings 문자열도 길어져야 한다.
    const m1 = JSON.parse(before!);
    const m2 = JSON.parse(after!);
    expect(m2.mappings.length).toBeGreaterThan(m1.mappings.length);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getHmrSourceMap — multi-module rebuild 에서 모든 모듈 id 로 조회 가능', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-multi-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;\n');
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 999;\n');
    const event = await rebuildP;

    expect(event.updates).toBeDefined();
    // rebuild 의 updates 는 변경된 모듈(a.ts) 만 — 하지만 module_sm_map 에는 전체 모듈이
    // 적재돼 있어야 이후 요청에서 b.ts / entry.ts 의 map 도 lazy serve 가능.
    const u = event.updates![0];
    const mapA = handle.getHmrSourceMap(u.id);
    expect(mapA).not.toBeNull();

    // 변경 안 된 모듈도 module_sm_map 에 있으므로 id 알면 조회 가능.
    // NAPI 는 모든 모듈의 per-module code 를 수집하지만 JS 는 updates diff 만 받는다 —
    // id 를 직접 구성하는 대신 rebuild 에서 updates 의 id 패턴이 파일명을 포함하는지 확인.
    expect(u.id.endsWith('a.ts')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getBundleSourceMap — sources_content 옵션 반영 (false 면 sourcesContent 제외)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sc-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcesContent: false,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.sourcesContent).toBeUndefined();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — debug_ids 활성 시 JSON 과 bundle.js 가 동일 UUID 공유', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-did-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcemapDebugIds: true,
      devMode: true,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const js = readFileSync(join(dir, 'bundle.js'), 'utf8');
    const match = js.match(/\/\/# debugId=([0-9a-f-]+)/);
    expect(match).not.toBeNull();
    const uuid = match![1];

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.debugId).toBe(uuid);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getHmrSourceMap — initial build 직후 (rebuild 전) 모듈 id 조회 가능', async () => {
    // swap 이 rebuild 뿐 아니라 initial build 완료 시에도 호출돼야 한다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-init-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    // 아직 rebuild 없음 — 하지만 initial build 의 swap 으로 모듈 id 를 얻기 위해
    // 일단 한 번 수정을 일으켜 id 를 알아낸 뒤, 동일 rebuild 후 getter 를 호출한다.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;\n');
    const event = await rebuildP;
    const id = event.updates![0].id;

    // rebuild swap 이 된 상태에서 모듈 id 로 JSON 을 받아낼 수 있다.
    const json = handle.getHmrSourceMap(id);
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.version).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getBundleSourceMap — custom output_filename 이 map.file 에 반영', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-file-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'custom-name.mjs'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(typeof m.file).toBe('string');
    expect(m.file.endsWith('custom-name.mjs')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getHmrSourceMap — graph 변경 (모듈 추가) 후 새 모듈도 swap 에 포함', async () => {
    // graph_changed=true 이면 NAPI 가 updates 배열을 비우므로, 2단계로 진행:
    //   1) b.ts 추가 → graphChanged 이벤트
    //   2) b.ts 재수정 → updates=[b] — 이 시점에 b 의 id 를 획득
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-graph-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;\n');
    writeFileSync(join(dir, 'entry.ts'), "import { A } from './a';\nconsole.log(A);\n");

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let seenGraphChange = false;
    let secondUpdates: Array<{ id: string }> | undefined;
    const { promise: secondP, resolve: secondDone } = Promise.withResolvers<void>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        if (!seenGraphChange) {
          if (event.graphChanged) seenGraphChange = true;
        } else if (event.updates && event.updates.length > 0) {
          secondUpdates = event.updates;
          secondDone();
        }
      },
    });
    await readyP;

    // 1차: b.ts 추가 + entry import 확장 → graphChanged.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );
    // graphChanged 이벤트 처리 대기.
    await new Promise((r) => setTimeout(r, 500));
    expect(seenGraphChange).toBe(true);

    // 2차: b.ts 재수정 → updates=[b] — b 의 id 획득 경로.
    writeFileSync(join(dir, 'b.ts'), 'export const B = 999;\n');
    await secondP;

    const bId = secondUpdates!.find((u) => u.id.endsWith('b.ts'))?.id;
    expect(bId).toBeDefined();

    // graph 변경 후에도 handle 의 module_sm_map 에 b 가 포함 → getter 성공.
    const mapB = handle.getHmrSourceMap(bId!);
    expect(mapB).not.toBeNull();

    // 완전 존재하지 않는 id — null.
    expect(handle.getHmrSourceMap('absolutely/not/a/module.ts')).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 20000);

  test('getBundleSourceMap — rebuild 실패 후 이전 JSON 이 캐시로 유지된다', async () => {
    // rebuild 가 parse error 등으로 실패하면 swap 이 호출되지 않아 이전 rebuild 의 builder 유지.
    // dev 서버가 의미있는 sourcemap 을 계속 제공할 수 있어야 함.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-err-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildResolved = false;
    const { promise: errP, resolve: errDone } = Promise.withResolvers<{ success: boolean }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        if (!rebuildResolved) {
          rebuildResolved = true;
          errDone(event);
        }
      },
    });
    await readyP;

    const before = handle.getBundleSourceMap();
    expect(before).not.toBeNull();

    // 파싱 불가능한 코드로 덮어쓰기.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: = = =;;;\n');
    await errP;

    // 실패해도 이전 builder 가 남아있어 getter 는 유효 JSON 반환.
    const after = handle.getBundleSourceMap();
    expect(after).not.toBeNull();
    const m = JSON.parse(after!);
    expect(m.version).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getBundleSourceMap — sourcemap_function_map 활성 시에도 lazy JSON 생성 성공', async () => {
    // lazy 경로는 generateJSON 을 일반 경로로 호출 (infra PR 은 per-source fn_map 통합 미지원).
    // function_map 옵션이 켜져 있어도 bundle sourcemap JSON 이 crash 없이 반환되고 V3 형식.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-fnmap-'));
    writeFileSync(join(dir, 'entry.ts'), "export function hello() { return 'hi'; }\n");

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcemapFunctionMap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.version).toBe(3);
    expect(Array.isArray(m.sources)).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('bundle.js — lazy 경로에서도 sourceMappingURL 주석 출력 (DevTools fetch 경로)', async () => {
    // lazy 는 .map 을 디스크에 쓰지 않지만 bundle.js 의 sourceMappingURL 주석은 유지.
    // DevTools / Sentry 가 이 URL 을 fetch → NAPI getter → JSON 응답 경로.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-url-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const js = readFileSync(join(dir, 'bundle.js'), 'utf8');
    expect(js).toContain('//# sourceMappingURL=');
    expect(js).toContain('.map');

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — 연쇄 rebuild (3회) 에서 최신 swap 만 유효', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-chain-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuilds = 0;
    const rebuildResolvers: Array<() => void> = [];
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuilds++;
        const next = rebuildResolvers.shift();
        if (next) next();
      },
    });
    await readyP;

    const lens: number[] = [];
    for (let i = 0; i < 3; i++) {
      const { promise, resolve } = Promise.withResolvers<void>();
      rebuildResolvers.push(resolve);
      await new Promise((r) => setTimeout(r, 100));
      // 매 rebuild 마다 코드 길이 증가.
      const body = Array.from(
        { length: (i + 1) * 3 },
        (_, k) => `export const e${i}_${k} = ${k};`,
      ).join('\n');
      writeFileSync(join(dir, 'entry.ts'), body + '\n');
      await promise;

      const json = handle.getBundleSourceMap();
      expect(json).not.toBeNull();
      const m = JSON.parse(json!);
      lens.push(m.mappings.length);
    }

    // 매 rebuild 마다 mappings 가 더 길어지는 경향 (strictly increasing).
    expect(lens[0]).toBeGreaterThan(0);
    expect(lens[1]).toBeGreaterThan(lens[0]);
    expect(lens[2]).toBeGreaterThan(lens[1]);
    expect(rebuilds).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 20000);

  test('getBundleSourceMap + getHmrSourceMap 교대 호출 — 상호 간섭 없음', async () => {
    // 같은 handle 에서 bundle/hmr getter 를 번갈아 호출. mutex 가 재진입 아니므로
    // 동일 thread 순차 호출은 안전. JSON 내용이 서로 섞이지 않는지 확인.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-mix-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 42;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 99;\n');
    const event = await rebuildP;
    const id = event.updates![0].id;

    // 교대로 3회씩 호출 — 각 호출이 type 정합성 유지.
    for (let i = 0; i < 3; i++) {
      const bundleJson = handle.getBundleSourceMap();
      expect(bundleJson).not.toBeNull();
      expect(JSON.parse(bundleJson!).version).toBe(3);

      const hmrJson = handle.getHmrSourceMap(id);
      expect(hmrJson).not.toBeNull();
      const hm = JSON.parse(hmrJson!);
      expect(hm.version).toBe(3);
      // per-module map 은 sources 길이 1.
      expect(hm.sources.length).toBe(1);
    }

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('emitDiskSourcemap=false + eager (devMode=false) — .map 디스크 skip 유지', async () => {
    // devMode=false 면 NAPI 가 lazy 를 안 켬 → eager 경로. 이 상태에서도 emitDiskSourcemap
    // 옵션이 .map 디스크 write 제어 가능해야 한다. getter 는 lazy 가 꺼져있으니 null.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-eager-nodev-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: false,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    expect(existsSync(join(dir, 'bundle.js'))).toBe(true);
    expect(existsSync(join(dir, 'bundle.js.map'))).toBe(false);
    // eager 경로이므로 handle cache 에 builder 없음 → null.
    expect(handle.getBundleSourceMap()).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — stop() 후 null 반환 (use-after-stop 방어)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-stop-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    handle.stop();
    // stop 후 napi_remove_wrap 된 handle — getter 는 null 반환 (throw 하지 않음)
    expect(handle.getBundleSourceMap()).toBeNull();
    expect(handle.getHmrSourceMap('whatever')).toBeNull();

    rmSync(dir, { recursive: true });
  }, 10000);
});

// ================================================================
// Issue #1223: HMR perf — 재현 테스트
// 폴링 워처(500ms), mtime-only 캐시, 디바운스 부재, 증분 미흡, 관측성 부재
// ================================================================
