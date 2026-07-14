---
"@zntc/core": patch
---

TS 접미사(`!` non-null / `<T>` 타입인자)가 `new` 의 callee **밖으로 새던** 무성 오컴파일 수정 (#4505).

```ts
const b = new tag<number>`${"hello"} ${"world"}`(100, 200);
// 방출(버그): new tag()`${"hello"} ${"world"}`(100, 200)
//             → tag 를 *생성*한 뒤 그 인스턴스를 태그 호출 (완전히 다른 프로그램)
// 방출(정상): new tag`${"hello"} ${"world"}`(100, 200)   ← tsc 동일
```

ECMAScript 문법상 `MemberExpression TemplateLiteral` 은 그 자체가 MemberExpression 이라 tagged template 은 **바깥 new 의 callee** 에 속한다. 그런데 `parseNewCallee` 가 member 체인 루프를 **다 돈 뒤에** TS 접미사를 처리해서, 타입인자가 붙는 순간 callee 가 거기서 끊기고 뒤따르는 template 이 new 밖으로 새어나갔다. argless 로 끝난 바깥 new 에 codegen 이 `()` 를 다시 붙여 `new tag()` 가 됐다.

타입인자 speculation 을 member 루프 **안으로** 옮겨 해결. #4500(같은 함수의 `kw_new` 분기가 즉시 return) 과 같은 파일, 다른 루트커즈다.

TSC 컨퍼먼스 스냅샷(`taggedTemplatesWithTypeArguments2`)이 이 오컴파일을 **박제**하고 있어 함께 갱신했다 — 갱신 후 tsc 정본 emit 과 일치한다.
