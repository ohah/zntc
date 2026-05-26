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

  test('handlers.ping override — user implementation 이 default 보다 우선 (F4 retroactive)', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    // user 가 default 후 override
    rt.handlers.ping = () => ({ custom: true, src: 'user' });

    lastWs!.triggerOpen();
    lastWs!.triggerMessage('{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}');
    const resp = JSON.parse(lastWs!.sent[0]);
    expect(resp.result).toEqual({ custom: true, src: 'user' });
    // default 의 pong/ts 가 안 나와야 함
    expect(resp.result.pong).toBeUndefined();
  });

  test('default `ping` handler — `ping_app` MCP tool 의 양방향 sanity check', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    // ping 이 기본 등록되어 있어야 함 (별도 user handler 추가 없음)
    expect(typeof rt.handlers.ping).toBe('function');

    lastWs!.triggerOpen();
    lastWs!.triggerMessage('{"jsonrpc":"2.0","id":7,"method":"ping","params":{"src":"test"}}');

    expect(lastWs!.sent.length).toBe(1);
    const resp = JSON.parse(lastWs!.sent[0]);
    expect(resp.id).toBe(7);
    expect(resp.result.pong).toBe(true);
    expect(typeof resp.result.ts).toBe('number');
    expect(resp.result.echo).toEqual({ src: 'test' });
  });

  test('invalid JSON → 무시 (응답 안 보냄, throw 안 함)', () => {
    loadRuntime(g);
    lastWs!.triggerOpen();
    lastWs!.triggerMessage('not-json{');
    expect(lastWs!.sent.length).toBe(0);
  });
});

describe('mcp-runtime.cjs (PR-E2) — reconnect', () => {
  test('WebSocket constructor throw — scheduleReconnect 호출 (F6 deferred 회귀 잠금)', () => {
    // 일부 RN 버전 / 이상한 URL / 네트워크 정책 issue 로 `new WebSocket(...)` 가 즉시
    // throw 가능. catch 후 reconnect schedule 되어야 함.
    g.WebSocket = function ThrowingWebSocket() {
      throw new Error('socket creation failed');
    } as unknown as FakeGlobal['WebSocket'];
    loadRuntime(g);
    // 첫 setTimeout(connect, 0) 실행 → connect 안 throw → catch → scheduleReconnect (1000ms)
    const scheduled = g.setTimeout_calls!.filter((c) => c.ms > 0);
    expect(scheduled.length).toBeGreaterThanOrEqual(1);
    expect(scheduled[0].ms).toBe(1000);
  });

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

  test('send drop warn — connecting 상태 (handler 가 open 전 message 받음) 의 documented race path', () => {
    // 진짜 race: handler 가 message 받았는데 state.connectionState === 'connecting' 인
    // 짧은 윈도우. 이전 test 는 close 후 onmessage 강제호출 (state.ws === null 분기) 라
    // 사실상 trivial branch 만 검증. 이번엔 'connecting' state 에서 send drop path 진입.
    const warnings: string[] = [];
    g.console = {
      warn: (msg: string) => warnings.push(msg),
      log: () => {},
      error: () => {},
    } as unknown as Console;
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as {
      handlers: Record<string, (p: unknown) => unknown>;
      connectionState: string;
    };
    rt.handlers.echo = () => ({ ok: true });

    // onopen 미발화 — state.connectionState === 'connecting'
    expect(rt.connectionState).toBe('connecting');
    lastWs!.triggerMessage('{"jsonrpc":"2.0","id":42,"method":"echo"}');

    // send drop warn 발생 + id + state 표시
    expect(warnings.length).toBe(1);
    expect(warnings[0]).toContain('send drop');
    expect(warnings[0]).toContain('id=42');
    expect(warnings[0]).toContain('state=connecting');
    // 응답 byte 안 보냄 (drop)
    expect(lastWs!.sent.length).toBe(0);
  });

  test('send drop warn — g.console === null 환경에서도 throw 안 함 (F4 retroactive)', () => {
    // RN sandbox 가 `globalThis.console = null` 설정 시 `typeof === "object"` 통과해
    // 그 다음 `.warn` 접근에서 null deref. 가드가 truthy check 로 강화되어야 OK.
    g.console = null as unknown as Console;
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    rt.handlers.echo = () => ({ ok: true });
    expect(() => {
      lastWs!.triggerMessage('{"jsonrpc":"2.0","id":1,"method":"echo"}');
    }).not.toThrow();
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

// PR-F1 — find_element. fiber tree 순회 + opaque ref. 실 React 없이 minimal mock
// fiber 로 검증 — Playwright MCP 의 ref(e1, e2) 패턴 동치 동작 확인.
interface FakeFiber {
  type?: unknown;
  memoizedProps?: unknown;
  child?: FakeFiber | null;
  sibling?: FakeFiber | null;
  stateNode?: unknown;
  _debugSource?: { fileName?: string; lineNumber?: number };
}

interface FakeFiberRoot {
  current: FakeFiber;
}

function makeFiberHook(g: FakeGlobal, roots: FakeFiberRoot[]): void {
  (g as unknown as Record<string, unknown>).__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
    renderers: new Map([[1, {}]]),
    getFiberRoots: (_rendererID: number) => new Set(roots),
  };
}

describe('mcp-runtime.cjs (PR-F1) — find_element', () => {
  // PR-F1 review F4: 잘못된 input 은 `{error}` return 대신 throw — dispatcher (onmessage) 가
  // catch 해서 JSON-RPC `-32603 Internal error` 로 wrap.
  test('params 누락 → throw: requires `by` and `value`', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.find_element({})).toThrow(/requires `by`/);
    expect(() => rt.handlers.find_element({ by: 'text' })).toThrow(/requires `by`/);
  });

  test('unknown `by` → throw: only text/role/component supported', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.find_element({ by: 'xpath', value: '//div' })).toThrow(/unknown `by`/);
  });

  test('DevTools hook 없음 → throw: no React fiber root found', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.find_element({ by: 'text', value: 'Hello' })).toThrow(
      /no React fiber root/,
    );
  });

  test('by=text — fiber.memoizedProps.children 매칭 + opaque ref 부여', () => {
    // App > View > Text("Hello world")
    const textFiber: FakeFiber = {
      type: 'Text',
      memoizedProps: { children: 'Hello world' },
    };
    const viewFiber: FakeFiber = {
      type: 'View',
      memoizedProps: { accessibilityRole: 'group' },
      child: textFiber,
    };
    const appFiber: FakeFiber = {
      type: { displayName: 'App' },
      memoizedProps: {},
      child: viewFiber,
    };
    makeFiberHook(g, [{ current: appFiber }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.find_element({ by: 'text', value: 'Hello' }) as {
      ref?: string;
      component?: string;
      text?: string;
    };
    expect(r.ref).toMatch(/^e\d+$/);
    expect(r.component).toBe('Text');
    expect(r.text).toBe('Hello world');

    // 같은 인스턴스 두 번 find → 새 ref 부여 (캐시 안 함 — 매번 fresh)
    const r2 = rt.handlers.find_element({ by: 'text', value: 'Hello' }) as { ref?: string };
    expect(r2.ref).not.toBe(r.ref);
  });

  test('by=role — props.accessibilityRole 또는 props.role 매칭', () => {
    const btnFiber: FakeFiber = {
      type: 'View',
      memoizedProps: { accessibilityRole: 'button', accessibilityLabel: 'Submit' },
    };
    const linkFiber: FakeFiber = {
      type: 'View',
      memoizedProps: { role: 'link' },
    };
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: btnFiber,
    };
    btnFiber.sibling = linkFiber;
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r1 = rt.handlers.find_element({ by: 'role', value: 'button' }) as {
      ref?: string;
      role?: string;
      label?: string;
    };
    expect(r1.ref).toBeDefined();
    expect(r1.role).toBe('button');
    expect(r1.label).toBe('Submit');

    const r2 = rt.handlers.find_element({ by: 'role', value: 'link' }) as { role?: string };
    expect(r2.role).toBe('link');
  });

  test('by=component — getComponentName 매칭 (host string + displayName/name)', () => {
    const myButton: FakeFiber = {
      type: { displayName: 'MyButton' },
      memoizedProps: {},
    };
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: myButton,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.find_element({ by: 'component', value: 'MyButton' }) as {
      component?: string;
    };
    expect(r.component).toBe('MyButton');
  });

  test('DFS first-match 순서 — child 가 sibling 보다 먼저 visited (review F4 회귀 잠금)', () => {
    // root
    //   ├ child  (Component A — accessibilityRole=button)
    //   └ sibling (Component B — accessibilityRole=button)
    // DFS stack push 순서: sibling → child → child pop 먼저 → A 매칭.
    // walkFiber 의 push order (sibling first, child last) 가 child-first 보장.
    const fiberA: FakeFiber = {
      type: { displayName: 'A' },
      memoizedProps: { accessibilityRole: 'button' },
    };
    const fiberB: FakeFiber = {
      type: { displayName: 'B' },
      memoizedProps: { accessibilityRole: 'button' },
    };
    fiberA.sibling = fiberB;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiberA,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.find_element({ by: 'role', value: 'button' }) as { component?: string };
    expect(r.component).toBe('A');
  });

  test('refMap LRU cap — 256 entry 후 oldest evicted (review F3 회귀 잠금)', () => {
    // 매우 큰 트리는 비현실 — root child chain 으로 LRU 검증.
    // 257번째 find 시 e1 이 evicted, e2~e257 + e258 살아있음.
    // walkFiber 가 stack 기반 DFS — child 만 따라가는 chain 만들기.
    function makeChain(n: number): FakeFiber {
      let last: FakeFiber = {
        type: 'Text',
        memoizedProps: { children: 'leaf' },
      };
      for (let i = 0; i < n; i++) {
        last = {
          type: { displayName: 'C' + i },
          memoizedProps: {},
          child: last,
        };
      }
      return last;
    }
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: makeChain(1),
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    // 260번 find — 같은 'leaf' 매칭. 매 호출마다 새 ref. e1~e260.
    const refs: string[] = [];
    for (let i = 0; i < 260; i++) {
      const r = rt.handlers.find_element({ by: 'text', value: 'leaf' }) as { ref: string };
      refs.push(r.ref);
    }
    expect(refs.length).toBe(260);
    // 256 cap — e1~e4 evicted, e5~e260 살아있음.
    const has = (ref: string) =>
      (rt.handlers.__getFiberByRef({ ref }) as { has?: boolean }).has === true;
    expect(has('e1')).toBe(false);
    expect(has('e4')).toBe(false);
    expect(has('e5')).toBe(true);
    expect(has('e260')).toBe(true);
  });

  test('__getFiberByRef — 등록된 ref 는 has:true, 없는 ref 는 has:false', () => {
    const fiber: FakeFiber = {
      type: 'Text',
      memoizedProps: { children: 'X' },
    };
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.find_element({ by: 'text', value: 'X' }) as { ref: string };
    expect((rt.handlers.__getFiberByRef({ ref: r.ref }) as { has?: boolean }).has).toBe(true);
    expect((rt.handlers.__getFiberByRef({ ref: 'e9999' }) as { has?: boolean }).has).toBe(false);
  });

  test('매칭 없음 → { found: false }', () => {
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.find_element({ by: 'text', value: 'NotPresent' }) as {
      found?: boolean;
    };
    expect(r.found).toBe(false);
  });

  test('serializeFiber — testID + source(_debugSource) 포함', () => {
    const fiber: FakeFiber = {
      type: 'Text',
      memoizedProps: { children: 'Tagged', testID: 'btn-1' },
      _debugSource: { fileName: '/abs/path/App.tsx', lineNumber: 42 },
    };
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.find_element({ by: 'text', value: 'Tagged' }) as {
      testID?: string;
      source?: string;
    };
    expect(r.testID).toBe('btn-1');
    expect(r.source).toBe('/abs/path/App.tsx:42');
  });
});
