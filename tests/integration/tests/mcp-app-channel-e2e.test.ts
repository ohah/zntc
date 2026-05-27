// MCP App Channel E2E — Zig dev_server 의 `/__mcp-app` WebSocket 과 MCP HTTP `/mcp`
// 의 양방향 흐름을 진짜 server 띄워서 검증.
//
// 시나리오:
//   1. dev_server 시작 (`zntc --serve --bundle entry.ts --port <free>`).
//   2. Mock app — Bun 의 `new WebSocket(...)` 으로 `/__mcp-app` 접속, hello 메시지 받음.
//      RN 안 mcp-runtime.cjs 가 하는 일을 test thread 안에서 모방.
//   3. MCP HTTP `/mcp tools/call ping_app` 호출 → Zig dispatcher 가 AppChannel 통해
//      mock app 에 `method:"ping"` request 송신 → mock 이 응답 → dispatcher 가 결과를
//      MCP client 에 forward.
//   4. content[0].text 가 `{"pong":...}` 형태 JSON string 임을 검증.
//
// IMPORTANT: 반드시 tests/integration 디렉토리에서 `bun test`로 실행할 것 (메모리 가이드).

import { describe, test, expect, afterEach } from 'bun:test';
import { waitForServer } from '@zntc/test-helpers';
import { createFixture, ZNTC_BIN } from './helpers';
import { join } from 'node:path';

interface Server {
  port: number;
  kill: () => Promise<void>;
}

async function findFreePort(): Promise<number> {
  const sock = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: { data() {} } });
  const port = sock.port;
  sock.stop(true);
  return port;
}

async function startServer(args: string[]): Promise<Server> {
  const port = await findFreePort();
  // F1: stdout/stderr pipe 를 drain 안 하면 OS pipe buffer (~16-64KB) 가득 차서
  // server write block → response 멎음. dev_server 가 verbose log 송신 (`[mcp-app]`,
  // `[bundle.js]` 등) 라 6 test 동안 누적 → flaky. `ignore` 로 drain 우회.
  const proc = Bun.spawn({
    cmd: [ZNTC_BIN, ...args, '--port', String(port)],
    stdout: 'ignore',
    stderr: 'ignore',
  });

  await waitForServer(port, {
    host: '127.0.0.1',
    path: '/bundle.js',
    timeoutMs: 5_000,
    intervalMs: 100,
    requestTimeoutMs: 200,
    acceptStatus: (s) => s === 200 || s === 500,
  });

  return {
    port,
    kill: async () => {
      proc.kill();
      await proc.exited;
    },
  };
}

async function mcpCall(port: number, body: object): Promise<any> {
  const res = await fetch(`http://127.0.0.1:${port}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return res.json();
}

/**
 * Mock RN app — `/__mcp-app` 에 접속해 server 의 request 받으면 `handlers` 의
 * function 호출 후 response 송신. Real `mcp-runtime.cjs` 의 JSON-RPC dispatcher
 * 단순화 버전.
 */
interface MockApp {
  ws: WebSocket;
  helloReceived: Promise<void>;
  close: () => void;
}

function connectMockApp(
  port: number,
  handlers: Record<string, (params: unknown) => unknown>,
): MockApp {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/__mcp-app`);
  let helloResolve!: () => void;
  let helloReject!: (e: Error) => void;
  const helloReceived = new Promise<void>((res, rej) => {
    helloResolve = res;
    helloReject = rej;
  });
  // F2: hello 가 도착하기 전 close/error 시 helloReceived 가 영원히 pending → test
  // 가 bun default timeout 까지 hang. close 시 reject 로 명확 fail.
  ws.addEventListener('close', () => helloReject(new Error('ws closed before hello')), {
    once: true,
  });
  ws.addEventListener('error', () => helloReject(new Error('ws error before hello')), {
    once: true,
  });

  ws.addEventListener('message', (ev) => {
    if (typeof ev.data !== 'string') return;
    let msg: any;
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }
    // hello — 받았다고 신호만.
    if (msg.method === 'connected' && msg.id == null) {
      helloResolve();
      return;
    }
    // server → app request (id + method) → handler 호출 → response 송신.
    if (typeof msg.method === 'string' && msg.id != null) {
      const fn = handlers[msg.method];
      if (typeof fn !== 'function') {
        ws.send(
          JSON.stringify({
            jsonrpc: '2.0',
            id: msg.id,
            error: { code: -32601, message: `Method not found: ${msg.method}` },
          }),
        );
        return;
      }
      try {
        const result = fn(msg.params ?? {});
        // raw escape hatch — `{__raw:true, body:{...}}` 반환 시 wrap 우회.
        // result/error 둘 다 없는 응답 같은 spec-violating case 직접 송신용.
        if (result && (result as any).__raw === true) {
          ws.send(JSON.stringify({ jsonrpc: '2.0', id: msg.id, ...(result as any).body }));
        } else {
          ws.send(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: result ?? {} }));
        }
      } catch (err: any) {
        ws.send(
          JSON.stringify({
            jsonrpc: '2.0',
            id: msg.id,
            error: { code: -32603, message: String(err?.message ?? err) },
          }),
        );
      }
    }
  });

  return {
    ws,
    helloReceived,
    close: () => {
      try {
        ws.close();
      } catch {
        /* ignore */
      }
    },
  };
}

async function waitForWsOpen(ws: WebSocket, timeoutMs = 3000): Promise<void> {
  if (ws.readyState === WebSocket.OPEN) return;
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('ws open timeout')), timeoutMs);
    ws.addEventListener(
      'open',
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
    ws.addEventListener(
      'error',
      () => {
        clearTimeout(timer);
        reject(new Error('ws error before open'));
      },
      { once: true },
    );
  });
}

describe('MCP App Channel E2E (/__mcp-app + /mcp ping_app)', () => {
  let killServer: (() => Promise<void>) | undefined;
  let cleanupFixture: (() => Promise<void>) | undefined;
  let mockApp: MockApp | undefined;

  afterEach(async () => {
    if (mockApp) {
      mockApp.close();
      mockApp = undefined;
    }
    if (killServer) {
      await killServer();
      killServer = undefined;
    }
    if (cleanupFixture) {
      await cleanupFixture();
      cleanupFixture = undefined;
    }
  });

  async function setupServer(): Promise<Server> {
    const fixture = await createFixture({ 'entry.ts': 'console.log("ok");' });
    cleanupFixture = fixture.cleanup;
    const server = await startServer(['--serve', '--bundle', join(fixture.dir, 'entry.ts')]);
    killServer = server.kill;
    return server;
  }

  test('hello 메시지 — connect 직후 `method:"connected"` + protocol id', async () => {
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {});
    await waitForWsOpen(mockApp.ws);
    // 5초 timeout — hello 가 핸드셰이크 직후 송신되어 거의 즉시 도착.
    await Promise.race([
      mockApp.helloReceived,
      new Promise((_, reject) => setTimeout(() => reject(new Error('hello timeout')), 5000)),
    ]);
  });

  test('tools/list — ping_app 노출', async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, { jsonrpc: '2.0', id: 1, method: 'tools/list' });
    const names = result.result.tools.map((t: any) => t.name);
    expect(names).toContain('ping_app');
  });

  test('ping_app — app 미연결 시 -32603 + "app not connected" 진단', async () => {
    const server = await setupServer();
    // mock app connect 안 함.
    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: { name: 'ping_app', arguments: {} },
    });
    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain('app not connected');
  });

  test('ping_app — mock app 연결 + ping handler → 양방향 round-trip', async () => {
    const server = await setupServer();
    let pingReceived = false;
    mockApp = connectMockApp(server.port, {
      ping: (params) => {
        pingReceived = true;
        return { pong: true, src: 'mock', echo: params };
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/call',
      params: { name: 'ping_app', arguments: {} },
    });

    expect(pingReceived).toBe(true);
    expect(result.id).toBe(3);
    expect(result.error).toBeUndefined();
    // content[0].text 가 raw JSON string — double-encoded (MCP 2024-11-05 content[] text-only)
    expect(result.result.content[0].type).toBe('text');
    const innerJson = JSON.parse(result.result.content[0].text);
    expect(innerJson.pong).toBe(true);
    expect(innerJson.src).toBe('mock');
  });

  test('ping_app — mock app 의 handler 가 throw → -32603 forward', async () => {
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {
      ping: () => {
        throw new Error('mock app handler boom');
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 4,
      method: 'tools/call',
      params: { name: 'ping_app', arguments: {} },
    });

    // dispatcher 가 app 의 error response 를 받음 → result 없음 → app 의 error.message
    // 를 추출해 -32603 으로 forward (PR-F1 review F4). throw message ("mock app handler
    // boom") 가 그대로 client 에 도달해야 진단 가능.
    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain('mock app handler boom');
  });

  test('tools/list — find_element 노출', async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, { jsonrpc: '2.0', id: 10, method: 'tools/list' });
    const names = result.result.tools.map((t: any) => t.name);
    expect(names).toContain('find_element');
  });

  test('find_element — mock app 의 fiber search 결과 round-trip', async () => {
    const server = await setupServer();
    let receivedParams: any = null;
    mockApp = connectMockApp(server.port, {
      find_element: (params) => {
        receivedParams = params;
        // mock app 이 fiber tree 순회 흉내 — 매칭 element 반환.
        return { ref: 'e1', component: 'Text', text: 'Hello world' };
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 11,
      method: 'tools/call',
      params: { name: 'find_element', arguments: { by: 'text', value: 'Hello' } },
    });

    // dispatcher 가 args 를 그대로 app params 로 forward 했는지 확인.
    expect(receivedParams).toEqual({ by: 'text', value: 'Hello' });
    expect(result.id).toBe(11);
    expect(result.error).toBeUndefined();
    expect(result.result.content[0].type).toBe('text');
    const innerJson = JSON.parse(result.result.content[0].text);
    expect(innerJson.ref).toBe('e1');
    expect(innerJson.component).toBe('Text');
    expect(innerJson.text).toBe('Hello world');
  });

  test('find_element — mock app handler throw → -32603 + 원본 message forward', async () => {
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {
      find_element: () => {
        throw new Error('fiber root missing');
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 13,
      method: 'tools/call',
      params: { name: 'find_element', arguments: { by: 'text', value: 'x' } },
    });

    // F4: app 의 error.message ("fiber root missing") 가 그대로 client 에 forward.
    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain('fiber root missing');
  });

  test('find_element — mock app 미연결 → -32603 + "app not connected"', async () => {
    const server = await setupServer();
    // mock app connect 안 함.
    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 12,
      method: 'tools/call',
      params: { name: 'find_element', arguments: { by: 'text', value: 'x' } },
    });
    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain('app not connected');
  });

  test('tools/list — inspect_state 노출', async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, { jsonrpc: '2.0', id: 14, method: 'tools/list' });
    const names = result.result.tools.map((t: any) => t.name);
    expect(names).toContain('inspect_state');
  });

  test('inspect_state — ref forward + round-trip', async () => {
    const server = await setupServer();
    let receivedParams: any = null;
    mockApp = connectMockApp(server.port, {
      inspect_state: (params) => {
        receivedParams = params;
        return {
          ref: 'e1',
          component: 'Counter',
          kind: 'function',
          props: { step: 1 },
          hooks: [{ type: 'useState', value: 3 }],
        };
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 15,
      method: 'tools/call',
      params: { name: 'inspect_state', arguments: { ref: 'e1' } },
    });

    expect(receivedParams).toEqual({ ref: 'e1' });
    expect(result.error).toBeUndefined();
    const inner = JSON.parse(result.result.content[0].text);
    expect(inner.component).toBe('Counter');
    expect(inner.kind).toBe('function');
    expect(inner.hooks[0]).toEqual({ type: 'useState', value: 3 });
  });

  test('inspect_state — unknown ref → app throw → -32603 + 원본 메시지 forward', async () => {
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {
      inspect_state: (params: any) => {
        throw new Error('inspect_state: ref `' + params.ref + '` not found');
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 16,
      method: 'tools/call',
      params: { name: 'inspect_state', arguments: { ref: 'e9999' } },
    });

    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain('not found');
  });

  test('tools/list — eval_code 노출', async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, { jsonrpc: '2.0', id: 20, method: 'tools/list' });
    const names = result.result.tools.map((t: any) => t.name);
    expect(names).toContain('eval_code');
  });

  test('eval_code — expression + optional ref forward + 결과 round-trip', async () => {
    const server = await setupServer();
    let receivedParams: any = null;
    mockApp = connectMockApp(server.port, {
      eval_code: (params: any) => {
        receivedParams = params;
        return { ok: true, value: 42, type: 'number' };
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 21,
      method: 'tools/call',
      params: {
        name: 'eval_code',
        arguments: { expression: '6*7', ref: 'e1' },
      },
    });

    expect(receivedParams).toEqual({ expression: '6*7', ref: 'e1' });
    expect(result.error).toBeUndefined();
    const inner = JSON.parse(result.result.content[0].text);
    expect(inner.ok).toBe(true);
    expect(inner.value).toBe(42);
    expect(inner.type).toBe('number');
  });

  test('eval_code — params 누락 → app throw → -32603 + 원본 메시지 forward', async () => {
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {
      eval_code: () => {
        throw new Error('eval_code: params requires `expression` (string)');
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 22,
      method: 'tools/call',
      params: { name: 'eval_code', arguments: {} },
    });

    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain('requires `expression`');
  });

  test('tools/list — get_logs 노출', async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, { jsonrpc: '2.0', id: 30, method: 'tools/list' });
    const names = result.result.tools.map((t: any) => t.name);
    expect(names).toContain('get_logs');
  });

  test('get_logs — since/level/limit forward + 결과 round-trip', async () => {
    const server = await setupServer();
    let receivedParams: any = null;
    mockApp = connectMockApp(server.port, {
      get_logs: (params) => {
        receivedParams = params;
        return {
          entries: [
            { seq: 1, ts: 1000, level: 'warn', args: ['hello'] },
            { seq: 2, ts: 1100, level: 'warn', args: ['world'] },
          ],
          dropped: 0,
          total: 2,
        };
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 31,
      method: 'tools/call',
      params: {
        name: 'get_logs',
        arguments: { since: 500, level: 'warn', limit: 10 },
      },
    });

    expect(receivedParams).toEqual({ since: 500, level: 'warn', limit: 10 });
    expect(result.error).toBeUndefined();
    const inner = JSON.parse(result.result.content[0].text);
    expect(inner.entries.length).toBe(2);
    expect(inner.entries[0].level).toBe('warn');
    expect(inner.entries[0].args).toEqual(['hello']);
    expect(inner.total).toBe(2);
  });

  test('get_logs — invalid level → app throw → -32603 + 원본 메시지', async () => {
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {
      get_logs: () => {
        throw new Error('get_logs: invalid `level` -- must be one of log/info/warn/error/debug');
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 32,
      method: 'tools/call',
      params: { name: 'get_logs', arguments: { level: 'verbose' } },
    });

    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain('invalid `level`');
  });

  test('tools/list — take_snapshot 노출', async () => {
    const server = await setupServer();
    const result = await mcpCall(server.port, { jsonrpc: '2.0', id: 40, method: 'tools/list' });
    const names = result.result.tools.map((t: any) => t.name);
    expect(names).toContain('take_snapshot');
  });

  test('take_snapshot — option forward + 결과 round-trip', async () => {
    const server = await setupServer();
    let receivedParams: any = null;
    mockApp = connectMockApp(server.port, {
      take_snapshot: (params) => {
        receivedParams = params;
        return {
          roots: [
            {
              ref: 'e1',
              component: 'App',
              children: [{ ref: 'e2', component: 'Text', text: 'Hi' }],
            },
          ],
          nodes: 2,
          truncated: false,
        };
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 41,
      method: 'tools/call',
      params: {
        name: 'take_snapshot',
        arguments: { max_depth: 4, max_nodes: 100 },
      },
    });

    expect(receivedParams).toEqual({ max_depth: 4, max_nodes: 100 });
    expect(result.error).toBeUndefined();
    const inner = JSON.parse(result.result.content[0].text);
    expect(inner.nodes).toBe(2);
    expect(inner.roots[0].component).toBe('App');
    expect(inner.roots[0].children[0].text).toBe('Hi');
  });

  test('take_snapshot — unknown ref → app throw → -32603', async () => {
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {
      take_snapshot: (params: any) => {
        throw new Error('take_snapshot: ref `' + params.ref + '` not found');
      },
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 42,
      method: 'tools/call',
      params: { name: 'take_snapshot', arguments: { ref: 'e9999' } },
    });

    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain('not found');
  });

  test('forwardAppTool fallback — app response 가 result/error 둘 다 없으면 "missing \'result\'" (#50)', async () => {
    // PR-F1 review F4 fallback path. 정상 mock 은 항상 result 또는 error 를 보내지만,
    // spec-violating app (또는 race condition 으로 partial response) 가 둘 다 없는
    // envelope 송신 시 dispatcher 가 silent fail 안 하고 명시 진단. raw escape hatch
    // 로 직접 mock.
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {
      ping: () => ({ __raw: true, body: {} }), // {jsonrpc, id} 만, result/error 없음
    });
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    const result = await mcpCall(server.port, {
      jsonrpc: '2.0',
      id: 50,
      method: 'tools/call',
      params: { name: 'ping_app', arguments: {} },
    });

    expect(result.error).toBeDefined();
    expect(result.error.code).toBe(-32603);
    expect(result.error.message).toContain("missing 'result'");
  });

  test('app 두 번째 연결 — first-wins 거절', async () => {
    const server = await setupServer();
    mockApp = connectMockApp(server.port, {});
    await waitForWsOpen(mockApp.ws);
    await mockApp.helloReceived;

    // 두 번째 connect — error 메시지 (`-32000 another app already connected`) 후 close.
    // listener race 회피: WebSocket 인스턴스 생성 직후 (open 전) listener 등록.
    const second = new WebSocket(`ws://127.0.0.1:${server.port}/__mcp-app`);
    const messages: string[] = [];
    second.addEventListener('message', (ev) => {
      if (typeof ev.data === 'string') messages.push(ev.data);
    });
    await waitForWsOpen(second);
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, 1000);
      second.addEventListener(
        'close',
        () => {
          clearTimeout(timer);
          resolve();
        },
        { once: true },
      );
    });
    expect(messages.length).toBeGreaterThanOrEqual(1);
    const errMsg = messages[0];
    expect(errMsg).toContain('-32000');
    expect(errMsg).toContain('another app already connected');
    try {
      second.close();
    } catch {
      /* already closed */
    }
  });
});
