---
'@zntc/core': patch
---

package.json `"module"` 필드로 해석된 ESM 빌드가 Babel 형식 CJS 를 default import 할 때
함수 대신 네임스페이스 객체를 받던 문제를 고쳤다 (#4659).

`@mui/material` 처럼 `"module"` 로 ESM 빌드를 노출하는 패키지에서 `TypeError:
createStyled is not a function` 으로 앱이 죽었다.

`"module"` 은 **번들러 관례**("여기 ESM 빌드가 있다")이지 Node 의 `"type": "module"` 이
아니다. Node 는 `"module"` 필드를 읽지 않으므로 그 파일은 Node 기준으로 여전히 CJS 이고,
따라서 CJS default import 에 Node interop 의미(`import d from 'cjs'` → `d = module.exports`)를
적용하면 안 된다. 이전엔 두 개념이 같은 `def_format` 값으로 접혀 있어 Node 모드
(`__toESM(x, 1)`)가 켜졌다.

이제 `ModuleDefFormat` 이 두 질문을 나눠 답한다 — `isEsm()`(ESM 구문으로 파싱할까)과
`isNodeEsm()`(Node 가 ESM 으로 볼까). interop 판정만 후자를 쓴다. esbuild · rolldown ·
rspack 셋 다와 결과가 일치한다.
