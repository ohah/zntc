// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import react from "@astrojs/react";

// https://astro.build/config
export default defineConfig({
  site: "https://ohah.github.io",
  base: "/zts",
  integrations: [
    starlight({
      title: "ZTS",
      description: "Zig TypeScript Transpiler & Bundler",
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/ohah/zts",
        },
      ],
      sidebar: [
        {
          label: "시작하기",
          items: [
            { label: "소개", slug: "guides/introduction" },
            { label: "설치", slug: "guides/installation" },
            { label: "빠른 시작", slug: "guides/quick-start" },
          ],
        },
        {
          label: "가이드",
          items: [
            { label: "트랜스파일", slug: "guides/transpile" },
            { label: "번들링", slug: "guides/bundling" },
            { label: "플러그인", slug: "guides/plugins" },
            { label: "React Native", slug: "guides/react-native" },
          ],
        },
        {
          label: "레퍼런스",
          autogenerate: { directory: "reference" },
        },
        {
          label: "Playground",
          items: [{ label: "Playground", slug: "playground" }],
        },
      ],
      customCss: ["./src/styles/custom.css"],
    }),
    react(),
  ],
  vite: {
    ssr: {
      noExternal: ["@monaco-editor/react"],
    },
  },
});
