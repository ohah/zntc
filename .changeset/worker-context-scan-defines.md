---
'@zntc/core': patch
---

워커의 의존성 탐색에도 define 설정을 전달해 require.context 모드가 define인 경우 파일 목록이 비는 문제와 비활성 분기의 불필요한 context 탐색을 수정합니다.
