---
title: Incremental rebuild benchmark guide
description: zntc 의 watch / HMR rebuild 측정 가이드. incremental rebuild 재설계 epic 의 ROI 입증용.
---

zntc 의 `--profile=*` 인프라로 watch mode rebuild 측정. 결과는 incremental rebuild
재설계 epic 의 ROI 분기 결정에 사용.

## 측정 명령

### 1. cold + warm build phase 측정

```sh
ZNTC_PROFILE=parse,semantic,graph_discover,graph_build,graph_finalize \
  zntc --bundle src/main.ts -o dist/bundle.js
```

stderr 로 phase 별 totalNs / count 출력. cold (첫 build) 의 parse + semantic 합계가
total 의 몇 % 를 차지하는지 확인.

### 2. watch mode 의 incremental rebuild 측정

```sh
ZNTC_PROFILE=parse,semantic,graph_discover \
  zntc --watch --bundle src/main.ts -o dist/bundle.js
```

dev server 가 source 변경 감지하면 rebuild — 그 시점의 phase 별 ns 가 stderr 로
출력. 다른 터미널에서 `touch src/some-file.ts` 또는 1-line 편집 후 측정.

## ROI 분기 임계 (재설계 epic 진입 결정)

| 메트릭 | 시나리오 A (재설계 진입) | 시나리오 B (epic 폐기) |
|---|---|---|
| cache hit률 = `(total_modules - reparsed) / total_modules` | ≥ 80% | < 50% |
| parse + semantic ns 합 / total build ns | ≥ 20% | < 10% |
| graph_discover ns / total build ns | ≥ 30% | < 15% |

**시나리오 A**: incremental cache hit 률 높고 parse/semantic 이 dominant — *ModuleData path-keyed cache* 분리가 진짜 절감 효과.

**시나리오 B**: cache miss 많거나 parse/semantic 비중 작음 — *재설계 ROI 부재*, 다른 병목 우선 (resolve, source read, applyScanResult).

## 측정 보고 형식

issue 또는 PR comment 에 다음 형식으로 보고:

```
Project: <name>
Modules: <total>
Cold build (ns):
  parse:      <X>
  semantic:   <Y>
  discover:   <Z>
  total:      <T>
  parse+sem%: <(X+Y)/T*100>%

Watch rebuild (1-line edit, leaf module):
  reparsed modules: <N> / <total>
  cache hit률: <100*(total-N)/total>%
  parse:      <X'>
  semantic:   <Y'>
  discover:   <Z'>
  total:      <T'>
```

## 본 가이드의 위치

incremental rebuild 재설계 epic 의 PR-0 산출물. 데이터 수집 후 epic 진입/폐기 결정.
