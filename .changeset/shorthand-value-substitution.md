---
"@zntc/core": patch
---

구조분해/객체리터럴 shorthand 의 값 치환이 **프로퍼티 이름까지 바꾸던** 버그와 `undefined` peephole 의 섀도잉 오적용 수정 (#4515).

shorthand `{x}` 는 노드 **하나**가 프로퍼티 이름(키)이자 값이다. 그런데 파서는 `({x} = o)` 의 `x` 도 늘 `identifier_reference` 로 태그하므로, codegen 이 이걸 그냥 값으로 방출하면 값 치환(mangler rename / 상수 인라인 / `undefined`→`void 0`)이 **키까지 같이** 바꾼다.

```js
{exports}    → {$e}          // CJS 래퍼 안에서 키가 바뀜
{undefined}  → {void 0}      // SyntaxError
```

치환이 일어날 자리면 longhand(`이름: 값`)로 펼치도록 했다. 자리(값 / 대입대상)는 호출자가 `ShorthandSlot` 으로 알려준다 — 파서에서 태그를 바꾸면 `makeRestExcludeKey` 같은 태그 스위치 소비자들이 조용히 깨진다.

함께 수정:

- **패턴 프로퍼티의 computed key 를 semantic 이 방문하지 않았다** — `({[k]: t = d} = o)` 의 `k` 가 읽기 참조로 안 잡혀 rename/DCE 에서 누락됐다.
- **`undefined` → `void 0` peephole 이 섀도잉된 지역 바인딩에도 발동**했다. 가드가 `sym_id == null` 하나였는데 `sym_id` 는 linking metadata(= 번들 모드)가 있을 때만 채워진다 — transpile 모드엔 metadata 가 없어 **항상 null** 이라 "unbound global" 판정이 무조건 참이었다.

  ```js
  function f(x){ let undefined = x; return { undefined }; }
  f(5)   // node: {"undefined":5}   zntc(버그): {}   ← 문법 유효, 값만 틀림
  ```

  섀도잉이 없으면 그대로 치환하므로 size 회귀는 없다.
- `({[k] = 1} = o)` 처럼 computed key 에 default 를 붙인 **invalid 문법을 accept** 하던 것도 거부.

추가(코드리뷰): **import 바인딩도 섀도잉으로 봐야 한다.** `import { v as undefined }` 의 local 은 별도 `binding_identifier` 노드가 아니라 `import_specifier` 의 오른쪽 자식이고 태그가 `identifier_reference` 다. 그래서 바인딩 스캔이 놓쳤고, 그 local 이름 **자신**이 peephole 을 맞아 `import { v as void 0 }` — **파싱 불가** 산출물이 나왔다. `import undefined from` / `import * as undefined` 도 같다. 또 `targetIdentSafeToEmit` 이 술어를 이름으로 재구현하고 있어 섀도잉 검사를 건너뛰었다 — `Codegen.undefinedPeepholeApplies` 로 위임했다.
