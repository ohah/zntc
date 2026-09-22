---
'@zntc/core': patch
---

`--target=es5 --minify` 에서 `for await` 이 들어간 `try/catch` 가 `ReferenceError: _e is not defined` 로 죽던 문제를 고쳤습니다 (#4703).

```js
async function f() {
  try { for await (const v of xs) use(v); } catch (e) { handle(e); }
}
// es5 + minify: ReferenceError: _e is not defined
```

es5 상태 기계는 `catch (e) {…}` 를 `case N: e = _state.sent();` 로 접는데, catch 의 **바인딩** 노드를 그대로 대입 좌변에 재사용하고 있었습니다. 좌변은 선언이 아니라 **참조**입니다. 소스에서 온 catch 파라미터는 스코프 분석이 이미 등록해 둬서 우연히 해석되지만, 트랜스포머가 합성한 temp(`for await` 의 `_e`)는 분석 이후에 만들어져 해석되지 않습니다 → minify 때 호이스트된 `var` 선언만 리네임되고 좌변은 원래 이름으로 남았습니다.

minify 없이는 이름이 그대로라 드러나지 않았고, es5 에서만 발생합니다.
