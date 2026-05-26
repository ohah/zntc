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

  // Default `ping` handler — `ping_app` MCP tool 이 호출하면 server → request →
  // app handler → `{pong: true, ts}` 반환. 양방향 채널 sanity check 용.
  // 후속 tool (`take_snapshot`, `find_element` 등) 이 같은 패턴으로 등록.
  handlers.ping = function (params) {
    return {
      pong: true,
      ts: Date.now(),
      echo: params || null,
    };
  };

  // ─── Fiber tree 순회 + ref 시스템 (PR-F1 baseline) ───
  //
  // React DevTools 의 global hook 통해 fiber root 접근 → DFS 순회로 component 검색.
  // 각 매칭 element 에 opaque ref (`e1`, `e2`, ...) 부여 + Map 으로 reverse-lookup.
  // 후속 tool (inspect_state, eval_code 등) 이 ref 로 instance 호출.
  //
  // 메모리 가이드: 매 find 호출마다 새 ref 부여 — 기존 ref invalidate 안 함. caller
  // 가 stale ref 받아도 inspect_state 가 null 응답. RN fast-refresh 시 tree 재구성
  // 되어도 동작.
  //
  // refMap 의 unbounded growth 방지 — REF_MAP_MAX 도달 시 가장 오래된 entry 를 FIFO
  // 로 evict. Map 의 insertion-order 보장 사용 (ES2015+). fiber 는 strong reference
  // 라 evict 안 하면 unmount 된 subtree 까지 GC 못 함 — 디버그 세션에서 find_element
  // 를 hot loop 로 호출하면 누적.
  //
  // PR-F5 fix: 1024 — take_snapshot 가 단일 call 로 최대 1024 node 까지 ref 발급
  // 가능하므로 그 만큼 cap 도 함께 보장해야 즉시 evict 되지 않음. (이전 256 은
  // single snapshot 1000 node 가 첫 ~744 ref 를 evict 시켰음).
  var REF_MAP_MAX = 1024;
  var refMap = new Map(); // ref string → fiber pointer (insertion-ordered)
  var refIdCounter = 1;

  function nextRefId() {
    var id = refIdCounter;
    refIdCounter += 1;
    return 'e' + id;
  }

  function rememberRef(ref, fiber) {
    if (refMap.size >= REF_MAP_MAX) {
      // 가장 오래된 entry (Map iteration order = insertion order) drop.
      var oldest = refMap.keys().next().value;
      if (oldest != null) refMap.delete(oldest);
    }
    refMap.set(ref, fiber);
  }

  function getFiberRoots() {
    var hook = g.__REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!hook || typeof hook.getFiberRoots !== 'function') return [];
    // RN 은 보통 renderer 1개 (RCTHostView), 그러나 multi-renderer 가능성 위해
    // hook.renderers (Map<rendererID, RendererInterface>) 전체를 iterate.
    var roots = [];
    try {
      var renderers = hook.renderers;
      if (renderers && typeof renderers.forEach === 'function') {
        renderers.forEach(function (_, rendererID) {
          var rootsSet = hook.getFiberRoots(rendererID);
          if (rootsSet && typeof rootsSet.forEach === 'function') {
            rootsSet.forEach(function (root) {
              roots.push(root);
            });
          }
        });
      }
    } catch (err) {
      // DevTools hook 이 unexpected state — silent ignore 면 디버그 어려움.
      // RN console 가 있으면 warn (loop 가능성 낮음, getFiberRoots 는 매 find 마다 한번).
      if (g.console && typeof g.console.warn === 'function') {
        try {
          g.console.warn('[zntc:mcp:runtime] getFiberRoots failed:', err && err.message);
        } catch (_) {
          /* console 자체 throw — 더 할 수 있는 게 없음 */
        }
      }
    }
    return roots;
  }

  function getComponentName(fiber) {
    if (!fiber || !fiber.type) return null;
    var t = fiber.type;
    if (typeof t === 'string') return t; // host component (View, Text, etc)
    return t.displayName || t.name || null;
  }

  function getTextContent(fiber) {
    // RN host text fiber 는 두 패턴:
    //   1. `<Text>Hello</Text>` → memoizedProps.children === 'Hello'
    //   2. host text node (RN 의 RCTText 내부) → memoizedProps === 'Hello' (string 자체)
    // children 가 array (e.g. `<Text>Hi {name}</Text>`) 인 경우는 미지원 — 후속 PR.
    if (!fiber) return null;
    if (typeof fiber.memoizedProps === 'string') return fiber.memoizedProps;
    if (fiber.memoizedProps && typeof fiber.memoizedProps.children === 'string') {
      return fiber.memoizedProps.children;
    }
    return null;
  }

  // DFS — fiber.child 따라 내려가고 fiber.sibling 따라 옆으로. parent chain 은
  // fiber.return.
  function walkFiber(root, visitor) {
    var current = root.current; // FiberRoot 의 current = root fiber
    if (!current) return;
    var stack = [current];
    while (stack.length > 0) {
      var fiber = stack.pop();
      if (!fiber) continue;
      if (visitor(fiber) === false) return; // early stop
      if (fiber.sibling) stack.push(fiber.sibling);
      if (fiber.child) stack.push(fiber.child);
    }
  }

  function matchByText(fiber, value) {
    var text = getTextContent(fiber);
    return typeof text === 'string' && text.indexOf(value) !== -1;
  }

  function matchByComponent(fiber, value) {
    return getComponentName(fiber) === value;
  }

  function matchByRole(fiber, value) {
    var props = fiber.memoizedProps;
    if (!props || typeof props !== 'object') return false;
    return props.accessibilityRole === value || props.role === value;
  }

  function serializeFiber(fiber, ref) {
    var name = getComponentName(fiber) || '(unknown)';
    var text = getTextContent(fiber);
    var props = fiber.memoizedProps || {};
    var summary = {
      ref: ref,
      component: name,
    };
    if (text != null) summary.text = text;
    var role = (props && (props.accessibilityRole || props.role)) || null;
    if (role) summary.role = role;
    var label = (props && (props.accessibilityLabel || props['aria-label'])) || null;
    if (label) summary.label = label;
    if (props && typeof props.testID === 'string') summary.testID = props.testID;
    // source — React 의 _debugSource 가 fileName + lineNumber 보유 (dev only).
    var src = fiber._debugSource;
    if (src && typeof src.fileName === 'string') {
      summary.source =
        src.fileName + (typeof src.lineNumber === 'number' ? ':' + src.lineNumber : '');
    }
    return summary;
  }

  // find_element({ by, value }) — by: 'text' / 'role' / 'component'. value: string.
  // 첫 매칭 element 반환. 매칭 없으면 `{ found: false }`.
  //
  // 잘못된 input (params 누락, unknown `by`, fiber root 없음) 는 **throw** 한다 —
  // dispatcher (onmessage) 가 catch 해서 JSON-RPC `-32603 Internal error` 로 wrap →
  // MCP client 가 표준 error 채널로 받음. `{error:...}` 객체 반환은 result content
  // 안에 묻혀 silent fail 처럼 보이는 anti-pattern (PR-F1 review F4).
  handlers.find_element = function (params) {
    if (!params || typeof params.by !== 'string' || typeof params.value !== 'string') {
      throw new Error(
        'find_element: params requires `by` (text/role/component) and `value` (string)',
      );
    }
    var matcher;
    if (params.by === 'text') matcher = matchByText;
    else if (params.by === 'role') matcher = matchByRole;
    else if (params.by === 'component') matcher = matchByComponent;
    else {
      throw new Error('find_element: unknown `by` -- only text/role/component supported');
    }

    var roots = getFiberRoots();
    if (roots.length === 0) {
      throw new Error(
        'find_element: no React fiber root found (DevTools hook not installed or React not mounted yet)',
      );
    }

    var found = null;
    for (var i = 0; i < roots.length && !found; i++) {
      walkFiber(roots[i], function (fiber) {
        if (matcher(fiber, params.value)) {
          var ref = nextRefId();
          rememberRef(ref, fiber);
          found = serializeFiber(fiber, ref);
          return false; // early stop
        }
        return true;
      });
    }
    return found || { found: false };
  };

  // (internal) refMap 노출 — 후속 tool (inspect_state) 이 ref → fiber 조회. test 도 사용.
  handlers.__getFiberByRef = function (params) {
    if (!params || typeof params.ref !== 'string') return { fiber: null };
    return { has: refMap.has(params.ref) };
  };

  // ─── inspect_state (PR-F2) ───
  //
  // safeSerialize — JSON.stringify 의 cycle / non-serializable 값 핸들링.
  // - function/symbol/undefined → marker string ('[Function]' 등)
  // - Map/Set/Date/Promise/Error/TypedArray → 명시적 marker
  // - cycle → '[Circular]'
  // - max depth → '[MaxDepth]' (RN 의 큰 fiber tree 가 nested props 갖기도)
  // - throwing getter/Proxy → '[Throws ...]' (해당 key 만 marker, 전체 inspect 실패 방지)
  // - 긴 array → 앞 N 개만 + '[...M more]'
  // 결과는 plain object/array/primitive 만 — JSON.stringify 안전.
  var SERIALIZE_MAX_DEPTH = 8;
  var SERIALIZE_MAX_ARRAY = 256;
  function safeSerialize(value, seen, depth) {
    if (depth > SERIALIZE_MAX_DEPTH) return '[MaxDepth]';
    if (value === null) return null;
    var t = typeof value;
    if (t === 'string' || t === 'boolean') return value;
    if (t === 'number') {
      // NaN / Infinity 는 JSON 표현 불가 → marker.
      if (value !== value) return '[NaN]';
      if (value === Infinity) return '[+Infinity]';
      if (value === -Infinity) return '[-Infinity]';
      return value;
    }
    if (t === 'undefined') return '[Undefined]';
    if (t === 'function') {
      return '[Function' + (value.name ? ' ' + value.name : '') + ']';
    }
    if (t === 'symbol') return '[Symbol]';
    if (t === 'bigint') return '[BigInt ' + value.toString() + ']';
    if (t !== 'object') return '[' + t + ']';

    if (seen.has(value)) return '[Circular]';
    seen.add(value);

    try {
      if (Array.isArray(value)) {
        var arr = [];
        var cap = Math.min(value.length, SERIALIZE_MAX_ARRAY);
        for (var i = 0; i < cap; i++) {
          arr.push(safeSerialize(value[i], seen, depth + 1));
        }
        if (value.length > SERIALIZE_MAX_ARRAY) {
          arr.push('[...' + (value.length - SERIALIZE_MAX_ARRAY) + ' more]');
        }
        return arr;
      }
      // 잘 알려진 instance 들 — 빈 object 로 직렬화되지 않게 marker.
      if (value instanceof Date) return '[Date ' + value.toISOString() + ']';
      if (typeof Map !== 'undefined' && value instanceof Map)
        return '[Map size=' + value.size + ']';
      if (typeof Set !== 'undefined' && value instanceof Set)
        return '[Set size=' + value.size + ']';
      if (typeof Error !== 'undefined' && value instanceof Error) {
        return '[Error ' + (value.message || value.name || '?') + ']';
      }
      if (typeof Promise !== 'undefined' && value instanceof Promise) return '[Promise]';
      // TypedArray (Uint8Array/Int32Array/...) — large image/audio buffer 가 props 에
      // 들어오면 전체 byte 직렬화로 폭주. ArrayBuffer.isView 가 모든 typed array + DataView
      // 커버. byteLength 만 marker 에 포함.
      if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView && ArrayBuffer.isView(value)) {
        var ctor = (value.constructor && value.constructor.name) || 'TypedArray';
        var len = typeof value.byteLength === 'number' ? value.byteLength : value.length || 0;
        return '[' + ctor + ' byteLength=' + len + ']';
      }
      if (typeof ArrayBuffer !== 'undefined' && value instanceof ArrayBuffer) {
        return '[ArrayBuffer byteLength=' + value.byteLength + ']';
      }
      // React element ($$typeof Symbol) — 거대한 children 트리 직렬화 방지. Proxy 가
      // 임의 get trap 으로 throw 할 수 있어 try/catch.
      try {
        if (value.$$typeof) return '[ReactElement]';
      } catch (e) {
        return '[Throws ' + ((e && e.message) || '?') + ']';
      }

      var out = {};
      // Own enumerable keys 만 — prototype chain (e.g. component instance methods) 제외.
      // F3: 사용자 정의 getter / Proxy get trap 이 throw 하면 한 key 만 marker — 전체
      // inspect_state 실패 방지.
      for (var key in value) {
        if (Object.prototype.hasOwnProperty.call(value, key)) {
          try {
            out[key] = safeSerialize(value[key], seen, depth + 1);
          } catch (e2) {
            out[key] = '[Throws ' + ((e2 && e2.message) || '?') + ']';
          }
        }
      }
      return out;
    } finally {
      seen.delete(value);
    }
  }

  // React 18 fiber 의 memoizedState 가 function component 면 Hook linked list:
  //   { memoizedState, baseState, queue, next } chain.
  // _debugHookTypes (dev only) 가 hook 이름 array — index 로 매칭.
  function serializeHooks(fiber) {
    var hook = fiber.memoizedState;
    if (!hook || typeof hook !== 'object') return null;
    // class component 의 state 객체 인지 hook chain 인지 판별 — hook 은 `next` field 와
    // `memoizedState` field 동시 보유 (React 가 internal contract). 그 외는 class state.
    if (!('next' in hook) || !('memoizedState' in hook)) return null;

    var types = Array.isArray(fiber._debugHookTypes) ? fiber._debugHookTypes : [];
    var hooks = [];
    var cur = hook;
    var idx = 0;
    var MAX_HOOKS = 64; // 안전 한도 — 정상 component 는 수개~수십개.
    var seen = new Set();
    while (cur && hooks.length < MAX_HOOKS) {
      if (seen.has(cur)) break; // cycle guard (이론상 없지만 방어)
      seen.add(cur);
      // useEffect 등의 Effect 객체는 fiber-wide Effect linked list 의 next 를 갖고 있어서
      // memoizedState 그대로 직렬화하면 동일 chain 이 hook 마다 중복 트리화. tag/create/
      // destroy/deps 시그너처로 Effect 감지 → marker.
      var hookValue = cur.memoizedState;
      var isEffectLike =
        hookValue != null &&
        typeof hookValue === 'object' &&
        typeof hookValue.tag === 'number' &&
        'create' in hookValue &&
        'deps' in hookValue;
      hooks.push({
        type: types[idx] || null,
        value: isEffectLike
          ? '[Effect tag=' + hookValue.tag + ']'
          : safeSerialize(hookValue, new Set(), 0),
      });
      cur = cur.next;
      idx += 1;
    }
    // 64 hook 초과 시 silent truncate 면 reader 가 완전한 list 로 오인. marker 명시.
    if (cur && hooks.length >= MAX_HOOKS) {
      hooks.push({ type: '[...truncated]', value: null });
    }
    return hooks;
  }

  // inspect_state({ ref }) — find_element 가 부여한 ref 로 fiber lookup, props/state/hooks
  // 직렬화. ref 가 없거나 fiber 가 unmount 됐으면 throw → -32603.
  handlers.inspect_state = function (params) {
    if (!params || typeof params.ref !== 'string') {
      throw new Error('inspect_state: params requires `ref` (string from find_element)');
    }
    var fiber = refMap.get(params.ref);
    if (!fiber) {
      throw new Error('inspect_state: ref `' + params.ref + '` not found (expired or unknown)');
    }

    var name = getComponentName(fiber) || '(unknown)';
    // fiber kind 판별:
    //   - host: `fiber.type` 이 string (View, Text 등 RN 내장 / DOM 의 div). stateNode
    //     는 NativeViewInstance 라 React Component 아님.
    //   - class: stateNode 가 React.Component 인스턴스 — Component.prototype 에
    //     `isReactComponent = {}` (빈 객체) 가 박혀 있어 truthy check (F1 fix:
    //     `=== true` 는 잘못된 contract, 실제 React 는 `{}`).
    //   - function: 그 외 (hook 기반 컴포넌트). memoizedState 가 Hook linked list.
    var isHost = typeof fiber.type === 'string';
    var isClass =
      !isHost &&
      fiber.stateNode != null &&
      typeof fiber.stateNode === 'object' &&
      !!fiber.stateNode.isReactComponent;
    var kind = isHost ? 'host' : isClass ? 'class' : 'function';

    var snapshot = {
      ref: params.ref,
      component: name,
      kind: kind,
      props: safeSerialize(fiber.memoizedProps, new Set(), 0),
    };

    if (isClass) {
      snapshot.state = safeSerialize(fiber.memoizedState, new Set(), 0);
    } else if (!isHost) {
      var hooks = serializeHooks(fiber);
      if (hooks != null) snapshot.hooks = hooks;
    }
    return snapshot;
  };

  // ─── eval_code (PR-F3) ───
  //
  // user 가 보낸 JavaScript expression 을 RN main JS thread 에서 평가. ref 가 있으면
  // 그 fiber 의 context (stateNode → class 인스턴스 / host NativeView / 없으면 props/
  // state snapshot) 를 `this` + `$ctx` 양쪽에 바인딩.
  //
  // **중요한 contract**:
  //   - 동기 expression 전용 — `await` / `yield` 는 SyntaxError. `new Function` 이라
  //     async function 안 됨. Promise 반환 가능 (resolve 안 기다림, marker 직렬화).
  //   - 평가는 RN main JS thread 에서 발생 — **side-effect 가능**. `this.setState(...)`
  //     로 컴포넌트 mutate, `globalThis.foo = ...` 로 global 변경. dev 디버거 console
  //     처럼 동작 (pure observer 아님).
  //   - 'use strict' — sloppy mode 의 묵시적 global 변수 생성 차단. props 가 frozen
  //     이면 `this.props = {}` 가 TypeError 로 표면화.
  //
  // 보안: arbitrary code 평가 — dev 빌드에만 inject 되므로 production 우려 없음.
  //
  // Hermes 호환: 일부 Hermes 빌드는 `enableEval = false` 라 `new Function` 자체가 throw.
  // 첫 호출 시 1회 probe → unsupported kind 로 의미 있는 메시지 반환 (모든 eval_code
  // 호출이 cryptic "syntax error" 로 보이는 anti-pattern 회피).
  //
  // 에러 분류:
  //   - system error (params 누락, unknown ref) → throw → dispatcher 가 -32603 wrap.
  //     find_element / inspect_state 와 동일 contract.
  //   - runtime / syntax error → {ok:false, error, kind, stack} 으로 result 안에. user
  //     input 의 결과는 result 채널로 — IDE / repl 의 통상 동작.
  //   - JS engine 이 eval 비허용 → {ok:false, kind:'unsupported', error}. 다른 tool
  //     (inspect_state) 로 대체 안내.

  // 1회 probe — install time. typeof Function 자체는 항상 있지만 `new Function('...')`
  // 가 Hermes enableEval=false 일 때 throw. 매 호출마다 probe 하면 매번 overhead +
  // exception throw 비용이라 cached.
  var EVAL_SUPPORTED = (function () {
    try {
      // 부작용 0 — 그냥 빈 함수 만들기만.
      new Function('return 0;');
      return true;
    } catch (_) {
      return false;
    }
  })();

  handlers.eval_code = function (params) {
    if (!params || typeof params.expression !== 'string') {
      throw new Error('eval_code: params requires `expression` (string)');
    }
    if (!EVAL_SUPPORTED) {
      return {
        ok: false,
        kind: 'unsupported',
        error:
          'eval_code unavailable -- JS engine disables `new Function` (typically Hermes ' +
          'enableEval=false). Use inspect_state for read-only fiber inspection.',
      };
    }
    var expr = params.expression;
    var ctx = null;
    if (typeof params.ref === 'string') {
      var fiber = refMap.get(params.ref);
      if (!fiber) {
        throw new Error('eval_code: ref `' + params.ref + '` not found (expired or unknown)');
      }
      // class → component 인스턴스 (this.props/this.state 접근 + setState 호출 가능),
      // host (type=string) → NativeView (stateNode), 그 외 (function/forwardRef/memo/
      // Fragment) → props + memoizedState snapshot. function component 의 memoizedState
      // 는 Hook linked list 라 일반 `state.x` 접근은 inspect_state 결과 보고 따로.
      if (
        fiber.stateNode &&
        typeof fiber.stateNode === 'object' &&
        fiber.stateNode.isReactComponent
      ) {
        ctx = fiber.stateNode;
      } else if (typeof fiber.type === 'string') {
        // host fiber 가 pre-mount 면 stateNode null — `this` 가 undefined 라 user
        // 코드의 `this.foo` 가 runtime error. acceptable (감지 가능).
        ctx = fiber.stateNode || null;
      } else {
        // forwardRef / memo / Fragment / function component — stateNode null.
        // memoizedState 는 hook chain (function component) 일 수 있어 raw 노출이지만
        // 일반 inspect 용도로는 충분.
        ctx = { props: fiber.memoizedProps, memoizedState: fiber.memoizedState };
      }
    }

    var fn;
    try {
      // `new Function` body — expression 을 괄호로 감싸 statement 와 구분.
      // `$ctx` 는 명시 파라미터, `this` 는 .call 의 first arg 로 동시 바인딩.
      fn = new Function('$ctx', '"use strict"; return (' + expr + ');');
    } catch (synErr) {
      return {
        ok: false,
        error: (synErr && synErr.message) || String(synErr),
        kind: 'syntax',
      };
    }

    try {
      var result = fn.call(ctx, ctx);
      return {
        ok: true,
        value: safeSerialize(result, new Set(), 0),
        type: typeof result,
      };
    } catch (runErr) {
      // stack 은 길어질 수 있어 cap (2KB) — fiber tree 같은 거대 객체 사용 안 했지만 안전.
      var stack = runErr && runErr.stack ? String(runErr.stack) : null;
      if (stack && stack.length > 2000) stack = stack.slice(0, 2000) + '...';
      return {
        ok: false,
        error: (runErr && runErr.message) || String(runErr),
        kind: 'runtime',
        stack: stack,
      };
    }
  };

  // ─── get_logs (PR-F4) ───
  //
  // RN 의 console.log/info/warn/error/debug 를 intercept 해 ring buffer 에 누적.
  // get_logs handler 로 cursor/since/level/limit filter + snapshot 반환. LLM 이
  // 디버깅 시 RN 화면을 직접 못 봐도 console 출력을 통해 상태 추적 가능.
  //
  // 설계:
  //   - 원본 console method 보존 — intercept 안에서 forward 호출 (RN dev 표시 유지).
  //   - args 는 safeSerialize 통과 — function/cycle/typed-array 등 안전.
  //     args 는 **call time** 에 직렬화 — Promise 는 `[Promise]` marker (resolve 안
  //     기다림). 각 arg 별 독립 cycle 추적 (Set per-arg). 같은 sub-object 가 두 arg
  //     에 걸쳐 있어도 각각 직렬화 — `[Circular]` 는 한 arg 안의 cycle 만.
  //   - ring buffer 1000 entries, FIFO. 초과 시 oldest drop + `dropped` counter
  //     누적 (cumulative — runtime install 이후 evict 된 총합).
  //   - 각 entry 에 monotonic `seq` 부여. **pagination 은 seq 기반 cursor 사용 추천**
  //     — `ts` (Date.now ms) 는 1ms 안에 여러 entry 있으면 same-ms 가 lost.
  //   - intercept 는 idempotent — 한 번만. RN HMR 시 startMcpRuntime 가 early-return
  //     하므로 자연스럽게 1회 wrap.
  //
  // **Wrap order contract**: 본 wrap 은 startMcpRuntime 가 실행되는 시점 (앱 entry
  // preamble — `InitializeCore` 이후) 에 적용. RN LogBox / DevTools 가 wrap 만 하고
  // replace 안 하면 그들이 outer chain 으로 호출됨 (LogBox(wrapped(original))) — ring
  // buffer 는 여전히 entry 캡처. 누군가 console.log 를 **replace** (덮어쓰기) 하면
  // ring buffer 끊김 — 주의.
  //
  // **Side-effect**: globalThis.console 의 5개 method 가 wrap 됨. 다른 라이브러리가
  // console.log.toString() 등으로 native check 하면 다를 수 있음 (드문 케이스).
  var LOG_RING_MAX = 1000;
  var LOG_DEFAULT_LIMIT = 100; // schema description 의 default 와 single source.
  var logRing = []; // entries: {seq, ts, level, args}
  var logSeq = 0;
  var logDropped = 0; // 누적 drop 카운터 (overflow eviction, runtime install 이후 monotonic)
  var LOG_LEVELS = ['log', 'info', 'warn', 'error', 'debug'];

  function appendLog(level, argsArray) {
    if (logRing.length >= LOG_RING_MAX) {
      logRing.shift();
      logDropped += 1;
    }
    var serialized = [];
    for (var i = 0; i < argsArray.length; i++) {
      // 각 arg 독립적으로 직렬화 — circular 가 한 arg 에 갇혀 옆 arg 영향 X.
      serialized.push(safeSerialize(argsArray[i], new Set(), 0));
    }
    logSeq += 1;
    logRing.push({
      seq: logSeq,
      ts: Date.now(),
      level: level,
      args: serialized,
    });
  }

  // console method 가 console 자체에 있는지 (Hermes 일부 env 가 console null/undefined)
  // 확인 후 wrap. wrap 의 closure 가 `original` 보존.
  if (g.console && typeof g.console === 'object') {
    for (var li = 0; li < LOG_LEVELS.length; li++) {
      (function (level) {
        var original = g.console[level];
        if (typeof original !== 'function') return;
        // 이미 wrap 됐으면 (HMR 가 startMcpRuntime 안 통하고 import 만 갱신한 edge case)
        // 다시 wrap 하면 double-log → marker 로 idempotency 보장.
        if (original.__zntcMcpWrapped === true) return;
        var wrapped = function () {
          // arguments → array
          var argsArr = new Array(arguments.length);
          for (var i = 0; i < arguments.length; i++) argsArr[i] = arguments[i];
          try {
            appendLog(level, argsArr);
          } catch (_) {
            /* ring buffer 자체 throw 면 RN 콘솔 영향 안 받게 swallow */
          }
          return original.apply(this, arguments);
        };
        wrapped.__zntcMcpWrapped = true;
        g.console[level] = wrapped;
      })(LOG_LEVELS[li]);
    }
  }

  handlers.get_logs = function (params) {
    var p = params || {};
    // cursor (seq) 가 same-ms 손실 없는 정확한 pagination — caller 가 response 의
    // `nextCursor` 를 다음 호출의 `cursor` 로 넘기면 lossless.
    // since (ts) 는 사람이 timestamp 로 자르고 싶을 때 — coarse filter.
    var cursorSeq = typeof p.cursor === 'number' ? p.cursor : -Infinity;
    var sinceTs = typeof p.since === 'number' ? p.since : -Infinity;
    var levelFilter = null;
    if (typeof p.level === 'string') {
      if (LOG_LEVELS.indexOf(p.level) === -1) {
        throw new Error('get_logs: invalid `level` -- must be one of log/info/warn/error/debug');
      }
      levelFilter = p.level;
    }
    if (p.limit != null) {
      if (typeof p.limit !== 'number' || !isFinite(p.limit) || p.limit < 1) {
        throw new Error('get_logs: invalid `limit` -- must be a positive number');
      }
    }
    var limit = typeof p.limit === 'number' ? Math.floor(p.limit) : LOG_DEFAULT_LIMIT;
    if (limit > LOG_RING_MAX) limit = LOG_RING_MAX;

    // Forward 순회 (oldest → newest) 로 cursor/since/level filter 후 newest limit
    // 슬라이스. cursor 와 since 둘 다 있으면 AND (cursor 우선 — strictly newer).
    var filtered = [];
    for (var i = 0; i < logRing.length; i++) {
      var e = logRing[i];
      if (e.seq <= cursorSeq) continue;
      if (e.ts <= sinceTs) continue;
      if (levelFilter != null && e.level !== levelFilter) continue;
      filtered.push(e);
    }
    // newest limit 반환 — 끝에서 N개 (LLM context 효율).
    var sliced = filtered.length > limit ? filtered.slice(filtered.length - limit) : filtered;
    return {
      entries: sliced,
      // 다음 호출에 `cursor: nextCursor` 로 넘기면 lossless 이어보기. entries 가 비어도
      // 마지막 seq 유지 (단조 증가 보장).
      nextCursor: sliced.length > 0 ? sliced[sliced.length - 1].seq : cursorSeq,
      dropped: logDropped,
      total: logRing.length,
    };
  };

  // ─── take_snapshot (PR-F5) ───
  //
  // fiber tree 전체 (또는 ref 의 subtree) 를 nested summary 로 직렬화. find_element
  // 의 single-shot 결과와 달리 화면 전체 구조 한 번에 파악 — LLM 의 "이 화면에 뭐
  // 있어?" 질의 대응.
  //
  // 각 node 는 serializeFiber 와 같은 shape (component, text, role, label, testID,
  // source) + children. 매 node 마다 fresh ref 부여 → 후속 inspect_state / eval_code
  // / tap 등이 그 ref 로 target 가능. (refMap 의 256-cap 이 적용되어 큰 tree 일 때
  // 오래된 ref 가 evict 될 수 있음 — caller 가 받자마자 사용 권장.)
  //
  // depth / node cap 으로 폭주 방지. 초과 시 partial snapshot + truncated:true 또는
  // __depth_truncated:true marker.
  var SNAPSHOT_DEFAULT_DEPTH = 12;
  var SNAPSHOT_MAX_DEPTH_CAP = 32;
  // refMap 의 REF_MAP_MAX 와 align — snapshot 결과의 ref 가 즉시 evict 되지 않게.
  // 더 큰 화면이 필요하면 ref 기반 subtree snapshot 으로 나누어 호출.
  var SNAPSHOT_DEFAULT_NODES = 256;
  var SNAPSHOT_MAX_NODES_CAP = REF_MAP_MAX;

  function snapshotFiber(fiber, depth, maxDepth, state) {
    if (state.nodes >= state.maxNodes) {
      state.truncated = true;
      return null;
    }
    if (depth > maxDepth) {
      // depth-truncated node — fresh ref 부여해 caller 가 후속 take_snapshot({ref})
      // 로 그 subtree 를 expand 할 수 있게 (review F4). state.nodes 도 카운트 —
      // refMap 쓰는 entry 와 1:1 align (truncated 마커도 ref slot 차지).
      state.nodes += 1;
      var truncRef = nextRefId();
      rememberRef(truncRef, fiber);
      return { ref: truncRef, __depth_truncated: true };
    }
    state.nodes += 1;
    var ref = nextRefId();
    rememberRef(ref, fiber);
    var node = serializeFiber(fiber, ref);
    // children — fiber.child 의 sibling chain 순회.
    var child = fiber.child;
    if (child) {
      var children = [];
      while (child) {
        if (state.nodes >= state.maxNodes) {
          // 더 처리할 child 가 남았는데 한도 도달 — truncated 명시.
          state.truncated = true;
          break;
        }
        var c = snapshotFiber(child, depth + 1, maxDepth, state);
        if (c != null) children.push(c);
        child = child.sibling;
      }
      if (children.length > 0) node.children = children;
    }
    return node;
  }

  handlers.take_snapshot = function (params) {
    var p = params || {};

    // option 정규화 + 범위 enforce.
    var maxDepth =
      typeof p.max_depth === 'number' && p.max_depth >= 1
        ? Math.min(Math.floor(p.max_depth), SNAPSHOT_MAX_DEPTH_CAP)
        : SNAPSHOT_DEFAULT_DEPTH;
    var maxNodes =
      typeof p.max_nodes === 'number' && p.max_nodes >= 1
        ? Math.min(Math.floor(p.max_nodes), SNAPSHOT_MAX_NODES_CAP)
        : SNAPSHOT_DEFAULT_NODES;

    var state = { nodes: 0, maxNodes: maxNodes, truncated: false };

    // ref 있으면 그 subtree 만, 없으면 모든 fiber root.
    if (typeof p.ref === 'string') {
      var fiber = refMap.get(p.ref);
      if (!fiber) {
        throw new Error('take_snapshot: ref `' + p.ref + '` not found (expired or unknown)');
      }
      var node = snapshotFiber(fiber, 0, maxDepth, state);
      return {
        root: node,
        nodes: state.nodes,
        truncated: state.truncated,
      };
    }

    var roots = getFiberRoots();
    if (roots.length === 0) {
      throw new Error(
        'take_snapshot: no React fiber root found (DevTools hook not installed or React not mounted yet)',
      );
    }

    var trees = [];
    for (var i = 0; i < roots.length; i++) {
      // 한도 도달 후 남은 root 가 있으면 truncated 표시 — silent partial 방지
      // (review F2). 단순 loop predicate 만으로는 truncated flag 가 false 로 남음.
      if (state.nodes >= state.maxNodes) {
        state.truncated = true;
        break;
      }
      var rootCurrent = roots[i].current;
      if (!rootCurrent) continue;
      var tree = snapshotFiber(rootCurrent, 0, maxDepth, state);
      if (tree != null) trees.push(tree);
    }
    return {
      roots: trees,
      nodes: state.nodes,
      truncated: state.truncated,
    };
  };

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
          '[zntc:mcp:runtime] send dropped — WS closed (state=' +
            state.connectionState +
            ')' +
            idHint,
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
