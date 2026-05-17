// React Native runtime injection plugin — Metro 의 HMRClient.js 를 ZNTC HMR
// runtime (`runtime/zntc-hmr-client.js`) 으로 교체 + RN source asset transformer
// 통합. Asset registry / scale variant 처리는 ZNTC 코어가 직접 (preset 의
// assetRegistry/loader/alias 옵션) 처리한다.

import { readFileSync } from 'node:fs';
import { basename, extname } from 'node:path';

import type { ZntcPlugin } from '@zntc/core';

import { HMR_CLIENT_SUFFIX, ZNTC_HMR_CLIENT_CODE } from '../runtime-loader.ts';
import { escapeRegex } from './escape-regex.ts';
import { getErrorMessage, normalizeExt, requireFromCli } from './internal.ts';
import type { PluginConfig } from './types.ts';

interface MetroTransformerResult {
  code?: string;
  ast?: unknown;
}

interface MetroTransformer {
  transform(args: {
    src: string;
    filename: string;
    options: {
      platform: 'ios' | 'android';
      dev: boolean;
      hot: boolean;
      projectRoot: string;
    };
  }): Promise<MetroTransformerResult> | MetroTransformerResult;
}

// SVGR/react-native-svg-transformer 와 동일하게 `Svg{Pascal}` 형태 — 사용자가
// 두 transformer 사이를 옮길 때 컴포넌트 이름 변하지 않도록.
function svgComponentName(filePath: string): string {
  const pascal = basename(filePath, extname(filePath))
    .split(/[^A-Za-z0-9_$]+/)
    .filter(Boolean)
    .map((part) => part[0]!.toUpperCase() + part.slice(1))
    .join('');
  return pascal ? `Svg${pascal}` : 'SvgComponent';
}

export function createSvgComponentModule(svg: string, filePath: string): string {
  const componentName = svgComponentName(filePath);
  return [
    `import * as React from 'react';`,
    `import { SvgXml } from 'react-native-svg';`,
    ``,
    `const xml = ${JSON.stringify(svg)};`,
    ``,
    `function ${componentName}(props) {`,
    `  return React.createElement(SvgXml, Object.assign({ xml }, props));`,
    `}`,
    ``,
    `${componentName}.displayName = ${JSON.stringify(componentName)};`,
    ``,
    `export default ${componentName};`,
    ``,
  ].join('\n');
}

/**
 * RN runtime 통합 plugin:
 * - Metro HMRClient.js path → ZNTC HMR runtime (`runtime/zntc-hmr-client.js`) 교체
 * - `.svg` sourceExt 는 ZNTC 내장 transformer 로 직접 JS module 생성
 * - 사용자 babelTransformerPath 는 ZNTC 내장 transformer 가 처리하지 않는 custom
 *   sourceExt 에만 적용한다. Babel AST 반환은 처리하지 않는다.
 */
export function createAssetPlugin(config: PluginConfig): ZntcPlugin {
  return {
    name: 'zntc:react-native:runtime',
    setup(build) {
      // HMRClient.js path 매칭 — onLoad 응답으로 ZNTC_HMR_CLIENT_CODE 그대로.
      const hmrClientPattern = new RegExp(`${escapeRegex(HMR_CLIENT_SUFFIX)}$`);
      build.onLoad({ filter: hmrClientPattern }, () => ({
        contents: ZNTC_HMR_CLIENT_CODE,
      }));

      const hasSvgSource = config.sourceExts.some((e) => normalizeExt(e).toLowerCase() === '.svg');
      if (hasSvgSource) {
        build.onLoad({ filter: /\.svg$/i }, (args) => ({
          contents: createSvgComponentModule(readFileSync(args.path, 'utf8'), args.path),
        }));
      }

      if (config.babelTransformerPath) {
        let customTransformer: MetroTransformer | null = null;
        const transformerPath = config.babelTransformerPath;
        const dev = config.dev ?? true;

        // 사용자 transformer 적용 대상 — sourceExts 중 ts/tsx/js/jsx/mjs/cjs/json
        // 외 확장자. `.svg` 는 위의 ZNTC 내장 transformer 가 처리하므로 제외.
        const customExts = config.sourceExts
          .map((e) => normalizeExt(e).slice(1))
          .filter((e) => !/^(tsx?|jsx?|mjs|cjs|json|svg)$/.test(e))
          .join('|');

        if (customExts) {
          const customExtPattern = new RegExp(`\\.(${customExts})$`);
          build.onLoad({ filter: customExtPattern }, async (args) => {
            try {
              if (!customTransformer) {
                customTransformer = requireFromCli(
                  requireFromCli.resolve(transformerPath, { paths: [config.projectRoot] }),
                ) as MetroTransformer;
              }
              const src = readFileSync(args.path, 'utf8');
              const result = await customTransformer.transform({
                src,
                filename: args.path,
                options: {
                  platform: config.rnPlatform,
                  dev,
                  hot: dev,
                  projectRoot: config.projectRoot,
                },
              });
              if (result?.code) return { contents: result.code };
              if (result?.ast) {
                throw new Error(
                  `${transformerPath} returned a Babel AST for ${args.path}. ZNTC custom source transformers must return code; use a ZNTC native transformer for this extension.`,
                );
              }
            } catch (err: unknown) {
              process.stderr.write(
                `[zntc:transformer] ${args.path.split('/').pop()}: ${getErrorMessage(err)}\n`,
              );
              throw err;
            }
            return null;
          });
        }
      }
    },
  };
}
