/**
 * Mermaid / ECharts / 기타 canvas-rendered surface 가 사용하는 hex 토큰.
 * `documents/src/styles/tailwind.css` 의 `--color-zig-*` / `--color-surface-*` 와 1:1 sync.
 *
 * 왜 CSS variable 을 직접 못 쓰나: mermaid 는 themeVariables 를 받아 SVG attribute 로 직렬화하고,
 * ECharts 는 canvas 렌더링이라 `var(--color-...)` 문자열을 그대로 fill/stroke 로 보낸다.
 * computed style 을 읽어주는 단계가 없어 raw hex 가 필요.
 * 한쪽 갱신 시 tailwind.css 의 동일 토큰도 함께 수정할 것.
 */

export const ZIG = {
  50: "#fff7ed",
  100: "#ffedd5",
  200: "#fed7aa",
  300: "#fdba74",
  400: "#fb923c",
  500: "#f7a41d",
  600: "#ea580c",
  700: "#c2410c",
  800: "#9a3412",
  900: "#7c2d12",
  950: "#431407",
} as const;

export const SURFACE = {
  50: "#fafaf9",
  100: "#f5f5f4",
  200: "#e7e5e4",
  300: "#d6d3d1",
  400: "#a8a29e",
  500: "#78716c",
  600: "#57534e",
  700: "#3a3432",
  800: "#2a2422",
  900: "#1c1816",
  950: "#141110",
} as const;
