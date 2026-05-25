/**
 * `@zntc/web/css` — ZTS dev/build 의 CSS pipeline plugin (#2538 4-4 PR-2).
 *
 * 사용자가 명시 안 해도 controller 가 default 로 등록 (#2538 4-4 PR-3 에서 wiring).
 * 명시적으로 끄거나 옵션 override 하려면 zntc.config 에 `plugins: [css(...)]` 추가.
 *
 * Vite 의 `vite:css` plugin 과 같은 역할 — postcss.config.js 자동 발견 (Vite 정확
 * 패턴) + `css({ postcss: { plugins } })` 명시 override. 둘 다 지원.
 *
 * 현 PR-2 의 scope = factory + ZntcPlugin shape + .css 파일 onLoad PostCSS 통과
 * (minimal). Sass / CSS Modules 는 follow-up commit.
 */

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

import type { ZntcPlugin } from '@zntc/core';

import { loadPostcssConfig } from '../style/postcss.ts';

export interface CssPluginOptions {
  /** plugin 전체 비활성. 사용자가 `plugins:[css()]` 명시했지만 특정 빌드에서 끄고 싶을 때. */
  disabled?: boolean;
  /**
   * PostCSS override. 미지정 시 ZTS 가 postcss.config.js 자동 발견 (Vite 패턴).
   * 명시 시 자동 발견 무시하고 해당 plugins 사용.
   */
  postcss?: {
    plugins?: unknown[];
    options?: Record<string, unknown>;
  };
  /**
   * postcss.config 검색의 root. 미지정 시 process.cwd().
   * Vite 의 `css.postcss` 또는 `process.cwd()` 와 동일 의미.
   */
  root?: string;
  /**
   * postcss-load-config 의 `env` 로 전달 — postcss.config.js 가 factory 형식
   * `({ mode }) => ({...})` 일 때 사용. 미지정 시 `process.env.NODE_ENV` 또는
   * `'development'` (dev safer). Vite 의 `css.postcss` env parity.
   */
  mode?: 'development' | 'production';
}

/**
 * CSS pipeline plugin factory. ZTS dev / build pipeline 의 `.css` 파일 onLoad 시
 * PostCSS pass 적용 (autoprefixer / preset-env 등 postcss.config 의 plugin들).
 *
 * @example
 * ```ts
 * // zero-config — postcss.config.js 자동 발견
 * export default defineConfig({ plugins: [css()] });
 *
 * // override
 * export default defineConfig({
 *   plugins: [css({ postcss: { plugins: [autoprefixer()] } })],
 * });
 *
 * // disable
 * export default defineConfig({ plugins: [css({ disabled: true })] });
 * ```
 */
export function css(options: CssPluginOptions = {}): ZntcPlugin {
  return {
    name: '@zntc/web/css',
    setup(build) {
      if (options.disabled) return;

      // `.module.css` 는 CSS Modules 처리 path 라 본 plugin 의 raw PostCSS 통과
      // 대상에서 제외. negative-lookbehind 로 `.module.css` 매치 방지.
      build.onLoad({ filter: /(?<!\.module)\.css$/ }, async (args) => {
        // 파일 read — onLoad 의 caller 가 contents 직접 안 줌. 우리가 fs 호출.
        const input = readFileSync(args.path, 'utf8');

        // override 가 있으면 그 plugins 사용. 미지정 시 postcss.config 자동 발견.
        const root = options.root ?? process.cwd();
        const fallbackRequire = createRequire(import.meta.url);
        const mode =
          options.mode ??
          ((process.env.NODE_ENV === 'production' ? 'production' : 'development') as
            | 'development'
            | 'production');

        let plugins: unknown[];
        let postcssOptions: Record<string, unknown>;
        let postcssModule: { (plugins?: unknown[]): { process: PostcssProcess } };

        const overridePlugins = options.postcss?.plugins;
        if (overridePlugins && overridePlugins.length > 0) {
          // override path — 사용자가 명시한 plugins 사용. 빈 배열 (`.length === 0`)
          // 은 round-trip 만 발생시킬 무의미 호출이라 pass-through.
          try {
            postcssModule = (await import('postcss')).default as typeof postcssModule;
          } catch {
            return { contents: input }; // postcss 미설치 시 pass-through
          }
          plugins = overridePlugins;
          postcssOptions = options.postcss?.options ?? {};
        } else {
          // zero-config path — postcss.config 자동 발견 (Vite 패턴). postcss /
          // postcss-load-config 미설치 시 silent pass-through (optionalDependencies
          // 정합 — packages/web/package.json 의 optional 선언과 일치).
          let loaded;
          try {
            loaded = await loadPostcssConfig(root, { mode }, fallbackRequire);
          } catch {
            return { contents: input };
          }
          if (!loaded) return { contents: input };
          plugins = loaded.plugins;
          postcssOptions = loaded.options ?? {};
          postcssModule = loaded.postcss as typeof postcssModule;
        }

        const result = await postcssModule(plugins).process(input, {
          ...postcssOptions,
          from: args.path,
          to: args.path,
        });

        return {
          contents: result.css,
          map: result.map?.toString(),
          loader: 'css',
        };
      });
    },
  };
}

interface PostcssProcess {
  (
    input: string,
    options: { from: string; to: string; [k: string]: unknown },
  ): Promise<{ css: string; map?: { toString(): string } }>;
}
