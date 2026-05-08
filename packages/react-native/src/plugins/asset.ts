// React Native runtime injection plugin — Metro 의 HMRClient.js 를 ZNTC HMR
// runtime (`runtime/zntc-hmr-client.js`) 으로 교체 + 사용자 babelTransformerPath
// (예: react-native-svg-transformer) 통합. Asset registry / scale variant 처리는
// ZNTC 코어가 직접 (preset 의 assetRegistry/loader/alias 옵션) — 이 plugin 의
// 책임 아님.

import { readFileSync } from 'node:fs';
import { basename, extname } from 'node:path';

import type { ZntcPlugin } from '@zntc/core';

import { HMR_CLIENT_SUFFIX, ZNTC_HMR_CLIENT_CODE } from '../runtime-loader.ts';
import { escapeRegex } from './escape-regex.ts';
import { type BabelInstance, getErrorMessage, normalizeExt, requireFromCli } from './internal.ts';
import type { PluginConfig } from './types.ts';

interface MetroTransformerResult {
  code?: string;
  ast?: unknown;
}

interface MetroTransformer {
  transform(args: {
    src: string;
    filename: string;
    options: { platform: 'ios' | 'android'; dev: boolean };
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
 * - 사용자 babelTransformerPath (예: react-native-svg-transformer) — Metro
 *   호환 시그니처 (`transform({src, filename, options})` → `{code}` or `{ast}`)
 *   로 호출, AST 반환 시 babel.transformFromAstSync 로 generate.
 */
export function createAssetPlugin(config: PluginConfig): ZntcPlugin {
  return {
    name: 'zntc:react-native:runtime',
    setup(build) {
      // HMRClient.js path 매칭 — onLoad 응답으로 ZNTC_HMR_CLIENT_CODE 그대로.
      const hmrClientPattern = new RegExp(`${escapeRegex(HMR_CLIENT_SUFFIX)}$`);
      build.onLoad({ filter: hmrClientPattern }, () => ({
        contents: ZNTC_HMR_CLIENT_CODE.replace(
          /__ZNTC_FORWARD_CLIENT_LOGS__/g,
          config.forwardClientLogs === true ? 'true' : 'false',
        ),
      }));

      const hasSvgSource = config.sourceExts.some((e) => normalizeExt(e).toLowerCase() === '.svg');
      if (!config.babelTransformerPath && hasSvgSource) {
        build.onLoad({ filter: /\.svg$/i }, (args) => ({
          contents: createSvgComponentModule(readFileSync(args.path, 'utf8'), args.path),
        }));
      }

      if (config.babelTransformerPath) {
        let customTransformer: MetroTransformer | null = null;
        let babel: BabelInstance | null = null;
        const transformerPath = config.babelTransformerPath;

        // 사용자 transformer 적용 대상 — sourceExts 중 ts/tsx/js/jsx/mjs/cjs/json
        // 외 (RN-specific 확장자, 예: .svg). 표준 JS/TS 는 ZNTC 가 처리하므로 제외.
        const customExts = config.sourceExts
          .map((e) => normalizeExt(e).slice(1))
          .filter((e) => !/^(tsx?|jsx?|mjs|cjs|json)$/.test(e))
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
              if (!babel) {
                babel = requireFromCli('@babel/core') as BabelInstance;
              }
              const src = readFileSync(args.path, 'utf8');
              const result = await customTransformer.transform({
                src,
                filename: args.path,
                options: { platform: config.rnPlatform, dev: true },
              });
              if (result?.code) return { contents: result.code };
              if (result?.ast) {
                const generated = babel.transformFromAstSync?.(result.ast, undefined, {
                  filename: args.path,
                  babelrc: false,
                  configFile: false,
                });
                if (generated?.code) return { contents: generated.code };
              }
            } catch (err: unknown) {
              process.stderr.write(
                `[zntc:transformer] ${args.path.split('/').pop()}: ${getErrorMessage(err)}\n`,
              );
            }
            return null;
          });
        }
      }
    },
  };
}
