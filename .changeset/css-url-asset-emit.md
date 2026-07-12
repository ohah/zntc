---
"@zntc/core": minor
---

CSS `url()` 로 참조된 자산을 방출하고 url 을 재작성한다 (#4466).

지금까지 CSS 본문의 `url(./font.ttf)` 는 완전히 무시됐다 — 자산이 `dist` 에 나오지 않고 CSS 는 원문 경로를 그대로 들고 있어 런타임 404 였다 (dangling 참조). `monaco-editor` 를 번들하면 `codicon.ttf` 가 빠져 에디터 아이콘이 전부 깨지는 식이다.

이제 `url()` / `image-set()` 참조를 JS `import` 자산과 동일하게 해시 방출 + url 재작성한다.

- **적용 대상**: `@font-face { src: url(...) }`, `background`/`background-image`, `border-image`, `cursor`, `mask-image`, `list-style-image`, CSS 커스텀 속성, `image-set()` / `-webkit-image-set()`.
- **suffix 보존**: `url(./f.eot?#iefix)` → `url("./f-a1b2c3d4.eot?#iefix")` (IE9 훅), `url(./i.svg#icon)` 의 fragment 유지.
- **손대지 않는 것**: `url(#gradient)` (SVG filter/gradient 참조 — 파일이 아니다), `url(/abs.png)` (public 디렉토리 규약), `url(https://…)` / `url(//cdn…)` / `url(data:…)` / `url(blob:…)`.
- **확장자 무관**: `url()` 대상은 기본 확장자 테이블에 없어도(`.cur` 등) 파일 자산으로 처리한다 — 하드 에러로 빌드를 세우지 않는다.
- **해석 실패 시 경고 후 원문 유지** — 빌드를 세우지 않는다. 배포 스크립트가 나중에 채워 넣는 자산이 흔하기 때문.
- suffix 가 붙은 참조(`#icon` / `?#iefix`)의 대상은 인라인하지 않는다 — data URL 뒤엔 suffix 를 붙일 자리가 없다. 작은 SVG 스프라이트도 파일로 방출된다.
- JS 와 CSS 가 같은 자산을 참조하면 파일 하나로 dedup 되고, CSS 에서만 참조된 자산은 JS 번들에 죽은 `__commonJS` 래퍼로 실리지 않는다.
- `zntc dev` 도 방출 자산을 서빙한다 (예전엔 dev 에서만 404). 자산은 **메모리에서** 서빙 — 번들 산출물을 소스 디렉토리에 쓰지 않는다.

### 기본 asset 로더

폰트/이미지/미디어 확장자에 기본 `.file` 로더가 붙는다 — 예전엔 전부 `No loader is configured` 에러였다 (Vite/rspack parity).

- 이미지 `.png .jpg .jpeg .jfif .pjpeg .pjp .gif .svg .ico .webp .avif .bmp`
- 폰트 `.woff .woff2 .eot .ttf .otf`
- 미디어 `.mp4 .webm .ogg .mp3 .wav .flac .aac .opus .mov .m4a .vtt`
- 기타 `.webmanifest .pdf`

목록 밖의 확장자는 여전히 `--loader` 명시가 필요하다. `zntc build` / `zntc dev` 도 이제 `--loader:.ext=type` / `--asset-names` / `--asset-inline-limit` 을 받는다 (예전엔 `unknown option` 으로 거부).

### `--asset-inline-limit` (신규, 기본 4096)

이 크기 이하의 자산은 별도 파일 대신 data URL 로 인라인한다 (Vite `assetsInlineLimit` 상당). `0` 이면 항상 파일로 방출. JS API / config 키는 `assetInlineLimit`.

확장자 기본 테이블로 `.file` 이 된 자산에만 적용된다 — `--loader:.png=file` 처럼 **명시** 지정한 로더, `copy` 로더, RN asset-registry 모드는 인라인하지 않는다.

### Breaking

- 알려진 이미지/폰트/미디어 확장자를 `--loader` 없이 import 하면, 예전엔 빌드 에러였지만 이제 성공한다 (4KB 이하는 data URL, 초과는 해시 파일).
- CSS `url()` 이 가리키던 상대 경로가 이제 재작성된다. 출력 CSS 의 `url()` 을 문자열 비교로 검사하는 스냅샷 테스트가 있다면 갱신이 필요하다.
