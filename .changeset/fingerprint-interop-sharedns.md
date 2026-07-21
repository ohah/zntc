---
"@zntc/core": patch
---

증분(warm) 빌드 emit 캐시의 fingerprint 누락 홀 2종 수정 (#4545) — provider 상태가 바뀌어도 소비자 emit 이 stale 하게 재사용되던 under-invalidation.

## 홀 2 — node/babel interop mode

소비자가 CJS provider 를 `__toESM(require_X(), 1)`(node) vs `__toESM(require_X())`(babel) 로 낮추는데, 이 모드는 provider 의 **첫 importer def_format**(`cjsInteropIsNode`)으로 정해진다. importer-방향 의존이라 dep-방향 Merkle deep-fold 가 못 잡아, 첫 importer 의 def_format 이 바뀌면 그 provider 를 소비하는 다른 소비자가 stale. `emitFingerprint(m)` 에 `wrap_kind == .cjs` 게이트(emit 과 동일)로 interop 모드를 folding.

## 홀 3 — shared-ns 합성 var 이름

`import * as ns` 의 합성 ns var 이름(`t_ns`→`t_ns_2`)은 전-모듈 path 충돌 rank 로 정해지는데 local fp 에 없었다. 충돌 구성(동명-base 모듈 추가/삭제)이 이름을 바꾸면 `ns.member` 참조 소비자가 stale. `sharedNsVarNameHash`(base name + 충돌 rank)를 target 모듈 `emitFingerprint` 에 folding.

## 단조 안전

두 입력 모두 fp 에 **추가만** 하며 graph 상태의 결정적 함수라, 항상 "더 많이 감지"(새 false-hit 불가). SCC back-edge 홀(#4545 홀 1)은 Tarjan 축약 재작성이라 범위 밖(별도).

## 검증

fp-unit(load-bearing: interop flip → provider fp 변화·non-cjs 불변, rank 0→1 → target fp 변화) + warm==cold emit-byte(shared-ns 충돌 후 소비자 재사용) + 기존 #4535 Merkle 가드, GPA leak 0.
