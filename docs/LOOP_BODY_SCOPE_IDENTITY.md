# 루프 본문 생성 시의 lexical owner

for-of, 상태 기계용 for-in, for-await의 공통 본문 producer는 새 block 노드와 Scope를 먼저 생성합니다. iterator 값 읽기 등 생성 Reference는 처음부터 그 Scope에 연결합니다. for-in/for-await의 본문 읽기도 ID만 별도 메타데이터에 남겨 finish에서 등록하지 않고, 실제 Reference 행을 즉시 생성합니다. 생성 값의 실제 식별자 참조를 검사하는 validator는 ID·Reference·계획된 Scope 누락을 거부하며 보정하지 않습니다. 헤더에서 가져온 기존 lexical binding과 그 초기화/대입 Reference를 정확한 ID로 새 본문 Scope에 연결합니다. 함수 소유의 var 저장소는 유지합니다.

원본 본문 block을 펼치면 기존 Scope owner 노드가 실제 출력에서 사라집니다. producer는 원본 block을 실제 자식으로 보존하고, 그 ScopeId를 유지한 채 새 본문 Scope 아래로 부모만 바꿉니다. 상태 기계의 for-of는 현재 방문 커서 대신 보존된 operation Scope를 사용하고, 임시 변수의 저장소는 별도의 정확한 wrapper Scope를 사용합니다. 추출 함수와 매개변수의 ID가 생성되면 실제 본문만 먼저 이관하여 중첩 변환이 새 저장소를 볼 수 있게 합니다. 원본 루프 헤더와 호출 지점의 Scope는 보존합니다. 콜백 조립에서는 그 실제 AST 영역의 Scope owner를 기준으로 사라진 본문 부모만 제거하고, 유지된 생성 블록의 부모 관계는 보존합니다. 헤더 초기화 식의 클로저와 import expression provenance도 같은 producer에서 이동합니다. 이름이나 출력 위치를 이용하여 ID를 복구하지 않습니다.

직접 검사는 서로 다른 14개 source를 각각 독립된 Zig test로 실행합니다. 각 test는 for-of, for-in, for-await 세 경로를 전체 방문/finish 전에 호출합니다. 본문 노드 도달성, 실제 Scope 부모, 원본 block ScopeId 보존, lexical/var 저장소, 기존 SID, 실제 Reference Scope, 중첩 클로저 부모와 import provenance를 확인합니다. 원래 구현에서는 14개 test 모두 실패합니다.

실행 비교는 11개 원본 프로그램에 대해 for-of/for-await, 5개 target, single/bundle, plain/minify의 440개 CLI 입력과 native API transpile/buildSync의 176개 입력을 사용합니다. 원본 Node 출력과 비교하며 실패 예상으로 입력을 제외하지 않습니다.

이 변경은 공통 본문 producer만 다룹니다. iterator cleanup의 다른 try/catch/finally wrapper와 for-in의 다른 생성 owner, 상태 기계의 다른 수명/Scope 보정은 별도 완료 조건으로 남습니다. #4819/#6193 전체 완료를 뜻하지 않습니다.
