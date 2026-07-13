---
"@zntc/core": patch
---

`--splitting` 에서 **선언이 tree-shake 된 심볼이 청크의 `export {}` 에 남아** node 가 모듈 로드를 거부하던 버그 수정 (#4495).

```
SyntaxError: Export 'extra' is not defined in module
```

크로스-청크 export/import 목록(`chunk.exports_to` / `chunk.imports_from`)은 **스캐너 시점 메타데이터**(`import_bindings` / `export_bindings`)만 보고 만들어졌다. 그런데 그 뒤에 tree-shaker 가 선언을 지우는 경로가 두 가지 있다.

- **크로스-모듈 const-inline**: `export const extra = 1` 은 소비자 AST 에 리터럴 `1` 로 박히므로 참조가 0 → 선언 statement 가 DCE.
- **미사용 named import**: `import { unused } from "./barrel"` 를 실제로 안 쓰면 참조가 애초에 0 → 마찬가지로 DCE.

두 경우 모두 provider 청크는 선언 없이 `export { extra };` 를 내보내고, 소비자 청크는 `import { extra } from "./chunk-X.js"` 를 그대로 유지했다. **빌드 exit 0 + 모든 청크 파싱 통과** 라 산출물 재파싱 게이트로는 잡히지 않고, node 가 모듈을 **링크**할 때 거부한다.

이제 크로스-청크 심볼 등록 지점(`addCrossChunkSymbol`)이 canonical 선언의 생존 여부를 확인해, DCE 된 심볼은 provider 의 `export {}` 와 소비자의 `import {}` 양쪽에서 함께 빠진다. emitter 가 statement DCE 를 건너뛰는 모듈(래핑 모듈 / `export *` 소스 / 청크 entry + non-minify / tree-shaker 비활성)은 선언이 그대로 남으므로 보수적으로 유지한다.

번들을 실제로 **실행**하는 스모크 스위트(`split-runtime-smoke`)를 함께 추가했다.
