---
title: Dev Server
description: ZNTC dev server의 SSE 이벤트 스트림, Control API, MCP 서버
---

`zntc --serve --bundle <entry>`로 시작하는 dev 서버는 일반 HTTP/HMR 외에 **외부 자동화/관측 도구를 위한 3가지 인터페이스**를 제공합니다.

| 엔드포인트 | 용도 | 호환 |
|---|---|---|
| `/sse/events` | Server-Sent Events 스트림 — 실시간 빌드/watch 이벤트 | rollipop |
| `/reset-cache` | Control API — 외부에서 캐시 무효화 | rollipop |
| `/mcp` | MCP (Model Context Protocol) JSON-RPC | Claude Code, MCP 클라이언트 |

## 빠른 시작

```bash
zntc --serve --bundle src/index.tsx --port 12300
```

```bash
# SSE 이벤트 구독
curl -N http://localhost:12300/sse/events

# 캐시 리셋
curl -X POST http://localhost:12300/reset-cache

# MCP 도구 호출
curl -X POST http://localhost:12300/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## HMR — `import.meta.hot` API

`zntc --serve` 로 띄운 dev 서버는 변경된 모듈만 클라이언트로 push 하고, 모듈 단위로 재실행합니다. 사용자 코드는 `import.meta.hot` 으로 어떤 모듈이 hot boundary 인지, 업데이트가 들어왔을 때 무엇을 할지 제어합니다.

ZNTC 의 `import.meta.hot` 는 **Vite 호환** 입니다. 기존 Vite 플러그인 / 코드를 거의 그대로 가져올 수 있습니다.

### 기본 사용법

```ts
// src/store.ts
export const store = createStore();

if (import.meta.hot) {
  // 이 모듈을 hot boundary 로 표시
  import.meta.hot.accept((newModule) => {
    if (newModule) {
      // newModule.store 가 새 인스턴스
      replaceStore(newModule.store);
    }
  });
}
```

빌드 산출물에서 `import.meta.hot` 블록 전체는 **production 빌드** 에서 자동으로 제거됩니다 (dev 서버에서만 truthy).

### 의존성 변경 받기

```ts
// 자기 모듈 변경
import.meta.hot.accept((newSelf) => { ... });

// 특정 dep 의 변경
import.meta.hot.accept('./logger', (newLogger) => { ... });

// 여러 dep 한 번에
import.meta.hot.accept(['./a', './b'], ([newA, newB]) => { ... });
```

### Cleanup — `dispose`

모듈이 교체되기 직전에 호출됩니다. 타이머/리스너/소켓 정리에 사용:

```ts
const id = setInterval(tick, 1000);

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    clearInterval(id);
  });
}
```

### 데이터 전달 — `hot.data`

`dispose` 콜백이 받는 객체에 무엇을 담아두면, 새 모듈의 `import.meta.hot.data` 에서 읽을 수 있습니다 — 모듈 교체 사이에 상태 전달.

```ts
let count = import.meta.hot?.data.count ?? 0;

if (import.meta.hot) {
  import.meta.hot.dispose((data) => {
    data.count = count;        // 다음 모듈 인스턴스로 넘김
  });
}
```

### Full reload 강제 — `invalidate`

업데이트를 받았지만 안전하게 처리할 수 없을 때:

```ts
if (import.meta.hot) {
  import.meta.hot.accept((newModule) => {
    if (!canSafelyApply(newModule)) {
      import.meta.hot.invalidate();   // 페이지 전체 reload
    }
  });
}
```

브라우저에서는 `location.reload()`, React Native 에서는 `DevSettings.reload()` 가 호출됩니다.

### React Fast Refresh

`.tsx` / `.jsx` 파일이 **모든 export 가 React 컴포넌트** 인 경우 — `import.meta.hot.accept` 를 직접 작성하지 않아도 자동으로 hot boundary 로 처리됩니다. 컴포넌트 함수 / forwardRef / memo / lazy 가 컴포넌트로 인식됩니다.

```tsx
// Auto Fast Refresh — 명시적 hot 코드 불필요
export function Button({ children }) {
  return <button>{children}</button>;
}
```

다음 경우는 자동 boundary 가 동작하지 않아 **full reload** 됩니다:

- 컴포넌트와 일반 값을 **함께 export** — 예: `export const config = {...}; export function App() {}`
- default export 가 anonymous arrow (`export default () => <div />`) — displayName 없음
- 컴포넌트 안에서 `useState` 의 초기값을 모듈 스코프 변수로 참조하는 경우 (state 손실 가능)

여러 컴포넌트 업데이트는 50ms debounce 로 한 번의 React refresh 사이클에 배칭됩니다.

### 파일 변경 감지 — watcher 동작

| OS | 메커니즘 |
|---|---|
| macOS | kqueue |
| Linux | inotify |
| Windows | ReadDirectoryChangesW |

대부분 환경에서 OS 이벤트가 즉시 반영됩니다. 다음 환경에서는 OS 이벤트가 불안정해 변경이 누락될 수 있습니다.

- Docker volume mount (호스트 → 컨테이너)
- NFS / SMB 같은 네트워크 파일시스템
- Windows WSL1 (WSL2 는 OK)

현재 ZNTC 에는 polling fallback flag 가 없습니다. 위 환경에서 변경이 반영되지 않으면 브라우저 새로고침으로 강제 갱신하세요. polling fallback 은 추후 추가 예정.

### 디버깅 — 업데이트가 안 들어올 때

| 증상 | 의심 |
|---|---|
| 파일 저장해도 클라이언트 갱신 없음 | watcher (위 polling fallback 검토) 또는 hot boundary 누락 (full reload 안 함) |
| Full reload 가 자꾸 일어남 | mixed export, 또는 module dependency chain 의 어떤 모듈도 `accept` 안 함 |
| Component state 가 매번 초기화됨 | React Fast Refresh boundary 가 깨졌음 — anonymous default export 또는 mixed export 확인 |
| 업데이트 후 두 인스턴스 공존 | `dispose` 누락 — 타이머/리스너 정리 필요 |

`/sse/events` 를 구독하면 watcher 가 변경을 감지했는지 (`watch_change` 이벤트), 빌드가 성공했는지 (`bundle_build_done`) 직접 확인할 수 있습니다.

## SSE 이벤트 스트림

### `GET /sse/events`

응답: `Content-Type: text/event-stream`, 연결 유지(keep-alive).

각 이벤트는 표준 SSE 형식:
```
event: <type>
data: <json>

```

### 이벤트 타입

| Type | When | Payload |
|---|---|---|
| `server_ready` | 서버 시작 | `{type, host, port}` |
| `watch_change` | 파일 변경 감지 | `{type, file}` |
| `bundle_build_started` | 빌드 시작 | `{type, id}` |
| `bundle_build_done` | 빌드 성공 | `{type, id, totalModules, duration}` |
| `bundle_build_failed` | 빌드 실패 | `{type, id}` |
| `cache_reset` | 캐시 초기화 (수동/MCP) | `{type}` |

### 사용 예 (브라우저)

```ts
const es = new EventSource("http://localhost:12300/sse/events");
es.addEventListener("bundle_build_done", (e) => {
  const { duration, totalModules } = JSON.parse(e.data);
  console.log(`Built ${totalModules} modules in ${duration}ms`);
});
```

### 사용 예 (Node)

```ts
const res = await fetch("http://localhost:12300/sse/events");
const reader = res.body!.getReader();
const decoder = new TextDecoder();
while (true) {
  const { value, done } = await reader.read();
  if (done) break;
  process.stdout.write(decoder.decode(value));
}
```

## Control API

### `ALL /reset-cache`

빌드 캐시 전체 무효화 요청. 다음 빌드는 초기 빌드와 동일 (모든 모듈 재파싱/재변환).

GET, POST 모두 허용.

응답:
```json
{"ok":true,"action":"reset_cache"}
```

캐시가 실제로 리셋되면 SSE에 `cache_reset` 이벤트가 발행됩니다.

## MCP (Model Context Protocol)

LLM 에이전트(Claude Code 등)가 표준 MCP 프로토콜로 dev 번들러와 직접 상호작용. **JSON-RPC 2.0 over HTTP**.

### 등록 (`.mcp.json`)

```json
{
  "mcpServers": {
    "zntc": {
      "type": "http",
      "url": "http://localhost:12300/mcp"
    }
  }
}
```

dev 서버를 먼저 띄운 뒤 MCP 클라이언트(Claude Code 등) 시작.

### 지원 메서드

| Method | 설명 |
|---|---|
| `initialize` | 프로토콜 핸드셰이크 (버전 2024-11-05) |
| `tools/list` | 도구 목록 + JSON Schema 반환 |
| `tools/call` | 도구 실행 |
| `notifications/initialized` | 클라이언트 준비 완료 통지 |

### 도구

#### `reset_cache`

빌드 캐시를 무효화. Control API `/reset-cache`와 동일 효과.

```json
{
  "jsonrpc": "2.0", "id": 1,
  "method": "tools/call",
  "params": { "name": "reset_cache", "arguments": {} }
}
```

#### `get_build_events`

지정된 시간(ms) 동안 수집된 빌드 이벤트를 JSON 배열로 반환.

| 인자 | 타입 | 기본 | 범위 |
|---|---|---|---|
| `duration` | number | 10000 | 1000~60000 (ms) |

```json
{
  "jsonrpc": "2.0", "id": 2,
  "method": "tools/call",
  "params": {
    "name": "get_build_events",
    "arguments": { "duration": 5000 }
  }
}
```

응답 (`content[0].text`는 JSON 문자열):
```json
[
  {"seq":42,"type":"watch_change","data":{"type":"watch_change","file":"src/App.tsx"}},
  {"seq":43,"type":"bundle_build_started","data":{"type":"bundle_build_started","id":"43"}},
  {"seq":44,"type":"bundle_build_done","data":{"type":"bundle_build_done","id":"43","totalModules":42,"duration":123.45}}
]
```

### LLM 워크플로우 예

```
1. get_build_events(2000)으로 현재 빌드 상태 캡처
2. (LLM이 코드 수정)
3. get_build_events(10000) → bundle_build_done 또는 bundle_build_failed 대기
4. failed면 에러 메시지 읽고 수정 → 2번으로
5. 필요 시 reset_cache로 캐시 초기화
```

## 에러 코드 (MCP)

| Code | Meaning |
|---|---|
| `-32600` | Invalid Request (POST 아님 / body 64KB 초과 등) |
| `-32601` | Method not found |
| `-32602` | Unknown tool |
| `-32700` | Parse error (JSON 오류) |

## 제약

- **Body 크기**: MCP 요청 body는 최대 64KB. 초과 시 HTTP 413.
- **HTTP method**: `/mcp`는 POST만. GET 등은 405.
- **이벤트 버퍼**: `get_build_events`가 참조하는 ring buffer는 최근 256개. 그 이상은 덮어쓰임.
- **SSE 동시 연결**: 64개. 초과 시 거부.

## Proxy — `--proxy`

백엔드 API 호출을 dev server 가 가로채서 다른 origin 으로 포워딩합니다. CLI 플래그로 지정.

```bash
zntc dev . --proxy /api=http://localhost:8080
# 여러 개 — 플래그 반복
zntc dev . --proxy /api=http://localhost:8080 --proxy /ws=http://localhost:9000
```

요청 path 가 prefix 로 시작하면 prefix 를 떼고 target 뒤에 붙여 재요청합니다.

| 요청 | 포워딩 |
|---|---|
| `GET /api/users` (`--proxy /api=http://localhost:8080`) | `GET http://localhost:8080/users` |
| `GET /api/users?page=2` | `GET http://localhost:8080/users?page=2` |

### 한계

현재 proxy 는 *prefix → target* 단순 매핑만 지원합니다. 다음 시나리오는 미지원이므로 별도 reverse proxy (nginx / Caddy / Node `http-proxy` 모듈을 별도 프로세스로 띄우는 방식) 를 앞단에 두는 것을 권장합니다.

- **요청 method / header / body**: Bun 런타임에서는 method / header / body 가 모두 target 으로 전달되지 않아 모든 요청이 사실상 `GET` 으로 다운그레이드됩니다. Node 런타임에서는 method 와 header 는 전달되지만 body 는 전달되지 않습니다. 어느 쪽이든 mutation API (POST / PUT / PATCH / DELETE) 를 proxy 통해 호출하면 의도대로 동작하지 않습니다.
- **regex / 함수형 path 재작성**: prefix strip 만 가능. `^/api/v1/(.*) → /v2/$1` 같은 변환은 미지원.
- **WebSocket upgrade (`ws://`)**: HTTP upgrade 요청은 가로채지 않습니다. 별도 ws target 필요 시 reverse proxy 필수.
- **HTTPS target 의 self-signed cert 검증 우회**: `secure: false` 등 옵션 없음. 개발용 self-signed target 은 일반적으로 검증 실패.
- **Host header / Origin 변경**: target 에 원본 Host 가 그대로 전달. virtual-host 기반 백엔드와 호환 안 될 수 있음.
- **per-request bypass / 커스텀 middleware 훅**: 특정 요청만 proxy 우회하거나 응답을 가공하는 훅 없음.

> 위 옵션들은 향후 정식 지원 예정입니다. 그 전까지는 외부 reverse proxy 사용을 권장합니다.

## `server` config (zntc.config)

CLI `--port` / `--host` / `--open` 외에 config 파일에서도 같은 항목을 지정할 수 있습니다 (Vite `server` 호환). CLI flag 가 항상 우선.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  server: {
    port: 12300,
    host: "0.0.0.0",      // boolean true 도 0.0.0.0 의미 (Vite 동등)
    strictPort: true,     // 점유 시 다음 포트 시도 안 하고 종료
    open: true,           // 시작 후 브라우저 자동 열기
  },
});
```

| 필드 | 타입 | 기본 | 설명 |
|---|---|---|---|
| `port` | `number` | `12300` | listen 포트. CLI `--port` 가 override. |
| `host` | `string \| boolean` | `"127.0.0.1"` | `true` = `0.0.0.0` (Vite 호환). CLI `--host` 가 override. |
| `strictPort` | `boolean` | `false` | `true` 면 포트 점유 시 다음 포트로 fallback 하지 않고 종료. |
| `open` | `boolean` | `false` | 시작 후 served URL 을 브라우저에서 자동 열기. CLI `--open` 가 override. |

## Lazy sourcemap — `emitDiskSourcemap` + `WatchHandle`

`@zntc/core` 의 `watch()` 핸들로 dev server 를 직접 호스팅할 때 — `.map` 디스크 쓰기 비용을 HMR latency 밖으로 빼냅니다.

```ts
import { watch } from "@zntc/core";

const handle = watch({
  entryPoints: ["src/index.tsx"],
  outfile: "dist/bundle.js",
  bundle: true,
  sourcemap: true,
  emitDiskSourcemap: false,   // 디스크 .map 안 쓰고 메모리 보관
  onRebuild(event) { /* ... */ },
});

// dev server 가 /bundle.js.map 요청 시 lazy 생성
app.get("/bundle.js.map", (_req, res) => {
  const json = handle.getBundleSourceMap();
  if (!json) return res.sendStatus(404);
  res.type("application/json").send(json);
});

// HMR 단위 모듈 sourcemap (Metro `_processSourceMapRequest` 패턴)
app.get("/hmr-map/:moduleId", (req, res) => {
  const json = handle.getHmrSourceMap(req.params.moduleId);
  if (!json) return res.sendStatus(404);
  res.type("application/json").send(json);
});
```

- `emitDiskSourcemap: true` (기본): `output_filename + ".map"` 경로에 `.map` 자동 저장.
- `emitDiskSourcemap: false`: 디스크 I/O 생략 — 위 lazy 엔드포인트 모델 사용 시.
- `getBundleSourceMap()` / `getHmrSourceMap()` 는 sourcemap 비활성, 초기 빌드 전, `stop()` 이후엔 `null` 반환.
- `getHmrSourceMap(moduleId)` 는 `moduleId` 가 마지막 rebuild 에 포함되지 않았으면 `null`.

## `onReady` / `onRebuild` 이벤트

`watch()` 콜백으로 받는 rich event payload — dev server 통합 시 phase breakdown 과 HMR delta 직접 소비.

```ts
watch({
  // ...
  onReady(event) {
    // event: WatchReadyEvent
    console.log(`ready: ${event.files} files / ${event.bytes} bytes`);
  },
  onRebuild(event) {
    // event: WatchRebuildEvent
    if (!event.success) {
      console.error("rebuild failed:", event.error);
      return;
    }
    for (const file of event.changed ?? []) console.log("changed:", file);
    for (const update of event.updates ?? []) {
      // update.id, update.code, update.map (per-module sourcemap V3 JSON)
      hmrSocket.send({ id: update.id, code: update.code, map: update.map });
    }
    const p = event.phaseDurations;
    if (p) console.log(`total=${p.total}ms graph=${p.graph}ms emit=${p.emit}ms`);
  },
});
```

`WatchRebuildEvent` 핵심 필드:

| 필드 | 타입 | 설명 |
|---|---|---|
| `success` | `boolean` | rebuild 성공 여부. |
| `error` | `string?` | 실패 시 fatal diagnostic message. |
| `changed` | `string[]?` | 이번 rebuild 를 트리거한 파일 절대 경로. **`changedFiles` 아님 — `changed`.** |
| `graphChanged` | `boolean?` | 모듈 그래프 토폴로지 변화 여부. |
| `updates` | `Array<{ id, code, map? }>?` | HMR delta. `map` 은 모듈별 standalone sourcemap V3 JSON (sourcemap 활성 시). |
| `bytes` | `number?` | 출력 바이트 수. |
| `reparsedModules` | `number?` | 캐시 미스로 재파싱된 모듈 수 (전체 빌드에선 미노출). |
| `phaseDurations` | object | 단계별 ms — 아래 표. |

`phaseDurations` 의 기본 phase (항상 측정):

| 필드 | 의미 |
|---|---|
| `detect` | 변경 감지 (mtime 스캔). |
| `graph` | resolve + parse + semantic + finalize. |
| `link` | scope hoisting + linker. |
| `shake` | tree shaking. |
| `emit` | transform + codegen + emit. |
| `delta` | HMR delta 추출. |
| `total` | `detect` ~ `delta` 합산. |

Sub-phase (`profile: ["..."]` / `ZNTC_PROFILE=...` 활성 시에만 채워짐, 비활성 시 0):

`scan` / `parse` / `resolve` / `semantic` / `transform` / `codegen` / `metadata` / `graphBuild` / `graphWorker` / `graphDiscover` / `graphFinalize` / `emitPolyfill` / `emitRefresh` / `emitOutput` / `emitMetafile` / `emitCss` / `emitPrelude` / `emitModulePass` / `emitConcat` / `emitSourcemapFinalize`.

## 관련

- [Server-Sent Events (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [rollipop SSE/MCP](https://rollipop.dev/docs/features/sse) — 호환 surface
