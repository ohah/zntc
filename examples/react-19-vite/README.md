# @zntc/example-react-19-vite

React 19 의 `babel-plugin-react-compiler` (자동 메모이제이션) 와 ZNTC 를 Vite 환경에서 함께 쓰는 예제.

## 동작 원리

```
파일 변경
   ↓
@vitejs/plugin-react (babel) — babel-plugin-react-compiler 적용 (JSX 보존)
   ↓
@zntc/vite-plugin — TS strip + JSX automatic runtime + 번들
   ↓
브라우저
```

`vite.config.ts` 의 plugin 순서가 위 흐름을 보장한다. plugin-react 가 transform 후크에서
먼저 동작해 컴파일러가 JSX 가 살아있는 AST 를 보고, 그 결과를 ZNTC 가 받아 마무리.

## 실행

```bash
# 루트에서
bun install

# dev
cd examples/react-19-vite && bun run dev

# 프로덕션 빌드
cd examples/react-19-vite && bun run build

# 빌드 결과 미리보기
cd examples/react-19-vite && bun run preview
```

`dev` / `build` script 는 실행 전에 `packages/core` JS dist 를 자동으로 빌드한다.

## 지원하는 기능

- React 19 (Server Components, Actions, `useOptimistic` 등) — 라이브러리 차원의 기능은 그대로 사용 가능
- `babel-plugin-react-compiler` 자동 메모이제이션 — `useMemo` / `useCallback` 을 거의 쓸 필요 없게 됨
- ZNTC 의 TS strip, JSX automatic runtime, Fast Refresh

## 한계

- react-compiler 의 동작 자체는 babel runtime 위에서 돌아간다 — ZNTC 단일 바이너리로 끝나지 않음.
  ZNTC 단독 어댑터는 `examples/react-19-zntc/` 참고.
- React Compiler 가 RC/실험 단계라 패턴 인식 규칙이 변할 수 있다.
- `babel-plugin-react-compiler` 의 `target` 옵션은 React minor 버전 (`"17"` | `"18"` | `"19"`) 만 받는다 — 컴파일러가 생성하는 helper 의 호환 대상이다.
- `@vitejs/plugin-react` v5 의 `babel.plugins` 형태 기준. v6 부터는 내부 babel 이 분리되어 `@rolldown/plugin-babel` + 별도 preset 으로 바뀐다.
