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
      defaultLocale: "root",
      locales: {
        root: { label: "한국어", lang: "ko" },
        en: { label: "English", lang: "en" },
      },
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
          translations: { en: "Getting Started" },
          items: [
            { label: "소개", slug: "guides/introduction", translations: { en: "Introduction" } },
            { label: "설치", slug: "guides/installation", translations: { en: "Installation" } },
            { label: "빠른 시작", slug: "guides/quick-start", translations: { en: "Quick Start" } },
          ],
        },
        {
          label: "가이드",
          translations: { en: "Guides" },
          items: [
            { label: "트랜스파일", slug: "guides/transpile", translations: { en: "Transpile" } },
            { label: "번들링", slug: "guides/bundling", translations: { en: "Bundling" } },
            { label: "플러그인", slug: "guides/plugins", translations: { en: "Plugins" } },
            { label: "React Native", slug: "guides/react-native" },
          ],
        },
        {
          label: "레퍼런스",
          translations: { en: "Reference" },
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
