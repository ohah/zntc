import { test, expect } from "@playwright/test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

/**
 * Vite-style app builder (`zts build` / `zts dev` / `zts preview`) 의 브라우저 E2E.
 *
 * tests/integration 와 packages/core/bin/zts.test.ts 는 CLI exit code / stderr / 출력 파일까지만
 * 검증한다. 본 테스트는 빌드된 앱이 실제 브라우저에서 실행되는 것까지 확인한다 — 멀티 모듈
 * import 그래프, import.meta.env 정적 주입, HTML %VITE_*% 토큰 치환, public/ 자산 복사,
 * stylesheet rewrite 후 CSS 적용.
 */

const ZTS_BIN = resolve(__dirname, "../../../zig-out/bin/zts");
const BUILD_PREVIEW_PORT = 3997;
const DEV_PORT = 3998;

const FIXTURE: Record<string, string> = {
  "index.html": `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>%VITE_APP_TITLE%</title>
    <link rel="icon" href="/favicon.svg" />
    <link rel="stylesheet" href="/src/style.css" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>`,
  "src/main.ts": `import { greet } from "./util";
const target = document.getElementById("root")!;
target.innerHTML = \`
  <h1 data-testid="title">\${greet(import.meta.env.VITE_APP_TITLE)}</h1>
  <p data-testid="mode">\${import.meta.env.MODE}</p>
  <p data-testid="prod">\${String(import.meta.env.PROD)}</p>
\`;
`,
  "src/util.ts": `export function greet(name: string): string {
  return \`hello \${name}\`;
}
`,
  "src/style.css": `body { background: rgb(220, 230, 240); }
[data-testid="title"] { color: rgb(33, 150, 243); }
`,
  "public/favicon.svg": `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="black"/></svg>`,
  ".env.production": `VITE_APP_TITLE=Prod App
`,
  ".env.development": `VITE_APP_TITLE=Dev App
`,
};

async function writeFixture(dir: string): Promise<void> {
  for (const [name, content] of Object.entries(FIXTURE)) {
    const filePath = join(dir, name);
    await mkdir(dirname(filePath), { recursive: true });
    await writeFile(filePath, content);
  }
}

// ─── zts build → zts preview → 브라우저 ───
test.describe("zts build + preview E2E", () => {
  let fixtureDir: string;
  let preview: ChildProcess | null = null;

  test.beforeAll(async () => {
    fixtureDir = await mkdtemp(join(tmpdir(), "zts-app-build-e2e-"));
    await writeFixture(fixtureDir);

    const built = spawnSync(ZTS_BIN, ["build", fixtureDir, "--outdir", join(fixtureDir, "dist")], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (built.status !== 0) {
      throw new Error(
        `zts build failed (exit ${built.status})\n--- stdout ---\n${built.stdout}\n--- stderr ---\n${built.stderr}`,
      );
    }

    preview = spawn(
      ZTS_BIN,
      ["preview", join(fixtureDir, "dist"), "--port", String(BUILD_PREVIEW_PORT)],
      { stdio: "pipe" },
    );
    await new Promise((r) => setTimeout(r, 2000));
  });

  test.afterAll(async () => {
    if (preview) {
      preview.kill();
      await new Promise((r) => preview!.on("close", r));
    }
    if (fixtureDir) await rm(fixtureDir, { recursive: true, force: true });
  });

  test("페이지가 로드되고 import.meta.env 가 production 으로 정적 주입된다", async ({ page }) => {
    await page.goto(`http://localhost:${BUILD_PREVIEW_PORT}/`);
    await expect(page.getByTestId("title")).toHaveText("hello Prod App");
    await expect(page.getByTestId("mode")).toHaveText("production");
    await expect(page.getByTestId("prod")).toHaveText("true");
  });

  test("HTML title 의 %VITE_*% placeholder 가 치환된다", async ({ page }) => {
    await page.goto(`http://localhost:${BUILD_PREVIEW_PORT}/`);
    await expect(page).toHaveTitle("Prod App");
  });

  test("public/ 자산이 그대로 복사되어 서빙된다", async ({ request }) => {
    const r = await request.get(`http://localhost:${BUILD_PREVIEW_PORT}/favicon.svg`);
    expect(r.status()).toBe(200);
    expect(await r.text()).toContain("<svg");
  });

  test("HTML 의 <link rel=stylesheet> 가 빌드 산출물 경로로 rewrite 되고 CSS 가 적용된다", async ({
    page,
  }) => {
    await page.goto(`http://localhost:${BUILD_PREVIEW_PORT}/`);
    const bg = await page.locator("body").evaluate((el) => getComputedStyle(el).backgroundColor);
    expect(bg).toBe("rgb(220, 230, 240)");
    const titleColor = await page.getByTestId("title").evaluate((el) => getComputedStyle(el).color);
    expect(titleColor).toBe("rgb(33, 150, 243)");
  });

  test("빌드된 JS 에 TS 타입 어노테이션이 남아있지 않다", async ({ request }) => {
    const html = await (await request.get(`http://localhost:${BUILD_PREVIEW_PORT}/`)).text();
    const scriptMatch = html.match(/<script[^>]+src="([^"]+)"/);
    expect(scriptMatch).not.toBeNull();
    const js = await (
      await request.get(`http://localhost:${BUILD_PREVIEW_PORT}${scriptMatch![1]}`)
    ).text();
    expect(js).toContain("hello");
    expect(js).not.toMatch(/: string\b/);
  });
});

// ─── zts dev 직접 띄움 → 브라우저 ───
test.describe("zts dev E2E", () => {
  let fixtureDir: string;
  let server: ChildProcess | null = null;

  test.beforeAll(async () => {
    fixtureDir = await mkdtemp(join(tmpdir(), "zts-app-dev-e2e-"));
    await writeFixture(fixtureDir);
    server = spawn(ZTS_BIN, ["dev", fixtureDir, "--port", String(DEV_PORT)], {
      stdio: "pipe",
    });
    await new Promise((r) => setTimeout(r, 2500));
  });

  test.afterAll(async () => {
    if (server) {
      server.kill();
      await new Promise((r) => server!.on("close", r));
    }
    if (fixtureDir) await rm(fixtureDir, { recursive: true, force: true });
  });

  test("dev 모드에서 import.meta.env.MODE 가 development, PROD 가 false", async ({ page }) => {
    await page.goto(`http://localhost:${DEV_PORT}/`);
    await expect(page.getByTestId("title")).toHaveText("hello Dev App");
    await expect(page.getByTestId("mode")).toHaveText("development");
    await expect(page.getByTestId("prod")).toHaveText("false");
  });

  test("dev 모드 HTML title placeholder 도 치환된다", async ({ page }) => {
    await page.goto(`http://localhost:${DEV_PORT}/`);
    await expect(page).toHaveTitle("Dev App");
  });

  test("dev 모드도 public/ 와 stylesheet 자산을 서빙한다", async ({ request }) => {
    const fav = await request.get(`http://localhost:${DEV_PORT}/favicon.svg`);
    expect(fav.status()).toBe(200);
    const css = await request.get(`http://localhost:${DEV_PORT}/style.css`);
    expect(css.status()).toBe(200);
    expect(await css.text()).toContain("rgb(220, 230, 240)");
  });
});
