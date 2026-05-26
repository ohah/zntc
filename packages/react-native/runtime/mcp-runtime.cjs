'use strict';

// MCP (Model Context Protocol) RN runtime — dev 빌드 한정 preamble.
//
// zntc transform pass 가 entry preamble (`runBeforeMain`) 로 inject. 앱 시작 시
// 즉시 실행되어 dev_server 의 `/__mcp-app` WebSocket 에 connect, JSON-RPC 2.0
// 메시지 dispatcher 등록. 후속 PR (PR-E3+) 가 `__ZNTC_MCP_RUNTIME__.handlers` 에
// 본격 tool 핸들러 (takeSnapshot / findElement / inspectState 등) 채움.
//
// production 빌드에는 inject 안 됨 (`dev: false`).
//
// **Runtime 적용 범위 — JS thread only**:
//   본 runtime 은 RN 의 main JS thread (RN 앱 main bundle) 에서만 동작.
//   Reanimated worklet runtime / UI thread / Hermes worker 등 별도 realm 에는
//   `__ZNTC_MCP_RUNTIME__` 등록 안 됨. 후속 PR 가 worklet runtime 의 fiber tree
//   직렬화를 지원하려면 별도 inject 전략 (worklet preamble) 필요.
//
// Wire contract (Zig 측 `src/server/mcp_app_channel.zig` 참조):
//   - URL path: `/__mcp-app`
//   - server hello: `{"jsonrpc":"2.0","method":"connected","params":{"protocol":"mcp-app-1"}}`
//   - server reject: `{"jsonrpc":"2.0","error":{"code":-32000,...}}` + close frame
//
// URL discovery:
//   1. `globalThis.__ZNTC_MCP_APP_WS_URL__` — 사용자 또는 빌드 시 inject (override)
//   2. fallback: `ws://localhost:12300/__mcp-app` — RN 시뮬레이터 default
//
// Reconnect: 지수 backoff (1s → 2s → 4s → ... → max 30s) — server restart / network
// hiccup 시 복구. dev 환경의 noise 줄이기 위해 console 출력 최소.

function startMcpRuntime(g) {
  if (!g) return;
  if (g.__ZNTC_MCP_RUNTIME__ && g.__ZNTC_MCP_RUNTIME__.loaded) return; // 이미 loaded — HMR idempotent

  var DEFAULT_URL = 'ws://localhost:12300/__mcp-app';
  var EXPECTED_PROTOCOL = 'mcp-app-1';
  var RECONNECT_MIN_MS = 1000;
  var RECONNECT_MAX_MS = 30000;

  // RN 환경에서 WebSocket 은 RN core (Libraries/WebSocket) 가 polyfill 제공.
  // RN runtime 초기화 후에만 사용 가능 (InitializeCore 이후 — runBeforeMain 순서로 보장).
  if (typeof g.WebSocket !== 'function') {
    // RN 외 환경 (Node CLI 테스트 등) — 등록만 하고 connect skip.
    g.__ZNTC_MCP_RUNTIME__ = {
      version: '0.1.0',
      loaded: true,
      connectionState: 'unsupported',
      ws: null,
      handlers: Object.create(null),
    };
    return;
  }

  var url = g.__ZNTC_MCP_APP_WS_URL__ || DEFAULT_URL;
  var handlers = Object.create(null);
  // closedExplicitly: 사용자 `runtime.close()` 호출 (사용자 의도, reconnect 금지)
  // protocolMismatch: server 가 광고한 protocol version 이 client EXPECTED 와 불일치
  // — reconnect 무의미 (RN reload 필요). 별도 sentinel 로 두 가지 케이스 구분.
  var state = {
    ws: null,
    connectionState: 'closed',
    reconnectMs: RECONNECT_MIN_MS,
    closedExplicitly: false,
    protocolMismatch: false,
  };

  // public API surface — 후속 PR 이 `runtime.handlers[name] = fn` 으로 tool 추가.
  //
  // **의도된 mutable assignment** (Object.defineProperty 의 freeze 안 함):
  //   HMR 재평가 시 새 startMcpRuntime 호출 가능해야 reconfigure 가능. idempotent 분기
  //   (`loaded === true` early return) 가 두 번째 호출은 막지만, user 가 `loaded = false`
  //   로 reset 후 재 init 하는 escape hatch 필요. 또한 `connectionState` getter 같은
  //   accessor 패턴 유지를 위해 일반 assignment 가 더 단순.
  g.__ZNTC_MCP_RUNTIME__ = {
    version: '0.1.0',
    loaded: true,
    get connectionState() {
      return state.connectionState;
    },
    get ws() {
      return state.ws;
    },
    handlers: handlers,
    /** 명시적 종료 — 테스트나 reconfigure 시 호출. reconnect loop 도 멈춤. */
    close: function () {
      state.closedExplicitly = true;
      if (state.ws) {
        try {
          state.ws.close();
        } catch (_) {}
      }
    },
  };

  // `msg` 는 이미 parse 된 object. onmessage 가 parse 1회 후 hello 분기 + 일반 dispatch
  // 양쪽에 같은 결과 forward.
  function dispatch(msg) {
    // server 가 보낸 request (id + method) — handler 호출 → response.
    if (typeof msg.method === 'string' && msg.id != null) {
      var fn = handlers[msg.method];
      if (typeof fn !== 'function') {
        send({
          jsonrpc: '2.0',
          id: msg.id,
          error: { code: -32601, message: 'Method not found: ' + msg.method },
        });
        return;
      }
      try {
        var result = fn(msg.params || {});
        // sync 결과만 우선 — async (Promise) 처리는 후속 PR
        send({ jsonrpc: '2.0', id: msg.id, result: result == null ? {} : result });
      } catch (err) {
        send({
          jsonrpc: '2.0',
          id: msg.id,
          error: { code: -32603, message: String((err && err.message) || err) },
        });
      }
      return;
    }

    // notification (id 없음) — 핸들러만 호출, 응답 안 보냄.
    if (typeof msg.method === 'string') {
      var nfn = handlers[msg.method];
      if (typeof nfn === 'function') {
        try {
          nfn(msg.params || {});
        } catch (_) {}
      }
      return;
    }

    // server-initiated response (result/error + id) — 후속 PR 에서 pending Map 매칭.
  }

  function send(obj) {
    if (!state.ws || state.connectionState !== 'open') {
      // handler 실행 중 / 직후에 onclose 발화 race — pending response 손실.
      // dev console.warn 으로 디버깅 hint (서버는 timeout 까지 hang). 후속 PR 에서
      // pending response queue 또는 retry 로 강화 가능.
      // `g.console === null` 도 `typeof === 'object'` 이라 truthy check 필수 (F4).
      if (g.console && typeof g.console.warn === 'function') {
        var idHint = obj && obj.id != null ? ' id=' + String(obj.id) : '';
        g.console.warn(
          '[zntc:mcp:runtime] send drop — WS 닫힘 (state=' + state.connectionState + ')' + idHint,
        );
      }
      return false;
    }
    try {
      state.ws.send(JSON.stringify(obj));
      return true;
    } catch (_) {
      return false;
    }
  }

  function scheduleReconnect() {
    if (state.closedExplicitly || state.protocolMismatch) return;
    var delay = state.reconnectMs;
    state.reconnectMs = Math.min(state.reconnectMs * 2, RECONNECT_MAX_MS);
    // `g.setTimeout` 명시 — runtime 안에서 bare `setTimeout` 은 closure 의
    // host realm setTimeout 을 참조해 test mock 이 안 통한다. RN 환경에선
    // `g === globalThis` 라 동일 동작.
    if (typeof g.setTimeout === 'function') {
      g.setTimeout(connect, delay);
    }
  }

  function connect() {
    if (state.closedExplicitly) return;
    state.connectionState = 'connecting';
    var ws;
    try {
      ws = new g.WebSocket(url);
    } catch (_) {
      scheduleReconnect();
      return;
    }
    state.ws = ws;

    ws.onopen = function () {
      state.connectionState = 'open';
      state.reconnectMs = RECONNECT_MIN_MS; // 성공 connect → backoff reset
    };

    ws.onmessage = function (ev) {
      var data = ev && ev.data;
      if (typeof data !== 'string') return;
      // 단 1회 parse — substring 검사 (false-positive 위험) 대신 typed check.
      var msg;
      try {
        msg = JSON.parse(data);
      } catch (_) {
        return;
      }
      if (!msg || typeof msg !== 'object') return;

      // hello 메시지 — top-level `method === "connected"` 만 검출. nested object 의
      // `method` field 가 우연히 "connected" 여도 영향 없음.
      if (msg.method === 'connected' && msg.id == null) {
        var serverProtocol =
          msg.params && typeof msg.params.protocol === 'string' ? msg.params.protocol : null;
        if (serverProtocol !== EXPECTED_PROTOCOL) {
          state.protocolMismatch = true;
          try {
            ws.close();
          } catch (_) {}
        }
        return;
      }
      dispatch(msg);
    };

    ws.onerror = function () {
      // 별도 처리 없음 — onclose 가 이어 호출됨.
    };

    ws.onclose = function () {
      state.connectionState = 'closed';
      state.ws = null;
      scheduleReconnect();
    };
  }

  // 첫 connect — RN 의 InitializeCore 가 fetch/XHR 등을 준비한 후 호출됨 (runBeforeMain
  // 순서 보장). 즉시 동기 호출하면 WebSocket polyfill 이 아직 mount 안 된 케이스가
  // 있어 microtask 로 살짝 늦춤.
  if (typeof g.setTimeout === 'function') {
    g.setTimeout(connect, 0);
  } else {
    connect();
  }
}

// Auto-execute — RN preamble (runBeforeMain) 으로 inject 시 자동 실행.
//
// **RN-only guard**: `navigator.product === 'ReactNative'` 가 RN 환경 표준 detection.
// Node test runner / Bun / 일반 브라우저는 skip — 그 환경엔 polyfill WebSocket 이
// 있어도 ws://localhost:12300 으로 실제 connect 시도가 process hang 유발 가능.
//
// **Opt-out**: 사용자 / jest setup 이 `globalThis.__ZNTC_DISABLE_MCP_RUNTIME__ = true`
// 로 명시 설정 시 RN 환경이라도 skip. jest-environment-node + react-native preset 가
// `navigator.product = 'ReactNative'` 를 set 해서 RN detection 이 false-positive
// 인 unit test 시나리오 대응.
function __zntcIsReactNative(g) {
  return (
    g != null &&
    typeof g.navigator === 'object' &&
    g.navigator != null &&
    g.navigator.product === 'ReactNative'
  );
}

function __zntcShouldAutoStart(g) {
  // opt-out 은 truthy 값 모두 허용 — jest 의 흔한 패턴 (`'1'` / `'true'` / boolean) 다 통과.
  // 명시적 `=== true` 만 받으면 `globalThis.__ZNTC_DISABLE_MCP_RUNTIME__ = '1'` 로 끄려는
  // 사용자가 silent fail 한다 (F5).
  if (!g || g.__ZNTC_DISABLE_MCP_RUNTIME__) return false;
  return __zntcIsReactNative(g);
}

var __zntcAutoG =
  typeof globalThis !== 'undefined' ? globalThis : typeof global !== 'undefined' ? global : null;
if (__zntcShouldAutoStart(__zntcAutoG)) startMcpRuntime(__zntcAutoG);

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { startMcpRuntime: startMcpRuntime };
}
