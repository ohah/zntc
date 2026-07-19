---
"@zntc/core": patch
---

`--preserve-modules --format=cjs` 에서 **default-only 모듈**(default export 만) 을 default import 하면 `TypeError: X is not a function` 로 실패하던 것 수정 (#4580).

```js
// m1.js: export default function foo(){ return "D1"; }
// entry: import a from "./m1.js"; console.log(a());
```

## 근본

default-only 모듈은 `module.exports = X`(default = exports **전체**) 로 방출된다(named 이 섞이면 `exports.default = X` + `__esModule`). 그런데 소비자 import 블록(chunks.zig)은 **항상** `const { default: foo } = require("./m1.js")` 로 `.default` 를 구조분해했다 — `module.exports = foo` 는 `.default` 가 없으니 `foo`=undefined → TypeError. ESM 출력은 Node 네이티브 interop 으로 정상이라 **cjs 전용**.

## 수정

소비자가 dep 이 **default-only**(→ provider 가 `module.exports = X` 방출) 이고 default 단일 import 면, `require()` 결과 **전체**를 바인딩한다: `const foo = require("./m1.js")`. rollup/esbuild 의 런타임 interop 헬퍼(`getDefaultExportFromCjs`/`__toESM`) 대신, preserve-modules 는 provider shape 를 정적으로 알 수 있어 헬퍼 없이 형태를 맞춘다(더 깨끗).

- default-only 판정 `cjsDepDefaultOnly`: dep 청크 모듈에 default 있고 named 없음. `export *`(ESM 스펙상 default 제외, named 확장) 는 **소스로 재귀 flatten**(`moduleHasAnyNamedExport`)해 provider 의 `collectExportsRecursive` 와 판정을 맞춘다 — star 가 named 0 개면 provider 는 `module.exports = X` 이므로 소비자도 전체 바인딩해야 한다. 미해결/external star 는 보수적으로 구조분해.
- `.auto`/`.default_` OutputExports 게이트(`.named` 은 `exports.default` 라 구조분해가 맞음). dep 이 완전 unwrapped(래퍼 경로 아님)일 때만.
- deconflict/전역명/lazy 로컬 처리는 심볼 블록과 동일 경로 재사용(#4576 `mintConsumerLocal`).

## 검증

- 회귀 스위트 `preserve-modules-cjs-default-interop.test.ts` 6종: default-only(전체 바인딩)·default+named(구조분해 유지)·re-export 배럴·mixed 배럴·**동명 default 2개(#4576 deconflict + #4580 interop 협업 → 실행 `12`)**·named-only(무영향).
- #4576 cjs 동명 default 테스트를 emit-only → **런타임 검증**으로 승격(이 fix 로 실제 실행됨).
- preserve-modules 171·cross-chunk/splitting/wrapper 137 통합 + zig 전체 무회귀.

## `/code-review max` 반영

- **[0]** `cjsDepDefaultOnly` 가 `export *` 를 무조건 named 로 봐, provider 가 star flatten 후 named 0 → `module.exports = X` 인데 소비자는 구조분해 → TypeError 잔존(재현). → star 를 재귀 flatten(`moduleHasAnyNamedExport`)해 provider 와 일치.
- **[2]** bind_whole 의 dead `lazy_local_keys`(pm_cjs 라 항상 false) 제거 + 불필요한 `if (preserve_modules)` 가드 제거.
- **[1]** symbol-level·bind_whole 의 로컬 발급+정합 로직을 `deconflictedConsumerLocal` 헬퍼로 통합(정책 발산 방지).

## 한계

- `--minify-identifiers`(따라서 `--minify`)는 별개 선행 mangler 버그(#4579 계열)로 소비자 default import 로컬과 body 참조가 발산해 실패한다 — 이 fix·구조분해/전체바인딩 무관하며 main 도 동일(단일 default 포함 광범위). #4579 에서 처리.
