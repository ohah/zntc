#!/usr/bin/env node

/**
 * ZNTC CLI — Node.js/Bun 호환 CLI
 *
 * 내부적으로 @zntc/core NAPI 바인딩을 사용하여 트랜스파일/번들링을 수행.
 * Watch/Serve는 JS 레이어에서 구현.
 */

import {
  mkdirSync,
  existsSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { resolve, dirname, basename, extname, join, sep } from 'node:path';
import { createServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

import {
  applyFlagAction,
  KNOWN_FLAGS,
  matchFlagFromRegistry,
  normalizeFallback,
} from './cli-flags.mjs';
import { copyRnAssets } from './rn-asset-copy.mjs';
import {
  buildRnBundleExtra,
  buildRnBundleOverride,
  buildRnDevServerInput,
} from './rn-dev-input.mjs';
import { applyColorPreference, printZntcBanner } from './banner.mjs';

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
  watch,
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
  if (command === 'verify') {
    return [
      'Usage: zntc verify <path-or-url> [options]',
      '',
      'Loads the target in a headless Chromium and reports pageerror,',
      'console.error, 4xx responses, and request failures. Exits non-zero',
      'on any captured event so CI can gate on real browser runtime errors.',
      '',
      'Options:',
      '  --verify-timeout <ms>          Page load timeout (default: 10000)',
      '  --verify-ignore <pattern>      Regex to skip matching console/url events (repeatable)',
      '  --verify-allow-console-error   console.error events do not affect exit code',
      '  --verify-json                  Emit machine-readable report on stdout',
      '  --verify-report <path>         Write JSON report to file',
      '  --help, -h                     Show this help message',
      '',
      'Requires Playwright (peer/optional):',
      '  npm install --save-dev playwright',
      '  npx playwright install chromium',
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
    '  --tree-shaking[=false]     Tree shaking (default: true; --no-tree-shaking to disable)',
    '  --scope-hoist[=false]      Scope hoisting (default: true; --no-scope-hoist to disable)',
    '  --emit-disk-sourcemap[=false] Write .map to disk in watch mode (default: true)',
    '  --fallback:SPEC=TARGET     Fallback resolution on failure (=false → empty module)',
    '  --block-list=<pattern>     Block module resolution by pattern (repeatable)',
    '  --min-chunk-size=<n>       Merge small common chunks below n bytes',
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
    '  --no-config                Skip config file discovery/loading (CLI flags only)',
    '  --color, --no-color        Force or disable colored output (honors NO_COLOR)',
    '  --version, -v              Print version and exit',
    '  --test262 <dir>            Run Zig Test262 runner via zig build test262-run',
    '  --help, -h                 Show this help message',
  ];
}

function printUsage(command, stream = console.log) {
  stream(usageLines(command).join('\n'));
}

function parseArgs(argv) {
  const args = argv.slice(2);
  const appCommands = new Set(['dev', 'build', 'preview', 'verify']);
  const appCommand = appCommands.has(args[0]) ? args.shift() : undefined;
  const opts = {
    appCommand,
    help: false,
    version: false,
    // config 자동 탐색·로드 우회 (--no-config). --config 명시보다 우선.
    // workspace 모드(--workspace)는 config 가 본질이라 미적용 (경고만).
    noConfig: false,
    // 색상 출력 강제(true)/억제(false). undefined = NO_COLOR/FORCE_COLOR + TTY 자동.
    color: undefined,
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
    // 엔진 기본값 true — `--no-*` / `--*=false` 또는 config false 로만 끈다.
    scopeHoist: true,
    emitDiskSourcemap: true,
    fallback: {},
    blockList: [],
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
    cssNames: undefined,
    jsx: undefined,
    jsxDev: false,
    jsxFactory: undefined,
    jsxFragment: undefined,
    jsxImportSource: undefined,
    // undefined 기본값이어야 RN dev server 의 자체 default(true)를 막지 않는다.
    // `--dev` / config.devMode=true 만 명시 opt-in 으로 BuildOptions devMode에 전달.
    devMode: undefined,
    flow: false,
    experimentalDecorators: false,
    useDefineForClassFields: true,
    keepNames: false,
    shimMissingExports: false,
    preserveSymlinks: false,
    resolveSymlinkSiblings: false,
    // canonical shape — BOOL_KEYS 머지 키. 이전 opts default 누락으로
    // config.disableHierarchicalLookup 가 silent 무시되던 pre-existing 버그
    // (깨진 double-quote 가드가 은폐, C4 fix 로 검출).
    disableHierarchicalLookup: false,
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
    minChunkSize: undefined,
    clean: false,
    allowOverwrite: false,
    preserveModules: false,
    preserveModulesRoot: undefined,
    inlineDynamicImports: undefined,
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
    // canonical opts shape — ARRAY_KEYS 머지 키는 default 에 존재해야
    // (drift-guard #2112). 미존재 시 lazy 초기화돼 머지 조건이 어긋남.
    globalIdentifiers: [],
    polyfills: [],
    runBeforeMain: [],
    watchFolders: [],
    watchInclude: [],
    watchExclude: [],
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
    // verify 모드 (`zntc verify <path-or-url>`) 전용 — FLAG_REGISTRY 가 다른 모드에서
    // 매칭해도 핸들러가 무시. verifyTarget 만 positional 로 채워진다.
    verifyTarget: undefined,
    verifyJson: false,
    verifyReport: undefined,
    verifyTimeout: undefined,
    verifyIgnore: [],
    verifyAllowConsoleError: false,
  };

  if (appCommand === 'dev') {
    opts.serve = true;
    opts.bundle = true;
    opts.watch = true;
    // #3793 — `zntc dev` 는 incremental HMR 활성 (__zntc_apply_update / __esm register
    // 주입) 이 필수. 명시 안 set 시 initial bundle 이 production 모드로 빌드돼 HMR
    // 런타임 누락 → broadcast 된 Update 가 client 에서 fallback reload. user 가
    // 명시적으로 `--dev=false` 줘서 override 하기 전엔 dev 모드 default 보장.
    opts.devMode = true;
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
      } else if (opts.appCommand === 'verify') {
        opts.verifyTarget = opts.verifyTarget ?? arg;
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

/**
 * BuildResult / NAPI diag 의 errors / warnings 를 stderr 로 출력.
 * `logLevel === 'silent'` 면 출력 안 함, `'error'` 면 errors 만.
 * `err.specifier` 는 NAPI 가 diag suggestion 으로 노출하는 import specifier.
 */
function printResultDiagnostics(result, logLevel) {
  if (result.errors.length > 0 && logLevel !== 'silent') {
    for (const err of result.errors) {
      const loc = err.location ? `${err.location.file}: ` : '';
      const detail = err.specifier ? ` (${err.specifier})` : '';
      console.error(`error: ${loc}${err.text}${detail}`);
    }
  }
  if (result.warnings.length > 0 && logLevel !== 'silent' && logLevel !== 'error') {
    for (const warn of result.warnings) {
      const detail = warn.specifier ? ` (${warn.specifier})` : '';
      console.error(`warning: ${warn.text}${detail}`);
    }
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

/**
 * RFC #3833 v3 D1a'' (caller-side pre-warm) helper — runAppBuild/runAppDev 가
 * 공유. 사용자 explicit `plugins: [css({postcss:{...}})]` 의 옵션을 추출해
 * prepare 단계의 `postcssOverride` 로 전달. buildAppSync 의 sync dispatcher ×
 * async cssOnLoad 충돌 회피 — Vite/esbuild 의 main thread pre-process → sync
 * bundle 패턴.
 *
 * 분기:
 *   1. disabled:true     → explicit PostCSS 끄기 (override={plugins:[]} 로
 *                          auto-discover 도 차단, prepare 가 length 0 skip)
 *   2. postcss 명시       → presence check, plugins ?? [] 정규화. options-only
 *                          override 도 explicit no-op (Vite inline override
 *                          시맨틱)
 *   3. 둘 다 없으면       → override=null → prepare 가 auto-discover path
 *
 * **findLast**: 미래 default `css()` prepend 와 user override 가 동시 존재 시
 * 마지막 등록이 winner (Vite plugins 순서 의미). sentinel `__cssOptions` 는
 * runtime 위장 방어 0 — 의도 매치용.
 *
 * @param {Array<{name?:string,__cssOptions?:object}>} plugins
 * @returns {{plugins: unknown[], options: Record<string,unknown> | undefined} | null}
 */
/**
 * sentinel `__cssOptions` 보유 css plugin 의 raw options 추출. 매치 안 되면 null.
 * extractCssPostcssOverride / extractCssAutoDiscoverRoot 의 공통 helper.
 */
function extractCssOptions(plugins) {
  const cssPlugin = plugins.findLast(
    // 두 항 모두 optional chain — predicate 순서 변경 시 null/undefined deref 회귀
    // 차단 (/code-review max #1 latent finding).
    (p) => p?.name === '@zntc/web/css' && p?.__cssOptions !== undefined,
  );
  return cssPlugin?.__cssOptions ?? null;
}

function extractCssPostcssOverride(plugins) {
  const opts = extractCssOptions(plugins);
  if (!opts) return null;
  if (opts.disabled === true) return { plugins: [], options: undefined };
  if (opts.postcss) {
    return {
      plugins: opts.postcss.plugins ?? [],
      options: opts.postcss.options,
      // issue #3851 — css({root}) 의 root 가 caller-pre-warm path 에서 silent
      // ignore 였던 회귀 fix. override path 의 postcss require base 로 routing.
      // mode 는 override.plugins 명시 시 loadPostcssConfig 미호출이라 무의미 —
      // routing 안 함 (사용자가 root 와 mode 둘 다 명시한 경우 mode 는 onLoad
      // 의 dispatcher path 에서만 의미 있었음, caller-pre-warm 에선 dead).
      root: opts.root,
    };
  }
  return null;
}

/**
 * issue #3857 — `css({root})` 단독 명시 (postcss override 없이) 시 root 가
 * auto-discover path 의 findPostcssConfig 시작 base 로 사용되게 caller 가 전달.
 * monorepo edge: postcss.config 가 monorepo root 에 있고 app 이 sub-package
 * 인 경우 사용자가 root='/monorepo-root' 명시.
 *
 * - opts.disabled 면 null (자동발견 차단은 disabled true 의 책임)
 * - opts.postcss truthy 면 null (override path 가 root 직접 routing)
 * - opts.root 만 있으면 그것 반환
 */
function extractCssAutoDiscoverRoot(plugins) {
  const opts = extractCssOptions(plugins);
  if (!opts || opts.disabled === true) return null;
  if (opts.postcss) return null;
  // /code-review max #3/#4: type/empty guard — non-string 또는 빈 string 거부.
  // findPostcssConfig(non-string) → TypeError, findPostcssConfig('') → cwd 기준
  // wrong-base search. 사용자 invalid 입력은 silent null (auto-discover skip).
  if (typeof opts.root !== 'string' || opts.root.length === 0) return null;
  return opts.root;
}

/**
 * RFC #3833 v3 D1a'' — caller-pre-warm sentinel (`__cssOptions !== undefined`)
 * 가진 css plugin 을 native dispatcher plugin chain 에서 제거.
 *
 * Caller paths:
 *   - **runAppBuild**: buildAppSync 의 sync dispatcher 가 async onLoad 받으면
 *     syncPluginPromiseFailure → BundleFailed. 본 helper 로 dispatch 차단.
 *   - **buildBundleOptions** (runBundle/watch/runServe): native async dispatcher
 *     가 onLoad 호출 → prepare 와 같은 PostCSS 두 번 실행 (double-pass). 본
 *     helper 로 dispatch 차단.
 *
 * **runAppDev 는 본 helper 미경유** — controller (createAppDevController) 에
 * postcssOverride 만 전달, plugin chain 자체는 runServe → buildBundleOptions
 * 경로에서 처리. 따라서 dev path 의 filter 는 buildBundleOptions 가 cover.
 *
 * extractCssPostcssOverride 와 동일 sentinel match 조건 (predicate 일관) —
 * drift 위험 차단.
 *
 * @param {Array<{name?:string,__cssOptions?:object}>} plugins
 * @returns {Array<unknown>} caller-pre-warm 활성 css plugin 제거된 새 array
 */
function dropCallerPreWarmedCssPlugin(plugins) {
  return plugins.filter((p) => !(p?.name === '@zntc/web/css' && p?.__cssOptions !== undefined));
}

async function runAppBuild(opts, config, configEnv, _dotenvVars) {
  // JS plugin 로드 — bundle pipeline 의 buildBundleOptions 와 동일 패턴. app
  // pipeline 도 plugin dispatcher 통과 (#2538 4-4 PR-1).
  const appPlugins = [];
  if (config && Array.isArray(config.plugins)) {
    appPlugins.push(...config.plugins);
  }
  for (const pluginPath of opts.pluginPaths) {
    const absPath = resolve(pluginPath);
    const cfg = await importAndResolveDefault(absPath);
    if (Array.isArray(cfg.plugins)) {
      appPlugins.push(...cfg.plugins);
    } else if (typeof cfg.setup === 'function') {
      appPlugins.push(cfg);
    }
  }
  const web = await loadWebModule();
  const root = resolve(opts.appRoot ?? '.');
  const outdir = resolve(opts.outdir ?? join(root, 'dist'));
  if (opts.clean) rmSync(outdir, { recursive: true, force: true });
  // RFC #3833 v3 D1a'' caller-side pre-warm — extractCssPostcssOverride helper 참조.
  const postcssOverride = extractCssPostcssOverride(appPlugins);
  // issue #3857 — css({root}) 단독 명시 시 findPostcssConfig search base
  // (monorepo edge: app 이 sub-package, postcss.config 가 monorepo root).
  const cssAutoDiscoverRoot = extractCssAutoDiscoverRoot(appPlugins);
  // dropCallerPreWarmedCssPlugin: sentinel 가진 css plugin 을 항상 dispatcher 에서
  // 제거 (buildBundleOptions 와 동일 무조건 적용). /code-review max #5: 조건부
  // (postcssOverride truthy 시만) 분기는 비대칭 — 사용자가 sentinel 만 가진
  // plugin (예: `__cssOptions:{someFutureKey}` — extract null) 등록 시
  // BundleFailed 회귀 가능. 무조건 drop 으로 future-key 안전 + 양쪽 path 일관.
  const dispatchPlugins = dropCallerPreWarmedCssPlugin(appPlugins);
  let pipelineRoot = null;
  try {
    const pipeline = await web.prepareAppCssPipelineRoot(
      root,
      outdir,
      configEnv,
      opts.logLevel,
      'build',
      { fallbackRequire: requireFromCli, cliNodeModules },
      { postcssOverride, cssAutoDiscoverRoot },
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
      jsx: opts.jsx,
      jsxImportSource: opts.jsxImportSource,
      jsxFactory: opts.jsxFactory,
      jsxFragment: opts.jsxFragment,
      compiler: config?.compiler,
      plugins: dispatchPlugins.length > 0 ? dispatchPlugins : undefined,
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
  // RFC #3833 v3 D1a'' Phase 2: build path 와 동일 plugin walk + helper 추출.
  const devUserPlugins = [];
  if (config && Array.isArray(config.plugins)) devUserPlugins.push(...config.plugins);
  for (const pluginPath of opts.pluginPaths) {
    const absPath = resolve(pluginPath);
    const cfg = await importAndResolveDefault(absPath);
    if (Array.isArray(cfg.plugins)) devUserPlugins.push(...cfg.plugins);
    else if (typeof cfg.setup === 'function') devUserPlugins.push(cfg);
  }
  const appDev = web.createAppDevController(
    {
      ...opts,
      postcssOverride: extractCssPostcssOverride(devUserPlugins),
      // issue #3857 — css({root}) 단독 명시 (postcss override 없이) 시 root 를
      // findPostcssConfig 의 search base 로 전달. monorepo 의 sub-package app
      // 이 monorepo root 의 postcss.config 참조하는 시나리오.
      cssAutoDiscoverRoot: extractCssAutoDiscoverRoot(devUserPlugins),
    },
    root,
    configEnv,
    { fallbackRequire: requireFromCli, cliNodeModules },
  );
  const prepared = await appDev.prepare();

  opts.entryPoints = [prepared.entryPath];
  opts.serveDir = opts.outdir;
  // issue #3858 — runServe 의 watchFolders 자동 set 위해 app root 를 stash.
  // opts.serveDir 은 outdir(`.zntc-dev`) 이라 사용자 source code root 가 아님 —
  // 별도 channel 필요.
  opts._appWatchRoot = root;
  // issue #3852 — runAppDev 가 collect 한 plugin 을 stash → runServe 의
  // buildBundleOptions 가 재import 안 함. ESM cache hit 라 시맨틱 회귀는 0 였지만
  // perf + cache invalidate edge 안전.
  opts._resolvedPlugins = devUserPlugins;

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
      // @zntc/web 의 module 평가가 dev-overlay-client.raw.js 를 readFileSync 한다
      // (#2538 4-3). dist 가 incomplete 한 경우 (build:bundle 의 copy 누락 / 일부만
      // 추출된 tarball) 가 ENOENT 로 throw — 친절 핸들 분기.
      if (code === 'ENOENT' && /dev-overlay-client\.raw\.js/.test(message)) {
        console.error('error: @zntc/web 의 dist/dev-overlay-client.raw.js 가 누락됐습니다.');
        console.error('');
        console.error(
          'help: `bun --cwd <repo>/packages/web run build` 로 재빌드하거나 @zntc/web 을 재설치하세요.',
        );
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
  applySingleFileDynamicImportDefault(opts);

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

  const extra = buildRnBundleExtra(cfg, opts);
  const result = await rn.bundleRn({
    entry,
    projectRoot,
    rnPlatform,
    dev: Boolean(opts.devMode),
    sourcemap: wantsSourcemap,
    minify:
      opts.minify || opts.minifyWhitespace || opts.minifyIdentifiers || opts.minifySyntax || false,
    dropConsole: opts.drop.includes('console'),
    dropDebugger: opts.drop.includes('debugger'),
    extra,
    override: buildRnBundleOverride({
      config: cfg,
      opts,
      override: outfile && !callerWrite ? { outfile, write: true } : undefined,
    }),
  });

  printResultDiagnostics(result, opts.logLevel);

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

  // production asset 복사 (`--assets-dest`) — dev=false + 명시 시. Metro 처럼
  // bundle 에 등록된 AssetRegistry asset 만 복사한다. 미지정 시 skip (dev server 가 HTTP 서빙).
  if (result.errors.length === 0 && !opts.devMode && opts.assetsDest) {
    const assetsDestAbs = resolve(opts.assetsDest);
    try {
      const copied = await copyRnAssets({
        assetsDest: assetsDestAbs,
        rnPlatform,
        assets: result.rnAssetMetadata ?? [],
      });
      if (opts.logLevel !== 'silent') {
        console.error(`[bundle] copied ${copied} asset(s) to ${assetsDestAbs}`);
      }
    } catch (err) {
      process.stderr.write(`[zntc:rn-bundle] asset copy 실패: ${err?.message ?? err}\n`);
      throw err;
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
  // --no-config: 명시(--config)·자동 탐색 모두 우회. env(.env/define)는 config 와
  // 독립이므로 계속 로드해 `{ config: null }` 만 반환.
  const noConfig = opts.noConfig === true;
  const explicit = !noConfig && opts.configPath ? resolve(opts.configPath) : null;
  if (explicit && !existsSync(explicit)) {
    throw new Error(`failed to load config — file not found: ${explicit}`);
  }
  const configSearchDir = getAutoConfigSearchDir(opts);
  const configPath = noConfig ? null : (explicit ?? findConfigPath(configSearchDir));

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
  const modeConfigPath = noConfig || explicit ? null : findModeConfigPath(configSearchDir, mode);

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
 * 키 5그룹은 손-유지(머지 분류가 FLAG_REGISTRY kind/TS type 어디에도 기계적
 * 으로 없는 큐레이션 정책이라 순수 파생 불가 — 2회 실측 회귀로 확인). 대신
 * `zntc-cli-schema-sync.test.ts` 가 drift-guard: config-mergeable BuildOption
 * flag 가 여기 누락되면 CI 가 loud fail (이전 silent-무시 footgun 해소).
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
    'cssNames',
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
    'minChunkSize',
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

  // boolean default=false/undefined → config 가 true 면 적용. CLI 명시 false 를
  // 구분 못 하므로 함수형 config (#2103) 에서 정밀한 우선순위 적용 예정.
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
    'resolveSymlinkSiblings',
    'disableHierarchicalLookup',
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
    // drift-guard 가 검출한 silent-무시 버그 수정 (#2112 잔여): config 값이
    // 머지 안 되던 실 BuildOption bool.
    'analyze',
    'devMode',
  ];
  for (const key of BOOL_KEYS) {
    if ((opts[key] === false || opts[key] === undefined) && config[key] === true) {
      opts[key] = true;
    }
  }
  // default=true 옵션: CLI 가 default(true) 면 config=false 일 때만 false 로 내린다
  // (개별 키는 아래 배열 — 추가 시 여기만 갱신).
  for (const key of [
    'sourcesContent',
    'treeShaking',
    'scopeHoist',
    'emitDiskSourcemap',
    'useDefineForClassFields',
  ]) {
    if (opts[key] === true && config[key] === false) {
      opts[key] = false;
    }
  }

  // tristate bool: false 가 명시적 의미를 가져서 default 를 undefined 로 두는 키.
  // CLI 가 미지정(undefined)일 때만 config 값(true/false)을 채택한다 (CLI flag 우선).
  // inlineDynamicImports=false 의 single-file 보정은 applySingleFileDynamicImportDefault.
  for (const key of ['inlineDynamicImports']) {
    if (opts[key] === undefined && config[key] !== undefined) {
      opts[key] = config[key];
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
    'blockList',
    // drift-guard 검출 silent-무시 버그 수정 (#2112 잔여): 실 BuildOption array.
    'globalIdentifiers',
    'polyfills',
    'runBeforeMain',
    'watchFolders',
    'watchInclude',
    'watchExclude',
  ];
  for (const key of ARRAY_KEYS) {
    // opts[key] 미초기화([]가 아님) 가능 → 방어 (config 만 있으면 채택).
    if (
      Array.isArray(config[key]) &&
      config[key].length > 0 &&
      (!Array.isArray(opts[key]) || opts[key].length === 0)
    ) {
      opts[key] = [...config[key]];
    }
  }

  for (const key of ['define', 'alias', 'loader', 'globals', 'fallback']) {
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

/**
 * `runBundle` / `startBundleWatch` 가 공유하는 NAPI BuildOptions 생성 helper.
 * plugins 머지 + applySingleFileDynamicImportDefault + 옵션 매핑을 한 곳에 모아
 * runBundle (single-shot) 와 watch (incremental HMR, #3779) 의 옵션 drift 차단.
 */
async function buildBundleOptions(opts, config, { filterCallerPreWarmCss = false } = {}) {
  // issue #3852 — caller (runAppDev) 가 이미 plugin walk 했으면 `_resolvedPlugins`
  // 로 stash → 재import skip. ESM cache hit 이라 시맨틱 회귀 없지만 perf +
  // cache invalidate edge 안전.
  let plugins;
  if (Array.isArray(opts._resolvedPlugins)) {
    plugins = [...opts._resolvedPlugins];
  } else {
    plugins = [];
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
  }
  // RFC #3833 v3 D1a'' caller-side pre-warm — dropCallerPreWarmedCssPlugin helper
  // 로 sentinel 가진 css plugin 을 dispatcher chain 에서 제거. **app caller
  // (runServe with appDev) 만 적용** — bundle/transpile 모드 사용자가 css()
  // 명시한 경우 무조건 drop 하면 PostCSS 효과 0 silent regression (review #2).
  // app 모드만 caller-pre-warm 로 prepare 가 처리하므로 dispatcher dispatch 차단
  // 필요, bundle 모드는 native async dispatcher 가 onLoad 호출 (단 caller-pre-warm
  // 없어 PostCSS 적용 안 되지만 사용자 의도 그대로 dispatcher 에 전달).
  const dispatchPlugins = filterCallerPreWarmCss ? dropCallerPreWarmedCssPlugin(plugins) : plugins;

  applySingleFileDynamicImportDefault(opts);

  return {
    entryPoints: opts.entryPoints.map((e) => resolve(e)),
    // #3795/#3796 — watch handle 이 outdir 알아야 worker thread 의 createFile 가 정확한 위치에
    // 출력. `prepareNapiOptions` 가 build/buildSync 케이스에서 outdir 를 delete 하지만 watch()
    // wrapper (index.ts:3358) 가 명시 outdir 받아 NAPI 로 restore. 그러므로 BuildOptions 의
    // outdir/outfile 필드 자체는 enrich 해서 보내야 함.
    outdir: opts.outdir,
    outfile: opts.outfile,
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
    scopeHoist: opts.scopeHoist,
    emitDiskSourcemap: opts.emitDiskSourcemap,
    fallback: normalizeFallback(opts.fallback),
    blockList: opts.blockList.length > 0 ? opts.blockList : undefined,
    minChunkSize: opts.minChunkSize,
    metafile: !!opts.metafile,
    keepNames: opts.keepNames,
    shimMissingExports: opts.shimMissingExports,
    preserveSymlinks: opts.preserveSymlinks,
    resolveSymlinkSiblings: opts.resolveSymlinkSiblings,
    disableHierarchicalLookup: opts.disableHierarchicalLookup,
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
    cssNames: opts.cssNames,
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
    plugins: dispatchPlugins.length > 0 ? dispatchPlugins : undefined,
    // compiler.styledComponents / compiler.emotion 도 bundle 모드에서 forward.
    // 누락 시 `zntc.config.json` 의 `compiler` 설정이 silently drop 돼 1st-party transform
    // (autoLabel 등) 이 활성화 안 됨.
    compiler: config?.compiler,
    // PR-plumb (#3318): zntc.config 의 `mf`(Module Federation) 를 NAPI 로
    // forward. 누락 시 `mf` 가 silently drop → 발행 패키지에서 MF 미동작
    // (native CLI 만 zntc.config.json mf 를 직접 읽어 동작했던 갭).
    mf: config?.mf,
  };
}

async function runBundle(opts, config) {
  const buildOpts = await buildBundleOptions(opts, config);
  const hasPlugins = Array.isArray(buildOpts.plugins) && buildOpts.plugins.length > 0;
  const result = hasPlugins ? await build(buildOpts) : buildSync(buildOpts);

  printResultDiagnostics(result, opts.logLevel);

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

function applySingleFileDynamicImportDefault(opts) {
  if (opts.splitting || opts.preserveModules) return;
  if (opts.inlineDynamicImports === false) {
    throw new Error(
      'inlineDynamicImports=false requires splitting or preserveModules in bundle mode',
    );
  }
  // Zig CLI 와 동일한 기본값: 단일 파일 번들은 dynamic import target 을 같은 파일에
  // 인라인해야 Hermes/Node 가 외부 chunk 없는 native import() 를 실행하지 않는다.
  opts.inlineDynamicImports = true;
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

  // --no-config 면 config 를 안 읽으므로 그 변경도 restart trigger 아님.
  const noConfig = opts.noConfig === true;
  const explicitConfig = !noConfig && opts.configPath ? resolve(opts.configPath) : null;
  const autoConfig = noConfig ? null : (explicitConfig ?? findConfigPath(configSearchDir));
  if (autoConfig) dirs.add(dirname(autoConfig));

  const mode = opts.mode ?? (opts.serve || opts.watch ? 'development' : 'production');
  // mode-specific config (`zntc.config.${mode}.{ext}`) 변경도 restart trigger (#2110).
  const modeConfig = noConfig || explicitConfig ? null : findModeConfigPath(configSearchDir, mode);
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

/**
 * #3858 — raw root .css 의 diff 기반 reconcile. 이전 scan 결과와 비교해
 * **사라진 path** 만 outdir 에서 unlink. 이전 design (raw vs outdir set diff)
 * 은 outdir 의 bundler/sass/css-modules 가 emit 한 transient file (chunk.css,
 * Button.module.zntc.css 등) 을 stale 오판 → unlink 회귀 (/code-review max #4/#5).
 *
 * caller 가 closure 로 prevRawSet 보관 — 매 cycle current scan + diff:
 *   - removed = prev ∖ current → outdir 의 동일 rel path unlink
 *   - prev := current
 *
 * .scss/.sass 는 sass pipeline 이 별도 outdir 에 emit, raw root 의 .scss 자체
 * 삭제 시 sass 산출물도 dev_controller 가 cleanup. reconcile 은 plain raw .css
 * 만 cover (사용자가 직접 만든 .css 파일).
 *
 * cost: O(raw .css count) walk per rebuild — 일반적 small (dozens).
 */
function createReconcileOutdirCss(rawRoot, outdir) {
  let prevRawSet = new Set();

  function scanRawCss() {
    const set = new Set();
    function walk(dir, relBase) {
      let entries;
      try {
        entries = readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of entries) {
        if (e.name === 'node_modules' || e.name === '.git') continue;
        if (e.name.startsWith('.zntc-')) continue;
        const rel = relBase ? `${relBase}/${e.name}` : e.name;
        if (e.isDirectory()) walk(join(dir, e.name), rel);
        else if (e.isFile() && e.name.endsWith('.css')) set.add(rel);
      }
    }
    walk(rawRoot, '');
    return set;
  }

  // 첫 호출 시 prev 를 현재 raw scan 으로 초기화 — 첫 reconcile cycle 에서
  // 모든 outdir .css 가 stale 로 오판되는 것 회피.
  prevRawSet = scanRawCss();

  return function reconcile() {
    const current = scanRawCss();
    for (const rel of prevRawSet) {
      if (current.has(rel)) continue;
      const target = join(outdir, rel);
      try {
        unlinkSync(target);
      } catch {
        // best-effort — file 이 없거나 race
      }
    }
    prevRawSet = current;
  };
}

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
  // #3779 follow-up — restart 시 stop 호출용. opts.bundle+watch+appDev+hmr 분기 안에서만 할당.
  let nativeWatchHandle = null;
  // #4062 PR-B-2 — JS dev 서버 lazy on-demand 라우트(env ZNTC_LAZY=1 게이트, 실험적).
  // D105 접근1: native lazy 프리미티브(#4069/#4070, watch lazySeeds + build lazyForceParse)
  // 위에 JS 서버가 얇게 on-demand 라우팅을 얹는다. lazy 동적 청크는 emit-skip 되므로
  // (디스크에 없음) 브라우저가 `/<stem>-<8hex>.js` 를 요청하면 그 seed 만 force-parse 한
  // 단발 build() 로 즉석 생성·캐시해서 서빙한다. 게이트 OFF 면 아래 상태/분기 전부 무시 → 0 영향.
  const lazyMode = process.env.ZNTC_LAZY === '1';
  // pathHash(8 hex) → seed 절대경로. watch onReady/onRebuild 의 event.lazySeeds 로 갱신.
  const lazySeedMap = new Map();
  // pathHash → { body, type }. on-demand 빌드 결과 캐시. rebuild 마다 무효화(seed 본문 변경 가능).
  const lazyChunkCache = new Map();
  // pathHash → in-flight build Promise. 같은 청크 동시 요청을 coalesce(중복 build 회피).
  const lazyInflight = new Map();
  // on-demand build() 직렬화 tail. 페이지 로드 시 여러 lazy 청크가 동시 요청돼도 native build()
  // 를 한 번에 하나씩만 돌려 watch worker 와의 동시 재진입 위험을 없앤다(/code-review Q2).
  let lazyBuildTail = Promise.resolve();
  // #4062 PR-C-2 — 캐시 세대(epoch). rebuild(captureLazyState)가 캐시를 무효화할 때마다 +1.
  // on-demand build 가 시작 시 epoch 를 캡처하고 완료 후 비교해, 빌드 도중 rebuild 가 끼면
  // (epoch 변동) 그 결과를 캐시에 넣지 않는다(옛 소스로 만든 stale 바이트가 비워진 캐시를
  // 재오염하는 것을 막음 — native LazyState.epoch PR-4-iii 패턴 이식).
  let lazyEpoch = 0;
  // lazy entry 청크의 디스크 경로(`<entrystem>.js`). served index.html 은 prepareDev 가 non-split
  // 으로 `/bundle.js` 를 참조하게 rewrite 했지만, watch lazy 빌드의 entry 청크는 stem 이름이라
  // mismatch → `/bundle.js` 를 이 파일로 alias.
  let lazyEntryFile = null;
  // on-demand 단발 build() 옵션 템플릿(watchBuildOpts 와 동일 lazy 설정, callback/outdir 제거).
  let lazyOnDemandOpts = null;
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

  // #3796/#3798 root-cause — cold-start 시 runBundle 호출 제거. native watch 가 initial
  // 빌드 + outdir 출력 + appDev hooks 전부 담당. plugin.setup() 1회만 invoke (cold-start
  // 시점). race 회피는 HTTP server listen 을 watch.onReady 까지 wait — `napi_tsfn_blocking`
  // 모드라 worker 가 outdir 출력 완료 후 ready_event firing, JS callback 안에서 markWatchReady.
  if (opts.bundle && opts.entryPoints.length > 0) {
    opts.outdir = opts.outdir || join(opts.serveDir, '.zntc-serve');
    if (!opts.watch) {
      opts.watch = true;
    }
  }

  // #3796 — watch.onReady 까지 HTTP listen 이 wait 할 수 있게 promise. appDev + hmr 모드만
  // 의미 — 그 외 모드는 markWatchReady 즉시 호출 → promise 가 처음부터 resolved.
  let watchReadyResolve;
  const watchReadyPromise = new Promise((r) => {
    watchReadyResolve = r;
  });
  let watchReadyResolved = false;
  const markWatchReady = () => {
    if (!watchReadyResolved) {
      watchReadyResolved = true;
      watchReadyResolve();
    }
  };
  if (!(opts.bundle && opts.watch && appDev && hmr)) markWatchReady();

  const serveDir = resolve(opts.outdir || opts.serveDir);
  const base = normalizeBase(opts.base ?? '/');

  // #3799 — HMR Update modules 의 sourceMappingURL 이 가리키는 lazy sourcemap endpoint.
  // dev_overlay_client.js 의 __zntc_apply_update 가 eval 한 module code 끝의 주석을 DevTools
  // 가 fetch 함. RN bridge 의 `/__zntc_hmr_map/<id>` 와 동일 path.
  const HMR_MAP_PATH = '/__zntc_hmr_map/';

  function handleRequest(reqUrl, accept = '') {
    let pathname = new URL(reqUrl, 'http://localhost').pathname;
    if (appDev && pathname === APP_DEV_HMR_CLIENT_PATH) {
      return {
        status: 200,
        body: APP_DEV_HMR_CLIENT,
        type: 'application/javascript',
      };
    }
    // #3799 — HMR module 별 sourcemap. nativeWatchHandle 이 lazy cache 한 V3 JSON 을
    // moduleId 로 조회. handle 가 stop 됐거나 module 미수집 시 null → 404. 사용자
    // app 의 routing 우선순위 (base prefix 처리) 보다 앞에 위치 — `__zntc_hmr_map/`
    // 는 internal prefix 라 base 영향 무관.
    if (appDev && pathname.startsWith(HMR_MAP_PATH) && nativeWatchHandle) {
      const moduleId = decodeURIComponent(pathname.slice(HMR_MAP_PATH.length));
      try {
        const sm = nativeWatchHandle.getHmrSourceMap(moduleId);
        if (sm) {
          return { status: 200, body: sm, type: 'application/json' };
        }
      } catch {
        // handle stop 또는 unwrap 실패 — 404
      }
      return { status: 404, body: 'Not Found', type: 'text/plain' };
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

  // #4062 PR-B-2 — lazy 상태 갱신. watch onReady/onRebuild event 의 lazySeeds 로 pathHash→seed
  // 맵을 다시 채우고, entry 청크 파일을 식별하고, 캐시를 무효화한다(seed 본문 변경 가능).
  // event.outputs 는 디스크 경로 목록. entry 청크 = entry stem(`<name>.js`)과 basename 이 일치하는
  // 출력(splitting 의 entry 청크 네이밍). dev 모드는 content-hash off 라 stem 그대로.
  function captureLazyState(event) {
    // 실패한 rebuild(event.success===false)는 무시 — 직전 성공 빌드의 seed/cache 를 유지한다
    // (clear 하면 다음 요청이 또 실패할 빌드를 돌려 last-good 청크를 잃는다). onReady event 는
    // success 필드가 없어(undefined) 통과한다.
    if (!lazyMode || !event || event.success === false) return;
    // 캐시는 매 성공 rebuild 마다 무효화(편집으로 seed 본문 변경 가능) + epoch 증가
    // (진행 중 on-demand build 가 이 무효화를 넘겨 stale 바이트를 재캐시하지 못하게).
    lazyChunkCache.clear();
    lazyEpoch++;
    // seed 맵은 event.lazySeeds 가 *실제로 올 때만* 교체한다. 일반 편집(동적 import 를 가진
    // 모듈이 cache-hit)은 native 가 graph.lazy_seeds 를 다시 안 쌓아 lazySeeds 가 undefined 로
    // 온다 — 무조건 clear 하면 직전 유효 맵을 날려(PR-B-2 보다 나쁨) on-demand 라우트가 죽는다.
    // 새 seed 집합(동적 import 추가/제거 = importer 재파싱)일 때만 clear+repopulate.
    // (lazyEntryFile 의 `if (entry)` 보존과 같은 원리.)
    if (Array.isArray(event.lazySeeds)) {
      lazySeedMap.clear();
      for (const s of event.lazySeeds) {
        if (s && typeof s.pathHash === 'string' && typeof s.path === 'string') {
          lazySeedMap.set(s.pathHash, s.path);
        }
      }
    }
    const entryStem = basename(opts.entryPoints[0] ?? '', extname(opts.entryPoints[0] ?? ''));
    // event.outputs 는 outdir 기준 bare 파일명("main.js") — serveDir 로 절대화한다(이미 절대면 그대로).
    const outputs = (Array.isArray(event.outputs) ? event.outputs : [])
      .filter((p) => typeof p === 'string')
      .map((p) => resolve(serveDir, p));
    let entry = outputs.find((p) => basename(p, '.js') === entryStem) ?? null;
    // fallback: entry stem 매칭 실패 시 `__zntc_load_chunk` 를 포함한 .js 출력(동적 import 보유 청크).
    if (!entry) {
      for (const p of outputs) {
        if (!p.endsWith('.js')) continue;
        try {
          if (readFileSync(p, 'utf8').includes('__zntc_load_chunk(')) {
            entry = p;
            break;
          }
        } catch {
          // 읽기 실패 — skip
        }
      }
    }
    // dev rebuild 는 skip_bundle_output 라 event.outputs 가 비어있을 수 있다(#3796). entry 를
    // 못 찾았으면 직전 값을 유지(entry 청크 파일명은 stem 고정이라 안정 — 매 요청 readFileSync 라
    // 내용은 자동 fresh). 찾았을 때만 갱신.
    if (entry) lazyEntryFile = entry;
  }

  // #4062 PR-B-2 — lazy on-demand 라우트. 반환 null = lazy 라우트가 처리 안 함(기존 handleRequest 로).
  //   ① `/bundle.js` (served index.html 이 참조) → lazy entry 청크 alias.
  //   ② `/<stem>-<8hex>.js` → seed 역참조 후 그 seed 만 force-parse 한 단발 build() 로 동적 청크 생성.
  async function tryServeLazy(reqUrl) {
    if (!lazyMode) return null;
    let pathname = new URL(reqUrl, 'http://localhost').pathname;
    if (base && base !== '/' && pathname.startsWith(base)) {
      pathname = '/' + pathname.slice(base.length);
    }
    // ① entry alias — served index.html 의 `/bundle.js` 를 lazy entry 청크로.
    if ((pathname === '/bundle.js' || pathname === '/index.js') && lazyEntryFile) {
      try {
        return {
          status: 200,
          body: readFileSync(lazyEntryFile),
          type: 'application/javascript',
        };
      } catch {
        return null; // 파일 사라짐 — 정적 fallback
      }
    }
    // ② on-demand 동적 청크.
    const m = pathname.match(/-([0-9a-f]{8})\.js$/);
    if (!m) return null;
    const pathHash = m[1];
    const seedPath = lazySeedMap.get(pathHash);
    if (!seedPath) return null; // 알 수 없는 hash — 정적 자산일 수 있어 fallback
    const cached = lazyChunkCache.get(pathHash);
    if (cached) return cached;
    if (!lazyOnDemandOpts) return null;
    // 같은 청크 동시 요청은 진행 중 build 를 공유(coalesce).
    const existing = lazyInflight.get(pathHash);
    if (existing) return existing;
    // tail 에 체인 → on-demand build 들을 직렬화(동시 native build()+watch worker 재진입 회피).
    const job = lazyBuildTail.then(async () => {
      // 큐 대기 중 cache 가 채워졌으면(다른 동일 요청이 먼저 완료) 그대로 재사용.
      const c = lazyChunkCache.get(pathHash);
      if (c) return c;
      // build 시작 직전 세대 캡처 — 완료 후 변동(=빌드 도중 rebuild) 시 캐시 오염 방지.
      const epoch = lazyEpoch;
      try {
        const r = await build({ ...lazyOnDemandOpts, lazyForceParse: [seedPath] });
        if (r.errors && r.errors.length > 0) return null;
        // seed 모듈을 포함한 청크를 moduleIds 로 찾는다(force-parse 라 그 seed 가 어느 청크에 인라인됨).
        const chunk = (r.outputFiles ?? []).find(
          (f) => Array.isArray(f.moduleIds) && f.moduleIds.includes(seedPath),
        );
        if (!chunk) return null;
        const result = {
          status: 200,
          body: chunk.contents,
          type: 'application/javascript',
        };
        // 빌드 도중 rebuild 가 끼지 않았을 때만 캐시(epoch 불변). 끼었으면 이 결과는 옛 소스
        // 기반이라 캐시하지 않고(다음 요청이 fresh 재빌드) 이번 응답으로만 반환.
        if (lazyEpoch === epoch) lazyChunkCache.set(pathHash, result);
        return result;
      } catch (err) {
        console.error('[serve] lazy chunk build failed:', err);
        return null;
      }
    });
    lazyBuildTail = job.catch(() => {}); // tail 은 reject 흡수(다음 build 가 멈추지 않게).
    lazyInflight.set(pathHash, job);
    try {
      return await job;
    } finally {
      lazyInflight.delete(pathHash);
    }
  }

  const useTls = opts.certfile && opts.keyfile;

  // #3796/#3798 root-cause — watch handle 을 HTTP listen 전에 띄움. cold-start runBundle 제거
  // 후 watch worker 가 outdir 출력 + appDev hooks 담당. HTTP listen 은 watchReadyPromise 까지
  // wait → server listen 시점에 outdir 채워진 상태 (race-free).
  if (opts.bundle && opts.watch && appDev && hmr) {
    // app dev path (appDev 활성) — caller-pre-warm 으로 prepare 가 처리한
    // css plugin 을 dispatcher 에서 제거 필요. bundle 모드 (appDev=null) 는
    // filter false (사용자 명시 css() 가 dispatcher 에 정상 전달).
    const watchBuildOpts = await buildBundleOptions(opts, config, {
      filterCallerPreWarmCss: true,
    });
    watchBuildOpts.devMode = true;
    // #4062 PR-B-2 — lazy on-demand 활성화. lazy 동적 청크는 (a) code splitting 으로 분리되고
    // (b) IIFE registry(`__zntc_require`/`__zntc_load_chunk`) 로 로드되어야 한다. dev 단일파일
    // 기본(applySingleFileDynamicImportDefault 가 splitting 미설정 시 inlineDynamicImports=true)
    // 을 명시적으로 끄고 splitting+iife 를 강제한다. on-demand 단발 build() 템플릿도 동일 설정으로
    // 준비(watch callback/outdir 제거 — build() 는 outdir 없으면 in-memory outputFiles 반환).
    if (lazyMode) {
      watchBuildOpts.splitting = true;
      watchBuildOpts.inlineDynamicImports = false;
      watchBuildOpts.lazyCompilation = true;
      watchBuildOpts.format = 'iife';
      lazyOnDemandOpts = {
        ...watchBuildOpts,
        splitting: true,
        inlineDynamicImports: false,
        lazyCompilation: true,
        format: 'iife',
      };
      delete lazyOnDemandOpts.onReady;
      delete lazyOnDemandOpts.onRebuild;
      // outdir/outfile 둘 다 제거 → build() 가 write skip(in-memory outputFiles)해 watch 의
      // 디스크 출력을 매 요청마다 clobber 하지 않게 한다(/code-review: outfile 누락 footgun).
      delete lazyOnDemandOpts.outdir;
      delete lazyOnDemandOpts.outfile;
      delete lazyOnDemandOpts.watch;
    }
    // issue #3858 — appDev path 에서 watchFolders 자동 = app root. 사용자가 직접
    // .css 파일을 import 없이 만들었을 때 (graph 외) 신규 file 의 add 감지를
    // native watcher (TrackedFileSet 의 dir-watch) 가 처리하도록 root_dir 등록.
    // opts._appWatchRoot 는 runAppDev 가 stash 한 사용자 source code root (outdir
    // 아닌 진짜 src/ 컨테이너). 사용자 명시 watchFolders 가 있으면 union — 우선순위 유지.
    let reconcileOutdir = null;
    if (opts._appWatchRoot) {
      const autoWatchRoot = resolve(opts._appWatchRoot);
      const existing = Array.isArray(watchBuildOpts.watchFolders)
        ? watchBuildOpts.watchFolders
        : [];
      if (!existing.includes(autoWatchRoot)) {
        watchBuildOpts.watchFolders = [...existing, autoWatchRoot];
      }
      // issue #3858 — reconcileOutdir factory 생성 (closure 가 prev/current raw
      // .css set 추적). onRebuild 마다 호출 — sass/.module/.chunk emit 영향 0.
      if (opts.outdir) {
        reconcileOutdir = createReconcileOutdirCss(autoWatchRoot, resolve(opts.outdir));
      }
    }
    watchBuildOpts.onReady = async (event) => {
      try {
        // #3799 root-cause — initial build 의 diagnostics 의 error 도 reportError.
        if (event && event.errors && event.errors.length > 0) {
          hmr.reportError(
            event.errors.map((e) => ({ text: e.message, location: { file: e.file } })),
          );
        } else {
          hmr.clearError();
        }
        captureLazyState(event); // #4062 — lazySeed 맵 + entry 청크 식별 (lazyMode 아니면 no-op)
        // #3796 — event.outputs (path 목록) 를 BundleResult shape 으로 변환해 injectBundleCssLinks.
        const mockResult = {
          outputFiles: (event && event.outputs ? event.outputs : []).map((p) => ({ path: p })),
        };
        appDev.injectBundleCssLinks(mockResult);
        await appDev.afterBundle();
      } catch (err) {
        console.error('[serve] initial appDev hooks failed:', err);
      } finally {
        markWatchReady();
      }
    };
    watchBuildOpts.onRebuild = (event) => {
      // dev_mode + collect_module_codes 인 incremental rebuild 는 skip_bundle_output 자동
      // 활성이라 outdir 갱신 안 함. graphChanged 시 추가 runBundle 호출 (plugin.setup 2회
      // 시점 — cold-start 는 watch 1회만).
      void (async () => {
        try {
          // #4062 PR-C-1 — rebuild 마다 lazy 상태 갱신: seed 맵을 event.lazySeeds 로 다시 채우고
          // (신규 동적 import 추가/제거 반영) 청크 캐시를 무효화한다. captureLazyState 가 실패한
          // rebuild 는 skip, outputs 가 비면(skip_bundle_output) entry 는 유지한다. (PR-B-2 는
          // onRebuild 가 lazySeeds 미노출이라 cache.clear 만 했음 — PR-C-1 에서 native 가 노출.)
          captureLazyState(event);
          // issue #3858 — native onRebuild 의 cssChanges 분기는 PR #3859 머지로
          // 도입됐으나, drain (fs.watch) 가 이미 같은 fs event 받아 rebuildAppDevCss
          // (syncDirty + afterBundle, PostCSS incremental) 로 처리. dual watch race
          // 의 source 였음 + prepare 호출이 PostCSS 를 tempRoot 전체 reprocess →
          // "processed N" 회귀 (dev-hmr/postcss test fail). drain 단일 처리로 통합.
          // graph 외 .css ADD case (#3858 핵심) 는 drain 의 fs.watch (recursive)
          // 가 신규 add event 받아 처리 — native 의 cssChanges 분기 redundant.
          // 단 graphChanged 시 outdir 갱신은 아래 runBundle 분기가 cover.
          // issue #3858 — 매 rebuild 마다 outdir reconcile (raw root .css diff
          // 후 사라진 path 만 outdir unlink). closure factory 의 prev/current
          // diff 로 outdir 의 sass/.module/.chunk emit 영향 0.
          if (event && event.success && reconcileOutdir) {
            reconcileOutdir();
          }
          if (event && event.success && event.graphChanged) {
            try {
              const r = await runBundle(opts, config);
              if (r.errors.length === 0) appDev.injectBundleCssLinks(r);
            } catch (cssErr) {
              console.error('[serve] graph-change outdir rebuild failed:', cssErr);
            }
          }
          const annotated =
            event && event.success && event.updates && event.updates.length > 0
              ? {
                  ...event,
                  updates: event.updates.map((u) => ({
                    ...u,
                    code: `${u.code}\n//# sourceMappingURL=${HMR_MAP_PATH}${encodeURIComponent(u.id)}\n`,
                  })),
                }
              : event;
          web.broadcastRebuildEvent(hmr, annotated);
        } catch (err) {
          console.error('[serve] hmr broadcast error:', err);
        }
      })();
    };
    try {
      nativeWatchHandle = watch(watchBuildOpts);
    } catch (err) {
      console.error('[serve] native watch failed to start (incremental HMR disabled):', err);
      markWatchReady();
    }
  }

  // #3796 — HTTP listen 을 watch.onReady 까지 wait (5초 timeout 으로 deadlock 방어).
  await Promise.race([watchReadyPromise, new Promise((r) => setTimeout(r, 5000))]);

  if (isBun) {
    // Bun.serve
    const serveOpts = {
      port: opts.port,
      hostname: opts.host,
      async fetch(req, server) {
        const url = new URL(req.url);
        // /__hmr WebSocket upgrade — Bun-native API 사용 (Node 분기는 server.on('upgrade')).
        // upgrade 는 첫 await 전에 동기 실행돼 async fetch 여도 안전.
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

        // #4062 PR-B-2 — lazy 라우트(entry alias + on-demand 동적 청크). null = 정적 처리로.
        const lazy = await tryServeLazy(req.url);
        if (lazy) {
          return new Response(lazy.body, {
            status: lazy.status,
            headers: {
              'Content-Type': lazy.type,
              'Access-Control-Allow-Origin': '*',
            },
          });
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

      // #4062 PR-B-2 — lazy 라우트(entry alias + on-demand 동적 청크). null = 정적 처리로.
      const lazy = await tryServeLazy(req.url);
      if (lazy) {
        res.writeHead(lazy.status, {
          'Content-Type': lazy.type,
          'Access-Control-Allow-Origin': '*',
        });
        res.end(Buffer.isBuffer(lazy.body) ? lazy.body : Buffer.from(lazy.body));
        return;
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
    // #3779 follow-up — native watch worker thread 가 child process spawn 후에도 살아남으면
    // outdir 출력이 부모/자식 두 곳에서 일어나 race. emitRestartAfter 의 child spawn 전에 stop.
    // stop 자체가 throw 해도 server.close 는 시도 (HTTP 포트 해제 우선).
    // #3803 — stop() throw 시 nativeWatchHandle 을 null 하지 않고 유지 → 다음 호출에서 retry
    // 가능. 정상 path 에서만 null 로 갱신. idempotent stop (#3794 의 napi_remove_wrap) 라
    // 다음 시도도 안전.
    if (nativeWatchHandle) {
      try {
        nativeWatchHandle.stop();
        nativeWatchHandle = null;
      } catch (err) {
        console.error('[serve] native watch stop failed (will retry on next invocation):', err);
      }
    }
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

    // #3796 — native watch handle 은 HTTP listen 전에 띄움 (위쪽 코드). 이 블록은
    // fsWatch + drain (CSS / sass / postcss / restart) 만 — JS 변경은 native watch 가 단독 처리.

    async function rebuildAppDevCss(changedPath) {
      // issue #3861 — drain (fs.watch) 가 prepare skip 시 tempRoot 가 raw root
      // 와 동기 안 되어 afterBundle 의 mirror 가 stale .css 를 outdir 에 다시
      // write → reconcileOutdirCss 의 unlink 무효화 (dual watch race).
      // syncDirty 는 prepare 의 syncDirtyFilesIntoTempRoot 만 호출 — PostCSS
      // 재실행 skip (prepare 가 full PostCSS reprocess 라 단일 CSS modify 시
      // 전체 .css 처리 → "processed N" 회귀, dev-hmr/postcss test fail). PostCSS
      // incremental 처리는 아래 afterBundle 의 changedPath 분기가 cover.
      appDev.syncDirty([changedPath]);
      try {
        await appDev.afterBundle({ changedPath });
      } catch (cssErr) {
        if (opts.logLevel !== 'silent') {
          console.error('[serve] css afterBundle failed:', cssErr);
        }
        throw cssErr; // drain outer catch (line 2460) 가 hmr.reportThrownError.
      }
      hmr?.clearError();
      hmr?.broadcast({
        type: HMR_MSG.CssUpdate,
        href: appDev.hrefFor(changedPath),
        timestamp: Date.now(),
      });
      if (opts.logLevel !== 'silent') console.error('[serve] css updated');
    }

    // #3779 — sass partial / 다중 sass 변경 (drain 의 sass 분기) 전용. SCSS dependents
    // 까지 재컴파일해야 하므로 full pipeline + FullReload. JS module 변경은 native watch
    // handle 이 단독 처리 — 이 함수는 더 이상 JS 분기에서 호출되지 않는다.
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
            } else if (paths.some((p) => p.endsWith('.scss') || p.endsWith('.sass'))) {
              // #71: sass 변경인데 fast-path 자격 없음(다른 root scss 가 @import 하는 partial,
              // 또는 다중 sass 변경) → full pipeline rebuild 로 dirty 의 transitive dependents 까지
              // 재컴파일. CSS-only 분기(afterBundle = postcss only)는 sass 를 재컴파일하지 않아
              // partial 변경 시 root scss 가 stale 로 남는다(code-review max 적발).
              await rebuildAppDevFull(paths);
            } else if (cssChanges.length === 1 && paths.length === 1) {
              await rebuildAppDevCss(cssChanges[0]);
            } else {
              await appDev.afterBundle();
              hmr?.clearError();
              hmr?.broadcast({ type: HMR_MSG.CssUpdate, timestamp: Date.now() });
              if (opts.logLevel !== 'silent') console.error('[serve] css updated');
            }
          } else {
            // #3797 — paths 의 종류에 따라 3분기:
            // - 전부 CSS-derived (CSS Module / Sass Module / postcss): native watch 의 module
            //   graph 밖이라 incremental update 트리거 안 됨 → full pipeline + FullReload.
            // - JS module (.ts/.tsx/.js 등) 섞임: native watch 가 단독 처리. drain noop
            //   (중복 컴파일/output race 회피).
            // - 그 외 (HTML / JSON / static asset 등 native watch graph 밖 + non-CSS): fallback
            //   FullReload broadcast. pre-#3779 의 unconditional rebuildAppDevFull 회귀 가드.
            // #3801 — appDev 의 isCssLikeChange 가 단일 진실 소스. inline literal endsWith
            // 가 `.less` (미지원) 포함하거나 `.styl/.pcss` 누락하던 drift 회귀 방지.
            const isJsModule = (p) =>
              p.endsWith('.ts') ||
              p.endsWith('.tsx') ||
              p.endsWith('.js') ||
              p.endsWith('.jsx') ||
              p.endsWith('.mjs') ||
              p.endsWith('.cjs');
            const allCssDerived = paths.every((p) => appDev.isCssLikeChange(p));
            const hasJs = paths.some(isJsModule);
            if (allCssDerived) {
              await rebuildAppDevFull(paths);
            } else if (!hasJs) {
              // HTML/JSON/asset 변경 — native watch 가 안 보는 변경에 대한 reload 신호.
              hmr?.clearError();
              hmr?.broadcast({ type: HMR_MSG.FullReload, timestamp: Date.now() });
              if (opts.logLevel !== 'silent') console.error('[serve] file changed, full reload');
            }
            // hasJs=true: native watch handle 의 onRebuild 가 단독 broadcast. drain noop.
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
  // workspace 모드는 root/entry config 가 본질이라 --no-config 미적용. silent
  // 무시는 혼란을 주므로 1회 경고 (loadAutoConfig 경로와 달리 게이트하지 않음).
  if (opts.noConfig) {
    console.warn('zntc: --no-config is ignored in workspace mode (--workspace)');
  }
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

  // --color/--no-color 를 NO_COLOR/FORCE_COLOR env 로 환원 (명시 flag 가 기존 env override).
  applyColorPreference(opts.color);

  if (opts.help) {
    printUsage(opts.appCommand);
    return;
  }

  if (opts.version) {
    console.log(getCliVersion() ?? 'unknown');
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

  // verify 는 Playwright 만 호출 — config / NAPI dlopen 불필요. test262 와 동일한 early dispatch.
  if (opts.appCommand === 'verify') {
    try {
      const { runVerify } = await import('./verify.mjs');
      const r = await runVerify(opts);
      process.exit(r.exitCode);
    } catch (err) {
      console.error(`error: ${err.message}`);
      process.exit(1);
    }
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
