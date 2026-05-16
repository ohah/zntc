import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// P0-1: code splitting 시 JS 청크별로 CSS 를 분리 emit 하는지 검증.
// 기존 동작(단일 파일 번들 = entry 당 하나의 CSS)은 회귀로 함께 검증한다.
// 관련: #3321 (일반 청크 백로그 P0)

const cssFiles = (outs: { path: string; text: string }[]) =>
  outs.filter((o) => o.path.endsWith('.css'));

describe('CSS code splitting (per-chunk CSS)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('동적 import 청크마다 자기 CSS 만 분리된다', async () => {
    const fixture = await createFixture({
      'entry.ts': `
        import './common.css';
        export async function load(which: string) {
          if (which === 'a') return (await import('./route-a')).default;
          return (await import('./route-b')).default;
        }
      `,
      'route-a.ts': `import './a.css';\nexport default "ROUTE_A";`,
      'route-b.ts': `import './b.css';\nexport default "ROUTE_B";`,
      'common.css': `.common { color: black; }`,
      'a.css': `.route-a { color: red; }`,
      'b.css': `.route-b { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const css = cssFiles(result.outputFiles!);
    // 최소 3개 청크(entry/route-a/route-b)로 CSS 가 분리되어야 한다.
    expect(css.length).toBeGreaterThanOrEqual(3);

    const aCss = css.find((c) => c.text.includes('color: red'));
    const bCss = css.find((c) => c.text.includes('color: blue'));
    const commonCss = css.find((c) => c.text.includes('color: black'));
    expect(aCss).toBeDefined();
    expect(bCss).toBeDefined();
    expect(commonCss).toBeDefined();

    // 각 청크 CSS 는 자기 규칙만 포함 (다른 라우트 CSS 가 섞이면 안 됨)
    expect(aCss!.text).not.toContain('color: blue');
    expect(aCss!.text).not.toContain('color: black');
    expect(bCss!.text).not.toContain('color: red');
    expect(bCss!.text).not.toContain('color: black');

    // 서로 다른 파일이어야 함
    expect(aCss!.path).not.toBe(bCss!.path);
  });

  test('여러 라우트가 공유하는 CSS 는 중복 없이 한 청크에만 들어간다', async () => {
    const fixture = await createFixture({
      'entry.ts': `
        export async function load(which: string) {
          if (which === 'a') return (await import('./route-a')).default;
          return (await import('./route-b')).default;
        }
      `,
      'route-a.ts': `import './shared.css';\nimport './a.css';\nexport default "A";`,
      'route-b.ts': `import './shared.css';\nimport './b.css';\nexport default "B";`,
      'shared.css': `.shared { color: green; }`,
      'a.css': `.a { color: red; }`,
      'b.css': `.b { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const css = cssFiles(result.outputFiles!);
    const sharedHits = css.filter((c) => c.text.includes('color: green'));
    // shared.css 규칙은 정확히 한 청크 CSS 에만 존재해야 한다 (중복 금지)
    expect(sharedHits.length).toBe(1);
  });

  // P0-4 (#3321): 서로 다른 청크의 CSS 가 같은 CSS 를 @import 하면, 그
  // 공유 CSS 는 각 청크에 모두 존재해야 한다 (한 청크에만 inline 되면
  // 다른 라우트 로드 시 스타일 누락).
  test('cross-chunk @import: 공유 CSS 가 양쪽 청크에 모두 들어간다', async () => {
    const fixture = await createFixture({
      'entry.ts': `
        export async function load(which: string) {
          if (which === 'a') return (await import('./route-a')).default;
          return (await import('./route-b')).default;
        }
      `,
      'route-a.ts': `import './a.css';\nexport default "A";`,
      'route-b.ts': `import './b.css';\nexport default "B";`,
      'a.css': `@import "./shared.css";\n.a { color: red; }`,
      'b.css': `@import "./shared.css";\n.b { color: blue; }`,
      'shared.css': `.shared { color: gold; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const css = cssFiles(result.outputFiles!);
    const aCss = css.find((c) => c.text.includes('color: red'))!;
    const bCss = css.find((c) => c.text.includes('color: blue'))!;
    expect(aCss).toBeDefined();
    expect(bCss).toBeDefined();
    // 두 라우트 청크 모두 @import 한 shared 규칙을 포함해야 함
    expect(aCss.text).toContain('.shared');
    expect(bCss.text).toContain('.shared');
    // @import 규칙 자체는 제거(인라인)
    expect(aCss.text).not.toContain('@import');
    expect(bCss.text).not.toContain('@import');
  });

  test('순환 @import (a↔b): 무한루프 없이 양쪽 규칙 1회씩 인라인', async () => {
    const fixture = await createFixture({
      'entry.ts': `import './a.css';\nconsole.log("x");`,
      'a.css': `@import "./b.css";\n.ca { color: red; }`,
      'b.css': `@import "./a.css";\n.cb { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const css = cssFiles(result.outputFiles!);
    expect(css.length).toBe(1);
    const t = css[0].text;
    expect(t).toContain('.ca');
    expect(t).toContain('.cb');
    expect(t).not.toContain('@import');
    // 순환이어도 각 규칙 정확히 1회 (중복 emit 없음)
    const ca = t.match(/\.ca\b/g);
    const cb = t.match(/\.cb\b/g);
    expect(ca).not.toBeNull();
    expect(cb).not.toBeNull();
    expect(ca!.length).toBe(1);
    expect(cb!.length).toBe(1);
  });

  test('@import 전용 CSS(규칙 없음): 대상 CSS 가 인라인된다', async () => {
    const fixture = await createFixture({
      'entry.ts': `import './imports.css';\nconsole.log("x");`,
      'imports.css': `@import "./actual.css";\n/* only a comment */`,
      'actual.css': `.real { color: teal; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const css = cssFiles(result.outputFiles!);
    expect(css.some((c) => c.text.includes('color: teal'))).toBe(true);
    expect(css.every((c) => !c.text.includes('@import'))).toBe(true);
  });

  test('CSS 없는 청크는 CSS 파일을 만들지 않는다', async () => {
    const fixture = await createFixture({
      'entry.ts': `
        export async function load() {
          return (await import('./route-nocss')).default;
        }
      `,
      'route-nocss.ts': `export default 42;`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    expect(cssFiles(result.outputFiles!).length).toBe(0);
  });

  test('회귀: 비-splitting 단일 번들은 entry 당 단일 CSS 그대로', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.css';\nimport './b.css';\nconsole.log("x");`,
      'a.css': `.a { color: red; }`,
      'b.css': `.b { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      splitting: false,
    });

    const css = cssFiles(result.outputFiles!);
    expect(css.length).toBe(1);
    expect(css[0].text).toContain('color: red');
    expect(css[0].text).toContain('color: blue');
  });

  test('manualChunks 로 분리된 청크의 CSS 도 따라 분리된다', async () => {
    const fixture = await createFixture({
      'entry.ts': `
        import { v } from './vendor';
        import { a } from './app';
        console.log(v, a);
      `,
      'vendor.ts': `import './vendor.css';\nexport const v = 1;`,
      'app.ts': `import './app.css';\nexport const a = 2;`,
      'vendor.css': `.vendor { color: red; }`,
      'app.css': `.app { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
      manualChunks: (id: string) => (id.includes('vendor') ? 'vendor' : null),
    });

    const css = cssFiles(result.outputFiles!);
    const vendorCss = css.find((c) => c.text.includes('.vendor'));
    const appCss = css.find((c) => c.text.includes('.app'));
    expect(vendorCss).toBeDefined();
    expect(appCss).toBeDefined();
    expect(vendorCss!.path).not.toBe(appCss!.path);
    expect(vendorCss!.text).not.toContain('.app');
  });

  // P0-2: css_names 패턴 충실 적용. 기본 "[name]" 은 안정 파일명(강제 hash
  // 없음 — app-builder HTML link rewrite 호환). [hash] 동작은 css_emitter.zig
  // applyCssChunkName 단위테스트가 커버 (build() JS API 에 cssNames 미노출).
  test('동일 입력 재빌드 시 청크 CSS 파일명이 결정적', async () => {
    const files = {
      'entry.ts': `export async function load(){ return (await import('./r')).default; }`,
      'r.ts': `import './s.css';\nexport default 1;`,
      's.css': `.s { color: teal; }`,
    };
    const f1 = await createFixture(files);
    const r1 = await build({ entryPoints: [join(f1.dir, 'entry.ts')], splitting: true });
    const p1 = cssFiles(r1.outputFiles!).find((c) => c.text.includes('teal'))!.path;
    await f1.cleanup();

    const f2 = await createFixture(files);
    cleanup = f2.cleanup;
    const r2 = await build({ entryPoints: [join(f2.dir, 'entry.ts')], splitting: true });
    const p2 = cssFiles(r2.outputFiles!).find((c) => c.text.includes('teal'))!.path;

    expect(p1).toBe(p2);
  });

  // #3330: Sass/CSS Modules 는 `import "./x.scss"` 를 `.css.js` proxy
  // (`import "./x.css"` 한 줄) 로 rewrite 한다. proxy JS 모듈은 tree-shake
  // 되어 chunk 미할당이 되는데, splitting 경로가 그 너머 CSS 를 놓치면 안 됨.
  test('side-effect proxy(.css.js) 체인 너머 CSS 도 분리 emit 된다', async () => {
    const fixture = await createFixture({
      'entry.ts': `import './style.css.js';\nconsole.log("x");`,
      'style.css.js': `import './style.css';`,
      'style.css': `.proxied { color: rebeccapurple; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const css = cssFiles(result.outputFiles!);
    expect(css.length).toBeGreaterThanOrEqual(1);
    expect(css.some((c) => c.text.includes('rebeccapurple'))).toBe(true);
  });

  test('다단계 proxy 체인(JS→JS→CSS) 너머 CSS 도 수집된다', async () => {
    const fixture = await createFixture({
      'entry.ts': `import './p1.js';\nconsole.log("x");`,
      'p1.js': `import './p2.js';`,
      'p2.js': `import './deep.css';`,
      'deep.css': `.deep { color: seagreen; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const css = cssFiles(result.outputFiles!);
    expect(css.some((c) => c.text.includes('seagreen'))).toBe(true);
  });

  // P0-3②: 동적 import 된 청크는 자기 CSS 를 런타임 <link> 로 주입한다.
  test('동적 청크 JS 에 CSS <link> 주입 prologue 가 들어간다', async () => {
    const fixture = await createFixture({
      'entry.ts': `
        export async function load() {
          return (await import('./route-a')).default;
        }
      `,
      'route-a.ts': `import './a.css';\nexport default "ROUTE_A_MARKER";`,
      'a.css': `.route-a { color: crimson; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const outs = result.outputFiles!;
    const aCss = outs.find((o) => o.path.endsWith('.css') && o.text.includes('crimson'))!;
    expect(aCss).toBeDefined();
    const cssBase = aCss.path.split('/').pop()!;

    // route-a 모듈을 담은 JS 청크에 link 주입 prologue + 정확한 CSS basename
    const routeChunk = outs.find(
      (o) => o.path.endsWith('.js') && o.text.includes('ROUTE_A_MARKER'),
    )!;
    expect(routeChunk).toBeDefined();
    expect(routeChunk.text).toContain('document.createElement("link")');
    expect(routeChunk.text).toContain('rel="stylesheet"');
    expect(routeChunk.text).toContain(`new URL("./${cssBase}",import.meta.url)`);
    expect(routeChunk.text).toContain('typeof document!=="undefined"');

    // entry 청크(자기 CSS 없음)에는 주입이 없어야 함
    const entryChunk = outs.find(
      (o) => o.path.endsWith('.js') && o.text.includes('async function load'),
    )!;
    expect(entryChunk).toBeDefined();
    expect(entryChunk.text).not.toContain('document.createElement("link")');
  });
});
