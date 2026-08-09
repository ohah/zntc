---
"@zntc/core": patch
---

top-level await + `--target < es2022` 에서 export 가 스코프 분리로 깨지던 문제를 고쳤다 (#4598).

TLA 래퍼가 최상위 문장을 `(async () => {…})()` 안으로 넣는데 export 는 밖에 남아,
**선언은 안 / 사용은 밖** 으로 갈려 `ReferenceError` 가 났다. 이제 바인딩만 밖으로 올리고
초기화는 래퍼 안에 남긴다 — ESM live binding.

- `export const/let/var X = init` → `var X;`(밖) + `X = init;`(원위치)
- `export function f(){}` → `f = function f(){…};`(본문 **맨 위** = 호이스팅 등가)
- `export class C{}` → `C = class C{…};`(원위치 — 클래스는 원래 TDZ)
- `export default expr` → `export { _t as default };` (live binding. `export default _t` 는 스냅샷)
- `const X=…; export {X}` → 선언을 대입으로 전환 (const-bake 가 elide 하던 것도 해소)

⚠️ 대입 전 접근 시 원본의 TDZ `ReferenceError` 가 `undefined` 접근으로 바뀐다 — 이미 에러인
경로에서 에러 종류만 달라지는 것으로, ESM live binding 방식의 본질적 한계다.
