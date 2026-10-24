---
'@zntc/core': patch
---

숫자 상수 전파 후 semantic graph를 유지할 때 새로 접힌 export 초기값의 constant facts를 정확한 선언 SymbolId에 갱신합니다. re-export 체인의 후속 import도 최신 숫자로 인라인됩니다.
