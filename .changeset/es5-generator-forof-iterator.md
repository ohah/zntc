---
'@zntc/core': patch
---

`--target=es5` 에서 generator 안의 `for…of` 가 비배열 iterable 을 돌 때 **조용히 아무것도 내보내지 않던** 문제를 고쳤습니다 (#4709).

```js
function* src()   { yield 1; yield 2; }
function* outer() { for (const v of src()) yield v; }
[...outer()]
// es5: []   ← 에러도 경고도 없이 빈 결과
```

`yield` 를 품은 `for…of` 는 상태 기계로 접히는데, 그 경로만 `_arr[_i]` / `_arr.length` **인덱스 루프**로 고정 변환하고 있었습니다. `.length` 가 없는 Set·Map·generator·커스텀 iterable 은 첫 비교에서 루프가 끝납니다(배열과 문자열만 우연히 동작). 이제 `__values()` + `next()/done` 으로 돕니다 — `yield*` 가 이미 쓰던 것과 같은 헬퍼입니다.

`for…in` 은 키 수집 의미라 기존 경로를 그대로 씁니다.
