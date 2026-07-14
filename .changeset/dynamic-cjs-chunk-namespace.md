---
"@zntc/core": patch
---

code-split 된 **동적 CJS import** 가 named 멤버를 잃던 무성 오컴파일 수정 (#4522).

```js
// legacy.cjs
module.exports = { foo(){ return "FOO"; }, bar: 42 };

const m = await import("./legacy.cjs");
m.foo();
```

| | code-split 시 `keys` | `m.foo()` |
|---|---|---|
| node (정본) | `default, foo` | ✅ |
| zntc (버그) | `default` | ❌ `TypeError` |
| rolldown / rspack | named 포함 | ✅ |

**같은 소스가 청킹 설정에 따라 런타임 값이 갈렸다** — 인라인(단일 번들)은 정상, `--splitting` 만 깨졌다. 빌드 exit 0 · 파싱 통과 · 실행만 실패.

근본 원인: 동적 CJS entry 청크가 CJS↔ESM interop 결과(namespace)를 **`default` 슬롯 하나로 좁혀서** 내보냈다. CJS 는 정적 export 가 없어 named 멤버를 ESM `export` 문법으로 **표현할 수 없으므로** 그대로 유실된다. 같은-청크 경로는 `import()` **호출 자체**를 `__toESM(require_x())` 표현식으로 치환하니 namespace 가 통째로 살아남아서, 두 경로가 갈렸다.

처방(rolldown 동형): 청크가 **namespace 를 통째로** 실어 보내고(`export default __toESM(require_x())`), 소비자가 `.default` 로 한 겹 벗긴다. esm / cjs / iife·umd·amd 세 형식 모두 동일하게 적용된다. 이제 인라인과 splitting 이 **같은 값**을 만든다.

함께 수정: 동적 entry 청크의 `__toESM` 헬퍼 주입 조건에서 `can_skip_cjs_default_interop` 예외를 제거했다. 그 예외는 "`default` 값 하나만 내보내던" 시절의 것으로, namespace 를 보내는 지금은 shape 와 무관하게 항상 헬퍼가 필요하다(안 그러면 `ReferenceError: __toESM is not defined`).
