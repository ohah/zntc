import { describe, it, expect, afterEach } from 'bun:test';
import { createFixture, runZntc } from './helpers';
import { join } from 'node:path';
import { readFile, readdir } from 'node:fs/promises';

describe('CSS Bundling', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it('single CSS import → separate .css file', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("hello");`,
      'style.css': `body { color: red; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    // JS 출력에 CSS import가 없어야 함
    const js = await readFile(outJs, 'utf-8');
    expect(js).toContain('console.log');
    expect(js).not.toContain('color: red');

    // CSS 파일이 생성되어야 함
    const cssPath = join(fixture.dir, 'index.css');
    const css = await readFile(cssPath, 'utf-8');
    expect(css).toContain('body { color: red; }');
  });

  it('@import chaining → inlined in correct order', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.css';\nconsole.log("hello");`,
      'a.css': `@import "./b.css";\nbody { color: red; }`,
      'b.css': `* { margin: 0; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // b.css가 a.css보다 먼저 나와야 함 (DFS 순서)
    const marginIdx = css.indexOf('margin: 0');
    const colorIdx = css.indexOf('color: red');
    expect(marginIdx).toBeGreaterThanOrEqual(0);
    expect(colorIdx).toBeGreaterThanOrEqual(0);
    expect(marginIdx).toBeLessThan(colorIdx);
    // @import 규칙은 제거되어야 함
    expect(css).not.toContain('@import');
  });

  it('deep @import chain (3 levels)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.css';`,
      'a.css': `@import "./b.css";\n.a { color: red; }`,
      'b.css': `@import "./c.css";\n.b { color: blue; }`,
      'c.css': `.c { color: green; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    const cIdx = css.indexOf('.c');
    const bIdx = css.indexOf('.b');
    const aIdx = css.indexOf('.a');
    expect(cIdx).toBeLessThan(bIdx);
    expect(bIdx).toBeLessThan(aIdx);
  });

  it('no CSS imports → no .css file generated', async () => {
    const fixture = await createFixture({
      'index.ts': `console.log("no css");`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    let hasCss = true;
    try {
      await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    } catch {
      hasCss = false;
    }
    expect(hasCss).toBe(false);
  });

  it('--loader:.css=empty → CSS ignored (existing behavior)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("hello");`,
      'style.css': `body { color: red; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs, '--loader:.css=empty']);

    // empty 로더 → CSS 파일 미생성
    let hasCss = true;
    try {
      await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    } catch {
      hasCss = false;
    }
    expect(hasCss).toBe(false);
  });

  it('multiple CSS imports from same JS', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.css';\nimport './b.css';\nconsole.log("hello");`,
      'a.css': `.a { color: red; }`,
      'b.css': `.b { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('.a { color: red; }');
    expect(css).toContain('.b { color: blue; }');
    // a.css가 b.css보다 먼저 (import 순서)
    expect(css.indexOf('.a')).toBeLessThan(css.indexOf('.b'));
  });

  it('CSS imported from nested JS module', async () => {
    const fixture = await createFixture({
      'index.ts': `import './components/button';\nconsole.log("app");`,
      'components/button.ts': `import './button.css';\nexport const Button = "btn";`,
      'components/button.css': `.button { padding: 8px; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('.button { padding: 8px; }');
  });

  it('CSS with @charset and comments before @import', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `@charset "UTF-8";\n/* header styles */\n@import "./header.css";\nbody { margin: 0; }`,
      'header.css': `header { display: flex; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('header { display: flex; }');
    expect(css).toContain('body { margin: 0; }');
    expect(css).not.toContain('@import');
  });

  it('duplicate CSS import is not duplicated in output', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.ts';\nimport './b.ts';`,
      'a.ts': `import './shared.css';\nexport const a = 1;`,
      'b.ts': `import './shared.css';\nexport const b = 2;`,
      'shared.css': `.shared { color: green; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // shared.css는 한 번만 나와야 함
    const firstIdx = css.indexOf('.shared');
    const secondIdx = css.indexOf('.shared', firstIdx + 1);
    expect(firstIdx).toBeGreaterThanOrEqual(0);
    expect(secondIdx).toBe(-1);
  });

  it('CSS-only entry (no JS logic) → still generates .css', async () => {
    const fixture = await createFixture({
      'index.ts': `import './global.css';`,
      'global.css': `html { font-size: 16px; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('html { font-size: 16px; }');

    // JS는 빈 IIFE (또는 최소 출력)
    const js = await readFile(outJs, 'utf-8');
    expect(js).not.toContain('font-size');
  });

  it('@import url() with single quotes', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `@import url('./reset.css');\n.main { display: flex; }`,
      'reset.css': `* { box-sizing: border-box; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('box-sizing: border-box');
    expect(css).toContain('.main { display: flex; }');
    expect(css).not.toContain('@import');
  });

  it('circular @import → no infinite loop, no duplication', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.css';`,
      'a.css': `@import "./b.css";\n.a { color: red; }`,
      'b.css': `@import "./a.css";\n.b { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    // 번들이 성공해야 함 (무한루프 X)
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('.a');
    expect(css).toContain('.b');
    // 각 클래스가 한 번만 등장
    const aFirst = css.indexOf('.a');
    const aSecond = css.indexOf('.a', aFirst + 2);
    expect(aSecond).toBe(-1);
  });

  it('@import with media query → specifier correctly extracted', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `@import "./print.css" print;\n.screen { display: block; }`,
      'print.css': `.print-only { display: none; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // print.css 내용이 인라인되어야 함
    expect(css).toContain('.print-only');
    expect(css).toContain('.screen');
    // @import 자체는 제거
    expect(css).not.toContain('@import');
  });

  it('non-existent CSS @import → build succeeds with error diagnostic', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("ok");`,
      'style.css': `@import "./missing.css";\nbody { color: red; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    // 에러가 발생하거나 경고가 있어야 함 (missing.css 없음)
    const hasError = result.exitCode !== 0 || result.stderr.includes('missing.css');
    expect(hasError).toBe(true);
  });

  // #4466: CSS url() 자산은 해시 파일로 방출되고 url 이 재작성된다.
  // 이 테스트는 예전에 `expect(css).toContain('url(./img/hero.png)')` 로
  // "원문 보존" 을 기대했는데, 그건 dangling 404 버그(#4466)를 명세로 박제한
  // 것이었다. 실제로는 참조 대상이 fixture 에 없어서 "재작성 안 됨" 이 우연히
  // 통과했을 뿐이다.

  it('#4466 CSS url() 자산 → 해시 파일 방출 + url 재작성', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `.bg { background: url(./img/hero.png) no-repeat; }`,
      // inline limit(4096) 초과 → 별도 파일로 방출되어야 함
      'img/hero.png': 'X'.repeat(5000),
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // 원문 경로는 사라지고, 해시가 붙은 방출 자산을 가리켜야 한다
    expect(css).not.toContain('url(./img/hero.png)');
    expect(css).toMatch(/url\("\.\/hero-[0-9a-f]{8}\.png"\)/);

    // 실제 자산 파일이 out.js 옆에 방출됐는지
    const emitted = (await readdir(fixture.dir)).filter((f) => /^hero-[0-9a-f]{8}\.png$/.test(f));
    expect(emitted).toHaveLength(1);
  });

  it('#4466 CSS url() 작은 자산 → data URL 인라인', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `.bg { background: url(./img/tiny.png); }`,
      'img/tiny.png': 'tiny',
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('url("data:image/png;base64,');
  });

  it('#4466 해석 불가 url() → 경고 + 원문 유지 (빌드는 성공)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      // hero.png 를 fixture 에 두지 않는다 — 배포 스크립트가 나중에 복사하는 흔한 패턴
      'style.css': `.bg { background: url(./img/hero.png) no-repeat; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    // 하드 에러가 아니라 경고 — 기존에 빌드되던 프로젝트를 깨지 않는다
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toContain('Cannot resolve CSS url()');

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('url(./img/hero.png)');
  });

  it('#4466 external / SVG fragment / 절대경로 url() 은 건드리지 않는다', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': [
        `.a { background: url(https://cdn.example.com/a.png); }`,
        `.b { filter: url(#blur); }`,
        `.c { background: url(/public/keep.png); }`,
        `.d { background: url(data:image/gif;base64,R0lGOD); }`,
      ].join('\n'),
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('url(https://cdn.example.com/a.png)');
    expect(css).toContain('url(#blur)'); // SVG filter 참조 — 파일이 아니다
    expect(css).toContain('url(/public/keep.png)'); // public 디렉토리 규약
    expect(css).toContain('url(data:image/gif;base64,R0lGOD)');
  });

  it('CSS imported from dynamically imported module', async () => {
    const fixture = await createFixture({
      'index.ts': `const mod = import('./lazy.ts');\nconsole.log("main");`,
      'lazy.ts': `import './lazy.css';\nexport const x = 1;`,
      'lazy.css': `.lazy { opacity: 0; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    // dynamic import의 CSS도 번들에 포함될 수 있음 (단일 엔트리이므로)
    const cssExists = await readFile(join(fixture.dir, 'index.css'), 'utf-8').catch(() => null);
    if (cssExists) {
      expect(cssExists).toContain('.lazy');
    }
    // JS는 정상 생성
    const js = await readFile(outJs, 'utf-8');
    expect(js).toContain('main');
  });

  it('--outdir with CSS', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("outdir test");`,
      'style.css': `.test { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, 'dist');
    await runZntc([
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '--splitting',
      '--format=esm',
      '--outdir',
      outDir,
    ]);

    const css = await readFile(join(outDir, 'index.css'), 'utf-8');
    expect(css).toContain('.test { color: blue; }');

    const js = await readFile(join(outDir, 'index.js'), 'utf-8');
    expect(js).toContain('console.log');
  });

  it('CSS with only whitespace/comments after @import stripping → no .css file', async () => {
    const fixture = await createFixture({
      'index.ts': `import './wrapper.css';`,
      'wrapper.css': `@import "./actual.css";\n/* just a wrapper */\n`,
      'actual.css': `.actual { color: green; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('.actual { color: green; }');
    // wrapper.css는 @import 외에 주석뿐이므로 그 부분은 무시됨
    expect(css).not.toContain('@import');
  });

  it('CSS with multiple @import then rules', async () => {
    const fixture = await createFixture({
      'index.ts': `import './main.css';`,
      'main.css': `@import "./vars.css";\n@import "./reset.css";\n@import "./base.css";\n.main { color: black; }`,
      'vars.css': `:root { --c: red; }`,
      'reset.css': `* { margin: 0; }`,
      'base.css': `body { font: 16px sans-serif; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // 순서: vars → reset → base → main
    const varsIdx = css.indexOf('--c: red');
    const resetIdx = css.indexOf('margin: 0');
    const baseIdx = css.indexOf('font: 16px');
    const mainIdx = css.indexOf('color: black');
    expect(varsIdx).toBeGreaterThanOrEqual(0);
    expect(resetIdx).toBeGreaterThan(varsIdx);
    expect(baseIdx).toBeGreaterThan(resetIdx);
    expect(mainIdx).toBeGreaterThan(baseIdx);
    expect(css).not.toContain('@import');
  });

  it('CSS with special characters in selectors and values', async () => {
    const fixture = await createFixture({
      'index.ts': `import './special.css';`,
      'special.css': `.cls\\:hover { color: red; }\n[data-attr="@import"] { display: none; }\n.emoji { content: "\\1F600"; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // @import가 selector/value 안에 있으면 추출되면 안 됨
    expect(css).toContain('[data-attr="@import"]');
    expect(css).toContain('emoji');
  });

  it('empty CSS file → no .css output', async () => {
    const fixture = await createFixture({
      'index.ts': `import './empty.css';\nconsole.log("hi");`,
      'empty.css': ``,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    let hasCss = true;
    try {
      await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    } catch {
      hasCss = false;
    }
    expect(hasCss).toBe(false);
  });

  it('CSS with @import inside a rule block → not extracted', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `.parent {\n  color: red;\n}\n/* @import inside comment: @import "./nope.css"; */\n.child { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('.parent');
    expect(css).toContain('.child');
  });

  it('CSS with BOM (byte order mark)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './bom.css';`,
      'bom.css': `\uFEFF@import "./base.css";\n.bom { color: red; }`,
      'base.css': `.base { margin: 0; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('.bom');
    // base.css가 인라인되었으면 OK, 안 되었어도 bom.css 자체는 출력
    expect(css.length).toBeGreaterThan(0);
  });

  it('large CSS file with many rules', async () => {
    // 1000개 rule 생성
    const rules = Array.from(
      { length: 1000 },
      (_, i) => `.c${i} { color: hsl(${i}, 50%, 50%); }`,
    ).join('\n');
    const fixture = await createFixture({
      'index.ts': `import './big.css';`,
      'big.css': rules,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('.c0');
    expect(css).toContain('.c999');
    // 모든 rule이 포함되어야 함
    expect(css.split('.c').length - 1).toBe(1000);
  });

  it('re-export chain: JS re-exports from module that imports CSS', async () => {
    const fixture = await createFixture({
      'index.ts': `export { x } from './lib.ts';`,
      'lib.ts': `import './lib.css';\nexport const x = 42;`,
      'lib.css': `.lib { padding: 10px; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('.lib { padding: 10px; }');
  });

  it('CSS and JS interleaved imports preserve CSS order', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.css';\nimport { x } from './util.ts';\nimport './b.css';\nconsole.log(x);`,
      'util.ts': `export const x = 1;`,
      'a.css': `.a { order: 1; }`,
      'b.css': `.b { order: 2; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css.indexOf('.a')).toBeLessThan(css.indexOf('.b'));
  });

  // ── external @import URL preservation (#3321 P0-3 cross-chunk @import 재작성) ──
  // esbuild parity: protocol-prefixed (`http:`/`https:`) 또는 protocol-relative
  // (`//`) @import 는 *resolve 대상이 아님* — bundler 가 graph 에 등록 시도
  // 하면 "Cannot resolve module" 로 실패. 정석은 external 로 인식해 출력
  // CSS 상단에 그대로 보존 (런타임 fetch). 멀티 청크 / 멀티 importer 시에도
  // 각 출력에서 dedup 된 1회 emit.
  it('external http(s) @import URL → resolve 시도 안 함 + 출력에 보존', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("ok");`,
      'style.css':
        `@import "https://fonts.googleapis.com/css?family=Inter";\n` +
        `.btn { font-family: "Inter"; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    // 빌드는 성공해야 함 (esbuild parity)
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // external @import URL 은 출력에 보존
    expect(css).toContain('@import "https://fonts.googleapis.com/css?family=Inter"');
    expect(css).toContain('.btn');
    // CSS spec: 모든 @import 는 모든 일반 규칙보다 먼저 와야 함
    expect(css.indexOf('@import')).toBeLessThan(css.indexOf('.btn'));
  });

  it('protocol-relative // @import URL → 보존', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("ok");`,
      'style.css': `@import "//cdn.example.com/reset.css";\n.app { color: red; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('@import "//cdn.example.com/reset.css"');
  });

  it('external + 일반 @import 혼합 → external 보존, 일반 inline', async () => {
    const fixture = await createFixture({
      'index.ts': `import './main.css';\nconsole.log("ok");`,
      'main.css':
        `@import "https://example.com/normalize.css";\n` +
        `@import "./local.css";\n` +
        `.main { color: black; }`,
      'local.css': `.local { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // external 보존
    expect(css).toContain('@import "https://example.com/normalize.css"');
    // 일반 @import 는 inline 됐으므로 제거
    expect(css).not.toContain('./local.css');
    expect(css).toContain('.local');
    expect(css).toContain('.main');
    // external @import 이 일반 규칙보다 앞에 있어야 함
    expect(css.indexOf('@import')).toBeLessThan(css.indexOf('.main'));
  });

  // code-review max post-review 회귀 가드.
  it('uppercase HTTPS scheme → external 로 인식, resolve 실패 안 함', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("ok");`,
      'style.css': `@import "HTTPS://cdn.example.com/x.css";\n.a {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);
    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('@import "HTTPS://cdn.example.com/x.css"');
  });

  it('external @import + media query → media clause 보존 (semantic preserve)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("ok");`,
      'style.css':
        `@import "https://cdn/print.css" print;\n` +
        `@import "https://cdn/screen.css" screen and (max-width: 600px);\n` +
        `.app {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // print 키워드 / media query 가 specifier 뒤에 살아있어야 함
    expect(css).toMatch(/@import\s+"https:\/\/cdn\/print\.css"\s+print\s*;/);
    expect(css).toMatch(
      /@import\s+"https:\/\/cdn\/screen\.css"\s+screen\s+and\s+\(max-width:\s*600px\)\s*;/,
    );
  });

  it('순수 external @import 만 있는 CSS → 같은 @import 가 한 번만 출력 (double-emit 회피)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './only-ext.css';\nconsole.log("ok");`,
      'only-ext.css': `@import "https://cdn/normalize.css";`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    const matches = css.match(/@import\s+"https:\/\/cdn\/normalize\.css"/g) ?? [];
    expect(matches.length).toBe(1);
  });

  it('같은 external URL 을 여러 모듈이 @import → chunk 내 1회 emit (dedup)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.css';\nimport './b.css';\nconsole.log("ok");`,
      'a.css': `@import "https://cdn/normalize.css";\n.a {}`,
      'b.css': `@import "https://cdn/normalize.css";\n.b {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    const matches = css.match(/@import\s+"https:\/\/cdn\/normalize\.css"/g) ?? [];
    expect(matches.length).toBe(1);
    expect(css).toContain('.a');
    expect(css).toContain('.b');
  });

  it('data: URL with embedded escaped quote — backslash escape 보존 + emit 시 hex escape', async () => {
    // scanner 가 `\"` 를 string terminator 로 오인하면 specifier 절단 → broken CSS.
    // findClosingQuote 가 `\<char>` 를 escape sequence 로 인식해 다음 1바이트 skip
    // 해야 한다. emitter 의 appendCssStringEscaped 가 `"` → `\22 ` 로 변환해
    // round-trip 정확성 유지.
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("ok");`,
      'style.css': `@import "data:text/css,body{content:\\"x\\"}";\n.app {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // specifier 가 절단되지 않고 끝까지 보존 + closing `}` 와 `";` 가 모두 같은 라인에
    expect(css).toContain('@import "data:text/css,body{content:');
    expect(css).toContain('}";');
    // 백슬래시 escape 가 CSS hex escape 로 변환됨 (\22 는 `"`, \\ 는 `\`)
    expect(css).toMatch(/\\22/);
    // 절단 후 dangling 본문이 emit 되지 않음 — 닫는 quote 다음에 `";\n` 만
    const importLine = css.match(/^@import[^\n]+/m);
    expect(importLine?.[0].endsWith('";')).toBe(true);
  });

  // ── #3747 CSS @charset / @layer top-of-file 선언 보존 ──
  // strip_end 가 마지막 @import 의 end 까지 전체를 잘라 그 앞의 @charset / 바
  // @layer 선언이 silent drop. 루트커즈 fix: scanner 가 두 종류도 캡처하고
  // emitter 가 본문 앞에 보존 emit. esbuild parity.
  it('#3747 @charset "UTF-8"; 가 출력에 보존된다 (silent drop 회귀)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `@charset "UTF-8";\n@import "./other.css";\nbody { color: red; }`,
      'other.css': `.other {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // @charset 은 파일의 첫 byte 여야 함 (CSS spec)
    expect(css.trimStart().startsWith('@charset "UTF-8"')).toBe(true);
    expect(css).toContain('.other');
    expect(css).toContain('color: red');
  });

  it('#3747 bare @layer reset, base, theme; 가 출력에 보존된다', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `@layer reset, base, theme;\n@import "./other.css";\n.app { color: red; }`,
      'other.css': `.other {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // @layer 선언이 출력에 살아있어야 함 — cascade layer 순서 정의용
    expect(css).toMatch(/@layer\s+reset\s*,\s*base\s*,\s*theme/);
    // 본문 보다 앞에 위치
    expect(css.indexOf('@layer')).toBeLessThan(css.indexOf('.app'));
  });

  it('#3747 @charset + @layer + external @import 혼합 → 모두 보존, 순서 정확', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css':
        `@charset "UTF-8";\n` +
        `@layer reset, base;\n` +
        `@import "https://cdn/x.css";\n` +
        `.app { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toContain('@charset "UTF-8"');
    expect(css).toMatch(/@layer\s+reset\s*,\s*base/);
    expect(css).toContain('@import "https://cdn/x.css"');
    expect(css).toContain('.app');
    // 순서 invariant: charset → (layer/import 둘 다 가능) → body
    expect(css.indexOf('@charset')).toBeLessThan(css.indexOf('.app'));
    expect(css.indexOf('@layer')).toBeLessThan(css.indexOf('.app'));
    expect(css.indexOf('@import')).toBeLessThan(css.indexOf('.app'));
  });

  it('#3747 multi-line @layer (`@layer\\nreset, base;`) → newline boundary 인식, 캡처 + 후속 @import 정상', async () => {
    // code-review max Angle B1: 옛 boundary 가드가 `\n` 미인식 → break 로
    // @layer + 후속 @import 둘 다 silent drop. fix 후 multi-line valid CSS 도
    // 정상 캡처되어야 한다.
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css': `@layer\nreset, base;\n@import "./other.css";\n.app {}`,
      'other.css': `.other {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // @layer 캡처 (newline 으로 분리된 형식)
    expect(css).toMatch(/@layer\s+reset\s*,\s*base/);
    // @import 가 inline 됨 — 캡처 가드가 break 로 빠지지 않아 후속 @import 까지 처리
    expect(css).toContain('.other');
    // raw `@import "./other.css"` 가 출력에 남지 않아야 함 (inline 됐다는 증거)
    expect(css).not.toContain('@import "./other.css"');
  });

  it('#3747 @charsetXYZ (word-boundary 없는 fake at-rule) → charset 으로 캡처 안 됨', async () => {
    // code-review max Angle B2: `@charsetXYZ "evil";` 가 `@charset` 으로
    // 오인 캡처되어 출력 상단 hoist 되던 버그. word-boundary 가드 추가.
    // 두 모듈 시나리오 — hoist 시 a 의 @charsetXYZ 가 b 본문보다 *앞* 으로
    // 가고, fix 시엔 a 본문에 그대로 남아 b 본문 *뒤* 에 emit.
    const fixture = await createFixture({
      'index.ts': `import './b.css';\nimport './a.css';`,
      'a.css': `@charsetXYZ "evil";\n.a {}`,
      'b.css': `.b {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // 핵심 invariant: @charsetXYZ 가 hoist 안 되면 a 본문에 머물러 b 본문 뒤에 위치.
    const bIdx = css.indexOf('.b');
    const fakeCharsetIdx = css.indexOf('@charsetXYZ');
    expect(bIdx).toBeGreaterThanOrEqual(0);
    expect(fakeCharsetIdx).toBeGreaterThanOrEqual(0);
    expect(fakeCharsetIdx).toBeGreaterThan(bIdx);
  });

  it('#3747 여러 모듈의 @charset → 첫 발견 1개만 emit (CSS spec: 1개만 valid)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './a.css';\nimport './b.css';`,
      'a.css': `@charset "UTF-8";\n.a {}`,
      'b.css': `@charset "UTF-8";\n.b {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    const matches = css.match(/@charset/g) ?? [];
    expect(matches.length).toBe(1);
  });

  it('같은 URL 의 다른 media query → 서로 다른 @import 로 둘 다 emit (dedup key=specifier+tail)', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';\nconsole.log("ok");`,
      'style.css':
        `@import "https://cdn/x.css" print;\n` +
        `@import "https://cdn/x.css" screen;\n` +
        `.app {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    expect(css).toMatch(/@import\s+"https:\/\/cdn\/x\.css"\s+print\s*;/);
    expect(css).toMatch(/@import\s+"https:\/\/cdn\/x\.css"\s+screen\s*;/);
  });

  // ── post-merge 검증 (manual repro 로 통과 확인) 영구 회귀 가드. PR #3746
  // (#3321 P0-3 external @import) + #3752 (#3747 @charset/@layer) 의 보존
  // 메커니즘이 단일 bundle 경로 외에도 정확히 작동하는지 확정.
  it('#3747 nested 3-level @import — 각 단계의 @charset/@layer 가 deps-first 순서로 보존', async () => {
    const fixture = await createFixture({
      'index.ts': `import './top.css';`,
      'deep.css': `@charset "UTF-8";\n@layer deep_reset;\n.deep {}`,
      'mid.css': `@import "./deep.css";\n@layer mid_layer;\n.mid {}`,
      'top.css': `@import "./mid.css";\n@layer top_layer;\n.top {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // @charset 살아있고 첫 byte
    expect(css.trimStart().startsWith('@charset "UTF-8"')).toBe(true);
    // 3 단계 @layer 모두 보존 + deps-first (deep → mid → top)
    const deepIdx = css.indexOf('@layer deep_reset');
    const midIdx = css.indexOf('@layer mid_layer');
    const topIdx = css.indexOf('@layer top_layer');
    expect(deepIdx).toBeGreaterThanOrEqual(0);
    expect(midIdx).toBeGreaterThanOrEqual(0);
    expect(topIdx).toBeGreaterThanOrEqual(0);
    expect(deepIdx).toBeLessThan(midIdx);
    expect(midIdx).toBeLessThan(topIdx);
    // 본문도 deps-first
    expect(css.indexOf('.deep')).toBeLessThan(css.indexOf('.mid'));
    expect(css.indexOf('.mid')).toBeLessThan(css.indexOf('.top'));
  });

  it('#3747 multi-chunk (--splitting) — 각 chunk 가 자기 모듈의 @charset/@layer 캡처', async () => {
    const fixture = await createFixture({
      'entry-a.ts': `import './a.css';\nconsole.log("a");`,
      'entry-b.ts': `import './b.css';\nconsole.log("b");`,
      'a.css': `@charset "UTF-8";\n@layer reset, base;\n.a {}`,
      'b.css': `@charset "UTF-8";\n@layer theme;\n.b {}`,
    });
    cleanup = fixture.cleanup;

    const distDir = join(fixture.dir, 'dist');
    await import('node:fs/promises').then((m) => m.mkdir(distDir, { recursive: true }));
    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'entry-a.ts'),
      join(fixture.dir, 'entry-b.ts'),
      '--splitting',
      '--outdir',
      distDir,
      '--format=esm',
    ]);
    expect(result.exitCode).toBe(0);

    const cssA = await readFile(join(distDir, 'entry-a.css'), 'utf-8');
    const cssB = await readFile(join(distDir, 'entry-b.css'), 'utf-8');
    // 각 chunk 자기 @charset + @layer
    expect(cssA.trimStart().startsWith('@charset "UTF-8"')).toBe(true);
    expect(cssA).toMatch(/@layer\s+reset\s*,\s*base/);
    expect(cssA).toContain('.a');
    expect(cssA).not.toContain('.b');
    expect(cssB.trimStart().startsWith('@charset "UTF-8"')).toBe(true);
    expect(cssB).toContain('@layer theme');
    expect(cssB).not.toContain('@layer reset');
    expect(cssB).toContain('.b');
    expect(cssB).not.toContain('.a');
  });

  it('#3321 P0-3 @import url() + layer() + supports() 복합 condition_tail 보존', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css':
        `@import url("https://cdn/x.css") layer(reset);\n` +
        `@import url("https://cdn/y.css") layer(theme) supports(display: grid);\n` +
        `.app {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // layer() / supports() condition tail 보존 (url() form 은 quoted form 으로 정규화)
    expect(css).toMatch(/@import\s+"https:\/\/cdn\/x\.css"\s+layer\(reset\)\s*;/);
    expect(css).toMatch(
      /@import\s+"https:\/\/cdn\/y\.css"\s+layer\(theme\)\s+supports\(display:\s*grid\)\s*;/,
    );
  });

  it('#3747 bare @layer + block-form @layer 공존 — bare 만 상단 prepend, block-form 은 본문', async () => {
    const fixture = await createFixture({
      'index.ts': `import './style.css';`,
      'style.css':
        `@layer reset, base;\n` + `@layer reset {\n  .reset { margin: 0; }\n}\n` + `.app {}`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, 'out.js');
    const result = await runZntc(['--bundle', join(fixture.dir, 'index.ts'), '-o', outJs]);
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, 'index.css'), 'utf-8');
    // bare 선언 + block-form 둘 다 출력에 살아있음
    const bareIdx = css.search(/@layer\s+reset\s*,\s*base\s*;/);
    const blockIdx = css.search(/@layer\s+reset\s*\{/);
    expect(bareIdx).toBeGreaterThanOrEqual(0);
    expect(blockIdx).toBeGreaterThanOrEqual(0);
    // bare 가 block-form 보다 앞 (prepend 동작)
    expect(bareIdx).toBeLessThan(blockIdx);
    // body 본문도 살아있음
    expect(css).toContain('.reset { margin: 0; }');
    expect(css).toContain('.app');
  });
});
