/**
 * `css()` plugin factory 단위 test (#2538 4-4 PR-2).
 *
 * setup() 안 onLoad hook 등록 검증 + disabled 옵션 + ZntcPlugin shape. 실 PostCSS
 * 호출은 integration test (PR-3) 에서.
 */

import { describe, expect, test } from 'bun:test';
import type { PluginBuild } from '@zntc/core';

import { css } from './index.ts';

interface MockBuild {
  loadHooks: Array<{ filter: RegExp; cb: (args: { path: string }) => unknown }>;
  resolveHooks: Array<{ filter: RegExp; cb: unknown }>;
  transformHooks: Array<{ filter: RegExp; cb: unknown }>;
}

function makeMockBuild(): { build: PluginBuild; tracked: MockBuild } {
  const tracked: MockBuild = { loadHooks: [], resolveHooks: [], transformHooks: [] };
  const build = {
    onLoad: (opts: { filter: RegExp }, cb: (args: { path: string }) => unknown) => {
      tracked.loadHooks.push({ filter: opts.filter, cb });
    },
    onResolve: (opts: { filter: RegExp }, cb: unknown) => {
      tracked.resolveHooks.push({ filter: opts.filter, cb });
    },
    onTransform: (opts: { filter: RegExp }, cb: unknown) => {
      tracked.transformHooks.push({ filter: opts.filter, cb });
    },
  } as unknown as PluginBuild;
  return { build, tracked };
}

describe('css() plugin factory', () => {
  test('ZntcPlugin shape — name + setup(build)', () => {
    const plugin = css();
    expect(plugin.name).toBe('@zntc/web/css');
    expect(typeof plugin.setup).toBe('function');
  });

  // RFC #3833 v3 D1a'' (caller-side pre-warm): css() 반환 객체에 `__cssOptions`
  // sentinel — runAppBuild/runAppDev 의 extractCssPostcssOverride helper 가
  // 이걸로 explicit override 추출. dispatcher 는 name/setup 만 사용, sentinel 무영향.
  test('__cssOptions sentinel — caller-side pre-warm 용 (D1a)', () => {
    // 기본 옵션 — empty 객체로 sentinel 부착
    const plugin1 = css() as { __cssOptions: unknown };
    expect(plugin1.__cssOptions).toEqual({});

    // postcss override 명시
    const plugin2 = css({ postcss: { plugins: [{ postcssPlugin: 'x', Once() {} }] } }) as {
      __cssOptions: { postcss?: { plugins?: unknown[] } };
    };
    expect(plugin2.__cssOptions.postcss?.plugins).toHaveLength(1);

    // disabled flag
    const plugin3 = css({ disabled: true }) as { __cssOptions: { disabled?: boolean } };
    expect(plugin3.__cssOptions.disabled).toBe(true);

    // root / mode 옵션 sentinel 보존
    const plugin4 = css({ root: '/abs', mode: 'production' }) as {
      __cssOptions: { root?: string; mode?: string };
    };
    expect(plugin4.__cssOptions.root).toBe('/abs');
    expect(plugin4.__cssOptions.mode).toBe('production');
  });

  test('zero-config 호출 — onLoad hook 1개 등록 (.css filter)', () => {
    const plugin = css();
    const { build, tracked } = makeMockBuild();
    plugin.setup(build);

    expect(tracked.loadHooks.length).toBe(1);
    // filter 는 .module.css 제외 — negative lookbehind 적용된 정규식.
    expect(tracked.loadHooks[0]!.filter.test('foo.css')).toBe(true);
    expect(tracked.loadHooks[0]!.filter.test('foo.module.css')).toBe(false);
    expect(tracked.resolveHooks.length).toBe(0);
    expect(tracked.transformHooks.length).toBe(0);
  });

  test('disabled: true — setup 이 hook 미등록', () => {
    const plugin = css({ disabled: true });
    const { build, tracked } = makeMockBuild();
    plugin.setup(build);

    expect(tracked.loadHooks.length).toBe(0);
    expect(tracked.resolveHooks.length).toBe(0);
    expect(tracked.transformHooks.length).toBe(0);
  });

  test('postcss override — postcss.plugins 명시 시에도 정상 setup', () => {
    const plugin = css({ postcss: { plugins: [], options: { map: false } } });
    const { build, tracked } = makeMockBuild();
    plugin.setup(build);

    // override 케이스에도 onLoad hook 은 동일하게 1개 — 차이는 hook 안의 분기.
    expect(tracked.loadHooks.length).toBe(1);
  });

  test('onLoad — postcss.config 없을 때 입력 그대로 pass-through', async () => {
    const plugin = css({ root: '/nonexistent-dir-no-config' });
    const { build, tracked } = makeMockBuild();
    plugin.setup(build);

    const hook = tracked.loadHooks[0]!.cb;
    const fs = await import('node:fs');
    const os = await import('node:os');
    const path = await import('node:path');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zntc-css-test-'));
    const file = path.join(dir, 'sample.css');
    fs.writeFileSync(file, 'body { color: red; }');

    try {
      const result = (await hook({ path: file })) as { contents: string };
      // postcss.config 없으므로 pass-through — 입력 그대로
      expect(result.contents).toBe('body { color: red; }');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('filter regex 는 .module.css 미매치', () => {
    const plugin = css();
    const { build, tracked } = makeMockBuild();
    plugin.setup(build);

    const filter = tracked.loadHooks[0]!.filter;
    expect(filter.test('/foo/app.css')).toBe(true);
    expect(filter.test('/foo/a.module.css')).toBe(false);
    expect(filter.test('/foo/styles.module.css')).toBe(false);
  });

  test('override path 의 plugins=[] (empty) → onLoad 가 pass-through', async () => {
    const plugin = css({ postcss: { plugins: [] } }); // empty 명시
    const { build, tracked } = makeMockBuild();
    plugin.setup(build);

    const hook = tracked.loadHooks[0]!.cb;
    const fs = await import('node:fs');
    const os = await import('node:os');
    const path = await import('node:path');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zntc-css-test-'));
    const file = path.join(dir, 'empty.css');
    fs.writeFileSync(file, 'a { b: c; }');

    try {
      const result = (await hook({ path: file })) as { contents: string };
      // empty plugins → round-trip 회피 (zero-config path 진입). config 없으면 pass-through.
      expect(result.contents).toBe('a { b: c; }');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
