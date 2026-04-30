import { defineConfig } from "@zts/core";

export default defineConfig({
  entryPoints: ["src/main.tsx"],
  outdir: "dist",
  format: "esm",
  platform: "browser",
  target: "es2022",
  jsx: "automatic",
  sourcemap: true,
  // styled-components / react / emotion 의 production guard (`process.env.NODE_ENV`)
  // 가 번들에 살아남으면 브라우저에서 `ReferenceError: process is not defined`.
  // Vite 가 dev mode 에서 자동 주입하는 것과 동등.
  define: {
    "process.env.NODE_ENV": '"development"',
  },
  // compiler 네임스페이스 — @next/swc 와 동일한 surface.
  // styled-components: displayName / componentId / withConfig 래핑 / chain 인식 / 사용자
  //                    .withConfig MERGE / IIFE & control-flow return walker / CSS minify
  //                    (옵션 minify: true 시).
  // emotion: autoLabel — css / keyframes / @emotion/styled (default styled.X / styled(X))
  //          모두 첫 quasi 에 `label:<varname>;` prepend.
  compiler: {
    styledComponents: { ssr: true, minify: true },
    emotion: true,
  },
});
