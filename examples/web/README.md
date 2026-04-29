# @zts/example-web

ZTS 의 웹 빌드 / dev server 검증용 예제 앱. styled-components 와 emotion 의 주요 패턴을 모아 향후 1st-party transform 의 회귀 테스트 베이스로 사용.

## 실행

```bash
# 루트에서
bun install

# dev (HMR)
cd examples/web && bun run dev

# 프로덕션 빌드
cd examples/web && bun run build

# 빌드 결과 미리보기
cd examples/web && bun run preview
```

`zts.config.ts` 에 이미 `compiler.styledComponents: true` / `compiler.emotion: true` 가 선언돼 있지만, **현재는 타입 stub 단계라 런타임 효과는 없습니다**. 두 라이브러리 자체의 런타임으로 모든 기능이 동작.

## 데모 케이스

### styled-components (`src/styled-cases.tsx`)
1. 기본 `styled.div\`...\``
2. Props interpolation (`${({$primary}) => ...}`)
3. `styled(Component)` 확장
4. `.attrs()` default props
5. `keyframes` 애니메이션
6. `css\`...\`` helper 재사용
7. `createGlobalStyle`

### emotion (`src/emotion-cases.tsx`)
1. `css={...}` prop
2. `@emotion/styled`
3. 동적 css 함수 (autoLabel 검증)
4. `<Global styles={...} />`

## 향후 1st-party transform 이 추가할 변환

### styled-components
- **displayName** — devtools 에 컴포넌트 이름 표시 (`Card`, `Button`, ...)
- **componentId** — 결정론적 hash 로 SSR hydration mismatch 방지
- **정적 CSS hoist** — 매 렌더 재할당 방지
- **CSS minify** — 화이트스페이스 제거

레퍼런스: `references/styled-components-babel/`, `references/swc-plugins/packages/styled-components/`

### emotion
- **autoLabel** — 변수명을 CSS class label 로 자동 부여
- **sourceMap** — CSS 위치 → 원본 .tsx 역추적
- **cssPropOptimization** — `css={...}` 정적 hoist
- **hash 안정화** — SSR hydration

레퍼런스: `references/emotion/packages/babel-plugin/`, `references/swc-plugins/packages/emotion/`

## 옵션 surface (next.config.js 호환)

```ts
defineConfig({
  compiler: {
    styledComponents: true,
    // 또는 세밀하게:
    // styledComponents: {
    //   displayName: true,
    //   ssr: true,
    //   fileName: true,
    //   minify: true,
    //   transpileTemplateLiterals: true,
    // },
    emotion: true,
    // 또는:
    // emotion: {
    //   sourceMap: true,
    //   autoLabel: "dev-only",  // "always" | "dev-only" | "never"
    //   labelFormat: "[local]",
    // },
  },
});
```

`@next/swc` 의 `compiler.styledComponents` / `compiler.emotion` 와 동일한 surface 를 의도. Next.js 사용자가 mental model 그대로 이전 가능.

## 회귀 검증 메모

- **HMR**: styled / css 인터폴레이션 변경 시 모듈만 교체되는지 (전체 새로고침 아님) 확인
- **sourcemap**: `.tsx` 라인이 devtools 에서 매핑되는지
- **production minify**: 클래스명/CSS 가 축약되는지
- **번들 크기**: tree-shake 후 emotion / styled-components 의 dead path 제거 여부
