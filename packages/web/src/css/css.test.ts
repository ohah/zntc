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
