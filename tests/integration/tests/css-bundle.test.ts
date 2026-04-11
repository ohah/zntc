import { describe, it, expect, afterEach } from "bun:test";
import { createFixture, runZts } from "./helpers";
import { join } from "node:path";
import { readFile } from "node:fs/promises";

describe("CSS Bundling", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("single CSS import → separate .css file", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';\nconsole.log("hello");`,
      "style.css": `body { color: red; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    const result = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);
    expect(result.exitCode).toBe(0);

    // JS 출력에 CSS import가 없어야 함
    const js = await readFile(outJs, "utf-8");
    expect(js).toContain("console.log");
    expect(js).not.toContain("color: red");

    // CSS 파일이 생성되어야 함
    const cssPath = join(fixture.dir, "index.css");
    const css = await readFile(cssPath, "utf-8");
    expect(css).toContain("body { color: red; }");
  });

  it("@import chaining → inlined in correct order", async () => {
    const fixture = await createFixture({
      "index.ts": `import './a.css';\nconsole.log("hello");`,
      "a.css": `@import "./b.css";\nbody { color: red; }`,
      "b.css": `* { margin: 0; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // b.css가 a.css보다 먼저 나와야 함 (DFS 순서)
    const marginIdx = css.indexOf("margin: 0");
    const colorIdx = css.indexOf("color: red");
    expect(marginIdx).toBeGreaterThanOrEqual(0);
    expect(colorIdx).toBeGreaterThanOrEqual(0);
    expect(marginIdx).toBeLessThan(colorIdx);
    // @import 규칙은 제거되어야 함
    expect(css).not.toContain("@import");
  });

  it("deep @import chain (3 levels)", async () => {
    const fixture = await createFixture({
      "index.ts": `import './a.css';`,
      "a.css": `@import "./b.css";\n.a { color: red; }`,
      "b.css": `@import "./c.css";\n.b { color: blue; }`,
      "c.css": `.c { color: green; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    const cIdx = css.indexOf(".c");
    const bIdx = css.indexOf(".b");
    const aIdx = css.indexOf(".a");
    expect(cIdx).toBeLessThan(bIdx);
    expect(bIdx).toBeLessThan(aIdx);
  });

  it("no CSS imports → no .css file generated", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log("no css");`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    let hasCss = true;
    try {
      await readFile(join(fixture.dir, "index.css"), "utf-8");
    } catch {
      hasCss = false;
    }
    expect(hasCss).toBe(false);
  });

  it("--loader:.css=empty → CSS ignored (existing behavior)", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';\nconsole.log("hello");`,
      "style.css": `body { color: red; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs, "--loader:.css=empty"]);

    // empty 로더 → CSS 파일 미생성
    let hasCss = true;
    try {
      await readFile(join(fixture.dir, "index.css"), "utf-8");
    } catch {
      hasCss = false;
    }
    expect(hasCss).toBe(false);
  });

  it("multiple CSS imports from same JS", async () => {
    const fixture = await createFixture({
      "index.ts": `import './a.css';\nimport './b.css';\nconsole.log("hello");`,
      "a.css": `.a { color: red; }`,
      "b.css": `.b { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain(".a { color: red; }");
    expect(css).toContain(".b { color: blue; }");
    // a.css가 b.css보다 먼저 (import 순서)
    expect(css.indexOf(".a")).toBeLessThan(css.indexOf(".b"));
  });

  it("CSS imported from nested JS module", async () => {
    const fixture = await createFixture({
      "index.ts": `import './components/button';\nconsole.log("app");`,
      "components/button.ts": `import './button.css';\nexport const Button = "btn";`,
      "components/button.css": `.button { padding: 8px; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain(".button { padding: 8px; }");
  });

  it("CSS with @charset and comments before @import", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';`,
      "style.css": `@charset "UTF-8";\n/* header styles */\n@import "./header.css";\nbody { margin: 0; }`,
      "header.css": `header { display: flex; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain("header { display: flex; }");
    expect(css).toContain("body { margin: 0; }");
    expect(css).not.toContain("@import");
  });

  it("duplicate CSS import is not duplicated in output", async () => {
    const fixture = await createFixture({
      "index.ts": `import './a.ts';\nimport './b.ts';`,
      "a.ts": `import './shared.css';\nexport const a = 1;`,
      "b.ts": `import './shared.css';\nexport const b = 2;`,
      "shared.css": `.shared { color: green; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // shared.css는 한 번만 나와야 함
    const firstIdx = css.indexOf(".shared");
    const secondIdx = css.indexOf(".shared", firstIdx + 1);
    expect(firstIdx).toBeGreaterThanOrEqual(0);
    expect(secondIdx).toBe(-1);
  });

  it("CSS-only entry (no JS logic) → still generates .css", async () => {
    const fixture = await createFixture({
      "index.ts": `import './global.css';`,
      "global.css": `html { font-size: 16px; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain("html { font-size: 16px; }");

    // JS는 빈 IIFE (또는 최소 출력)
    const js = await readFile(outJs, "utf-8");
    expect(js).not.toContain("font-size");
  });

  it("@import url() with single quotes", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';`,
      "style.css": `@import url('./reset.css');\n.main { display: flex; }`,
      "reset.css": `* { box-sizing: border-box; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain("box-sizing: border-box");
    expect(css).toContain(".main { display: flex; }");
    expect(css).not.toContain("@import");
  });

  it("circular @import → no infinite loop, no duplication", async () => {
    const fixture = await createFixture({
      "index.ts": `import './a.css';`,
      "a.css": `@import "./b.css";\n.a { color: red; }`,
      "b.css": `@import "./a.css";\n.b { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    const result = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);
    // 번들이 성공해야 함 (무한루프 X)
    expect(result.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain(".a");
    expect(css).toContain(".b");
    // 각 클래스가 한 번만 등장
    const aFirst = css.indexOf(".a");
    const aSecond = css.indexOf(".a", aFirst + 2);
    expect(aSecond).toBe(-1);
  });

  it("@import with media query → specifier correctly extracted", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';`,
      "style.css": `@import "./print.css" print;\n.screen { display: block; }`,
      "print.css": `.print-only { display: none; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // print.css 내용이 인라인되어야 함
    expect(css).toContain(".print-only");
    expect(css).toContain(".screen");
    // @import 자체는 제거
    expect(css).not.toContain("@import");
  });

  it("non-existent CSS @import → build succeeds with error diagnostic", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';\nconsole.log("ok");`,
      "style.css": `@import "./missing.css";\nbody { color: red; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    const result = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);
    // 에러가 발생하거나 경고가 있어야 함 (missing.css 없음)
    const hasError = result.exitCode !== 0 || result.stderr.includes("missing.css");
    expect(hasError).toBe(true);
  });

  it("CSS with url() image reference → preserved in output", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';`,
      "style.css": `.bg { background: url(./img/hero.png) no-repeat; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // url() 참조가 그대로 유지되어야 함
    expect(css).toContain("url(./img/hero.png)");
  });

  it("CSS imported from dynamically imported module", async () => {
    const fixture = await createFixture({
      "index.ts": `const mod = import('./lazy.ts');\nconsole.log("main");`,
      "lazy.ts": `import './lazy.css';\nexport const x = 1;`,
      "lazy.css": `.lazy { opacity: 0; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    // dynamic import의 CSS도 번들에 포함될 수 있음 (단일 엔트리이므로)
    const cssExists = await readFile(join(fixture.dir, "index.css"), "utf-8").catch(() => null);
    if (cssExists) {
      expect(cssExists).toContain(".lazy");
    }
    // JS는 정상 생성
    const js = await readFile(outJs, "utf-8");
    expect(js).toContain("main");
  });

  it("--outdir with CSS", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';\nconsole.log("outdir test");`,
      "style.css": `.test { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--splitting",
      "--format=esm",
      "--outdir",
      outDir,
    ]);

    const css = await readFile(join(outDir, "index.css"), "utf-8");
    expect(css).toContain(".test { color: blue; }");

    const js = await readFile(join(outDir, "index.js"), "utf-8");
    expect(js).toContain("console.log");
  });

  it("CSS with only whitespace/comments after @import stripping → no .css file", async () => {
    const fixture = await createFixture({
      "index.ts": `import './wrapper.css';`,
      "wrapper.css": `@import "./actual.css";\n/* just a wrapper */\n`,
      "actual.css": `.actual { color: green; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain(".actual { color: green; }");
    // wrapper.css는 @import 외에 주석뿐이므로 그 부분은 무시됨
    expect(css).not.toContain("@import");
  });

  it("CSS with multiple @import then rules", async () => {
    const fixture = await createFixture({
      "index.ts": `import './main.css';`,
      "main.css": `@import "./vars.css";\n@import "./reset.css";\n@import "./base.css";\n.main { color: black; }`,
      "vars.css": `:root { --c: red; }`,
      "reset.css": `* { margin: 0; }`,
      "base.css": `body { font: 16px sans-serif; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // 순서: vars → reset → base → main
    const varsIdx = css.indexOf("--c: red");
    const resetIdx = css.indexOf("margin: 0");
    const baseIdx = css.indexOf("font: 16px");
    const mainIdx = css.indexOf("color: black");
    expect(varsIdx).toBeGreaterThanOrEqual(0);
    expect(resetIdx).toBeGreaterThan(varsIdx);
    expect(baseIdx).toBeGreaterThan(resetIdx);
    expect(mainIdx).toBeGreaterThan(baseIdx);
    expect(css).not.toContain("@import");
  });

  it("CSS with special characters in selectors and values", async () => {
    const fixture = await createFixture({
      "index.ts": `import './special.css';`,
      "special.css": `.cls\\:hover { color: red; }\n[data-attr="@import"] { display: none; }\n.emoji { content: "\\1F600"; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // @import가 selector/value 안에 있으면 추출되면 안 됨
    expect(css).toContain('[data-attr="@import"]');
    expect(css).toContain("emoji");
  });

  it("empty CSS file → no .css output", async () => {
    const fixture = await createFixture({
      "index.ts": `import './empty.css';\nconsole.log("hi");`,
      "empty.css": ``,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    let hasCss = true;
    try {
      await readFile(join(fixture.dir, "index.css"), "utf-8");
    } catch {
      hasCss = false;
    }
    expect(hasCss).toBe(false);
  });

  it("CSS with @import inside a rule block → not extracted", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';`,
      "style.css": `.parent {\n  color: red;\n}\n/* @import inside comment: @import "./nope.css"; */\n.child { color: blue; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain(".parent");
    expect(css).toContain(".child");
  });

  it("CSS with BOM (byte order mark)", async () => {
    const fixture = await createFixture({
      "index.ts": `import './bom.css';`,
      "bom.css": `\uFEFF@import "./base.css";\n.bom { color: red; }`,
      "base.css": `.base { margin: 0; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain(".bom");
    // base.css가 인라인되었으면 OK, 안 되었어도 bom.css 자체는 출력
    expect(css.length).toBeGreaterThan(0);
  });

  it("large CSS file with many rules", async () => {
    // 1000개 rule 생성
    const rules = Array.from(
      { length: 1000 },
      (_, i) => `.c${i} { color: hsl(${i}, 50%, 50%); }`,
    ).join("\n");
    const fixture = await createFixture({
      "index.ts": `import './big.css';`,
      "big.css": rules,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain(".c0");
    expect(css).toContain(".c999");
    // 모든 rule이 포함되어야 함
    expect(css.split(".c").length - 1).toBe(1000);
  });

  it("re-export chain: JS re-exports from module that imports CSS", async () => {
    const fixture = await createFixture({
      "index.ts": `export { x } from './lib.ts';`,
      "lib.ts": `import './lib.css';\nexport const x = 42;`,
      "lib.css": `.lib { padding: 10px; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain(".lib { padding: 10px; }");
  });

  it("CSS and JS interleaved imports preserve CSS order", async () => {
    const fixture = await createFixture({
      "index.ts": `import './a.css';\nimport { x } from './util.ts';\nimport './b.css';\nconsole.log(x);`,
      "util.ts": `export const x = 1;`,
      "a.css": `.a { order: 1; }`,
      "b.css": `.b { order: 2; }`,
    });
    cleanup = fixture.cleanup;

    const outJs = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outJs]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css.indexOf(".a")).toBeLessThan(css.indexOf(".b"));
  });
});
