import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { zntc } from "@zntc/vite-plugin";

// React 19 의 babel-plugin-react-compiler 를 Vite 의 babel 단계에서 적용하고,
// 나머지 TS / 번들 변환은 ZNTC 로 위임한다.
// 순서: plugin-react 가 먼저 transform 후크에서 JSX 를 *보존한 채* 자동 메모이제이션을
// 삽입 → zntc 가 그 결과를 받아 TS strip + JSX automatic runtime + 번들.
export default defineConfig({
  plugins: [
    react({
      babel: {
        plugins: [["babel-plugin-react-compiler", { target: "19" }]],
      },
    }),
    zntc(),
  ],
});
