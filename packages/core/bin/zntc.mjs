#!/usr/bin/env node

/**
 * ZNTC CLI — Node.js/Bun 호환 CLI
 *
 * 내부적으로 @zntc/core NAPI 바인딩을 사용하여 트랜스파일/번들링을 수행.
 * Watch/Serve는 JS 레이어에서 구현.
 */

import { mkdirSync, existsSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { resolve, dirname, basename, extname, join, sep } from 'node:path';
import { createServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

import { applyFlagAction, KNOWN_FLAGS, matchFlagFromRegistry } from './cli-flags.mjs';
import { copyRnAssets } from './rn-asset-copy.mjs';
import {
  buildRnBundleExtra,
  buildRnBundleOverride,
  buildRnDevServerInput,
} from './rn-dev-input.mjs';
import { printZntcBanner } from './banner.mjs';

function isMissingBuiltCore(error) {
  if (!error || error.code !== 'ERR_MODULE_NOT_FOUND') return false;
  const builtCorePath = fileURLToPath(new URL('../dist/index.js', import.meta.url));
  return String(error.message ?? '').includes(builtCorePath);
}

async function loadCoreModule() {
  try {
    return await import('../dist/index.js');
  } catch (error) {
    if (!isMissingBuiltCore(error)) throw error;
    console.error('error: @zntc/core JS bundle is missing');
    console.error('');
    console.error('note: zntc CLI runs the built JS entry at packages/core/dist/index.js.');
    console.error('note: source TypeScript is not loaded directly by Node.');
    console.error('');
    console.error('help: run `bun run --cwd packages/core build:js` from the repository root.');
    console.error(
      'help: for a full local build (NAPI binary 포함), run `bun run --cwd packages/core build:local`.',
    );
    process.exit(1);
  }
}

const coreModule = await loadCoreModule();
const {
  init,
  transpile,
  build,
  buildAppSync,
  buildSync,
  envToDefine,
  filterWorkspaces,
  findConfigPath,
  findModeConfigPath,
  findWorkspacePath,
  identifyWorkspaceEntries,
  importAndResolveDefault,
  KNOWN_CONFIG_KEYS,
  loadConfig,
  loadEnv,
  loadIdentifiedConfig,
  loadWorkspace,
  mergeUserConfigs,
  suggestKey,
  tokenize,
  configureProfile,
  profileReport,
  validateTsConfigRaw,
  warnUnknownKeys,
} = coreModule;

export { KNOWN_FLAGS };
const requireFromCli = createRequire(import.meta.url);
const cliNodeModules = resolve(dirname(fileURLToPath(import.meta.url)), '../../..', 'node_modules');

// `@zntc/core` 패키지 version — dev server banner 의 v0.x.y 자리에 표시.
// dev / serve / RN dev 분기에서만 사용되므로 lazy 로 읽어 `zntc transpile` 같은
// one-shot CLI 의 cold start 비용 회피.
let cliVersionCache;
function getCliVersion() {
  if (cliVersionCache !== undefined) return cliVersionCache;
  try {
    cliVersionCache = requireFromCli('../package.json').version;
  } catch {
    cliVersionCache = null;
  }
  return cliVersionCache;
}

// ─── CLI 인자 파싱 ───

function usageLines(command) {
  if (command === 'dev') {
    return [
      'Usage: zntc dev [root] [options]',
      '',
      'Options:',
      '  --host [host]              Host to listen on (default: localhost)',
      '  --port <port>              Port to listen on (default: 12300)',
      '  --open                     Open the app URL in the browser',
      '  --mode <mode>              Load mode-specific config and .env files',
      '  --base <path>              Base public path',
      '  --entry-html <path>        HTML entry file',
      '  --public-dir <path|false>  Public directory to serve',
      '  --help, -h                 Show this help message',
    ];
  }
  if (command === 'build') {
    return [
      'Usage: zntc build [root] [options]',
      '',
      'Options:',
      '  --outdir <dir>             Output directory',
      '  --mode <mode>              Load mode-specific config and .env files',
      '  --base <path>              Base public path',
      '  --entry-html <path>        HTML entry file',
      '  --public-dir <path|false>  Public directory to copy',
      '  --minify                   Minify output',
      '  --sourcemap[=mode]         Emit source maps',
      '  --help, -h                 Show this help message',
    ];
  }
  if (command === 'preview') {
    return [
      'Usage: zntc preview [outdir] [options]',
      '',
      'Options:',
      '  --host [host]              Host to listen on (default: localhost)',
      '  --port <port>              Port to listen on (default: 12300)',
      '  --strict-port              Exit if the specified port is already in use',
      '  --open                     Open the preview URL in the browser',
      '  --base <path>              Base public path',
      '  --spa-fallback[=path]      Serve an HTML fallback for app routes',
      '  --certfile <path>          HTTPS certificate file',
      '  --keyfile <path>           HTTPS key file',
      '  --help, -h                 Show this help message',
    ];
  }
  return [
    'Usage: zntc [options] <file.ts>',
    '       zntc --bundle <entry.ts> -o out.js',
    '       zntc --serve --bundle <entry.ts>',
    '       zntc dev [root]',
    '       zntc build [root]',
    '       zntc preview [outdir]',
    '',
    'Options:',
    '  --bundle                   Bundle dependencies',
    '  --packages=external        Treat all bare package imports as external',
    '  --pure:CALLEE              Mark matching call/new expressions as removable when unused',
    '  --line-limit=<n>           Wrap generated output lines after safe token boundaries',
    '  --conditions=<csv>         Add custom package exports conditions',
    '  --node-paths=<csv>         Add bare specifier lookup directories',
    '  --global:SPEC=NAME         Map external specifier to IIFE/UMD global',
    '  --intro=<text>             Insert wrapper-internal text before bundle code',
    '  --outro=<text>             Insert wrapper-internal text after bundle code',
    '  --ignore-annotations       Ignore pure/sideEffects annotations',
    '  --jsx-side-effects         Preserve unused JSX expressions',
    '  --profile=<csv>            Collect profile categories (all, parse, transform, ...)',
    '  --profile-level=<level>    Profile level: summary, detailed, per-module, per-pass',
    '  --profile-format=<format>  Profile output: table, tree, json, csv',
    '  --runtime-polyfills=<mode> Inject core-js runtime polyfills: auto, usage, entry, off',
    "  --runtime-target=<query>   Runtime polyfill Browserslist target (repeatable: 'chrome >= 87', 'safari >= 14')",
    '  --core-js=<version>        core-js version used for runtime polyfill compatibility',
    '  --stop-after=<phase>       Stop transpile after a given phase (debug)',
    '  --tokenize[=false]         Print scanner tokens instead of generated code',
    '  --tokenize-format=<format> Token output: text or json',
    '  --outdir <dir>             Output directory',
    '  --outfile <file>, -o <file> Output file',
    '  --allow-overwrite          Permit output paths to overwrite input files',
    '  --watch, -w                Rebuild on changes',
    '  --serve [dir]              Serve bundled output',
    '  --config <path>            Config file path',
    '  --test262 <dir>            Run Zig Test262 runner via zig build test262-run',
    '  --help, -h                 Show this help message',
  ];
}

function printUsage(command, stream = console.log) {
  stream(usageLines(command).join('\n'));
}

function parseArgs(argv) {
  const args = argv.slice(2);
  const appCommands = new Set(['dev', 'build', 'preview']);
  const appCommand = appCommands.has(args[0]) ? args.shift() : undefined;
  const opts = {
    appCommand,
    help: false,
    parseError: false,
    appRoot: undefined,
    previewDir: undefined,
    entryPoints: [],
    // SCALAR_KEYS (mergeConfigIntoOpts) 의 다른 키들과 동일하게 `undefined` 기본값 사용.
    // 과거 `null` 이었으나 머지 조건이 `=== undefined` 라 `zntc.config.json` 의 outdir/outfile
    // 만 silent drop 되는 회귀가 있었음. 모든 사용처가 truthy 검사 (`if (opts.outdir)`) 라
    // null → undefined 변경은 동작 영향 없음.
    outfile: undefined,
    outdir: undefined,
    bundle: false,
    watch: false,
    watchJson: false,
    watchDelay: 100,
    serve: false,
    serveDir: '.',
    port: undefined,
    host: undefined,
    strictPort: false,
    open: false,
    proxy: {},
    format: undefined,
    platform: undefined,
    minify: false,
    minifyWhitespace: false,
    minifyIdentifiers: false,
    minifySyntax: false,
    sourcemap: false,
    // undefined: NAPI 측이 missing 시 "linked" fallback. CLI/config 명시 시 override.
    sourcemapMode: undefined,
    // undefined: NAPI 측이 missing 시 "auto" fallback (#2159).
    outputExports: undefined,
    sourcemapDebugIds: false,
    sourcesContent: true,
    splitting: false,
    metafile: undefined,
    analyze: false,
    treeShaking: true,
    external: [],
    packagesExternal: false,
    define: {},
    alias: {},
    banner: undefined,
    footer: undefined,
    globalName: undefined,
    publicPath: undefined,
    entryNames: undefined,
    chunkNames: undefined,
    assetNames: undefined,
    jsx: undefined,
    jsxDev: false,
    jsxFactory: undefined,
    jsxFragment: undefined,
    jsxImportSource: undefined,
    devMode: undefined,
    flow: false,
    experimentalDecorators: false,
    useDefineForClassFields: true,
    keepNames: false,
    shimMissingExports: false,
    preserveSymlinks: false,
    charsetUtf8: false,
    asciiOnly: false,
    quotes: undefined,
    inject: [],
    pure: [],
    plugins: [],
    pluginPaths: [],
    stdin: false,
    project: undefined,
    tsconfigRaw: undefined,
    logLevel: 'info',
    jobs: undefined,
    logLimit: undefined,
    lineLimit: undefined,
    clean: false,
    allowOverwrite: false,
    preserveModules: false,
    preserveModulesRoot: undefined,
    inlineDynamicImports: false,
    loader: {},
    legalComments: undefined,
    resolveExtensions: [],
    mainFields: [],
    rnPlatform: undefined,
    jsxInJs: false,
    outExtensionJs: undefined,
    sourceRoot: undefined,
    target: undefined,
    emitDecoratorMetadata: false,
    verbatimModuleSyntax: undefined,
    browserslist: undefined,
    outbase: undefined,
    drop: [],
    dropLabels: [],
    certfile: undefined,
    keyfile: undefined,
    configPath: undefined, // --config <path> 명시 시 자동 탐색 우회
    mode: undefined, // --mode <name> 함수형 config / mode 별 config 머지 (#2110) 에서 사용
    envPrefixes: undefined, // --env-prefix=VITE_,ZNTC_ — undefined 면 loadEnv default 사용
    envDir: undefined, // --env-dir <path> — undefined 면 cwd
    workspaceConfig: undefined, // --workspace-config <path> — 명시 시 자동 탐색 우회 (#2111)
    workspace: undefined, // --workspace <name> — 단일 entry 만 빌드 (#2111)
    entryHtml: undefined,
    publicDir: undefined,
    base: undefined,
    spaFallback: undefined,
    intro: undefined,
    outro: undefined,
    globals: {},
    conditions: [],
    nodePaths: [],
    profile: [],
    profileLevel: undefined,
    profileFormat: undefined,
    runtimePolyfills: undefined,
    coreJs: undefined,
    runtimeTargetQueries: [],
    ignoreAnnotations: false,
    jsxSideEffects: false,
    stopAfter: undefined,
    tokenize: false,
    tokenizeFormat: 'text',
    test262: undefined,
  };

  if (appCommand === 'dev') {
    opts.serve = true;
    opts.bundle = true;
    opts.watch = true;
  } else if (appCommand === 'build') {
    opts.bundle = true;
  } else if (appCommand === 'preview') {
    opts.serve = true;
  }

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    // stdin
    if (arg === '-') {
      opts.stdin = true;
      continue;
    }

    // positional (파일 경로)
    if (!arg.startsWith('-')) {
      if (opts.appCommand === 'dev' || opts.appCommand === 'build') {
        opts.appRoot = opts.appRoot ?? arg;
      } else if (opts.appCommand === 'preview') {
        opts.previewDir = opts.previewDir ?? arg;
      } else {
        opts.entryPoints.push(arg);
      }
      continue;
    }

    // registry-driven 매칭. 새 flag 는 FLAG_REGISTRY 에 entry 한 줄만 추가.
    const matched = matchFlagFromRegistry(arg, args, i);
    if (matched) {
      applyFlagAction(opts, matched.spec, matched.action);
      i += matched.consumed - 1;
      continue;
    }

    // ─── 특수 형식 (registry 표현이 어색해 if-chain 잔존) ───

    // `--serve [DIR]` — 다음 토큰이 flag 아니면 serveDir 로 사용 (next-arg optional, default 유지)
    if (arg === '--serve') {
      opts.serve = true;
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
        opts.serveDir = args[++i];
      }
      continue;
    }

    // `--host [VALUE]` — pair-form 이지만 누락 시 default "0.0.0.0".
    // registry 의 string kind 와 의미 다름 (누락 시 undefined 가 아닌 명시 default).
    if (arg === '--host') {
      opts.host = args[++i] || '0.0.0.0';
      continue;
    }

    // dev-server proxy — `--proxy /api=http://localhost:8080` 형식 (특수 parser)
    if (arg.startsWith('--proxy')) {
      const [path, target] =
        arg.split('=').length > 1
          ? [arg.split(' ')[0].replace('--proxy', '').replace('=', ''), args[i].split('=')[1]]
          : [args[++i]?.split('=')[0], args[i]?.split('=')[1]];
      if (path && target) opts.proxy[path] = target;
      continue;
    }

    // unknown — typo 시 가장 가까운 known flag 제안 (Levenshtein, threshold 2).
    if (opts.logLevel !== 'silent') {
      const suggestion = suggestKey(arg, KNOWN_FLAGS);
      console.error(
        suggestion
          ? `warning: unknown option '${arg}' — did you mean '${suggestion}'?`
          : `warning: unknown option '${arg}'`,
      );
    }
    opts.parseError = true;
  }

  // jsx-dev 단축어
  if (opts.jsxDev) opts.jsx = 'automatic-dev';

  // esbuild legacy alias normalize: `--jsx=transform` / `--jsx=preserve` → classic.
  // docs/CONFIG.md 가 명시한 CLI vocab (preserve/transform/automatic) 을 strict NAPI vocab
  // (classic/automatic/automatic-dev) 로 변환. JS API 는 이 정규화를 받지 않고 strict union
  // type 만 허용 — CLI argv 의 raw string 만 esbuild 호환을 위해 관대하게 처리.
  if (opts.jsx === 'transform' || opts.jsx === 'preserve') opts.jsx = 'classic';

  // drop 처리
  for (const d of opts.drop) {
    if (d === 'console') opts.define['console.log'] = 'undefined';
    if (d === 'debugger') opts.define['debugger'] = '';
  }

  return opts;
}

function formatTokenizeOutput(tokens, format) {
  if (format === 'json') {
    return `${JSON.stringify(tokens, null, 2)}\n`;
  }
  return tokens
    .map((token) => {
      const loc = `${token.line + 1}:${token.column + 1}`;
      const span = `${token.start}-${token.end}`;
      const text = token.text.length > 0 ? ` ${JSON.stringify(token.text)}` : '';
      return `${loc} ${span} ${token.kind}${text}`;
    })
    .join('\n')
    .concat('\n');
}

// ─── 파일 출력 ───

// realpathSync 가 throw 하면 (출력 파일은 보통 미존재) lexical resolve 로 fallback.
// Zig 측 (src/main.zig) 도 같은 전략을 쓴다 — 입력은 심볼릭 링크 해석, 출력은 일반적으로 미존재.
function safeRealpath(p) {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
}

function assertCanWriteOutput(outPath, resolvedEntries) {
  if (!resolvedEntries) return;
  if (resolvedEntries.has(safeRealpath(outPath))) {
    throw new Error(
      `zntc: output file '${outPath}' would overwrite input file (use --allow-overwrite to permit)`,
    );
  }
}

function writeOutputFiles(outputFiles, outfile, outdir, entryPoints, allowOverwrite) {
  const resolvedEntries = allowOverwrite ? null : new Set(entryPoints.map(safeRealpath));
  if (outfile) {
    const outPath = resolve(outfile);
    const outDirAbs = dirname(outPath);
    assertCanWriteOutput(outPath, resolvedEntries);
    mkdirSync(outDirAbs, { recursive: true });
    // 첫 entry 는 main bundle/transpile output → outfile. 나머지는 path 로 분기 —
    // `.map` 으로 끝나면 sourcemap (`outfile.map`), 아니면 asset (CSS bundle / worker
    // chunk 등) 으로 outfile 의 dirname 안에 basename. 옛 코드가 `[1]` slot 을 무조건
    // sourcemap 으로 가정해 asset 이 함께 emit 될 때 asset 이 `.map` 자리에 잘못
    // write 되던 회귀 해소.
    // file.contents 는 Uint8Array — Node fs 가 그대로 syscall 로 전달 (utf-8 encode
    // 비용 없음). transpile path 가 만든 임시 outputFiles 도 `{ path, contents }` 형식
    // (자세히: line 912 참고).
    writeFileSync(outPath, outputFiles[0].contents);
    for (let i = 1; i < outputFiles.length; i++) {
      const file = outputFiles[i];
      if (file.path.endsWith('.map')) {
        writeFileSync(outPath + '.map', file.contents);
      } else {
        const assetPath = join(outDirAbs, basename(file.path));
        assertCanWriteOutput(assetPath, resolvedEntries);
        writeFileSync(assetPath, file.contents);
      }
    }
  } else if (outdir) {
    const outDirAbs = resolve(outdir);
    mkdirSync(outDirAbs, { recursive: true });
    for (const file of outputFiles) {
      const outPath = join(outDirAbs, basename(file.path));
      assertCanWriteOutput(outPath, resolvedEntries);
      writeFileSync(outPath, file.contents);
    }
  }
}

function normalizeBase(base) {
  if (!base) return '/';
  if (base === '.') return '';
  let out = base.startsWith('/') ? base : `/${base}`;
  if (!out.endsWith('/')) out += '/';
  return out;
}

function isBrowserLikePlatform(platform) {
  return platform === undefined || platform === 'browser' || platform === 'react-native';
}

function injectDefaultNodeEnvDefine(opts) {
  if (opts.define['process.env.NODE_ENV'] !== undefined) return;

  const appBrowserCommand = opts.appCommand === 'dev' || opts.appCommand === 'build';
  const browserBundle = opts.bundle && (isBrowserLikePlatform(opts.platform) || opts.minifySyntax);
  if (!appBrowserCommand && !browserBundle) return;

  const isDev = opts.appCommand === 'dev' || opts.serve || opts.watch;
  opts.define['process.env.NODE_ENV'] = isDev ? '"development"' : '"production"';
}

function normalizeServerHost(host) {
  if (host === true) return '0.0.0.0';
  if (typeof host === 'string' && host.length > 0) return host;
  return undefined;
}

function mergeServerConfigIntoOpts(opts, config) {
  const server = config?.server;
  if (!server || typeof server !== 'object') return;

  if (opts.port === undefined && Number.isInteger(server.port)) {
    opts.port = server.port;
  }
  if (opts.host === undefined) {
    const host = normalizeServerHost(server.host);
    if (host !== undefined) opts.host = host;
  }
  if (opts.strictPort === false && server.strictPort === true) {
    opts.strictPort = true;
  }
  if (opts.open === false && server.open === true) {
    opts.open = true;
  }
}

function applyServerDefaults(opts) {
  if (opts.port === undefined) opts.port = 12300;
  if (opts.host === undefined) opts.host = 'localhost';
}

function isPortInUseError(err) {
  const code = err?.code;
  const message = String(err?.message ?? err);
  return code === 'EADDRINUSE' || /address already in use|port .*in use/i.test(message);
}

async function resolveServePort(opts, start) {
  let port = opts.port;
  for (;;) {
    try {
      const server = await start(port);
      opts.port = port;
      return server;
    } catch (err) {
      if (opts.strictPort || !isPortInUseError(err)) throw err;
      port += 1;
    }
  }
}

function getAutoConfigSearchDir(opts) {
  if (opts.appCommand === 'dev' || opts.appCommand === 'build') {
    return resolve(opts.appRoot ?? '.');
  }
  return process.cwd();
}

async function runAppBuild(opts, config, configEnv, _dotenvVars) {
  if (config?.plugins?.length || opts.pluginPaths.length > 0) {
    throw new Error(
      'zntc build app mode does not support JS plugins yet; use --bundle for plugin builds',
    );
  }
  const web = await loadWebModule();
  const root = resolve(opts.appRoot ?? '.');
  const outdir = resolve(opts.outdir ?? join(root, 'dist'));
  if (opts.clean) rmSync(outdir, { recursive: true, force: true });
  let pipelineRoot = null;
  try {
    const pipeline = await web.prepareAppCssPipelineRoot(
      root,
      outdir,
      configEnv,
      opts.logLevel,
      'build',
      { fallbackRequire: requireFromCli, cliNodeModules },
    );
    pipelineRoot = pipeline?.tempRoot ?? null;
    const result = buildAppSync({
      root: pipelineRoot ?? root,
      outdir,
      entryHtml: opts.entryHtml ?? 'index.html',
      publicDir: opts.publicDir === undefined ? 'public' : opts.publicDir,
      base: normalizeBase(opts.base ?? opts.publicPath ?? '/'),
      mode: configEnv.mode,
      envDir: opts.envDir ? resolve(opts.envDir) : (pipelineRoot ?? root),
      envPrefixes: opts.envPrefixes,
      define: Object.keys(opts.define).length > 0 ? opts.define : undefined,
      minify: opts.minify || opts.minifyWhitespace || opts.minifyIdentifiers || opts.minifySyntax,
      sourcemap: opts.sourcemap,
      splitting: opts.splitting || undefined,
      compiler: config?.compiler,
    });
    const htmlEnv = loadEnv(
      configEnv.mode,
      opts.envDir ? resolve(opts.envDir) : (pipelineRoot ?? root),
      ['ZNTC_'],
    );
    const { warnings: htmlWarnings } = web.applyHtmlEnvTokens(outdir, htmlEnv);
    if (opts.logLevel !== 'silent') {
      for (const w of htmlWarnings) console.error(`[html-env] ${w}`);
      console.error(`[build] wrote ${result.outputCount ?? 0} files to ${outdir}`);
    }
    return result;
  } finally {
    if (pipelineRoot) web.cleanupPostcssTempRoot(pipelineRoot);
  }
}

// HMR_MSG / APP_DEV_HMR_*_PATH / createHmrChannel 등은 @zntc/server 가 source
// of truth. dev/preview/build app 모드의 lazy load 한 web 모듈을 통해 접근
// (web 의 dist 에 server 가 inline). #2539 PR #6a cut over.

async function runAppDev(opts, config, configEnv, _dotenvVars) {
  printZntcBanner({
    flavor: 'web',
    version: getCliVersion(),
    silent: opts.logLevel === 'silent',
  });
  const web = await loadWebModule();
  const root = resolve(opts.appRoot ?? '.');
  opts.outdir = opts.outdir || join(root, '.zntc-dev');
  const appDev = web.createAppDevController(opts, root, configEnv, {
    fallbackRequire: requireFromCli,
    cliNodeModules,
  });
  const prepared = await appDev.prepare();

  opts.entryPoints = [prepared.entryPath];
  opts.serveDir = opts.outdir;

  return runServe(opts, config, { appDev });
}

// app 모드 (dev/preview/build) 에서만 @zntc/web 을 lazy import. bundle/transpile/watch
// 모드에서는 web 패키지를 받지 않은 사용자도 동작해야 하기에 정적 import 회피.
let webModulePromise = null;
async function loadWebModule() {
  if (webModulePromise) return webModulePromise;
  webModulePromise = (async () => {
    try {
      return await import('@zntc/web');
    } catch (err) {
      const code = err?.code;
      const message = String(err?.message ?? '');
      if (code === 'ERR_MODULE_NOT_FOUND' || /Cannot find package "@zntc\/web"/.test(message)) {
        console.error(
          'error: @zntc/web 패키지가 필요합니다 (zntc dev / preview / build app 모드).',
        );
        console.error('');
        console.error('help: install with `bun add -D @zntc/web` 또는 `npm i -D @zntc/web`.');
        process.exit(1);
      }
      throw err;
    }
  })();
  return webModulePromise;
}

// RN 모드 (`zntc bundle --platform=react-native`) — @zntc/react-native 을 lazy
// import. transpile/bundle 일반 사용자는 web 처럼 영향 0 (#2540 PR #7).
let rnModulePromise = null;
async function loadRnModule() {
  if (rnModulePromise) return rnModulePromise;
  rnModulePromise = (async () => {
    try {
      return await import('@zntc/react-native');
    } catch (err) {
      const code = err?.code;
      const message = String(err?.message ?? '');
      if (
        code === 'ERR_MODULE_NOT_FOUND' ||
        /Cannot find package "@zntc\/react-native"/.test(message)
      ) {
        console.error(
          'error: @zntc/react-native 패키지가 필요합니다 (zntc bundle --platform=react-native).',
        );
        console.error('');
        console.error(
          'help: install with `bun add -D @zntc/react-native` 또는 `npm i -D @zntc/react-native`.',
        );
        process.exit(1);
      }
      throw err;
    }
  })();
  return rnModulePromise;
}

/**
 * RN CLI 호환 미지원 영역 — 사용자가 `--asset-catalog-dest` 등을 지정해도 zntc 가
 * 처리 못 함을 한 줄 stderr 로 알림. silent drop 방지 (#2605 audit P0).
 *
 * graph-bundler 전용 + production asset 영역은 후속 PR (P0#2 — asset 복사) 에서
 * 흡수 예정. 현재는 경고만.
 */
function warnRnBundleUnsupported(opts) {
  // `--asset-catalog-dest` 는 iOS Images.xcassets — Xcode catalog 별도 작업이라
  // 본 스코프 외. graph-bundler 전용 (`transform-option` / `resolver-option`) 도
  // 미지원.
  const map = {
    assetCatalogDest: '--asset-catalog-dest',
    unstableTransformProfile: '--unstable-transform-profile',
    transformOptions: '--transform-option',
    resolverOptions: '--resolver-option',
  };
  for (const [key, flag] of Object.entries(map)) {
    const v = opts[key];
    if (v === undefined) continue;
    if (typeof v === 'object' && Object.keys(v).length === 0) continue;
    process.stderr.write(`[zntc:rn-bundle] ${flag} (zntc 미지원, ignore)\n`);
  }
}

async function runRnBundle(opts, config) {
  const rn = await loadRnModule();
  const cfg = config ?? {};
  const projectRoot = resolve(opts.rnProjectRoot ?? cfg.projectRoot ?? cfg.root ?? '.');
  const entry = opts.entryPoints?.[0];
  if (!entry) {
    console.error(
      'error: zntc bundle --platform=react-native 는 entry point 가 필요합니다 (예: `zntc bundle index.ts --platform=react-native`)',
    );
    process.exit(1);
  }
  warnRnBundleUnsupported(opts);
  const rnPlatform = opts.rnPlatform === 'android' ? 'android' : 'ios';

  // RN CLI 호환 — `--bundle-output X` 가 `--outfile X` 와 동일 의미. 양쪽 다 받되
  // 명시 우선순위: --outfile > --bundle-output. 둘 다 미지정 시 in-memory.
  const outfile = opts.outfile ?? opts.bundleOutput;

  // `--sourcemap-output` 또는 `--source-map-url` 이 명시되면 sourcemap 자동 활성.
  // bungae build.ts L38-79 와 동일 패턴 — caller-side write 로 path 처리.
  const wantsSourcemap = Boolean(opts.sourcemap || opts.sourcemapOutput || opts.sourceMapUrl);

  // outfile 명시 + 추가 path 옵션 (sourcemapOutput / sourceMapUrl / bundleEncoding /
  // sourcemapSourcesRoot / sourcemapUseAbsolutePath) 있으면 caller-side 로 직접
  // write — NAPI write:true 회피 후 sourcemap 후처리.
  const callerWrite =
    outfile &&
    (opts.sourcemapOutput ||
      opts.sourceMapUrl ||
      opts.bundleEncoding ||
      typeof opts.sourcemapSourcesRoot === 'string' ||
      opts.sourcemapUseAbsolutePath === true);

  const result = await rn.bundleRn({
    entry,
    projectRoot,
    rnPlatform,
    dev: Boolean(opts.devMode),
    sourcemap: wantsSourcemap,
    minify:
      opts.minify || opts.minifyWhitespace || opts.minifyIdentifiers || opts.minifySyntax || false,
    extra: buildRnBundleExtra(cfg, opts),
    override: buildRnBundleOverride(
      cfg,
      outfile && !callerWrite ? { outfile, write: true } : undefined,
    ),
  });

  // caller-side write — bundle / sourcemap path 분리 + URL override 적용.
  if (callerWrite && result.errors.length === 0 && result.outputFiles?.length) {
    const bundlePath = resolve(outfile);
    const mapPath = opts.sourcemapOutput ? resolve(opts.sourcemapOutput) : `${bundlePath}.map`;
    const sourceMappingURL = opts.sourceMapUrl ?? basename(mapPath);
    const encoding = opts.bundleEncoding ?? 'utf-8';
    mkdirSync(dirname(bundlePath), { recursive: true });
    let bundleCode = result.outputFiles[0].text;
    // sourcemap 이 emit 됐으면 `//# sourceMappingURL=` 주석 append.
    if (wantsSourcemap && result.outputFiles[1]) {
      bundleCode = `${bundleCode}\n//# sourceMappingURL=${sourceMappingURL}`;
    }
    writeFileSync(bundlePath, bundleCode, encoding);
    if (wantsSourcemap && result.outputFiles[1]) {
      mkdirSync(dirname(mapPath), { recursive: true });
      // ignoreList (DevTools) + path 옵션 한 패스. production bundle 의
      // DevTools 디버깅 시 node_modules / zntc:runtime frame 자동 hide.
      const mapJson = rn.postProcessSourceMap(result.outputFiles[1].text, {
        sourceRoot: opts.sourcemapSourcesRoot,
        useAbsolutePath: opts.sourcemapUseAbsolutePath === true,
        projectRoot,
      });
      writeFileSync(mapPath, mapJson);
    }
  }

  // production asset 복사 (`--assets-dest`) — dev=false + 명시 시. iOS 는
  // `<assetsDest>/<relPath>/<file>`, Android 는 Metro scaleToDrawable folder
  // + flattened naming + keep.xml. 미지정 시 skip (dev server 가 HTTP 서빙).
  if (result.errors.length === 0 && !opts.devMode && opts.assetsDest) {
    const assetsDestAbs = resolve(opts.assetsDest);
    try {
      const copied = copyRnAssets({
        projectRoot,
        assetsDest: assetsDestAbs,
        rnPlatform,
        assetExts: rn.DEFAULT_ASSET_EXTS ?? [],
      });
      if (opts.logLevel !== 'silent') {
        console.error(`[bundle] copied ${copied} asset(s) to ${assetsDestAbs}`);
      }
    } catch (err) {
      process.stderr.write(`[zntc:rn-bundle] asset copy 실패: ${err?.message ?? err}\n`);
    }
  }

  if (result.errors.length === 0 && opts.logLevel !== 'silent') {
    console.error(`[bundle] react-native ${rnPlatform} ${outfile ?? '(in-memory)'}`);
  }
  return result;
}

/**
 * `zntc dev --platform=react-native` (#2605) — @zntc/react-native 의 serveRn lazy
 * import. cli-server-api / dev-middleware / RN runtime peer optional.
 */
async function runRnDev(opts, config) {
  const rn = await loadRnModule();
  const input = buildRnDevServerInput(opts, config);
  if (!input) {
    console.error(
      'error: zntc dev --platform=react-native 는 entry point 가 필요합니다 (예: `zntc dev index.js --platform=react-native`)',
    );
    process.exit(1);
  }
  // banner / bundle log 모두 serveRn 내부가 출력 — version 만 주입.
  const handle = await rn.serveRn(rn.buildRnDevServerOptions(input), {
    silent: opts.logLevel === 'silent',
    version: getCliVersion(),
  });

  // Graceful shutdown — SIGINT / SIGTERM 시 handle.stop().
  const onSignal = async () => {
    await handle.stop();
    process.exit(0);
  };
  process.once('SIGINT', onSignal);
  process.once('SIGTERM', onSignal);
}

async function runAppPreview(opts) {
  opts.serveDir = resolve(opts.previewDir ?? opts.outdir ?? 'dist');
  opts.outdir = undefined;
  opts.bundle = false;
  opts.watch = false;
  return runServe(opts, null);
}

function normalizeSpaFallback(value) {
  if (value === undefined || value === null || value === false || value === 'false') return null;
  const raw = value === true ? 'index.html' : String(value);
  return raw.startsWith('/') ? raw.slice(1) : raw;
}

function requestAcceptsHtml(accept) {
  if (!accept) return true;
  return accept.includes('text/html') || accept.includes('*/*');
}

function looksLikeAssetPath(pathname) {
  return extname(pathname) !== '';
}

// ─── Transpile 모드 ───

async function runTranspile(opts) {
  let source;
  if (opts.stdin) {
    // stdin 읽기
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    source = Buffer.concat(chunks).toString();
  } else {
    source = readFileSync(resolve(opts.entryPoints[0]), 'utf8');
  }

  if (opts.tokenize) {
    const filename = opts.stdin ? 'stdin.ts' : opts.entryPoints[0];
    const tokens = tokenize(source, { filename });
    process.stdout.write(formatTokenizeOutput(tokens, opts.tokenizeFormat));
    return;
  }

  if (opts.profile.length > 0) {
    configureProfile(opts.profile, opts.profileLevel);
  }

  const result = transpile(source, {
    filename: opts.stdin ? 'stdin.ts' : opts.entryPoints[0],
    sourcemap: opts.sourcemap,
    minify: opts.minify,
    minifyWhitespace: opts.minifyWhitespace,
    minifyIdentifiers: opts.minifyIdentifiers,
    minifySyntax: opts.minifySyntax,
    jsx: opts.jsx,
    jsxFactory: opts.jsxFactory,
    jsxFragment: opts.jsxFragment,
    jsxImportSource: opts.jsxImportSource,
    flow: opts.flow,
    jsxInJs: opts.jsxInJs,
    experimentalDecorators: opts.experimentalDecorators,
    emitDecoratorMetadata: opts.emitDecoratorMetadata,
    useDefineForClassFields: opts.useDefineForClassFields,
    verbatimModuleSyntax: opts.verbatimModuleSyntax,
    tsconfigPath: opts.project,
    asciiOnly: opts.asciiOnly,
    charsetUtf8: opts.charsetUtf8,
    quotes: opts.quotes,
    format: opts.format,
    platform: opts.platform,
    dropConsole: opts.drop.includes('console'),
    dropDebugger: opts.drop.includes('debugger'),
    target: opts.target,
    browserslist: opts.browserslist,
    tsconfigRaw: opts.tsconfigRaw,
    stopAfter: opts.stopAfter,
  });

  if (opts.outfile || opts.outdir) {
    const name = basename(opts.entryPoints[0]).replace(/\.[^.]+$/, '.js');
    // transpile result.code / result.map 은 string — writeOutputFiles 는 contents
    // (Uint8Array) 를 받으므로 `Buffer.from` 으로 한 번 변환. 같은 메모리 backing 의
    // utf-8 byte view 라 추가 copy 없음.
    const outputFiles = [{ path: name, contents: Buffer.from(result.code) }];
    if (opts.outfile && result.map) {
      outputFiles.push({ path: name + '.map', contents: Buffer.from(result.map) });
    }
    writeOutputFiles(outputFiles, opts.outfile, opts.outdir, opts.entryPoints, opts.allowOverwrite);
  } else {
    process.stdout.write(result.code);
  }

  if (opts.profile.length > 0) {
    process.stderr.write(profileReport(opts.profileFormat ?? 'table'));
  }
}

// ─── Bundle 모드 ───

/**
 * config 로드 — `--config <path>` 명시 시 그 경로, 아니면 cwd 자동 탐색.
 *
 * 함수형 config 는 CLI 모드/`--mode` 인자 기반의 `ConfigEnv` 로 호출된다:
 *  - command: serve→"serve", watch→"watch", 그 외→"bundle"
 *  - mode: `--mode <name>` 명시값 또는 command 기본 (serve/watch→"development", 그 외→"production")
 *  - env: dotenv 파일 + process.env 머지. shell env 가 file 보다 우선 (CI 가 .env
 *    값을 override 가능 — Vite/dotenv 16+ 와 일치).
 *
 * 실패 시 `Error("failed to load config — ...")` 를 throw — main 의 try/catch 가 처리.
 */
async function loadAutoConfig(opts) {
  const explicit = opts.configPath ? resolve(opts.configPath) : null;
  if (explicit && !existsSync(explicit)) {
    throw new Error(`failed to load config — file not found: ${explicit}`);
  }
  const configSearchDir = getAutoConfigSearchDir(opts);
  const configPath = explicit ?? findConfigPath(configSearchDir);

  const command = opts.serve ? 'serve' : opts.watch ? 'watch' : 'bundle';
  const mode = opts.mode ?? (command === 'bundle' ? 'production' : 'development');

  // .env 파일 4단계 우선순위로 로드 (#2106). prefix 미지정 시 default `["VITE_", "ZNTC_"]`.
  const envDir = opts.envDir ? resolve(opts.envDir) : configSearchDir;
  const dotenvVars = loadEnv(mode, envDir, opts.envPrefixes);

  // dotenv 키 중 shell env 에도 정의된 건 shell 값으로 override (CI/배포 시 .env
  // 수정 없이 override — Vite/dotenv 16+ 와 일치). dotenvVars 자체를 final source 로
  // 갱신하면 envToDefine 에 그대로 전달 가능 (별도 머지 불필요).
  for (const k of Object.keys(dotenvVars)) {
    const shellValue = process.env[k];
    if (shellValue !== undefined) dotenvVars[k] = shellValue;
  }

  // dotenv 파일 부재 시 process.env spread 회피 (보통 100+ 키 복사 방지).
  const mergedEnv =
    Object.keys(dotenvVars).length === 0 ? process.env : { ...process.env, ...dotenvVars };
  const env = { command, mode, env: mergedEnv };

  // mode-specific config 자동 탐색 + 머지 (#2110). `--config <path>` 명시 시
  // 그 파일이 단독 source — mode-specific 자동 탐색 안 함 (사용자 의도 존중).
  const modeConfigPath = explicit ? null : findModeConfigPath(configSearchDir, mode);

  if (!configPath && !modeConfigPath) return { config: null, env, dotenvVars };

  try {
    const baseConfig = configPath ? await loadConfig(configPath, env) : {};
    const modeConfig = modeConfigPath ? await loadConfig(modeConfigPath, env) : null;
    const config = modeConfig ? mergeUserConfigs(baseConfig, modeConfig) : baseConfig;
    return { config, env, dotenvVars };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    throw new Error(`failed to load config — ${reason}`);
  }
}

/**
 * CLI > config 우선순위로 BuildOptions 머지.
 *
 * - scalar/string: CLI 가 undefined 면 config 사용
 * - boolean (default=false): CLI 가 false 면 config=true 만 적용 (`minify`, `sourcemap` 등)
 * - boolean (default=true): CLI 가 true 면 config=false 만 적용 (`sourcesContent`, `treeShaking` 등)
 *   ※ CLI 가 명시적으로 default 값을 줬는지 (--no-minify 같은) 구분 못 하는 한계 존재.
 *      함수형 config (#2103) 에서 정밀한 우선순위 적용 예정.
 * - 배열: CLI 가 비어있으면 config 사용
 * - 객체 (define/alias/loader): shallow merge (config defaults + CLI override)
 *
 * FIXME: 키 리스트 4종이 `BuildOptions` 와 수동 동기화. 새 옵션 추가 시 누락 가능.
 *        근본 fix 는 #2112 (Phase 3-5 schema sync) 에서 single source of truth 도입.
 */
function mergeConfigIntoOpts(opts, config) {
  if (!config) return opts;

  const SCALAR_KEYS = [
    'format',
    'platform',
    'target',
    'banner',
    'footer',
    'globalName',
    'publicPath',
    'entryNames',
    'chunkNames',
    'assetNames',
    'jsx',
    'jsxFactory',
    'jsxFragment',
    'jsxImportSource',
    'quotes',
    'preserveModulesRoot',
    'legalComments',
    'sourceRoot',
    'sourcemapMode',
    'jobs',
    'logLevel',
    'logLimit',
    'lineLimit',
    'outputExports',
    'outExtensionJs',
    'metafile',
    'spaFallback',
    'outfile',
    'outdir',
    'outbase',
    'browserslist',
    'tsconfigRaw',
    'intro',
    'outro',
    'stopAfter',
    'profileLevel',
    'profileFormat',
    'runtimePolyfills',
    'coreJs',
    'tokenizeFormat',
  ];
  for (const key of SCALAR_KEYS) {
    if (opts[key] === undefined && config[key] !== undefined) {
      opts[key] = config[key];
    }
  }

  // boolean default=false → config 가 true 면 적용. CLI 명시 false 를 구분 못 하므로
  // 함수형 config (#2103) 에서 정밀한 우선순위 적용 예정.
  const BOOL_KEYS = [
    'minify',
    'minifyWhitespace',
    'minifyIdentifiers',
    'minifySyntax',
    'sourcemap',
    'sourcemapDebugIds',
    'splitting',
    'flow',
    'experimentalDecorators',
    'emitDecoratorMetadata',
    'keepNames',
    'shimMissingExports',
    'preserveSymlinks',
    'charsetUtf8',
    'asciiOnly',
    'jsxInJs',
    'jsxDev',
    'preserveModules',
    'verbatimModuleSyntax',
    'packagesExternal',
    'allowOverwrite',
    'ignoreAnnotations',
    'jsxSideEffects',
  ];
  for (const key of BOOL_KEYS) {
    if (opts[key] === false && config[key] === true) {
      opts[key] = true;
    }
  }
  // sourcesContent / treeShaking / useDefineForClassFields 는 default=true.
  // CLI 가 default 면 config 가 false 일 때 false 로.
  for (const key of ['sourcesContent', 'treeShaking', 'useDefineForClassFields']) {
    if (opts[key] === true && config[key] === false) {
      opts[key] = false;
    }
  }

  const ARRAY_KEYS = [
    'entryPoints',
    'external',
    'inject',
    'drop',
    'dropLabels',
    'pure',
    'resolveExtensions',
    'mainFields',
    'conditions',
    'nodePaths',
    'profile',
  ];
  for (const key of ARRAY_KEYS) {
    if (opts[key].length === 0 && Array.isArray(config[key]) && config[key].length > 0) {
      opts[key] = [...config[key]];
    }
  }

  for (const key of ['define', 'alias', 'loader', 'globals']) {
    if (config[key] && typeof config[key] === 'object') {
      opts[key] = { ...config[key], ...opts[key] };
    }
  }
  mergeServerConfigIntoOpts(opts, config);

  return opts;
}

function mergeCliRuntimeTargets(runtimePolyfills, runtimeTargetQueries) {
  if (!Array.isArray(runtimeTargetQueries) || runtimeTargetQueries.length === 0) {
    return runtimePolyfills;
  }
  if (runtimePolyfills === undefined || runtimePolyfills === 'off') return runtimePolyfills;
  const targets = runtimeTargetQueries;
  if (typeof runtimePolyfills === 'string') return { mode: runtimePolyfills, targets };
  if (runtimePolyfills && typeof runtimePolyfills === 'object') {
    return { ...runtimePolyfills, targets };
  }
  return runtimePolyfills;
}

async function runBundle(opts, config) {
  // config 자동 탐색 + 머지는 main() 에서 모든 모드에 대해 사전 적용된다.
  // 여기서는 plugins 만 추가로 합친다 (config 의 plugins → --plugin <path> 의 plugins).
  const plugins = [];
  if (config && Array.isArray(config.plugins)) {
    plugins.push(...config.plugins);
  }
  for (const pluginPath of opts.pluginPaths) {
    const absPath = resolve(pluginPath);
    // importAndResolveDefault 는 pathToFileURL 으로 Windows 경로를 안전하게 처리하고
    // ENOENT/객체 검증을 통일한다 (config-loader 와 공유).
    const cfg = await importAndResolveDefault(absPath);
    if (Array.isArray(cfg.plugins)) {
      plugins.push(...cfg.plugins);
    } else if (typeof cfg.setup === 'function') {
      plugins.push(cfg);
    }
  }

  const buildOpts = {
    entryPoints: opts.entryPoints.map((e) => resolve(e)),
    format: opts.format,
    platform: opts.platform,
    target: opts.target,
    browserslist: opts.browserslist,
    external: opts.external,
    packagesExternal: opts.packagesExternal,
    // `--alias:K=V` 플래그 (webpack/rollup 스타일) — JS 옵션이 tsconfig paths 보다 우선 적용됨.
    alias: Object.keys(opts.alias).length > 0 ? opts.alias : undefined,
    define: Object.keys(opts.define).length > 0 ? opts.define : undefined,
    loader: Object.keys(opts.loader).length > 0 ? opts.loader : undefined,
    minify: opts.minify,
    minifyWhitespace: opts.minifyWhitespace,
    minifyIdentifiers: opts.minifyIdentifiers,
    minifySyntax: opts.minifySyntax,
    splitting: opts.splitting,
    sourcemap: opts.sourcemap,
    sourcemapMode: opts.sourcemapMode,
    sourcemapDebugIds: opts.sourcemapDebugIds,
    sourcesContent: opts.sourcesContent,
    sourceRoot: opts.sourceRoot,
    treeShaking: opts.treeShaking,
    metafile: !!opts.metafile,
    keepNames: opts.keepNames,
    shimMissingExports: opts.shimMissingExports,
    preserveSymlinks: opts.preserveSymlinks,
    flow: opts.flow,
    jsxInJs: opts.jsxInJs,
    charsetUtf8: opts.charsetUtf8,
    asciiOnly: opts.asciiOnly,
    quotes: opts.quotes,
    drop: opts.drop.length > 0 ? opts.drop : undefined,
    dropLabels: opts.dropLabels.length > 0 ? opts.dropLabels : undefined,
    pure: opts.pure.length > 0 ? opts.pure : undefined,
    // bundle 모드도 transpile 과 동일하게 drop console/debugger 적용 (#2155).
    dropConsole: opts.drop.includes('console'),
    dropDebugger: opts.drop.includes('debugger'),
    useDefineForClassFields: opts.useDefineForClassFields,
    experimentalDecorators: opts.experimentalDecorators,
    emitDecoratorMetadata: opts.emitDecoratorMetadata,
    verbatimModuleSyntax: opts.verbatimModuleSyntax,
    preserveModules: opts.preserveModules,
    preserveModulesRoot: opts.preserveModulesRoot,
    inlineDynamicImports: opts.inlineDynamicImports,
    legalComments: opts.legalComments,
    logLevel: opts.logLevel,
    logLimit: opts.logLimit,
    lineLimit: opts.lineLimit,
    allowOverwrite: opts.allowOverwrite,
    outputExports: opts.outputExports,
    resolveExtensions: opts.resolveExtensions.length > 0 ? opts.resolveExtensions : undefined,
    mainFields: opts.mainFields.length > 0 ? opts.mainFields : undefined,
    conditions: opts.conditions.length > 0 ? opts.conditions : undefined,
    nodePaths: opts.nodePaths.length > 0 ? opts.nodePaths : undefined,
    profile: opts.profile.length > 0 ? opts.profile : undefined,
    profileLevel: opts.profileLevel,
    profileFormat: opts.profileFormat,
    runtimePolyfills: mergeCliRuntimeTargets(opts.runtimePolyfills, opts.runtimeTargetQueries),
    coreJs: opts.coreJs,
    ignoreAnnotations: opts.ignoreAnnotations,
    jsxSideEffects: opts.jsxSideEffects,
    // NAPI 가 tsconfig paths / baseUrl 을 alias 로 변환해 resolver 에 주입하도록 전달.
    tsconfigPath: opts.project,
    tsconfigRaw: opts.tsconfigRaw,
    banner: opts.banner,
    footer: opts.footer,
    intro: opts.intro,
    outro: opts.outro,
    globalName: opts.globalName,
    globals: Object.keys(opts.globals).length > 0 ? opts.globals : undefined,
    publicPath: opts.publicPath,
    entryNames: opts.entryNames,
    chunkNames: opts.chunkNames,
    assetNames: opts.assetNames,
    jsx: opts.jsx,
    jsxDev: opts.jsxDev,
    jsxFactory: opts.jsxFactory,
    jsxFragment: opts.jsxFragment,
    jsxImportSource: opts.jsxImportSource,
    inject: opts.inject.map((p) => resolve(p)),
    devMode: opts.devMode,
    globalIdentifiers: opts.globalIdentifiers,
    // --polyfill / --run-before-main / --watch-folder 는 경로 → abs 변환 (--inject 와 동일).
    // --watch-include / --watch-exclude 는 루트 기준 glob 이므로 변환 안 함.
    polyfills: opts.polyfills?.length ? opts.polyfills.map((p) => resolve(p)) : undefined,
    runBeforeMain: opts.runBeforeMain?.length
      ? opts.runBeforeMain.map((p) => resolve(p))
      : undefined,
    watchFolders: opts.watchFolders?.length ? opts.watchFolders.map((p) => resolve(p)) : undefined,
    watchInclude: opts.watchInclude?.length ? opts.watchInclude : undefined,
    watchExclude: opts.watchExclude?.length ? opts.watchExclude : undefined,
    jobs: opts.jobs,
    outbase: opts.outbase,
    plugins: plugins.length > 0 ? plugins : undefined,
    // compiler.styledComponents / compiler.emotion 도 bundle 모드에서 forward.
    // 누락 시 `zntc.config.json` 의 `compiler` 설정이 silently drop 돼 1st-party transform
    // (autoLabel 등) 이 활성화 안 됨.
    compiler: config?.compiler,
  };

  const result = plugins.length > 0 ? await build(buildOpts) : buildSync(buildOpts);

  if (result.errors.length > 0 && opts.logLevel !== 'silent') {
    for (const err of result.errors) {
      const loc = err.location ? `${err.location.file}: ` : '';
      console.error(`error: ${loc}${err.text}`);
    }
  }
  if (result.warnings.length > 0 && opts.logLevel !== 'silent' && opts.logLevel !== 'error') {
    for (const warn of result.warnings) {
      console.error(`warning: ${warn.text}`);
    }
  }

  // 출력
  if (opts.outfile || opts.outdir) {
    if (opts.clean && opts.outdir) {
      rmSync(resolve(opts.outdir), { recursive: true, force: true });
    }
    writeOutputFiles(
      result.outputFiles,
      opts.outfile,
      opts.outdir,
      opts.entryPoints,
      opts.allowOverwrite,
    );
  } else {
    // stdout
    if (result.outputFiles.length > 0) {
      process.stdout.write(result.outputFiles[0].text);
    }
  }

  // metafile
  if (opts.metafile && result.metafile) {
    if (opts.analyze) {
      console.error(result.metafile);
    } else {
      writeFileSync(resolve(opts.metafile), result.metafile);
    }
  }

  if (opts.profile.length > 0) {
    process.stderr.write(profileReport(opts.profileFormat ?? 'table'));
  }

  return result;
}

// ─── Watch 모드 ───

async function runWatch(opts, config) {
  const { watch } = await import('node:fs');

  let building = false;
  let pendingRebuild = false;
  let debounceTimer = null;

  async function rebuild() {
    if (building) {
      pendingRebuild = true;
      return;
    }
    building = true;

    try {
      const start = performance.now();
      const result = await runBundle(opts, config);
      const elapsed = Math.round(performance.now() - start);
      const files = result.outputFiles?.length ?? 0;

      if (opts.watchJson) {
        const event =
          result.errors.length > 0
            ? { type: 'rebuild', success: false, error: result.errors[0]?.text }
            : { type: 'rebuild', success: true, files, ms: elapsed };
        console.log(JSON.stringify(event));
      } else if (opts.logLevel !== 'silent') {
        if (result.errors.length === 0) {
          console.error(`[watch] rebuilt in ${elapsed}ms`);
        }
      }
    } catch (err) {
      if (opts.watchJson) {
        console.log(JSON.stringify({ type: 'rebuild', success: false, error: String(err) }));
      } else if (opts.logLevel !== 'silent') {
        console.error(`[watch] error: ${err}`);
      }
    } finally {
      building = false;
      if (pendingRebuild) {
        pendingRebuild = false;
        rebuild();
      }
    }
  }

  // 초기 빌드
  await rebuild();

  // 파일 감시
  const watchDirs = new Set();
  for (const entry of opts.entryPoints) {
    watchDirs.add(safeRealpath(dirname(resolve(entry))));
  }
  // config/.env 파일 변경 감지를 위해 cwd / envDir / config 디렉토리 추가.
  const restartTriggers = computeRestartTriggers(opts);
  for (const dir of restartTriggers.dirs) watchDirs.add(safeRealpath(dir));

  for (const dir of watchDirs) {
    const watcher = watch(dir, { recursive: true }, (_event, filename) => {
      if (!filename) return;
      // node_modules, .git, 출력 디렉토리 무시
      if (filename.includes('node_modules') || filename.includes('.git')) return;
      if (opts.outdir && filename.startsWith(basename(resolve(opts.outdir)))) return;

      if (restartTriggers.matches(filename)) {
        emitRestart(opts, 'config 또는 .env 파일 변경 감지');
        return;
      }

      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(rebuild, opts.watchDelay);
    });
    attachWatcherErrorHandler(watcher, dir, opts.logLevel);
  }

  if (opts.watchJson) {
    console.log(JSON.stringify({ type: 'ready' }));
  } else if (opts.logLevel !== 'silent') {
    console.error('[watch] watching for changes...');
  }
}

/**
 * watch/serve 모드에서 config 또는 .env 파일이 변경되면 in-process reload 가
 * 까다롭다 (.ts config 의 dynamic import 캐시, mergeConfigIntoOpts 의 1회성 mutation 등).
 * Vite 식 spawn-self 패턴으로 깔끔히 재시작 — 동일 argv 로 자식 프로세스 시작 후 종료.
 */
function computeRestartTriggers(opts) {
  const dirs = new Set();
  const configSearchDir = getAutoConfigSearchDir(opts);
  const envDir = opts.envDir ? resolve(opts.envDir) : configSearchDir;
  dirs.add(envDir);

  const explicitConfig = opts.configPath ? resolve(opts.configPath) : null;
  const autoConfig = explicitConfig ?? findConfigPath(configSearchDir);
  if (autoConfig) dirs.add(dirname(autoConfig));

  const mode = opts.mode ?? (opts.serve || opts.watch ? 'development' : 'production');
  // mode-specific config (`zntc.config.${mode}.{ext}`) 변경도 restart trigger (#2110).
  const modeConfig = explicitConfig ? null : findModeConfigPath(configSearchDir, mode);
  if (modeConfig) dirs.add(dirname(modeConfig));

  const configBase = autoConfig ? basename(autoConfig) : null;
  const modeConfigBase = modeConfig ? basename(modeConfig) : null;
  const envBases = new Set(['.env', '.env.local', `.env.${mode}`, `.env.${mode}.local`]);

  return {
    dirs,
    matches(filename) {
      const base = basename(filename);
      if (modeConfigBase && base === modeConfigBase) return true;
      if (configBase && base === configBase) return true;
      if (envBases.has(base)) return true;
      return false;
    },
  };
}

/**
 * fs.watch 의 'error' 이벤트는 unhandled 면 process crash 를 일으킨다. macOS Node v24
 * 의 `recursive: true` 는 빈 디렉토리에서도 즉시 EMFILE 'error' 를 던질 수 있어
 * (kqueue 기반 한계), watch 가 죽는 건 허용하되 dev server 자체는 살아있도록 한다
 * — fail-soft. 첫 error 후 watcher 를 닫으므로 `once` 로 충분.
 */
function attachWatcherErrorHandler(watcher, dir, logLevel) {
  watcher.once('error', (err) => {
    if (logLevel !== 'silent') {
      if (err && (err.code === 'EMFILE' || err.code === 'ENOSPC')) {
        console.error(
          `[watch] ${dir} 파일 감시 비활성화 (${err.code}): 변경 시 재빌드가 동작하지 않습니다. ` +
            `open-file 한도를 늘리거나 큰 하위 트리를 제거하세요.`,
        );
      } else {
        console.error(`[watch] ${dir} 감시 오류: ${err?.message ?? err}`);
      }
    }
    try {
      watcher.close();
    } catch {}
  });
}

function emitRestart(opts, reason) {
  return emitRestartAfter(opts, reason, null);
}

async function emitRestartAfter(opts, reason, beforeSpawn) {
  if (opts.watchJson) {
    console.log(JSON.stringify({ type: 'restart', reason }));
  } else if (opts.logLevel !== 'silent') {
    console.error(`[watch] ${reason} — restarting CLI...`);
  }
  if (beforeSpawn) await beforeSpawn();
  // 자식 프로세스 spawn 후 종료 — 새 프로세스가 fresh config/env 로 시작.
  // stdio inherit 으로 부모의 출력 스트림을 그대로 이어받는다.
  const { spawn } = await import('node:child_process');
  const child = spawn(process.argv[0], process.argv.slice(1), {
    stdio: 'inherit',
    env: process.env,
  });
  child.on('exit', (code) => process.exit(code ?? 0));
  child.on('error', (err) => {
    console.error(`[watch] restart failed: ${err}`);
    process.exit(1);
  });
}

// ─── Serve 모드 ───

async function runServe(opts, config, { appDev = null } = {}) {
  const isBun = typeof globalThis.Bun !== 'undefined';
  // appDev 모드에서만 web 모듈 (HMR_MSG / APP_DEV_HMR_*_PATH / createHmrChannel /
  // APP_DEV_HMR_CLIENT) 이 필요. handleRequest / watch drain 의 hot path 마다
  // `web.X.Y` property chain 을 재계산하지 않도록 진입 시점에 destructure 해
  // 캐시 (per-request 호출, #2539 PR #6a /simplify finding).
  const web = appDev ? await loadWebModule() : null;
  const hmr = web ? web.createHmrChannel() : null;
  const HMR_MSG = web?.HMR_MSG;
  const APP_DEV_HMR_CLIENT = web?.APP_DEV_HMR_CLIENT;
  const APP_DEV_HMR_CLIENT_PATH = web?.APP_DEV_HMR_CLIENT_PATH;
  const APP_DEV_HMR_WS_PATH = web?.APP_DEV_HMR_WS_PATH;
  let serverHandle = null;
  const mimeTypes = {
    '.html': 'text/html',
    '.js': 'application/javascript',
    '.mjs': 'application/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.gif': 'image/gif',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.map': 'application/json',
  };

  // 번들 모드면 먼저 빌드
  if (opts.bundle && opts.entryPoints.length > 0) {
    opts.outdir = opts.outdir || join(opts.serveDir, '.zntc-serve');
    const bundleResult = await runBundle(opts, config);
    if (appDev) {
      if (bundleResult.errors.length > 0) {
        hmr?.reportError(bundleResult.errors);
      } else {
        hmr?.clearError();
        appDev.injectBundleCssLinks(bundleResult);
        await appDev.afterBundle();
      }
    }

    // watch도 같이
    if (!opts.watch) {
      opts.watch = true;
    }
  }

  const serveDir = resolve(opts.outdir || opts.serveDir);
  const base = normalizeBase(opts.base ?? '/');

  function handleRequest(reqUrl, accept = '') {
    let pathname = new URL(reqUrl, 'http://localhost').pathname;
    if (appDev && pathname === APP_DEV_HMR_CLIENT_PATH) {
      return {
        status: 200,
        body: APP_DEV_HMR_CLIENT,
        type: 'application/javascript',
      };
    }
    if (base && base !== '/' && pathname.startsWith(base)) {
      pathname = '/' + pathname.slice(base.length);
    }
    if (pathname === '/') pathname = '/index.html';

    let filePath = join(serveDir, pathname);
    if (!existsSync(filePath)) {
      const fallback = normalizeSpaFallback(opts.spaFallback);
      if (!fallback || !requestAcceptsHtml(accept) || looksLikeAssetPath(pathname)) {
        return { status: 404, body: 'Not Found', type: 'text/plain' };
      }
      const fallbackPath = resolve(serveDir, fallback);
      const insideServeDir =
        fallbackPath === serveDir || fallbackPath.startsWith(`${serveDir}${sep}`);
      if (!insideServeDir || !existsSync(fallbackPath)) {
        return { status: 404, body: 'Not Found', type: 'text/plain' };
      }
      filePath = fallbackPath;
    }

    const ext = extname(filePath);
    const type = mimeTypes[ext] || 'application/octet-stream';
    const body = readFileSync(filePath);
    return { status: 200, body, type };
  }

  const useTls = opts.certfile && opts.keyfile;

  if (isBun) {
    // Bun.serve
    const serveOpts = {
      port: opts.port,
      hostname: opts.host,
      fetch(req, server) {
        const url = new URL(req.url);
        // /__hmr WebSocket upgrade — Bun-native API 사용 (Node 분기는 server.on('upgrade')).
        if (hmr && url.pathname === APP_DEV_HMR_WS_PATH) {
          if (server.upgrade(req)) return undefined;
          return new Response('Upgrade required', { status: 426 });
        }
        // 프록시 처리
        for (const [prefix, target] of Object.entries(opts.proxy)) {
          if (url.pathname.startsWith(prefix)) {
            return fetch(target + url.pathname.slice(prefix.length) + url.search);
          }
        }

        const { status, body, type } = handleRequest(req.url, req.headers.get('accept') ?? '');
        return new Response(body, {
          status,
          headers: {
            'Content-Type': type,
            'Access-Control-Allow-Origin': '*',
          },
        });
      },
    };
    if (hmr) {
      serveOpts.websocket = {
        open(ws) {
          hmr.addBunClient(ws);
        },
        close(ws) {
          hmr.removeBunClient(ws);
        },
        message() {},
      };
    }
    if (useTls) {
      serveOpts.tls = {
        cert: globalThis.Bun.file(opts.certfile),
        key: globalThis.Bun.file(opts.keyfile),
      };
    }
    serverHandle = await resolveServePort(opts, (port) => {
      serveOpts.port = port;
      return globalThis.Bun.serve(serveOpts);
    });
  } else {
    // Node.js http/https
    const handler = async (req, res) => {
      // 프록시 처리
      const url = new URL(req.url, `${useTls ? 'https' : 'http'}://${req.headers.host}`);
      for (const [prefix, target] of Object.entries(opts.proxy)) {
        if (url.pathname.startsWith(prefix)) {
          try {
            const proxyRes = await fetch(target + url.pathname.slice(prefix.length) + url.search, {
              method: req.method,
              headers: req.headers,
            });
            res.writeHead(proxyRes.status, Object.fromEntries(proxyRes.headers));
            const body = await proxyRes.arrayBuffer();
            res.end(Buffer.from(body));
          } catch {
            res.writeHead(502);
            res.end('Bad Gateway');
          }
          return;
        }
      }

      const { status, body, type } = handleRequest(req.url, req.headers.accept ?? '');
      res.writeHead(status, {
        'Content-Type': type,
        'Access-Control-Allow-Origin': '*',
      });
      res.end(body);
    };
    const server = useTls
      ? createHttpsServer(
          { cert: readFileSync(opts.certfile), key: readFileSync(opts.keyfile) },
          handler,
        )
      : createServer(handler);
    if (hmr) {
      server.on('upgrade', (req, socket) => {
        const pathname = new URL(req.url, `${useTls ? 'https' : 'http'}://${req.headers.host}`)
          .pathname;
        if (pathname !== APP_DEV_HMR_WS_PATH) {
          socket.destroy();
          return;
        }
        hmr.accept(req, socket);
      });
    }
    serverHandle = await resolveServePort(
      opts,
      (port) =>
        new Promise((resolveListen, rejectListen) => {
          const onError = (err) => {
            server.off('listening', onListening);
            rejectListen(err);
          };
          const onListening = () => {
            server.off('error', onError);
            resolveListen(server);
          };
          server.once('error', onError);
          server.once('listening', onListening);
          server.listen(port, opts.host);
        }),
    );
  }

  async function closeServerForRestart() {
    if (!serverHandle) return;
    if (typeof serverHandle.stop === 'function') {
      await serverHandle.stop();
      return;
    }
    if (typeof serverHandle.close === 'function') {
      await new Promise((resolveClose, rejectClose) => {
        serverHandle.close((err) => (err ? rejectClose(err) : resolveClose()));
      });
    }
  }

  const protocol = useTls ? 'https' : 'http';
  if (opts.logLevel !== 'silent') {
    console.error(`[serve] ${protocol}://${opts.host}:${opts.port}`);
  }

  // watch 시작 (번들 모드일 때)
  if (opts.watch && opts.bundle) {
    const { watch: fsWatch } = await import('node:fs');
    const outdirAbs = opts.outdir ? resolve(opts.outdir) : null;
    const outdirPrefix = outdirAbs ? `${outdirAbs}${sep}` : null;
    let debounceTimer = null;
    let rebuilding = false;
    const dirty = new Set();

    async function rebuildAppDevCss(changedPath) {
      await appDev.afterBundle({ changedPath });
      hmr?.clearError();
      hmr?.broadcast({
        type: HMR_MSG.CssUpdate,
        href: appDev.hrefFor(changedPath),
        timestamp: Date.now(),
      });
      if (opts.logLevel !== 'silent') console.error('[serve] css updated');
    }

    async function rebuildAppDevFull(dirtyPaths = null) {
      const prepared = await appDev.prepare(dirtyPaths);
      opts.entryPoints = [prepared.entryPath];
      const bundleResult = await runBundle(opts, config);
      if (bundleResult.errors.length > 0) {
        hmr?.reportError(bundleResult.errors);
        return;
      }
      hmr?.clearError();
      appDev.injectBundleCssLinks(bundleResult);
      await appDev.afterBundle();
      hmr?.broadcast({ type: HMR_MSG.FullReload, timestamp: Date.now() });
      if (opts.logLevel !== 'silent') console.error('[serve] rebuilt');
    }

    async function drain() {
      if (rebuilding) return;
      rebuilding = true;
      try {
        while (dirty.size > 0) {
          const paths = Array.from(dirty);
          dirty.clear();
          if (!appDev) {
            await runBundle(opts, config);
            if (opts.logLevel !== 'silent') console.error('[serve] rebuilt');
            continue;
          }
          // 변경된 path 들이 모두 CSS-only 면 incremental 처리, 그 외엔 full reload.
          const allCssOnly = paths.every(
            (p) => appDev.isCssOnlyChange(p) || appDev.isPostcssConfig(p),
          );
          if (allCssOnly) {
            // postcss config 변경이 섞이면 changedPath 미지정 → 전체 재처리.
            const cssChanges = paths.filter(
              (p) => p.endsWith('.css') && !appDev.isPostcssConfig(p),
            );
            // 단일 non-module `.scss/.sass` 변경 → 그 파일만 재컴파일하고 outdir mirror
            // 후 CssUpdate broadcast (BACKLOG #71). full pipeline rebuild + cpSync 회피.
            if (paths.length === 1 && appDev.isSassOnlyChange(paths[0])) {
              const href = await appDev.rebuildScssIncremental(paths[0]);
              if (href) {
                hmr?.clearError();
                hmr?.broadcast({ type: HMR_MSG.CssUpdate, href, timestamp: Date.now() });
                if (opts.logLevel !== 'silent') console.error('[serve] sass updated');
              } else {
                await rebuildAppDevFull();
              }
            } else if (cssChanges.length === 1 && paths.length === 1) {
              await rebuildAppDevCss(cssChanges[0]);
            } else {
              await appDev.afterBundle();
              hmr?.clearError();
              hmr?.broadcast({ type: HMR_MSG.CssUpdate, timestamp: Date.now() });
              if (opts.logLevel !== 'silent') console.error('[serve] css updated');
            }
          } else {
            await rebuildAppDevFull(paths);
          }
        }
      } catch (err) {
        console.error('[serve] rebuild error:', err);
        hmr?.reportThrownError(err);
      } finally {
        rebuilding = false;
        if (dirty.size > 0) drain();
      }
    }

    const watchDirs = new Set();
    if (appDev) {
      watchDirs.add(appDev.root);
    } else {
      for (const entry of opts.entryPoints) {
        watchDirs.add(dirname(resolve(entry)));
      }
    }
    const restartTriggers = computeRestartTriggers(opts);
    for (const dir of restartTriggers.dirs) watchDirs.add(dir);

    for (const dir of watchDirs) {
      const watcher = fsWatch(dir, { recursive: true }, (_event, filename) => {
        if (!filename || filename.includes('node_modules') || filename.includes('.git')) return;
        const absPath = resolve(dir, filename);
        if (outdirAbs && (absPath === outdirAbs || absPath.startsWith(outdirPrefix))) return;
        if (restartTriggers.matches(filename)) {
          void emitRestartAfter(opts, 'config 또는 .env 파일 변경 감지', closeServerForRestart);
          return;
        }
        dirty.add(absPath);
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(drain, opts.watchDelay);
      });
      attachWatcherErrorHandler(watcher, dir, opts.logLevel);
    }
  }

  // open browser
  if (opts.open) {
    const url = `${protocol}://${opts.host === '0.0.0.0' ? 'localhost' : opts.host}:${opts.port}`;
    const { exec } = await import('node:child_process');
    const cmd =
      process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'start' : 'xdg-open';
    exec(`${cmd} ${url}`);
  }
}

// ─── Build dispatch ───

async function runTest262(opts) {
  const dir = opts.test262;
  if (!dir) throw new Error('--test262 requires a directory path');
  const { spawnSync } = await import('node:child_process');
  const result = spawnSync('zig', ['build', 'test262-run', '--', resolve(dir)], {
    cwd: resolve(dirname(fileURLToPath(import.meta.url)), '../../..'),
    stdio: 'inherit',
  });
  if (result.error) {
    throw new Error(`failed to run Test262 runner: ${result.error.message}`);
  }
  return { errors: result.status === 0 ? 0 : 1 };
}

/**
 * 단일/워크스페이스 흐름 공통 dispatch — 모드별 (`runServe`/`runWatch`/`runBundle`/`runTranspile`)
 * 진입점 호출 + bundle 의 user error 카운트 반환. caller (main / runWorkspace) 가 exit 처리.
 *
 * 반환 형태가 다른 두 호출 사이트의 drift 를 차단 — 모드 분기/추가가 1곳에서 끝남.
 */
async function dispatchBuild(opts, config, configEnv, dotenvVars) {
  if (opts.appCommand === 'build') {
    const result = await runAppBuild(opts, config, configEnv, dotenvVars);
    return { errors: result.errors.length };
  }
  if (opts.appCommand === 'dev') {
    if (opts.platform === 'react-native') {
      // #2605 — RN dev server 는 별도 lazy import. cli-server-api / dev-middleware
      // / RN runtime peer optional.
      await runRnDev(opts, config);
      return { errors: 0 };
    }
    await runAppDev(opts, config, configEnv, dotenvVars);
    return { errors: 0 };
  }
  if (opts.appCommand === 'preview') {
    await runAppPreview(opts);
    return { errors: 0 };
  }
  if (opts.serve) {
    printZntcBanner({
      flavor: 'web',
      version: getCliVersion(),
      silent: opts.logLevel === 'silent',
    });
    await runServe(opts, config);
    return { errors: 0 };
  }
  if (opts.watch) {
    await runWatch(opts, config);
    return { errors: 0 };
  }
  if (opts.bundle && opts.platform === 'react-native') {
    // #2540 PR #7 — RN platform 시 @zntc/react-native 의 preset 호출. lazy
    // import 라 web/transpile/bundle 일반 사용자 영향 0.
    const result = await runRnBundle(opts, config);
    return { errors: result.errors.length };
  }
  if (opts.bundle) {
    const result = await runBundle(opts, config);
    return { errors: result.errors.length };
  }
  await runTranspile(opts);
  return { errors: 0 };
}

// ─── Workspace mode (#2111) ───

/**
 * 단일 워크스페이스 entry 를 위한 `subOpts` 생성. `opts` deep clone → entry/root config
 * 머지 → entry.cwd 기준 path 정규화.
 *
 * `structuredClone` 사용 — `JSON.parse(JSON.stringify(opts))` 는 미래에 함수/Date/undefined
 * 필드가 추가되면 silent drop 위험.
 *
 * `outdir`/`outfile` 보강은 historical 잔재 — parseArgs default 가 과거 `null` 이라
 * `mergeConfigIntoOpts` 의 `=== undefined` 머지 조건을 우회 못 했었음. default 가 `undefined`
 * 가 된 후로는 mergeConfigIntoOpts 만으로 충분하지만 `== null` 은 둘 다 매치하므로 안전망으로 유지.
 */
function buildSubOpts(opts, w, merged) {
  const subOpts = structuredClone(opts);
  mergeConfigIntoOpts(subOpts, merged);

  if (subOpts.outdir == null && merged.outdir) subOpts.outdir = merged.outdir;
  if (subOpts.outfile == null && merged.outfile) subOpts.outfile = merged.outfile;

  subOpts.entryPoints = subOpts.entryPoints.map((p) => resolve(w.cwd, p));
  if (subOpts.outdir) subOpts.outdir = resolve(w.cwd, subOpts.outdir);
  if (subOpts.outfile) subOpts.outfile = resolve(w.cwd, subOpts.outfile);

  return subOpts;
}

/**
 * `zntc.workspace.{ts,...}` 가 발견되면 단일 build 대신 워크스페이스 fan-out 으로 전환.
 *
 * 흐름:
 *  1. workspace 파일 로드 → `identifyWorkspaceEntries` (config 로드 없는 식별 단계)
 *  2. `--workspace=<name>` 필터 즉시 적용 — 비싼 TS config 로드를 N-1 회 회피
 *  3. 필터 후 entries 의 config 를 `Promise.all` 로 병렬 로드
 *  4. root config (`zntc.config.*`) 가 같은 디렉토리에 있으면 모든 entry 가 상속
 *  5. 각 entry 마다: opts clone → entry config + root config 머지 → entry.cwd 기준 path 정규화 → build
 *
 * `serve`/`watch` 는 워크스페이스에서 의미가 모호 (어느 entry 를 watch?) — 다중 entry 시 reject.
 * `--workspace=<name>` 필터로 단일 entry 만 남기면 serve/watch 허용.
 */
async function runWorkspace(opts, workspacePath) {
  const command = opts.serve ? 'serve' : opts.watch ? 'watch' : 'bundle';
  const mode = opts.mode ?? (command === 'bundle' ? 'production' : 'development');
  const env = { command, mode, env: process.env };

  const rootDir = dirname(resolve(workspacePath));
  let entries;
  try {
    entries = await loadWorkspace(workspacePath, env);
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    throw new Error(`failed to load workspace — ${reason}`);
  }

  // 식별 단계 — config 로드 없이 cwd/name/source 만. 필터 후에만 실제 config 로드.
  const ids = identifyWorkspaceEntries(entries, rootDir);
  const filtered = filterWorkspaces(ids, opts.workspace);

  // 필터링된 entry 의 config 만 병렬 로드. root config 도 함께 await.
  const rootConfigPath = findConfigPath(rootDir);
  const [rootConfig, ...entryConfigs] = await Promise.all([
    rootConfigPath ? loadConfig(rootConfigPath, env) : Promise.resolve(null),
    ...filtered.map((w) => loadIdentifiedConfig(w, env)),
  ]);
  const resolved = filtered.map((w, i) => ({
    name: w.name,
    cwd: w.cwd,
    source: w.source,
    config: entryConfigs[i],
  }));

  if (resolved.length > 1 && (opts.serve || opts.watch)) {
    throw new Error(
      `workspace serve/watch requires --workspace=<name> filter (matched ${resolved.length} entries)`,
    );
  }

  if (opts.logLevel !== 'silent') {
    const filterMsg = opts.workspace ? ` (filtered by name='${opts.workspace}')` : '';
    console.error(
      `@zntc/core: workspace ${workspacePath} → ${resolved.length} entr${
        resolved.length === 1 ? 'y' : 'ies'
      }${filterMsg}`,
    );
  }

  let exitCode = 0;
  for (const w of resolved) {
    if (opts.logLevel !== 'silent') {
      console.error(`\n--- workspace: ${w.name} (cwd=${w.cwd}, source=${w.source}) ---`);
    }
    const merged = rootConfig ? mergeUserConfigs(rootConfig, w.config) : w.config;

    if (opts.logLevel !== 'silent' && Object.keys(w.config).length > 0) {
      warnUnknownKeys(w.config, KNOWN_CONFIG_KEYS, { sourceLabel: `workspace[${w.name}]` });
    }

    const subOpts = buildSubOpts(opts, w, merged);

    if (subOpts.entryPoints.length === 0 && !subOpts.stdin && !subOpts.serve) {
      if (opts.logLevel !== 'silent') {
        console.error(`@zntc/core: workspace '${w.name}' has no entryPoints — skipping`);
      }
      continue;
    }

    init();
    try {
      const r = await dispatchBuild(subOpts, merged, { mode }, {});
      if (r.errors > 0) exitCode = 1;
    } catch (err) {
      console.error(`error [workspace ${w.name}]: ${err.message}`);
      exitCode = 1;
    }
  }
  if (exitCode !== 0) process.exit(exitCode);
}

// ─── Main ───

async function main() {
  const opts = parseArgs(process.argv);

  if (opts.help) {
    printUsage(opts.appCommand);
    return;
  }

  if (opts.parseError) {
    printUsage(opts.appCommand, console.error);
    process.exit(1);
  }

  // --test262 는 zig 서브프로세스로 위임. config / NAPI dlopen 모두 불필요 — early dispatch.
  if (opts.test262 !== undefined) {
    if (!opts.test262) {
      printUsage(opts.appCommand, console.error);
      process.exit(1);
    }
    try {
      const r = await runTest262(opts);
      if (r.errors > 0) process.exit(1);
    } catch (err) {
      console.error(`error: ${err.message}`);
      process.exit(1);
    }
    return;
  }

  // RN dev/build 의 positional arg 는 entry point (파일) — web 처럼 appRoot (디렉토리)
  // 가 아니라서 그대로 두면 envDir 가 파일을 가리켜 `.env` 로딩에서 ENOTDIR 발생.
  // entry → entryPoints[0] 로 옮기고 그 dirname 을 appRoot 로 사용.
  if (
    (opts.appCommand === 'dev' || opts.appCommand === 'build') &&
    opts.platform === 'react-native' &&
    opts.appRoot
  ) {
    const entryArg = opts.appRoot;
    if (opts.entryPoints.length === 0) opts.entryPoints.push(entryArg);
    opts.appRoot = dirname(resolve(entryArg));
  }

  if ((opts.appCommand === 'dev' || opts.appCommand === 'build') && !opts.envDir) {
    opts.envDir = resolve(opts.appRoot ?? '.');
  }

  // workspace 자동 탐색 — `--workspace-config <path>` 명시 또는 cwd 의 zntc.workspace.*
  // 발견 시 워크스페이스 fan-out 모드로 분기. 나머지 단일 build 흐름은 우회.
  const workspacePath = opts.workspaceConfig
    ? resolve(opts.workspaceConfig)
    : findWorkspacePath(process.cwd());
  if (workspacePath) {
    applyServerDefaults(opts);
    if (opts.workspaceConfig && !existsSync(workspacePath)) {
      throw new Error(`failed to load workspace — file not found: ${workspacePath}`);
    }
    await runWorkspace(opts, workspacePath);
    return;
  }

  // config 자동 탐색 + .env 로드 + 머지 (CLI > config > tsconfig). entry 검사 전에
  // 적용해야 config 의 entryPoints 가 검사 통과에 기여한다.
  // init() 은 entry 검사 후로 미뤄 no-args 경로의 NAPI dlopen 비용을 절감한다.
  // (config 가 .ts 면 loadConfig 내부에서 init() 이 idempotent 하게 호출됨)
  const { config, env: configEnv, dotenvVars } = await loadAutoConfig(opts);
  if (config) {
    // unknown 키 검출 + Levenshtein "did you mean?" 제안 (#2109).
    // 머지 전에 검사 — 사용자 typo 가 silent 무시되지 않도록.
    if (opts.logLevel !== 'silent') {
      warnUnknownKeys(config, KNOWN_CONFIG_KEYS, { sourceLabel: 'zntc.config' });
    }
    mergeConfigIntoOpts(opts, config);
  }
  applyServerDefaults(opts);

  // import.meta.env.* + import.meta.env.MODE/PROD/DEV/SSR 정적 치환을 define 으로
  // 자동 주입. 사용자 명시 define 이 동일 키를 덮어쓰면 그대로 우선.
  const envDefine = envToDefine(
    dotenvVars,
    configEnv.mode,
    normalizeBase(opts.base ?? opts.publicPath ?? '/'),
  );
  for (const [key, value] of Object.entries(envDefine)) {
    if (opts.define[key] === undefined) opts.define[key] = value;
  }
  injectDefaultNodeEnvDefine(opts);

  if (opts.entryPoints.length === 0 && !opts.stdin && !opts.serve && !opts.appCommand) {
    printUsage(undefined, console.error);
    process.exit(1);
  }

  try {
    // raw tsconfig 입력 사전 검증 — NAPI 가 silent fallback 이라 invalid 라도 진입은 가능,
    // 사용자 디버깅 편의를 위해 여기서 명시 에러로 실패시킨다.
    validateTsConfigRaw(opts.tsconfigRaw);
    init();
    const r = await dispatchBuild(opts, config, configEnv, dotenvVars);
    if (r.errors > 0) process.exit(1);
  } catch (err) {
    console.error(`error: ${err.message}`);
    process.exit(1);
  }
}

main();
