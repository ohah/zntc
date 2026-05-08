import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  vitePlugin,
  resolve,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  existsSync,
  symlinkSync,
  join,
  tmpdir,
  ROOT_NODE_MODULES,
  diagText,
  expectPluginDiagnostic,
} from './helpers';

describe('@zntc/core build + plugins', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
    writeFileSync(
      join(dir, 'app.ts'),
      'import { greet } from "./virtual:greeting";\nconsole.log(greet());',
    );
    // lifecycle hook 테스트용 — plugin 의존성 없는 깔끔한 entry.
    writeFileSync(join(dir, 'lifecycle-entry.ts'), 'console.log("hi");');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('onResolve disabled: true → 빈 모듈로 대체 (Metro empty / webpack false 매핑)', async () => {
    // entry가 'should-be-empty'를 import. plugin이 disabled로 매핑.
    writeFileSync(
      join(dir, 'entry-disabled.ts'),
      `import * as m from "should-be-empty"; console.log(typeof m);`,
    );
    const disabledPlugin: ZntcPlugin = {
      name: 'disabled-resolver',
      setup(build) {
        build.onResolve({ filter: /^should-be-empty$/ }, () => ({
          disabled: true,
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry-disabled.ts')],
      plugins: [disabledPlugin],
    });
    expect(result.errors.length).toBe(0);
    // disabled 모듈은 빈 객체 export → typeof는 "object"
    expect(result.outputFiles[0].text).toMatch(/should-be-empty|module\.exports\s*=/);
  });

  test('onResolve + onLoad 플러그인 (CSS → JS 변환)', async () => {
    const cssPlugin: ZntcPlugin = {
      name: 'css-plugin',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "color: red";',
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [cssPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('color: red');
  });

  test('multiple plugins 체이닝', async () => {
    const plugin1: ZntcPlugin = {
      name: 'css-resolve',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
      },
    };
    const plugin2: ZntcPlugin = {
      name: 'css-load',
      setup(build) {
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "blue";',
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [plugin1, plugin2],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('blue');
  });

  test('onTransform 플러그인 (코드 변환)', async () => {
    const transformPlugin: ZntcPlugin = {
      name: 'transform-plugin',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (args) => ({
          code: args.code.replace('console.log', 'console.warn'),
        }));
      },
    };

    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-transform-'));
    writeFileSync(join(entryDir, 'main.ts'), 'console.log("hello");');

    const result = await build({
      entryPoints: [join(entryDir, 'main.ts')],
      plugins: [transformPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('console.warn');
    expect(result.outputFiles[0].text).not.toContain('console.log');
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('#2038: onTransform이 추가한 sideEffects:false 패키지 import도 tree-shaking 입력이 됨', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-2038-plugin-pkg-'));
    writeFileSync(join(entryDir, 'main.ts'), "console.log('__ORIGINAL_2038__');");
    mkdirSync(join(entryDir, 'node_modules', 'pure-lib-2038'), { recursive: true });
    writeFileSync(
      join(entryDir, 'node_modules', 'pure-lib-2038', 'package.json'),
      '{"name":"pure-lib-2038","main":"index.js","sideEffects":false}',
    );
    writeFileSync(
      join(entryDir, 'node_modules', 'pure-lib-2038', 'index.js'),
      [
        'export const used = "core-plugin-used-2038";',
        'export const unused = "core-plugin-unused-2038";',
      ].join('\n'),
    );

    const transformPlugin: ZntcPlugin = {
      name: 'transform-adds-package-import',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, () => ({
          code: 'import { used } from "pure-lib-2038";\nconsole.log(used);',
        }));
      },
    };

    try {
      const result = await build({
        entryPoints: [join(entryDir, 'main.ts')],
        treeShaking: true,
        plugins: [transformPlugin],
      });
      expect(result.errors.length).toBe(0);
      const text = result.outputFiles[0].text;
      expect(text).toContain('core-plugin-used-2038');
      expect(text).not.toContain('core-plugin-unused-2038');
      expect(text).not.toContain('__ORIGINAL_2038__');
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });

  test.skipIf(!existsSync(join(ROOT_NODE_MODULES, 'lodash-es', 'package.json')))(
    '#2038: 실제 lodash-es import를 onTransform으로 주입해도 dead export가 새지 않음',
    async () => {
      const entryDir = mkdtempSync(join(tmpdir(), 'zntc-2038-lodash-plugin-'));
      writeFileSync(join(entryDir, 'main.ts'), "console.log('__ORIGINAL_LODASH_2038__');");
      mkdirSync(join(entryDir, 'node_modules'), { recursive: true });
      symlinkSync(
        join(ROOT_NODE_MODULES, 'lodash-es'),
        join(entryDir, 'node_modules', 'lodash-es'),
      );

      const transformPlugin: ZntcPlugin = {
        name: 'transform-adds-lodash-import',
        setup(build) {
          build.onTransform({ filter: /main\.ts$/ }, () => ({
            code: 'import { uniq } from "lodash-es";\nconsole.log(uniq([1,2,2,3]).join(","));',
          }));
        },
      };

      try {
        const result = await build({
          entryPoints: [join(entryDir, 'main.ts')],
          platform: 'node',
          treeShaking: true,
          plugins: [transformPlugin],
        });
        expect(result.errors.length).toBe(0);
        const text = result.outputFiles[0].text;
        expect(text).toContain('uniq');
        expect(text).not.toContain('__ORIGINAL_LODASH_2038__');
        for (const dead of ['groupBy', 'orderBy', 'mapValues', 'debounce', 'throttle']) {
          expect(
            new RegExp(`(^|\\n)(function|const|var|let)\\s+${dead}\\b`, 'm').test(text),
            `dead lodash-es identifier "${dead}" leaked to transform-added bundle`,
          ).toBe(false);
        }
      } finally {
        rmSync(entryDir, { recursive: true, force: true });
      }
    },
  );

  // ============================================================
  // require.context — onResolveContext hook (#1579 Phase 2.5)
  // ============================================================

  test('onResolveContext: hook 호출 + args 전달 (dir/recursive/filter/flags/importer)', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./pages', true, /\\.tsx?$/, 'sync'); console.log(ctx);",
    );

    let captured: any = null;
    const plugin: ZntcPlugin = {
      name: 'rc-capture',
      setup(build) {
        build.onResolveContext({ filter: /.*/ }, (args) => {
          captured = args;
          return { context: ['./a.tsx', './b.tsx'] };
        });
      },
    };

    await build({
      entryPoints: [join(entryDir, 'entry.ts')],
      plugins: [plugin],
    });

    expect(captured).not.toBeNull();
    expect(captured.dir).toBe('./pages');
    expect(captured.recursive).toBe(true);
    expect(captured.filter).toBe('\\.tsx?$');
    expect(captured.importer).toContain('entry.ts');
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: plugin 미구현 → require_context_no_handler warning', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-noplug-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./pages'); console.log(ctx);",
    );

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
    });

    const allDiags = [...(result.warnings ?? []), ...(result.errors ?? [])];
    const hasNoHandler = allDiags.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('requires a host plugin')) ||
        (typeof d.message === 'string' && d.message.includes('requires a host plugin')),
    );
    expect(hasNoHandler).toBe(true);
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: invalid require.context (numeric arg) → require_context_invalid error', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-invalid-'));
    writeFileSync(join(entryDir, 'entry.ts'), 'const ctx = require.context(42); console.log(ctx);');

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
    });

    const hasInvalid = result.errors.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('first argument must be a string')) ||
        (typeof d.message === 'string' && d.message.includes('first argument must be a string')),
    );
    expect(hasInvalid).toBe(true);
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: 빈 매칭 결과 (empty context) — diagnostic 없음', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-empty-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./nonexistent'); console.log(ctx);",
    );

    const plugin: ZntcPlugin = {
      name: 'rc-empty',
      setup(build) {
        build.onResolveContext({ filter: /.*/ }, () => ({ context: [] }));
      },
    };

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
      plugins: [plugin],
    });

    const allDiags = [...(result.warnings ?? []), ...(result.errors ?? [])];
    const hasNoHandler = allDiags.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('requires a host plugin')) ||
        (typeof d.message === 'string' && d.message.includes('requires a host plugin')),
    );
    expect(hasNoHandler).toBe(false);
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('buildSync: onResolve/onLoad/onTransform sync plugin 동작', () => {
    const syncDir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-plugin-'));
    writeFileSync(
      join(syncDir, 'entry.ts'),
      'import msg from "virtual:message";\nconsole.log(msg);',
    );
    const virtualPath = join(syncDir, 'virtual-message.ts');

    const plugin: ZntcPlugin = {
      name: 'sync-plugin',
      setup(build) {
        build.onResolve({ filter: /^virtual:message$/ }, () => ({ path: virtualPath }));
        build.onLoad({ filter: /virtual-message\.ts$/ }, () => ({
          contents: 'export default "SYNC_LOAD";',
        }));
        build.onTransform({ filter: /virtual-message\.ts$/ }, (args) => ({
          code: args.code.replace('SYNC_LOAD', 'SYNC_TRANSFORM'),
        }));
      },
    };

    const result = buildSync({
      entryPoints: [join(syncDir, 'entry.ts')],
      plugins: [plugin],
    });

    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('SYNC_TRANSFORM');
    rmSync(syncDir, { recursive: true, force: true });
  });

  test('buildSync: vitePlugin sync hooks 동작', () => {
    const syncDir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-vite-plugin-'));
    writeFileSync(
      join(syncDir, 'entry.ts'),
      'import { msg } from "virtual:vite";\nconsole.log(msg);',
    );
    const virtualPath = join(syncDir, 'virtual-vite.ts');

    const result = buildSync({
      entryPoints: [join(syncDir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-sync-plugin',
          resolveId(id) {
            if (id === 'virtual:vite') return virtualPath;
            return null;
          },
          load(id) {
            if (id === virtualPath) return 'export const msg = "VITE_LOAD";';
            return null;
          },
          transform(code, id) {
            if (id === virtualPath) return { code: code.replace('VITE_LOAD', 'VITE_TRANSFORM') };
            return null;
          },
        }),
      ],
    });

    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('VITE_TRANSFORM');
    rmSync(syncDir, { recursive: true, force: true });
  });

  test('buildSync: Promise 반환 plugin hook은 plugin_error로 실패하고 async build 안내를 포함', () => {
    const syncDir = mkdtempSync(join(tmpdir(), 'zntc-buildsync-async-plugin-'));
    writeFileSync(join(syncDir, 'entry.ts'), 'import "./async-module";');
    writeFileSync(join(syncDir, 'async-module.ts'), 'console.log("original");');

    const plugin: ZntcPlugin = {
      name: 'async-in-sync-plugin',
      setup(build) {
        build.onLoad({ filter: /async-module\.ts$/ }, () =>
          Promise.resolve({ contents: 'console.log("async");' }),
        );
      },
    };

    const result = buildSync({
      entryPoints: [join(syncDir, 'entry.ts')],
      plugins: [plugin],
    });

    expectPluginDiagnostic(result, {
      plugin: 'async-in-sync-plugin',
      hook: 'load',
      message: 'buildSync() does not support async plugin hooks',
      fileIncludes: 'async-module.ts',
    });
    expect(diagText(result.errors[0])).toContain('use build() instead');
    rmSync(syncDir, { recursive: true, force: true });
  });

  test('plugin_error: onLoad sync throw가 diagnostic으로 노출됨', async () => {
    const throwPlugin: ZntcPlugin = {
      name: 'throw-plugin',
      setup(build) {
        build.onResolve({ filter: /\.boom$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.boom$/ }, () => {
          throw new Error('plugin error!');
        });
      },
    };
    writeFileSync(join(dir, 'entry-load-error.ts'), 'import "./style.boom";');

    const result = await build({
      entryPoints: [join(dir, 'entry-load-error.ts')],
      plugins: [throwPlugin],
    });
    expectPluginDiagnostic(result, {
      plugin: 'throw-plugin',
      hook: 'load',
      message: 'plugin error!',
      fileIncludes: 'style.boom',
    });
  });

  test('plugin_error: onTransform async reject가 diagnostic으로 노출됨', async () => {
    const rejectPlugin: ZntcPlugin = {
      name: 'reject-transform',
      setup(build) {
        build.onTransform({ filter: /transform-reject\.ts$/ }, async () => {
          throw new Error('async transform rejected');
        });
      },
    };
    writeFileSync(join(dir, 'transform-reject.ts'), 'console.log("transform");');

    const result = await build({
      entryPoints: [join(dir, 'transform-reject.ts')],
      plugins: [rejectPlugin],
    });
    expectPluginDiagnostic(result, {
      plugin: 'reject-transform',
      hook: 'transform',
      message: 'async transform rejected',
      fileIncludes: 'transform-reject.ts',
    });
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

// ─── 엣지케이스 테스트 ───
