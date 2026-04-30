import { defineConfig } from "@zts/core";

export default defineConfig({
  entryPoints: ["src/main.tsx"],
  outdir: "dist",
  format: "esm",
  platform: "browser",
  target: "es2022",
  jsx: "automatic",
  sourcemap: true,
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
