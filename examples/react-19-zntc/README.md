# @zntc/example-react-19-zntc

React 19 의 `babel-plugin-react-compiler` (자동 메모이제이션) 를 **Vite 없이 ZNTC 단일 파이프라인** 에서 사용하는 예제. `zntc.config.ts` 안에 onTransform 어댑터 plugin 을 정의해 babel 을 위임한다.

## 동작 원리

```
파일 변경
   ↓
ZNTC pipeline 진입
   ↓
onTransform({ filter: /\.[jt]sx$/ }) — @babel/core 호출, babel-plugin-react-compiler 적용
   ↓
ZNTC 본체 — TS strip + JSX automatic runtime + 번들 + Fast Refresh
   ↓
브라우저
```

핵심은 onTransform 콜백이 babel 결과 (JSX 가 *살아있는* 코드 + 자동 메모이제이션) 를 반환하고,
ZNTC 가 그 결과를 받아 나머지 변환을 마무리한다는 점.

## 실행

```bash
# 루트에서
bun install

# dev (HMR + Fast Refresh)
cd examples/react-19-zntc && bun run dev

# 프로덕션 빌드
cd examples/react-19-zntc && bun run build

# 빌드 결과 미리보기
cd examples/react-19-zntc && bun run preview
```

`dev` / `build` / `preview` script 는 실행 전에 `packages/core` JS dist 를 자동으로 빌드한다.

## Vite 예제와의 선택 기준

Vite 생태계 (HMR overlay, vite plugin, vite preview) 를 이미 쓰고 있다면 `examples/react-19-vite/` 가 자연스럽다. ZNTC 단일 도구로 dev/build/preview 까지 끝내고 싶다면 이쪽이다. 기능적 결과 (자동 메모이제이션 적용 여부) 는 같다.

## 한계

- babel runtime 자체는 여전히 Node 위에서 돈다 — *단일 zig 바이너리* 가 아니다. babel-plugin-react-compiler 가 자체 IR / 데이터흐름 분석을 하므로 ZNTC 가 그 일부를 Zig 로 재구현하는 건 별도 큰 작업.
- onTransform 콜백이 파일마다 babel 을 호출 — `node_modules` 같은 큰 트리는 filter 정규식으로 제외해야 빌드 시간 안정.
- React Compiler 가 RC/실험 단계라 패턴 인식 규칙이 변할 수 있다.
