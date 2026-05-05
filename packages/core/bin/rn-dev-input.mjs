// `runRnDev` 의 config + opts 추출 helper. zts.mjs 에서 import + 사용.
// 별도 module 로 분리해 단위 테스트가 zts.mjs 의 entry main() 트리거 없이
// helper 만 import 가능.

import { resolve } from "node:path";

/**
 * config 의 미지원 필드는 stderr 에 한 번 경고 — silent drop 방지. zts 의
 * RN dev server 가 아직 wire-up 안 한 영역 (graph-bundler 전용 필드 + dummy
 * placeholder) 을 사용자가 적었을 때 "왜 동작 안 함?" 디버깅 비용 절감.
 */
const UNSUPPORTED_FIELDS = [
  // graph-bundler (Metro 호환) 전용 — zts NAPI build 는 미수용.
  ["transformer", "inlineRequires"],
  ["transformer", "minifier"],
  ["transformer", "babel"],
  ["serializer", "prelude"],
  ["serializer", "bundleType"],
  ["serializer", "getModulesRunBeforeMainModule"],
  ["serializer", "getPolyfills"],
  ["serializer", "shouldAddToIgnoreList"],
  ["serializer", "inlineSourceMap"],
  // dummy placeholder — bungae 도 declared-but-unused.
  ["server", "forwardClientLogs"],
  ["server", "verifyConnections"],
  ["server", "https"],
  ["server", "key"],
  ["server", "cert"],
  ["server", "unstable_serverRoot"],
];

function warnUnsupported(config) {
  for (const [section, key] of UNSUPPORTED_FIELDS) {
    const sectionVal = config?.[section];
    if (sectionVal && Object.prototype.hasOwnProperty.call(sectionVal, key)) {
      process.stderr.write(`[zts:rn-dev] config.${section}.${key} (zts 미지원, ignore)\n`);
    }
  }
}

/**
 * 번개 BungaeConfig 의 `root` / `entry` / `dev` / `minify` / `server.*` /
 * `resolver.*` / `transformer.*` / `serializer.*` / `symbolicator.*` /
 * `watchFolders` 영역 인식.
 *
 * CLI flag 우선 → config 영역 → default 순서 fallback. entry 가 없으면 null —
 * caller 가 friendly error 처리.
 *
 * 미지원 필드 (graph-bundler 전용 + placeholder) 는 stderr 에 한 번 경고 —
 * `transformer.inlineRequires` / `transformer.minifier` / `serializer.prelude` /
 * `serializer.bundleType` / `server.forwardClientLogs` / `server.verifyConnections` 등.
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
  const serializer = cfg.serializer ?? {};
  const symbolicator = cfg.symbolicator ?? {};

  warnUnsupported(cfg);

  // server.useGlobalHotkey 가 의미상 terminalActions — 둘 다 r/d/? 키보드
  // shortcut 의 enable gate. CLI 미노출이라 config 만 source.
  const terminalActions = server.useGlobalHotkey === false ? false : undefined;

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
        polyfills: serializer.polyfills ?? undefined,
        extraVars: serializer.extraVars ?? undefined,
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
    ...(terminalActions === false ? { terminalActions: false } : {}),
  };
}
