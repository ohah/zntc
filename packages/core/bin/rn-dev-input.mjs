// `runRnDev` 의 config + opts 추출 helper. zntc.mjs 에서 import + 사용.
// 별도 module 로 분리해 단위 테스트가 zntc.mjs 의 entry main() 트리거 없이
// helper 만 import 가능.

import { resolve } from 'node:path';

/**
 * config 의 미지원 필드는 stderr 에 한 번 경고 — silent drop 방지. zntc 의
 * RN dev server 가 아직 wire-up 안 한 영역 (graph-bundler 전용 필드 + dummy
 * placeholder) 을 사용자가 적었을 때 "왜 동작 안 함?" 디버깅 비용 절감.
 */
const UNSUPPORTED_FIELDS = [
  // graph-bundler (Metro 호환) 전용 — zntc NAPI build 는 미수용.
  ['transformer', 'inlineRequires'],
  ['transformer', 'minifier'],
  ['serializer', 'bundleType'],
  ['serializer', 'getModulesRunBeforeMainModule'],
  ['serializer', 'getRunModuleStatement'],
  ['serializer', 'shouldAddToIgnoreList'],
  // dummy placeholder — bungae 도 declared-but-unused.
  ['server', 'verifyConnections'],
  ['server', 'https'],
  ['server', 'key'],
  ['server', 'cert'],
  ['server', 'unstable_serverRoot'],
];

function warnUnsupported(config) {
  for (const [section, key] of UNSUPPORTED_FIELDS) {
    const sectionVal = config?.[section];
    if (sectionVal && Object.prototype.hasOwnProperty.call(sectionVal, key)) {
      process.stderr.write(`[zntc:rn-dev] config.${section}.${key} (zntc 미지원, ignore)\n`);
    }
  }
}

function normalizeStringArray(value, label) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) {
    throw new TypeError(`config.serializer.${label} must be a string array`);
  }
  for (const item of value) {
    if (typeof item !== 'string') {
      throw new TypeError(`config.serializer.${label} must contain only strings`);
    }
  }
  return value;
}

function getSerializerPolyfills(serializer, opts = {}) {
  const polyfills = [];

  const platform = opts.rnPlatform === 'android' ? 'android' : 'ios';
  if (typeof serializer.getPolyfills === 'function') {
    const generated = serializer.getPolyfills({ platform });
    if (generated && typeof generated.then === 'function') {
      throw new TypeError('async config.serializer.getPolyfills() is not supported');
    }
    polyfills.push(...normalizeStringArray(generated, 'getPolyfills() result'));
  }

  // Metro prepends getPolyfills() and then appends serializer.polyfillModuleNames.
  polyfills.push(...normalizeStringArray(serializer.polyfillModuleNames, 'polyfillModuleNames'));
  // ZNTC also keeps the existing serializer.polyfills compatibility field.
  polyfills.push(...normalizeStringArray(serializer.polyfills, 'polyfills'));

  return polyfills.length > 0 ? polyfills : undefined;
}

/**
 * Metro-shape config (`resolver` / `serializer` / `transformer` / `server` /
 * `watchFolders` / `sourcemapSourcesRoot`) → `RnBundleInput.extra` 평탄화. dev
 * server (rn-dev-input) 와 prod bundle (zntc.mjs runRnBundle) 양쪽이 공유.
 *
 * `opts.rnWatchFolders` / `opts.rnSourceExts` 만 CLI flag 가 config 위에 우선 —
 * 나머지 필드는 config-only.
 */
export function buildRnBundleExtra(config, opts = {}) {
  const cfg = config ?? {};
  const resolver = cfg.resolver ?? {};
  const transformer = cfg.transformer ?? {};
  const serializer = cfg.serializer ?? {};
  const server = cfg.server ?? {};
  return {
    watchFolders: opts.rnWatchFolders ?? cfg.watchFolders ?? undefined,
    nodeModulesPaths: resolver.nodeModulesPaths ?? undefined,
    sourceExts: opts.rnSourceExts ?? resolver.sourceExts ?? undefined,
    assetExts: resolver.assetExts ?? undefined,
    platforms: resolver.platforms ?? undefined,
    blockList: resolver.blockList ?? undefined,
    fallback: resolver.extraNodeModules ?? undefined,
    metroResolveRequest: resolver.resolveRequest ?? undefined,
    babelTransformerPath: transformer.babelTransformerPath ?? undefined,
    polyfills: getSerializerPolyfills(serializer, opts),
    extraVars: serializer.extraVars ?? undefined,
    prelude: serializer.prelude ?? undefined,
    babel: transformer.babel ?? undefined,
    inlineSourceMap: serializer.inlineSourceMap ?? undefined,
    sourceRoot: cfg.sourcemapSourcesRoot ?? undefined,
    silentConsoleErrorPatterns: server.silentConsoleErrorPatterns ?? undefined,
    forwardClientLogs: server.forwardClientLogs !== false,
  };
}

function assignRnBuildOptionOverrides(out, config, opts = {}) {
  const cfg = config ?? {};
  if (opts.experimentalDecorators === true || cfg.experimentalDecorators === true) {
    out.experimentalDecorators = true;
  }
  if (opts.emitDecoratorMetadata === true || cfg.emitDecoratorMetadata === true) {
    out.emitDecoratorMetadata = true;
  }
  if (opts.useDefineForClassFields === false || cfg.useDefineForClassFields === false) {
    out.useDefineForClassFields = false;
  }
  if (opts.inlineDynamicImports === true || cfg.inlineDynamicImports === true) {
    out.inlineDynamicImports = true;
  } else if (opts.inlineDynamicImports === false || cfg.inlineDynamicImports === false) {
    out.inlineDynamicImports = false;
  }
}

/**
 * Internal helper — RN dev/bundle 경로의 `bundle.override` 객체를 구성한다.
 * `@zntc/core` package.json `exports` 에 노출되지 않는 CLI bin 전용. 외부에서
 * deep import 로 호출하지 말 것.
 *
 * @param {object} input
 * @param {object} [input.config]   사용자 `zntc.config.{ts,js,json}` 의 root 객체.
 *   `alias` / `moduleSpecifierMap` 같은 dict 타입은 RN preset 으로 forwarding.
 *   `experimentalDecorators` 등은 BuildOptions override 로 forward.
 * @param {object} [input.opts]     CLI flag 가 우선 적용된 RuntimeOptions
 *   (`experimentalDecorators`/`emitDecoratorMetadata`/`useDefineForClassFields`).
 *   config 와 OR 로 합산.
 * @param {object} [input.override] 호출자(zntc.mjs) 가 build 결과 후 caller-side
 *   write 를 처리할 때 강제로 덮어 씌우고 싶은 BuildOptions (예: `outfile`,
 *   `write`). 마지막에 `Object.assign` 으로 머지.
 * @returns {object | undefined} 빈 object 면 `undefined` 반환 — caller 의 spread/
 *   merge 로직이 noop 으로 처리되도록.
 */
export function buildRnBundleOverride({ config, opts = {}, override } = {}) {
  const cfg = config ?? {};
  const out = {};
  if (
    (cfg.alias && typeof cfg.alias === 'object') ||
    (opts.alias && typeof opts.alias === 'object')
  ) {
    // RN 경로에서도 일반 zntc `--alias`/config.alias 를 동일하게 적용한다.
    // Babel module-resolver 를 제외한 프로젝트가 alias 를 native resolver 로 옮길 때 필요하다.
    out.alias = { ...(cfg.alias ?? {}), ...(opts.alias ?? {}) };
  }
  if (cfg.moduleSpecifierMap && typeof cfg.moduleSpecifierMap === 'object') {
    out.moduleSpecifierMap = cfg.moduleSpecifierMap;
  }
  assignRnBuildOptionOverrides(out, cfg, opts);
  if (override && typeof override === 'object') {
    Object.assign(out, override);
  }
  return Object.keys(out).length > 0 ? out : undefined;
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
  const projectRoot = resolve(opts.rnProjectRoot ?? cfg.projectRoot ?? cfg.root ?? '.');
  const entry = opts.entryPoints?.[0] ?? cfg.entry;
  if (!entry) return null;
  const rnPlatform = opts.rnPlatform === 'android' ? 'android' : 'ios';
  const server = cfg.server ?? {};
  const resolver = cfg.resolver ?? {};
  const symbolicator = cfg.symbolicator ?? {};

  warnUnsupported(cfg);

  // server.useGlobalHotkey + CLI `--no-interactive` 둘 다 r/d/? 키보드
  // shortcut 의 enable gate. CLI flag 우선 — 명시 시 config override.
  const terminalActions =
    opts.noInteractive === true || server.useGlobalHotkey === false ? false : undefined;
  const dev = opts.devMode !== undefined ? Boolean(opts.devMode) : cfg.dev !== false;

  return {
    bundle: {
      entry,
      projectRoot,
      rnPlatform,
      // dev server 는 default __DEV__=true / sourcemap=true (bundle 의 default false 와 의도적 비대칭).
      dev,
      // dev server 는 항상 sourcemap=true — RN LogBox / DevTools 의 source link
      // 동작에 필수. zntc.mjs 의 `opts.sourcemap` default 가 false 라 `!== false`
      // 비교는 무용 (사용자 명시 disable 구분 불가). dev server 컨텍스트에선
      // sourcemap 필수 default.
      sourcemap: true,
      minify:
        opts.minify ||
        opts.minifyWhitespace ||
        opts.minifyIdentifiers ||
        opts.minifySyntax ||
        cfg.minify ||
        false,
      extra: buildRnBundleExtra(cfg, opts),
      override: buildRnBundleOverride({ config: cfg, opts }),
    },
    port: opts.port ?? server.port ?? 8081,
    host: opts.host ?? server.host ?? 'localhost',
    nodeModulesPaths: resolver.nodeModulesPaths ?? [],
    enhanceMiddleware: server.enhanceMiddleware,
    rewriteRequestUrl: server.rewriteRequestUrl,
    symbolicator: symbolicator.customizeFrame
      ? { customizeFrame: symbolicator.customizeFrame }
      : undefined,
    ...(server.hmr === false ? { hmr: false } : {}),
    ...(terminalActions === false ? { terminalActions: false } : {}),
  };
}
