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
