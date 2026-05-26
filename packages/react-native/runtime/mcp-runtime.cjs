'use strict';

// MCP (Model Context Protocol) RN runtime — dev 빌드 한정 preamble.
//
// zntc transform pass 가 entry preamble (`runBeforeMain`) 로 inject. 앱 시작 시
// 즉시 실행되어 global registry 만 등록 (silent + idempotent). 실제 MCP server
// 연결 / Fiber tree 직렬화 / 네트워크 캡처 등 본격 로직은 후속 PR-E 에서 흡수.
//
// 이 placeholder 의 역할:
//   1. dev 빌드의 entry preamble inject 메커니즘 검증 (`buildRnBundleOptions`)
//   2. `globalThis.__ZNTC_MCP_RUNTIME__` extension point 예약 — 후속 PR-E 가 같은
//      slot 에 실제 runtime API 등록
//   3. 다중 import 안전 (idempotent) — pnpm peer 등으로 module 이 중복 import 돼도
//      hooks 등록은 1회만
//
// production 빌드에는 inject 안 됨 (`dev: false`).

(function () {
  var g =
    typeof globalThis !== 'undefined' ? globalThis : typeof global !== 'undefined' ? global : null;
  if (!g) return;
  if (g.__ZNTC_MCP_RUNTIME__) return; // 이미 loaded
  g.__ZNTC_MCP_RUNTIME__ = {
    version: '0.1.0-placeholder',
    loaded: true,
    // 후속 PR-E 에서 채워질 API surface:
    //   takeSnapshot, findElement, inspectState, evalCode, networkMock, ...
  };
})();
