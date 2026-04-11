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
});
