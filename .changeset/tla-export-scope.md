---
"@zntc/core": patch
---

top-level await + `--target < es2022` 에서 `export const/let/var` 가 스코프 분리로 깨지던 문제를
고쳤다 (#4598 1단계).

TLA 래퍼가 최상위 문장을 `(async () => {…})()` 안으로 넣는데 export 선언은 밖에 남아,
**선언은 안 / 사용은 밖** 으로 갈려 `ReferenceError` 가 났다. 이제 `var X;`(밖) +
`X = init;`(래퍼 안, 원래 순서 유지) 로 분해한다 — ESM live binding 으로 밖에서도 보인다.

⚠️ `export function` / `export class` / `export default` / `const X=…; export {X}` 는 아직
같은 방식으로 깨진다 (#4598 에 후속 기록).
