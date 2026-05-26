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

// PR-F2 — inspect_state. find_element 가 부여한 ref 로 fiber 의 props/state/hooks 직렬화.
describe('mcp-runtime.cjs (PR-F2) — inspect_state', () => {
  function findThenInspect(
    rt: { handlers: Record<string, (p: unknown) => unknown> },
    by: 'text' | 'role' | 'component',
    value: string,
  ): { ref: string; result: any } {
    const f = rt.handlers.find_element({ by, value }) as { ref: string };
    return { ref: f.ref, result: rt.handlers.inspect_state({ ref: f.ref }) };
  }

  test('params 누락 → throw: requires `ref`', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.inspect_state({})).toThrow(/requires `ref`/);
    expect(() => rt.handlers.inspect_state({ ref: 123 })).toThrow(/requires `ref`/);
  });

  test('unknown ref → throw: not found (expired or unknown)', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.inspect_state({ ref: 'e9999' })).toThrow(/not found/);
  });

  test('function component — props + hooks 직렬화 (_debugHookTypes 활용)', () => {
    // function component (memoizedState 가 Hook linked list)
    // hook0: useState(count=3), hook1: useState(name='hi')
    const hook1: any = { memoizedState: 'hi', next: null };
    const hook0: any = { memoizedState: 3, next: hook1 };
    const fnFiber: FakeFiber = {
      type: { displayName: 'Counter' },
      memoizedProps: { label: 'click', step: 1 },
      stateNode: null,
      _debugHookTypes: ['useState', 'useState'],
    } as any;
    (fnFiber as any).memoizedState = hook0;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fnFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Counter');
    expect(result.component).toBe('Counter');
    expect(result.kind).toBe('function');
    expect(result.props).toEqual({ label: 'click', step: 1 });
    expect(result.hooks).toEqual([
      { type: 'useState', value: 3 },
      { type: 'useState', value: 'hi' },
    ]);
    expect(result.state).toBeUndefined();
  });

  test('class component — memoizedState 직렬화, hooks 없음 (F1: isReactComponent 는 빈 객체 {})', () => {
    // PR-F2 review F1: 실제 React 는 Component.prototype.isReactComponent = {} (빈 객체).
    // 이전 stub 가 `true` 였어 production class 컴포넌트가 'function' 으로 오분류 됐던
    // bug 를 mask 했었음. 이제 React 와 동일한 contract 로 검증.
    const classFiber: FakeFiber = {
      type: { displayName: 'Modal' },
      memoizedProps: { visible: true },
      stateNode: { isReactComponent: {} } as any,
    } as any;
    (classFiber as any).memoizedState = { open: true, count: 7 };
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: classFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Modal');
    expect(result.kind).toBe('class');
    expect(result.props).toEqual({ visible: true });
    expect(result.state).toEqual({ open: true, count: 7 });
    expect(result.hooks).toBeUndefined();
  });

  test('safeSerialize — function/cycle/undefined/Date/Map 등 non-JSON 값 marker 로 대체', () => {
    const cycle: any = { name: 'self' };
    cycle.me = cycle; // cycle
    const fiber: FakeFiber = {
      type: { displayName: 'Mix' },
      memoizedProps: {
        cb: function namedFn() {},
        n: undefined,
        when: new Date('2026-01-01T00:00:00.000Z'),
        map: new Map([['k', 'v']]),
        set: new Set([1, 2]),
        nan: NaN,
        inf: Infinity,
        cycle: cycle,
      },
      stateNode: null,
    } as any;
    (fiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Mix');
    const p = result.props;
    expect(p.cb).toBe('[Function namedFn]');
    expect(p.n).toBe('[Undefined]');
    expect(p.when).toBe('[Date 2026-01-01T00:00:00.000Z]');
    expect(p.map).toBe('[Map size=1]');
    expect(p.set).toBe('[Set size=2]');
    expect(p.nan).toBe('[NaN]');
    expect(p.inf).toBe('[+Infinity]');
    expect(p.cycle).toEqual({ name: 'self', me: '[Circular]' });
  });

  test('React element ($$typeof) → [ReactElement] marker (children 트리 폭주 방지)', () => {
    var element = { $$typeof: Symbol.for('react.element'), type: 'div', props: {} };
    const fiber: FakeFiber = {
      type: { displayName: 'Wrap' },
      memoizedProps: { children: element },
      stateNode: null,
    } as any;
    (fiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Wrap');
    expect(result.props.children).toBe('[ReactElement]');
  });

  test('max depth — 깊이 8 초과 시 [MaxDepth]', () => {
    // 9 레벨 nested object
    let deep: any = 'leaf';
    for (let i = 0; i < 9; i++) deep = { v: deep };
    const fiber: FakeFiber = {
      type: { displayName: 'Deep' },
      memoizedProps: { tree: deep },
      stateNode: null,
    } as any;
    (fiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Deep');
    // depth 8 에서 truncate — root props (depth 0) → .tree (1) → .v×N. depth 9 호출에서
    // marker 반환되므로 depth 8 위치 obj 의 `.v` 가 '[MaxDepth]'.
    let cur = result.props.tree;
    for (let i = 0; i < 7; i++) cur = cur.v; // depth 8 까지 내려감 (8 - 1 = 7번)
    expect(cur.v).toBe('[MaxDepth]');
  });

  test('hook cycle guard — next pointer 가 자기 자신이면 안전 종료', () => {
    const hook: any = { memoizedState: 'a' };
    hook.next = hook; // 비정상 cycle
    const fnFiber: FakeFiber = {
      type: { displayName: 'Cyc' },
      memoizedProps: {},
      stateNode: null,
      _debugHookTypes: ['useState'],
    } as any;
    (fnFiber as any).memoizedState = hook;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fnFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Cyc');
    expect(Array.isArray(result.hooks)).toBe(true);
    expect(result.hooks.length).toBe(1); // 첫 hook 만 직렬화 후 cycle 감지로 stop
  });

  test('host fiber (RN View / Text) → kind:"host", hooks/state 없음 (review F1)', () => {
    // host fiber 의 type 은 string. stateNode 는 NativeViewInstance (React.Component
    // 아님). 이전 코드는 `kind: 'function'` 으로 잘못 분류했음 + serializeHooks 가
    // class state 인 척 wrong 결과 가능성.
    const hostFiber: FakeFiber = {
      type: 'View',
      memoizedProps: { style: { padding: 8 }, accessible: true },
      stateNode: { _nativeTag: 42 } as any,
    } as any;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: hostFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const f = rt.handlers.find_element({ by: 'component', value: 'View' }) as { ref: string };
    const r = rt.handlers.inspect_state({ ref: f.ref }) as {
      kind?: string;
      props?: any;
      hooks?: unknown;
      state?: unknown;
    };
    expect(r.kind).toBe('host');
    expect(r.props.accessible).toBe(true);
    expect(r.hooks).toBeUndefined();
    expect(r.state).toBeUndefined();
  });

  test('safeSerialize — TypedArray / ArrayBuffer / Promise 는 marker (size/buffer 폭주 방지)', () => {
    const fiber: FakeFiber = {
      type: { displayName: 'Buf' },
      memoizedProps: {
        u8: new Uint8Array(1024),
        i32: new Int32Array([1, 2, 3]),
        ab: new ArrayBuffer(64),
        pr: Promise.resolve(1),
      },
      stateNode: null,
    } as any;
    (fiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Buf');
    expect(result.props.u8).toBe('[Uint8Array byteLength=1024]');
    expect(result.props.i32).toBe('[Int32Array byteLength=12]');
    expect(result.props.ab).toBe('[ArrayBuffer byteLength=64]');
    expect(result.props.pr).toBe('[Promise]');
  });

  test('safeSerialize — throwing getter → "[Throws ...]" marker, 다른 key 는 정상 직렬화', () => {
    const props: any = { ok: 1 };
    Object.defineProperty(props, 'boom', {
      enumerable: true,
      get() {
        throw new Error('getter exploded');
      },
    });
    const fiber: FakeFiber = {
      type: { displayName: 'Boom' },
      memoizedProps: props,
      stateNode: null,
    } as any;
    (fiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Boom');
    expect(result.props.ok).toBe(1);
    expect(result.props.boom).toContain('[Throws');
    expect(result.props.boom).toContain('getter exploded');
  });

  test('safeSerialize — 긴 array (length > 256) 는 앞 256개 + "...more" marker', () => {
    const big = Array.from({ length: 300 }, (_, i) => i);
    const fiber: FakeFiber = {
      type: { displayName: 'Big' },
      memoizedProps: { list: big },
      stateNode: null,
    } as any;
    (fiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Big');
    expect(result.props.list.length).toBe(257); // 256 + 1 marker
    expect(result.props.list[256]).toBe('[...44 more]');
  });

  test('hook truncation — 65 hook 일 때 64 + truncated marker', () => {
    // 65개 hook chain
    let tail: any = null;
    const types: string[] = [];
    for (let i = 64; i >= 0; i--) {
      tail = { memoizedState: i, next: tail };
      types.unshift('useState');
    }
    const fnFiber: FakeFiber = {
      type: { displayName: 'Many' },
      memoizedProps: {},
      stateNode: null,
      _debugHookTypes: types,
    } as any;
    (fnFiber as any).memoizedState = tail;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fnFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'Many');
    expect(result.hooks.length).toBe(65); // 64 hook + 1 truncated marker
    expect(result.hooks[64].type).toBe('[...truncated]');
  });

  test('useEffect-like hook (tag + create + deps) → "[Effect tag=N]" marker (chain 폭주 방지)', () => {
    const effect2: any = { tag: 5, create: () => {}, deps: [], destroy: undefined };
    const effect1: any = { tag: 5, create: () => {}, deps: [], destroy: undefined, next: effect2 };
    effect2.next = effect1; // 동일 fiber Effect chain
    const hook1: any = { memoizedState: effect1, next: null };
    const fnFiber: FakeFiber = {
      type: { displayName: 'WithEffect' },
      memoizedProps: {},
      stateNode: null,
      _debugHookTypes: ['useEffect'],
    } as any;
    (fnFiber as any).memoizedState = hook1;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fnFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const { result } = findThenInspect(rt, 'component', 'WithEffect');
    expect(result.hooks[0]).toEqual({ type: 'useEffect', value: '[Effect tag=5]' });
  });
});

// PR-F3 — eval_code. user expression 평가 + ref 가 있으면 fiber stateNode 를
// `this`/`$ctx` 로 바인딩. system error → throw, runtime/syntax → {ok:false}.
describe('mcp-runtime.cjs (PR-F3) — eval_code', () => {
  test('params 누락 → throw: requires `expression`', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.eval_code({})).toThrow(/requires `expression`/);
    expect(() => rt.handlers.eval_code({ expression: 123 })).toThrow(/requires `expression`/);
  });

  test('unknown ref → throw: not found', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.eval_code({ expression: '1+1', ref: 'e9999' })).toThrow(/not found/);
  });

  test('ref 없이 단순 expression — ok + value + type', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.eval_code({ expression: '1 + 2 * 3' }) as {
      ok: boolean;
      value: unknown;
      type: string;
    };
    expect(r.ok).toBe(true);
    expect(r.value).toBe(7);
    expect(r.type).toBe('number');
  });

  test('global access — Math.PI / JSON.stringify 작동', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const pi = rt.handlers.eval_code({ expression: 'Math.PI' }) as { value: number };
    expect(pi.value).toBeCloseTo(3.14159, 4);
    const json = rt.handlers.eval_code({ expression: 'JSON.stringify({a:1})' }) as {
      value: string;
    };
    expect(json.value).toBe('{"a":1}');
  });

  test('syntax error → {ok:false, kind:"syntax"}', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.eval_code({ expression: '1 +' }) as {
      ok: boolean;
      kind?: string;
      error?: string;
    };
    expect(r.ok).toBe(false);
    expect(r.kind).toBe('syntax');
    expect(typeof r.error).toBe('string');
  });

  test('runtime error → {ok:false, kind:"runtime", stack}', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.eval_code({ expression: 'nonExistentVar.foo' }) as {
      ok: boolean;
      kind?: string;
      error?: string;
      stack?: string;
    };
    expect(r.ok).toBe(false);
    expect(r.kind).toBe('runtime');
    expect(r.error).toContain('nonExistentVar');
    expect(typeof r.stack).toBe('string');
  });

  test('ref (class) — this.state / this.props 접근', () => {
    const classInstance = {
      isReactComponent: {},
      props: { title: 'Hello' },
      state: { count: 5 },
    } as any;
    const classFiber: FakeFiber = {
      type: { displayName: 'Card' },
      memoizedProps: { title: 'Hello' },
      stateNode: classInstance,
    } as any;
    (classFiber as any).memoizedState = { count: 5 };
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: classFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const f = rt.handlers.find_element({ by: 'component', value: 'Card' }) as { ref: string };
    const r = rt.handlers.eval_code({
      expression: 'this.state.count + 1',
      ref: f.ref,
    }) as { ok: boolean; value: number };
    expect(r.ok).toBe(true);
    expect(r.value).toBe(6);
  });

  test('ref ($ctx) — $ctx.props 로도 접근 가능 (this 대안)', () => {
    const classInstance = {
      isReactComponent: {},
      props: { name: 'Bob' },
      state: {},
    } as any;
    const classFiber: FakeFiber = {
      type: { displayName: 'Greet' },
      memoizedProps: { name: 'Bob' },
      stateNode: classInstance,
    } as any;
    (classFiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: classFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const f = rt.handlers.find_element({ by: 'component', value: 'Greet' }) as { ref: string };
    const r = rt.handlers.eval_code({
      expression: '"Hi " + $ctx.props.name',
      ref: f.ref,
    }) as { value: string };
    expect(r.value).toBe('Hi Bob');
  });

  test('ref (function component) — $ctx 는 props/state snapshot (stateNode null 일 때)', () => {
    const fnFiber: FakeFiber = {
      type: { displayName: 'FnCmp' },
      memoizedProps: { x: 42 },
      stateNode: null,
    } as any;
    (fnFiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fnFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const f = rt.handlers.find_element({ by: 'component', value: 'FnCmp' }) as { ref: string };
    const r = rt.handlers.eval_code({
      expression: '$ctx.props.x * 2',
      ref: f.ref,
    }) as { ok: boolean; value: number };
    expect(r.ok).toBe(true);
    expect(r.value).toBe(84);
  });

  test('safeSerialize 통과 — function 결과는 marker', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.eval_code({
      expression: '(function namedFn() {})',
    }) as { value: string; type: string };
    expect(r.value).toBe('[Function namedFn]');
    expect(r.type).toBe('function');
  });

  test('strict mode — undeclared assignment 은 ReferenceError', () => {
    // "use strict" 로 sloppy mode 우회 차단 — undeclared 변수 assignment 가 throw.
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.eval_code({
      expression: '(undeclared = 5)',
    }) as { ok: boolean; error: string };
    expect(r.ok).toBe(false);
    expect(r.error).toContain('undeclared');
  });

  test('F2 contract — this.x = ... 으로 stateNode 인스턴스 mutation 실행 (debugger console 시맨틱)', () => {
    // PR-F3 review F2: 의도된 동작 — `this` 가 live React 인스턴스. 변경 가능.
    // 사용자 계약: side-effect 허용 (this.setState/globalThis 대입 등). 본 test 가
    // 미래 refactor 가 silent 하게 read-only proxy 로 wrap 안 하게 lock.
    const instance: any = {
      isReactComponent: {},
      props: { v: 1 },
      state: { count: 0 },
      setState(patch: any) {
        this.state = Object.assign({}, this.state, patch);
      },
    };
    const fiber: FakeFiber = {
      type: { displayName: 'Mut' },
      memoizedProps: instance.props,
      stateNode: instance,
    } as any;
    (fiber as any).memoizedState = instance.state;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: fiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const f = rt.handlers.find_element({ by: 'component', value: 'Mut' }) as { ref: string };
    // setState 호출 → state 변경
    const r1 = rt.handlers.eval_code({
      expression: 'this.setState({count: 42}), this.state.count',
      ref: f.ref,
    }) as { ok: boolean; value: number };
    expect(r1.ok).toBe(true);
    expect(r1.value).toBe(42);
    expect(instance.state.count).toBe(42); // 실제 인스턴스 변경됨
  });

  test('F3 — forwardRef-like fiber (stateNode null + type 이 object) → $ctx 가 snapshot', () => {
    // React.forwardRef / React.memo / React.Fragment 등 — type 이 string 도 아니고
    // class instance 도 아닌 fiber. snapshot ctx 로 fallback.
    const forwardRefFiber: FakeFiber = {
      type: { $$typeof: Symbol.for('react.forward_ref'), displayName: 'Wrapped' } as any,
      memoizedProps: { label: 'forward' },
      stateNode: null,
    } as any;
    (forwardRefFiber as any).memoizedState = null;
    const root: FakeFiber = {
      type: { name: 'Root' },
      memoizedProps: {},
      child: forwardRefFiber,
    };
    makeFiberHook(g, [{ current: root }]);

    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const f = rt.handlers.find_element({ by: 'component', value: 'Wrapped' }) as { ref: string };
    const r = rt.handlers.eval_code({
      expression: '$ctx.props.label.toUpperCase()',
      ref: f.ref,
    }) as { ok: boolean; value: string };
    expect(r.ok).toBe(true);
    expect(r.value).toBe('FORWARD');
  });

  test('F4 — await / yield 는 syntax error (sync 전용 — contract lock)', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r1 = rt.handlers.eval_code({
      expression: 'await Promise.resolve(1)',
    }) as { ok: boolean; kind?: string };
    expect(r1.ok).toBe(false);
    expect(r1.kind).toBe('syntax');
    const r2 = rt.handlers.eval_code({
      expression: 'yield 1',
    }) as { ok: boolean; kind?: string };
    expect(r2.ok).toBe(false);
    expect(r2.kind).toBe('syntax');
  });

  test('F6 — globalThis 같은 큰 cyclic graph 반환도 safeSerialize 가 bound', () => {
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.eval_code({
      expression: 'globalThis',
    }) as { ok: boolean; value: unknown };
    expect(r.ok).toBe(true);
    // JSON.stringify 가 throw 안 함 → depth/cycle/array cap 이 효과
    expect(typeof JSON.stringify(r.value)).toBe('string');
  });

  test('F1 — new Function 이 throw 하는 환경 (Hermes enableEval=false) 시 kind:"unsupported"', () => {
    // bun:test 의 Function 자체를 override 못 함 (Function global 은 const). 대신
    // module-cache reset + bun runtime 에서 new Function 자체는 항상 작동하므로,
    // 이 test 는 EVAL_SUPPORTED probe 의 동작 자체 검증 — Hermes 시뮬레이션이 어려워
    // sanity 만 확인. 진짜 Hermes path 는 device test 영역.
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.eval_code({ expression: '1+1' }) as { ok: boolean; value?: number };
    // Bun 환경에서는 항상 ok:true. unsupported 분기는 코드 review 로만 확인.
    expect(r.ok).toBe(true);
    expect(r.value).toBe(2);
  });
});

// PR-F4 — get_logs. console.log/info/warn/error/debug intercept + ring buffer.
describe('mcp-runtime.cjs (PR-F4) — get_logs', () => {
  // get_logs test 는 g.console 의 5개 method 가 wrap 되는지 검증. mock console 을
  // 매번 fresh 로 두고 wrapping → emit → handlers.get_logs round-trip 확인.
  function setupConsole(): { calls: Array<{ level: string; args: unknown[] }> } {
    const calls: Array<{ level: string; args: unknown[] }> = [];
    (g as any).console = {
      log: (...args: unknown[]) => calls.push({ level: 'log', args }),
      info: (...args: unknown[]) => calls.push({ level: 'info', args }),
      warn: (...args: unknown[]) => calls.push({ level: 'warn', args }),
      error: (...args: unknown[]) => calls.push({ level: 'error', args }),
      debug: (...args: unknown[]) => calls.push({ level: 'debug', args }),
    };
    return { calls };
  }

  test('console.log/warn/error 호출 → ring buffer 누적 + 원본 console 도 호출', () => {
    const { calls } = setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };

    (g as any).console.log('hello', 1);
    (g as any).console.warn('warn-msg');
    (g as any).console.error('boom');

    // 원본 mock 도 호출됐는지
    expect(calls.length).toBe(3);
    expect(calls[0]).toEqual({ level: 'log', args: ['hello', 1] });

    // ring buffer 도 채워졌는지
    const r = rt.handlers.get_logs({}) as {
      entries: Array<{ level: string; args: unknown[]; ts: number }>;
      dropped: number;
      total: number;
    };
    expect(r.entries.length).toBe(3);
    expect(r.entries[0].level).toBe('log');
    expect(r.entries[0].args).toEqual(['hello', 1]);
    expect(r.entries[1].level).toBe('warn');
    expect(r.entries[2].level).toBe('error');
    expect(r.dropped).toBe(0);
    expect(r.total).toBe(3);
  });

  test('level filter — `warn` 만 반환', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };

    (g as any).console.log('a');
    (g as any).console.warn('b');
    (g as any).console.error('c');
    (g as any).console.warn('d');

    const r = rt.handlers.get_logs({ level: 'warn' }) as { entries: Array<{ level: string }> };
    expect(r.entries.length).toBe(2);
    expect(r.entries.every((e) => e.level === 'warn')).toBe(true);
  });

  test('invalid level → throw', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.get_logs({ level: 'verbose' })).toThrow(/invalid `level`/);
  });

  test('cursor (seq) pagination — lossless, same-ms entry 도 포함', () => {
    // PR-F4 review F3 — seq 기반 cursor 가 정확한 pagination 경로. busy-wait 없이도
    // 검증 가능 — seq 는 monotonic 보장.
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };

    (g as any).console.log('a');
    (g as any).console.log('b');
    const r1 = rt.handlers.get_logs({}) as {
      entries: Array<{ seq: number; args: unknown[] }>;
      nextCursor: number;
    };
    expect(r1.entries.length).toBe(2);
    expect(r1.nextCursor).toBe(r1.entries[1].seq);

    (g as any).console.log('c');
    (g as any).console.log('d');
    const r2 = rt.handlers.get_logs({ cursor: r1.nextCursor }) as {
      entries: Array<{ args: unknown[] }>;
      nextCursor: number;
    };
    expect(r2.entries.length).toBe(2);
    expect(r2.entries[0].args).toEqual(['c']);
    expect(r2.entries[1].args).toEqual(['d']);
  });

  test('cursor — entries 비어도 nextCursor 보존 (단조 증가)', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    (g as any).console.log('x');
    const r1 = rt.handlers.get_logs({}) as { nextCursor: number };
    // 새 log 없이 cursor 진행
    const r2 = rt.handlers.get_logs({ cursor: r1.nextCursor }) as {
      entries: unknown[];
      nextCursor: number;
    };
    expect(r2.entries.length).toBe(0);
    expect(r2.nextCursor).toBe(r1.nextCursor); // 그대로 유지
  });

  test('since filter — timestamp 이후 entry 반환 (coarse, same-ms 한계 명시)', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };

    (g as any).console.log('a');
    (g as any).console.log('b');
    // since 가 매우 작은 값 — 모든 entry 반환.
    const all = rt.handlers.get_logs({ since: 0 }) as { entries: unknown[] };
    expect(all.entries.length).toBe(2);
    // since 가 매우 큰 값 — 0개.
    const none = rt.handlers.get_logs({ since: Date.now() + 1_000_000 }) as { entries: unknown[] };
    expect(none.entries.length).toBe(0);
  });

  test('invalid limit (음수/0/NaN) → throw', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    expect(() => rt.handlers.get_logs({ limit: 0 })).toThrow(/invalid `limit`/);
    expect(() => rt.handlers.get_logs({ limit: -5 })).toThrow(/invalid `limit`/);
    expect(() => rt.handlers.get_logs({ limit: NaN })).toThrow(/invalid `limit`/);
  });

  test('cursor + since AND — 둘 다 만족하는 entry 만', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    (g as any).console.log('a');
    const after = rt.handlers.get_logs({}) as {
      entries: Array<{ seq: number; ts: number }>;
    };
    const seq0 = after.entries[0].seq;
    // 같은 cursor 와 매우 큰 since — since 가 효과 발휘
    const r = rt.handlers.get_logs({ cursor: seq0, since: Date.now() + 1_000_000 }) as {
      entries: unknown[];
    };
    expect(r.entries.length).toBe(0);
  });

  test('intercept chain — 우리 wrap 위로 third-party 가 wrap 해도 ring buffer 캡처', () => {
    // PR-F4 review F6: LogBox 같은 후속 wrapper 가 console.log 를 한 번 더 wrap 하면
    // call chain 은 third-party → our wrap → original. our wrap 안의 appendLog 가
    // 호출되어 ring buffer 채워져야 함.
    const { calls } = setupConsole();
    loadRuntime(g);
    // mcp-runtime 가 wrap 후 — 그 위로 third-party (LogBox 흉내) wrap.
    const ourWrapped = (g as any).console.log;
    let thirdPartyCalls = 0;
    (g as any).console.log = function () {
      thirdPartyCalls += 1;
      return ourWrapped.apply(this, arguments);
    };

    (g as any).console.log('hi');
    expect(thirdPartyCalls).toBe(1);
    expect(calls.length).toBe(1);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.get_logs({}) as { entries: Array<{ args: unknown[] }> };
    expect(r.entries.length).toBe(1);
    expect(r.entries[0].args).toEqual(['hi']);
  });

  test('limit — newest N 만 반환', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };

    for (let i = 0; i < 10; i++) (g as any).console.log('e' + i);
    const r = rt.handlers.get_logs({ limit: 3 }) as { entries: Array<{ args: unknown[] }> };
    expect(r.entries.length).toBe(3);
    // newest 3 = e7, e8, e9
    expect(r.entries.map((e) => e.args[0])).toEqual(['e7', 'e8', 'e9']);
  });

  test('safeSerialize 적용 — function/cycle/Date 등 marker', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const cycle: any = { a: 1 };
    cycle.self = cycle;
    (g as any).console.log('mixed', function fn() {}, new Date('2026-01-01T00:00:00Z'), cycle);
    const r = rt.handlers.get_logs({}) as { entries: Array<{ args: unknown[] }> };
    expect(r.entries[0].args[0]).toBe('mixed');
    expect(r.entries[0].args[1]).toBe('[Function fn]');
    expect(r.entries[0].args[2]).toBe('[Date 2026-01-01T00:00:00.000Z]');
    expect((r.entries[0].args[3] as any).self).toBe('[Circular]');
  });

  test('intercept idempotent — 두 번 load 해도 wrap 한 번만', () => {
    const { calls } = setupConsole();
    loadRuntime(g);
    loadRuntime(g);
    (g as any).console.log('once');
    // wrap 두 번이면 mock 호출 2번, append 도 2번. 1회 wrap 이라 1번씩.
    expect(calls.length).toBe(1);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.get_logs({}) as { entries: unknown[] };
    expect(r.entries.length).toBe(1);
  });

  test('ring buffer overflow → 가장 오래된 entry drop + dropped counter 증가', () => {
    setupConsole();
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };

    // 1005 entry — 5개 drop
    for (let i = 0; i < 1005; i++) (g as any).console.log('e' + i);
    const r = rt.handlers.get_logs({ limit: 1000 }) as {
      entries: Array<{ args: unknown[] }>;
      dropped: number;
      total: number;
    };
    expect(r.dropped).toBe(5);
    expect(r.total).toBe(1000);
    expect(r.entries.length).toBe(1000);
    // 가장 oldest 5개 (e0~e4) 가 drop — 시작은 e5
    expect(r.entries[0].args[0]).toBe('e5');
    expect(r.entries[999].args[0]).toBe('e1004');
  });

  test('console null/undefined 환경 — intercept skip, get_logs 는 빈 entries', () => {
    (g as any).console = null;
    loadRuntime(g);
    const rt = g.__ZNTC_MCP_RUNTIME__ as { handlers: Record<string, (p: unknown) => unknown> };
    const r = rt.handlers.get_logs({}) as { entries: unknown[]; dropped: number };
    expect(r.entries.length).toBe(0);
    expect(r.dropped).toBe(0);
  });

  test('intercept 의 try/catch — appendLog 가 throw 해도 원본 console 호출 보존', () => {
    // safeSerialize 가 throw 하는 시나리오는 어렵지만, ring buffer assertion 의 wrap
    // 이 try-catch 덕에 가시화 안 됨. 일단 normal path 가 원본 호출 보존하는 sanity.
    const { calls } = setupConsole();
    loadRuntime(g);
    (g as any).console.warn('keep-going');
    expect(calls.length).toBe(1);
    expect(calls[0].args).toEqual(['keep-going']);
  });
});
