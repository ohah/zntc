# PERF — Sampling Profiler 측정

ZNTC 의 wall time hotspot 을 sampling profiler (`samply`) 로 격리하는 절차.
ZNTC 자체의 `--profile` 인프라는 phase·sub-phase 단위 wall 누적을 보여 주지만,
호출 빈도가 큰 hot path 함수에서는 `std.time.Timer` 의 read 오버헤드가 self time 을
부풀려 dominant 영역을 흐린다 ([[feedback_profile_self_timer_artifact]] 참고). 함수
단위 self time 의 정확한 분포가 필요할 때 본 절차를 쓴다.

## 전제

* macOS / Linux. Windows 는 `samply` 가 ETW 백엔드를 쓰며 별도 검증 안 됨.
* `samply` 설치 — `cargo install samply` 또는 `brew install samply`.
* macOS 는 `dsymutil` 필요 (Xcode CLT 에 포함).

## 빌드

`-Dkeep-debug=true` 를 주면 ReleaseFast 빌드에서도 DWARF 가 보존돼 samply 가
함수명을 해석할 수 있다. 기본값은 `false` 라 프로덕션 배포 결과물에는 영향이 없다.

```sh
zig build -Doptimize=ReleaseFast -Dkeep-debug=true
# macOS 만:
dsymutil zig-out/bin/zntc
```

## 측정

`scripts/profile-parse-samply.sh` 가 빌드 + dsymutil + samply record 를 한 줄로
처리한다. 기본 fixture 는 `tests/benchmark/node_modules/node_modules/typescript/lib/typescript.js`
(약 9MB, 단일 파일 transpile 의 worst-case 워크로드).

```sh
scripts/profile-parse-samply.sh                                       # 기본
scripts/profile-parse-samply.sh path/to/fixture.ts 5 4000              # fixture, iters, rate(Hz)
ZNTC_SAMPLY_OUT=./profile-out scripts/profile-parse-samply.sh          # 출력 디렉토리 변경
```

iteration 수가 늘어날수록 sample 수가 늘고 noise 가 줄어든다. 이론적 상한은
`iter × rate × wall_ms / 1000` 이지만 실제는 thread sleep / I/O wait / sampler
드롭 때문에 그보다 적다 — 5 iter × 4kHz × ~170ms wall 의 *이론 ~3,400 sample*
이 typescript.js 9MB 에서 실측 ~1,600~2,500 정도 잡힌다. 회귀 비교용으로는 이
정도면 충분하다.

## 분석

```sh
python3 scripts/analyze-samply.py /tmp/zntc-samply                     # 기본 디렉토리
python3 scripts/analyze-samply.py /tmp/zntc-samply --top 20             # top 20 만
python3 scripts/analyze-samply.py /tmp/zntc-samply --filter Scanner    # Scanner 만
```

함수별 self count (leaf-frame 기준) 와 inclusive count (스택 어디든 등장) 표가 나온다.
self 가 진짜 hotspot 지표, inclusive 는 caller chain 파악용.

UI 가 필요하면 Firefox profiler:

```sh
samply load /tmp/zntc-samply/profile.json.gz
# localhost:3000 에 Firefox profiler 열림
```

## 측정 예시 (main d0fe8e10, typescript.js 9MB, 5 iter × 4kHz)

총 1,621 sample 기준 top self:

| 순위 | self% | 함수 |
| ---: | ---: | --- |
| 1 | 15.05% | `lexer.scanner.Scanner.next` |
| 2 | 14.74% | `_platform_memmove` (libsystem_platform) |
| 3 |  4.75% | `transformer.node_dispatch.visitNodeInner` |
| 4 |  4.32% | `codegen.node_dispatch.emitNode` |
| 5 |  4.26% | `bundler.resolver.DirEntryCache.HashMap.getIndex` |
| 6 |  3.58% | `lexer.scanner.Scanner.skipWhitespace` |
| 7 |  3.27% | `parser.ast.Ast.addNode` |
| 8 |  2.90% | `semantic.analyzer.SemanticAnalyzer.visitNode` |
| 9 |  2.16% | `lexer.scanner.Scanner.scanIdentifierTail` |

Scanner family (next + skipWhitespace + scanIdentifierTail + parser.advance) 합계
약 22% self — ZNTC `--profile` 의 `scan` phase 표시 (24%) 와 비슷하지만, 본 데이터는
`parse` phase 안에서 호출되는 lex 비용까지 포함하므로 `parse` 의 dominant 도
사실 Scanner 임을 보여 준다.

`parse.expression.assignment` `self time` 이 `--profile-level=detailed` 에서 45ms 로
크게 잡히는 부분은 대부분 timer 오버헤드이고, 진짜 parser 함수 self 는 합쳐도 ~6%
수준 (parseAssignmentExpression / parsePrimaryExpression / parseBinaryExpression /
parseCallExpression / parseStatement 각 1% 안팎). 이 결론은 호출-빈도 큰 scope 의
self time 절대값을 ROI 근거로 쓰지 말라는 기존 ([[feedback_profile_self_timer_artifact]])
가이드와 같은 방향이다.

## 회귀 비교

PR 머지 전후로 동일 절차로 두 번 측정한 뒤 `diff <(analyze A) <(analyze B)` 또는
top N self 표의 함수별 비율 차이를 확인한다. sample noise 가 5~10% 정도라 1% 미만
변화는 신호가 아닐 가능성이 높다 — 회귀 게이트는 typescript.js 9MB wall median
(`zntc --profile=all` 의 `wall:` 줄) 5회 median ±5% 정도를 기준으로 잡는 게 안전.

## 알려진 함정

* macOS: `dsymutil` 를 빠뜨리면 함수명이 `<0x…>` 만 나온다. 스크립트가 자동 수행하지만
  수동 빌드 시 주의.
* `--unstable-presymbolicate` 옵션은 samply 의 미정안정 API (samply ≥0.12). 향후
  버전에서 sidecar 대신 profile 에 통합될 수 있다. 그 때는 `scripts/analyze-samply.py`
  의 `build_addr_map()` 가 그대로 깨질 가능성이 있어 수정 필요.
* `analyze-samply.py` 는 `known_addresses` 의 union 으로 RVA→함수 매핑을 만든다.
  samply 가 `frameTable.nativeSymbol[]` 를 비워둔 채 sidecar 로 분리해 두기 때문에
  frame 단위 lib 식별이 불가능 — 이론적으로 lib 간 RVA 충돌 시 마지막 lib 의 이름이
  덮어쓴다. 실측에선 충돌 0건 (1,500개 unique address) 이지만, 스크립트가 충돌을
  탐지하면 stderr 로 경고하고 영향 받은 RVA 를 표시한다.
* Linux: dSYM 대신 `.debug` 섹션이 in-binary 로 들어가 자동 인식. `dsymutil` 단계는
  스크립트가 macOS 에서만 실행.
* 동시 실행 / CI A/B 비교 시 기본 출력 디렉토리 `/tmp/zntc-samply` 가 충돌한다.
  `ZNTC_SAMPLY_OUT=./out-A scripts/profile-parse-samply.sh` 처럼 분리할 것.
* 첫 iteration 은 파일 시스템 캐시 cold 영향이 크다. 스크립트가 warmup 1회를 자동 수행.
