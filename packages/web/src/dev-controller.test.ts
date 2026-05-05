import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  cleanupPostcssTempRoot,
  createAppDevController,
  prepareAppCssPipelineRoot,
} from './dev-controller.ts';

const fallbackRequire = createRequire(import.meta.url);

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zts-dev-controller-'));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function touch(rel: string, content = ''): string {
  const path = join(dir, rel);
  mkdirSync(join(path, '..'), { recursive: true });
  writeFileSync(path, content);
  return path;
}

function deps(): { fallbackRequire: typeof fallbackRequire; cliNodeModules: string } {
  // node_modules 가 없는 fixture — symlink 안 만들어지지만 prepareAppCssPipelineRoot
  // 가 그 path 의 존재만 보고 skip 하므로 빈 string 도 OK.
  return { fallbackRequire, cliNodeModules: '' };
}

describe('prepareAppCssPipelineRoot', () => {
  test('postcss config 도 없고 .scss/.module.css 도 없으면 null', async () => {
    touch('src/main.ts', 'console.log(1);');
    const result = await prepareAppCssPipelineRoot(
      dir,
      join(dir, 'dist'),
      { mode: 'development' },
      'silent',
      'dev',
      deps(),
    );
    expect(result).toBeNull();
  });

  test('.module.css 가 있으면 generated path 반환', async () => {
    touch('src/main.ts', `import "./button.module.css";`);
    touch('src/button.module.css', `.btn { color: red; }`);
    const result = await prepareAppCssPipelineRoot(
      dir,
      join(dir, 'dist'),
      { mode: 'development' },
      'silent',
      'dev',
      deps(),
    );
    expect(result).not.toBeNull();
    if (!result) return;
    // tempRoot 안에 .module.zts.css 가 emit, 절대 path 로 반환.
    expect(result.generatedCssAbsPaths.some((p) => p.endsWith('.module.zts.css'))).toBe(true);
    expect(result.tempRoot).toContain('zts-postcss-dev-');
    cleanupPostcssTempRoot(result.tempRoot);
  });

  test('F1+F2 cache 가 두 번째 호출에 재사용', async () => {
    touch('src/main.ts', `import "./a.module.css";`);
    touch('src/a.module.css', '.a { color: red; }');

    const first = await prepareAppCssPipelineRoot(
      dir,
      join(dir, 'dist'),
      { mode: 'development' },
      'silent',
      'dev',
      deps(),
    );
    expect(first).not.toBeNull();
    if (!first) return;

    const second = await prepareAppCssPipelineRoot(
      dir,
      join(dir, 'dist'),
      { mode: 'development' },
      'silent',
      'dev',
      deps(),
      { existingTempRoot: first.tempRoot, dirtyPaths: [], cache: first.cache },
    );
    expect(second).not.toBeNull();
    if (!second) return;
    expect(second.tempRoot).toBe(first.tempRoot);
    cleanupPostcssTempRoot(first.tempRoot);
  });
});

describe('createAppDevController', () => {
  function controller() {
    return createAppDevController({ logLevel: 'silent' }, dir, { mode: 'development' }, deps());
  }

  test('base / outdir / root 가 정확히 노출', () => {
    const c = createAppDevController(
      { logLevel: 'silent', base: '/app', outdir: join(dir, '.zts-dev') },
      dir,
      { mode: 'development' },
      deps(),
    );
    expect(c.root).toBe(dir);
    expect(c.outdir).toBe(join(dir, '.zts-dev'));
    expect(c.base).toBe('/app/');
  });

  test('base 누락 시 / 로 default', () => {
    const c = controller();
    expect(c.base).toBe('/');
  });

  test('isPostcssConfig — postcss 표준 config 이름 인식', () => {
    const c = controller();
    expect(c.isPostcssConfig('/x/postcss.config.js')).toBe(true);
    expect(c.isPostcssConfig('/x/postcss.config.cjs')).toBe(true);
    expect(c.isPostcssConfig('/x/.postcssrc.json')).toBe(true);
    expect(c.isPostcssConfig('/x/main.ts')).toBe(false);
  });

  test('isCssOnlyChange — css/scss true, module variant false', () => {
    const c = controller();
    expect(c.isCssOnlyChange('/x/style.css')).toBe(true);
    expect(c.isCssOnlyChange('/x/style.scss')).toBe(true);
    expect(c.isCssOnlyChange('/x/style.sass')).toBe(true);
    // CSS Modules 는 JS proxy 도 재생성 필요 — false (full reload).
    expect(c.isCssOnlyChange('/x/style.module.css')).toBe(false);
    expect(c.isCssOnlyChange('/x/style.module.scss')).toBe(false);
    expect(c.isCssOnlyChange('/x/main.ts')).toBe(false);
  });

  test('isSassOnlyChange — non-module .scss/.sass 만 true', () => {
    const c = controller();
    expect(c.isSassOnlyChange('/x/style.scss')).toBe(true);
    expect(c.isSassOnlyChange('/x/style.sass')).toBe(true);
    expect(c.isSassOnlyChange('/x/style.module.scss')).toBe(false);
    expect(c.isSassOnlyChange('/x/style.module.sass')).toBe(false);
    expect(c.isSassOnlyChange('/x/style.css')).toBe(false);
  });

  test('hrefFor — .css 는 base + rel, 그 외엔 primary fallback', () => {
    const c = controller();
    expect(c.hrefFor(join(dir, 'style.css'))).toBe('/style.css');
    // primary 없으면 style.css fallback.
    expect(c.hrefFor(join(dir, 'main.ts'))).toBe('/style.css');
  });

  test('rebuildScssIncremental — pipelineRoot 없으면 null', async () => {
    const c = controller();
    expect(await c.rebuildScssIncremental(join(dir, 'x.scss'))).toBeNull();
  });
});
