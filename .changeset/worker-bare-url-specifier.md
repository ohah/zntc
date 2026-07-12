---
"@zntc/core": patch
---

`new URL("x.worker.js", import.meta.url)` 처럼 `./` 가 없는 worker 지정자도 재작성한다 (#4483).

`new URL(spec, import.meta.url)` 의 `spec` 은 **URL 상대 참조**다. base 가 모듈 자신의 URL 이므로 `"x.worker.js"` 와 `"./x.worker.js"` 는 같은 파일을 가리킨다. 그런데 지금까지 zntc 는 `./` 가 붙은 것만 재작성하고, `./` 없는 bare 형태는 npm 패키지 이름으로 보고 `node_modules` 를 뒤졌다 → resolve 실패 → 경고만 남기고 원문 그대로 방출 → 해시된 산출물 이름과 어긋나 **런타임 404**.

```js
new Worker(new URL("./dbl.worker.js", import.meta.url)); // → new URL("./dbl.worker-1c4d8b20.js", …) ✅
new Worker(new URL("dbl.worker.js", import.meta.url)); // → new URL("dbl.worker.js", …) ❌ 404
```

`monaco-editor` 의 `cssMode.js` / `tsMode.js` 등이 정확히 이 형태(`new Worker(new URL("css.worker.js", import.meta.url), { type: "module" })`)를 써서, Monaco 기본 워커 해석에 의존하는 앱이 그대로 깨졌다.

resolve 레이어에서 worker 지정자가 bare 상대 참조면 `./` 를 붙여 해석한다. `--packages=external` 이 bare worker 지정자를 external **패키지**로 오인하던 부수 버그도 함께 해소된다.

- 스킴이 있는 절대 URL(`https:` / `data:` / `blob:` / `chrome-extension:`), protocol-relative(`//cdn/w.js`), root-absolute(`/abs.js`) 는 그대로 둔다 — origin 기준 참조라 `./` 를 붙이면 의미가 깨진다.
- 형제 파일이 없으면 원문 그대로 한 번 더 해석한다 — `new Worker(new URL("monaco-editor/esm/vs/editor/editor.worker.js", import.meta.url))` 같은 **패키지 경로 worker** 가 예전처럼 `node_modules` 로 해석된다 (Vite 도 양쪽을 지원).
- `--external:x.worker.js` 처럼 사용자가 원문 철자로 건 external 패턴도 그대로 존중한다.
