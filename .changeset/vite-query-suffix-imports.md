---
"@zntc/core": patch
---

Vite 식 query-suffix import 지원 — `?raw` / `?url` / `?inline` / `?worker` (#4467).

Vite 생태계 문서·레시피가 널리 쓰는 관용구인데 zntc 가 resolve 하지 못해 `ZNTC0100 Cannot resolve module` 이 났다. 라이브러리 문서 다수가 이 형태를 전제해서 마이그레이션 마찰이 됐다.

| suffix | 동작 |
|---|---|
| `?raw` | 파일 내용을 문자열로 인라인 (`text` 로더) |
| `?url` | 자산으로 방출하고 URL 문자열을 export. **`--asset-inline-limit` 을 무시**한다 — 사용자가 URL 을 명시 요청한 것이므로 작은 파일도 data URL 로 바뀌지 않는다 |
| `?inline` | data URL 로 인라인 (`dataurl` 로더). 크기와 무관하게 항상 인라인 |
| `?worker` | Worker 생성 함수를 default export — `new W()` 로 Worker 를 만든다 |
| `?sharedworker` | SharedWorker 생성 함수를 default export |

```js
import txt from "./data.txt?raw";      // "hello raw content"
import u   from "./icon.png?url";      // "./icon-a1b2c3d4.png"
import i   from "./icon.png?inline";   // "data:image/png;base64,..."
import W   from "./x.worker.js?worker";
const w = new W();
```

같은 파일도 query 마다 다른 모듈이다 (`x.png` 는 자산, `x.png?raw` 는 문자열).

`?worker` 는 새 인프라를 만들지 않고 **표준 worker 패턴을 합성**해 기존 기계를 재사용한다:

```js
export default function WorkerWrapper(options) {
  return new Worker(new URL("./x.worker.js", import.meta.url), options);
}
```

`{ type: "module" }` 을 붙이지 **않는다.** zntc 는 worker entry 를 항상 classic script(IIFE)로 방출하므로, module worker 로 로드하면 strict mode / `importScripts` 부재 같은 다른 semantics 가 걸려 classic 번들이 터질 수 있다. Vite 도 worker 출력이 `es` 일 때만 붙인다.

`?vue&type=style&lang.css` 같은 **알려지지 않은 query 는 건드리지 않는다** — 그쪽은 플러그인이 가상 경로로 처리하는 기존 관용구다.
