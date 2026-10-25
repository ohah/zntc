---
'@zntc/core': patch
---

using 정리 코드의 try/catch 본문/finally 블록 Scope와 실제 참조를 생성 시점에 연결하고, 이동하는 원본 바인딩·중첩 클로저의 정체성을 같은 semantic graph에서 보존합니다.
