---
'@zntc/core': patch
---

package.json 의 `"type": "module"` 이 **사용자 프로젝트 코드에는 적용되지 않던 것**을 고쳤다.

판정이 `node_modules/` 경로에서만 동작해서, `"type": "module"` 인 앱의 `.js` · `.ts` 파일이
CommonJS 를 default import 할 때 Node · esbuild · rolldown · rspack · webpack 과 다른 값을
받고 있었다. 이제 Node 규칙대로 **가장 가까운 package.json** 이 판정을 끝낸다 — `"type"` 이
없으면 그 자리에서 CommonJS 로 확정하고, 상위의 `"type": "module"` 이 하위 디렉토리를 덮지
않는다.

### ⚠️ 동작 변경 — `"type": "module"` 프로젝트에서 Babel 형식 CJS 의 default import

Babel 이 만든 CommonJS(`__esModule` 표시 + `exports.default`)를 default import 하면, 이제
`exports.default` 가 아니라 **모듈 네임스페이스 전체**를 받는다. Node 의 ESM↔CJS interop
명세 그대로다. 함수를 기대하고 바로 호출하던 코드는 런타임에 `... is not a function` 으로
실패한다.

```js
// 이전 (zntc 에서만 동작 — 다른 번들러·Node 에서는 이미 실패)
import generate from '@babel/generator';
generate(ast);

// 이후
import pkg from '@babel/generator';
const generate = pkg.default ?? pkg;
generate(ast);
```

실물 npm 패키지 58개를 조사한 결과 영향받는 것은 아래 5개다. 나머지는 값이 바뀌지 않거나
객체 → 객체 변화라 호출부에 영향이 없다.

- `@babel/code-frame`
- `@babel/generator`
- `@babel/template`
- `@babel/traverse`
- `lines-and-columns`

`.mjs` importer 와 `"type"` 없는 `.js`, package.json `"module"` 필드 경유 모듈의 동작은
바뀌지 않는다.
