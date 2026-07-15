---
"@zntc/core": patch
---

`--splitting` 에서 CJS/ESM-wrapped **user entry** 모듈이 호출되지 않아 본문이 실행되지 않던 버그 수정 (#4537).

## 증상
entry 가 `require()` 를 써서 `__commonJS` 로 래핑되면(`var require_entry = __commonJS({...})`), `--splitting` 빌드에서 **아무도 `require_entry()` 를 부르지 않아** entry 본문이 통째로 미실행이었다. 빌드 exit 0 · 파싱 통과 · **실행만** 무동작(`node out/entry.js` 가 아무것도 출력 안 함).

## 루트커즈
wrapped entry 호출 emit 이 세 경로의 게이트에 전부 걸려 표준 splitting 에서 어디서도 안 나왔다:
- `dev_split_chunk` — `reg_split`(iife/umd/amd) 한정 + entry 자신은 skip
- `preserveModulesWrapperChunk` — `preserve_modules` 한정
- `reg_split` bootstrap(`__zntc_require`) — iife/umd/amd 한정

단일번들은 맨 끝에서 `require_X()`/`init_X()` 로 entry 를 실행하고(`emitter.zig`), preserve-modules·reg_split 도 각자 호출하는데, **표준 `--splitting`(esm/cjs, 비-preserve-modules)만** 그 호출을 빠뜨렸다.

## 수정
`chunks.zig` 청크 조립부에 단일번들과 대칭인 호출을 추가 — `!reg_split and !preserve_modules and chunk_is_user_entry` 이고 entry 모듈이 wrapped 이면 body 끝에서 `appendModuleCall` 로 호출. reg_split·preserve-modules 는 각자 담당하므로 게이트로 제외(이중호출 방지, `__commonJS`/`__esm` memoize 라 설령 중복돼도 본문은 1회). CJS-format 청크의 TLA(.esm+top-level await) entry 만 제외(top-level await 불가).

esbuild/rolldown 은 entry 를 아예 wrap 하지 않고 scope-hoist 인라인 실행하지만, zntc 는 "entry wrap + 호출" 모델(단일번들·preserve-modules·reg_split 전부)이라 그 모델과 일관되게 splitting 도 호출하도록 맞춘 것 — wrap_kind 분류를 바꾸는 광범위 변경(#4522-4538 campaign 전체)을 피한 저위험 root-cause 수정.

검증: zig 6227/6227 · split-cjs-cross-chunk 19 pass(esm/cjs 가드 2종 추가, 빈 dist 실행 non-vacuous) · 인접 splitting/wrap 145 pass · effect/zod/three --minify byte-identical.

## code-review 반영
- **[3] --minify 변형 추가**: 회귀 가드에 esm/cjs × plain/minify 4종. 호출은 `appendModuleCall` 이 rename_table 로 이름을 풀어 선언측과 일치(minify 래퍼명 `require_entry`→`$c` 축약도 실측 정상). 파일 규약(minify-only 회귀 방지).
- **[4] TLA 가드 통합**: `wrap_kind==.esm and uses_top_level_await` 술어가 세 entry-invoke 지점(dev_split·reg_split·표준 splitting)에 복붙돼 있던 것을 `isTlaEsmModule` helper 로 단일화(각 지점의 컨텍스트별 await-합법성 게이트는 유지).
- **[0] known limitation (범위 밖·무회귀)**: wrapped-CJS entry 를 외부에서 `require()` 로 소비하면 exports 가 청크 module.exports 에 노출되지 않는다(호출 반환값 discard). **단일번들 `--format=cjs` 도 동일**(실측 `result=undefined`) — zntc "wrap entry+호출" 모델의 선재 한계이지 이 수정의 회귀가 아니다. `module.exports=require_X()` 확장은 pm 블록이 경고한 손상 위험이 있어 별도 이슈 #4542.
- **[2] known limitation (범위 밖·무회귀)**: CJS-format + ESM-wrap + top-level await entry 는 top-level await 불가로 침묵 미실행(additive 라 pre-fix 대비 무회귀). esbuild식 async-IIFE 래핑은 별도 기능.

## code-review 반영 (2차)
- **[3] non-vacuity 가드 강화**: `toMatch(/__commonJS|\$c/)` 는 helper 정의·형제 `require_legacy` 래퍼와도 매칭돼 scope-hoist entry 를 진공 통과시켰다. plain 변형에서 entry **자기** 래퍼 `var require_entry =` **선언 + `require_entry();` 호출**을 직접 확인(회귀 시 실패)으로 교체.
- **[4] multi-chunk 가드**: `.js` 파일 >1 assert 추가(청킹 붕괴 시 진공 방지).
- **[1] 별도 선재 버그 발견(범위 밖)**: entry(또는 임의 청크)가 raw `require("./x.cjs")` 하고 그 CJS 가 common chunk 에 안착하면, 소비자 청크가 common chunk 를 side-effect import 만 하고 `require_X` 를 **import 도 export 도 안 해** `ReferenceError: require_X is not defined`. **entry 를 미-wrap 시켜 이 수정을 끈 상태에서도 동적 import 된 비-entry 청크가 동일 크래시** → 내 수정과 독립인 #4494/#4522 계열 raw-require 변종. 별도 이슈 #4541.
- **[2] manualChunks 로 relocate 된 entry(범위 밖)**: entry 모듈을 manual 청크로 옮기면 `chunk_is_user_entry`=false 라 미호출(선재 #4537 하위케이스, 회귀 아님). 리뷰의 "선언/호출 분리 → ReferenceError"는 재현 안 됨(entry 청크 자체가 없어짐). 별도 이슈.

## code-review 반영 (3차, 최종)
- **entry_error_guard parity**: 표준 splitting entry 호출을 `appendModuleCall`→`appendGuardedModuleCall` 로 교체 — 단일번들과 동일하게 `entry_error_guard`(RN/Metro) 활성 시 `__zntc_guarded(require_X)` 로 wrap. guard 비활성(기본)엔 `shouldGuard`=false 라 `appendModuleCall` 로 fallback → **출력 byte-identical**(repro 확인). reg_split/dev_split 은 factory/bootstrap 자체 error 처리라 그대로.
- **테스트 주석 정정**: minify rename 회귀는 `runNode` 가 non-zero exit 시 throw 하므로 "빈 stdout"이 아니라 thrown error 로 드러남.
검증: zig 6227/6227 · split/iife/umd/pm/dev/RN(es5-rn) 인접 127 pass · guard-off byte-identical.
