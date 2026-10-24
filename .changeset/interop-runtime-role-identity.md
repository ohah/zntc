---
'@zntc/core': patch
---

ESM interop 런타임의 helper 및 내부 binding SymbolId를 typed semantic cache에 보존합니다. Module 편의 필드가 초기화되어도 이름으로 ID를 재검색하지 않으며, 필요한 canonical 역할이 사라지면 명시적으로 실패합니다.
