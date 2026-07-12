---
"@zntc/core": patch
---

`--jsx=preserve` 가 JSX 를 소스 원문 복사가 아니라 AST 로 출력한다 (#4470).

preserve 모드는 JSX 를 변환하지 않고 downstream tool 에 위임한다. 그런데 그 "그대로" 를 **소스 span 통째 복사**로 구현하고 있어서, JSX 안에서만 AST 변형이 전부 무시됐다.

### 고쳐진 것

**1. 번들 deconflict rename 누수 → `ReferenceError`**

```jsx
import { Widget as A } from "./a.jsx";
export const q = <A.Panel />;
```

scope hoisting 후 실제 심볼은 `Widget` 인데 태그는 `A` 를 그대로 들고 있었다. 번들에 `A` 선언이 없으므로 downstream 변환 결과는 `ReferenceError: A is not defined`. 이제 `<Widget.Panel />` 로 나간다.

**2. JSX 안의 TypeScript 어노테이션 미strip**

`<Foo prop={value as Type} />` 의 `as Type` 이 남아 JS 로 파싱 불가였다. (기존 코드가 "알려진 제약" 으로 주석에 명시해 두던 항목.)

**3. `--define` 치환 미적용**

`<Foo x={__MODE__} />` 의 `__MODE__` 가 그대로 남았다.

**4. 깨진 JSX 출력**

transformer 가 element/fragment 는 `shouldLowerJsx()`(preserve 존중)로, 자식(expression container / text / spread)은 `jsx_transform` 으로 게이트해서 **preserve 모드인데 자식만 lowering** 됐다. 그 결과 `<div>{x}</div>` 가 `<div>"..."x</div>` 처럼 텍스트에 따옴표가 붙고 중괄호가 사라진 채로 나갔다. 두 게이트를 통일했다.

### 안전 장치

- **속성 이름은 절대 rename 되지 않는다.** semantic analyzer 가 `jsx_attribute` 의 value 만 방문하고 name 은 방문하지 않으므로 심볼이 붙을 수 없고, codegen 도 name 을 원문 경로로 낸다.
- **원본 소스의 attribute string 은 원문 보존.** JSX attribute string 은 JS string 과 escaping 규칙이 다르다(backslash escape 없음, HTML entity 사용) — `c="a&amp;b"` 가 그대로 나간다.
- **합성된 string 은 `{}` 로 감싼다.** `--define` 치환 결과처럼 따옴표가 든 값을 attribute string 자리에 그대로 내면 `d="a\"b"` 가 되는데 JSX 는 그 백슬래시를 escape 로 읽지 않는다. `d={"a\"b"}` 로 낸다.
