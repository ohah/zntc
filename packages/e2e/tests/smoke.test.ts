import { test, expect } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ZTS_BIN = resolve(__dirname, "../../../zig-out/bin/zts");
const TEST_PORT = 3999;

let server: ChildProcess | null = null;
let fixtureDir: string;

test.beforeAll(async () => {
  fixtureDir = await mkdtemp(join(tmpdir(), "zts-e2e-"));
  await writeFile(
    join(fixtureDir, "app.ts"),
    'const msg: string = "hello from zts"; console.log(msg); var el = document.getElementById("root"); if (el) { el.textContent = msg; }',
  );
  await writeFile(join(fixtureDir, "style.css"), "body { background: white; }");

  server = spawn(
    ZTS_BIN,
    ["--serve", "--bundle", join(fixtureDir, "app.ts"), "--port", String(TEST_PORT)],
    { stdio: "pipe" },
  );

  await new Promise((resolve) => setTimeout(resolve, 2000));
});

test.afterAll(async () => {
  if (server) {
    server.kill();
    await new Promise((resolve) => server!.on("close", resolve));
  }
  await rm(fixtureDir, { recursive: true, force: true });
});

test.describe("Dev Server E2E", () => {
  test("페이지가 로드되고 번들이 실행된다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);
    await expect(page.locator("#root")).toHaveText("hello from zts");
  });

  test("HMR WebSocket 연결이 수립된다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);

    const wsConnected = await page.evaluate((port: number) => {
      return new Promise<boolean>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onopen = () => {
          ws.close();
          resolve(true);
        };
        ws.onerror = () => resolve(false);
        setTimeout(() => resolve(false), 3000);
      });
    }, TEST_PORT);

    expect(wsConnected).toBe(true);
  });

  test("connected 메시지를 수신한다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);

    const firstMessage = await page.evaluate((port: number) => {
      return new Promise<string>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (e) => {
          ws.close();
          resolve(e.data);
        };
        ws.onerror = () => resolve("error");
        setTimeout(() => resolve("timeout"), 3000);
      });
    }, TEST_PORT);

    const msg = JSON.parse(firstMessage);
    expect(msg.type).toBe("connected");
  });

  test("번들에 TS 타입이 제거되어 있다", async ({ page }) => {
    const response = await page.goto(`http://localhost:${TEST_PORT}/bundle.js`);
    const body = await response!.text();

    expect(body).toContain("hello from zts");
    expect(body).not.toContain(": string");
  });

  test("React Fast Refresh 코드가 주입된다", async ({ page }) => {
    const response = await page.goto(`http://localhost:${TEST_PORT}/bundle.js`);
    const body = await response!.text();

    // $RefreshReg$ 글로벌 바인딩 (HMR 런타임)
    expect(body).toContain("$RefreshReg$");
    expect(body).toContain("$RefreshSig$");
    // react-refresh 런타임 연결
    expect(body).toContain("__REACT_REFRESH_RUNTIME__");
    // /@react-refresh 가상 엔드포인트
    const refreshRes = await page.goto(`http://localhost:${TEST_PORT}/@react-refresh`);
    expect(refreshRes!.status()).toBe(200);
  });

  test("소스맵이 서빙된다", async ({ page }) => {
    // bundle.js에 sourceMappingURL 포함 확인
    const bundleRes = await page.goto(`http://localhost:${TEST_PORT}/bundle.js`);
    const bundleBody = await bundleRes!.text();
    expect(bundleBody).toContain("//# sourceMappingURL=/bundle.js.map");

    // /bundle.js.map 엔드포인트 응답 확인
    const smRes = await page.goto(`http://localhost:${TEST_PORT}/bundle.js.map`);
    expect(smRes!.status()).toBe(200);
    const smBody = await smRes!.text();

    // V3 소스맵 JSON 구조 검증
    const sm = JSON.parse(smBody);
    expect(sm.version).toBe(3);
    expect(sm.file).toBe("bundle.js");
    expect(sm.sources).toBeDefined();
    expect(sm.sources.length).toBeGreaterThan(0);
    expect(sm.mappings).toBeDefined();
    expect(sm.mappings.length).toBeGreaterThan(0);
  });

  // Linux CI에서 inotify 타이밍 불안정 — macOS kqueue/로컬에서는 통과
  test.skip(!!process.env.CI && process.platform === "linux", "inotify timing on Linux CI");
  test("파일 변경 시 HMR update 메시지를 수신한다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);

    // WS 연결 + update 메시지 대기 설정
    const updatePromise = page.evaluate((port: number) => {
      return new Promise<string>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (e) => {
          const msg = JSON.parse(e.data);
          // connected 메시지는 스킵, update 또는 full-reload 대기
          if (msg.type === "update" || msg.type === "full-reload") {
            ws.close();
            resolve(msg.type);
          }
        };
        ws.onerror = () => resolve("error");
        setTimeout(() => resolve("timeout"), 8000);
      });
    }, TEST_PORT);

    // watch가 감지할 수 있도록 잠시 대기 후 파일 변경
    await new Promise((r) => setTimeout(r, 1000));
    await writeFile(
      join(fixtureDir, "app.ts"),
      'const msg: string = "updated"; console.log(msg); var el = document.getElementById("root"); if (el) { el.textContent = msg; }',
    );

    const msgType = await updatePromise;
    // update 또는 full-reload 중 하나 (accept 없으면 서버가 update 보내고 클라이언트가 reload)
    expect(msgType === "update" || msgType === "full-reload").toBe(true);

    // 파일 원복
    await writeFile(
      join(fixtureDir, "app.ts"),
      'const msg: string = "hello from zts"; console.log(msg); var el = document.getElementById("root"); if (el) { el.textContent = msg; }',
    );
    await new Promise((r) => setTimeout(r, 1500));
  });

  test.skip(!!process.env.CI && process.platform === "linux", "inotify timing on Linux CI");
  test("빌드 에러 시 에러 오버레이가 표시된다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);

    // HMR 연결 대기
    await page.evaluate((port: number) => {
      return new Promise<void>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = () => resolve();
        setTimeout(() => resolve(), 3000);
      });
    }, TEST_PORT);

    // 구문 에러 주입
    await writeFile(join(fixtureDir, "app.ts"), "const x: = ;");

    // 에러 오버레이가 나타날 때까지 대기
    await expect(page.locator("#zts-error-overlay")).toBeVisible({ timeout: 5000 });
    await expect(page.locator("#zts-error-overlay")).toContainText("Build Error");

    // 에러 수정 → 오버레이 사라짐 + 페이지 리로드
    await writeFile(
      join(fixtureDir, "app.ts"),
      'const msg: string = "hello from zts"; console.log(msg); var el = document.getElementById("root"); if (el) { el.textContent = msg; }',
    );

    // full-reload가 발생하면 페이지가 새로고침되어 오버레이가 사라짐
    await expect(page.locator("#zts-error-overlay")).not.toBeVisible({ timeout: 5000 });
    await expect(page.locator("#root")).toHaveText("hello from zts", { timeout: 5000 });
  });

  test.skip(!!process.env.CI && process.platform === "linux", "inotify timing on Linux CI");
  test("CSS 변경 시 css-update 메시지를 수신한다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);

    // WS 연결 + css-update 메시지 대기 설정
    const updatePromise = page.evaluate((port: number) => {
      return new Promise<string>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (e) => {
          const msg = JSON.parse(e.data);
          if (msg.type === "css-update") {
            ws.close();
            resolve(JSON.stringify(msg));
          }
        };
        ws.onerror = () => resolve("error");
        setTimeout(() => resolve("timeout"), 12000);
      });
    }, TEST_PORT);

    // watch가 감지할 수 있도록 잠시 대기 후 CSS 변경 (CI 환경에서 mtime polling 간격 고려)
    await new Promise((r) => setTimeout(r, 1500));
    await writeFile(join(fixtureDir, "style.css"), "body { background: red; }");

    const result = await updatePromise;
    expect(result).not.toBe("timeout");
    expect(result).not.toBe("error");

    const msg = JSON.parse(result);
    expect(msg.type).toBe("css-update");
    expect(msg.file).toContain("style.css");
  });
});
