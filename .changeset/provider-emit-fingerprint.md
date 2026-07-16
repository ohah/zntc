---
"@zntc/core": patch
---

증분 emit 캐시가 provider 의 graph-derived emit 상태 변경을 놓쳐 stale 바이트를 재사용하던 버그 수정 (#4535, emit-캐시 층).

## 증상
non-dev 증분 빌드(dev server / NAPI `rebuild()`)에서 **provider 모듈 변경이 소비자의 방출 바이트를 바꿔야 하는데** 소비자가 cache-hit 으로 **옛 바이트를 재사용** → 조용한 오컴파일. 예: 소비자가 import 한 CJS 가 다른 모듈이 `require()` 를 추가해 `wrap_kind` 가 flip 돼도, 소비자 source/mtime 은 그대로라 interop emit 이 옛 형태로 박제. re-export barrel 을 통해 origin 이 심볼을 rename 하면 소비자가 옛 이름을 참조해 `ReferenceError`.

## 루트커즈
`compiled_cache.computeInputHash` 는 소비자 자신의 상태(mtime/source/options/used_exports/import path)만 해시하고, **provider(및 그 전이 dep)의 post-link emit-영향 상태**(wrap_kind·exports_kind·canonical 이름·래퍼명·상수값·export 순서 등)는 안 본다. import record 는 "어디로 resolve 됐나(path)"만 보고 "그 대상이 어떤 wrap/export 인가"는 안 본다.

## 수정 — Merkle deep-fold
- `Linker.emitFingerprint(m)` = 모듈의 **local** emit-영향 상태 해시: Module 필드(wrap_kind·exports_kind·has_cjs_export_signal·can_skip_cjs_default_interop·uses_top_level_await·isInCycle) + 래퍼명(require_/init_/exports_/synthetic) + export 별(exported_name·자기 canonical·자기 const 값), **order-dependent**(export 순서가 소비자 inline namespace object 순서를 바꾸므로).
- `Linker.emitDeepFingerprint(M)` = `local(M) *31 +% Σ deep(dep)` (Merkle) — `import_records` 재귀(require.context 대상은 `rec.context_resolved_paths`→`path_to_module` 로 해석). **re-export barrel 을 통한 origin 의 전이 상태(이름·wrap·star `export *`)를 자동 흡수**한다.
- `computeInputHash` 가 각 resolved import 대상(+ 모듈 **자신**)의 **deep** fingerprint 를 키에 접어 provider 변경 시 소비자 cache miss 를 유발.
- **자신의 fingerprint 도 접음**: 다른 모듈이 `require()` 를 추가해 이 모듈의 wrap_kind 가 flip 되면 자기 source 불변이어도 자기 emit 이 바뀌므로.
- **non-dev 전용**: dev 는 모듈을 registry(path-id)로 래핑해 provider 변경이 소비자 바이트를 안 바꾸므로 stale 재사용이 정답(HMR 핫패스 보호 — emit_fps 빈 slice).
- 사이클: on-stack 재방문 시 local 만 반환해 무한재귀 차단. 깊이 상한(4096)으로 매우 깊은 선형 체인의 native stack overflow 방어.
- `is_included`(tree-shaking)는 증분 경로에서 빌드 간 비결정적이라 fingerprint 제외(provider dead/alive 는 used_export_names + path-set clear 로 커버).

## 범위 / 분리 (별도 이슈)
- **커버**: wrap_kind flip · exports_kind · canonical/래퍼 이름 · export 재정렬 · **named/star re-export barrel 통한 origin rename**. warm≡cold 회귀 가드 4종(wrap_kind flip · named barrel rename · export reorder · star barrel rename).
- **require.context 확장 대상**: `context_resolved_paths`→`path_to_module` 로 fold(구조적 커버). ⚠️ live warm≡cold 가드는 플러그인이 context_resolved_paths 를 채워야 가능해 유닛으로는 미검증(#4538 과 동일 제약) — emitter/forEachWrapperImportTarget 와 동일 해석 경로라 구조적 정확.
- (provider const 값도 local fp 에 접히나, 상수 인라이닝의 실제 stale 는 대개 #4544 AST-mutation 층이 지배 — 그쪽에서 종결.)
- **#4544 (const-materialize AST-mutation)**: `export const N=42` 류 인라이닝은 tree_shaker 가 소비자 AST 를 파괴적 in-place mutation(`z`→`1`)하고 그게 `module_store` 에 남는 **두 번째 캐시 층**. Merkle 이 소비자를 정확히 miss 시켜도 재emit 이 mutated AST 를 써서 여전히 stale — emit-캐시 fp 범위 밖.
- **잔여(비-회귀, 후속)**: 사이클 back-edge 로만 도달하는 전이 provider(완전 정확엔 SCC 축약 필요, #4545); node/babel interop mode(provider 의 importer 방향 의존)·shared-ns var 이름. 모두 **단조 안전**(fp 는 해시 입력을 추가만 → 새 false-hit 불가; 미해시분은 fp 미도입 시와 동일 stale, 회귀 아님).

검증: zig build test 6231/6231 · effect/zod/three cold 빌드 byte-identical(fp 는 compiled_cache 경로 전용) · integration 4247 pass(known flake 2종 제외).
