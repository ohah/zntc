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

`/code-review max` 가 첫 구현의 회귀 3건을 잡아내 설계를 바로잡았다.

- **정규화를 먼저 시도한 게 잘못이었다.** `--alias` / tsconfig `paths` 로 매핑되던 worker 지정자가 같은 이름의 형제 파일에 조용히 가려졌다. → **기존 해석을 먼저 시도하고, 못 찾았을 때만 `./` 를 붙인다.** 기존에 resolve 되던 것은 하나도 바뀌지 않는다.
- `?worker` 등 query 가 붙은 bare 지정자를 정규화하면 worker 본문이 아니라 **WorkerWrapper 팩토리** 청크가 만들어져 워커가 영영 응답하지 않았다. → query/fragment 가 붙은 지정자는 정규화 대상에서 제외.
- codegen 이 `new URL(spec, base)` 의 **base 인자를 확인하지 않아**, 같은 문자열을 다른 base 로 쓴 무관한 `new URL("x.worker.js", "https://cdn/")` 까지 worker 청크로 재작성됐다 (scan 단계는 base 를 검사한다). → codegen 도 `import.meta.url` 인지 확인.

함께 고친 것:

- `--packages=external` 의 "bare = npm 패키지" 자동 규칙을 worker 에는 적용하지 않는다 (사용자가 명시한 `--external:` 패턴은 그대로 존중).
- external 로 분류된 worker 가 UMD/AMD **의존성 배열**에 딸려 들어가 AMD 로더가 워커 스크립트를 메인 번들의 모듈 의존성으로 실행하려 들던 문제 (`.css_url` 과 같은 carve-out 적용).
