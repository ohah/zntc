# RSC Directive Fixtures

`"use client"` / `"use server"` / 기타 directive prologue 보존 검증용 입력.

## 출처
- `client-entry-mixed.js`, `client-entry-with-imports.js` — Next.js `next-custom-transforms/tests/fixture/react-server-components/{client,server}-graph/client-entry/input.js`
- `server-action-inline.tsx` — Next.js `server-actions/server-graph/1/input.js`
- `module-level-directive.js` — Rollup `test/function/samples/module-level-directive/main.js`

## 검증 규약 (ZTS)
1. **단일 파일 트랜스파일**: 첫 번째 directive prologue (예: `"use client"`)가 출력 첫 문장에 보존
2. **`--bundle --preserve-modules`**: 각 모듈 출력 파일에서 디렉티브가 import 보다 위, 파일 최상단 (banner 주석 직후 허용)
3. **번들 IIFE**: 디렉티브는 의미 없으므로 유실 허용 (Rollup 동작과 동일)

RSC 프로토콜 자체 (클라이언트 레퍼런스 주입, 서버 액션 RPC 변환)는 ZTS 범위 밖.
