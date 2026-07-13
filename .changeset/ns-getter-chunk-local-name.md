---
"@zntc/core": patch
---

코드 스플리팅 + `--minify` 에서 **materialize 된 namespace 객체의 getter** 가 같은 청크 소비자에게도 크로스-청크 전역 공개명을 써서 런타임에 죽던 버그 수정 (#4502, #4492 의 네 번째 표면).

```
ReferenceError: second is not defined
```

`import * as ns` 를 **값으로** 쓰면(`const o = ns`) 정적 멤버 재작성이 불가능해 객체가 materialize 된다. 그 리터럴은 **정의자 청크** preamble 로 들어가는데, getter 본문이 크로스-청크 전역 공개명을 쓰고 있었다:

```js
// 공유 청크 — 선언은 여기 있다
let n = { label: "second" }, r = { label: "other" };
var ns_ns = { get second(){ return second }, get other(){ return r } };
//                          ^^^^^^ 이 청크엔 `second` 선언이 없다 → ReferenceError
```

`other` 는 크로스-청크로 안 나가서 chunk-local `r` 을 올바르게 쓰는데, `second` 는 **다른 청크가 소비해서 전역 공개명이 등록됐다는 이유만으로** 그 이름을 썼다.

**왜 순진한 게이트로는 못 고치는가.** getter 생성 지점(`buildInlineObjectStr`)을 "같은 청크면 로컬 이름" 으로 게이트하면 #4101 이 회귀한다. 그 시점엔 **per-chunk rename 이 아직 안 돌아서** 로컬 이름이 미-deconflict 원본 이름이기 때문이다 — 서로 다른 모듈의 동명 `const k` 두 개가 한 청크에서 `k` / `k$1` 로 갈려야 하는데 둘 다 `k` 로 collapse 된다(`e1 XK YK XK YK` → `e1 XK YK XK XK`). 코드가 전역 공개명을 쓰고 있던 건 그것이 **"확정된 이름의 대리물"** 이었기 때문이다.

**처방은 게이트가 아니라 타이밍.** 공유 ns preamble 생성을 청크 emit 루프의 `computeRenamesForModules` **뒤** 로 옮겨(출력 위치는 `insertSlice` 로 종전과 동일하게 유지) chunk-local 이름이 확정된 뒤에 리터럴을 만든다. 그러면 getter 가 (같은 청크 선언 → 확정된 chunk-local 이름 / 다른 청크 선언 → 크로스-청크 전역 공개명) 을 정확히 고른다. `ns_inline_cache` 도 소비자 청크마다 문자열이 달라지므로 `(emitter 청크, target)` 복합 키로 re-key 했다.

빌드 exit 0 + 산출물 파싱 통과 + **실행만 실패**하는 계열이라, 번들을 실제로 실행하는 스모크 테스트를 함께 추가했다.
