# @zntc/web

## 0.1.10

### Patch Changes

- 7e023f9: `zntc dev` 에서 CSS 를 수정할 때마다 hot swap 대신 **전체 페이지 리로드**가 일어나던 문제를
  고쳤다 (#4672).

  HMR 클라이언트는 `css-update` 의 `href` 와 pathname 이 일치하는 `<link>` 만 교체하고, 하나도
  못 맞추면 페이지를 리로드한다. 그런데 변경 통지는 소스 미러 경로(`/styles.css`)를 가리키고
  주입된 링크는 번들 CSS(`/main.css`)라 언제나 어긋났다.

  이제 dev 컨트롤러가 **자신이 주입한 href 를 기억**해 두고, 변경된 소스가 그중 하나면 그
  href 를 정확히 지목한다. 번들 CSS 로 합쳐져 어느 링크인지 단정할 수 없으면 `href` 를 비워
  보내 클라이언트가 **모든 stylesheet 를 갱신**하게 한다 — 전체 리로드보다 훨씬 싸고 앱 상태도
  보존된다.

- 9e42ba9: dev 컨트롤러에서 호출자가 없는 `injectBundleCssLinksFromOutdir` 를 제거하고, HMR `css-update` 메시지의 `href` 타입을 실제 동작에 맞췄습니다 (#4680, #4681).

  `href` 는 "어느 stylesheet 를 갱신할지" 를 가리키는데, 단정할 수 없을 때는 `null` 을 보내 **모든 stylesheet 를 갱신**하게 합니다. 타입은 `string` 으로만 선언돼 있어 실제와 어긋나 있었습니다.

  `@zntc/web` 의 `AppDevController` 인터페이스에서 메서드 하나가 빠집니다. dev 컨트롤러를 직접 임베드해 그 메서드를 호출하던 코드가 있다면 영향을 받습니다 — 저장소 안에는 호출자가 없었습니다.

- 757ccd9: `zntc dev` 에서 CSS Module / SCSS 와 plain `.css` 를 함께 import 하면 plain CSS 가 적용되지 않던 문제를 고쳤습니다 (#4675).

  dev 는 SCSS / CSS Modules 의 생성 CSS 만 페이지에 연결했습니다. plain `.css` 는 디스크에 미러돼 서빙까지 되는데 `<link>` 가 없어 도달하지 못했습니다.

  이제 **번들러가 실제로 따라간 CSS 목록**으로 링크를 겁니다. 디렉토리를 훑어 붙이면 import 하지도 않은 CSS 까지 적용되므로, 모듈 그래프에 들어온 것만 연결합니다. 같은 내용의 합본인 번들 CSS 는 중복이라 이 경우 연결하지 않습니다.

  CSS 를 고칠 때 해당 링크 하나만 정확히 갱신되는 것도 함께 고쳐집니다 — 예전에는 plain CSS 가 링크에 없어 "어느 링크인지 모름" 으로 떨어져 모든 stylesheet 를 다시 받았습니다.

- b558d49: `zntc dev` 를 한 번 돌린 프로젝트에서 `zntc build` 가 실패하던 문제를 고쳤다 (#4674).

  ```
  error: ENOENT: no such file or directory, open
    '/var/.../zntc-postcss-build-XXXX/.zntc-dev/s.module.css'
  ```

  PostCSS temp root 로 프로젝트를 복사할 때는 dev 산출 디렉토리(`.zntc-dev`)를 제외하는데,
  CSS Module **탐색**은 `outdir` 하나만 제외해서 `.zntc-dev` 안의 `.module.css` 를 처리 대상으로
  잡았다. 복사본에 그 파일이 없으니 열다가 죽었다.

  "무엇이 source 인가" 라는 같은 질문에 복사와 탐색이 다르게 답하던 것을 **하나의 목록**
  (`postcssExcludedDirs`)으로 합쳤다. `collectAppFiles` 에 `skipDirs` 를 추가해 같은 목록을
  그대로 넘긴다.

- 0ab0b3e: `zntc dev` 에서 PostCSS 설정이 있을 때 번들 CSS 가 망가지던 문제를 고쳤습니다 (#4679).

  첫 CSS 편집에서 PostCSS 변환이 통째로 사라지고 그 뒤로는 갱신이 멈췄습니다. Tailwind 처럼 PostCSS 에 의존하는 설정에서는 저장 한 번에 스타일이 사라진 채 고정됐습니다.

  원인이 둘이었습니다. dev 에서는 번들러가 PostCSS 임시 트리를 입력으로 읽는데, CSS 를 고치면 그 트리에 원본이 덮여 쓰이고 처리 결과는 되돌아오지 않았습니다. 그리고 그 덮어쓰기가 파일을 교체해 macOS 의 파일 감시가 끊겼습니다 (#4682).

  부수 효과로, macOS 에서 **에디터의 원자적 저장**(임시파일을 쓰고 이름을 바꾸는 방식 — JetBrains IDE, `vim` 기본 설정, 많은 포매터가 이렇게 저장합니다) 이후 해당 파일의 변경이 영영 감지되지 않던 문제도 함께 해결됩니다. 이전에는 dev 서버를 재시작해야 했습니다.

- be5f0fb: `zntc dev` 에서 CSS import 를 지워도 스타일이 계속 적용되던 문제를 고쳤습니다 (#4671).

  링크 주입기가 추가만 하고 지우지 않아, JS 에서 `import './styles.css'` 를 없애도 `<link>` 가 HTML 에 남아 있었습니다. 이제 매 rebuild 마다 실제로 필요한 링크 집합에 맞춰 남은 링크를 지웁니다.

  주입한 링크에만 표시를 달아 구분하므로, `index.html` 에 직접 적어 둔 `<link>` 는 그대로 유지됩니다.

- f16ab4d: 하위 디렉토리에 `zntc dev` 산출물(`.zntc-dev`)이 남아 있으면 `zntc build` 가 같은 CSS Module 을 두 번 처리하던 문제를 고쳤습니다 (#4678).

  dev 산출 디렉토리에는 서빙용으로 **소스 CSS 가 그대로 미러**돼 있습니다. 예전에는 앱 루트의 `.zntc-dev` 만 걸러내서, 하위 앱이 dev 를 돌려 남긴 `sub/.zntc-dev` 가 소스로 취급됐습니다. 출력은 같았지만 빌드가 느려졌습니다.

  ⚠️ `--outdir` 로 이름을 바꾼 dev 산출물은 여전히 걸러지지 않습니다. `zntc build` 는 직전 `zntc dev` 가 어떤 outdir 을 썼는지 알 방법이 없습니다 — 알려진 한계로 #4678 에 남겨 둡니다.

- Updated dependencies [bfb98cf]
- Updated dependencies [757ccd9]
- Updated dependencies [0ab0b3e]
- Updated dependencies [be5f0fb]
- Updated dependencies [e113dc9]
  - @zntc/core@0.1.10

## 0.1.9

### Patch Changes

- Updated dependencies [85922e3]
- Updated dependencies [13c21ca]
- Updated dependencies [7e3ea66]
- Updated dependencies [e28ca9d]
  - @zntc/core@0.1.9

## 0.1.8

### Patch Changes

- Updated dependencies [c6885f6]
- Updated dependencies [f1c7dff]
- Updated dependencies [b3b8752]
- Updated dependencies [9c531f6]
- Updated dependencies [cdf7c85]
- Updated dependencies [4c18dfd]
- Updated dependencies [19944ac]
  - @zntc/core@0.1.8

## 0.1.7

### Patch Changes

- Updated dependencies [9f04c3a]
  - @zntc/core@0.1.7

## 0.1.6

### Patch Changes

- Updated dependencies [e3c8ac8]
  - @zntc/core@0.1.6

## 0.1.5

### Patch Changes

- Updated dependencies [5593c0e]
- Updated dependencies [413e86b]
- Updated dependencies [69dcc34]
- Updated dependencies [7b7afd9]
- Updated dependencies [3efda7c]
- Updated dependencies [43ad307]
- Updated dependencies [9274e02]
- Updated dependencies [2686be2]
- Updated dependencies [040b4be]
- Updated dependencies [19f9445]
- Updated dependencies [bd2fcaf]
- Updated dependencies [5e3bcbf]
- Updated dependencies [cc1f6de]
- Updated dependencies [593f4fe]
- Updated dependencies [2b6eaa6]
- Updated dependencies [ba6790e]
  - @zntc/core@0.1.5

## 0.1.4

### Patch Changes

- Updated dependencies [4cd691e]
- Updated dependencies [345d2cc]
- Updated dependencies [d916ea3]
- Updated dependencies [43245e6]
- Updated dependencies [c0cc120]
- Updated dependencies [5b8b6b2]
- Updated dependencies [3400ae1]
- Updated dependencies [5886863]
- Updated dependencies [51ff984]
- Updated dependencies [07eb2ba]
- Updated dependencies [20b3d1f]
- Updated dependencies [4cd691e]
- Updated dependencies [5a20552]
- Updated dependencies [8f0a320]
- Updated dependencies [7d55d86]
- Updated dependencies [00b5b66]
- Updated dependencies [2a926ba]
- Updated dependencies [b99caca]
- Updated dependencies [4cd691e]
- Updated dependencies [6222bf2]
- Updated dependencies [77409b1]
- Updated dependencies [53ab25e]
- Updated dependencies [4cd691e]
- Updated dependencies [d5f026b]
- Updated dependencies [7ad3022]
- Updated dependencies [6c292a3]
- Updated dependencies [cb58f6f]
- Updated dependencies [7242aa5]
- Updated dependencies [45a783c]
- Updated dependencies [33fcbb0]
- Updated dependencies [c06a4e9]
- Updated dependencies [311e32d]
- Updated dependencies [67bfbe5]
- Updated dependencies [20a894d]
- Updated dependencies [41abf90]
- Updated dependencies [1e48739]
- Updated dependencies [de1e03c]
- Updated dependencies [e66329b]
- Updated dependencies [62eef66]
- Updated dependencies [40e3d82]
- Updated dependencies [9593983]
- Updated dependencies [9433f96]
- Updated dependencies [7916018]
- Updated dependencies [6881eb0]
- Updated dependencies [4cd691e]
- Updated dependencies [16f1fda]
- Updated dependencies [9a26e88]
- Updated dependencies [8685326]
- Updated dependencies [e2026d6]
- Updated dependencies [8c5b013]
- Updated dependencies [eba909b]
- Updated dependencies [2f6adc9]
- Updated dependencies [f115678]
- Updated dependencies [07dd074]
  - @zntc/core@0.1.4

## 0.1.3

### Patch Changes

- Updated dependencies [c608d1b]
- Updated dependencies [b0d6898]
- Updated dependencies [b91fc85]
- Updated dependencies [872bf64]
- Updated dependencies [f91a98b]
- Updated dependencies [1f92385]
  - @zntc/core@0.1.3

## 0.1.2

### Patch Changes

- Updated dependencies [ab2c450]
  - @zntc/core@0.1.2
