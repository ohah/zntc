---
"@zntc/core": patch
---

인라인되는 dynamic import 의 모듈 방출 순서가 **의존성 역순**이라 TDZ `ReferenceError` 가 나던 버그 수정 (#4520).

```
entry → a → b → barrel → prov       ← 방출 순서 (버그)
ReferenceError: Cannot access 'second' before initialization
```

정적 import 는 post-order(의존성 먼저)로 방출 순서를 정하는데, **인라인되는 dynamic import 는 그 계산에 참여하지 않고** 발견 순서로 뒤에 붙었다. 그래서 동적 진입점 아래 서브그래프가 통째로 역순이 됐다. splitting 과 무관하게 **단일 번들**에서 재현된다.

인라인 dynamic import 를 정적 간선과 같은 방출-순서 계산에 넣어 해결. 빌드 exit 0 · 파싱 통과 · **실행만** 실패하는 계열이라 실행 스모크로 가드했다.
