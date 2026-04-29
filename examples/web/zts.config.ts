import { defineConfig } from "@zts/core";

export default defineConfig({
  entryPoints: ["src/main.tsx"],
  outdir: "dist",
  format: "esm",
  platform: "browser",
  target: "es2022",
  jsx: "automatic",
  sourcemap: true,
  // compiler 네임스페이스 — @next/swc 와 동일한 surface 를 따름.
  // 현재는 타입 stub 단계: Zig transformer 가 아직 인식하지 않으므로 런타임 효과 없음.
  // 후속 PR (#TBD) 에서 styled-components / emotion 1st-party transform 도입 시 활성화.
  compiler: {
    styledComponents: true,
    emotion: true,
  },
});
