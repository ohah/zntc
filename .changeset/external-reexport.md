---
"@zntc/core": patch
---

external 모듈에서 re-export 하면 산출물이 파싱 불가가 되거나 재export 가 사라지던 문제를 고쳤다 (#4621).

- `export { x } from '<external>'` → 예전엔 바인딩 없는 `export { x };` 만 나가 **SyntaxError**.
  이제 `import { x } from "…"; export { x };`
- `export * from '<external>'` → 예전엔 **통째로 사라짐**. 이제 그대로 통과.
- `export * as ns from '<external>'` → namespace import + export 로 편다.

esbuild·rolldown 실측과 일치한다.
