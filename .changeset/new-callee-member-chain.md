---
"@zntc/core": patch
---

`new` callee 파싱이 member 체인 / tagged template 을 흡수하지 못해 **진단 없이 잘못된 코드를 방출**하던 버그 3건 수정 (#4500).

```js
new new Inner().C()   // 방출: new new Inner()().C()  → TypeError: (intermediate value) is not a constructor
new tag`x`.B()        // 방출: new tag()`x`.B()       → TypeError: (intermediate value) is not a function
```

ECMAScript 는 `MemberExpression: new MemberExpression Arguments` 이므로 중첩 `new` 뒤의 `.C`/`[k]` 와 callee 안의 `` `tpl` `` 은 **바깥 new 의 callee** 에 속한다(`new (new Inner().C)()`). 그런데 `parseNewCallee` 가 중첩 new 를 만들고 **즉시 return** 해서 뒤의 member 체인 루프에 도달하지 못했고, 그 루프엔 tagged template arm 자체가 없었다. 그 결과 체인이 바깥 new *밖*으로 새어나가고, argless 로 끝난 바깥 new 에 codegen 이 `()` 를 다시 붙여 원본과 다른 프로그램이 됐다.

파이프라인 **idempotency** 도 함께 깨져 있었다 — zntc 가 `new (new A().b)()` 를 `new new A().b()` 로 방출하고, 그 출력을 zntc 가 다시 읽으면 `new new A()()` + `.b()` 로 잘못 재해석했다(2-pass/번들 시 위험).

세 번째로, TS 타입 래퍼가 argless-new head 를 가려 SyntaxError 를 놓치던 accept-invalid 도 고쳤다 — `new a\`x\`!?.b` 는 타입 소거 후 `new a\`x\`?.b` 와 같은 SyntaxError 인데 `!`/`as T`/`<T>x` 래퍼를 walk 가 안 넘어가 exit 0 으로 수용했다(ZNTC0623 정상 발생). Flow 의 `(x: T)` cast 는 **괄호 자체**라 통과시키면 안 된다(유효한 `(new a: any)?.b` 오거부) — `isParenFreeTypeWrapper` 로 분리했다.

"tagged template 이 new 의 callee" 라는 AST 모양이 처음 생기면서 그 모양을 못 다루던 하류 3곳도 함께 고쳤다:

- **codegen**: callee 안의 call 에 괄호를 안 붙여 `` new (f())`x` `` → `` new f()`x`() `` (f 가 *생성*되고 template 결과가 *호출*됨). member 의 object 처럼 tagged template 의 tag 에도 `forbid_call` 을 전파.
- **es5/es2015 다운레벨**: `lowerSpreadNew` 가 callee 를 identifier 로 가정해 `new a.b(...args)` 가 **컴파일러 crash** 였다(기존 버그). temp 캡처로 callee 를 1회만 평가하도록 수정 — `new ((_a = a.b).bind.apply(_a, ...))()` (tsc 동형).
- **minify**: `` (0, o.tag)`x` `` 의 sequence 를 풀어 tag 가 `this=o` 로 호출되던 것 방지.
