---
'@zntc/core': patch
---

변환 결과의 독립 저장소가 producer에서 선택한 SymbolId를 유지하도록 검사합니다. 출력 후처리가 중복 ID를 새 ID로 나누거나 같은 이름의 var ID로 합치는 동작을 제거하고, 정상적인 var 재선언과 Annex B 함수 별칭은 보존합니다.
