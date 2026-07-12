---
"@zntc/core": patch
---

방출 단계에서 **단항 연산자 토큰이 병합**되거나 **`**` 좌변 괄호가 사라지던** 버그 수정 (#4482).

```js
f(-(--t))      // 버그: f(---t)        → SyntaxError
f(-(-t))       // 버그: f(--t)         → t 를 감소시키는 silent miscompile
(-a) ** b      // 버그: -2**2          → SyntaxError
(-a).toString()// 버그: -2 .toString() → 문자열 "-2" 가 아니라 숫자 -2 (silent)
true.toString()// 버그: !0.toString()  → SyntaxError
undefined ** 2 // 버그: void 0**2      → SyntaxError
```

원인은 둘이다.

1. 단항 `-`/`+` 의 **피연산자 슬롯에 토큰 병합 방지 공백 가드가 없었다**. 이항 RHS 슬롯에는 있었지만 단항에는 대응물이 없어 `-` + `--t` 가 `---t` 로 붙었다. minify 와 무관하게 발생한다.
2. `binaryChildLevels` 가 `**` 좌변의 level 을 올려도, `exprNeedsParens` 에 `numeric_literal`/`boolean_literal` case 가 없어 그 level 이 그냥 버려졌다. 미니파이어가 `-a` 를 `numeric_literal("-2")` 로, `true` 를 `!0` 으로 바꾸는 순간 `.unary_expression` 매칭을 빠져나간다.

`d3@7` (`d3-ease` 의 elastic) 이 `tpmt(-(--t))` 를 써서 `import * as d3 from "d3"` 를 `--minify` 로 번들하면 산출물이 파싱되지 않았다.

`/code-review max` 가 같은 계열의 구멍 3건을 더 찾아 함께 고쳤다 (셋 다 `--minify` 없이 번들만 해도 발생).

```js
// flags.js: export const U = undefined; export const ON = true;
U ** 2                      // 버그: void 0**2      → SyntaxError
(ON && -1) ** k             // 버그: -1 ** k        → SyntaxError
x - (ON ? -1 : 1)           // 버그: x--1           → SyntaxError
-(ON ? -t : t)              // 버그: --t            → t 를 감소시키는 silent miscompile
```

원인은 하나다 — 괄호/공백 판정이 **AST 태그**를 봤는데, codegen 은 emit 시점에 노드를 갈아치운다(상수 인라인, 상수 단락/조건 fold). 그래서 fold 로 사라질 분기를 보고 판단했다.

처방도 하나다. 토큰 병합 방지를 **출력 바이트 기준**(esbuild `prevOp`/`prevOpEnd`)으로 바꿨다 — 어느 노드가 emit 되든 직전에 나간 바이트를 보므로 fold 와 무관하게 정확하다. AST 룩어헤드(`leadingSignChar`)는 제거했다. `**` 좌변 괄호 판정은 emit 시점의 fold/치환 결정을 그대로 따라 내려가도록 고쳤다.

덤으로 과잉 공백도 사라졌다: `-(-a - b)` 는 피연산자가 이미 괄호로 감싸이므로 공백이 불필요한데 AST 룩어헤드는 그걸 몰랐다 → 이제 esbuild 와 바이트 동일(`-(-a-b)`).
