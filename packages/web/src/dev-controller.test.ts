import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  cleanupPostcssTempRoot,
  createAppDevController,
  prepareAppCssPipelineRoot,
  recordSassReverseDep,
} from './dev-controller.ts';

const fallbackRequire = createRequire(import.meta.url);

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-dev-controller-'));
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
    // tempRoot 안에 .module.zntc.css 가 emit, 절대 path 로 반환.
    expect(result.generatedCssAbsPaths.some((p) => p.endsWith('.module.zntc.css'))).toBe(true);
    expect(result.tempRoot).toContain('zntc-postcss-dev-');
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
      { logLevel: 'silent', base: '/app', outdir: join(dir, '.zntc-dev') },
      dir,
      { mode: 'development' },
      deps(),
    );
    expect(c.root).toBe(dir);
    expect(c.outdir).toBe(join(dir, '.zntc-dev'));
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

  test('isCssLikeChange — CSS / Sass / postcss / CSS Module 전부 true, JS/HTML false (#3801)', () => {
    const c = controller();
    // 일반 CSS / Sass
    expect(c.isCssLikeChange('/x/style.css')).toBe(true);
    expect(c.isCssLikeChange('/x/style.scss')).toBe(true);
    expect(c.isCssLikeChange('/x/style.sass')).toBe(true);
    // CSS Modules / Sass Modules — drain 에서 full pipeline rebuild 가 필요한 케이스
    expect(c.isCssLikeChange('/x/style.module.css')).toBe(true);
    expect(c.isCssLikeChange('/x/style.module.scss')).toBe(true);
    // postcss config
    expect(c.isCssLikeChange('/x/postcss.config.js')).toBe(true);
    // 미지원 확장자 (.less / .styl / .pcss): 코드베이스에 pipeline 없음 → false. drift 가드.
    expect(c.isCssLikeChange('/x/style.less')).toBe(false);
    expect(c.isCssLikeChange('/x/style.styl')).toBe(false);
    expect(c.isCssLikeChange('/x/style.pcss')).toBe(false);
    // JS / HTML / asset — 명확히 false
    expect(c.isCssLikeChange('/x/main.ts')).toBe(false);
    expect(c.isCssLikeChange('/x/index.html')).toBe(false);
    expect(c.isCssLikeChange('/x/data.json')).toBe(false);
  });

  test('isSassOnlyChange — non-module .scss/.sass 만 true', () => {
    const c = controller();
    expect(c.isSassOnlyChange('/x/style.scss')).toBe(true);
    expect(c.isSassOnlyChange('/x/style.sass')).toBe(true);
    expect(c.isSassOnlyChange('/x/style.module.scss')).toBe(false);
    expect(c.isSassOnlyChange('/x/style.module.sass')).toBe(false);
    expect(c.isSassOnlyChange('/x/style.css')).toBe(false);
  });

  // #71: 실제 sass @use 컴파일로 reverse-dep 맵이 채워지는지(partial → 그것을 쓰는 root scss).
  // isSassOnlyChange 는 이 맵을 toTemp 후 조회하므로, 맵이 맞으면 fast-path 라우팅도 정확하다.
  test('prepareAppCssPipelineRoot — @use partial 의 reverse-dep 을 채운다(#71)', async () => {
    touch('src/style.scss', "@use './vars';\n.x { color: vars.$c; }\n");
    touch('src/_vars.scss', '$c: red;\n');
    const reverseDep = new Map<string, Set<string>>();
    const result = await prepareAppCssPipelineRoot(
      dir,
      join(dir, 'dist'),
      { mode: 'development' },
      'silent',
      'dev',
      deps(),
      { sassReverseDep: reverseDep },
    );
    expect(result).not.toBeNull();
    if (!result) return;
    const varsTemp = join(result.tempRoot, 'src', '_vars.scss');
    const styleTemp = join(result.tempRoot, 'src', 'style.scss');
    // _vars.scss 의 dependent 에 style.scss — partial 변경 시 style 을 재컴파일하도록.
    expect(reverseDep.get(varsTemp)?.has(styleTemp)).toBe(true);
    // self(style)는 reverse 에서 제외.
    expect(reverseDep.has(styleTemp)).toBe(false);
    cleanupPostcssTempRoot(result.tempRoot);
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

describe('recordSassReverseDep (#71)', () => {
  test('reverse-dep 구축 + self 제외 + 누적', () => {
    const map = new Map<string, Set<string>>();
    const style = '/t/style.scss';
    // loadedUrls 에 self(style) 도 포함되지만 reverse 에서 제외돼야 한다.
    recordSassReverseDep(map, style, [pathToFileURL('/t/_vars.scss'), pathToFileURL(style)]);
    expect(map.get('/t/_vars.scss')?.has(style)).toBe(true);
    expect(map.has(style)).toBe(false); // self 제외 — style 이 자기 자신의 dep 으로 기록되지 않음

    // 다른 root 가 같은 partial 을 import → dependents 누적.
    const theme = '/t/theme.scss';
    recordSassReverseDep(map, theme, [pathToFileURL('/t/_vars.scss')]);
    expect(map.get('/t/_vars.scss')?.size).toBe(2);
    expect(map.get('/t/_vars.scss')?.has(theme)).toBe(true);
  });
});
