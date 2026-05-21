# @zntc/example-rspack

`@zntc/rspack-loader` 를 rspack 의 `.tsx` loader 로 써서 React 19 앱을 빌드·서빙하는 예제.
swc-loader / babel-loader / esbuild-loader 자리에 ZNTC 를 끼우는 구성.

## 동작 원리

```
파일 변경
   ↓
@zntc/rspack-loader — ZNTC 가 TS strip + JSX automatic runtime 변환 (+ 소스맵 생성)
   ↓
rspack — 모듈 그래프 · 번들 · HMR · dev server
   ↓
브라우저
```

`rspack.config.mjs` 의 핵심:

- `transpileOptions.sourcemap: true` + `devtool: "source-map"` — 둘 다 켜야 DevTools
  Sources 에서 변환 결과(`_jsx(...)`)가 아닌 **원본 `.tsx`** 가 보인다. 끄면 loader 가
  rspack 에 map 을 넘기지 못해 디버깅 시 변환 코드가 그대로 노출된다.
- `@rspack/dev-server` 는 `@rspack/core` 와 메이저 버전이 일치해야 한다 (`^2.0.1`).

## 실행

```bash
bun run dev      # rspack serve — http://localhost:8080/ (기본 포트)
bun run build    # NODE_ENV=production rspack build → dist/
```

호스트/포트를 바꾸려면 CLI flag 로:

```bash
bun run dev -- --host 0.0.0.0 --port 12308
```
