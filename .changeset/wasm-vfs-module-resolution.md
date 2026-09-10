---
"@zntc/core": patch
"@zntc/wasm": patch
---

WASM VFS 번들러가 entry 의 import 를 해석하지 못해 multi-file 번들이 entry 만 담긴
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
