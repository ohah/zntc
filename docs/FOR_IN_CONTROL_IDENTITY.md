# for-in 수집·제어 참조의 생성 시점 identity

상태 기계용 `rewriteForIn`은 실제 wrapper block과 native key-collection for-in 노드를 먼저 만들고 Scope를 연결한다. 수집 루프의 키 대입·객체 읽기·push 인수, 실제 반복 루프의 비교·증가·본문 값 읽기를 각각 실제 Scope와 read/write flag로 즉시 등록한다. SID만 별도 map에 남기고 마지막 출력 walk에서 Reference를 만드는 경로는 사용하지 않는다.

원 반복문 ScopeId는 출력 for 노드에 명시적으로 이어 붙인다. 복사한 입력도 `outputOwnedScope`에서 정확한 owner를 받으며 방문 커서로 추측하지 않는다. 기존 원본 binding/reference의 SID와 함수 var 저장소는 유지한다. iterable 식의 기존 참조·import provenance와 함수 frontier는 wrapper 초기화 위치로 옮긴 뒤 원 루프의 부모를 wrapper 아래로 바꾼다.

`loop_scope_producer.zig`는 for-in/for-of/for-await의 실제 블록 생성과 입력 식 이관을 공유한다. for-await에서 검증한 부모 변경 전 frontier 이동 규칙을 그대로 사용한다. 블록 목록은 extra_data 추가가 끝난 뒤 실제 destination slot에 게시한다.

서로 다른 11개 source를 원본/복사된 입력 두 모드에서 visit/finish 전에 검사한다. stale traversal cursor, 실제 collector/iteration owner와 부모, 원 SID, 함수 저장소, 모든 생성 참조의 Scope/read/write, import provenance를 확인한다. 네 임시 변수의 실제 AST binding에서 ID를 가져와 읽기/쓰기 Reference 수 `[1,3,2,3]`와 symbol reference_count도 독립 대조한다. 원본 producer는 11개 test가 모두 실패한다.

실행 비교는 서로 다른 10개 프로그램의 sync/async generator, target·minify·bundle/API 조합을 원본 Node와 대조한다. inherited key, Object shadow, closure·shorthand key, var 저장소, assignment head, 단일 본문, shadowing, labeled continue와 RHS 평가를 포함한다. 최종 수치는 PR 본문에 기록한다.

for-of의 다른 iterator cleanup 생산자, generator 후속 조립의 소유자 이관, 다른 helper 생산자 및 일반 final output walk의 남은 보정과 post-transform analyzer 제거는 별도 잔여다. 이 변경은 #4819/#6193 전체 완료가 아니다.
