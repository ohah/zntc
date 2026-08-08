---
"@zntc/core": minor
---

`externalAlias` / `--external-alias:K=V` 추가 — external 로 남는 지정자를 **다른 이름으로 방출**한다 (#4616).

rollup `output.paths` / webpack object-form `externals` 대응. `alias` 와 달리 **해석에는 관여하지
않고** 이미 external 로 확정된 지정자를 출력에 쓸 때만 이름을 바꾼다.

```bash
zntc --bundle src/main.ts --external crypto --external-alias:crypto=crypto-browserify
# → import { x } from "crypto-browserify"
```

브라우저용 shim 을 번들하지 않고 이름만 갈아끼울 때 쓴다. 종전에는 `--external:crypto` 가 원문
`crypto` 를 방출해 브라우저가 해석에 실패했고, `--external:crypto-browserify` 는 external 판정이
원문 기준이라 매칭되지 않고 그냥 번들됐다.
