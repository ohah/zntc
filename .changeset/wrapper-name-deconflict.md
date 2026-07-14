---
"@zntc/core": patch
---

생성된 **래퍼 심볼**이 사용자 top-level 심볼과 deconflict 되지 않아 **파싱 불가** 산출물이 나오던 것 수정 (#4530).

```js
// entry.js
function require_legacy(){ return "USER"; }   // ← 사용자 심볼
import d from "./legacy.cjs";
```

방출:

```js
var require_legacy = __commonJS({ ... });     // ← emitter 가 찍은 래퍼
function require_legacy(){ return "USER"; }   // ← 사용자 코드
// → SyntaxError: Identifier 'require_legacy' has already been declared
```

**단일 번들에서도** 재현된다 — 번들 스코프에 모든 모듈의 top-level 이 호이스팅되기 때문이다.

근본 원인: 래퍼 심볼(`extendSymbol`)은 `scope_id = .none` 으로 만들어져 **`scope_maps` 에 들어가지 않는다** → linker 의 rename 풀(`name_to_owners`)이 **못 본다**. 그래서 사용자 심볼과 이름이 겹쳐도 아무도 못 막았다. CJS 의 `require_X` 뿐 아니라 ESM-wrap 의 `init_X` / `exports_X` 도 같았다.

처방: 래퍼 이름을 linker 의 **`reserved_globals` 에 예약**한다 → 충돌하는 **사용자 심볼**이 리네임된다.

⚠️ **래퍼 쪽 이름을 바꾸는 방식으로 풀면 안 된다.** graph finalize 의 `used_names` 와 linker 의 `$N` 할당기는 **서로를 못 보는 두 개의 독립 풀**이라, 한 단계 위에서 다시 충돌한다(양쪽이 각각 `require_legacy$2` 를 발급). 예약해서 사용자 심볼을 리네임시키면 할당기가 **하나로 모인다**. 부수 효과로:

- 래퍼가 자연스러운 이름을 유지 → size 회귀 0 (effect/zod/three `--minify` byte-identical).
- `computeRenames` 는 **매 빌드 실행**되므로 **watch/incremental 재빌드**도 커버된다 (래퍼 이름은 한 번 정해지면 캐시되므로, finalize 쪽 seed 는 warm 에서 아예 발동하지 않았다).
