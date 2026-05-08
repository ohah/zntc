import {
  describe,
  test,
  expect,
  build,
  vitePlugin,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core plugin lifecycle', () => {
  test('buildStart / buildEnd / closeBundle 정상 build 시 호출 + 호출 순서', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const order: string[] = [];
    const plugin: ZntcPlugin = {
      name: 'lifecycle',
      setup(build) {
        build.onBuildStart(() => {
          order.push('buildStart');
        });
        build.onTransform({ filter: /\.ts$/ }, (args) => {
          order.push('transform');
          return { code: args.code };
        });
        build.onBuildEnd((err) => {
          order.push(err ? `buildEnd:err=${err.message}` : 'buildEnd');
        });
        build.onCloseBundle(() => {
          order.push('closeBundle');
        });
      },
    };

    await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });

    expect(order[0]).toBe('buildStart');
    expect(order[order.length - 2]).toBe('buildEnd');
    expect(order[order.length - 1]).toBe('closeBundle');
    expect(order).toContain('transform');
    rmSync(dir, { recursive: true });
  });

  test('buildStart / buildEnd / closeBundle 미등록 plugin 도 정상 build', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-empty-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const plugin: ZntcPlugin = {
      name: 'no-lifecycle',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (args) => ({ code: args.code }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('const x = 1');
    rmSync(dir, { recursive: true });
  });

  test('다중 plugin: 모든 plugin 의 buildStart / buildEnd / closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-multi-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    let p1Start = 0,
      p2Start = 0,
      p1End = 0,
      p2End = 0,
      p1Close = 0,
      p2Close = 0;
    const p1: ZntcPlugin = {
      name: 'p1',
      setup(b) {
        b.onBuildStart(() => {
          p1Start++;
        });
        b.onBuildEnd(() => {
          p1End++;
        });
        b.onCloseBundle(() => {
          p1Close++;
        });
      },
    };
    const p2: ZntcPlugin = {
      name: 'p2',
      setup(b) {
        b.onBuildStart(() => {
          p2Start++;
        });
        b.onBuildEnd(() => {
          p2End++;
        });
        b.onCloseBundle(() => {
          p2Close++;
        });
      },
    };
    await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [p1, p2] });
    expect(p1Start).toBe(1);
    expect(p2Start).toBe(1);
    expect(p1End).toBe(1);
    expect(p2End).toBe(1);
    expect(p1Close).toBe(1);
    expect(p2Close).toBe(1);
    rmSync(dir, { recursive: true });
  });

  test('vitePlugin 어댑터: Rollup plugin 의 buildStart / buildEnd / closeBundle 을 ZNTC build 에서 호출', async () => {
    // vitePlugin: RollupPlugin → ZntcPlugin 변환 어댑터. 사용자가 작성한 Rollup plugin 의
    // lifecycle hook 들이 ZNTC bundle() 시 호출되는지 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-vite-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    let buildStartCalled = false;
    let buildEndCalled = false;
    let closeBundleCalled = false;
    const rollupPlugin: RollupPlugin = {
      name: 'rollup-lifecycle',
      buildStart() {
        buildStartCalled = true;
      },
      buildEnd() {
        buildEndCalled = true;
      },
      closeBundle() {
        closeBundleCalled = true;
      },
    };
    await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [vitePlugin(rollupPlugin)] });
    expect(buildStartCalled).toBe(true);
    expect(buildEndCalled).toBe(true);
    expect(closeBundleCalled).toBe(true);
    rmSync(dir, { recursive: true });
  });
});
