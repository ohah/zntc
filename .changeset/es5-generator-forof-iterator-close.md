---
'@zntc/core': patch
---

es5 generator/async 함수 안의 `for…of` 가 조기 종료할 때 iterator 를 닫지 않던 문제를 고쳤습니다 (#4714).

```js
function* src() { try { yield 1; yield 2; } finally { console.log('closed'); } }
function* g() { for (const v of src()) { if (v === 1) break; yield v; } }
// 네이티브: closed   /  이전(es5): 아무것도 출력되지 않음
```

`break`·`return`·`throw`·라벨 붙은 바깥 `break`·일시정지 중 `gen.return()`/`gen.throw()` 로 루프를 빠져나가면 이제 `iterator.return()` 을 부릅니다. 스펙(IteratorClose)대로:

- 정상 완료나 `next()` 자체가 던진 경우에는 닫지 않습니다.
- `return` 메서드가 없으면 건너뜁니다.
- 본문이 던진 에러는 `return()` 이 던진 에러보다 우선합니다.

일반 경로(`es2015_for_of`)와 같은 try/catch/finally 구조라, es5 산출물이 generator 안 `for…of` 마다 조금 커집니다(실측 라이브러리 기준 수백 B~1.7KB, minify 시 약 절반).
