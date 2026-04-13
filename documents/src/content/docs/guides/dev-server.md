---
title: Dev Server
description: ZTS dev server의 SSE 이벤트 스트림, Control API, MCP 서버
---

`zts --serve --bundle <entry>`로 시작하는 dev 서버는 일반 HTTP/HMR 외에 **외부 자동화/관측 도구를 위한 3가지 인터페이스**를 제공한다.

| 엔드포인트 | 용도 | 호환 |
|---|---|---|
| `/sse/events` | Server-Sent Events 스트림 — 실시간 빌드/watch 이벤트 | rollipop |
| `/reset-cache` | Control API — 외부에서 캐시 무효화 | rollipop |
| `/mcp` | MCP (Model Context Protocol) JSON-RPC | Claude Code, MCP 클라이언트 |

## 빠른 시작

```bash
zts --serve --bundle src/index.tsx --port 12300
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

캐시가 실제로 리셋되면 SSE에 `cache_reset` 이벤트가 발행된다.

## MCP (Model Context Protocol)

LLM 에이전트(Claude Code 등)가 표준 MCP 프로토콜로 dev 번들러와 직접 상호작용. **JSON-RPC 2.0 over HTTP**.

### 등록 (`.mcp.json`)

```json
{
  "mcpServers": {
    "zts": {
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

## 관련

- [Server-Sent Events (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [rollipop SSE/MCP](https://rollipop.dev/docs/features/sse) — 호환 surface
