# ZTS Backlog

구현 중 발견된 개선 사항을 추적한다. 해결된 항목은 제거.

---

## 성능 최적화 (SIMD/프로파일링 후)

| # | 항목 | 비고 |
|---|------|------|
| 1 | `Span`에 `source_id` 추가 (multi-file) | 번들러에서 필요 |
| 4 | `StaticStringMap` → perfect hash 최적화 | 프로파일링 후 |
| 5 | scan* 함수 테이블 기반 통합 | 구조 리팩토링 |
| 6 | skipWhitespace/scanIdentifierTail → local pos 패턴 | SIMD PR |
| 7 | handleNewline 특수화 (handleLF/handleCR) | SIMD PR |
| 8 | keyword lookup 길이 체크 early-exit | 최적화 PR |
| 9 | getLineColumn hint 캐싱 | 최적화 PR |
| 10 | line_offsets Small Buffer Optimization | 최적화 PR |
| 14 | scanHexDigits/scanOctalDigits/scanBinaryDigits 통합 | 최적화 PR |
| 15 | scanHexLiteral/scanOctalLiteral/scanBinaryLiteral 통합 | 최적화 PR |
| 17 | skipUnicodeEscape 헬퍼 추출 | 최적화 PR |
| 18 | isAsciiIdentStart/Continue를 unicode.zig로 이동 | 최적화 PR |
| 19 | pragma dead guard 제거 | 최적화 PR |
| 20 | checkPureComment 최적화 (단일 패스) | 최적화 PR |
| 21 | checkJSXPragma early-exit | 최적화 PR |
| 22 | peek() 캐싱 | 최적화 PR |
| 23 | isAsciiIdentContinue → lookup table | SIMD PR |
| 24 | line_offsets/template_depth_stack 초기 용량 | 최적화 PR |
| 25 | unicode.zig 범위 테이블 불완전 (Georgian 등) | 별도 PR |
| 28 | runner.zig failed_list 메모리 누수 | Arena 도입 시 해결 |
| 31 | scratch ArrayList 미적용 일부 파싱 함수 | 최적화 PR |
| 34 | parseForIn/parseForOf 통합 | 최적화 PR |

---

## TS 타입 전용 (d.ts 생성 시 필요)

ZTS는 타입 체크를 하지 않으므로 (스트리핑만) 당장 필요하지 않음.
AST Tag는 정의되어 있으나 파싱 미구현 — isolatedDeclarations 구현 시 추가.

| # | 항목 | 비고 |
|---|------|------|
| 49 | conditional type `T extends U ? X : Y` | Tag 정의됨, 파싱 미구현 |
| 50 | mapped type `{ [K in keyof T]: V }` | Tag 정의됨, 파싱 미구현 |
| 51 | infer type `infer T` | Tag 정의됨, 파싱 미구현 |
| 52 | template literal type `` `hello ${string}` `` | Tag 정의됨, 파싱 미구현 |
| 53 | declare 문 wrapper 노드 (ambient 구분) | .d.ts용 |
| 55 | declare global 미지원 | .d.ts용 |
| 56 | module "string" (문자열 모듈 이름) 미지원 | .d.ts용 |

