import { describe, it, expect, afterEach } from "bun:test";
import { createFixture, hasPackage, linkNodeModules, runZts } from "./helpers";
import { join } from "node:path";
import { readFile } from "node:fs/promises";

// CSS 라이브러리 스모크 테스트
// Tailwind CSS, Emotion, Styled-Components를 ZTS로 번들링 성공 검증
// 런타임 동작은 브라우저 환경이 필요하므로 e2e 테스트로 분리

const hasEmotion = hasPackage("@emotion/css");
const hasEmotionReact = hasPackage("@emotion/react");
const hasStyledComponents = hasPackage("styled-components");
const hasTailwind = hasPackage("tailwindcss");

// ─── ZTS 네이티브 CSS 번들링 + 외부 CSS 라이브러리 패턴 ───

describe("CSS Library Smoke — Native CSS Bundling", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("plain CSS with @import chain (Tailwind-style utility file)", async () => {
    const fixture = await createFixture({
      "index.ts": `import './style.css';\nconsole.log("app");`,
      "style.css": `@import "./base.css";\n@import "./utilities.css";\n.app { max-width: 1200px; }`,
      "base.css": `*, *::before, *::after { box-sizing: border-box; }\nbody { margin: 0; }`,
      "utilities.css": `.flex { display: flex; }\n.grid { display: grid; }\n.hidden { display: none; }`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // base → utilities → app 순서
    const boxIdx = css.indexOf("box-sizing");
    const flexIdx = css.indexOf("display: flex");
    const appIdx = css.indexOf("max-width");
    expect(boxIdx).toBeGreaterThanOrEqual(0);
    expect(flexIdx).toBeGreaterThan(boxIdx);
    expect(appIdx).toBeGreaterThan(flexIdx);
    expect(css).not.toContain("@import");
  });

  it("CSS variables + custom properties (design token pattern)", async () => {
    const fixture = await createFixture({
      "index.ts": `import './theme.css';`,
      "theme.css": `@import "./tokens.css";\n.btn { background: var(--primary); border-radius: var(--radius); }`,
      "tokens.css": `:root {\n  --primary: #3b82f6;\n  --radius: 0.5rem;\n  --spacing: 1rem;\n}`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    expect(css).toContain("--primary: #3b82f6");
    expect(css).toContain("var(--primary)");
    expect(css).toContain("var(--radius)");
  });
});

// ─── Emotion ───

describe.skipIf(!hasEmotion)("CSS Library Smoke — Emotion", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("@emotion/css bundle succeeds + contains core modules", async () => {
    const fixture = await createFixture({
      "index.ts": `
        import { css } from "@emotion/css";
        const style = css\`color: hotpink; font-size: 24px;\`;
        console.log("emotion:" + style);
      `,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, [
      "@emotion/css",
      "@emotion/cache",
      "@emotion/serialize",
      "@emotion/sheet",
      "@emotion/utils",
      "@emotion/hash",
      "@emotion/unitless",
      "@emotion/memoize",
      "stylis",
    ]);

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, "utf-8");
    expect(js).toContain("serializeStyles");
    expect(js).toContain("prefixer");
    // 번들 사이즈 합리적 (emotion core ~30KB+)
    expect(js.length).toBeGreaterThan(10000);
  });

  it("@emotion/css with tagged template literal", async () => {
    const fixture = await createFixture({
      "index.ts": `
        import { css, cx } from "@emotion/css";
        const base = css\`padding: 8px;\`;
        const highlight = css\`background: yellow;\`;
        const combined = cx(base, highlight);
        console.log(combined);
      `,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, [
      "@emotion/css",
      "@emotion/cache",
      "@emotion/serialize",
      "@emotion/sheet",
      "@emotion/utils",
      "@emotion/hash",
      "@emotion/unitless",
      "@emotion/memoize",
      "stylis",
    ]);

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, "utf-8");
    // cx 함수가 번들에 포함
    expect(js).toContain("merge");
  });
});

// ─── @emotion/react (JSX + css prop) ───

describe.skipIf(!hasEmotionReact)("CSS Library Smoke — @emotion/react", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("@emotion/react styled component bundle (React externalized)", async () => {
    const fixture = await createFixture({
      "index.tsx": `
        import styled from "@emotion/styled";
        import { css } from "@emotion/react";
        const Box = styled.div\`color: hotpink; padding: 8px;\`;
        const mixin = css\`background: yellow;\`;
        console.log(typeof Box, typeof mixin);
      `,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, [
      "@emotion/react",
      "@emotion/styled",
      "@emotion/cache",
      "@emotion/serialize",
      "@emotion/sheet",
      "@emotion/utils",
      "@emotion/hash",
      "@emotion/unitless",
      "@emotion/memoize",
      "@emotion/use-insertion-effect-with-fallbacks",
      "@emotion/weak-memoize",
      "@emotion/is-prop-valid",
      "@babel/runtime",
      "hoist-non-react-statics",
      "react-is",
      "stylis",
    ]);

    // #1824: `--format=iife` + `--globals` 로 external 을 factory-param 에 주입.
    // rollup `output.globals` 호환 — React/ReactDOM 은 런타임에 전역에서 가져온다.
    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.tsx"),
      "-o",
      outFile,
      "--format=iife",
      "--global-name=MyLib",
      "--external",
      "react",
      "--external",
      "react-dom",
      "--globals",
      "react=React",
      "--globals",
      "react-dom=ReactDOM",
    ]);
    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, "utf-8");
    expect(js).toContain("serializeStyles");
    // IIFE factory: 실제 import 된 external 만 param 으로 수록.
    // emotion 은 react 만 쓰므로 `var MyLib = ((React) => {` + `})(React);` 패턴.
    // (react-dom import 가 없으면 globals 매핑이 있어도 factory 에서 생략)
    expect(js).toMatch(/var MyLib = \(\(React\)? (?:=>|\)\s*=>)/);
    expect(js).toMatch(/\}\)\(React[^)]*\);\s*$/);
    expect(js.length).toBeGreaterThan(10000);
  });
});

// ─── Tailwind CSS v4 ───

describe.skipIf(!hasTailwind)("CSS Library Smoke — Tailwind CSS v4", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("bundles CSS importing tailwindcss/preflight.css", async () => {
    const fixture = await createFixture({
      "index.ts": `import './app.css';\nconsole.log("tailwind");`,
      "app.css": `@import "tailwindcss/preflight.css";\n.btn { padding: 0.5rem 1rem; }`,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, ["tailwindcss"]);

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // preflight.css는 box-sizing 리셋 포함
    expect(css).toContain("box-sizing");
    expect(css).toContain(".btn");
    expect(css).not.toContain("@import");
  });

  it("bundles tailwindcss/theme.css (CSS variables)", async () => {
    const fixture = await createFixture({
      "index.ts": `import './app.css';`,
      "app.css": `@import "tailwindcss/theme.css";\n.primary { color: var(--color-blue-500); }`,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, ["tailwindcss"]);

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const css = await readFile(join(fixture.dir, "index.css"), "utf-8");
    // theme.css는 --color-* design token 정의
    expect(css).toContain("--color-");
    expect(css).toContain("var(--color-blue-500)");
  });
});

// ─── Styled-Components ───

describe.skipIf(!hasStyledComponents)("CSS Library Smoke — Styled-Components", () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  it("styled-components bundle succeeds (React externalized)", async () => {
    const fixture = await createFixture({
      "index.ts": `
        import styled from "styled-components";
        const Button = styled.button\`color: red; padding: 8px 16px;\`;
        console.log(typeof Button);
      `,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, [
      "styled-components",
      "tslib",
      "stylis",
      "css-to-react-native",
      "camelize",
      "css-color-keywords",
      "postcss-value-parser",
      "shallowequal",
    ]);

    // #1824: IIFE + --globals 로 rollup 호환 라이브러리 번들.
    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--format=iife",
      "--global-name=Styled",
      "--external",
      "react",
      "--external",
      "react-dom",
      "--globals",
      "react=React",
      "--globals",
      "react-dom=ReactDOM",
    ]);

    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, "utf-8");
    expect(js).toContain("styled");
    expect(js).toContain("stylis");
    expect(js).toMatch(/var Styled = \(\(React/);
    expect(js).toMatch(/\}\)\(React[^)]*\);\s*$/);
    expect(js.length).toBeGreaterThan(5000);
  });

  it("styled-components css helper export", async () => {
    const fixture = await createFixture({
      "index.ts": `
        import { css, keyframes } from "styled-components";
        const fadeIn = keyframes\`from { opacity: 0; } to { opacity: 1; }\`;
        const mixin = css\`animation: \${fadeIn} 0.3s ease;\`;
        console.log(typeof fadeIn, typeof mixin);
      `,
    });
    cleanup = fixture.cleanup;

    await linkNodeModules(fixture.dir, [
      "styled-components",
      "tslib",
      "stylis",
      "css-to-react-native",
      "camelize",
      "css-color-keywords",
      "postcss-value-parser",
      "shallowequal",
    ]);

    // #1824: IIFE + --globals 로 rollup 호환 라이브러리 번들.
    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--format=iife",
      "--global-name=StyledKf",
      "--external",
      "react",
      "--external",
      "react-dom",
      "--globals",
      "react=React",
      "--globals",
      "react-dom=ReactDOM",
    ]);

    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, "utf-8");
    // keyframes 함수가 번들에 포함
    expect(js).toContain("keyframes");
    expect(js).toMatch(/var StyledKf = \(\(React/);
    expect(js).toMatch(/\}\)\(React[^)]*\);\s*$/);
  });
});
