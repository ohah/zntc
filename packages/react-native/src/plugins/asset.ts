// React Native runtime injection plugin — Metro 의 HMRClient.js 를 ZNTC HMR
// runtime (`runtime/zntc-hmr-client.js`) 으로 교체 + RN source asset transformer
// 통합. Asset registry / scale variant 처리는 ZNTC 코어가 직접 (preset 의
// assetRegistry/loader/alias 옵션) 처리한다.

import { existsSync, readFileSync } from 'node:fs';
import { basename, dirname, extname, isAbsolute, join, resolve } from 'node:path';

import type { ZntcPlugin } from '@zntc/core';

import { HMR_CLIENT_SUFFIX, ZNTC_HMR_CLIENT_CODE } from '../runtime-loader.ts';
import { escapeRegex } from './escape-regex.ts';
import { getErrorMessage, normalizeExt, requireFromCli } from './internal.ts';
import type { PluginConfig } from './types.ts';

const METRO_ASSET_RESOLUTIONS = ['1', '1.5', '2', '3', '4'];

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

function isRelativeSpecifier(path: string): boolean {
  return path.startsWith('./') || path.startsWith('../');
}

function isScaledAssetName(name: string): boolean {
  return /@\d+(?:\.\d+)?x$/.test(name);
}

function createAssetResolvePattern(assetExts: readonly string[]): RegExp | null {
  const extensions = assetExts.map((e) => escapeRegex(normalizeExt(e).slice(1))).filter(Boolean);
  if (extensions.length === 0) return null;
  return new RegExp(`\\.(${extensions.join('|')})$`, 'i');
}

function resolveMetroAssetFile(specifier: string, importer: string | undefined): string | null {
  if (!importer) return null;
  if (!isRelativeSpecifier(specifier) && !isAbsolute(specifier)) return null;

  const ext = extname(specifier);
  const baseName = basename(specifier, ext);
  if (!ext || isScaledAssetName(baseName)) return null;

  const specifierDir = dirname(specifier);
  const originDir = isAbsolute(specifier)
    ? dirname(specifier)
    : resolve(dirname(importer), specifierDir);
  const logicalBase = isAbsolute(specifier)
    ? join(originDir, baseName)
    : resolve(dirname(importer), specifierDir, baseName);

  // Metro DependencyGraph.resolveAsset 와 같은 후보군. base 파일이 없어도 @3x 같은
  // scale variant 만 있으면 assetFiles 로 취급하고, ModuleResolution 은 그중
  // lexicographically lowest path 하나를 graph module 로 사용한다.
  const candidates = [
    `${logicalBase}${ext}`,
    ...METRO_ASSET_RESOLUTIONS.map((resolution) => `${logicalBase}@${resolution}x${ext}`),
  ].filter((path) => existsSync(path));

  if (candidates.length === 0) return null;
  candidates.sort();
  return candidates[0]!;
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
      const assetResolvePattern = createAssetResolvePattern(config.assetExts);
      if (assetResolvePattern) {
        build.onResolve({ filter: assetResolvePattern }, (args) => {
          const resolved = resolveMetroAssetFile(args.path, args.importer);
          return resolved ? { path: resolved } : null;
        });
      }

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
