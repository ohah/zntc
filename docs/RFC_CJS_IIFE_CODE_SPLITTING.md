# RFC: CJS/IIFE Code Splitting (P3)

> 상태: **Draft (설계 고정 — 구현은 후속 다회 PR)**
> 범위: 비-ESM(`format=cjs`/`iife`) 출력에서의 code splitting / preserve-modules
> 백로그: 일반 청크 #3321 의 P3. **MF RFC `docs/RFC_MODULE_FEDERATION.md` 와 런타임 레지스트리를 공유** — 본 문서는 그 통합 지점을 명시한다.
> 결정 모드: P0-3(C/JSI 로더) RFC 와 동일하게 *설계를 먼저 고정*. XL 이라 단일 PR 로 구현하지 않는다.

---

## 1. 배경 & 현재 제약

`src/bundler/emitter/chunks.zig:65-73`:

```zig
if (options.format != .esm) {
    return if (options.preserve_modules)
        error.PreserveModulesRequiresESM
    else
        error.CodeSplittingRequiresESM;
}
```

→ **code splitting / preserve-modules 는 ESM 출력에서만 동작**. 이유: 청크 간 동적 로딩을 현재 **네이티브 `import()` 재작성**(`rewriteDynamicImports`, `chunks.zig:961-1071`)으로만 구현하기 때문. CJS/IIFE 에는 네이티브 `import()` 가 없고 `Promise.resolve().then(()=>require(x))` 는 specifier 가 정적 string 이어야 해 동적 청크 로딩이 불가.

비-ESM **단일 번들**은 정상(스코프 호이스팅 + `__commonJS`/IIFE wrapper, `runtime_helpers.zig`). 없는 것은 **청크 경계를 넘는 런타임 모듈 해석**이다.

참고: esbuild 도 **IIFE code splitting 미지원**(의도적, `docs/design/CODE_SPLITTING.md:46,227`). webpack 은 `__webpack_require__` 런타임 로더로 지원. Rollup 은 사실상 ESM 권장.

---

## 2. 기술 격차 (P3 가 신설해야 하는 것)

| # | 격차 | 현황 |
|---|---|---|
| G1 | **런타임 require 레지스트리** (모듈 id → factory, 캐시) | 없음 (`runtime_helpers.zig` 에 `__commonJS/__toESM/__esm` 만, registry 없음) |
| G2 | **청크 동적 로더** (청크 fetch/주입 → 레지스트리 등록 → require) | 없음 (ESM 은 native import() 재작성으로 회피) |
| G3 | **안정 모듈 ID** | ESM 청크 내부는 스코프 호이스팅으로 ID 소거. preserve-modules(1:1 파일) 또는 cross-chunk require 에는 결정적 ID 필요 |
| G4 | **청크 출력 포맷 표준화** | ESM 청크는 `export`/`import`. CJS/IIFE 청크는 레지스트리에 자기 모듈을 등록하는 wrapper 필요 |

핵심: **G1(런타임 레지스트리)** 이 본질. ESM 은 런타임이 브라우저(native import())라 레지스트리가 불필요했고, 비-ESM 은 그 런타임을 우리가 생성해야 한다.

---

## 3. MF RFC 와의 겹침 (중복 구현 방지 — 본 RFC 의 핵심)

`docs/RFC_MODULE_FEDERATION.md` §6.1:

> `module registry / container 런타임`: ❌ `runtime_helpers.zig` 에 `__commonJS/__toESM/__esm` 만, 청크 로더/registry 없음 → **신규**: MF2 호환 container/registry 헬퍼

**P3 의 G1(런타임 require 레지스트리)·G2(청크 로더)·G3(안정 모듈 ID)는 MF RFC 가 "신규 필요"로 식별한 바로 그 인프라와 동일하다.** 따로 만들면 한쪽이 버려진다.

| 인프라 | P3 요구 | MF 요구 | 통합 방침 |
|---|---|---|---|
| 안정 모듈 ID | cross-chunk require / preserve-modules 경계 | 연합 경계 모듈 ID (MF P1, RFC §4.1) | **공유** — 동일한 "경계 안정 ID" 메커니즘. 내부 청크는 양쪽 다 호이스팅 유지 |
| 런타임 모듈 레지스트리 | CJS/IIFE require 캐시 | MF2 container/shared scope (RFC §4.1) | **계층 분리·공유**: 하위 = 최소 require 레지스트리(P3), 상위 = MF container 가 그 레지스트리 위에 shared scope 얹음 |
| 청크 로더 | 비-ESM 청크 fetch/주입 | RN: ScriptManager(별도) / 웹: ESM or script | **인터페이스 공유**: `__zntc_load_chunk(id)` 추상화. P3 는 CJS/IIFE 구현, MF/RN 은 다른 구현 주입 |

**P3 고유(MF 무관)**: CJS/IIFE wrapper 포맷, preserve-modules 의 파일별 모듈 ID, Node `module.exports` 상호운용.

**결론**: P3 의 레지스트리/모듈ID 는 **MF RFC §4.1 의 "연합 경계 안정 모듈 ID + 레지스트리"와 같은 하위 인프라로 설계**한다. P3-Alpha 가 그 하위 인프라(최소 require 레지스트리)를 먼저 만들고, MF P1 의 container 가 그 위에 얹히도록 인터페이스를 맞춘다.

---

## 4. 설계

### 4.1 런타임 require 레지스트리 (G1, MF 와 공유 하위 계층)

번들/엔트리 청크에 1회 주입되는 최소 런타임:

```js
var __zntc_mods = {};                 // id -> factory(exports, module, require)
var __zntc_cache = {};                // id -> { exports }
function __zntc_require(id) {
  var c = __zntc_cache[id]; if (c) return c.exports;
  var m = { exports: {} }; __zntc_cache[id] = m;
  (0, __zntc_mods[id])(m.exports, m, __zntc_require);
  return m.exports;
}
function __zntc_register(map) { for (var k in map) __zntc_mods[k] = map[k]; }
```

- 내부 청크 모듈은 **여전히 스코프 호이스팅** — 레지스트리는 *청크 경계*에서만 사용(over-bundling/크기 회귀 방지, MF RFC 의 "내부 호이스팅 유지, 경계만 레지스트리" 원칙과 동일).
- MF container 는 이 레지스트리 위에 shared scope/버전 협상을 얹는 상위 계층(별도 RFC §4.1).

### 4.2 청크 출력 포맷 (G4)

각 비-ESM 청크는 자기 모듈을 레지스트리에 등록하는 self-registering wrapper:

```js
// chunk-<hash>.js  (cjs/iife 공통, 환경 가드)
(function(g){ g.__zntc_register({ "<id>": function(exports, module, require){ /* hoisted */ } }); })(
  typeof globalThis!=="undefined"?globalThis:this
);
// cjs 환경에선 module.exports 로도 노출(상호운용)
```

cross-chunk static import → `__zntc_require("<id>")` 호출로 재작성(현재 ESM `import {x} from "./c.js"` 재작성 자리, `chunks.zig:222-321` 대응).

### 4.3 청크 동적 로더 (G2)

`import("./page")` (CJS/IIFE 출력) 재작성 →
```js
__zntc_load_chunk("chunk-<hash>.js").then(function(){ return __zntc_require("<entry-id-of-chunk>"); })
```
`__zntc_load_chunk` 는 추상 — 환경별 구현 주입:
- **CJS/Node**: `Promise.resolve().then(()=>require("./chunk-<hash>.js"))` (정적 string OK)
- **IIFE/브라우저**: `<script>` 주입 또는 `import()`(가능 시) — 페이로드는 self-register 라 평가만 하면 등록됨
- **MF/RN**: ScriptManager 등 별도 구현이 같은 인터페이스로 주입(§3 표)

### 4.4 안정 모듈 ID (G3)

- 청크 경계/preserve-modules 모듈에만 결정적 ID 부여(content/relative-path 기반, 빌드 결정성 보장). 내부 호이스팅 모듈은 ID 없음.
- **MF RFC §4.1 "연합 경계 안정 모듈 ID"와 동일 메커니즘** — 한 번 구현해 양쪽이 사용.

---

## 5. 단계 분해

| Phase | 내용 | MF 관계 |
|---|---|---|
| **P3-A** | preserve-modules + CJS 만: 파일=모듈ID(결정적), self-register wrapper, `__zntc_require`. 동적 로더 불필요(전부 빌드타임 known). 최소·저위험 진입 | 레지스트리 하위 계층 = MF P1 의 토대 |
| **P3-B** | CJS/IIFE + code splitting: 동적 청크 + `__zntc_load_chunk` 추상 로더, cross-chunk require 재작성 | 로더 인터페이스 = MF/RN 과 공유 |
| **P3-C** | MF P1 과 레지스트리 통합 — container/shared scope 가 P3 레지스트리 위에 얹히도록 인터페이스 수렴 | **MF RFC §7 P1 과 합류** |

P3-A 를 먼저(작고 안전, esbuild 도 안 하는 영역의 최소 가치), P3-B/C 는 MF P1 과 보조 맞춰 진행.

---

## 6. 디리스크 스파이크

> 스파이크: 손수 작성한 self-register 청크 2개 + 최소 `__zntc_require`/`__zntc_load_chunk`(CJS) 로, cross-chunk require + 동적 청크 로드가 Node(cjs)에서 동작함을 증명. 통과 시 P3-B 진행, 실패 시 설계 재검토.

(P0-3 스파이크 0 패턴과 동일 — 위험한 5% 먼저 증명.)

---

## 7. 미해결 / 결정 필요

- IIFE 동적 로더의 브라우저 청크 fetch 방식(script 주입 vs 조건부 import()) — public_path/CSP 영향.
- preserve-modules CJS 의 Node `__esModule`/interop 경계(default/namespace).
- 모듈 ID 스킴: content-hash vs relative-path(결정성·디버깅·MF 계약 호환 trade-off) — MF RFC §9 의 모듈 ID 미해결과 **공동 결정**.
- P3-A 가치 대비 비용: esbuild 미지원 영역. 수요(누가 CJS/IIFE+splitting 을 원하나) 확인 후 P3-B 착수 여부 게이트.

---

## 8. 권고

P3 는 단일 PR 기능이 아니라 **MF 런타임 레지스트리와 같은 하위 인프라를 공유하는 에픽**이다. 따라서:

1. 본 RFC 로 설계·통합 지점 고정(완료).
2. **P3-A(preserve-modules+CJS, 동적 로더 없는 최소)** 를 작은 PR 시리즈로 먼저.
3. **레지스트리/모듈ID 는 MF RFC §4.1 과 한 설계로** — MF P1 착수 시 P3-C 로 수렴(중복 구현 금지).

`docs/RFC_MODULE_FEDERATION.md` 와 상호 참조. 구현 착수 전 §7 결정·§6 스파이크 선행.

## 부록: 참고 코드

- 제약: `src/bundler/emitter/chunks.zig:65-73`
- 동적 import 재작성: `chunks.zig:961-1071` / cross-chunk import: `chunks.zig:222-321`
- 런타임 헬퍼: `src/bundler/runtime_helpers.zig`, `src/runtime_helper_modules.zig`
- Format enum: `src/bundler/types.zig` (Format), `src/main.zig` --format
- 비교/원칙: `docs/design/CODE_SPLITTING.md:46,227,313,434`
- MF 통합: `docs/RFC_MODULE_FEDERATION.md` §4.1, §6.1, §7
