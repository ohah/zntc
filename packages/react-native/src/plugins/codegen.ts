// RN codegen view config 인라인 — `@react-native/babel-plugin-codegen` 래핑.
// ZTS 가 `@react-native/babel-preset` 을 native 처리하지만 그 내부의 codegen
// plugin 은 미구현 (#1589). RN 0.85+ Fabric 의 자동 컴포넌트 등록이 늘어나면서
// `codegenNativeComponent<Props>('Name')` 호출의 view config 가 빠지면 런타임
// crash (예: View config not found for component DebuggingOverlay). 이 plugin
// 이 marker 가진 파일만 Babel 로 한번 더 돌려 view config 를 inline.

import type { ZtsPlugin } from '@zts/core';

import {
  type BabelInstance,
  type BabelTransformOptions,
  getErrorMessage,
  requireFromCli,
} from './internal.ts';
import type { PluginConfig } from './types.ts';

/** `codegenNativeComponent` literal — code 에 이 marker 미포함 시 transform skip. */
export const CODEGEN_NATIVE_COMPONENT_MARKER = 'codegenNativeComponent';

/** `.js` / `.ts` 파일만 처리. RN NativeComponent 파일은 항상 .js/.ts (jsx/tsx 미지원). */
const CODEGEN_FILENAME_PATTERN = /\.(js|ts)$/;

/**
 * Lazy codegen transformer factory. 첫 transform 호출 시점에
 * `@react-native/babel-plugin-codegen` resolve (projectRoot 우선, 미발견 시
 * cli node_modules fallback). RN 0.85+ Fabric crash 회피 patch.
 */
export function createCodegenTransformer(
  projectRoot: string,
): (code: string, filename: string) => string | null {
  let babel: BabelInstance | null = null;
  let codegenPlugin: unknown = null;
  let babelOptions: BabelTransformOptions | null = null;

  function ensureBabel(): void {
    if (babel) return;
    babel = requireFromCli('@babel/core') as BabelInstance;

    try {
      const codegenPath = (() => {
        try {
          return requireFromCli.resolve('@react-native/babel-plugin-codegen', {
            paths: [projectRoot],
          });
        } catch {
          return requireFromCli.resolve('@react-native/babel-plugin-codegen');
        }
      })();
      codegenPlugin = requireFromCli(codegenPath);
    } catch (err: unknown) {
      process.stderr.write(
        `[zts:codegen] @react-native/babel-plugin-codegen not found (${getErrorMessage(err, 80)}) — view config inlining disabled\n`,
      );
      throw err;
    }

    babelOptions = {
      babelrc: false,
      configFile: false,
      compact: false,
      sourceMaps: false,
      plugins: [codegenPlugin],
    };
  }

  return (code: string, filename: string): string | null => {
    if (!CODEGEN_FILENAME_PATTERN.test(filename)) return null;
    if (!code.includes(CODEGEN_NATIVE_COMPONENT_MARKER)) return null;

    // RN NativeComponent 파일은 확장자로 언어 구분: .js → Flow 제네릭, .ts →
    // TypeScript. babel-plugin-codegen 내부 parseFile() 도 같은 분기.
    const parserPlugins = filename.endsWith('.ts') ? ['typescript'] : ['flow'];

    try {
      ensureBabel();
      const result = babel!.transformSync(code, {
        ...(babelOptions ?? {}),
        filename,
        parserOpts: { plugins: parserPlugins },
      });
      if (result?.code && result.code !== code) {
        process.stderr.write(`[zts:codegen] ${filename.split('/').pop()}: view config inlined\n`);
        return result.code;
      }
      return null;
    } catch (err: unknown) {
      process.stderr.write(
        `[zts:codegen] ${filename.split('/').pop()} failed: ${getErrorMessage(err, 120)}\n`,
      );
      return null;
    }
  };
}

/**
 * Codegen plugin — `codegenNativeComponent` marker 가진 .js/.ts 파일을 Babel
 * 로 transform 해서 view config 인라인. node_modules 포함 모든 파일 적용 (RN
 * core 의 NativeComponent.js 까지 — DebuggingOverlay 등).
 */
export function createCodegenPlugin(config: PluginConfig): ZtsPlugin {
  return {
    name: 'zts:react-native:codegen-view-config',
    setup(build) {
      const transformer = createCodegenTransformer(config.projectRoot);
      build.onTransform({ filter: /\.(js|ts)$/ }, (args) => {
        try {
          const result = transformer(args.code, args.path);
          return result ? { code: result } : null;
        } catch {
          return null;
        }
      });
    },
  };
}
