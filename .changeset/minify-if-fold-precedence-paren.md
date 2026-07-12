---
"@zntc/core": patch
---

minify 시 `if (c) ({a} = o)` 를 `c && ({a} = o)` 로 접을 때 **필수 괄호가 사라지던** 버그 수정 (#4481).

`&&` 는 `=` 보다 우선순위가 높아 `c && {a} = o` 는 `(c && {a}) = o` 로 파싱된다 — `SyntaxError: Invalid left-hand side in assignment`. 빌드는 exit 0 인데 산출물이 파싱조차 되지 않았다 (monaco-editor `ts.worker`, codemirror).

원인은 `if` → `&&`/`?:` 폴딩 경로가 피연산자를 `emitNode`(= precedence level `.lowest`)로 방출해, 방출 단계의 공통 괄호 로직(`exprNeedsParens`)을 우회한 것이다. 폴딩된 피연산자를 실제 자리의 level(`&&` 의 좌/우, `?:` 의 test/분기)로 방출하도록 바꿔 필요한 괄호가 재유도되게 했다. 같은 뿌리의 아래 케이스도 함께 고쳐진다.

- `if ((m = f())) g(m)` → `m=f()&&g(m)` (파싱은 되지만 `m = (f() && g(m))` 로 **의미가 바뀌던** silent miscompile) → `(m=f())&&g(m)`
- `if (c) (a(), b()); else d()` → `c?a(),b():d()` (SyntaxError) → `c?(a(),b()):d()`
- `if ({}.x) g()` → `{}.x&&g()` (SyntaxError) → `({}).x&&g()`
- `if ((m = f())) return A; return B;` → `return m=f()?A:B` (의미 변경) → `return (m=f())?A:B`

아래 두 건은 같은 뿌리(#4042 괄호 투명화)에서 온 것으로 code-review 에서 확인돼 함께 고쳤다.

- `return ( /* c */ g() )` 가 `return /* c */⏎ g()` 로 방출돼 **ASI 로 undefined 를 반환**하던 버그 (`throw` 는 `Illegal newline after throw`). minify 없이도 발생.
- `if (let[0]) g()` (sloppy `var let`) 를 `let[0] && g()` 로 접으면 statement 가 `let [` 로 시작해 lexical 선언으로 오파싱 → SyntaxError. 이 경우 폴딩을 포기한다.
