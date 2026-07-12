# @zntc/core

## 0.1.3

### Patch Changes

- c608d1b: 동명 basename 자산의 `require_X` 래퍼 이름이 충돌해 **다른 자산의 URL 을 돌려주던** 버그 수정 (#4475).

  ```js
  import x from './a/logo.png'; // 내용이 서로 다른 파일
  import y from './b/logo.png';
  console.log(x, y);
  // 전: ./logo-efdc71e4.png ./logo-efdc71e4.png   ← 둘 다 같은 URL
  // 후: ./logo-22fcfd0d.png ./logo-efdc71e4.png
  ```

  자산 파일은 둘 다 올바른 해시로 방출되는데, 번들 JS 가 `var require_logo` 를 **두 번 선언**해서 두 번째가 첫 번째를 가렸다. 결과적으로 `a/logo.png` 는 번들에서 도달 불가능해지고 `x` 가 `b/logo.png` 의 URL 을 받았다 — 빌드는 성공하는 조용한 오컴파일.

  근본 원인: `registerWrapperSymbols` 가 래퍼 이름을 `uniqueName()` 으로 deconflict 하는데, 그 앞에 `if (m.semantic) |*s| s else continue` 가드가 있다. asset 모듈은 JS 파싱을 거치지 않아 `semantic` 이 null 이라 **등록을 통째로 건너뛰었고**, emit 은 basename 기반 fallback(`makeRequireVarName`)으로 떨어졌다. 그 fallback 은 충돌을 모른다.

  semantic 이 없어도 이름 deconflict 는 할 수 있으므로 전용 슬롯(`Module.wrapper_name_synthetic`)에 담는다. `disabled` / `optional-missing` 모듈도 같은 fallback 을 타고 있었으므로 함께 보호된다.

- b0d6898: class static block 을 소스 원문 복사가 아니라 AST 로 출력한다 (#4468).

  `emitStaticBlock` 이 non-minify 경로에서 `writeNodeSpan` 으로 **소스 바이트를 그대로 복사**하고 있었다. 그래서 static block 안에서만 AST 에 가해진 변형이 통째로 유실됐다 — 조용한 오컴파일.

  ### 유실되던 것들
  - **deconflict rename**: `class Node` 가 `Node$1` 로 rename 돼도 블록 안의 자기참조 `new Node(...)` 는 옛 이름으로 남았다. 번들에 `Node` 선언이 없으니 그 참조는 **전역 바인딩을 탈취**한다 — 브라우저에서 `new Node()` 는 DOM `Node` 를 잡아 `TypeError: Illegal constructor` 로 죽는다. `monaco-editor` 의 `vs/base/common/linkedList.js` 가 정확히 이 패턴이라, `zntc build` 로 번들한 monaco 는 **에디터가 아예 뜨지 않았다**.
  - **TypeScript strip**: `static { getX = (obj: C) => obj.#x; }` 의 타입 주석 `: C` 가 그대로 남아 **문법적으로 깨진 JS** 가 나왔다.
  - **`--define` 치환**: `static { this.mode = __MODE__; }` 의 `__MODE__` 가 그대로 남아 런타임 `ReferenceError`.
  - 주석이 클래스 밖으로 중복 출력되고, 들여쓰기가 원본 소스 것과 codegen 것으로 뒤섞였다.

  minify 경로는 이미 AST 로 출력하고 있었고 그쪽은 정상이었다 — 즉 AST 출력은 이미 검증된 경로였고, 원문 복사 지름길만 그걸 건너뛰고 있었다. 그 지름길을 제거했다.

  ### 출력 변화

  static block 이 다른 블록과 동일하게 포맷된다. `minify_syntax` 가 꺼진 상태에서는 statement 종결 `;` 가 붙는다 (다른 모든 블록과 같은 규칙).

  ```js
  // 이전 (소스 원문 복사 — 들여쓰기가 뒤섞임)
  class C {
    static {
      const a = 1;
    }
  }

  // 이후 (AST 출력)
  class C {
    static {
      const a = 1;
    }
  }
  ```

- b91fc85: CSS `url()` 로 참조된 자산을 방출하고 url 을 재작성한다 (#4466).

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

  ### 동작 변화 (기존 사용자와 호환)
  - 알려진 이미지/폰트/미디어 확장자를 `--loader` 없이 import 하면, 예전엔 **빌드 에러**였지만 이제 성공한다 (4KB 이하는 data URL, 초과는 해시 파일). 에러가 성공으로 바뀌는 것이라 깨질 코드가 없다.
  - `--loader:.png=file` 처럼 로더를 **명시**한 설정은 인라인 대상에서 제외돼 기존 출력이 그대로 유지된다.
  - CSS `url()` 의 상대 경로가 재작성된다. 이전엔 자산이 방출되지 않아 런타임 404 였으므로 그 출력에 의존하던 동작은 존재할 수 없었다. 다만 출력 CSS 의 `url()` 을 문자열로 비교하는 스냅샷 테스트가 있다면 갱신이 필요하다.

- 872bf64: `--jsx=preserve` 가 JSX 를 소스 원문 복사가 아니라 AST 로 출력한다 (#4470).

  preserve 모드는 JSX 를 변환하지 않고 downstream tool 에 위임한다. 그런데 그 "그대로" 를 **소스 span 통째 복사**로 구현하고 있어서, JSX 안에서만 AST 변형이 전부 무시됐다.

  ### 고쳐진 것

  **1. 번들 deconflict rename 누수 → `ReferenceError`**

  ```jsx
  import { Widget as A } from './a.jsx';
  export const q = <A.Panel />;
  ```

  scope hoisting 후 실제 심볼은 `Widget` 인데 태그는 `A` 를 그대로 들고 있었다. 번들에 `A` 선언이 없으므로 downstream 변환 결과는 `ReferenceError: A is not defined`. 이제 `<Widget.Panel />` 로 나간다.

  **2. JSX 안의 TypeScript 어노테이션 미strip**

  `<Foo prop={value as Type} />` 의 `as Type` 이 남아 JS 로 파싱 불가였다. (기존 코드가 "알려진 제약" 으로 주석에 명시해 두던 항목.)

  **3. `--define` 치환 미적용**

  `<Foo x={__MODE__} />` 의 `__MODE__` 가 그대로 남았다.

  **4. 깨진 JSX 출력**

  transformer 가 element/fragment 는 `shouldLowerJsx()`(preserve 존중)로, 자식(expression container / text / spread)은 `jsx_transform` 으로 게이트해서 **preserve 모드인데 자식만 lowering** 됐다. 그 결과 `<div>{x}</div>` 가 `<div>"..."x</div>` 처럼 텍스트에 따옴표가 붙고 중괄호가 사라진 채로 나갔다. 두 게이트를 통일했다.

  ### 안전 장치
  - **속성 이름은 절대 rename 되지 않는다.** semantic analyzer 가 `jsx_attribute` 의 value 만 방문하고 name 은 방문하지 않으므로 심볼이 붙을 수 없고, codegen 도 name 을 원문 경로로 낸다.
  - **원본 소스의 attribute string 은 원문 보존.** JSX attribute string 은 JS string 과 escaping 규칙이 다르다(backslash escape 없음, HTML entity 사용) — `c="a&amp;b"` 가 그대로 나간다.
  - **합성된 string 은 `{}` 로 감싼다.** `--define` 치환 결과처럼 따옴표가 든 값을 attribute string 자리에 그대로 내면 `d="a\"b"` 가 되는데 JSX 는 그 백슬래시를 escape 로 읽지 않는다. `d={"a\"b"}` 로 낸다.

- f91a98b: minify 시 `if (c) { ({a} = o); g(); }` 를 콤마 시퀀스로 접을 때 **필수 괄호가 사라지던** 버그 수정 (#4472).

  `--minify`(= `minify_whitespace` + `minify_syntax`)는 블록 안의 expression statement 들을 `if(c) a,b;` 처럼 콤마 시퀀스로 접는다. 이 경로가 statement-start 를 표시하지 않아, 시퀀스 **첫 원소**가 object destructuring 할당이면 괄호가 빠졌다:

  ```js
  // 입력
  if (href) { ({ href, dimensions } = cleanUrl(href)); out.push(href); }

  // 잘못된 출력
  if(n){href:n,dimensions:r}=t(n),i.push(n);
  //    ^ 브라우저는 `{` 를 블록으로, `href:` 를 라벨로 읽는다 → SyntaxError

  // 고쳐진 출력
  if(n)({href:n,dimensions:r}=t(n)),i.push(n);
  ```

  **빌드는 exit 0 으로 성공하는데 산출물이 런타임에 죽는** silent miscompile 이었다 — `monaco-editor`(marked 의 image 렌더러)를 번들하면 `SyntaxError: Unexpected token ':'` 로 페이지 전체가 실행되지 않았다.

  단일 문장 본문(`if (c) ({a} = o);`)은 `emitExpressionStatement` 를 타서 정상이었고, 여러 문장을 접는 경로만 그 마킹을 건너뛰고 있었다. object literal 선두(`({}).toString()`)도 같은 원인으로 깨졌고 함께 고쳐진다. 배열 구조분해(`[a,b] = arr`)는 `[` 가 블록으로 오파싱되지 않으므로 괄호가 붙지 않는다.

- 1f92385: Vite 식 query-suffix import 지원 — `?raw` / `?url` / `?inline` / `?worker` (#4467).

  Vite 생태계 문서·레시피가 널리 쓰는 관용구인데 zntc 가 resolve 하지 못해 `ZNTC0100 Cannot resolve module` 이 났다. 라이브러리 문서 다수가 이 형태를 전제해서 마이그레이션 마찰이 됐다.

  | suffix          | 동작                                                                                                                                                       |
  | --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | `?raw`          | 파일 내용을 문자열로 인라인 (`text` 로더)                                                                                                                  |
  | `?url`          | 자산으로 방출하고 URL 문자열을 export. **`--asset-inline-limit` 을 무시**한다 — 사용자가 URL 을 명시 요청한 것이므로 작은 파일도 data URL 로 바뀌지 않는다 |
  | `?inline`       | data URL 로 인라인 (`dataurl` 로더). 크기와 무관하게 항상 인라인                                                                                           |
  | `?worker`       | Worker 생성 함수를 default export — `new W()` 로 Worker 를 만든다                                                                                          |
  | `?sharedworker` | SharedWorker 생성 함수를 default export                                                                                                                    |

  ```js
  import txt from './data.txt?raw'; // "hello raw content"
  import u from './icon.png?url'; // "./icon-a1b2c3d4.png"
  import i from './icon.png?inline'; // "data:image/png;base64,..."
  import W from './x.worker.js?worker';
  const w = new W();
  ```

  같은 파일도 query 마다 다른 모듈이다 (`x.png` 는 자산, `x.png?raw` 는 문자열).

  `?worker` 는 새 인프라를 만들지 않고 **표준 worker 패턴을 합성**해 기존 기계를 재사용한다:

  ```js
  export default function WorkerWrapper(options) {
    return new Worker(new URL('./x.worker.js', import.meta.url), options);
  }
  ```

  `{ type: "module" }` 을 붙이지 **않는다.** zntc 는 worker entry 를 항상 classic script(IIFE)로 방출하므로, module worker 로 로드하면 strict mode / `importScripts` 부재 같은 다른 semantics 가 걸려 classic 번들이 터질 수 있다. Vite 도 worker 출력이 `es` 일 때만 붙인다.

  `?vue&type=style&lang.css` 같은 **알려지지 않은 query 는 건드리지 않는다** — 그쪽은 플러그인이 가상 경로로 처리하는 기존 관용구다.

## 0.1.2

### Patch Changes

- ab2c450: 내부 실험 기능(MCP) 정리 — 0.1.1 이후 개발 중 추가됐던 미동작 MCP epic(`zntc mcp` / `/mcp` endpoint / `mcpStdioServe` 등) 제거. 게시본(0.1.0/0.1.1)에 포함된 적 없어 사용자 영향 없음.
