---
"@zntc/core": patch
---

함수-로컬 `const x` 가 import 참조를 shadow 해 self-TDZ(`const c = c.set(...)`) 나던 것을 **cross-chunk splitting** / **preserve-modules** / **dev-split** 세 토폴로지에서 모두 수정 (#4566, #4563 후속).

```js
// s.js:  const c = new C(); export default c;   // 싱글톤
// u.js:
import _c from "./s.js";
export const f = (r) => { const c = _c.set(r); return c; };   // 함수-로컬 c 가 import c 를 shadow
// 버그: const c = c.set(r) → ReferenceError: Cannot access 'c' before initialization
```

#4563 은 싱글톤과 소비자가 **같은 청크**(target canonical 을 `c$1` 로 rename)인 경우만 고쳤다. 잔여 토폴로지 — (A) cross-chunk splitting(싱글톤이 다른 청크로 hoist), (B) preserve-modules(import 를 문으로 보존, 로컬명이 export 명으로 rename 돼 함수-로컬과 충돌), (C) dev-split(same-chunk 인데 cross-chunk-export 도 돼 lazy override 가 target-rename 을 revert) — 은 target 의 canonical 을 이 청크서 못 건드려 self-TDZ 가 남았다.

## 수정

`resolveNestedShadowForModule` 을 분기: target 이 소비자와 **같은 청크 & cross-chunk-export 아님**이면 target canonical 을 rename(#4563), 아니면(다른 청크 / 파일경계 / cross-chunk-export) target 을 못/안 건드리므로 **소비자의 nested(scope 1+) 바인딩**을 rename. 소비자 로컬은 토폴로지 무관하게 항상 rename 가능하므로 세 케이스를 통합 해소한다.

### `/code-review max` 반영

- **참조 이름은 same-chunk 면 canonical local, cross-chunk 면 전역 공개명**: same-chunk 소비자는 로컬명으로 참조하므로 전역명으로 shadow 를 찾으면(local!=global) 놓쳐 #4563 이 회귀. `target_same_chunk` 판정 후 ref_name 결정.
- **eval/`with` 가드**: consumer-rename 는 `resolveWrapperConsumerShadows` 와 동일하게 `blocksMangling()` 모듈 skip(동적 이름 참조 → 리네임 시 ReferenceError). minify 도 skip(mangler 담당).
- **공유 헬퍼 `renameConsumerScopeBindings`**: consumer-nested-rename 루프를 `deconflictConsumerShadows`(#4533)와 공유 — 드리프트 제거(가드/scope 처리 단일 출처).
- 회귀 가드 cross-chunk 구조 검증에 `fChunk` 정의 확인 추가(undefined 시 vacuous 통과 방지).

## 검증

- (A) cross-chunk splitting: `import { c }` + `const c$1 = c.set(...)`, 실행 `f:6 / 6`.
- (B) preserve-modules: `import { default as c }` + `const c$1 = c.set(...)`, 실행 `f:6`.
- (#4563) same-chunk(non-cross-export): `channels$1`(target rename) 유지, `rgba:10`.
- 실제 mermaid: minify·non-minify **양쪽 9종 다이어그램 브라우저 렌더 성공**.
- 회귀 가드: `split-runtime-smoke.test.ts` `#4566(A)`/`#4566(B)`. zig 전체 + 통합(4272) 무회귀 — per-chunk 리네이머는 모든 splitting/preserve-modules 빌드 코어라 전량 검증.
