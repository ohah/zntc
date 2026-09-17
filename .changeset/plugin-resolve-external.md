---
'@zntc/core': patch
---

plugin 의 `onResolve` 가 `{ path, external: true }` 를 반환해도 무시되던 문제를 고쳤다.
`PluginBuild.onResolve` 타입에 문서화된 필드인데 native 가 `is_external` 을 파싱만 하고
쓰지 않아 일반 파일로 취급됐고, `No loader is configured for this file type` 로 죽었다.

graph 쪽도 함께 배선했다 — plugin 이 반환한 `.external` 변종이 "미설계" 로 남아 있어
넘기면 panic 에 걸렸다. 기존 phantom external 경로와 같은 기계를 쓰며, plugin 이 정한
경로가 원문과 다르면 방출 지정자로 둔다.

덕분에 배열 형태 alias 의 치환 결과가 external 로 판정되는 조합
(`alias: [{find:'a', replacement:'b'}]` + `external: ['b']`)도 동작한다.
