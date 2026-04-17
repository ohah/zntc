import { test, expect } from "@playwright/test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

/**
 * Multi-module Vite 앱을 vite-plugin-zts로 빌드 → 브라우저 실행 E2E.
 *
 * 기존 tests/integration/tests/vite-plugin-zts.test.ts는 단일 파일 transform 단위 검증.
 * 본 테스트는 다중 TS/TSX 모듈 앱을 실제 `vite build`로 프로덕션 번들한 뒤 Playwright
 * 브라우저에서 로드해 동작까지 확인 — real-world E2E.
 *
 * Vite config에서 vite-plugin-zts(TS 소스)를 import하므로 Bun을 통해 실행해야 한다.
 * Playwright 자체는 Node에서 돌지만, 빌드/preview 서브프로세스는 `bun x --bun vite …` 경유.
 */

const PROJECT_ROOT = resolve(__dirname, "../../..");
const TEST_PORT = 3996;

const FILES: Record<string, string> = {
  "index.html": `<!doctype html>
<html>
  <head><meta charset="utf-8" /><title>vite+zts e2e</title></head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>`,
  "src/main.tsx": `
import { greet } from "./util";
import { mountApp } from "./app";

const name: string = "ZTS";
const message = greet(name);
mountApp(document.getElementById("root")!, message);
`,
  "src/util.ts": `
export const PREFIX = "hello from";
export function greet(name: string): string {
  return \`\${PREFIX} \${name}\`;
}
`,
  "src/app.tsx": `
export function mountApp(el: HTMLElement, message: string): void {
  el.innerHTML = \`<h1 data-testid="greeting">\${message}</h1>\`;
}
`,
  "package.json": JSON.stringify({ type: "module" }),
};

function makeViteConfig(pluginDir: string): string {
  return `import { zts } from "${pluginDir.replace(/\\/g, "/")}/src/index.ts";
export default { plugins: [zts()], build: { minify: true, sourcemap: true } };
`;
}

let fixtureDir: string;
let previewServer: ChildProcess | null = null;

test.beforeAll(async () => {
  fixtureDir = await mkdtemp(join(tmpdir(), "zts-vite-e2e-"));

  for (const [name, content] of Object.entries(FILES)) {
    const filePath = join(fixtureDir, name);
    await mkdir(dirname(filePath), { recursive: true });
    await writeFile(filePath, content.trimStart());
  }

  const pluginDir = join(PROJECT_ROOT, "packages/vite-plugin-zts");
  await writeFile(join(fixtureDir, "vite.config.ts"), makeViteConfig(pluginDir));

  // `bun x --bun vite build` — Bun 런타임으로 실행하여 vite 플러그인의 TS 소스 import 가능
  const build = spawnSync("bun", ["x", "--bun", "vite", "build"], {
    cwd: fixtureDir,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (build.status !== 0) {
    throw new Error(
      `vite build failed (exit ${build.status})\n--- stdout ---\n${build.stdout}\n--- stderr ---\n${build.stderr}`,
    );
  }

  previewServer = spawn("bun", ["x", "--bun", "vite", "preview", "--port", String(TEST_PORT)], {
    cwd: fixtureDir,
    stdio: "pipe",
  });
  await new Promise((r) => setTimeout(r, 2500));
});

test.afterAll(async () => {
  if (previewServer) {
    previewServer.kill();
    await new Promise((r) => previewServer!.on("close", r));
  }
  if (fixtureDir) {
    await rm(fixtureDir, { recursive: true, force: true });
  }
});

test.describe("Vite app build (vite-plugin-zts) E2E", () => {
  test("다중 모듈 TS/TSX 앱이 번들되고 브라우저에서 정상 실행된다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);
    await expect(page.getByTestId("greeting")).toHaveText("hello from ZTS");
  });

  test("빌드 출력에 TS 타입 어노테이션이 남아있지 않다", async ({ request }) => {
    const indexHtml = await (await request.get(`http://localhost:${TEST_PORT}/`)).text();
    const scriptMatch = indexHtml.match(/src="(\/assets\/[^"]+\.js)"/);
    expect(scriptMatch).not.toBeNull();

    const js = await (await request.get(`http://localhost:${TEST_PORT}${scriptMatch![1]}`)).text();
    expect(js).toContain("hello from");
    expect(js).not.toMatch(/: string\b/);
    expect(js).not.toMatch(/: HTMLElement\b/);
  });
});
