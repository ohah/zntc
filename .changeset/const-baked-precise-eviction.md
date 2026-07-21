---
"@zntc/core": patch
---

증분(warm) 빌드에서 cross-module const 를 bake 한 소비자 모듈이 **provider 가 바뀌지 않아도 매번 reparse** 되던 perf 회귀 수정 (#4557, B-precise).

## 배경

#4544(crude-b)는 cross-module const 를 AST 에 리터럴로 bake 한 소비자(`m.const_baked`)를 `module_store` 에서 **무조건 evict** → correctness(warm==cold)는 완전하나, provider 불변 시에도 매 warm(프로덕션 증분/watch) 빌드마다 그 소비자를 reparse 했다. cross-module numeric const 사용량에 비례(date-fns 38/304 = 12.5%, 대부분 lib 0).

## 수정 (B-precise)

baked 소비자를 **캐시하되**, 각 소비자가 bake 한 값이 의존하는 **provider 경로 집합**(`const_providers` = canonical + 직접 import 대상)을 기록해 두고, warm 시작 시 `changed_files` 로부터 **전이 fixpoint** 로 provider 가 실제 바뀐 소비자만 evict:

```
dirty = changed_files
repeat: for each cached baked C: if C.const_providers ∩ dirty ≠ ∅: evict(C); dirty += C.path
until no change
```

provider 불변 → cache-hit(reparse 0). 전이 const 체인(`a→b→c`)은 `a` 변경 → `b` evict → `c` evict 로 자연 전파. `changed_files==null`(변경 정보 없음) 이면 보수적 전량 evict(= crude-b, correctness 안전).

`const_providers` 소유권은 `import_specifiers` 패턴을 그대로 미러(Module=parse_arena 소유, CachedModule=store allocator dupe, freeCachedModule 대칭 해제).

## 검증

reparse-count 직접 계측 유닛: provider 불변 warm → baked 소비자 cache-hit(reparse 0, crude-b 는 여기서 reparse), provider 변경 warm → evict/reparse. 전이 체인 fixpoint(warm==cold). 기존 #4544 stale 가드 유지, GPA leak/double-free 0.

## 한계

re-export 다단 체인(중간 barrel 재-export 대상 변경)은 `{직접, canonical}` 만 수집이라 놓칠 수 있음 — 후속(`resolveExportChain` 전체 체인 수집).
