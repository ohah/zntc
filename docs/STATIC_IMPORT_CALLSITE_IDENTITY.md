# 단일 출력 named CJS import의 실제 호출 참조

이 단계는 wrapped ESM 소비자(`wrap_kind == .esm`)가 CJS 모듈에서 가져오는 non-default named import를 실제 AST/Reference로 전환한다. #4819/#5954/#6193 전체 완료를 뜻하지 않는다.

## 기존 문제와 실행 결과

`consumer.mjs`가 `import {call, value} from './dep.cjs'` 뒤 `export function run(){return [call(),value]}`를 내보내고, entry가 이를 dynamic import하는 경우다. dependency는 실행 횟수를 증가시키고 `call`은 strict 함수에서 `this === undefined`를 반환한다.

- native: `1 [true,42]`
- 이전 문자열 expression rename: `undefined [false,42]`
- 실제 initializer/callee AST: `1 [true,42]`

기존 `require_dep().call()` expression rename은 함수 호출 receiver를 바꾸며, wrapped 소비자의 dependency 실행도 최초 binding read까지 미룬다. 새 경로는 소비자 초기화 AST에 실제 require 호출을 두고, binding read를 `(0, require_dep()["call"])` AST로 바꾼다. 최종 이름은 이미 선택한 foreign require SID의 rename 결과를 사용한다.

## 소유권과 처리 경계

- `static_import_callsite.zig`: 현재 import specifier의 exact local NodeIndex→SID와 scanner가 보존한 original binding anchor의 SID를 연결한다. scope-map/local spelling/cached local SID로 binding을 재선택하지 않는다. supported anchor가 없거나 record 범위가 잘못되면 `InvalidCallsiteBinding`을 반환한다.
- source Reference는 현재 semantic snapshot의 SID로 한 번 분류한다. 각 새 callee Reference는 그 source Reference의 실제 ScopeId에서 생성한다. generic 출력 walk로 scope를 고치지 않는다.
- `runtime_callsite_builder.zig`: module arena에서 실제 local import binding SID, declaration AST, import record, foreign role/SID/owner handle을 생성한다. 배열 확장은 amortized capacity를 유지한다. target 검증은 `runtime_callsite_targets.zig`의 known role 슬롯과 비교하며 이름 검색으로 복구하지 않는다.
- compiler import record는 binding-only edge이며 `callsite_lowered=true`로 생성한다. strict-order/async-cone metadata의 eager loop가 별도 raw initializer를 만들지 않는다. 그렇지 않으면 wrapped 소비자의 내부 dynamic import가 `run / dep / 42` 대신 `dep / run / 42`로 실행되는 기존 결함이 있었다. CJS/ESM target을 실제 실행으로 대조한다.
- 기존 source Reference는 일괄 제거한다. 원래 source import declaration을 program에서 제거하고, source record의 `callsite_lowered`를 표시한다. `linker/metadata.zig`는 이 source record의 raw preamble와 expression rename을 모두 생략한다. 생성한 compiler import는 기존 exact-target 분기를 사용한다.
- program owner는 새 root로 명시 이관하며 editor finish 결과와 transform-cache ID 배열을 동일 snapshot으로 갱신한다. 두 번 semantic analysis를 실행하지 않는다.

## 검사

세 unit test는 source context 10개, poisoned state 10개, mixed dependency 6개를 실행한다. 별도 AST owner walk로 live callee Reference의 ScopeId를 확인하며, 원래 import declaration/Reference가 남지 않는지도 확인한다. ES5 parameter/class/optional-call 변형을 포함한다. Node 실행 oracle은 dependency 실행 시점과 strict callee receiver를 함께 검사한다.

외부 실행 행렬은 source 10개 × ES5/ES2017 × ESM/CJS/IIFE × 일반/전체 압축 120개다. 원래 CLI의 동일 source 10개는 모두 native와 불일치했고, 새 CLI의 120개는 native와 일치한다. compiled mutation 및 최종 통합 결과는 PR에 별도로 기록한다.

## 유지한 잔여

- 첫 경로는 단일 출력 provider admission 안에서만 열린다. inlineRequires/Metro의 의도된 lazy 실행은 기존 경로를 유지한다. 기존 RN named-import ordering control을 함께 실행한다.
- 다른 user eager import가 raw 경로에 남아 있으면 해당 소비자 모듈 전체를 전환하지 않는다. mixed prefix의 bare B→named A에서 기존 정상 `B,A`가 `A,B`로 바뀌는 실제 회귀를 확인했다(plain/min). planned record와 exact compiler/helper record만 함께 허용하며, 다른 user eager record는 source-order typed handoff 후에 전환한다.
- mixed default/namespace/bare 3종 × source 순서 2종 × 일반/압축 12셀을 native/이전/새 출력으로 대조한다. consumer body effect가 있는 12셀도 별도로 실행한다. 기존 raw 순서 실패는 기존 debt로 유지하며 보호 gate의 회귀 방지를 별도로 검사한다.
- 일반 unwrapped 소비자의 snapshot 변수, namespace/default/bare import, reexport, shorthand/object-property 사용, source-phase/defer/attribute import, helper binding은 후속 실제 caller 전환 대상이다. 지원 범위에서 제외했다는 이유로 A 완료에 포함하지 않는다.
- foreign CJS wrapper 자체의 생성 Scope/Reference와 raw emitter는 이 단계로 제거되지 않는다. split/preserve/HMR도 기존 미완료 gate를 유지한다.
- compiler import가 있는 소비자는 기존 process-owner cache eviction 정책을 따른다. owner-linked persistent warm reuse는 아직 완료하지 않았으며 warm parse 0을 주장하지 않는다. 새 wire field나 codec 버전 변경은 없다.
- dynamic phase의 기존 DCE 5개 및 실제 TLA 4개 실패는 별도 잔여다. 이 named 경로의 통과 수에 섞지 않는다.
