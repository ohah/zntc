---
"@zntc/core": patch
---

top-level await + `--target < es2022` 에서 export 가 스코프 분리로 깨지던 문제를 고쳤다 (#4598).

TLA 래퍼가 최상위 문장을 `(async () => {…})()` 안으로 넣는데 export 선언은 밖에 남아,
**선언은 안 / 사용은 밖** 으로 갈려 `ReferenceError` 가 났다.

- `export const/let/var X = init` → `var X;`(밖) + `X = init;`(래퍼 안, 원래 순서 유지)
- `export function f(){}` → `var f;` + `f = function f(){…};`(본문 **맨 위** = 호이스팅 등가)
- `export class C{}` → `var C;` + `C = class C{…};`(원위치 — 클래스는 원래 TDZ)

⚠️ `export default` 와 `const X=…; export {X}` 는 아직 남았다 (#4598 후속).
⚠️ 대입 전 접근 시 원본의 TDZ `ReferenceError` 가 `undefined` 접근으로 바뀐다 — 이미 에러인
경로에서 에러 종류만 달라지는 것으로, ESM live binding 방식의 본질적 한계다.
