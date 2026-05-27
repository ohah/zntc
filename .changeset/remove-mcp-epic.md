---
"@zntc/core": minor
"@zntc/react-native": minor
"@zntc/server": minor
---

MCP (Model Context Protocol) epic 전체 롤백 — fiber 기반 RN MCP 도구 + `/mcp` HTTP endpoint + `zntc mcp` stdio 서브명령 + `mcpStdioServe` NAPI export + `/__mcp-app` WebSocket 채널 제거. NAPI HTTPS dev server (`startDevServer` / `stopDevServer` / `tlsSelfCheck` / `getDevServerPort`) 는 유지.

### Breaking

- `@zntc/core` 의 `mcpStdioServe()` 함수와 `McpStdioOptions` 타입 export 제거. `zntc mcp` CLI 서브명령도 제거 — 더 이상 stdio MCP transport 를 제공하지 않습니다.
- Dev server 의 `/mcp` HTTP endpoint 제거 — `tools/list` / `tools/call` / `initialize` JSON-RPC 가 더 이상 응답하지 않습니다.
- `@zntc/server` 의 `APP_DEV_MCP_APP_WS_PATH` 상수 export 제거.
- `@zntc/react-native` preset 의 `extra.mcp` 옵션, `runtime/mcp-runtime.cjs`, `runtime/webview-wrapper.cjs` 모두 제거. RN 앱에 자동 inject 되던 MCP runtime preamble 이 더 이상 동작하지 않습니다.

### 유지

Dev server 의 `/sse/events` (SSE 빌드 이벤트) 와 `/reset-cache` (Control API) 는 그대로 동작합니다 — MCP 와 별개의 인프라.
