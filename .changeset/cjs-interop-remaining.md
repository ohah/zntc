---
"@zntc/core": patch
---

CJS interop 잔여 결함 3건 수정 (#4510). #4494(크로스-청크 CJS 의 **직접** named/default import)가 못 덮은 표면들로, 셋 다 별개 루트커즈다.

1. **크로스-청크 `import * as ns from './x.cjs'`** — namespace 합성 경로는 #4494 의 크로스-청크 심볼 등록 기계를 타지 않아 소비자 청크에서 `require_X` 썽크가 undefined 였다. 합성 ns 도 provider 청크의 썽크를 크로스-청크 심볼로 등록한다.

2. **비-식별자 멤버명** — `import { 'foo-bar' as x } from './x.cjs'` 가 `require_x()."foo-bar"` 로 방출돼 **문법 오류**였다. splitting 없이도 실패하는 preamble-writer 버그로, bracket 표기(`["foo-bar"]`)로 수정.

3. **동적 import 의 `.default`** — `(await import('./x.cjs')).default` 가 undefined 였다. 동적 경로가 `__toESM` 의 default 합성을 거치지 않았다.

전부 빌드 exit 0 · 파싱 통과 · **실행만** 실패하는 계열이라 실행 스모크로 가드했다.

추가(코드리뷰): 2번(비-식별자 멤버명) 수정으로 quoted 이름이 CJS interop 배선을 타게 되면서 **새 구멍**이 드러났다.

- `import { "default" as d } from './x.cjs'` — ES2022 arbitrary module namespace name. binding_scanner 는 이름을 **따옴표째** 저장하는데(`"\"default\""`) default 판정 3곳이 bare `"default"` 와만 비교해서, 이 형태가 default-interop 을 통째로 비껴가 `require_x()["default"]` = **undefined** 가 됐다. 수정 전에는 `require_x()."default"` 라는 **문법 오류**(loud)였는데 2번 수정이 그걸 valid-but-wrong 으로 바꿨다. 판정을 `preamble_writer.isDefaultExportName` 단일 소스로 묶었다 (node/esbuild 는 `import d from` 과 동일 취급).
- cross-chunk 공개명 sanitize 가 **CJS owner 분기에만** 걸려 있었다. ESM 재-export 로 로컬명이 없으면 quoted export 명이 그대로 전역 이름이 되어 `var "a-b"` — 파싱 불가. 비-CJS 분기에도 적용했다.
- 새 `preamble_writer_test.zig` 가 **어디서도 import 되지 않아** Zig 테스트 discovery 에 안 잡혔다(회귀 가드 5건이 CI 에서 아예 안 돌고 있었다). `bundler/mod.zig` 에 등록.
