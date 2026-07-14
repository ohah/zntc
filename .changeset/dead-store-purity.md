---
"@zntc/core": patch
---

dead-store 제거가 **평가 부수효과까지 삭제**하던 무성 오컴파일 수정 (#4514).

```js
let x = obj.p;   // obj.p 가 getter 면 평가 자체가 부수효과
x = 2;           // 버그: `x = obj.p` 삭제 → getter 미호출

let y = a.b.c;   // a.b 가 undefined 면 TypeError
y = 2;           // 버그: 삭제 → TypeError 안 던짐

let z = undeclaredGlobal;   // ReferenceError
z = 2;                      // 버그: 삭제 → 안 던짐
```

근본 원인: dead-store 가 **tree-shaking 용** purity 판정(`purity.isExprPure`)을 썼다. 그건 "이 **선언을 안 만들어도** 되는가" 기준이라 member access 와 미해결 식별자를 pure 로 친다(esbuild 동일). 하지만 dead-store 는 **이미 실행되기로 확정된 표현식을 삭제**하는 패스라, 문 자리 DCE 와 같은 엄격 술어를 써야 한다. 두 패스가 이제 `purity.isRemovableAtStmtPos` 하나를 공유한다.

함께 수정: 비엄격 함수의 **파라미터** 는 `arguments` 객체와 양방향 aliasing (mapped arguments) 이라 `arguments[0]` 읽기가 참조 배열에 안 잡힌다 — 파라미터 store 는 제거하지 않는다.

진짜 dead store(부수효과 없는 리터럴·지역 식별자·순수 연산)는 계속 제거된다. 대표 라이브러리 12종 `--minify` 산출물은 **byte-identical**(size 영향 0).

추가(코드리뷰): 통합한 술어를 **쓰지 않던 두 호출부**가 남아 있었다. `isStmtRemovable(operand)` 은 "이 표현식의 **평가**를 없애도 되는가" 를 답하는데, 강제 변환 연산에서는 operand 의 **값이 관측**된다 — 술어를 잘못된 질문에 쓴 것이다.

- `rewriteBinaryUnused` 가 `+`/`==`/`<`/`in`/`instanceof` 까지 "양쪽 operand 가 removable 이면 전체 removable" 로 봤다. `({valueOf(){…}}) + 1;` 이 통째로 삭제돼 **valueOf 가 안 불린다**. 강제 변환이 전혀 없는 `===`/`!==` 만 손대도록 좁혔다 (esbuild 도 `1 < foo()` 를 건드리지 않는다).
- `rewriteObjectUnused` 가 computed key 표현식을 drop 했다. key 는 평가만 되는 게 아니라 그 **값에 ToPropertyKey** 가 걸려 `toString` 이 불린다. computed key 가 있으면 객체를 통째로 유지한다 (esbuild 는 `foo() + ""` 로 강제 변환을 보존한 채 추출한다 — zntc 는 그 합성 대신 보존을 택했다).

기존 minify 테스트 3건이 이 불건전한 축약을 **박제**하고 있어 함께 갱신했다(node 정본으로 확인 — 셋 다 부수효과가 실제로 호출된다).
