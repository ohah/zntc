---
"@zntc/core": patch
---

`<_ns/>` 처럼 소문자로 시작하지 않는 bare JSX 태그의 참조가 안 잡혀 대상 import 가 통째로
tree-shake 되던 문제를 고쳤다 (#4599 잔여분).

analyzer 가 bare 태그를 `isUpper(name[0])` 일 때만 변수 참조로 resolve 해서, `_ns`/`$x` 처럼
밑줄·달러로 시작하는 태그는 참조가 보이지 않았다. 선언 없는 `<_ns/>` 가 방출됐다.

JSX 관례(babel·tsc·esbuild·rolldown 공통)에서 intrinsic 은 **소문자로 시작하는 태그뿐**이므로,
판정을 "소문자로 시작하지 않음" 으로 바꿨다. `<div>` 같은 intrinsic 은 종전대로 문자열 태그다.
