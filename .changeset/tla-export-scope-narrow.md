---
"@zntc/core": patch
---

top-level await + `--target < es2022` (ESM 출력)에서 export 초기화식이 래퍼 안 바인딩을 참조하면
`ReferenceError` 가 나던 문제를 고쳤다 (#4598 부분).

`export const OUT = { items }` 처럼 초기화식이 래퍼 안 선언을 참조할 때만 `var OUT;`(밖) +
`OUT = { items };`(래퍼 안 원위치) 로 분해한다.

⚠️ 범위를 좁게 유지한다 — CJS/UMD/IIFE 출력, `export function`/`class`, 래퍼 로컬을 참조하지
않는 export 는 **건드리지 않는다**. 각각 분해하면 조용한 오답·순환 import 파손·import 시점
읽기 파손이 생긴다(#4598 코멘트에 반례 기록).
