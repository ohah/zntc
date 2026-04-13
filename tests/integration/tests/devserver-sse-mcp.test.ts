// SSE / Control API / MCP 통합 테스트
//
// `zts --serve --bundle entry.ts`를 subprocess로 띄우고, 같은 프로세스의 fetch로
// HTTP 엔드포인트(`/sse/events`, `/reset-cache`, `/mcp`)를 검증한다.
//
// IMPORTANT: 반드시 tests/integration 디렉토리에서 `bun test`로 실행할 것.

import { describe, test, expect, afterEach } from "bun:test";
import { createFixture, ZTS_BIN } from "./helpers";
import { join } from "node:path";

interface Server {
  port: number;
  kill: () => Promise<void>;
}

async function findFreePort(): Promise<number> {
  // 임의의 미사용 포트 — listen + close 후 OS가 곧바로 재할당
  const sock = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } });
  const port = sock.port;
  sock.stop(true);
  return port;
}

async function startServer(args: string[]): Promise<Server> {
  const port = await findFreePort();
  const proc = Bun.spawn({
    cmd: [ZTS_BIN, ...args, "--port", String(port)],
    stdout: "pipe",
    stderr: "pipe",
  });

  // 서버 ready 대기 — bundle.js GET 성공할 때까지 최대 5초 polling
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/bundle.js`, {
        signal: AbortSignal.timeout(200),
      });
      if (res.ok || res.status === 500) {
        await res.text();
        break;
      }
    } catch {
      // 아직 listen 안 됨
    }
    await new Promise((r) => setTimeout(r, 100));
  }

  return {
    port,
    kill: async () => {
      proc.kill();
      await proc.exited;
    },
  };
}

describe("Dev Server: SSE / Control API / MCP", () => {
  let killServer: (() => Promise<void>) | undefined;
  let cleanupFixture: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (killServer) {
      await killServer();
      killServer = undefined;
    }
    if (cleanupFixture) {
      await cleanupFixture();
      cleanupFixture = undefined;
    }
  });

  async function setupServer() {
    const fixture = await createFixture({
      "entry.ts": `console.log("ok");`,
    });
    cleanupFixture = fixture.cleanup;
    const server = await startServer(["--serve", "--bundle", join(fixture.dir, "entry.ts")]);
    killServer = server.kill;
    return server;
  }

  // ─── Control API ───────────────────────────────────────────

  test("/reset-cache: 200 + JSON ok 응답", async () => {
    const server = await setupServer();
    const res = await fetch(`http://127.0.0.1:${server.port}/reset-cache`, {
      method: "POST",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(true);
    expect(body.action).toBe("reset_cache");
  });

  test("/reset-cache: GET도 허용", async () => {
    const server = await setupServer();
    const res = await fetch(`http://127.0.0.1:${server.port}/reset-cache`);
    expect(res.status).toBe(200);
  });

  // ─── SSE ───────────────────────────────────────────────────

  test("/sse/events: text/event-stream 헤더 + 초기 연결 메시지", async () => {
    const server = await setupServer();
    const controller = new AbortController();
    const res = await fetch(`http://127.0.0.1:${server.port}/sse/events`, {
      signal: controller.signal,
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/event-stream");

    // 첫 청크에 ": connected" 주석 포함
    const reader = res.body!.getReader();
    const { value } = await reader.read();
    const text = new TextDecoder().decode(value);
    expect(text).toContain(": connected");

    controller.abort();
    await reader.cancel().catch(() => {});
  });

  test("/sse/events: cache_reset 이벤트 broadcast", async () => {
    const server = await setupServer();
    const controller = new AbortController();
    const res = await fetch(`http://127.0.0.1:${server.port}/sse/events`, {
      signal: controller.signal,
    });
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();

    // 초기 연결 메시지 소비
    await reader.read();

    // 별도 클라이언트가 /reset-cache 호출 → SSE 이벤트 발생
    fetch(`http://127.0.0.1:${server.port}/reset-cache`, { method: "POST" }).catch(() => {});

    // cache_reset 이벤트 수신 대기 (최대 3초)
    let received = "";
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline && !received.includes("cache_reset")) {
      const { value, done } = await reader.read();
      if (done) break;
      received += decoder.decode(value);
    }
    expect(received).toContain("event: cache_reset");
    expect(received).toContain('"type":"cache_reset"');

    controller.abort();
    await reader.cancel().catch(() => {});
  });

  // ─── MCP ───────────────────────────────────────────────────

  async function mcpCall(port: number, body: object): Promise<any> {
    const res = await fetch(`http://127.0.0.1:${port}/mcp`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    expect(res.status).toBe(200);
    return res.json();
  }

  test("MCP initialize: protocolVersion + serverInfo", async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {},
    });
    expect(result.jsonrpc).toBe("2.0");
    expect(result.id).toBe(1);
    expect(result.result.protocolVersion).toBe("2024-11-05");
    expect(result.result.serverInfo.name).toBe("zts-dev-server");
    expect(result.result.capabilities.tools).toBeDefined();
  });

  test("MCP tools/list: reset_cache + get_build_events 노출", async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/list",
    });
    const names = result.result.tools.map((t: any) => t.name);
    expect(names).toContain("reset_cache");
    expect(names).toContain("get_build_events");
    // inputSchema 필수 — MCP 클라이언트가 도구 호출 시 검증에 사용
    for (const tool of result.result.tools) {
      expect(tool.inputSchema).toBeDefined();
      expect(tool.inputSchema.type).toBe("object");
    }
  });

  test("MCP tools/call reset_cache: 캐시 리셋 트리거", async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "reset_cache", arguments: {} },
    });
    expect(result.id).toBe(3);
    expect(result.result.content[0].type).toBe("text");
    expect(result.result.content[0].text).toContain("Cache reset requested");
  });

  test("MCP tools/call get_build_events: duration 짧게 → 빈 events 또는 일부 수신", async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, {
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: { name: "get_build_events", arguments: { duration: 1000 } },
    });
    // 결과 text는 JSON 배열 문자열
    const text = result.result.content[0].text;
    const events = JSON.parse(text);
    expect(Array.isArray(events)).toBe(true);
  });

  test("MCP: 알 수 없는 method → -32601 에러", async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, {
      jsonrpc: "2.0",
      id: 5,
      method: "no_such_method",
    });
    expect(result.error.code).toBe(-32601);
    expect(result.error.message).toContain("Method not found");
  });

  test("MCP: invalid JSON body → -32700 parse error", async () => {
    const server = await setupServer();
    const res = await fetch(`http://127.0.0.1:${server.port}/mcp`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "not json {{{",
    });
    expect(res.status).toBe(200);
    const result = await res.json();
    expect(result.error.code).toBe(-32700);
  });

  test("MCP: GET → 405 Method Not Allowed", async () => {
    const server = await setupServer();
    const res = await fetch(`http://127.0.0.1:${server.port}/mcp`);
    expect(res.status).toBe(405);
  });

  test("MCP: body 64KB 초과 → 413", async () => {
    const server = await setupServer();
    const big = "x".repeat(70 * 1024);
    const res = await fetch(`http://127.0.0.1:${server.port}/mcp`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: `{"jsonrpc":"2.0","id":1,"method":"x","params":{"big":"${big}"}}`,
    });
    expect(res.status).toBe(413);
  });

  test("MCP tools/call reset_cache → SSE cache_reset 이벤트 발생", async () => {
    const server = await setupServer();
    const controller = new AbortController();
    const sseRes = await fetch(`http://127.0.0.1:${server.port}/sse/events`, {
      signal: controller.signal,
    });
    const reader = sseRes.body!.getReader();
    const decoder = new TextDecoder();
    await reader.read(); // 초기 연결 메시지

    // MCP로 reset_cache 호출
    fetch(`http://127.0.0.1:${server.port}/mcp`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "reset_cache", arguments: {} },
      }),
    }).catch(() => {});

    let received = "";
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline && !received.includes("cache_reset")) {
      const { value, done } = await reader.read();
      if (done) break;
      received += decoder.decode(value);
    }
    expect(received).toContain("cache_reset");
    controller.abort();
    await reader.cancel().catch(() => {});
  });
});
