---
title: 트리쉐이킹
description: ZNTC 번들러의 트리쉐이킹 전략 — 모듈 수준 fixpoint 분석부터 statement 수준 도달성 BFS, type-only import elision 까지.
---

ZNTC 번들러는 두 단계 트리쉐이킹을 수행합니다. **모듈 수준** 은 어떤 모듈/export 가 진입점에서 도달 가능한지를 fixpoint 로 좁히고, **statement 수준** 은 모듈 안에서 어떤 top-level 문이 살아남는지를 symbol graph BFS 로 결정합니다.

목표는 Rollup/Rolldown 수준 정확도 + esbuild 수준 속도. 인덱스 기반 AST 와 semantic analyzer 의 스코프/심볼 정보를 재활용해 두 마리 토끼를 잡습니다.

## 한눈에 보기

```bash
# 트리쉐이킹은 번들 모드의 기본 동작 — 따로 켤 필요 없음
zntc --bundle src/index.ts -o dist/bundle.js

# package.json sideEffects 자동 적용
# @__PURE__ / @__NO_SIDE_EFFECTS__ 주석 자동 인식
# 사용자 pure hint 추가
zntc --bundle src/index.ts -o dist/bundle.js --pure=myUtil --pure=invariant
```

## 1단계 — 모듈 수준

진입점부터 fixpoint 반복으로 도달 가능한 모듈/export 를 좁힙니다.

### Used export 추적

각 모듈의 `(module_idx, export_name)` 키를 `used_exports` 맵에 마킹합니다.

- **진입점 + dynamic import target**: 정적 분석 밖이라 모든 export 사용 (`*` sentinel) 으로 보수적 마킹
- **포함된 모듈의 import specifier 스캔**: 어떤 export 를 어떤 이름으로 가져왔는지 등록
- **Re-export chain cascade**: `export * from './a'`, `export { X } from './a'` 를 따라 상위 모듈 사용이 하위에 전파

```ts
// a.ts
export const used = 1;
export const unused = 2;  // 도달 안 됨 → 제거 후보

// entry.ts
import { used } from './a';
console.log(used);
```

### Side-effect 판정

모듈을 통째로 제거할 수 있는지는 다음 조건을 모두 만족해야 합니다.

- `used_exports` 에 등록된 항목 없음
- 진입점이 아님
- 평가 자체에 side-effect 가 없음 (top-level 문이 모두 순수)

### `package.json sideEffects`

```json
{
  "name": "my-lib",
  "sideEffects": false
}
```

라이브러리가 `sideEffects: false` 를 선언하면 ZNTC 는 미사용 import 를 자유롭게 제거합니다. 글롭 패턴도 지원:

```json
{
  "sideEffects": ["*.css", "./src/polyfills.ts"]
}
```

:::caution
`sideEffects` 정책은 **단조** 적용됩니다 — 한 번 `false` 가 되면 같은 파일에 대해 다시 `true` 로 돌릴 수 없습니다. 이는 의도적인 설계로, 라이브러리 작성자가 의도를 명확히 표현하도록 강제합니다.
:::

### 자동 순수 판별

`package.json` 에 `sideEffects` 가 없어도 ZNTC 는 모듈의 top-level 이 모두 순수하면 자동으로 `side_effects = false` 를 추론합니다 (entry 가 아닌 모듈에 한해).

## 2단계 — Statement 수준

모듈이 살아남기로 결정되면, 그 안에서 어떤 top-level 문이 실제로 도달 가능한지를 다시 판정합니다. semantic analyzer 가 만든 symbol_id 매핑을 재활용해 statement 단위 symbol graph 를 구축합니다.

### StmtInfo

각 top-level 문에 대해 **선언하는 심볼** 과 **참조하는 심볼** 을 기록:

```zig
pub const StmtInfo = struct {
    node_idx: u32,
    has_side_effects: bool,
    declared_symbols: []const u32,    // 이 stmt 가 선언하는 심볼
    referenced_symbols: []const u32,  // 참조 (선언분 제외)
};
```

이 정보로 `symbol_to_stmt`, `sym_to_referencing_stmts`, `sym_to_writer_stmts` 같은 역인덱스를 만듭니다.

### 도달성 BFS

```
Seed:
  - side-effectful statement
  - used export 의 선언 statement
  - 비선언 writer statement (var _a; ... _a = AST; 같은 TS 패턴)

전파:
  - referenced_symbols → symbol_to_stmt 로 의존 stmt enqueue
  - 같은 모듈 안에서 도달 가능한 statement 만 살아남음
```

### 예시

```ts
// utils.ts
export function used() { return 1; }
export function unused() { return 2; }

const helper = () => 'helper';   // unused 만 참조 → 도달 안 됨
function unused() { return helper(); }
```

번들 결과에서 `unused`, `helper` 둘 다 제거됩니다 — `used` 의 도달성 그래프에서 분리되어 있기 때문.

## 순수성 분석

`@__PURE__` / `@__NO_SIDE_EFFECTS__` 주석과 builtin 화이트리스트를 결합해 표현식 수준 순수성을 판정합니다 (재귀 깊이 128 제한).

### `@__PURE__` 주석

```ts
const x = /* @__PURE__ */ createComponent();  // 미사용이면 제거
```

렉서 단계에서 직후 call/new 노드의 `is_pure` 플래그를 설정하고, 트리쉐이커가 이를 무시합니다.

### `@__NO_SIDE_EFFECTS__` 주석

```ts
// @__NO_SIDE_EFFECTS__
function compute(x) { return x * 2; }

const a = compute(1);  // a 가 미사용이면 호출 자체가 제거됨
const b = compute(2);
```

함수 선언 자체에 마크하면 모든 호출이 자동으로 pure 처리됩니다.

### Builtin pure constructor

다음은 unresolved global (사용자 재정의 없음) 컨텍스트에서 자동 pure:

| 생성자 | 조건 |
|---|---|
| `Set`, `Map`, `WeakSet`, `WeakMap` | `new` 전용, 무인자 / `null` / `undefined` / ArrayExpression 만 (iterator protocol side-effect 회피) |
| `Array`, `Date`, `String` | 인자가 재귀적으로 pure |
| `Error` 계열 | message 인자가 Symbol 이 아님이 정적으로 증명되어야 함 |
| `Object.freeze`, `Object.assign` | fresh literal 제약 (special case) |

### 사용자 pure hint

CLI 또는 빌드 옵션으로 함수를 pure 로 표시:

```bash
zntc --bundle entry.ts --pure=invariant --pure=warning
```

```ts
import { invariant } from 'tiny-invariant';

invariant(condition, "msg");  // condition 이 컴파일타임 truthy 면 호출 제거 가능
```

## Type-only import elision

TypeScript 의 `import type` 과 inline `type` modifier 는 런타임 바인딩을 만들지 않습니다.

```ts
import type { User } from './types';        // 완전 제거
import { type Config, helper } from './x';  // type Config 만 제거, helper 는 use 여부 따라
```

ZNTC 는 두 경로에서 elision 을 수행:

- **번들러 경로**: `binding_scanner.zig` 가 `SPEC_FLAG_TYPE_ONLY` 플래그를 체크해 BindingRecord 생성 자체를 스킵
- **트랜스파일 fast-path** (BindingLite): full semantic 없이 named import 의 value-use 를 추적해 미사용 import 만 안전하게 제거

:::note
`default` / `namespace` import 는 JSX pragma, CSS-in-JS implicit-use 위험으로 elision 미지원. 안전하게 보존됩니다.
:::

### `verbatimModuleSyntax`

`tsconfig.json` 에 `"verbatimModuleSyntax": true` 가 설정되어 있으면 ZNTC 는 `import type` 만 제거하고 일반 import 는 그대로 둡니다 (TypeScript 표준 동작과 일치).

## 한계

:::caution[CJS wrap Asset 모듈]
`require()` 로 wrap 된 CJS 모듈은 `require_X()` 호출이 side-effect 로 간주되어 미사용이라도 트리쉐이킹되지 않습니다. esbuild 의 `NoSideEffects_PureData` 마킹은 ZNTC 에 아직 적용되지 않았습니다.

JSON 모듈은 ESM AST 변환으로 우회 — named export 단위 트리쉐이킹 가능.
:::

:::caution[Namespace barrel]
`import * as X; export { X }` 같은 namespace re-export 는 symbol 기반 추적이 어려워 local export 로 분류됩니다. lazyBarrel 정밀화는 진행 중.
:::

:::caution[Getter / Proxy / Global]
런타임 시점 side-effect (getter, Proxy, global 변수 변경) 를 정적으로 분석하는 deep-DCE 단계는 미구현 (후순위).
:::

## 더 읽을거리

- 내부 설계 문서: [`docs/BUNDLER.md` § Tree-shaking 구현](https://github.com/ohah/zntc/blob/main/docs/BUNDLER.md#tree-shaking-%EA%B5%AC%ED%98%84-%EB%AA%A8%EB%93%88-%EC%88%98%EC%A4%80--statement-%EC%88%98%EC%A4%80)
- 아키텍처 개요: [`docs/ARCHITECTURE.md` § Tree-shaking Design](https://github.com/ohah/zntc/blob/main/docs/ARCHITECTURE.md)
