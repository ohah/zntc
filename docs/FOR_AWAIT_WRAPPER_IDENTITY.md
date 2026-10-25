# for-await 제어·정리 구문의 생성 시점 identity

`rewriteForAwait`는 실제 출력 wrapper, try body, catch clause/body, finally와 rethrow block을 먼저 생성하고 정확한 ScopeId를 연결한다. 그 뒤 iterator/step/return/error 임시 변수 참조와 helper 호출을 각 실제 lexical Scope에서 생성한다. catch binding은 함수 var 저장소가 아닌 실제 catch Scope에 한 번만 선언한다. SID를 먼저 부착하고 별도 edge API로 뒤늦게 연결하던 이 경로는 필요 없으므로 사용처가 사라진 내부 API도 제거한다. 임시 변수 저장소는 lexical 참조 Scope와 구분해 원래 함수/상태 기계의 var Scope를 유지한다.

iterable 식을 새 wrapper의 초기화로 옮길 때 기존 Reference의 SID와 읽기/쓰기 flag는 유지하고, 원래 루프 Scope에서 직접 평가되는 참조 및 import provenance를 명시적으로 이동한다. 식 안의 함수는 고유 ScopeId를 유지하며 lexical frontier만 이동한다. 이 이동을 루프 자체의 부모 변경보다 먼저 수행한다. 그렇지 않으면 기존 frontier helper가 이미 새 wrapper의 하위에 들어간 함수를 이동 대상으로 보지 못한다. 이름·소스 위치로 심볼을 다시 찾지 않는다.

생성한 실제 while은 원본 loop ScopeId를 이어받고 try body 아래에 놓인다. native generator 안에서는 실제로 남는 wrapper/try-body Scope owner를 유지한다. 제너레이터 후속 조립에서 사라지는 소유 노드와 참조 이관, runtime helper의 다른 생산자 및 일반 final output walk의 나머지 보정은 별도 잔여다. for-in/for-of의 다른 제어·정리 참조도 이 변경에 포함하지 않는다. 이 문서는 #4819/#6193 전체 완료를 뜻하지 않는다.

직접 검사는 11개 서로 다른 원본 입력을 일반 lowering/상태 기계 수집 두 모드에서 호출하고, visit/finish 전에 실제 block/catch/while owner, 부모, catch kind, var 저장소, 생성·기존 참조의 SID/Scope/read/write 및 import provenance를 대조한다. static property 이름은 Reference가 아니므로 AST edge를 구분하는 reference walk를 사용한다. 직접 실행 비교는 10개 프로그램의 정상 종료, break/return/throw, next/return getter/close 거절, 중첩 루프, shadow/closure 및 labeled continue를 원본 Node와 비교한다. 일반 async function과 async generator를 모두 포함한다. 최종 검증 수치는 PR 본문에 기록한다.
