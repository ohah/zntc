---
"@zntc/core": patch
---

`--format iife|umd|amd --splitting` 에서 `run_before_main` 모듈이 `manualChunks` 로 다른 청크에 분리되면 entry 청크에 ESM `import` 를 방출해 SyntaxError 나던 버그 수정 (#4552). RBM 모듈을 entry 청크에 **co-locate** 한다.

## 증상
`--format iife --splitting` + `runBeforeMain: ['./setup.js']` + `manualChunks` 로 setup.js 를 별도 청크로 빼면, entry 청크에 `import { init_setup } from "./rbm-chunk.js";` 가 나온다. reg_split 청크는 `(function(g){...})` self-register IIFE 라 top-level ESM import = `SyntaxError: Unexpected token '{'`. 빌드 exit 0 · 실행만 실패.

## 루트커즈
reg_split(iife/umd/amd)은 registry 모델(`__zntc_require`)이라 다른 청크의 RBM 을 근본적으로 실행할 수 없다: 그 RBM 은 `var init_X = __esm({...})` (lazy)로 감싸지고 init 심볼이 factory 스코프 밖으로 안 나온다. 그래서 entry 청크가 (a) ESM `import`(IIFE 서 무효 문법) (b) `__zntc_require`(factory 실행하나 RBM body 미실행) (c) scope 밖 `init_X()` 호출 — 셋 다 깨진다. RBM 은 **entry 앞에서 실행돼야 하므로 애초에 split 되면 안 된다**(Metro 도 runBeforeMainModule 을 번들 최상단에 두고 split 하지 않음).

## 수정 — RBM co-location (reg_split 한정)
chunk.zig 의 manual 청크 배정에서 **run_before_main 클로저를 제외**한다 — dynamic import 대상(#1848/#1849)·user entry(#4553)가 이미 제외되는 것과 같은 방식. `GenerateOptions.run_before_main` + `reg_split` 로 받아 `rbm_modules` set 을 만들고, manual seed 수집(resolver·record)·Phase 2.5 BFS 전파에서 skip. RBM 은 entry 의 dep 로 링크돼 있어(build_flow linkExecutionRoots) 제외되면 entry 청크에 자연히 co-locate 된다. 매칭된 **non-RBM** 모듈은 종전대로 manual 로.
- **reg_split 한정**(iife/umd/amd): esm/cjs 는 cross-chunk RBM 이 valid ESM `import` 로 동작하므로 사용자의 manualChunks 배치를 **존중**(강제 co-locate 안 함). reg_split 아닐 땐 `rbm_modules` 가 비어 exclusion no-op.
- **최상위 RBM 만이 아니라 클로저 전체**: RBM 이 import 한 모듈(transitive static dep)이 manual 로 빠지면 entry prelude(emitter `collectRunBeforeMainClosure`)가 그걸 cross-chunk 참조해 똑같이 깨진다 → RBM 클로저 전체를 제외.
- manual 미설정이면 스캔 자체를 skip.

## 범위 / 후속
- **단일 entry**(RN 전형, RBM 의 실사용): 완전 해결(공유 없음 → RBM 은 entry 청크에만).
- **여러 entry 가 같은 RBM 공유**: RBM 이 `common` 청크로 가는데, zntc 는 1 모듈 = 1 청크라 각 entry 청크로 **복제(co-locate)가 불가** → registry-native(common 청크 eager-run) 필요 → **#4555 후속**. main 에서도 pre-existing(이 수정이 회귀 아님).
- **degenerate 조합**(같은 co-location 한계, #4555 영역): (a) manual 청크의 라이브러리가 app 의 RBM 을 import(entry 스코프 init 심볼 미도달), (b) RBM 이 동시에 `import()` 대상/federation-expose 라 Phase 1b 에서 자기 dynamic 청크가 됨. 둘 다 reg_split 에서 cross-chunk 참조 → 실사용 거의 없음.

참조: Metro `getModulesRunBeforeMainModule` = 번들별 최상단 co-locate(split 안 함). rollup/esbuild 는 run_before_main 개념 없음.

## code-review 반영
- **[reg_split 게이트]**: RBM co-location 은 **reg_split 한정** — esm/cjs 는 cross-chunk RBM 이 valid ESM import 로 동작(테스트가 `node` 실행으로 확인). 처음엔 무조건 제외라 esm/cjs 의 사용자 manualChunks 배치를 무성 무효화했다.
- **[클로저]**: 최상위 RBM 만이 아니라 **transitive static 클로저** 를 제외(emitter `collectRunBeforeMainClosure` 가 prelude 로 끌어오는 것과 일치) — RBM 이 import 한 모듈이 manual 로 빠지면 여전히 cross-chunk break.
- **[DRY]**: `reg_split = (iife|umd|amd) and !preserve_modules` 를 하드코딩하던 4곳(bundler + emitter 3)을 기존 미사용 헬퍼 `Format.isWrappedFormat()` 로 통일 — 청커 게이트와 방출부가 어긋나 초록 빌드로 버그 재발하는 드리프트 차단.
- manual 미설정이면 rbm_modules 빌드 skip.

검증: zig test(chunk_test #4552 co-locate 유닛) · esm/cjs/iife/umd/amd × manualChunks-RBM `node` 실행(`ENTRY sees DEV_SET`, ESM import·별도청크 없음) · 클로저·esm-존중 가드 · 인접 polyfill-rbm/manual-chunks/splitting 통과.

Closes #4552
