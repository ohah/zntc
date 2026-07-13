---
"@zntc/core": patch
---

코드 스플리팅 + `--minify` 에서 **같은 청크 안의 참조가 자유 변수로 남아** 런타임에 죽던 버그 수정 (#4492).

```
ReferenceError: second is not defined
```

크로스-청크 전역 일관 네이밍(#4101)이 import 참조를 재작성할 때, **소비자가 provider 와 다른 청크인지 검사하지 않았다.** 전역명 맵은 `(canonical module, export)` 키라 "다른 **어떤** 청크가 이 심볼을 소비하는가" 만 말해준다 — 누가 묻는지는 모른다. 그래서 provider 와 **같은 청크**에 있는 소비자까지 그 청크 바깥에서만 존재하는 공개명(`exports.second` 의 좌변)으로 본문을 재작성했다. `minify_identifiers` 로 로컬이 `n` 으로 mangle 되면 `second` 는 선언이 없는 자유 변수가 된다.

형제 호출부(CJS interop / entry exports)는 이미 `isCrossChunkConsumer` 로 게이트하고 있었다 — 본문 참조 rename 과 `importBindingName` 두 곳만 빠져 있었다.

`mermaid` 를 `--minify` 로 번들하면 d3-time 의 `second` 가 정확히 이 형태로 깨졌다. **빌드 exit 0 + 산출물 104개 전부 파싱 통과 + 실행만 실패**라 재파싱 게이트로는 못 잡힌다 — 번들을 실제로 실행하는 스모크를 함께 추가했다.
