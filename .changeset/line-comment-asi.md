---
'@zntc/core': patch
'@zntc/wasm': patch
---

`return` / `throw` / `yield` 피연산자 앞에 줄 주석(`//`)이 오면 그 뒤 코드가 전부 주석에
먹히던 문제를 고쳤다. `return`은 조용히 `undefined`를 반환하고, `throw`는 SyntaxError,
`yield`는 `undefined`를 yield했다. JSX와는 무관하며 숫자·문자열·호출 등 모든 식에서 발생했다.

이 세 키워드는 ECMAScript `NoLineTerminator` 제한이 있어 피연산자 앞에 줄바꿈이 오면 안 된다.
그래서 선두 주석을 줄바꿈 없이 인라인으로 붙여 왔는데, 그 전략은 블록 주석에만 유효하다.
이제 줄 주석이 선두에 있으면 **괄호로 감싼다** — 괄호가 줄바꿈을 안전하게 만들어 주석도
살고 ASI도 안 끊긴다 (swc·babel과 같은 전략). 블록 주석 경로와 `#4042`의 군더더기 괄호
제거는 그대로다.

함께 고친 것:

- `//` 주석 뒤에는 minify에서도 실제 개행을 쓴다. `writeNewline`이 minify에서 no-op이라
  `// @license` 같은 legal 줄 주석이 살아남는 경우 뒤가 전부 먹혔다.
- 괄호가 멤버 접근의 대상일 때(`return ( /* c */ x ).y`) 안쪽 주석을 놓쳐 ASI가 나던 것도
  고쳤다. 출력의 가장 왼쪽 토큰까지 내려가 주석을 미리 소비한다.
- 비어 있지 않은 블록의 마지막 statement 뒤 주석이 블록 밖으로 새던 것을 고쳤다 (`#4468`이
  빈 블록만 고쳐 둔 것의 짝). swc·babel·oxc 모두 제자리에 둔다.
