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

추가(코드리뷰): 첫 수정이 **하드 회귀 4건**을 만들었고 전부 잡았다.

- 소비자 재작성을 `rewriteImportCallToWrapper`(첫 `indexOf` 1회 + import attributes 미지원)로 바꾼 탓에, **앞선 문자열 리터럴 occurrence** 나 `import("./x.cjs", { with: {} })` 에서 specifier 가 통째로 미치환 → `ERR_MODULE_NOT_FOUND`. #4295 가 고쳤던 바로 그 miscompile 이다. 같은 positional walk 를 쓰되 호출 끝을 **괄호 균형**으로 찾는 재작성기로 다시 썼다.
- provider 는 `linker orelse break` 로 bail 하는데 consumer 는 `linker` 를 안 봐서, `scopeHoist: false`(linker null)에서 export 가 없는 값을 `.default` 로 벗겨 **TypeError**. provider/consumer/헬퍼 3곳의 복붙 술어를 `dynamicCjsNamespaceEntry` 단일 소스로 합쳤다.
- federation expose / plugin `emitFile({type:'chunk'})` 도 **같은 dynamic entry 모양**이라 provider 만 바뀌고 그쪽 소비자(container factory / 사용자 코드)는 안 벗긴다 → `default` 슬롯 의미가 조용히 바뀐다. entry 에 `is_import_call` 을 달아 **진짜 `import()` 대상만** namespace 로 가고, 그 둘은 기존 계약을 그대로 유지한다.
