// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import react from "@astrojs/react";
import tailwindcss from "@tailwindcss/vite";
import starlightLinksValidator from "starlight-links-validator";
import starlightTypeDoc, { typeDocSidebarGroup } from "starlight-typedoc";

// https://astro.build/config
export default defineConfig({
  site: "https://ohah.github.io",
  base: "/zts",
  integrations: [
    starlight({
      title: "ZTS",
      description: "Zig TypeScript Transpiler & Bundler",
      expressiveCode: {
        themes: ["github-dark", "github-light"],
        styleOverrides: {
          borderRadius: "0.375rem",
          codePaddingBlock: "0.875rem",
          codePaddingInline: "1.125rem",
          codeFontSize: "0.875rem",
          codeLineHeight: "1.7",
          frames: {
            shadowColor: "rgba(0, 0, 0, 0.12)",
          },
        },
        defaultProps: {
          showLineNumbers: false,
          wrap: false,
        },
      },
      plugins: [
        starlightLinksValidator({ exclude: ["/zts/playground/", "/zts/en/playground/"] }),
        starlightTypeDoc({
          entryPoints: ["../packages/core/index.ts"],
          tsconfig: "../packages/core/tsconfig.json",
          output: "reference/api",
          sidebar: {
            label: "API Reference",
            collapsed: false,
          },
          typeDoc: {
            excludePrivate: true,
            excludeInternal: true,
          },
        }),
      ],
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
            { label: "플러그인 레시피", slug: "guides/plugin-recipes", translations: { en: "Plugin Recipes" } },
            { label: "마이그레이션", slug: "guides/migration", translations: { en: "Migration" } },
            { label: "React Native", slug: "guides/react-native" },
          ],
        },
        {
          label: "레퍼런스",
          translations: { en: "Reference" },
          autogenerate: { directory: "reference" },
        },
        typeDocSidebarGroup,
        {
          label: "Playground",
          items: [{ label: "Playground", link: "/playground/" }],
        },
      ],
      customCss: ["./src/styles/custom.css"],
    }),
    react(),
  ],
  vite: {
    plugins: [tailwindcss()],
    ssr: {
      noExternal: ["@monaco-editor/react", "echarts-for-react"],
    },
  },
});
