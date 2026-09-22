---
'@zntc/core': patch
'@zntc/wasm': patch
---

`unsupported` feature 비트마스크가 32비트를 넘어설 수 있게 폭을 넓혔습니다 (#4628 · #4629 선행).

`UnsupportedFeatures` 는 `packed struct(u32)` 에 feature 31개가 들어차 **여유 비트가 1개**뿐이었습니다. `async function*`(#4628)과 public class field(#4629)를 다운레벨하려면 비트가 2개 필요하므로 먼저 폭을 넓힙니다. 기존 feature 의 비트 위치는 그대로라 **계산되는 값은 전부 동일**합니다 (ES 타겟 13종 · RN 0.60~0.90 · 엔진 매트릭스 표본을 main 과 대조해 52/52 바이트 일치 확인).

사용자에게 보이는 변화는 두 가지입니다.

- `zntc.config.json` / JS API / WASM 의 `unsupported` 값 상한이 `4294967295` → `9007199254740991`(JS 안전 정수). 예전에는 2³² 이상을 주면 `invalid options JSON` 으로 거부됐습니다.
- `transpile-options.schema.json` 재생성분에 `externalAlias` 가 포함됩니다 — DTO 에는 이미 있었지만 스키마 재생성이 누락돼 빠져 있었습니다.
