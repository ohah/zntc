import { describe, it, expect, afterEach } from "bun:test";
import { createFixture, runZts } from "./helpers";
import { join, resolve } from "node:path";
import { readFile, symlink, mkdir } from "node:fs/promises";

// CSS 라이브러리 스모크 테스트
// Tailwind CSS, Emotion, Styled-Components를 ZTS로 번들링 성공 검증
// 런타임 동작은 브라우저 환경이 필요하므로 e2e 테스트로 분리

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");

function hasPackage(name: string): boolean {
  try {
    const { statSync } = require("node:fs");
    statSync(join(PROJECT_ROOT, "node_modules", name, "package.json"));
    return true;
  } catch {
    return false;
  }
}

const hasEmotion = hasPackage("@emotion/css");
const hasStyledComponents = hasPackage("styled-components");

async function linkNodeModules(dir: string, packages: string[]) {
  const nmDir = join(dir, "node_modules");
  await mkdir(nmDir, { recursive: true });
  for (const pkg of packages) {
    const src = join(PROJECT_ROOT, "node_modules", pkg);
    if (pkg.startsWith("@")) {
      await mkdir(join(nmDir, pkg.split("/")[0]), { recursive: true });
    }
    try {
      await symlink(src, join(nmDir, pkg));
    } catch {}
  }
}

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

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--external",
      "react",
      "--external",
      "react-dom",
    ]);

    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, "utf-8");
    expect(js).toContain("styled");
    expect(js).toContain("stylis");
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

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--external",
      "react",
      "--external",
      "react-dom",
    ]);

    expect(bundle.exitCode).toBe(0);

    const js = await readFile(outFile, "utf-8");
    // keyframes 함수가 번들에 포함
    expect(js).toContain("keyframes");
  });
});
