---
'@zntc/core': patch
---

`export default Math` 처럼 **전역을 default 로 내보내는** 모듈이 splitting 으로 별도 청크가
되면 `export { Math as default };` 를 방출해 `SyntaxError: Export 'Math' is not defined in
module` 로 파싱이 실패하던 문제를 고쳤다. ESM 의 export specifier 자리는 **그 모듈에 선언된
바인딩**만 받는다.

전역 참조는 `unresolved_references` 로 판정해 `var <syn> = <global>;` 를 깔고 그 식별자를
내보낸다 — CJS interop 이 쓰던 `materialize` 와 같은 기계다.
