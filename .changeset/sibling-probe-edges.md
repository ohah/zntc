---
"@zntc/core": patch
---

`url()` / `new URL()` 참조가 **디렉토리 symlink** 를 파일로 잡아 빌드가 죽던 문제를 고쳤다 (#4612).

`DirEntryCache` 는 readdir 만으로 symlink 대상이 파일인지 디렉토리인지 알 수 없어 files·dirs
양쪽에 등록한다. 그래서 참조 대상 자리에 디렉토리 symlink 가 있으면 그걸 파일로 넘겼고, 읽기
단계에서 `ZNTC0200 Cannot read file` 로 **빌드 전체가 죽었다** — 해석 실패는 warning + 원문
유지가 맞는 동작인데 fatal 이 됐다.

이제 `.css_url` / `.worker` 는 디렉토리 후보를 거부한다. 판정은 **철자가 아니라 kind** 에
걸리므로 `url(logo.png)` 와 `url(./logo.png)` 가 같이 동작한다. dir 로도 등록된 후보만
`statFile` 로 확정하므로 파일 symlink 는 종전대로 이긴다.
