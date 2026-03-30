import { describe, test, expect, afterEach } from "bun:test";
import { createFixture, runZts, ZTS_BIN } from "./helpers";
import { join } from "node:path";

// dev server 테스트는 서버를 백그라운드로 시작하고 HTTP 요청으로 검증
async function startDevServer(
  args: string[],
  opts: { timeout?: number } = {},
): Promise<{ proc: ReturnType<typeof Bun.spawn>; port: number; kill: () => Promise<void> }> {
  const proc = Bun.spawn({
    cmd: [ZTS_BIN, ...args],
    stdout: "pipe",
    stderr: "pipe",
  });

  // 서버 시작 대기
  await new Promise((r) => setTimeout(r, opts.timeout ?? 2000));

  // stderr에서 포트 추출
  const port = args.includes("--port") ? Number.parseInt(args[args.indexOf("--port") + 1]) : 12300;

  return {
    proc,
    port,
    kill: async () => {
      proc.kill();
      await proc.exited;
    },
  };
}

describe("Dev Server", () => {
  let cleanup: (() => Promise<void>) | undefined;
  let killServer: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (killServer) {
      await killServer();
      killServer = undefined;
    }
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("serves bundle on default port 12300", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log("hello");`,
    });
    cleanup = fixture.cleanup;

    const server = await startDevServer(["--serve", "--bundle", join(fixture.dir, "index.ts")]);
    killServer = server.kill;

    const res = await fetch(`http://localhost:${server.port}/bundle.js`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain("hello");
  });

  test("--port changes listen port", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log("custom-port");`,
    });
    cleanup = fixture.cleanup;

    const server = await startDevServer([
      "--serve",
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--port",
      "12399",
    ]);
    killServer = server.kill;

    const res = await fetch(`http://localhost:12399/bundle.js`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain("custom-port");
  });

  test("serves static files", async () => {
    const fixture = await createFixture({
      "hello.txt": "static content",
    });
    cleanup = fixture.cleanup;

    const server = await startDevServer(["--serve", fixture.dir, "--port", "12398"]);
    killServer = server.kill;

    const res = await fetch(`http://localhost:12398/hello.txt`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain("static content");
  });

  test("returns 404 for missing files", async () => {
    const fixture = await createFixture({
      "index.html": "<h1>home</h1>",
    });
    cleanup = fixture.cleanup;

    const server = await startDevServer(["--serve", fixture.dir, "--port", "12397"]);
    killServer = server.kill;

    const res = await fetch(`http://localhost:12397/nonexistent.js`);
    expect(res.status).toBe(404);
  });

  test("CORS headers are present", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log(1);`,
    });
    cleanup = fixture.cleanup;

    const server = await startDevServer([
      "--serve",
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--port",
      "12396",
    ]);
    killServer = server.kill;

    const res = await fetch(`http://localhost:12396/bundle.js`);
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });

  test("--proxy forwards requests to backend", async () => {
    // 간단한 백엔드 서버 시작
    const backendServer = Bun.serve({
      port: 18080,
      fetch() {
        return new Response(JSON.stringify({ message: "from backend" }), {
          headers: { "Content-Type": "application/json" },
        });
      },
    });

    const fixture = await createFixture({
      "index.ts": `console.log("proxy-test");`,
    });
    cleanup = async () => {
      backendServer.stop();
      await fixture.cleanup();
    };

    const server = await startDevServer([
      "--serve",
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--port",
      "12395",
      "--proxy",
      "/api=http://127.0.0.1:18080",
    ]);
    killServer = server.kill;

    const res = await fetch(`http://localhost:12395/api/data`);
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.message).toBe("from backend");
  });

  test("--proxy passes request headers to backend", async () => {
    let receivedAuth = "";
    const backendServer = Bun.serve({
      port: 18081,
      fetch(req) {
        receivedAuth = req.headers.get("authorization") || "";
        return new Response("ok");
      },
    });

    const fixture = await createFixture({
      "index.ts": `console.log(1);`,
    });
    cleanup = async () => {
      backendServer.stop();
      await fixture.cleanup();
    };

    const server = await startDevServer([
      "--serve",
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--port",
      "12394",
      "--proxy",
      "/api=http://127.0.0.1:18081",
    ]);
    killServer = server.kill;

    await fetch(`http://localhost:12394/api/test`, {
      headers: { Authorization: "Bearer token123" },
    });

    expect(receivedAuth).toBe("Bearer token123");
  });

  test("--serve with --plugin loads CSS via plugin", async () => {
    const CORE_PATH = join(import.meta.dir, "../../../packages/core/index.js");

    const fixture = await createFixture({
      "index.ts": `import css from './style.css';\nconsole.log(css);`,
      "style.css": "body { color: green; }",
      "package.json": '{"type": "module"}',
      "plugin.js": `
          import { defineConfig } from '${CORE_PATH}';
          defineConfig({ plugins: [{
            name: 'css-loader',
            async load(id) {
              if (!id.endsWith('.css')) return null;
              const fs = await import('node:fs');
              const css = await fs.promises.readFile(id, 'utf8');
              return 'export default ' + JSON.stringify(css) + ';';
            }
          }] });
        `,
    });
    cleanup = fixture.cleanup;

    const server = await startDevServer(
      [
        "--serve",
        "--bundle",
        join(fixture.dir, "index.ts"),
        "--port",
        "12393",
        "--plugin",
        join(fixture.dir, "plugin.js"),
      ],
      { timeout: 3000 },
    );
    killServer = server.kill;

    // CI에서 서버 준비가 느릴 수 있으므로 retry
    let text = "";
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const res = await fetch(`http://localhost:12393/bundle.js`);
        if (res.status === 200) {
          text = await res.text();
          break;
        }
      } catch {
        await new Promise((r) => setTimeout(r, 500));
      }
    }

    expect(text).toContain("style.css");
    expect(text).toContain("__zts_register");
  }, 15000);
});
