---
'@zntc/core': patch
---

`zntc.config` 의 `alias` 가 app 모드(`zntc build .` / `zntc dev .`)에서 무시되던 문제를 고쳤다.
`AppBuildOptions` 에 `alias` 필드 자체가 없어 config 의 alias 가 조용히 사라졌다 — 타입 · CLI
전달 · NAPI 파싱 · app 빌드 옵션 구조체 네 표면에 배선했다.

배열 형태 alias (`[{ find, replacement }]`) 도 고쳤다. 치환 결과를 native resolver 로 다시
해석하지 않아 `{'@': '<abs>/src'}` 처럼 **디렉토리**를 가리키면 확장자가 안 붙어
`No loader is configured for this file type` 로 죽었다. `@rollup/plugin-alias` 가
`this.resolve()` 로 하는 것과 같이 한 번 더 해석한다. 아울러 CLI 의 config 병합이 배열에
객체 스프레드를 해서 `{"0": {...}}` 로 형태를 깨뜨리던 것도 고쳤다.

아울러 `buildSync` / app 빌드의 plugin hook 에도 native resolver 를 주입했다 — 예전엔
`NapiSyncPlugin` 이 hook 컨텍스트를 넘기지 않아 sync 경로의 plugin 은 `this.resolve()` 를 쓸 수
없었다. 이제 Object / Array 두 형태 모두 `build()` · `buildSync()` · app 빌드에서 동작한다.

문서는 디렉토리 alias 의 target 에 **절대경로**를 쓰도록 표준 예제를 정리했다 (Vite · webpack ·
esbuild · Rollup 모두 같은 관례).
