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

  // P0-2: 청크 CSS 는 자기 content-hash 를 가져야 한다 (JS 해시 종속 X).
  test('청크 CSS 파일명에 content-hash 가 붙는다', async () => {
    const fixture = await createFixture({
      'entry.ts': `
        export async function load() {
          return (await import('./route-a')).default;
        }
      `,
      'route-a.ts': `import './a.css';\nexport default 1;`,
      'a.css': `.route-a { color: red; }`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      splitting: true,
    });

    const css = cssFiles(result.outputFiles!);
    const aCss = css.find((c) => c.text.includes('color: red'))!;
    expect(aCss).toBeDefined();
    // <stem>-<8 hex>.css 형태
    expect(aCss.path).toMatch(/-[0-9a-f]{8}\.css$/);
  });

  test('동일 입력 재빌드 시 청크 CSS 파일명(해시)이 결정적', async () => {
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

  test('CSS 내용이 다르면 해시가 다르다', async () => {
    const mk = (rule: string) => ({
      'entry.ts': `export async function load(){ return (await import('./r')).default; }`,
      'r.ts': `import './s.css';\nexport default 1;`,
      's.css': rule,
    });
    const fa = await createFixture(mk('.s { color: red; }'));
    const ra = await build({ entryPoints: [join(fa.dir, 'entry.ts')], splitting: true });
    const pa = cssFiles(ra.outputFiles!).find((c) => c.text.includes('color'))!.path;
    await fa.cleanup();

    const fb = await createFixture(mk('.s { color: blue; }'));
    cleanup = fb.cleanup;
    const rb = await build({ entryPoints: [join(fb.dir, 'entry.ts')], splitting: true });
    const pb = cssFiles(rb.outputFiles!).find((c) => c.text.includes('color'))!.path;

    expect(pa).not.toBe(pb);
  });
});
