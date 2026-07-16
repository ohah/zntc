---
"@zntc/core": patch
---

manualChunks 로 relocate 된 CJS/ESM-wrapped user entry 가 `--splitting` 에서 호출되지 않아 본문이 실행되지 않던 버그 수정 (#4542, #4537 하위케이스).

## 증상
`manualChunks` 로 user entry 모듈을 manual 청크로 relocate 하면 `var require_entry = __commonJS(...)` 선언만 남고 `require_entry();` 호출이 없어 entry 본문 미실행. `node manual-entry-*.js` 무출력.

## 루트커즈
청크 배정(chunk.zig:1163)은 **manualChunks 우선 정책**상 user entry 모듈을 manual 청크에 **의도적으로 그대로 둔다** → 그 manual 청크가 곧 그 entry 의 출력(node 가 실행하는 파일)이다. 그런데 #4537 의 entry-invoke 가 "entry 출력 청크"를 `chunk_is_user_entry`(= `chunk.kind == .entry_point`)라는 **프록시**로 판정한다. relocate 되면 청크 kind 가 `.manual` 이라 이 프록시가 실패 → 호출이 안 나온다. 즉 근본은 "entry 가 어느 청크에 있든 그 청크가 그 entry 의 출력"인데 emit 이 chunk.kind 프록시만 봐 놓친 것.

## 수정
`chunk.kind == .entry_point` 라는 **프록시** 대신 "이 청크가 **프로그램 entry 출력**(node 가 직접 실행)인가" 라는 근본 신호를 쓴다. 기존 `chunk_is_user_entry`(비-dynamic `.entry_point`) 에 relocate 목적지인 `.manual` 을 더한 것이 곧 그 신호 — 분류 규칙을 단일 소스로 재사용한다:

```
const chunk_is_entry_output = chunk_is_user_entry or chunk.kind == .manual;
```

그 출력 청크 안에서 `is_entry_point` 인 모듈(build_flow 가 user/emitted entry 에만 설정, **dynamic-import 대상은 false**)을 호출한다. 이렇게 하면:
- **relocate 된 entry**(`.manual`) → 호출 ✓ (#4542)
- **dynamic-import 대상 / plugin `emitFile` on-demand 청크**(dynamic `.entry_point`) → 제외 ✓
- **common 청크** → 제외 ✓ (user entry 는 애초에 안 남음)
- **user entry ∧ emitFile'd 동시**(both-case): `addDynamicEntry` 가 "이미 non-dynamic user-entry면 skip" → 단일 비-dynamic `.entry_point` 청크로 남음 → 호출 ✓ (정확히 1회)

⚠️ on-demand 여부는 **청크** 단위 사실이라, 모듈 플래그 `is_emitted_chunk_entry` 로 제외하면 both-case(user entry 이면서 emitFile 된 모듈)를 **잘못 뺀다**. 그래서 제외를 청크 kind 로 한다. "entry 를 그것이 든 출력 청크에서 호출"이라는 #4537 규칙을 chunk.kind 무관하게 일반화한 것 — 방어 게이트 없이 근본 신호만 사용. reg_split(bootstrap)·preserve-modules(pm_entry_call) 는 각자 담당하므로 게이트 제외.

## 범위 / 후속
이 PR 은 **esm/cjs 경로만** 일반화한다. `/code-review max` 에서 같은 `chunk_is_user_entry` 프록시가 다른 emit site 에도 쓰임이 드러났고, 각자 별도 기계에 묶여 별도 수정이 필요하므로 형제 이슈로 분리:
- **#4548 (reg_split)**: iife/umd/amd 의 invoke(1644)+bootstrap(1676) 도 같은 프록시 게이트 — relocate entry 무출력. factory registry(reg_ids)·federation bootstrapSpan 강결합 동반.
- **#4549 (run_before_main)**: RBM polyfill(477/1021/1093) 도 같은 프록시 — relocate entry 가 polyfill 없이 실행. cross-chunk RBM import·closure 이관 필요. RN/Metro 전용·극드문 조합(#4542 이전엔 entry 미실행이라 가려져 있었음).

⚠️ manualChunks 가 user entry 를 다른 entry 의 dep 와 **같은 청크로 묶으면** 그 청크 로드 시 entry 본문이 실행된다("자기 출력 청크에서 호출"의 일관된 결과, #4537 과 동일 성질) — 비정상 config 의 예측 가능한 귀결.

검증: zig 통과 · manual-chunks #4542 relocate 가드(require_entry() 호출 + node 실행) · 인접 splitting/manualchunks/RN 218 pass. RN fixture 재커밋 금지 준수.

Closes #4542
