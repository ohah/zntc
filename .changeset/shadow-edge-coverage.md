---
"@zntc/core": patch
---

#4533(주입된 래퍼 참조가 소비자 스코프 바인딩에 가려짐)의 **edge 모드** 커버 (#4538).

#4533 은 cold 공통 케이스를 닫았고, 근본 원인(zntc non-minify 리네이머가 scope-0 중심)의 잔여 edge 를 여기서 메운다.

## 1. 런타임 헬퍼명 shadow — ESM 소비자 **scope 0**(top-level)
ESM 소비자가 CJS 를 import 하면 `__toESM(require_x())` 가 소비자 scope 0 에 주입되는데, 예전엔 스캔이 ESM 소비자의 scope 0 을 건너뛰어(래퍼명은 #4530 예약이 담당) 사용자의 top-level `function __toESM(){}` 이 가려졌다 → `TypeError`. 이제 소비자 **전 스코프**(0 포함)를 대조한다 — 래퍼명은 skip-guard(#4530 이 이미 개명)로 no-op, 헬퍼명만 새로 커버.

## 2. `require.context` 로 도달하는 래퍼
소비자 스캔이 `rec.resolved` 만 따라가 `require.context` 매치 모듈(`context_resolved_paths` 로 해석, `rec.resolved`=none)을 빠뜨렸다. 이제 emitter 와 **동일 경로**(`context_resolved_paths`→`path_to_module`→`getModule`)로 그 래퍼도 검사한다.

## 3. HMR/incremental warm 재빌드 fingerprint
`resolveWrapperConsumerShadows`(#4533)는 CJS 소비자의 scope 0(클로저 지역)도 개명하는데, `moduleFingerprint`(G2)는 CJS scope-0 사용자 로컬을 제외한다 → warm 재빌드에서 scope-0 shadow 바인딩이 새로 생겨도 fingerprint 불변 → stale snapshot 재사용 → shadow 재출현. CJS scope-0 이름을 fingerprint(G5)에 접어 넣어 그 변화를 잡는다.

## 범위
- 커버: 위 3종(전부 code-review max CONFIRMED). ESM scope-0 헬퍼는 통합 가드, fingerprint 는 renameReuseGuard 단위 가드(둘 다 비-공허 확인).
- **미해결(장기)**: HMR rename-reuse 스냅샷이 nested rename 시 통째 폐기돼 warm 이 full 재계산으로 떨어지는 **perf** 저하(정확성 유지). 근본 처방=non-minify 에도 mangler급 scope-aware 리네이머(#4538 원 이슈에 기록).

검증: zig build test 6226/6226 · effect/zod/three --minify byte-identical(size 0).

## code-review 반영 (2차)
- **[0] fingerprint 상쇄 버그**: CJS scope-0 fold 를 nested(0xc0)와 **다른 seed(0xc1)** 로 — 같은 seed·같은 누산기면 이름이 scope-0↔nested 로 **이동**할 때 상쇄돼 fingerprint 불변(stale reuse). unit 가드 추가(비-공허 확인).
- **[3] fold 과잉무효화**: `moduleImportsWrapped` 게이트 추가 — wrapped import 가 있는 CJS 모듈만 scope-0 을 fold(안 그러면 shadow 불가능한 CJS 편집마다 warm reuse 상실).
- **[1] require.context per-chunk 예약**: computeRenamesForModules 의 참조측 예약이 `require_context` 레코드(rec.resolved=none)를 빠뜨려 pickConsumerShadowName 후보가 형제 래퍼와 겹칠 수 있던 것 — context_resolved_paths 도 reserveWrapperNames.
- **[5] require.context __toESM 과잉**: emitter 는 context 자리에 __toESM 을 안 주입 → deconflictConsumerShadows 에 `inject_to_esm` 플래그로 제외.
- **[4]** forEachNestedBindingName docstring 갱신(fold 로 G5 가 상위집합인 게 의도임을 명시).

⚠️ require.context 경로는 **플러그인이 매치를 해석**(context_resolved_paths)해야 채워져 플러그인 없는 통합 테스트로는 라이브 검증 불가. fix 는 emitter.zig 의 주입 경로와 **대칭**(동일 context_resolved_paths→path_to_module→getModule)이라 정확성은 구조적으로 보장.

## code-review 반영 (3차)
- **[0] require.context `__toCommonJS` shadow**: dev 단일번들 require.context codegen 은 대상 wrap_kind 무관하게 매치마다 `(__zntc_modules[id].fn(), __toCommonJS(__zntc_modules[id].exports))` 를 찍어 `__toCommonJS` 를 **항상** 주입한다. names 배열은 `__toCommonJS` 를 esm 에만 넣어 CJS require.context 대상의 `__toCommonJS` shadow 를 놓쳤다 → `via_context` 플래그로 context 자리엔 `__toCommonJS` 항상(·`__toESM` 제외).
- **[1] 중복 walk 통합**: require.context 대상 열거가 fingerprint 게이트·shadow rename·per-chunk 예약 3곳에 복붙돼 있던 것을 `forEachWrapperImportTarget` **단일 iterator** 로 묶음(드리프트 방지 — 이 레포 단골 루트커즈).

## code-review 반영 (4차, 최종)
- **죽은 방어 가드 제거**: `deconflictConsumerShadows` 진입부의 `.none && synthetic==null` 재검사는 유일 호출 경로인 `forEachWrapperImportTarget`(위 [1] iterator)가 이미 pre-filter 하므로 항상 false → 제거하고 `.none` 판단을 iterator 한 곳으로 통일(통합 목적과 정합). 동작 무변경.
