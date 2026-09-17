# @zntc/wasm

## 0.1.8

### Patch Changes

- cdf7c85: `return` / `throw` / `yield` 피연산자 앞에 줄 주석(`//`)이 오면 그 뒤 코드가 전부 주석에
  먹히던 문제를 고쳤다. `return`은 조용히 `undefined`를 반환하고, `throw`는 SyntaxError,
  `yield`는 `undefined`를 yield했다. JSX와는 무관하며 숫자·문자열·호출 등 모든 식에서 발생했다.

  이 세 키워드는 ECMAScript `NoLineTerminator` 제한이 있어 피연산자 앞에 줄바꿈이 오면 안 된다.
  그래서 선두 주석을 줄바꿈 없이 인라인으로 붙여 왔는데, 그 전략은 블록 주석에만 유효하다.
  이제 줄 주석이 선두에 있으면 **괄호로 감싼다** — 괄호가 줄바꿈을 안전하게 만들어 주석도
  살고 ASI도 안 끊긴다 (swc·babel과 같은 전략). 블록 주석 경로와 `#4042`의 군더더기 괄호
  제거는 그대로다.

  함께 고친 것:
  - `//` 주석 뒤에는 minify에서도 실제 개행을 쓴다. `writeNewline`이 minify에서 no-op이라
    `// @license` 같은 legal 줄 주석이 살아남는 경우 뒤가 전부 먹혔다.
  - 괄호가 멤버 접근의 대상일 때(`return ( /* c */ x ).y`) 안쪽 주석을 놓쳐 ASI가 나던 것도
    고쳤다. 출력의 가장 왼쪽 토큰까지 내려가 주석을 미리 소비한다.
  - 비어 있지 않은 블록의 마지막 statement 뒤 주석이 블록 밖으로 새던 것을 고쳤다 (`#4468`이
    빈 블록만 고쳐 둔 것의 짝). swc·babel·oxc 모두 제자리에 둔다.

- 19944ac: 해석하지 못한 import 를 **번들 바깥에 있는 것으로 취급**하도록 고쳤다. 이전에는 출력 포맷과
  무관하게 `require(...)` 폴백을 방출해서, ESM/IIFE 출력이나 브라우저 타겟에서는 문법적으로
  성립하지 않는 번들이 나왔다. 그 번들은 로드 시점에 `require is not defined` 로 죽는데, 정작
  원인인 "패키지가 없다" 는 메시지에서 사라졌다.

  이제 ESM 은 `import`, CJS 는 `require`, IIFE 는 기존 "IIFE 포맷으로는 방출 불가" 진단으로
  각각 제 경로를 탄다. 런타임 메시지도 없는 패키지를 지목한다. 진단 등급은 그대로 error 다 —
  external 로 _방출_ 한다는 뜻이지 오탈자를 눈감아 준다는 뜻이 아니다.

  WASM `build()` / `buildChunks()` 는 해석 불가 import 가 있어도 출력을 반환한다. VFS 에
  `react` 를 올리지 않는 게 정상인 플레이그라운드에서 `jsx: "automatic"` 이 주입하는 런타임
  import 를 실패로 처리하면 JSX 자체를 쓸 수 없기 때문이다. 출력을 withhold 하는 건 번들이
  내부적으로 앞뒤가 안 맞을 때(export 충돌·모호·누락)뿐이다. 0.1.7 에서 이 구분 없이 막았던
  것을 되돌린다.

  CLI 의 산출물 방출 정책도 같은 규칙으로 통일했다. 이전엔 npm CLI(`bin/zntc.mjs`)는 에러가
  있어도 산출물을 냈고 Zig CLI(`zig build` 산출 바이너리)는 출력 전에 종료해 아무것도 내지
  않았다. 이제 둘 다 "번들이 내부적으로 앞뒤가 안 맞을 때만 보류" 로 같은 답을 낸다. exit code
  는 이와 별개로 에러가 있으면 1 이다.

## 0.1.7

### Patch Changes

- 9f04c3a: WASM VFS 번들러가 entry 의 import 를 해석하지 못해 multi-file 번들이 entry 만 담긴
  출력이 되던 문제를 고쳤다. resolver 의 파일 존재 판정은 `listDir` 로 채워지는 디렉토리
  캐시만 보는데, WASM 의 `VirtualFS.listDir` 이 항상 빈 목록을 반환해 모든 상대 import
  후보가 "없음" 으로 판정됐다. host `zntc_fs.listDir` ABI 를 실제로 구현하고,
  `VirtualFileSystem` 이 등록된 경로에서 디렉토리를 합성해 돌려준다.

  `access` / `statFile` / `realpath` 도 디렉토리를 인식하며, 디렉토리 성분이 없는 경로
  (`index.ts` 처럼 선행 `/` 없이 등록한 경우) 는 cwd 기준으로 해석한다.

  `build()` / `buildChunks()` 는 에러 진단이 있으면 부분 출력 대신 `null` 을 반환한다
  (CLI 의 "에러 있으면 출력 생략 + exit 1" 과 같은 계약). bundler ABI v6 → v7.

  또한 `./util` 처럼 **형제 파일과 동명 디렉토리가 함께 있을 때** 해석 순서를 고쳤다. 이전엔
  디렉토리 index(`util/index.ts`)가 형제 파일(`util.ts`)을 이겼는데, Node/TypeScript 는 물론
  esbuild·rolldown 도 전부 파일이 먼저다. pnpm package symlink root 를 위한 "디렉토리 먼저"
  carve-out 은 **양쪽(file+dir)에 등록된 ambiguous 후보** 로만 좁혔다 — symlink 케이스는 그대로
  동작한다. native(`@zntc/core`)와 WASM 양쪽에 적용된다.

## 0.1.6

## 0.1.5

## 0.1.4

## 0.1.3

## 0.1.2
