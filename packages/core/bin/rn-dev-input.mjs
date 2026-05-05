// `runRnDev` 의 config + opts 추출 helper. zts.mjs 에서 import + 사용.
// 별도 module 로 분리해 단위 테스트가 zts.mjs 의 entry main() 트리거 없이
// helper 만 import 가능.

import { resolve } from "node:path";

/**
 * 번개 BungaeConfig 의 `root` / `entry` / `dev` / `minify` / `server.*` /
 * `resolver.*` / `transformer.*` / `symbolicator.*` / `watchFolders` 영역 인식.
 *
 * CLI flag 우선 → config 영역 → default 순서 fallback. entry 가 없으면 null —
 * caller 가 friendly error 처리.
 */
export function buildRnDevServerInput(opts, config) {
  const cfg = config ?? {};
  const projectRoot = resolve(opts.rnProjectRoot ?? cfg.root ?? ".");
  const entry = opts.entryPoints?.[0] ?? cfg.entry;
  if (!entry) return null;
  const rnPlatform = opts.rnPlatform === "android" ? "android" : "ios";
  const server = cfg.server ?? {};
  const resolver = cfg.resolver ?? {};
  const transformer = cfg.transformer ?? {};
  const symbolicator = cfg.symbolicator ?? {};
  return {
    bundle: {
      entry,
      projectRoot,
      rnPlatform,
      // dev server 는 default __DEV__=true / sourcemap=true (bundle 의 default false 와 의도적 비대칭).
      dev: opts.devMode !== false && cfg.dev !== false,
      sourcemap: opts.sourcemap !== false,
      minify:
        opts.minify ||
        opts.minifyWhitespace ||
        opts.minifyIdentifiers ||
        opts.minifySyntax ||
        cfg.minify ||
        false,
      extra: {
        watchFolders: cfg.watchFolders ?? undefined,
        blockList: resolver.blockList ?? undefined,
        fallback: resolver.extraNodeModules ?? undefined,
        metroResolveRequest: resolver.resolveRequest ?? undefined,
        babelTransformerPath: transformer.babelTransformerPath ?? undefined,
        sourceExts: resolver.sourceExts ?? undefined,
        assetExts: resolver.assetExts ?? undefined,
      },
    },
    port: opts.port ?? server.port ?? 8081,
    host: opts.host ?? server.host ?? "localhost",
    nodeModulesPaths: resolver.nodeModulesPaths ?? [],
    enhanceMiddleware: server.enhanceMiddleware,
    rewriteRequestUrl: server.rewriteRequestUrl,
    symbolicator: symbolicator.customizeFrame
      ? { customizeFrame: symbolicator.customizeFrame }
      : undefined,
  };
}
