# Module specifier map의 binding identity

`import {map,filter} from 'library'`를 경로별 default import로 분해할 때, 이전 producer는 새 default-specifier 노드를 만들면서 원래 local SID를 전달하지 않았다. 기존 전체 semantic 재분석이 출력 동작을 보완하던 구조이며, 이번 변경은 runtime baseline 오동작을 고쳤다는 주장이 아니다.

분해 producer는 원래 named specifier의 local binding 노드 자체를 default-specifier 역할로 이관한다. 기존 SID, ScopeId, declaration Reference와 source read/export의 SID는 그대로다. semantic 입력이 있는 실행은 node/range/kind/import flag/root Scope를 확인하며 이름으로 ID를 복구하지 않는다. semantic-less 저수준 Transformer 계약은 유지한다. template의 `{name}`에는 identifier StringValue를 쓰고, 실제 binding은 원래 spelling/span을 유지한다.

전체 split group과 trailing-node 저장 공간의 할당이 끝난 뒤 역할을 함께 반영한다. 실패한 할당은 원래 binding tag들을 남긴다. 새 module-source literal은 실제 import AST child로 생성되며 scanner가 정확한 현재 NodeIndex를 graph record에 기록한다.

분해로 문장 개수가 늘어나면 실제 AST containment에서 Reference의 statement 좌표만 다시 계산한다. SID, ScopeId, reference node 또는 flags를 보정하지 않는다. native class-self처럼 별도 declaration leaf가 없는 기존 역할은 initial class-self SID와 그 SID의 현재 class Scope owner를 연결해 좌표를 정한다. 알 수 없는 역할이나 모호한 owner는 재분석으로 되돌아간다.

Map 전용 금지 gate를 제거하되 기존 import 정책은 유지한다. JavaScript import는 원래 elide하지 않으며, nonverbatim TypeScript는 모든 runtime binding에 exact value read가 입증될 때만 graph를 유지한다. type-only/unused elision, Flow, import attributes/phase 및 기존 minifier live-edge 검증 실패는 기존 보수 경계를 따른다. source local-export lists도 exact import SID를 유지한다.

cache의 AST와 semantic ID/reference 배열은 함께 직렬화되고, 복원 scanner가 같은 default binding anchor와 current source record를 재구성한다. owner token은 persist하지 않고 기본 unassigned로 복원한다. codec wire 필드는 추가하지 않았다. 이는 process-owner가 있는 생성 import consumer의 persistent warm reuse나 warm parse 0 완료를 뜻하지 않는다.

검증은 source 10개 before-finish/no-finalizer 대조, JavaScript/TypeScript 각 10개의 graph owner/SID/Scope/statement/cache 대조, malformed identity 10개 및 allocation failure 전수 주입을 포함한다. 최종 runtime/full/compiled mutation 수치는 PR에 기록한다. #4819/#5954 전체 및 implicit ESM strict, TLA, raw export/wrapper reference 잔여는 별도로 유지한다.
