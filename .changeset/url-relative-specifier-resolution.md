---
"@zntc/core": minor
---

CSS `url()` / `new URL()` 의 bare 지정자가 스타일시트 형제 파일보다 tsconfig `paths` 를 먼저 타던 문제 (#4604).

## 증상

catch-all `paths`(`"*": ["src/*"]` — 실사용 패턴)가 있으면 `url(logo.png)` 가 paths 에 가로채여
스타일시트 형제 파일 대신 전혀 다른 디렉토리의 파일이 자산으로 방출됐다. 같은 URL 을 가리키는
`url(./logo.png)` 는 형제로 가므로 **두 표기가 서로 다른 파일**이 된다 — 진단 0건, 자산 2개.
`new URL('w.js', import.meta.url)` 도 같은 형태로 worker 청크가 2개 생기고 한쪽이 잘못된
소스로 빌드됐다.

## 계약 변경 (동작이 바뀝니다)

`.css_url` / `.worker` 의 bare 지정자 해석 순서가
**`--alias` > 형제 파일 > tsconfig `paths` > node_modules** 로 바뀐다.

전엔 형제가 맨 뒤(패키지·paths 실패 시 폴백)였다. esbuild 를 같은 픽스처로 실측한 결과
형제가 앞서고, 형제가 없을 때만 `paths`·패키지로 간다. `url(pkg/img.png)` 가 node_modules
자산을 가리키는 동작과 `url(@/assets/logo.png)` 가 `paths` 로 해석되는 동작은 **그대로**다.

형제는 **정확히 그 이름의 파일**일 때만 이긴다 — 확장자 붙이기나 `.js`→`.ts` 매핑, RN `@2x`
variant, 디렉토리 인덱스로는 이기지 않는다. 즉 `url(x.png)` 옆에 진짜 `x.png` 가 있을 때만
결과가 바뀐다.

다음은 형제 우선에서 **제외**된다 (명시적 사용자 지시가 파일 존재 여부로 뒤집히면 안 된다):
`--alias` 가 걸린 지정자, 패키지 `browser` 필드가 remap 한 지정자, `--fallback:K=false` 로
끈 지정자, `block_list` 에 걸리는 후보.

CSS `@import` 은 아직 이 순서가 아니다 (#4611).

`--alias` 는 종전대로 형제보다 우선한다 — 사용자가 명시한 강제 재작성이 동명 파일의 존재
여부로 뒤집히면 안 되기 때문이며, esbuild 도 같다. `--packages=external` 의 "bare = 패키지"
자동 규칙도 종전 그대로다.

## 구현 노트

지정자 철자를 **재작성하지 않는다.** `ResolveCache` 가 kind 와 철자를 보고
`Resolver.url_relative` 를 켜면 resolver 가 탐색 순서만 바꾼다. `"./" ++ spec` 을 만들어
resolve 를 다시 돌리는 방식은 alias·`--fallback`·패키지 `browser` 필드·external 패턴·캐시
키가 전부 다른 철자를 보게 돼 각각 어긋난다.
