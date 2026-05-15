import { defineConfig, type ZntcPlugin } from "@zntc/core";
import { transformAsync } from "@babel/core";

// react-compiler 어댑터: ZNTC 의 onTransform 훅에서 @babel/core 를 호출해
// babel-plugin-react-compiler 를 적용한다. JSX/TS strip 은 그 뒤 ZNTC 본체가 처리하므로
// 이 plugin 은 *JSX 가 살아있는 상태* 의 코드를 babel 로 넘겨야 한다 — 그래야 컴파일러가
// reactive scope 를 정확히 추론한다.
const reactCompilerPlugin: ZntcPlugin = {
  name: "react-compiler-adapter",
  setup(build) {
    build.onTransform({ filter: /\.[jt]sx$/ }, async ({ code, path }) => {
      // ZNTC 의 onTransform 은 user file / node_modules 를 구분 없이 dispatch 한다.
      // react-compiler 는 React 컴포넌트 분석 비용이 적지 않아 node_modules tsx/jsx
      // 까지 거치면 빌드 시간 폭증 — 사용자 코드만 통과시킨다.
      if (path.includes("/node_modules/")) return null;
      const result = await transformAsync(code, {
        filename: path,
        babelrc: false,
        configFile: false,
        parserOpts: { plugins: ["jsx", "typescript"] },
        plugins: [["babel-plugin-react-compiler", { target: "19" }]],
        sourceMaps: true,
      });
      if (!result?.code) return null;
      return { code: result.code, map: result.map };
    });
  },
};

export default defineConfig({
  entryPoints: ["src/main.tsx"],
  outdir: "dist",
  format: "esm",
  platform: "browser",
  target: "es2022",
  jsx: "automatic",
  sourcemap: true,
  plugins: [reactCompilerPlugin],
});
