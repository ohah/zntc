---
"@zntc/core": patch
---

CSS `url(logo.png)` 처럼 `./` 가 없는 bare 상대 지정자도 자산으로 재작성한다 (#4485).

CSS 스펙상 `url()` 의 상대 참조는 **스타일시트 자신의 URL** 이 base 다. 그래서 `"logo.png"` 와 `"./logo.png"` 는 같은 파일을 가리켜야 한다. 그런데 지금까지 zntc 는 `./` 가 붙은 것만 재작성하고, bare 형태는 npm 패키지 이름으로 보고 `node_modules` 를 뒤졌다 → resolve 실패 → 경고만 남기고 원문 그대로 방출 → **런타임 404**.

```css
.a { background: url(./logo.png); }  /* → url("./logo-1c4d8b20.png") ✅ */
.b { background: url(logo.png); }    /* → url(logo.png) ❌ 404 */
```

#4483(worker 지정자)과 같은 루트커즈이며, 같은 처방을 `url()` 에 확장했다. resolve 레이어에서 **기존 해석을 먼저 시도하고, 못 찾았을 때만** `./` 를 붙여 재시도한다.

- `url(imgpkg/pic.png)` 처럼 지금 `node_modules` 패키지로 해석되던 bare url() 은 **그대로 패키지가 이긴다** (기존 동작 보존 — "패키지 우선 + 상대 폴백").
- `--platform=node` 에서 `url(path/logo.png)` / `url(url/x.png)` 처럼 첫 세그먼트가 Node 빌트인 이름과 겹치던 자산 디렉토리가 external 로 빠져 원문 방출되던 것도 함께 고쳤다 — CSS 의 `url()` 은 파일 참조지 모듈 지정자가 아니다 (worker 도 동일).
- scheme 있는 절대 URL(`https:` / `data:` / `blob:`), protocol-relative(`//cdn/x.png`), root-absolute(`/logo.png`), `url(#blur)` 는 그대로 둔다.
- `?query` / `#fragment` suffix 는 종전처럼 보존된다 (`url(f.eot?#iefix)`).
- 알려진 한계: `--packages=external` 을 켜면 bare url() 은 여전히 패키지로 간주돼 external 로 빠진다(원문 방출). 이 경우 `url(./logo.png)` 로 쓰면 정상 재작성된다.
