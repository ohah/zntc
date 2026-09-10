---
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
