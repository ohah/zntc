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
