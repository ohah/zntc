---
"@zntc/core": patch
---

`manualChunks` 가 user entry 모듈을 manual 청크로 **relocate 하지 않도록** 변경 — user entry 는 항상 자기 entry_point 청크에 유지된다(rollup/esbuild 불변식). `--splitting` + `manualChunks` 로 entry 를 옮기면 실행이 깨지던 버그 계열(#4542/#4548/#4549/#4551)을 **근본 원인**에서 제거.

## 배경 — 왜 화수분이었나
예전엔 `manualChunks` 패턴이 entry 를 매칭하면 그 entry **모듈 자체**를 manual 청크 안에 넣었다(chunk.zig 의 "manual 우선" 정책). 그런데 emit 파이프라인의 **십수 개 site** 가 "user entry 는 자기 `.entry_point` 청크에 산다"는 불변식(`chunk_is_user_entry` / `entry_mod_idx`)에 의존한다: 표준 entry-invoke, reg_split bootstrap·보편 wrapper, `"use client"` directive 호이스팅, `run_before_main` polyfill, dev HMR runtime, dev_split 선-init… entry 를 옮기면 이 전제를 쓰는 모든 곳이 하나씩 깨졌고, 파이프라인 전역에 흩어져 있어 **고칠수록 다른 코너에서 새 버그가 나왔다**(리뷰 라운드마다 서로 다른 서브시스템). rollup/esbuild 는 애초에 entry 를 relocate 하지 않아 이 버그 클래스가 존재하지 않는다.

## 수정 — entry 는 옮기지 않는다
chunk.zig 의 manual 청크 배정에서 **user(비-dynamic) entry 를 제외**한다 — dynamic import 대상(#1848/#1849)이 이미 제외되는 것과 정확히 같은 방식:
- **manual seed 수집**(resolver·record 경로): user entry 는 seed 로 안 넣는다. resolver 함수는 **여전히 호출**해 `getModuleInfo` 등 inspection hook 부작용은 보존하되, entry 의 배정 결과만 무시한다.
- **Phase 2.5 BFS 전파**: user entry 에는 manual bit 를 안 세운다(vendor seed 의 transitive dep 로 도달해도 차단, entry 를 통한 dep 전파도 중단).
- **Phase 4 강제 이동**: user entry 는 위 seed/전파에서 manual bit 를 못 받으므로 애초에 manual 청크에 배정되지 않는다 → Phase 4 에서 자기 entry_point 청크로 이동. (Phase 4 의 "manual 이면 그대로 유지" 예외는 **유지** — 이제 그건 dynamic import 대상이 manual seed 의 static dep 로 전파돼 흡수된 경우만 보호. 그걸 도로 빼내면 cross-chunk ReferenceError.)
- **warn**: `manualChunks` 가 entry 를 매칭하면 "entry 는 relocate 되지 않고 자기 청크에 유지됩니다" 경고(rollup 관례).

matched 된 **non-entry** 모듈은 종전대로 manual 청크로 간다. entry 만 매칭한 manual 청크는 비어서 생성되지 않는다.

## 효과
- `--format esm|cjs|iife|umd|amd --splitting` + `manualChunks` 가 entry 를 매칭해도 entry 는 표준 경로로 정상 실행(무출력/SyntaxError 없음).
- #4542(esm/cjs relocate 미실행), #4548(reg_split relocate 미실행), #4549(RBM 미emit), #4551(umd export 값) 이 **전부 해소** — entry 가 안 움직이니 인프라가 흩어질 일이 없다. #4552(reg_split RBM cross-chunk ESM import)는 relocate 와 무관한 pre-existing 이라 별도.
- #4542 가 도입했던 emit-side 일반화(`chunk_is_entry_output` +manual 스캔)는 이제 불필요 → `chunk_is_user_entry` 로 원복(both-case 처리 위한 is_entry_point 스캔만 유지).

## 참조 번들러
rollup/esbuild 모두 `manualChunks`/`splitting` 에서 entry 모듈을 relocate 하지 않는다(entry 는 항상 자기 출력 파일). 이 변경으로 zntc 도 동일 불변식을 따른다.

검증: zig test(chunk_test #4553 유닛 가드 + 전체) · manual-chunks/splitting/reg_split/MF integration · esm/cjs/iife/umd/amd × (entry-only 매칭 / entry+vendor 매칭) `node` 실행 · 통합 4255 pass.

(#4542 는 PR #4550 으로 이미 close — 이 변경은 그 emit-side 접근을 원복하고 근본을 chunk.zig 로 옮긴다.)

Closes #4553
Closes #4548
Closes #4549
Closes #4551
