/**
 * withExpo — Apply Expo-specific options to a ZNTC RN config.
 *
 * Mirrors the runtime opt-in pattern of `@expo/metro-config`:
 *   import { withExpo } from '@zntc/react-native';
 *   export default withExpo({ root: __dirname, entry: 'index.js', ... });
 *
 * Adds:
 *   - serializer.prelude:                 `expo/winter` + `@expo/metro-runtime`
 *   - resolver.assetExts:                 `.heic`, `.avif`, `.db` (expo-image, expo-sqlite)
 *   - resolver.blockList:                 `.expo/types/**` (generated d.ts)
 *   - server.silentConsoleErrorPatterns:  winter polyfill warning
 *
 * Resolves all paths from `config.root`, so monorepo hoisting in unrelated
 * workspace packages cannot leak Expo into a vanilla RN config.
 *
 * 번개 packages/bungae/src/bundler/zntc-bundler/withExpo.ts 의 ZNTC 포팅.
 * BungaeConfig 대신 ZNTC 의 Metro-shape config (rn-dev-input.mjs 가 인식하는
 * `resolver.assetExts` / `resolver.blockList` / `serializer.prelude` /
 * `server.silentConsoleErrorPatterns` 영역) 를 변형.
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { tryResolve } from './rn-constants.ts';

/**
 * Detect whether a project's own `package.json` declares Expo as a direct
 * dependency. Used by zero-config mode to decide whether to auto-apply
 * `withExpo()`. Hoisted-monorepo dependencies in workspace root do NOT
 * trigger detection — only the project's own deps do.
 */
export function detectExpo(
  projectRoot: string,
): { name: 'expo' | 'expo-router'; version: string } | undefined {
  try {
    const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8')) as {
      dependencies?: Record<string, string>;
      devDependencies?: Record<string, string>;
    };
    const deps = { ...pkg.dependencies, ...pkg.devDependencies };
    if (deps.expo) return { name: 'expo', version: deps.expo };
    if (deps['expo-router']) return { name: 'expo-router', version: deps['expo-router'] };
  } catch {
    // Missing or malformed package.json — treat as non-Expo project.
  }
  return undefined;
}

const EXPO_ASSET_EXTS = ['.heic', '.avif', '.db'] as const;

/** Normalize "ext" / ".ext" → ".ext" for dedup comparisons. */
function normalizeExt(ext: string): string {
  return ext.startsWith('.') ? ext : `.${ext}`;
}

const EXPO_BLOCK_LIST: RegExp[] = [/\.expo[\\/]types/];

/**
 * expo `installGlobal.ts:96` 의 winter polyfill (TextEncoderStream/TextDecoderStream/
 * Location) 이 Hermes 의 `configurable: false` spec global 위에 redefine 시도 →
 * catch 후 무해 console.error. dev console 을 오염시키므로 silent swallow.
 */
export const WINTER_POLYFILL_WARNING_PATTERN =
  '^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$';

function resolveExpoModules(root: string): {
  winter: string | undefined;
  metroRuntime: string | undefined;
} {
  const winter =
    tryResolve('expo/src/winter/index.ts', root) ??
    tryResolve('expo/src/winter/index', root) ??
    tryResolve('expo/build/winter/index.js', root) ??
    undefined;

  // expo-router 가 끌어오는 동일 인스턴스 보장 — top-level 패키지가 hoisted 된
  // 경우 instance 가 갈라져 require chain 이 깨질 수 있어 expo-router 의 dirname
  // 기준으로 resolve.
  const expoRouterPkg = tryResolve('expo-router/package.json', root);
  const metroRuntimeBase = expoRouterPkg ? dirname(expoRouterPkg) : root;
  const metroRuntime = tryResolve('@expo/metro-runtime', metroRuntimeBase) ?? undefined;

  return { winter, metroRuntime };
}

/**
 * ZNTC 의 Metro-shape config 가 가질 수 있는 영역 — withExpo 가 만지는 부분만
 * 명시. caller 가 `defineConfig` 없이 plain object 로 export 하므로 `T extends`
 * 형태로 generic 보존 — 추가 필드는 그대로 통과.
 */
export interface ZntcRnExpoConfig {
  root?: string;
  resolver?: {
    assetExts?: string[];
    blockList?: (RegExp | string)[];
    [key: string]: unknown;
  };
  serializer?: {
    prelude?: string[];
    [key: string]: unknown;
  };
  server?: {
    silentConsoleErrorPatterns?: string[];
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export function withExpo<T extends ZntcRnExpoConfig>(config: T): T {
  const root = config.root ?? process.cwd();
  const { winter, metroRuntime } = resolveExpoModules(root);

  const expoModules: string[] = [];
  if (winter) expoModules.push(winter);
  if (metroRuntime) expoModules.push(metroRuntime);

  const existingAssetExts = config.resolver?.assetExts ?? [];
  const existingNormalized = new Set(existingAssetExts.map(normalizeExt));

  return {
    ...config,
    resolver: {
      ...config.resolver,
      assetExts: [
        ...existingAssetExts,
        ...EXPO_ASSET_EXTS.filter((ext) => !existingNormalized.has(ext)),
      ],
      blockList: [...(config.resolver?.blockList ?? []), ...EXPO_BLOCK_LIST],
    },
    serializer: {
      ...config.serializer,
      prelude: [...(config.serializer?.prelude ?? []), ...expoModules],
    },
    server: {
      ...config.server,
      silentConsoleErrorPatterns: [
        ...(config.server?.silentConsoleErrorPatterns ?? []),
        WINTER_POLYFILL_WARNING_PATTERN,
      ],
    },
  };
}
