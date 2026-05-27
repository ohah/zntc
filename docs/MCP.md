# MCP — Model Context Protocol

zntc dev server 가 제공하는 **Model Context Protocol (MCP)** 엔드포인트와 11개
tool 의 사용 가이드. Claude Code / Cursor / Claude Desktop 같은 LLM 에이전트가
JSON-RPC 2.0 으로 직접 호출.

zntc 의 MCP 는 두 transport 를 지원한다:

- **HTTP `/mcp`** — `zntc --serve` 모드의 dev server 가 자동 노출. `.mcp.json`
  의 `url` 필드로 연결.
- **stdio** — `zntc mcp` 서브명령. child process 로 spawn 하는 클라이언트 (Claude
  Desktop 일부 환경) 가 stdin/stdout 으로 frame 교환.

두 transport 가 **다른 인스턴스**: `zntc mcp` 는 HTTP listener 가 없는 별개
DevServer (in-memory dispatcher 만). `--serve` 와는 in-memory state (`/__mcp-app`
WebSocket 연결, watcher, event ring) 가 공유되지 않는다.

- `zntc mcp` (stdio) — `reset_cache` / `get_build_events` / `verify_in_chrome` 만
  의미 있음. RN debug 7종 + `ping_app` 은 항상 `-32603 app not connected` (RN 앱이
  연결될 listener 가 없으므로).
- `zntc --serve` (HTTP `/mcp`) — 11개 tool 전부 사용 가능.

## 개요

11개 tool 을 세 카테고리로 분류:

| 카테고리 | 개수 | 도구 |
| --- | --- | --- |
| **Build domain** | 3 | `reset_cache`, `get_build_events`, `verify_in_chrome` |
| **RN app channel sanity** | 1 | `ping_app` |
| **RN debugging** | 7 | `find_element`, `inspect_state`, `eval_code`, `get_logs`, `take_snapshot`, `tap_element`, `get_network` |

RN debugging 7종 + `ping_app` 은 dev server 의 `/__mcp-app` WebSocket 으로 연결된
RN 앱 안에서 실제 동작. 앱이 연결 안 된 상태로 호출하면 `-32603 app not
connected` 진단.

### 11 tool 이 다루지 못하는 영역 — adb / idb 의존

다음 작업들은 native bridge 가 필요해 JS dispatch 만으로는 불가능. **adb (Android
Debug Bridge) / idb (iOS Debug Bridge)** 통한 별도 처리가 정공법:

- 진짜 native key event dispatch (TextInput 의 keyboard event)
- 실제 touch coordinate 기반 tap / swipe / pinch (`tap_element` 는 onPress prop
  호출이지 native touch 가 아님)
- full screen screenshot (RN core 에 API 없음 — `react-native-view-shot` 같은
  외부 lib 또는 adb/idb)
- device 회전 / location 변경 / system permission dialog
- background ↔ foreground 전환

이런 use case 는 본 MCP tool 집합 밖. `eval_code` 로 외부 RN module
(`react-native-view-shot`, `@react-native-community/cameraroll` 등) 이 설치된
경우 우회 가능하나 — 진짜 native flow 검증이 목적이면 adb/idb / `xcrun simctl` /
Maestro 같은 도구가 정합.

## 연결

### Claude Code / Cursor (HTTP)

`.mcp.json` 예시 — workspace root 에 둠:

```json
{
  "mcpServers": {
    "zntc-dev": {
      "url": "http://localhost:12300/mcp"
    }
  }
}
```

`zntc dev` 또는 `zntc --serve --bundle index.ts` 실행 후 LLM 에이전트가 자동
`tools/list` → 11개 도구 발견.

### Claude Desktop (stdio)

`claude_desktop_config.json` 의 `mcpServers` 에 spawn 설정:

```json
{
  "mcpServers": {
    "zntc": {
      "command": "zntc",
      "args": ["mcp"]
    }
  }
}
```

stdio 는 build domain 3종 (reset_cache / get_build_events / verify_in_chrome) 만
사용 가능. RN debug 가 필요하면 별도로 `zntc --serve` 띄우고 HTTP transport 사용.

## RN dev 셋업 — `@zntc/react-native` mcp-runtime

RN 앱 측에서는 `@zntc/react-native` preset 의 `runBeforeMain` 단계에 zntc 의
`runtime/mcp-runtime.cjs` 파일이 자동 추가. 별도 설치 / 코드 작성 필요 없음.

동작:
1. preset 이 dev build (`dev: true`) 에 한해 `runBeforeMain` 배열에 `@zntc/
   react-native/runtime/mcp-runtime.cjs` 경로 prepend.
2. 앱 시작 시 자동 `ws://localhost:12300/__mcp-app` 연결.
3. dev server 가 `find_element` 등 tool 호출 → WebSocket 으로 RN 앱에 forward.
4. 앱 안의 handler 가 fiber tree 조회 / 호출 후 응답.

URL override: `globalThis.__ZNTC_MCP_APP_WS_URL__` 을 빌드 시 inject 하거나 앱
시작 전에 설정.

### Opt-out
- **빌드 설정**: zntc config 의 `extra.mcp = false` 명시 — RN preset 이
  `runBeforeMain` 에서 mcp-runtime.cjs 추가 안 함. WebView 디버깅용 wrapper 도
  같이 우회.
- **runtime 환경**: `globalThis.__ZNTC_DISABLE_MCP_RUNTIME__ = true` — 번들에는
  포함되지만 자동 connect 건너뜀. jest setup / 환경별 disable 에 사용.

### 적용 범위 한계
- **JS thread only**. Reanimated worklet runtime / `react-native-worklets-core`
  같은 별도 JS realm 에는 `__ZNTC_MCP_RUNTIME__` 등록 안 됨. worklet 안 component
  의 fiber tree 직렬화는 미지원.
- **Hermes `enableEval=false`**. `eval_code` 가 install-time probe 로 감지하고
  `kind:'unsupported'` 반환. 다른 tool 은 영향 없음.
- **production build**. `dev: false` 이면 preset 이 runBeforeMain 추가 자체를
  skip → production app 에 디버거 채널 노출 위험 없음.

## ref 시스템

3 tool 이 fiber 를 가리키는 **opaque ref** (`e1`/`e2`/...) 를 발급:
- `find_element` — 첫 매칭 fiber 의 ref 반환.
- `take_snapshot` — 트리 안 모든 node 에 ref 부여.
- (`inspect_state`/`eval_code`/`tap_element` 도 이 ref 받음.)

ref 는 1024-entry FIFO map 에 저장 — 가장 오래된 entry 부터 evict. take_snapshot
의 단일 call 이 최대 1024 node 까지 발급 가능 (`max_nodes` 의 hard cap 과 일치
— 자체 evict 방지).

### 워크플로우 예시

각 tool 의 `arguments` 만 단축 표기 (실제 JSON-RPC envelope 은
`{jsonrpc:"2.0", id, method:"tools/call", params:{name, arguments}}`):

```
find_element({by:'text', value:'Press me'})
  → {ref: 'e3', component: 'Text', text: 'Press me'}

inspect_state({ref: 'e3'})
  → {kind: 'host', component: 'Text', props: {children: 'Press me'}}

eval_code({ref: 'e3', expression: '$ctx.props.children'})
  → {ok: true, value: 'Press me', type: 'string'}

tap_element({ref: 'e3'})
  → {ok: true}  // ancestor TouchableOpacity 의 onPress 호출

get_logs({})
  → {entries: [{level:'log', args:['button pressed']}, ...]}
```

오래된 ref 가 evict 됐으면 (`not found` throw) → `find_element` / `take_snapshot`
재호출로 새 ref 발급.

## Tool reference

모든 tool 의 응답은 MCP spec 의 `content: [{type:"text", text:"<JSON 문자열>"}]`
형식으로 wrap. 클라이언트는 `content[0].text` 를 다시 `JSON.parse` 해야 한다.

### Build domain

#### `reset_cache`
- **input**: 없음
- **동작**: 다음 build 가 full rebuild 되도록 flag set. 즉시 반환.
- **응답**: `"Cache reset requested; next build will be a full rebuild."`

#### `get_build_events`
- **input**: `{duration?: number}` (ms, default 10000, range 1000-60000)
- **동작**: SSE event ring buffer 의 새 event 를 `duration` 까지 대기. 첫 event
  도착 즉시 반환 (no head-of-line blocking).
- **응답**: `[{seq, type, data}, ...]` JSON 배열을 text 로 wrap.
- **event type**: `server_ready`, `watch_change`, `bundle_build_started`,
  `bundle_build_done`, `bundle_build_failed`, `cache_reset`.

#### `verify_in_chrome`
- **input**: `{target?: string, timeout?: number, ignore?: string[],
  allowConsoleError?: boolean}`
- **동작**: Node CLI (`zntc verify --verify-json`) 를 자식 프로세스로 spawn 해
  Playwright headless Chromium 으로 target URL 의 console error / network
  failure 를 JSON 리포트로 받음.
- **사전 조건**: Node CLI 환경에서 `playwright` 가 optionalDependency 로 설치되어
  있어야. CI 는 `ZNTC_CLI` env 로 `bin/zntc.mjs` 경로 명시.
- **응답**: `{target, status, duration_ms, events: [...]}` text wrap.

### RN app channel sanity

#### `ping_app`
- **input**: 없음 (`{}` arguments)
- **동작**: `/__mcp-app` WebSocket 으로 연결된 RN 앱의 `handlers.ping` 호출.
  양방향 채널 sanity check.
- **응답**: `{pong: true, ts: <Date.now()>, echo: {}}` (앱 측 기본 handler).
- **사전 조건**: RN 앱이 dev server `/__mcp-app` 에 연결되어 있어야. 안 됐으면
  `-32603 app not connected on /__mcp-app`.

### RN debugging — fiber 조회 / 직렬화

#### `find_element`
- **input**: `{by: 'text'|'role'|'component', value: string}`
- **동작**: React fiber tree DFS 순회. `by` 전략:
  - `text` — `<Text>...</Text>` 의 children 또는 host text fiber 의 substring 매칭.
  - `role` — `props.accessibilityRole` 또는 `props.role` 정확 매칭.
  - `component` — `getComponentName(fiber)` (host string / displayName / name)
    정확 매칭.
- **응답**: `{ref, component, text?, role?, label?, testID?, source?}` 또는
  `{found: false}`.
- **한계**:
  - 첫 매칭만. 여러 매칭 중 특정 선택은 `take_snapshot` 후 ref 직접 사용.
  - DFS 순서 (child 우선, sibling 후) — `walkFiber` cycle guard 로 corrupted
    fiber 무한 loop 방지.
  - Text children array (`<Text>Hi {name}</Text>`) 미지원 — children 가 string
    인 경우만.

#### `inspect_state`
- **input**: `{ref: string}`
- **동작**: ref 의 fiber 의 메모이즈된 props / state / hooks 직렬화.
- **응답**: `{ref, component, kind: 'class'|'function'|'host', props, state?,
  hooks?}`.
  - `class`: `state` 가 `this.state` snapshot.
  - `function`: `hooks` 가 `_debugHookTypes` 와 매칭된 array. Effect 객체는
    `[Effect tag=N]` marker.
  - `host`: RN NativeView fiber — `props` 만 직렬화.
- **직렬화 규칙** (`safeSerialize`):
  - cycle → `[Circular]`
  - function → `[Function name]`
  - Date / Map / Set / Promise / TypedArray / ArrayBuffer / Error → marker
  - `$$typeof` (React element) → `[ReactElement]`
  - depth > 8 → `[MaxDepth]`
  - array > 256 → `[...N more]` truncation
  - throwing getter / Proxy → `[Throws msg]` per key

#### `eval_code`
- **input**: `{expression: string, ref?: string}`
- **동작**: JavaScript expression 평가. ref 있으면 그 fiber 의 stateNode (class
  인스턴스 / NativeView) 또는 fallback `{props, memoizedState}` snapshot 을
  `this` 와 `$ctx` 양쪽에 바인딩.
- **sync 와 async 자동**:
  - `new Function('$ctx', '"use strict"; return (' + expr + ')')` 시도.
  - SyntaxError (`await` 등) 면 `new AsyncFunction` retry.
  - 결과가 Promise 면 dispatcher 가 await.
- **응답**: `{ok: true, value, type}` 또는 `{ok: false, error, kind: 'syntax'|
  'runtime'|'unsupported', stack?}`.
- **side-effect 허용** — debugger console 시맨틱:
  - class component: `this.setState({...})` 호출 가능.
  - `globalThis.foo = ...` global mutation 가능.
- **한계**:
  - Hermes `enableEval=false` 빌드는 install-time probe 가 감지 → 모든 호출이
    `kind: 'unsupported'` 응답.
  - `yield` (generator) 는 지원 안 함.
  - JS-side cancel 없음 — 10s timeout 은 Zig dispatcher 가 enforce, 늦은 resolve
    는 orphan drop.
  - ref 가 function component fiber 면 stateNode 가 null → `$ctx` 가 `{props,
    memoizedState}` snapshot. `this.setState` 같은 class API 는 호출 불가
    (`inspect_state` 의 `kind` 로 분류 확인 가능).

#### `take_snapshot`
- **input**: `{ref?: string, max_depth?: number, max_nodes?: number}`
  - default max_depth = 12 (hard cap 32)
  - default max_nodes = 256 (hard cap 1024 = refMap size)
- **동작**: fiber tree DFS 직렬화. ref 없으면 모든 fiber root, ref 있으면 그
  subtree.
- **응답**: `{roots: [...] | root: {...}, nodes, truncated}`. 각 node 는
  `find_element` 와 같은 shape + `children?` + `__depth_truncated?` marker.
- **모든 node 가 fresh ref 받음** — 후속 inspect_state / eval_code / tap_element
  로 그 자리 target. depth-truncated marker 도 ref 가 있어 후속
  `take_snapshot({ref})` 로 expand.
- **한계**:
  - cycle 발견 시 `__cycle: true` marker (ref 없음) + `truncated: true`.
  - 256 노드 default — 큰 화면은 `max_nodes: 1024` 또는 `ref` subtree 분할.

### RN debugging — interaction / observability

#### `tap_element`
- **input**: `{ref: string}`
- **동작**: ref fiber 또는 ancestor (`fiber.return` 따라 최대 5 step,
  cycle-guarded) 의 `memoizedProps.onPress` 호출. Mock SyntheticEvent (target /
  currentTarget / preventDefault / persist 등) 전달.
- **응답**: `{ok: true}` 또는 `{ok: false, kind: 'no_handler'|'disabled'|
  'runtime', error?, stack?}`.
- **시맨틱**:
  - `props.disabled === true` 또는 `accessibilityState.disabled === true` →
    native touch 와 동일하게 `kind: 'disabled'` 로 short-circuit (handler 호출
    안 함).
  - async handler → Promise return → dispatcher 가 await.
  - **side-effect 허용** — handler 가 setState / dispatch / navigate / fetch
    호출 가능.
- **한계**:
  - `onPress` 만 호출 — `onLongPress` / `onPressIn` / `onPressOut` / `onClick`
    은 `eval_code` 로.
  - 5 ancestor 안에 onPress 없으면 `kind: 'no_handler'`.
  - native touch event 가 아니라 React prop callback 만 호출 — 진짜 native key
    dispatch 가 필요하면 adb/idb 사용.

#### `get_logs`
- **input**: `{cursor?: number, since?: number, level?: string, limit?: number}`
  - `cursor` — seq 기반 lossless pagination.
  - `since` — Unix ms timestamp, same-ms 손실 (cursor 권장).
  - `level` — `log`/`info`/`warn`/`error`/`debug` 중 하나.
  - `limit` — default 100, max 1000.
- **동작**: `console.log/info/warn/error/debug` intercept (mcp-runtime.cjs 가
  wrap) 의 1000-entry FIFO ring buffer snapshot.
- **응답**: `{entries: [{seq, ts, level, args}], nextCursor, dropped, total}`.
  - args 는 `safeSerialize` 거쳐 직렬화 — function / cycle / Promise marker.
  - `dropped` — runtime install 이후 **누적** evict count. delta 가 필요하면
    caller 가 이전 응답의 `dropped` 와 비교.
- **한계**:
  - args 는 **call time** 직렬화. `console.log(promiseChain)` 의 future value
    캡처 안 함 (Promise marker).
  - third-party (LogBox / Flipper) 가 console 을 **replace** (덮어쓰기) 하면
    intercept 끊김. wrap 하면 chain 유지.

#### `get_network`
- **input**: `{cursor?: number, method?: string, status?: number, status_min?:
  number, status_max?: number, url_substring?: string, limit?: number}`
- **동작**: `XMLHttpRequest.prototype.open/send` intercept. RN 의 `fetch()` 도
  내부적으로 XHR 통과 → 양쪽 모두 캡처. **200-entry FIFO ring buffer**.
- **응답**: `{entries: [{seq, tsStart, method, url, status?, durationMs?,
  error?}], nextCursor, dropped, total}`. pending request (load 전) 는
  `status: null` / `durationMs: null`.
- **filter 시 pending 자동 제외** — status/status_min/status_max 중 하나라도
  set 되면 unknown status 매칭 불가.
- **한계**:
  - **request / response body 미캡처** — privacy / size. 필요하면 `eval_code`
    로 `xhr.response` 직접 inspect.
  - `fetch()` 의 XHR 외 경로 (AbortController pre-abort, native security policy
    rejection) 는 캡처 안 함.
  - `dropped` — 누적 evict count (`get_logs` 와 동일).

## Use case 매핑 — 11 tool 으로 가능한 것 / 외부 도구 필요한 것

| 의도 | 본 tool 집합 안 처리 | 외부 의존 필요 |
| --- | --- | --- |
| ScrollView 스크롤 | `eval_code({ref, expression: 'this.scrollTo({y: 500, animated: false})'})` | — |
| TextInput 값 변경 (prop 콜백) | `eval_code({ref, expression: '$ctx.props.onChangeText("typed")'})` (TextInput 의 onChangeText prop 호출. `inspect_state` 로 prop 존재 확인 후) | 진짜 keyboard event 흐름은 adb/idb |
| Modal / Alert 띄우기 | `eval_code({expression: 'require("react-native").Alert.alert("msg")'})` | — |
| Navigation 호출 | `eval_code({ref, expression: 'this.props.navigation.navigate("Screen")'})` (또는 useNavigation 결과를 `inspect_state` 로 확인) | — |
| ring buffer "reset" (logs/network) | `get_logs({cursor: nextCursor})` 로 이미 본 부분 skip — server-side reset 은 별도 API 없음 | — |
| Screenshot | `react-native-view-shot` 설치된 경우 `eval_code({expression:'await require("react-native-view-shot").captureScreen({format:"png"})'})` | full native screenshot 은 adb (`adb shell screencap`) / idb (`idb screenshot`) / `xcrun simctl io ... screenshot` |
| 진짜 keyboard event / touch coords | — | adb `input keyevent` / `input tap`, idb `ui tap`, Maestro |
| Device 회전 / location / permission dialog | — | adb / idb / `xcrun simctl` |
| App background ↔ foreground | — | adb `am start` / idb `launch`+`terminate` |

본 11 tool 은 JS-thread 안의 React state / 콜백 / observability 채널을 다룸.
native 환경 자체 제어가 필요한 시나리오는 adb/idb 또는 Maestro 같은 상위 도구가
정공법.

## 진단 / 에러 코드

| Code | 상황 |
| --- | --- |
| `-32600` | Invalid Request (HTTP POST 외 method / body too large) |
| `-32601` | Method not found — JSON-RPC method 가 `initialize` / `tools/list` / `tools/call` 외 |
| `-32602` | Invalid params / **Unknown tool** — `tools/call` 의 `name` 이 11 tool 외 |
| `-32603` | Internal — `app not connected`, `app response timeout (Xms)`, RN handler 가 throw 한 message forward (그대로, prefix 없음), `args serialization failed` 등 |
| `-32700` | Parse error (HTTP body JSON 파싱 실패) |

`-32603` 의 message 에 `"missing 'result'"` 같은 fallback 진단이 보이면 RN 측
runtime 의 dispatcher 가 spec-violating envelope (id 있고 result/error 둘 다
없음) 을 보냈다는 의미.

## ref evict / "ref not found"

ref 가 1024-entry FIFO 라 `take_snapshot({max_nodes: 1024})` 한 번 후 다른
`find_element` 호출하면 oldest evict 가능. caller pattern:
1. 큰 화면은 ref subtree 단위로 잘라 `take_snapshot` — 그 트리만 ref slot 차지.
2. inspect / eval / tap 등의 후속 사용은 같은 trace 안에서 빨리 — 다른 tool 의
   ref 발급 사이.
3. `not found` 받으면 `find_element` 재호출 — fresh ref.

## 보안

- `eval_code` 와 `tap_element` 는 **side-effect 허용** — debugger console
  시맨틱. RN 앱의 임의 state 변경 + global mutation + fetch / navigation 가능.
- mcp-runtime 은 **dev build 에만 inject**. production build 는 `dev: false`
  에서 preset 이 runBeforeMain 추가 자체를 skip → 종단 사용자에게 채널 노출
  위험 없음.
- HTTP `/mcp` endpoint 와 `/__mcp-app` WebSocket 은 dev server 의 host:port
  binding 만큼 노출 — `127.0.0.1` (default) 면 본 머신만, `0.0.0.0` 으로 binding
  하면 LAN 노출. LAN 노출은 신뢰된 환경에서만.

## 참조 구현

- Zig 측 dispatcher: `src/server/dev_server.zig` 의 `handleMcp` / `handleToolsCall`
- Zig 측 app channel: `src/server/mcp_app_channel.zig`
- JS runtime: `packages/react-native/runtime/mcp-runtime.cjs`
- 통합 test: `tests/integration/tests/mcp-app-channel-e2e.test.ts`
