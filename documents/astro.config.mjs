// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import react from '@astrojs/react';
import tailwindcss from '@tailwindcss/vite';
import starlightLinksValidator from 'starlight-links-validator';
import starlightTypeDoc, { typeDocSidebarGroup } from 'starlight-typedoc';

// https://astro.build/config
export default defineConfig({
  site: 'https://ohah.github.io',
  base: '/zntc',
  integrations: [
    starlight({
      title: 'ZNTC',
      description: 'Zig Native Transpiler & Compiler',
      expressiveCode: {
        themes: ['github-dark', 'github-light'],
        styleOverrides: {
          borderRadius: '0.375rem',
          codePaddingBlock: '0.875rem',
          codePaddingInline: '1.125rem',
          codeFontSize: '0.875rem',
          codeLineHeight: '1.7',
          frames: {
            shadowColor: 'rgba(0, 0, 0, 0.12)',
          },
        },
        defaultProps: {
          showLineNumbers: false,
          wrap: false,
        },
      },
      plugins: [
        starlightLinksValidator({
          exclude: [
            '/zntc/playground/',
            '/zntc/en/playground/',
            '/zntc/analyze/',
            '/zntc/en/analyze/',
          ],
        }),
        starlightTypeDoc({
          entryPoints: ['../packages/core/index.ts'],
          tsconfig: '../packages/core/tsconfig.json',
          output: 'reference/api',
          sidebar: {
            label: 'API Reference',
            collapsed: true,
          },
          typeDoc: {
            excludePrivate: true,
            excludeInternal: true,
          },
        }),
      ],
      defaultLocale: 'root',
      locales: {
        root: { label: '한국어', lang: 'ko' },
        en: { label: 'English', lang: 'en' },
      },
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/ohah/zntc',
        },
      ],
      sidebar: [
        {
          label: '가이드',
          translations: { en: 'Guides' },
          items: [
            { label: '소개', slug: 'guides/introduction', translations: { en: 'Introduction' } },
            { label: '설치', slug: 'guides/installation', translations: { en: 'Installation' } },
            { label: '빠른 시작', slug: 'guides/quick-start', translations: { en: 'Quick Start' } },
            { label: '설정 파일', slug: 'guides/config-file', translations: { en: 'Config File' } },
          ],
        },
        {
          label: '트랜스파일',
          translations: { en: 'Transpile' },
          items: [
            { label: '개요', slug: 'guides/transpile', translations: { en: 'Overview' } },
            {
              label: '네이티브 트랜스폼 (Babel 없이)',
              slug: 'guides/native-transforms',
              translations: { en: 'Native Transforms (No Babel)' },
            },
          ],
        },
        {
          label: '번들러',
          translations: { en: 'Bundler' },
          items: [
            { label: '개요', slug: 'guides/bundling', translations: { en: 'Overview' } },
            {
              label: '트리쉐이킹',
              slug: 'guides/tree-shaking',
              translations: { en: 'Tree-shaking' },
            },
            {
              label: '런타임 폴리필 (core-js)',
              slug: 'guides/runtime-polyfills',
              translations: { en: 'Runtime Polyfills (core-js)' },
            },
            {
              label: 'manualChunks',
              slug: 'guides/manual-chunks',
              translations: { en: 'manualChunks' },
            },
            {
              label: 'Module Federation',
              slug: 'guides/module-federation',
              translations: { en: 'Module Federation' },
            },
            {
              label: '구조와 동작 원리',
              slug: 'guides/bundler-deep-dive',
              translations: { en: 'Architecture & Internals' },
            },
          ],
        },
        {
          label: '플러그인',
          translations: { en: 'Plugins' },
          items: [
            { label: '플러그인', slug: 'guides/plugins', translations: { en: 'Plugins' } },
            {
              label: '플러그인 레시피',
              slug: 'guides/plugin-recipes',
              translations: { en: 'Plugin Recipes' },
            },
            {
              label: 'Rspack / Webpack 통합',
              slug: 'guides/rspack-loader',
              translations: { en: 'Rspack / Webpack' },
            },
          ],
        },
        {
          label: '마이그레이션',
          translations: { en: 'Migration' },
          items: [
            {
              label: '도구 비교',
              slug: 'guides/comparison',
              translations: { en: 'Tool Comparison' },
            },
            {
              label: '다른 도구에서 이관',
              slug: 'guides/migration',
              translations: { en: 'From Other Tools' },
            },
            {
              label: 'Babel 이관 (RN)',
              slug: 'guides/babel-migration',
              translations: { en: 'Babel Migration (RN)' },
            },
          ],
        },
        {
          label: '레시피',
          translations: { en: 'Recipes' },
          items: [
            { label: 'Dev Server (SSE/MCP)', slug: 'guides/dev-server' },
            {
              label: 'Module Federation 예제',
              slug: 'guides/module-federation-recipe',
              translations: { en: 'Module Federation Example' },
            },
            { label: 'Electron', slug: 'guides/electron' },
            { label: 'Vite', slug: 'guides/vite' },
            { label: 'Rspack / Webpack', slug: 'guides/rspack' },
            { label: 'Web (standalone)', slug: 'guides/web-starter' },
            {
              label: '라이브러리 빌드',
              slug: 'guides/library',
              translations: { en: 'Library Build' },
            },
            { label: 'React Native', slug: 'guides/react-native' },
            { label: 'React Native + Expo', slug: 'guides/react-native-expo' },
            {
              label: 'Flow 지원',
              slug: 'guides/flow-support',
              translations: { en: 'Flow Support' },
            },
          ],
        },
        {
          label: '레퍼런스',
          translations: { en: 'Reference' },
          items: [
            { label: 'CLI', slug: 'reference/cli', translations: { en: 'CLI' } },
            {
              label: 'NAPI / JS API',
              slug: 'reference/napi',
              translations: { en: 'NAPI / JS API' },
            },
            {
              label: 'Transpile 옵션',
              slug: 'reference/options',
              translations: { en: 'Transpile Options' },
            },
            {
              label: '옵션 매트릭스',
              slug: 'reference/options-matrix',
              translations: { en: 'Options Matrix' },
            },
            { label: '벤치마크', slug: 'reference/benchmarks', translations: { en: 'Benchmarks' } },
            { label: 'Metafile 분석', link: '/analyze/', translations: { en: 'Metafile Analyze' } },
            { label: '로드맵', slug: 'roadmap', translations: { en: 'Roadmap' } },
            {
              label: '에러 코드',
              translations: { en: 'Error Codes' },
              collapsed: true,
              // Starlight v0.39: autogenerated groups must be nested under `items`
              items: [{ autogenerate: { directory: 'reference/errors' } }],
            },
          ],
        },
        typeDocSidebarGroup,
        {
          label: 'Playground',
          items: [
            {
              label: '트랜스파일러',
              link: '/playground/',
              translations: { en: 'Transpiler' },
            },
            {
              label: '번들러',
              link: '/playground/bundler/',
              translations: { en: 'Bundler' },
            },
          ],
        },
      ],
      customCss: ['./src/styles/tailwind.css', './src/styles/custom.css'],
      components: {
        PageTitle: './src/overrides/PageTitle.astro',
      },
    }),
    react(),
  ],
  vite: {
    plugins: [tailwindcss()],
    ssr: {
      noExternal: ['@monaco-editor/react', 'echarts-for-react'],
    },
    // SharedArrayBuffer 사용 (#1885 Phase 2 — bundler WASM 의 wasm32-wasi+threads).
    // dev 서버에서 COOP/COEP 헤더 set 으로 cross-origin isolation 활성. prod 환경
    // (GitHub Pages) 은 헤더 set 불가 — coi-serviceworker 로 우회 (별도 PR).
    server: {
      headers: {
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp',
      },
    },
  },
});
