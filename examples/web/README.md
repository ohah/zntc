# @zts/example-web

ZTS 의 웹 빌드 / dev server 검증용 예제 앱. styled-components 와 emotion 의 주요 패턴을 모아 1st-party transform 의 회귀 테스트 베이스.

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

`zts.config.ts` 에서 `compiler.styledComponents` / `compiler.emotion` 활성. 두 transform 모두 1st-party 로 ZTS 안에서 동작 (별도 babel/swc plugin 불필요).

## 현재 지원되는 transform

### styled-components

| 기능 | 상태 | 비고 |
|---|---|---|
| `displayName` 자동 부여 | ✅ | DevTools 컴포넌트 이름 |
| `componentId` (hash + counter) | ✅ | SSR hydration 안정화. `ssr: false` 로 끄기 |
| `withConfig({...})` 래핑 | ✅ | babel/swc 표준 출력 형태 |
| chain `.attrs()` / `.withConfig()` | ✅ | rewriter 가 chain 중간 swap |
| 사용자 명시 `.withConfig` MERGE | ✅ | 사용자 key 보존, ZTS 누락만 prepend |
| ternary / 논리 / TS cast / IIFE / control flow | ✅ | wrappable expression walker |
| 클래스 정적/인스턴스 필드 | ✅ | field key → displayName |
| object property | ✅ | property key → displayName |
| assignment | ✅ | LHS identifier → displayName |
| CSS minify | ✅ (`minify: true`) | no-interp + interp 모두 |

### emotion

| 기능 | 상태 | 비고 |
|---|---|---|
| `import { css }` autoLabel | ✅ | `\`label:X;...\`` prepend |
| `@emotion/styled` (default) | ✅ | `styled.div\`...\`` / `styled(X)\`...\`` |
| `import { keyframes }` autoLabel | ✅ | animation name 으로 사용 |
| 4 source 인식 | ✅ | `@emotion/react|css|core|native` |
| alias (`{ css as cx }`, `import s from ...`) | ✅ | binding 추적 |

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
1. `css\`...\`` (cardCss)
2. `@emotion/styled` (Pill, FadeBox)
3. 동적 css 함수 (focusableInput)
4. `keyframes` (fadeIn) + animation
5. `<Global styles={...} />`

## 빌드 결과 확인

```bash
cd examples/web && bun run build
# 출력의 main-*.js 에서:
grep -E '\.withConfig' dist/main-*.js  # styled-components 6개
grep -oE 'label:[a-zA-Z]+;' dist/main-*.js | sort -u  # emotion 5개
```

## 옵션 surface (`@next/swc` 호환)

```ts
defineConfig({
  compiler: {
    styledComponents: true,
    // 또는 세밀하게:
    // styledComponents: {
    //   ssr: false,    // SSR 안 쓰면 componentId 생략 (bundle size 절감)
    //   minify: true,  // CSS template whitespace collapse
    // },
    emotion: true,
  },
});
```

## 미지원 (후속 PR)

- emotion `<div css={...}>` prop hoist
- emotion sourceMap 라벨링
- emotion chain `css.x\`...\``
- styled-components `transpileTemplateLiterals` (ES5 target)
- CSS-aware minify (`;{}:` 주변 정리)

## 레퍼런스

- styled-components: `references/styled-components-babel/`, `references/swc-plugins/packages/styled-components/`
- emotion: `references/emotion/packages/babel-plugin/`, `references/swc-plugins/packages/emotion/`
