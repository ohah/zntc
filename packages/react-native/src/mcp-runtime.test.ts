// mcp-runtime.cjs (PR-E2) — WS client 단위 test.
//
// 실 WebSocket 안 사용. mock WebSocket 으로 connect → hello parse → dispatch →
// reconnect lifecycle 검증.

import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { createRequire } from 'node:module';
import { join } from 'node:path';

const RUNTIME_PATH = join(__dirname, '..', 'runtime', 'mcp-runtime.cjs');
const reqFromHere = createRequire(__filename);
const { startMcpRuntime } = reqFromHere(RUNTIME_PATH) as {
  startMcpRuntime: (g: unknown) => void;
};

interface MockWsEvent {
  data?: unknown;
}

interface MockWs {
  url: string;
  sent: string[];
  onopen?: () => void;
  onmessage?: (ev: MockWsEvent) => void;
  onerror?: () => void;
  onclose?: () => void;
  send: (data: string) => void;
  close: () => void;
  triggerOpen: () => void;
  triggerMessage: (data: string) => void;
  triggerClose: () => void;
  closed: boolean;
}

interface FakeGlobal {
  WebSocket?: (url: string) => MockWs;
  __ZNTC_MCP_RUNTIME__?: unknown;
  __ZNTC_MCP_APP_WS_URL__?: string;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (id: unknown) => void;
  setTimeout_calls?: Array<{ fn: () => void; ms: number }>;
  // helper to flush all pending setTimeout 0-delay tasks
  __flushImmediate?: () => void;
}

/**
 * runtime 의 startMcpRuntime 함수를 mock global 과 함께 호출. cross-context closure
 * 문제 없이 단순 function call — outer Bun realm 에서 직접 실행.
 */
function loadRuntime(g: FakeGlobal): void {
  startMcpRuntime(g);
}

function makeMockWs(url: string): MockWs {
  const ws: MockWs = {
    url,
    sent: [],
    closed: false,
    send(data: string) {
      this.sent.push(data);
    },
    close() {
      if (this.closed) return;
      this.closed = true;
      this.onclose?.();
    },
    triggerOpen() {
      this.onopen?.();
    },
    triggerMessage(data: string) {
      this.onmessage?.({ data });
    },
    triggerClose() {
      this.close();
    },
  };
  return ws;
}

let g: FakeGlobal;
let lastWs: MockWs | null;

beforeEach(() => {
  lastWs = null;
  g = {};
  // Regular function — `new` 가능. arrow function 은 constructor 못 됨.
  g.WebSocket = function MockWebSocketCtor(url: string) {
    const ws = makeMockWs(url);
    lastWs = ws;
    return ws;
  } as unknown as FakeGlobal['WebSocket'];
  g.setTimeout_calls = [];
  g.setTimeout = ((fn: () => void, ms: number) => {
    g.setTimeout_calls!.push({ fn, ms });
    // 0-delay task 는 즉시 실행으로 시뮬레이션 (microtask 대용)
    if (ms === 0) fn();
    return 0;
  }) as FakeGlobal['setTimeout'];
});

afterEach(() => {
  // explicit cleanup
  if (lastWs) lastWs.close();
});

describe('mcp-runtime.cjs (PR-E2) — load + connect', () => {
  test('runtime 등록 — __ZNTC_MCP_RUNTIME__ 의 핵심 field', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as Record<string, unknown>;
    expect(rt).toBeDefined();
    expect(rt.loaded).toBe(true);
    expect(typeof rt.version).toBe('string');
    expect(typeof rt.handlers).toBe('object');
  });

  test('idempotent — 두 번 evaluate 해도 1번만 connect', () => {
    loadRuntime(g);
    const calls1 = g.setTimeout_calls!.length;
    loadRuntime(g);
    const calls2 = g.setTimeout_calls!.length;
    // 두 번째 evaluate 는 early return (loaded=true)
    expect(calls2).toBe(calls1);
  });

  test('WebSocket 미지원 환경 — connectionState=unsupported, ws=null', () => {
    g.WebSocket = undefined as unknown as FakeGlobal['WebSocket'];
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as Record<string, unknown>;
    expect(rt.connectionState).toBe('unsupported');
    expect(rt.ws).toBe(null);
  });

  test('default URL — ws://localhost:12300/__mcp-app', () => {
    loadRuntime(g);
    expect(lastWs).toBeDefined();
    expect(lastWs!.url).toBe('ws://localhost:12300/__mcp-app');
  });

  test('__ZNTC_MCP_APP_WS_URL__ override — 사용자 / 빌드 inject URL 우선', () => {
    g.__ZNTC_MCP_APP_WS_URL__ = 'ws://10.0.0.1:8080/__mcp-app';
    loadRuntime(g);
    expect(lastWs!.url).toBe('ws://10.0.0.1:8080/__mcp-app');
  });
});

describe('mcp-runtime.cjs (PR-E2) — dispatch', () => {
  test('hello 메시지 (`method: "connected"`, protocol mcp-app-1) — 정상 통과, close 안 함', () => {
    loadRuntime(g);
    lastWs!.triggerOpen();
    lastWs!.triggerMessage(
      '{"jsonrpc":"2.0","method":"connected","params":{"protocol":"mcp-app-1"}}',
    );
    expect(lastWs!.closed).toBe(false);
  });

  test('hello 의 protocol mismatch — close 후 reconnect 안 함', () => {
    loadRuntime(g);
    lastWs!.triggerOpen();
    lastWs!.triggerMessage(
      '{"jsonrpc":"2.0","method":"connected","params":{"protocol":"mcp-app-99"}}',
    );
    expect(lastWs!.closed).toBe(true);
    // protocolMismatch sentinel 로 reconnect schedule 안 됨 — 0-delay 외 추가 setTimeout 없음.
    // close() API 의 closedExplicitly 와 별도 sentinel — 두 case 구분.
    const reconnectScheduled = g.setTimeout_calls!.some((c) => c.ms > 0);
    expect(reconnectScheduled).toBe(false);
  });

  test('일반 RPC 의 nested params 에 "method":"connected" 가 있어도 hello 로 오인 안 함 (F1 회귀 잠금)', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    let dispatched: unknown = null;
    rt.handlers['app/dispatch'] = (params) => {
      dispatched = params;
      return { ok: true };
    };
    lastWs!.triggerOpen();
    // nested action 안에 `"method":"connected"` 문자열이 들어있는 정상 RPC.
    lastWs!.triggerMessage(
      '{"jsonrpc":"2.0","id":99,"method":"app/dispatch","params":{"action":{"method":"connected","payload":{}}}}',
    );
    // close 되면 안 됨 (이전 substring 기반 코드는 여기서 protocol mismatch 분기로 close 했었음).
    expect(lastWs!.closed).toBe(false);
    expect(dispatched).toEqual({ action: { method: 'connected', payload: {} } });
    expect(lastWs!.sent.length).toBe(1);
    const resp = JSON.parse(lastWs!.sent[0]);
    expect(resp.id).toBe(99);
    expect(resp.result).toEqual({ ok: true });
  });

  test('hello 의 protocol 키 부재 (server bug) — mismatch 로 처리, close', () => {
    loadRuntime(g);
    lastWs!.triggerOpen();
    // `connected` method 인데 params.protocol 누락.
    lastWs!.triggerMessage('{"jsonrpc":"2.0","method":"connected","params":{}}');
    expect(lastWs!.closed).toBe(true);
  });

  test('request 메시지 (id + method) — handler 호출 → response send', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    rt.handlers.ping = (params: unknown) => ({ pong: true, params });

    lastWs!.triggerOpen();
    lastWs!.triggerMessage('{"jsonrpc":"2.0","id":42,"method":"ping","params":{"hello":1}}');

    expect(lastWs!.sent.length).toBe(1);
    const resp = JSON.parse(lastWs!.sent[0]);
    expect(resp).toEqual({
      jsonrpc: '2.0',
      id: 42,
      result: { pong: true, params: { hello: 1 } },
    });
  });

  test('request 메시지 — unknown method → -32601 error response', () => {
    loadRuntime(g);
    lastWs!.triggerOpen();
    lastWs!.triggerMessage('{"jsonrpc":"2.0","id":7,"method":"nope"}');
    expect(lastWs!.sent.length).toBe(1);
    const resp = JSON.parse(lastWs!.sent[0]);
    expect(resp.error).toBeDefined();
    expect(resp.error.code).toBe(-32601);
    expect(resp.id).toBe(7);
  });

  test('request handler 가 throw → -32603 Internal error', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    rt.handlers.kaboom = () => {
      throw new Error('test failure');
    };
    lastWs!.triggerOpen();
    lastWs!.triggerMessage('{"jsonrpc":"2.0","id":3,"method":"kaboom"}');
    const resp = JSON.parse(lastWs!.sent[0]);
    expect(resp.error.code).toBe(-32603);
    expect(resp.error.message).toContain('test failure');
  });

  test('notification (id 없음) — 핸들러 호출 후 응답 안 보냄', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    let called = false;
    rt.handlers['hello/notify'] = () => {
      called = true;
    };
    lastWs!.triggerOpen();
    lastWs!.triggerMessage('{"jsonrpc":"2.0","method":"hello/notify","params":{}}');
    expect(called).toBe(true);
    expect(lastWs!.sent.length).toBe(0);
  });

  test('invalid JSON → 무시 (응답 안 보냄, throw 안 함)', () => {
    loadRuntime(g);
    lastWs!.triggerOpen();
    lastWs!.triggerMessage('not-json{');
    expect(lastWs!.sent.length).toBe(0);
  });
});

describe('mcp-runtime.cjs (PR-E2) — reconnect', () => {
  test('connection close 후 reconnect schedule (지수 backoff)', () => {
    loadRuntime(g);
    lastWs!.triggerOpen();
    // backoff 시작값 1000ms
    lastWs!.triggerClose();
    const scheduled = g.setTimeout_calls!.filter((c) => c.ms > 0);
    expect(scheduled.length).toBeGreaterThanOrEqual(1);
    expect(scheduled[0].ms).toBe(1000);
  });

  test('open 성공 시 backoff reset — 다음 close 도 1000ms 부터 시작', () => {
    loadRuntime(g);
    // 첫 connect open → close → reconnect (1000ms)
    lastWs!.triggerOpen();
    lastWs!.triggerClose();
    // setTimeout 콜 발화
    const firstReconnect = g.setTimeout_calls!.filter((c) => c.ms > 0)[0];
    firstReconnect.fn(); // 두 번째 connect
    lastWs!.triggerOpen(); // success
    lastWs!.triggerClose();
    const reconnects = g.setTimeout_calls!.filter((c) => c.ms > 0);
    // 두 번째 reconnect 도 1000ms (open 후 reset)
    expect(reconnects[reconnects.length - 1].ms).toBe(1000);
  });

  test('send drop warn — WS 닫힘 후 응답 send 시 console.warn (F7 deferred)', () => {
    const warnings: unknown[] = [];
    g.console = {
      warn: (...args: unknown[]) => warnings.push(args),
      log: () => {},
      error: () => {},
    } as unknown as Console;
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    // handler 가 동기 응답을 send 시도 — 그 사이 WS 가 닫혀 있다면?
    rt.handlers.echo = () => ({ ok: true });

    lastWs!.triggerOpen();
    // close 먼저 발생 후 dispatcher 가 try send.
    lastWs!.triggerClose();
    // close 후 message 받으면 — runtime 의 dispatch 가 호출되어 handler → send 시도.
    // 단 onmessage 가 close 후엔 호출 안 됨 (mockWs 의 spec). 직접 send 호출 시뮬레이션:
    // runtime 의 내부 send 는 직접 access 불가 — handler 호출 시뮬레이션 어려움.
    // 대신 onmessage 가 closed 상태에서 호출됐을 때 send 가 warn 하는지 검증:
    lastWs!.onmessage?.({ data: '{"jsonrpc":"2.0","id":1,"method":"echo"}' });
    // send 호출 시 state.connectionState !== 'open' 라 warn + return false
    const warnedCount = warnings.filter(
      (w) => Array.isArray(w) && typeof w[0] === 'string' && w[0].includes('send drop'),
    ).length;
    expect(warnedCount).toBeGreaterThanOrEqual(1);
  });

  test('close() 호출 — reconnect 안 함', () => {
    loadRuntime(g);
    lastWs!.triggerOpen();
    const rt = g.__ZNTC_MCP_RUNTIME__ as { close: () => void };
    rt.close();
    const scheduled = g.setTimeout_calls!.filter((c) => c.ms > 0);
    expect(scheduled.length).toBe(0);
  });
});
