#!/usr/bin/env node

/**
 * ZTS CLI — Node.js/Bun 호환 CLI
 *
 * 내부적으로 @zts/core NAPI 바인딩을 사용하여 트랜스파일/번들링을 수행.
 * Watch/Serve는 JS 레이어에서 구현.
 */

import {
  mkdirSync,
  cpSync,
  existsSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  mkdtempSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { resolve, relative, dirname, basename, extname, join, sep } from "node:path";
import { tmpdir } from "node:os";
import { createServer } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

import { applyFlagAction, KNOWN_FLAGS, matchFlagFromRegistry } from "./cli-flags.mjs";

function isMissingBuiltCore(error) {
  if (!error || error.code !== "ERR_MODULE_NOT_FOUND") return false;
  const builtCorePath = fileURLToPath(new URL("../dist/index.js", import.meta.url));
  return String(error.message ?? "").includes(builtCorePath);
}

async function loadCoreModule() {
  try {
    return await import("../dist/index.js");
  } catch (error) {
    if (!isMissingBuiltCore(error)) throw error;
    console.error("error: @zts/core JS bundle is missing");
    console.error("");
    console.error("note: zts CLI runs the built JS entry at packages/core/dist/index.js.");
    console.error("note: source TypeScript is not loaded directly by Node.");
    console.error("");
    console.error("help: run `bun run --cwd packages/core build:js` from the repository root.");
    console.error("help: for a full local build, run `bun run --cwd packages/core build`.");
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
  prepareAppDevSync,
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
  validateTsConfigRaw,
  warnUnknownKeys,
} = coreModule;

export { KNOWN_FLAGS };
const requireFromCli = createRequire(import.meta.url);
const cliNodeModules = resolve(dirname(fileURLToPath(import.meta.url)), "../../..", "node_modules");
const postcssTempRoots = new Set();
let postcssCleanupRegistered = false;

// ─── CLI 인자 파싱 ───

function usageLines(command) {
  if (command === "dev") {
    return [
      "Usage: zts dev [root] [options]",
      "",
      "Options:",
      "  --host [host]              Host to listen on (default: localhost)",
      "  --port <port>              Port to listen on (default: 12300)",
      "  --open                     Open the app URL in the browser",
      "  --mode <mode>              Load mode-specific config and .env files",
      "  --base <path>              Base public path",
      "  --entry-html <path>        HTML entry file",
      "  --public-dir <path|false>  Public directory to serve",
      "  --help, -h                 Show this help message",
    ];
  }
  if (command === "build") {
    return [
      "Usage: zts build [root] [options]",
      "",
      "Options:",
      "  --outdir <dir>             Output directory",
      "  --mode <mode>              Load mode-specific config and .env files",
      "  --base <path>              Base public path",
      "  --entry-html <path>        HTML entry file",
      "  --public-dir <path|false>  Public directory to copy",
      "  --minify                   Minify output",
      "  --sourcemap[=mode]         Emit source maps",
      "  --help, -h                 Show this help message",
    ];
  }
  if (command === "preview") {
    return [
      "Usage: zts preview [outdir] [options]",
      "",
      "Options:",
      "  --host [host]              Host to listen on (default: localhost)",
      "  --port <port>              Port to listen on (default: 12300)",
      "  --strict-port              Exit if the specified port is already in use",
      "  --open                     Open the preview URL in the browser",
      "  --base <path>              Base public path",
      "  --spa-fallback[=path]      Serve an HTML fallback for app routes",
      "  --certfile <path>          HTTPS certificate file",
      "  --keyfile <path>           HTTPS key file",
      "  --help, -h                 Show this help message",
    ];
  }
  return [
    "Usage: zts [options] <file.ts>",
    "       zts --bundle <entry.ts> -o out.js",
    "       zts --serve --bundle <entry.ts>",
    "       zts dev [root]",
    "       zts build [root]",
    "       zts preview [outdir]",
    "",
    "Options:",
    "  --bundle                   Bundle dependencies",
    "  --packages=external        Treat all bare package imports as external",
    "  --pure:CALLEE              Mark matching call/new expressions as removable when unused",
    "  --line-limit=<n>           Wrap generated output lines after safe token boundaries",
    "  --outdir <dir>             Output directory",
    "  --outfile <file>, -o <file> Output file",
    "  --allow-overwrite          Permit output paths to overwrite input files",
    "  --watch, -w                Rebuild on changes",
    "  --serve [dir]              Serve bundled output",
    "  --config <path>            Config file path",
    "  --help, -h                 Show this help message",
  ];
}

function printUsage(command, stream = console.log) {
  stream(usageLines(command).join("\n"));
}

function parseArgs(argv) {
  const args = argv.slice(2);
  const appCommands = new Set(["dev", "build", "preview"]);
  const appCommand = appCommands.has(args[0]) ? args.shift() : undefined;
  const opts = {
    appCommand,
    help: false,
    parseError: false,
    appRoot: undefined,
    previewDir: undefined,
    entryPoints: [],
    // SCALAR_KEYS (mergeConfigIntoOpts) 의 다른 키들과 동일하게 `undefined` 기본값 사용.
    // 과거 `null` 이었으나 머지 조건이 `=== undefined` 라 `zts.config.json` 의 outdir/outfile
    // 만 silent drop 되는 회귀가 있었음. 모든 사용처가 truthy 검사 (`if (opts.outdir)`) 라
    // null → undefined 변경은 동작 영향 없음.
    outfile: undefined,
    outdir: undefined,
    bundle: false,
    watch: false,
    watchJson: false,
    watchDelay: 100,
    serve: false,
    serveDir: ".",
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
    logLevel: "info",
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
    envPrefixes: undefined, // --env-prefix=VITE_,ZTS_ — undefined 면 loadEnv default 사용
    envDir: undefined, // --env-dir <path> — undefined 면 cwd
    workspaceConfig: undefined, // --workspace-config <path> — 명시 시 자동 탐색 우회 (#2111)
    workspace: undefined, // --workspace <name> — 단일 entry 만 빌드 (#2111)
    entryHtml: undefined,
    publicDir: undefined,
    base: undefined,
    spaFallback: undefined,
  };

  if (appCommand === "dev") {
    opts.serve = true;
    opts.bundle = true;
    opts.watch = true;
  } else if (appCommand === "build") {
    opts.bundle = true;
  } else if (appCommand === "preview") {
    opts.serve = true;
  }

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    // stdin
    if (arg === "-") {
      opts.stdin = true;
      continue;
    }

    // positional (파일 경로)
    if (!arg.startsWith("-")) {
      if (opts.appCommand === "dev" || opts.appCommand === "build") {
        opts.appRoot = opts.appRoot ?? arg;
      } else if (opts.appCommand === "preview") {
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
    if (arg === "--serve") {
      opts.serve = true;
      if (i + 1 < args.length && !args[i + 1].startsWith("-")) {
        opts.serveDir = args[++i];
      }
      continue;
    }

    // `--host [VALUE]` — pair-form 이지만 누락 시 default "0.0.0.0".
    // registry 의 string kind 와 의미 다름 (누락 시 undefined 가 아닌 명시 default).
    if (arg === "--host") {
      opts.host = args[++i] || "0.0.0.0";
      continue;
    }

    // dev-server proxy — `--proxy /api=http://localhost:8080` 형식 (특수 parser)
    if (arg.startsWith("--proxy")) {
      const [path, target] =
        arg.split("=").length > 1
          ? [arg.split(" ")[0].replace("--proxy", "").replace("=", ""), args[i].split("=")[1]]
          : [args[++i]?.split("=")[0], args[i]?.split("=")[1]];
      if (path && target) opts.proxy[path] = target;
      continue;
    }

    // unknown — typo 시 가장 가까운 known flag 제안 (Levenshtein, threshold 2).
    if (opts.logLevel !== "silent") {
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
  if (opts.jsxDev) opts.jsx = "automatic-dev";

  // esbuild legacy alias normalize: `--jsx=transform` / `--jsx=preserve` → classic.
  // docs/CONFIG.md 가 명시한 CLI vocab (preserve/transform/automatic) 을 strict NAPI vocab
  // (classic/automatic/automatic-dev) 로 변환. JS API 는 이 정규화를 받지 않고 strict union
  // type 만 허용 — CLI argv 의 raw string 만 esbuild 호환을 위해 관대하게 처리.
  if (opts.jsx === "transform" || opts.jsx === "preserve") opts.jsx = "classic";

  // drop 처리
  for (const d of opts.drop) {
    if (d === "console") opts.define["console.log"] = "undefined";
    if (d === "debugger") opts.define["debugger"] = "";
  }

  return opts;
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
      `zts: output file '${outPath}' would overwrite input file (use --allow-overwrite to permit)`,
    );
  }
}

function writeOutputFiles(outputFiles, outfile, outdir, entryPoints, allowOverwrite) {
  const resolvedEntries = allowOverwrite ? null : new Set(entryPoints.map(safeRealpath));
  if (outfile) {
    const outPath = resolve(outfile);
    assertCanWriteOutput(outPath, resolvedEntries);
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, outputFiles[0].text);
    if (outputFiles.length > 1) {
      writeFileSync(resolve(outfile + ".map"), outputFiles[1].text);
    }
  } else if (outdir) {
    const outDirAbs = resolve(outdir);
    mkdirSync(outDirAbs, { recursive: true });
    for (const file of outputFiles) {
      const outPath = join(outDirAbs, basename(file.path));
      assertCanWriteOutput(outPath, resolvedEntries);
      writeFileSync(outPath, file.text);
    }
  }
}

function normalizeBase(base) {
  if (!base) return "/";
  if (base === ".") return "";
  let out = base.startsWith("/") ? base : `/${base}`;
  if (!out.endsWith("/")) out += "/";
  return out;
}

function isBrowserLikePlatform(platform) {
  return platform === undefined || platform === "browser" || platform === "react-native";
}

function injectDefaultNodeEnvDefine(opts) {
  if (opts.define["process.env.NODE_ENV"] !== undefined) return;

  const appBrowserCommand = opts.appCommand === "dev" || opts.appCommand === "build";
  const browserBundle = opts.bundle && (isBrowserLikePlatform(opts.platform) || opts.minifySyntax);
  if (!appBrowserCommand && !browserBundle) return;

  const isDev = opts.appCommand === "dev" || opts.serve || opts.watch;
  opts.define["process.env.NODE_ENV"] = isDev ? '"development"' : '"production"';
}

function normalizeServerHost(host) {
  if (host === true) return "0.0.0.0";
  if (typeof host === "string" && host.length > 0) return host;
  return undefined;
}

function mergeServerConfigIntoOpts(opts, config) {
  const server = config?.server;
  if (!server || typeof server !== "object") return;

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
  if (opts.host === undefined) opts.host = "localhost";
}

function isPortInUseError(err) {
  const code = err?.code;
  const message = String(err?.message ?? err);
  return code === "EADDRINUSE" || /address already in use|port .*in use/i.test(message);
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
  if (opts.appCommand === "dev" || opts.appCommand === "build") {
    return resolve(opts.appRoot ?? ".");
  }
  return process.cwd();
}

async function runAppBuild(opts, config, configEnv, _dotenvVars) {
  if (config?.plugins?.length || opts.pluginPaths.length > 0) {
    throw new Error(
      "zts build app mode does not support JS plugins yet; use --bundle for plugin builds",
    );
  }
  const root = resolve(opts.appRoot ?? ".");
  const outdir = resolve(opts.outdir ?? join(root, "dist"));
  if (opts.clean) rmSync(outdir, { recursive: true, force: true });
  let pipelineRoot = null;
  try {
    const pipeline = await prepareAppCssPipelineRoot(
      root,
      outdir,
      configEnv,
      opts.logLevel,
      "build",
    );
    pipelineRoot = pipeline?.tempRoot ?? null;
    const result = buildAppSync({
      root: pipelineRoot ?? root,
      outdir,
      entryHtml: opts.entryHtml ?? "index.html",
      publicDir: opts.publicDir === undefined ? "public" : opts.publicDir,
      base: normalizeBase(opts.base ?? opts.publicPath ?? "/"),
      mode: configEnv.mode,
      envDir: opts.envDir ? resolve(opts.envDir) : (pipelineRoot ?? root),
      envPrefixes: opts.envPrefixes,
      define: Object.keys(opts.define).length > 0 ? opts.define : undefined,
      minify: opts.minify || opts.minifyWhitespace || opts.minifyIdentifiers || opts.minifySyntax,
      sourcemap: opts.sourcemap,
      splitting: opts.splitting || undefined,
      compiler: config?.compiler,
    });
    if (opts.logLevel !== "silent") {
      console.error(`[build] wrote ${result.outputCount ?? 0} files to ${outdir}`);
    }
    return result;
  } finally {
    if (pipelineRoot) cleanupPostcssTempRoot(pipelineRoot);
  }
}

const APP_DEV_HMR_CLIENT_PATH = "/__zts_app_dev_hmr__";
const APP_DEV_HMR_WS_PATH = "/__hmr";
const HMR_MSG = Object.freeze({
  Connected: "connected",
  CssUpdate: "css-update",
  FullReload: "full-reload",
});
// RFC 6455 fixed handshake GUID — 변경 불가.
const HMR_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

async function runAppDev(opts, config, configEnv, _dotenvVars) {
  const root = resolve(opts.appRoot ?? ".");
  opts.outdir = opts.outdir || join(root, ".zts-dev");
  const appDev = createAppDevController(opts, root, configEnv);
  const prepared = await appDev.prepare();

  opts.entryPoints = [prepared.entryPath];
  opts.serveDir = opts.outdir;

  return runServe(opts, config, { appDev });
}

function createAppDevController(opts, root, configEnv) {
  const outdir = resolve(opts.outdir || join(root, ".zts-dev"));
  const base = normalizeBase(opts.base ?? opts.publicPath ?? "/");
  let cssDeps = new Set();
  let cssDirDeps = new Set();
  let primaryHref = null;
  let pipelineRoot = null;
  // F1+F2 cache (incremental prep 에서 재사용). 구조 변화 (스타일 파일 추가/삭제) 시
  // 무효화 — `prepareAppCssPipelineRoot` 가 cache miss 일 때 자체적으로 재수집한다.
  let pipelineCache = null; // { stylePipelineFiles, styleSourceFiles }

  return {
    root,
    outdir,
    base,
    async prepare(dirtyPaths = null) {
      const reuseRoot = pipelineRoot && dirtyPaths != null;
      if (pipelineRoot && !reuseRoot) {
        cleanupPostcssTempRoot(pipelineRoot);
        pipelineRoot = null;
        pipelineCache = null;
      }
      // 구조 변화 — 새 .scss/.module.css 가 추가됐거나 삭제됐을 가능성. cache 무효화.
      if (reuseRoot && dirtyPaths.some((p) => isCssPreprocessorFile(p) || isCssModuleFile(p))) {
        pipelineCache = null;
      }
      const pipeline = await prepareAppCssPipelineRoot(
        root,
        outdir,
        configEnv,
        opts.logLevel,
        "dev",
        reuseRoot
          ? { existingTempRoot: pipelineRoot, dirtyPaths, cache: pipelineCache }
          : undefined,
      );
      pipelineRoot = pipeline?.tempRoot ?? null;
      pipelineCache = pipeline?.cache ?? null;
      const prepareRoot = pipelineRoot ?? root;
      const prepared = prepareAppDevSync({
        root: prepareRoot,
        outdir,
        entryHtml: opts.entryHtml ?? "index.html",
        publicDir: opts.publicDir === undefined ? "public" : opts.publicDir,
        base,
        mode: configEnv.mode,
        envDir: opts.envDir ? resolve(opts.envDir) : prepareRoot,
        envPrefixes: opts.envPrefixes,
      });
      injectAppDevHmrClient(outdir);
      // dev mode 한정 — bundler 가 dev splitting=false 라 CSS chunk 를 emit 하지
      // 않으므로 Sass / CSS Modules 결과를 outdir 로 mirror + `<link>` 주입.
      // mirror (cpSync) 는 sass/module 입력이 dirty 일 때만 — 그 외엔 outdir 의 직전 mirror
      // 본 그대로. inject 는 prepareAppDevSync 가 HTML 을 매번 덮어쓰므로 항상 필요.
      if (pipeline && pipeline.generatedCssAbsPaths.length > 0) {
        const sassOrModuleDirty =
          !reuseRoot || dirtyPaths.some((p) => isCssPreprocessorFile(p) || isCssModuleFile(p));
        const rels = sassOrModuleDirty
          ? mirrorPipelineCssToOutdir(pipelineRoot, outdir, pipeline.generatedCssAbsPaths)
          : pipeline.generatedCssAbsPaths.map((p) => relative(pipelineRoot, p));
        injectAppDevPipelineCssLinks(outdir, base, rels);
      }
      return prepared;
    },
    async afterBundle({ changedPath = null } = {}) {
      const result = await runPostcssForAppDev({
        root,
        outdir,
        configEnv,
        logLevel: opts.logLevel,
        base,
        changedPath,
      });
      cssDeps = result.deps;
      cssDirDeps = result.dirDeps;
      primaryHref = result.primaryHref;
      return result;
    },
    injectBundleCssLinks(bundleResult) {
      injectAppDevBundleCssLinks(outdir, base, bundleResult);
    },
    isPostcssConfig(absPath) {
      return isPostcssConfigFile(absPath);
    },
    isCssOnlyChange(absPath) {
      // CSS Modules 는 class 이름 매핑이 변할 수 있어 JS proxy 도 같이 재생성 필요 →
      // CSS-only HMR 로 갈음할 수 없고 full reload 가 안전한 기본값. Sass module
      // variant (`*.module.scss/.sass`) 도 같은 이유로 제외.
      if (isCssModuleFile(absPath) || isCssModulePreprocessorFile(absPath)) return false;
      if (isCssFile(absPath) || isCssPreprocessorFile(absPath)) return true;
      if (cssDeps.has(absPath)) return true;
      for (const dir of cssDirDeps) {
        if (absPath === dir || absPath.startsWith(`${dir}${sep}`)) return true;
      }
      return false;
    },
    isSassOnlyChange(absPath) {
      // Sass fast-path 자격 — non-module `.scss/.sass` 단일 변경. import dep 추적 없으므로
      // 이 파일을 import 한 다른 sass 파일은 갱신 누락 가능 (BACKLOG #71 deps tracking).
      return isCssPreprocessorFile(absPath) && !isCssModulePreprocessorFile(absPath);
    },
    async rebuildScssIncremental(absPath) {
      // pipelineRoot 가 없으면 fast-path 진입 못함 (full reload 로 fallback).
      if (!pipelineRoot) return null;
      // postcss config 가 있으면 fast-path 가 부정확한 결과 (Tailwind/autoprefixer 등이
      // skip 됨) — full reload 로 fallback.
      if (findPostcssConfig(root)) return null;
      const srcTemp = join(pipelineRoot, relative(root, absPath));
      mirrorFile(absPath, srcTemp);
      const sass = loadSassCompiler(root);
      const result = compileSassFile(sass, srcTemp, pipelineRoot);
      const cssTempPath = cssPreprocessorOutputPath(srcTemp);
      writeFileSync(cssTempPath, result.css);
      // 컴파일된 CSS 도 outdir 에 mirror 해서 dev server 가 서빙 가능하게.
      const cssRel = relative(pipelineRoot, cssTempPath);
      mirrorFile(cssTempPath, join(outdir, cssRel));
      return joinUrl(base, cssRel.replaceAll(sep, "/"));
    },
    hrefFor(absPath) {
      if (absPath.endsWith(".css")) return joinUrl(base, relative(root, absPath));
      return primaryHref ?? joinUrl(base, "style.css");
    },
  };
}

function joinUrl(base, rel) {
  if (!base) return rel;
  return `${base}${rel}`;
}

function injectIntoDevHtml(outdir, build) {
  const htmlPath = join(outdir, "index.html");
  let html;
  try {
    html = readFileSync(htmlPath, "utf8");
  } catch (err) {
    if (err?.code === "ENOENT") return;
    throw err;
  }
  const tag = build(html);
  if (!tag) return;
  const next = html.includes("</head>")
    ? html.replace("</head>", `${tag}\n</head>`)
    : html.replace("<script", `${tag}\n<script`);
  writeFileSync(htmlPath, next);
}

function injectAppDevHmrClient(outdir) {
  injectIntoDevHtml(outdir, (html) => {
    if (html.includes(APP_DEV_HMR_CLIENT_PATH)) return null;
    return `<script type="module" src="${APP_DEV_HMR_CLIENT_PATH}"></script>`;
  });
}

function injectAppDevBundleCssLinks(outdir, base, bundleResult) {
  injectIntoDevHtml(outdir, (html) => {
    const cssHrefs = [];
    for (const file of bundleResult?.outputFiles ?? []) {
      if (!file?.path || !isCssFile(file.path)) continue;
      const href = joinUrl(base, basename(file.path));
      if (!html.includes(`href="${href}"`) && !html.includes(`href='${href}'`)) cssHrefs.push(href);
    }
    if (cssHrefs.length === 0) return null;
    return cssHrefs.map((href) => `<link rel="stylesheet" href="${href}">`).join("\n");
  });
}

// 단일 파일 mirror — syncDirtyFilesIntoTempRoot, mirrorPipelineCssToOutdir,
// rebuildScssIncremental 가 공용. mkdir + cp 패턴이 흩어졌던 걸 일원화.
function mirrorFile(srcAbs, dstAbs) {
  mkdirSync(dirname(dstAbs), { recursive: true });
  cpSync(srcAbs, dstAbs);
}

// dev mode 의 sass / css-modules 컴파일 결과는 tempPipelineRoot 에만 있어 dev server 가
// 서빙 못 한다. 같은 rel path 로 outdir 에 복사해 `/<rel>` 로 fetch 가능하게 만든다.
function mirrorPipelineCssToOutdir(pipelineRoot, outdir, absPaths) {
  const rels = [];
  for (const abs of absPaths) {
    const rel = relative(pipelineRoot, abs);
    mirrorFile(abs, join(outdir, rel));
    rels.push(rel);
  }
  return rels;
}

function injectAppDevPipelineCssLinks(outdir, base, cssRelPaths) {
  if (cssRelPaths.length === 0) return;
  injectIntoDevHtml(outdir, (html) => {
    const tags = [];
    for (const rel of cssRelPaths) {
      const href = joinUrl(base, rel.replaceAll(sep, "/"));
      if (html.includes(`href="${href}"`) || html.includes(`href='${href}'`)) continue;
      tags.push(`<link rel="stylesheet" href="${href}">`);
    }
    return tags.length === 0 ? null : tags.join("\n");
  });
}

const APP_DEV_HMR_CLIENT = `
const socketProtocol = location.protocol === "https:" ? "wss:" : "ws:";
const socket = new WebSocket(socketProtocol + "//" + location.host + "${APP_DEV_HMR_WS_PATH}");
socket.addEventListener("message", (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === "${HMR_MSG.FullReload}") {
    location.reload();
    return;
  }
  if (msg.type !== "${HMR_MSG.CssUpdate}") return;
  const stamp = msg.timestamp || Date.now();
  const links = Array.from(document.querySelectorAll('link[rel="stylesheet"]'));
  let updated = false;
  for (const link of links) {
    const href = link.getAttribute("href");
    if (!href) continue;
    const current = new URL(href, location.href);
    const target = new URL(msg.href || current.pathname, location.href);
    if (msg.href && current.pathname !== target.pathname) continue;
    const next = new URL(current.href);
    next.searchParams.set("t", String(stamp));
    const replacement = link.cloneNode();
    replacement.href = next.href;
    replacement.onload = () => link.remove();
    replacement.onerror = () => location.reload();
    link.after(replacement);
    updated = true;
  }
  if (!updated) location.reload();
});
`;

function createAppDevHmrChannel() {
  // Node 와 Bun runtime 의 WebSocket 표현이 다르므로 두 클라이언트 종류를 구분.
  const nodeSockets = new Set();
  const bunClients = new Set();
  const connected = JSON.stringify({ type: HMR_MSG.Connected });
  return {
    accept(req, socket) {
      const key = req.headers["sec-websocket-key"];
      if (!key) {
        socket.destroy();
        return;
      }
      const accept = createHash("sha1").update(`${key}${HMR_WS_GUID}`).digest("base64");
      socket.write(
        [
          "HTTP/1.1 101 Switching Protocols",
          "Upgrade: websocket",
          "Connection: Upgrade",
          `Sec-WebSocket-Accept: ${accept}`,
          "",
          "",
        ].join("\r\n"),
      );
      nodeSockets.add(socket);
      socket.on("close", () => nodeSockets.delete(socket));
      socket.on("error", () => nodeSockets.delete(socket));
      writeWsText(socket, connected);
    },
    addBunClient(ws) {
      bunClients.add(ws);
      ws.send(connected);
    },
    removeBunClient(ws) {
      bunClients.delete(ws);
    },
    broadcast(message) {
      const text = JSON.stringify(message);
      for (const socket of nodeSockets) writeWsText(socket, text);
      for (const ws of bunClients) ws.send(text);
    },
  };
}

function writeWsText(socket, text) {
  if (socket.destroyed) return;
  const payload = Buffer.from(text);
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.allocUnsafe(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.allocUnsafe(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

const POSTCSS_CONFIG_NAMES = [
  "postcss.config.mjs",
  "postcss.config.js",
  "postcss.config.cjs",
  "postcss.config.json",
  ".postcssrc",
  ".postcssrc.json",
  ".postcssrc.js",
  ".postcssrc.cjs",
  ".postcssrc.mjs",
];

function findPostcssConfig(root) {
  for (const name of POSTCSS_CONFIG_NAMES) {
    const path = join(root, name);
    if (existsSync(path)) return path;
  }
  return null;
}

// Incremental: dirty 만 root → tempRoot 로 mirror. 비싼 cpSync 는 변경분으로 한정.
// 삭제된 source 는 tempRoot 의 generated peer (sass: `.css/.css.js`, module:
// `.module.zts.css/.module.css.js`) 까지 함께 정리해 stale orphan 방지.
function syncDirtyFilesIntoTempRoot(root, tempRoot, dirtyPaths) {
  for (const abs of dirtyPaths) {
    const rel = relative(root, abs);
    if (!rel || rel.startsWith("..")) continue;
    const dst = join(tempRoot, rel);
    if (existsSync(abs)) {
      mirrorFile(abs, dst);
    } else if (existsSync(dst)) {
      rmSync(dst, { force: true });
      for (const peer of generatedPeerPaths(dst)) {
        if (existsSync(peer)) rmSync(peer, { force: true });
      }
    }
  }
}

function generatedPeerPaths(srcPath) {
  if (isCssPreprocessorFile(srcPath)) {
    return [cssPreprocessorOutputPath(srcPath), cssPreprocessorProxyPath(srcPath)];
  }
  if (isCssModuleFile(srcPath)) {
    return [cssModuleGeneratedCssPath(srcPath), cssModuleProxyPath(srcPath)];
  }
  return [];
}

function copyAppRootForPostcss(root, outdir, phase) {
  const tempRoot = mkdtempSync(join(tmpdir(), `zts-postcss-${phase}-`));
  registerPostcssTempRoot(tempRoot);
  const skip = new Set([
    resolve(outdir),
    resolve(tempRoot),
    resolve(join(root, "node_modules")),
    resolve(join(root, ".git")),
    resolve(join(root, "dist")),
    resolve(join(root, ".zts-dev")),
  ]);
  cpSync(root, tempRoot, {
    recursive: true,
    dereference: false,
    filter(source) {
      const abs = resolve(source);
      if (abs === resolve(root)) return true;
      for (const ignored of skip) {
        if (abs === ignored || abs.startsWith(`${ignored}${sep}`)) return false;
      }
      return true;
    },
  });
  const appNodeModules = join(root, "node_modules");
  const nodeModulesTarget = existsSync(appNodeModules) ? appNodeModules : cliNodeModules;
  if (existsSync(nodeModulesTarget)) {
    symlinkSync(nodeModulesTarget, join(tempRoot, "node_modules"), "dir");
  }
  return tempRoot;
}

function registerPostcssTempRoot(tempRoot) {
  postcssTempRoots.add(tempRoot);
  if (postcssCleanupRegistered) return;
  postcssCleanupRegistered = true;
  const cleanupAll = () => {
    for (const root of postcssTempRoots) rmSync(root, { recursive: true, force: true });
    postcssTempRoots.clear();
  };
  process.once("exit", cleanupAll);
  process.once("SIGINT", () => {
    cleanupAll();
    process.exit(130);
  });
  process.once("SIGTERM", () => {
    cleanupAll();
    process.exit(143);
  });
}

function cleanupPostcssTempRoot(tempRoot) {
  postcssTempRoots.delete(tempRoot);
  rmSync(tempRoot, { recursive: true, force: true });
}

function requireFromAppOrCli(requireFromRoot, specifier) {
  try {
    return requireFromRoot(specifier);
  } catch (err) {
    const code = err?.code;
    if (code !== "MODULE_NOT_FOUND" && code !== "ERR_MODULE_NOT_FOUND") throw err;
    return requireFromCli(specifier);
  }
}

function collectAppFiles(dir, { skipDir = null, predicate = () => true } = {}) {
  if (!existsSync(dir)) return [];
  const skipResolved = skipDir ? resolve(skipDir) : null;
  const files = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name === ".git") continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (skipResolved && resolve(path) === skipResolved) continue;
      files.push(...collectAppFiles(path, { skipDir, predicate }));
    } else if (entry.isFile() && predicate(path)) {
      files.push(path);
    }
  }
  return files;
}

const isCssFile = (path) => path.endsWith(".css");
const isPostcssConfigFile = (path) => POSTCSS_CONFIG_NAMES.includes(basename(path));

const CSS_PREPROCESSOR_EXTENSIONS = new Set([".scss", ".sass"]);
const MODULE_PREPROCESSOR_RE = /\.module\.(?:scss|sass)$/;

function isCssPreprocessorFile(path) {
  return CSS_PREPROCESSOR_EXTENSIONS.has(extname(path));
}

function isCssModulePreprocessorFile(path) {
  return MODULE_PREPROCESSOR_RE.test(path);
}

function cssPreprocessorOutputPath(file) {
  return file.replace(/\.(?:scss|sass)$/i, ".css");
}

function cssPreprocessorProxyPath(file) {
  return `${cssPreprocessorOutputPath(file)}.js`;
}

function loadSassCompiler(root) {
  const requireFromRoot = createRequire(join(root, "package.json"));
  return requireFromAppOrCli(requireFromRoot, "sass");
}

// Sass option 일관성: full transform 과 fast-path (rebuildScssIncremental) 양쪽이 같은
// 옵션을 써야 한다. drift 감지는 이 헬퍼 호출 일치성으로 한다.
function compileSassFile(sass, file, loadRoot) {
  return sass.compile(file, {
    style: "expanded",
    loadPaths: [dirname(file), loadRoot],
    sourceMap: false,
  });
}

// HTML 은 `<link href="x.scss">` 를 그대로 컴파일된 CSS 로, JS/TS 는 `.css.js` proxy
// (`import "./generated.css"` 한 줄짜리) 로 다른 확장자로 rewrite. CSS Modules 의
// `.module.css` rewriter (rewriteCssModuleReferences) 는 HTML 미지원이라 별도 함수.
function rewriteSassReferences(sourceFiles) {
  const pattern = /(["'])([^"']+\.(?:scss|sass))([?#][^"']*)?\1/g;
  for (const source of sourceFiles) {
    const input = readFileSync(source, "utf8");
    if (!input.includes(".scss") && !input.includes(".sass")) continue;
    const toExt = source.endsWith(".html") ? ".css" : ".css.js";
    const output = input.replace(
      pattern,
      (_match, quote, spec, suffix = "") =>
        `${quote}${spec.replace(/\.(?:scss|sass)$/i, toExt)}${suffix}${quote}`,
    );
    if (output !== input) writeFileSync(source, output);
  }
}

function isStyleReferenceSource(path) {
  return /\.(?:html|mjs|cjs|js|jsx|ts|tsx)$/.test(path);
}

function buildCssPreprocessorProxy(cssPath) {
  // proxy 는 bundler 의 module graph 에서 CSS 를 side-effect 로 추적하기 위한 entry.
  // 실제 CSS 는 build mode 에서는 bundler 의 CSS chunk 로, dev mode 에서는 컴파일된 CSS
  // 를 outdir 로 복사한 뒤 HTML `<link>` 로 서빙한다 (`mirrorPipelineCssToOutdir` 참고).
  const cssImport = `./${basename(cssPath)}`;
  return `import ${JSON.stringify(cssImport)};\n`;
}

function transformCssPreprocessors(root, files, sourceFiles, logLevel, opts = {}) {
  if (files.length === 0) return [];
  const { dirtyOnly = null, dirtySources = null } = opts;
  const targets = dirtyOnly ? files.filter((f) => dirtyOnly.has(f)) : files;
  // Generated CSS path 는 입력 파일에 결정적 — 컴파일 안 해도 path 는 항상 알 수 있다.
  // dirty 만 다시 컴파일하고, 전체 list 는 항상 반환해 outdir mirror 가 누락 없게.
  if (targets.length === 0) {
    return files.map(cssPreprocessorOutputPath);
  }

  let sass;
  try {
    sass = loadSassCompiler(root);
  } catch (err) {
    const message =
      err?.code === "MODULE_NOT_FOUND" || err?.code === "ERR_MODULE_NOT_FOUND"
        ? "Sass/SCSS support requires the optional `sass` package. Install it with `bun add -d sass` or `npm install -D sass`."
        : `Failed to load sass: ${err?.message ?? err}`;
    throw new Error(message);
  }

  for (const file of targets) {
    const result = compileSassFile(sass, file, root);
    const cssPath = cssPreprocessorOutputPath(file);
    writeFileSync(cssPath, result.css);
    writeFileSync(cssPreprocessorProxyPath(file), buildCssPreprocessorProxy(cssPath));
  }

  // dirty source 만 freshly cp 됐으므로 그쪽에만 rewriter 적용 (이전 prep 의 source 들은
  // 이미 rewrite 된 상태). 전체 prep 일 때는 sourceFiles 자체가 전체.
  rewriteSassReferences(dirtySources ?? sourceFiles);
  if (logLevel !== "silent") {
    console.error(`[sass] processed ${targets.length} Sass/SCSS file(s)`);
  }
  return files.map(cssPreprocessorOutputPath);
}

function isCssModuleFile(path) {
  return basename(path).endsWith(".module.css");
}

function cssModuleGeneratedCssPath(file) {
  return file.replace(/\.module\.css$/, ".module.zts.css");
}

function cssModuleProxyPath(file) {
  return `${file}.js`;
}

function cssModuleLocalName(root, file, local) {
  const rel = relative(root, file).replaceAll(sep, "/");
  const fileName = basename(file, ".module.css").replace(/[^a-zA-Z0-9_]/g, "_");
  const safeLocal = local.replace(/[^a-zA-Z0-9_]/g, "_");
  // 8 chars (~48 bits) 면 100k 클래스에서도 birthday collision <0.001%. 5 chars (~30 bits)
  // 일 때 10k 키만 돼도 ~5% 라 무성격 시각적 충돌이 가능했음.
  const hash = createHash("sha1").update(`${rel}:${local}`).digest("base64url").slice(0, 8);
  return `${fileName}_${safeLocal}__${hash}`;
}

// 지원 범위: 일반 `.class-name` 토큰의 위치 추출. `:global`/`:local` 슈도, `composes:`
// 룰, `@keyframes` 이름 scoping 등 고급 CSS Modules 스펙은 미지원.
function scanCssModuleClassTokens(css) {
  const tokens = [];
  let i = 0;
  while (i < css.length) {
    const ch = css[i];
    const next = css[i + 1];
    if ((ch === '"' || ch === "'") && css[i - 1] !== "\\") {
      i = skipCssString(css, i, ch);
      continue;
    }
    if (ch === "/" && next === "*") {
      const end = css.indexOf("*/", i + 2);
      i = end === -1 ? css.length : end + 2;
      continue;
    }
    if (startsWithCssIdent(css, i, "url(")) {
      i = skipCssUrl(css, i + 4);
      continue;
    }
    if (ch === "." && isCssIdentStart(next)) {
      let end = i + 2;
      while (end < css.length && isCssIdent(css[end])) end += 1;
      tokens.push({ start: i, end, local: css.slice(i + 1, end) });
      i = end;
      continue;
    }
    i += 1;
  }
  return tokens;
}

function skipCssString(css, start, quote) {
  let i = start + 1;
  while (i < css.length) {
    if (css[i] === "\\" && i + 1 < css.length) {
      i += 2;
      continue;
    }
    if (css[i] === quote) return i + 1;
    i += 1;
  }
  return css.length;
}

function skipCssUrl(css, start) {
  let i = start;
  while (i < css.length) {
    if ((css[i] === '"' || css[i] === "'") && css[i - 1] !== "\\") {
      i = skipCssString(css, i, css[i]);
      continue;
    }
    if (css[i] === ")") return i + 1;
    i += 1;
  }
  return css.length;
}

function startsWithCssIdent(css, offset, value) {
  return css.slice(offset, offset + value.length).toLowerCase() === value;
}

function isCssIdentStart(ch) {
  return ch === "_" || (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z");
}

function isCssIdent(ch) {
  return isCssIdentStart(ch) || ch === "-" || (ch >= "0" && ch <= "9");
}

function collectCssModuleClasses(css) {
  return [...new Set(scanCssModuleClassTokens(css).map((token) => token.local))];
}

function rewriteCssModuleClasses(css, mapping) {
  const tokens = scanCssModuleClassTokens(css);
  let out = "";
  let offset = 0;
  for (const token of tokens) {
    const scoped = mapping[token.local];
    if (!scoped) continue;
    out += css.slice(offset, token.start);
    out += `.${scoped}`;
    offset = token.end;
  }
  out += css.slice(offset);
  return out;
}

function isValidExportName(name) {
  return /^[$A-Z_a-z][$\w]*$/.test(name) && !CSS_MODULE_RESERVED_EXPORTS.has(name);
}

const CSS_MODULE_RESERVED_EXPORTS = new Set([
  "arguments",
  "await",
  "break",
  "case",
  "catch",
  "class",
  "const",
  "continue",
  "debugger",
  "default",
  "delete",
  "do",
  "else",
  "enum",
  "export",
  "extends",
  "false",
  "finally",
  "for",
  "function",
  "if",
  "implements",
  "import",
  "in",
  "instanceof",
  "interface",
  "let",
  "new",
  "null",
  "package",
  "private",
  "protected",
  "public",
  "return",
  "static",
  "super",
  "switch",
  "this",
  "throw",
  "true",
  "try",
  "typeof",
  "var",
  "void",
  "while",
  "with",
  "yield",
]);

function buildCssModuleProxy(generatedCssPath, mapping) {
  // CSS 자체는 generated `.module.zts.css` 가 책임 — proxy 는 class-name map 의 default
  // export 와 valid named export 만 emit. dev/build 모두 CSS 는 `<link>` 로 도달.
  const cssImport = `./${basename(generatedCssPath)}`;
  const stylesJson = JSON.stringify(mapping);
  const named = Object.keys(mapping)
    .filter(isValidExportName)
    .map((name) => `export const ${name} = ${JSON.stringify(mapping[name])};`)
    .join("\n");
  return [
    `import ${JSON.stringify(cssImport)};`,
    `const styles = ${stylesJson};`,
    "export default styles;",
    named,
    "",
  ]
    .filter(Boolean)
    .join("\n");
}

// CSS Modules 의 source rewrite 는 HTML 미지원 — `<link href="x.module.css">` 같은 직접
// 참조는 일반 CSS 로 취급되므로 `.js` 로 rewrite 하면 안 됨. styleSources 에서 .html
// 은 제외하고 import specifier 만 `.module.css.js` 로 redirect 한다.
function rewriteCssModuleReferences(sourceFiles) {
  const pattern = /(["'])([^"']+\.module\.css)([?#][^"']*)?\1/g;
  for (const source of sourceFiles) {
    if (/\.html?$/i.test(source)) continue;
    const input = readFileSync(source, "utf8");
    if (!input.includes(".module.css")) continue;
    const output = input.replace(
      pattern,
      (_match, quote, spec, suffix = "") => `${quote}${spec}.js${suffix}${quote}`,
    );
    if (output !== input) writeFileSync(source, output);
  }
}

function transformCssModules(root, moduleFiles, styleSources, logLevel, opts = {}) {
  if (moduleFiles.length === 0) return [];
  const { dirtyOnly = null, dirtySources = null } = opts;
  const targets = dirtyOnly ? moduleFiles.filter((f) => dirtyOnly.has(f)) : moduleFiles;
  if (targets.length === 0) {
    return moduleFiles.map(cssModuleGeneratedCssPath);
  }

  for (const file of targets) {
    const css = readFileSync(file, "utf8");
    const mapping = {};
    for (const local of collectCssModuleClasses(css)) {
      mapping[local] = cssModuleLocalName(root, file, local);
    }
    const rewrittenCss = rewriteCssModuleClasses(css, mapping);
    const generatedCssPath = cssModuleGeneratedCssPath(file);
    writeFileSync(generatedCssPath, rewrittenCss);
    writeFileSync(cssModuleProxyPath(file), buildCssModuleProxy(generatedCssPath, mapping));
  }

  rewriteCssModuleReferences(dirtySources ?? styleSources);

  if (logLevel !== "silent") {
    console.error(`[css-modules] processed ${targets.length} CSS module file(s)`);
  }
  return moduleFiles.map(cssModuleGeneratedCssPath);
}

async function loadPostcssConfig(root, configEnv) {
  const requireFromRoot = createRequire(join(root, "package.json"));
  const postcssrc = requireFromAppOrCli(requireFromRoot, "postcss-load-config");
  const postcssModule = requireFromAppOrCli(requireFromRoot, "postcss");
  const postcss = postcssModule.default ?? postcssModule;
  const config = await postcssrc({ cwd: root, env: configEnv.mode }, root).catch((err) => {
    if (err?.message?.includes("No PostCSS Config found")) return null;
    throw err;
  });
  if (!config) return null;
  const plugins = config.plugins ?? [];
  if (plugins.length === 0) return null;
  return { postcss, plugins, options: config.options ?? {}, configFile: config.file ?? null };
}

function logPostcssProcessed(logLevel, count, configFile) {
  if (logLevel === "silent") return;
  console.error(
    `[postcss] processed ${count} CSS file(s) using ${basename(configFile ?? "postcss config")}`,
  );
}

async function runPostcssIfConfigured(root, cssDir, skipDir, configEnv, logLevel) {
  const loaded = await loadPostcssConfig(root, configEnv);
  if (!loaded) return;
  const cssFiles = collectAppFiles(cssDir, { skipDir, predicate: isCssFile });
  await Promise.all(
    cssFiles.map(async (file) => {
      const input = readFileSync(file, "utf8");
      const result = await loaded.postcss(loaded.plugins).process(input, {
        ...loaded.options,
        from: file,
        to: file,
      });
      writeFileSync(file, result.css);
      if (result.map) writeFileSync(`${file}.map`, result.map.toString());
    }),
  );
  logPostcssProcessed(logLevel, cssFiles.length, loaded.configFile);
}

async function runPostcssForAppDev({
  root,
  outdir,
  configEnv,
  logLevel,
  base,
  changedPath = null,
}) {
  const deps = new Set();
  const dirDeps = new Set();
  let primaryHref = null;
  const configPath = findPostcssConfig(root);
  if (!configPath) {
    const first = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile })[0];
    if (first) primaryHref = joinUrl(base, relative(root, first));
    return { deps, dirDeps, primaryHref, processed: 0 };
  }

  const loaded = await loadPostcssConfig(root, configEnv);
  if (!loaded) return { deps, dirDeps, primaryHref, processed: 0 };
  deps.add(resolve(loaded.configFile ?? configPath));

  mkdirSync(outdir, { recursive: true });
  const allCssFiles = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile });
  // 단일 CSS 파일 변경이면 그 파일만 reprocess. 그 외(첫 빌드, postcss config 변경 등)는 전체.
  const targets =
    changedPath && changedPath.endsWith(".css") && allCssFiles.includes(changedPath)
      ? [changedPath]
      : allCssFiles;

  await Promise.all(
    targets.map(async (file) => {
      const outputRel = relative(root, file);
      const outputPath = join(outdir, outputRel);
      mkdirSync(dirname(outputPath), { recursive: true });
      const input = readFileSync(file, "utf8");
      const result = await loaded.postcss(loaded.plugins).process(input, {
        ...loaded.options,
        from: file,
        to: outputPath,
      });
      writeFileSync(outputPath, result.css);
      if (result.map) writeFileSync(`${outputPath}.map`, result.map.toString());
      deps.add(resolve(file));
      collectPostcssMessages(result.messages, deps, dirDeps);
    }),
  );
  // primaryHref 는 "임의의 첫 stylesheet" 기준 — non-CSS 변경 시 fallback 으로 사용.
  if (allCssFiles.length > 0) primaryHref = joinUrl(base, relative(root, allCssFiles[0]));

  logPostcssProcessed(logLevel, targets.length, loaded.configFile);
  return { deps, dirDeps, primaryHref, processed: targets.length };
}

function collectPostcssMessages(messages, deps, dirDeps) {
  for (const message of messages ?? []) {
    if (message.type === "dependency" && message.file) deps.add(resolve(message.file));
    if (message.type === "dir-dependency") {
      const dir = message.dir ?? message.directory;
      if (dir) dirDeps.add(resolve(dir));
    }
    if (message.type === "context-dependency" && message.file) deps.add(resolve(message.file));
  }
}

async function prepareAppCssPipelineRoot(root, outdir, configEnv, logLevel, phase, options = {}) {
  const { existingTempRoot = null, dirtyPaths = null, cache = null } = options;
  const configPath = findPostcssConfig(root);
  // F1 cache: 이전 prep 의 stylePipelineFiles 를 재사용. 호출자가 구조 변화 (.scss/.module.css
  // 추가/삭제) 시 cache=null 로 무효화한다. 재사용이면 full tree walk 를 통째 회피.
  const stylePipelineFiles =
    cache?.stylePipelineFiles ??
    collectAppFiles(root, {
      skipDir: outdir,
      predicate: (path) => isCssPreprocessorFile(path) || isCssModuleFile(path),
    });
  const preprocessorFiles = stylePipelineFiles.filter(isCssPreprocessorFile);
  const moduleFiles = stylePipelineFiles.filter(isCssModuleFile);
  const needsSource = preprocessorFiles.length > 0 || moduleFiles.length > 0;

  if (!configPath && !needsSource) return null;
  // Incremental: existing tempRoot 가 있으면 dirty 파일만 sync (BACKLOG #70). 초기 빌드는
  // 전체 cpSync. dirtyPaths 가 null 이면 안전쪽 fallback 으로 간주해 full sync.
  const tempRoot = existingTempRoot ?? copyAppRootForPostcss(root, outdir, phase);
  const isIncremental = existingTempRoot && dirtyPaths;
  if (isIncremental) {
    syncDirtyFilesIntoTempRoot(root, tempRoot, dirtyPaths);
  }

  const toTemp = (path) => join(tempRoot, relative(root, path));
  // F2 cache: styleSourceFiles 도 cache 재사용 — 구조 변화 없으면 .html/.js/.ts 트리 walk 회피.
  // postcss-only 경로 (preprocessor/module 모두 없음) 면 dead 라 빈 배열.
  const styleSourceFiles = !needsSource
    ? []
    : (cache?.styleSourceFiles ?? collectAppFiles(tempRoot, { predicate: isStyleReferenceSource }));

  // Incremental 모드에서 transforms 가 다시 계산할 dirty 입력 set 을 미리 만든다.
  // — sass: dirty `.scss/.sass` 만 컴파일
  // — css-modules: dirty `.module.css` (또는 dirty `.module.scss` 의 sass 산출물) 만 scoping
  // — source rewriter: freshly cp 된 dirty source 만 (나머지는 이전 prep 의 rewrite 가 살아있음)
  // postcss 는 자체 changedPath 옵션이 있어 별도 호출 (afterBundle / runPostcssForAppDev) 가 처리.
  let dirtySassSet = null;
  let dirtyModuleSet = null;
  let dirtySourceList = null;
  if (isIncremental) {
    const dirtyTempPaths = dirtyPaths.map(toTemp);
    dirtySassSet = new Set(dirtyTempPaths.filter((p) => isCssPreprocessorFile(p)));
    dirtyModuleSet = new Set(dirtyTempPaths.filter((p) => isCssModuleFile(p)));
    // dirty `.module.scss` → sass 산출물 `.module.css` 도 css-modules dirty 입력에 포함.
    for (const sassDirty of dirtySassSet) {
      const cssOut = cssPreprocessorOutputPath(sassDirty);
      if (isCssModuleFile(cssOut)) dirtyModuleSet.add(cssOut);
    }
    dirtySourceList = dirtyTempPaths.filter((p) => isStyleReferenceSource(p) && existsSync(p));
  }

  // 파이프라인 순서 (유지 필수):
  //  1. Sass: `*.scss/.sass` → `*.css` (`.module.scss` 면 `.module.css` 가 새로 생김)
  //  2. PostCSS: 모든 `*.css` 에 변환 적용 (Tailwind 등이 `@apply` 같은 룰 주입)
  //  3. CSS Modules: postcss 가 주입한 `.injected` 같은 selector 까지 scoping
  // 순서가 바뀌면 postcss 가 추가한 selector 가 scoped 안 되거나 sass 미컴파일 상태로
  // postcss 가 돌아 깨진다 — 통합 테스트 `Sass output flows through PostCSS before CSS Modules scoping` 참고.
  const sassOutputs = transformCssPreprocessors(
    tempRoot,
    preprocessorFiles.map(toTemp),
    styleSourceFiles,
    logLevel,
    isIncremental ? { dirtyOnly: dirtySassSet, dirtySources: dirtySourceList } : undefined,
  );
  // Incremental 모드에서 dirty 가 모두 non-CSS 면 postcss prep 도 skip — 이미 이전 prep
  // 결과가 tempRoot 에 살아 있다. CSS / SCSS / postcss config 가 dirty 일 때만 재실행.
  const postcssRelevant =
    !isIncremental ||
    dirtyPaths.some((p) => isCssFile(p) || isCssPreprocessorFile(p) || isPostcssConfigFile(p));
  if (postcssRelevant) {
    await runPostcssIfConfigured(tempRoot, tempRoot, null, configEnv, logLevel);
  }
  // `*.module.scss` 는 위 sass 단계에서 `*.module.css` 가 새로 만들어지므로, 사전 walk
  // 가 본 모듈 리스트엔 빠져 있다. preprocessor 출력 경로를 재계산해 보강.
  const generatedModuleFiles = preprocessorFiles
    .map(cssPreprocessorOutputPath)
    .filter(isCssModuleFile);
  const moduleOutputs = transformCssModules(
    tempRoot,
    [...moduleFiles, ...generatedModuleFiles].map(toTemp),
    styleSourceFiles,
    logLevel,
    isIncremental ? { dirtyOnly: dirtyModuleSet, dirtySources: dirtySourceList } : undefined,
  );
  // dev mode 가 brwoser 까지 CSS 를 도달시키도록 outdir mirror 에 사용. build mode 는
  // bundler 가 entry 의 `import "./generated.css"` 를 따라 CSS chunk 를 emit 하므로
  // 별도로 mirror 할 필요 없음 (소비자가 결정).
  // `.module.scss` 의 sass 산출물 (`*.module.css`) 은 그 자체가 CSS Modules 입력으로
  // 다시 들어가 결국 `*.module.zts.css` 로 emit 되므로 mirror 대상에서 제외.
  const moduleInputCssPaths = new Set(
    generatedModuleFiles.map((p) => join(tempRoot, relative(root, p))),
  );
  const generatedCssAbsPaths = [
    ...sassOutputs.filter((p) => !moduleInputCssPaths.has(p)),
    ...moduleOutputs,
  ];
  return {
    tempRoot,
    generatedCssAbsPaths,
    cache: { stylePipelineFiles, styleSourceFiles },
  };
}

async function runAppPreview(opts) {
  opts.serveDir = resolve(opts.previewDir ?? opts.outdir ?? "dist");
  opts.outdir = undefined;
  opts.bundle = false;
  opts.watch = false;
  return runServe(opts, null);
}

function normalizeSpaFallback(value) {
  if (value === undefined || value === null || value === false || value === "false") return null;
  const raw = value === true ? "index.html" : String(value);
  return raw.startsWith("/") ? raw.slice(1) : raw;
}

function requestAcceptsHtml(accept) {
  if (!accept) return true;
  return accept.includes("text/html") || accept.includes("*/*");
}

function looksLikeAssetPath(pathname) {
  return extname(pathname) !== "";
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
    source = readFileSync(resolve(opts.entryPoints[0]), "utf8");
  }

  const result = transpile(source, {
    filename: opts.stdin ? "stdin.ts" : opts.entryPoints[0],
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
    dropConsole: opts.drop.includes("console"),
    dropDebugger: opts.drop.includes("debugger"),
    target: opts.target,
    browserslist: opts.browserslist,
    tsconfigRaw: opts.tsconfigRaw,
  });

  if (opts.outfile || opts.outdir) {
    const name = basename(opts.entryPoints[0]).replace(/\.[^.]+$/, ".js");
    const outputFiles = [{ path: name, text: result.code }];
    if (opts.outfile && result.map) {
      outputFiles.push({ path: name + ".map", text: result.map });
    }
    writeOutputFiles(outputFiles, opts.outfile, opts.outdir, opts.entryPoints, opts.allowOverwrite);
  } else {
    process.stdout.write(result.code);
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

  const command = opts.serve ? "serve" : opts.watch ? "watch" : "bundle";
  const mode = opts.mode ?? (command === "bundle" ? "production" : "development");

  // .env 파일 4단계 우선순위로 로드 (#2106). prefix 미지정 시 default `["VITE_", "ZTS_"]`.
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
    "format",
    "platform",
    "target",
    "banner",
    "footer",
    "globalName",
    "publicPath",
    "entryNames",
    "chunkNames",
    "assetNames",
    "jsx",
    "jsxFactory",
    "jsxFragment",
    "jsxImportSource",
    "quotes",
    "preserveModulesRoot",
    "legalComments",
    "sourceRoot",
    "sourcemapMode",
    "jobs",
    "logLevel",
    "logLimit",
    "lineLimit",
    "outputExports",
    "outExtensionJs",
    "metafile",
    "spaFallback",
    "outfile",
    "outdir",
    "outbase",
    "browserslist",
    "tsconfigRaw",
  ];
  for (const key of SCALAR_KEYS) {
    if (opts[key] === undefined && config[key] !== undefined) {
      opts[key] = config[key];
    }
  }

  // boolean default=false → config 가 true 면 적용. CLI 명시 false 를 구분 못 하므로
  // 함수형 config (#2103) 에서 정밀한 우선순위 적용 예정.
  const BOOL_KEYS = [
    "minify",
    "minifyWhitespace",
    "minifyIdentifiers",
    "minifySyntax",
    "sourcemap",
    "sourcemapDebugIds",
    "splitting",
    "flow",
    "experimentalDecorators",
    "emitDecoratorMetadata",
    "keepNames",
    "shimMissingExports",
    "preserveSymlinks",
    "charsetUtf8",
    "asciiOnly",
    "jsxInJs",
    "jsxDev",
    "preserveModules",
    "verbatimModuleSyntax",
    "packagesExternal",
    "allowOverwrite",
  ];
  for (const key of BOOL_KEYS) {
    if (opts[key] === false && config[key] === true) {
      opts[key] = true;
    }
  }
  // sourcesContent / treeShaking / useDefineForClassFields 는 default=true.
  // CLI 가 default 면 config 가 false 일 때 false 로.
  for (const key of ["sourcesContent", "treeShaking", "useDefineForClassFields"]) {
    if (opts[key] === true && config[key] === false) {
      opts[key] = false;
    }
  }

  const ARRAY_KEYS = [
    "entryPoints",
    "external",
    "inject",
    "drop",
    "dropLabels",
    "pure",
    "resolveExtensions",
    "mainFields",
  ];
  for (const key of ARRAY_KEYS) {
    if (opts[key].length === 0 && Array.isArray(config[key]) && config[key].length > 0) {
      opts[key] = [...config[key]];
    }
  }

  for (const key of ["define", "alias", "loader"]) {
    if (config[key] && typeof config[key] === "object") {
      opts[key] = { ...config[key], ...opts[key] };
    }
  }
  mergeServerConfigIntoOpts(opts, config);

  return opts;
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
    } else if (typeof cfg.setup === "function") {
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
    dropConsole: opts.drop.includes("console"),
    dropDebugger: opts.drop.includes("debugger"),
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
    // NAPI 가 tsconfig paths / baseUrl 을 alias 로 변환해 resolver 에 주입하도록 전달.
    tsconfigPath: opts.project,
    tsconfigRaw: opts.tsconfigRaw,
    banner: opts.banner,
    footer: opts.footer,
    globalName: opts.globalName,
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
    jobs: opts.jobs,
    outbase: opts.outbase,
    plugins: plugins.length > 0 ? plugins : undefined,
    // compiler.styledComponents / compiler.emotion 도 bundle 모드에서 forward.
    // 누락 시 `zts.config.json` 의 `compiler` 설정이 silently drop 돼 1st-party transform
    // (autoLabel 등) 이 활성화 안 됨.
    compiler: config?.compiler,
  };

  const result = plugins.length > 0 ? await build(buildOpts) : buildSync(buildOpts);

  if (result.errors.length > 0 && opts.logLevel !== "silent") {
    for (const err of result.errors) {
      const loc = err.location ? `${err.location.file}: ` : "";
      console.error(`error: ${loc}${err.text}`);
    }
  }
  if (result.warnings.length > 0 && opts.logLevel !== "silent" && opts.logLevel !== "error") {
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

  return result;
}

// ─── Watch 모드 ───

async function runWatch(opts, config) {
  const { watch } = await import("node:fs");

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
            ? { type: "rebuild", success: false, error: result.errors[0]?.text }
            : { type: "rebuild", success: true, files, ms: elapsed };
        console.log(JSON.stringify(event));
      } else if (opts.logLevel !== "silent") {
        if (result.errors.length === 0) {
          console.error(`[watch] rebuilt in ${elapsed}ms`);
        }
      }
    } catch (err) {
      if (opts.watchJson) {
        console.log(JSON.stringify({ type: "rebuild", success: false, error: String(err) }));
      } else if (opts.logLevel !== "silent") {
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

  if (opts.watchJson) {
    console.log(JSON.stringify({ type: "ready" }));
  } else if (opts.logLevel !== "silent") {
    console.error("[watch] watching for changes...");
  }

  // 파일 감시
  const watchDirs = new Set();
  for (const entry of opts.entryPoints) {
    watchDirs.add(dirname(resolve(entry)));
  }
  // config/.env 파일 변경 감지를 위해 cwd / envDir / config 디렉토리 추가.
  const restartTriggers = computeRestartTriggers(opts);
  for (const dir of restartTriggers.dirs) watchDirs.add(dir);

  for (const dir of watchDirs) {
    watch(dir, { recursive: true }, (_event, filename) => {
      if (!filename) return;
      // node_modules, .git, 출력 디렉토리 무시
      if (filename.includes("node_modules") || filename.includes(".git")) return;
      if (opts.outdir && filename.startsWith(basename(resolve(opts.outdir)))) return;

      if (restartTriggers.matches(filename)) {
        emitRestart(opts, "config 또는 .env 파일 변경 감지");
        return;
      }

      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(rebuild, opts.watchDelay);
    });
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

  const mode = opts.mode ?? (opts.serve || opts.watch ? "development" : "production");
  // mode-specific config (`zts.config.${mode}.{ext}`) 변경도 restart trigger (#2110).
  const modeConfig = explicitConfig ? null : findModeConfigPath(configSearchDir, mode);
  if (modeConfig) dirs.add(dirname(modeConfig));

  const configBase = autoConfig ? basename(autoConfig) : null;
  const modeConfigBase = modeConfig ? basename(modeConfig) : null;
  const envBases = new Set([".env", ".env.local", `.env.${mode}`, `.env.${mode}.local`]);

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

function emitRestart(opts, reason) {
  return emitRestartAfter(opts, reason, null);
}

async function emitRestartAfter(opts, reason, beforeSpawn) {
  if (opts.watchJson) {
    console.log(JSON.stringify({ type: "restart", reason }));
  } else if (opts.logLevel !== "silent") {
    console.error(`[watch] ${reason} — restarting CLI...`);
  }
  if (beforeSpawn) await beforeSpawn();
  // 자식 프로세스 spawn 후 종료 — 새 프로세스가 fresh config/env 로 시작.
  // stdio inherit 으로 부모의 출력 스트림을 그대로 이어받는다.
  const { spawn } = await import("node:child_process");
  const child = spawn(process.argv[0], process.argv.slice(1), {
    stdio: "inherit",
    env: process.env,
  });
  child.on("exit", (code) => process.exit(code ?? 0));
  child.on("error", (err) => {
    console.error(`[watch] restart failed: ${err}`);
    process.exit(1);
  });
}

// ─── Serve 모드 ───

async function runServe(opts, config, { appDev = null } = {}) {
  const isBun = typeof globalThis.Bun !== "undefined";
  const hmr = appDev ? createAppDevHmrChannel() : null;
  let serverHandle = null;
  const mimeTypes = {
    ".html": "text/html",
    ".js": "application/javascript",
    ".mjs": "application/javascript",
    ".css": "text/css",
    ".json": "application/json",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".map": "application/json",
  };

  // 번들 모드면 먼저 빌드
  if (opts.bundle && opts.entryPoints.length > 0) {
    opts.outdir = opts.outdir || join(opts.serveDir, ".zts-serve");
    const bundleResult = await runBundle(opts, config);
    if (appDev) {
      appDev.injectBundleCssLinks(bundleResult);
      await appDev.afterBundle();
    }

    // watch도 같이
    if (!opts.watch) {
      opts.watch = true;
    }
  }

  const serveDir = resolve(opts.outdir || opts.serveDir);
  const base = normalizeBase(opts.base ?? "/");

  function handleRequest(reqUrl, accept = "") {
    let pathname = new URL(reqUrl, "http://localhost").pathname;
    if (appDev && pathname === APP_DEV_HMR_CLIENT_PATH) {
      return {
        status: 200,
        body: APP_DEV_HMR_CLIENT,
        type: "application/javascript",
      };
    }
    if (base && base !== "/" && pathname.startsWith(base)) {
      pathname = "/" + pathname.slice(base.length);
    }
    if (pathname === "/") pathname = "/index.html";

    let filePath = join(serveDir, pathname);
    if (!existsSync(filePath)) {
      const fallback = normalizeSpaFallback(opts.spaFallback);
      if (!fallback || !requestAcceptsHtml(accept) || looksLikeAssetPath(pathname)) {
        return { status: 404, body: "Not Found", type: "text/plain" };
      }
      const fallbackPath = resolve(serveDir, fallback);
      const insideServeDir =
        fallbackPath === serveDir || fallbackPath.startsWith(`${serveDir}${sep}`);
      if (!insideServeDir || !existsSync(fallbackPath)) {
        return { status: 404, body: "Not Found", type: "text/plain" };
      }
      filePath = fallbackPath;
    }

    const ext = extname(filePath);
    const type = mimeTypes[ext] || "application/octet-stream";
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
          return new Response("Upgrade required", { status: 426 });
        }
        // 프록시 처리
        for (const [prefix, target] of Object.entries(opts.proxy)) {
          if (url.pathname.startsWith(prefix)) {
            return fetch(target + url.pathname.slice(prefix.length) + url.search);
          }
        }

        const { status, body, type } = handleRequest(req.url, req.headers.get("accept") ?? "");
        return new Response(body, {
          status,
          headers: {
            "Content-Type": type,
            "Access-Control-Allow-Origin": "*",
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
      const url = new URL(req.url, `${useTls ? "https" : "http"}://${req.headers.host}`);
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
            res.end("Bad Gateway");
          }
          return;
        }
      }

      const { status, body, type } = handleRequest(req.url, req.headers.accept ?? "");
      res.writeHead(status, {
        "Content-Type": type,
        "Access-Control-Allow-Origin": "*",
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
      server.on("upgrade", (req, socket) => {
        const pathname = new URL(req.url, `${useTls ? "https" : "http"}://${req.headers.host}`)
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
            server.off("listening", onListening);
            rejectListen(err);
          };
          const onListening = () => {
            server.off("error", onError);
            resolveListen(server);
          };
          server.once("error", onError);
          server.once("listening", onListening);
          server.listen(port, opts.host);
        }),
    );
  }

  async function closeServerForRestart() {
    if (!serverHandle) return;
    if (typeof serverHandle.stop === "function") {
      await serverHandle.stop();
      return;
    }
    if (typeof serverHandle.close === "function") {
      await new Promise((resolveClose, rejectClose) => {
        serverHandle.close((err) => (err ? rejectClose(err) : resolveClose()));
      });
    }
  }

  const protocol = useTls ? "https" : "http";
  if (opts.logLevel !== "silent") {
    console.error(`[serve] ${protocol}://${opts.host}:${opts.port}`);
  }

  // watch 시작 (번들 모드일 때)
  if (opts.watch && opts.bundle) {
    const { watch: fsWatch } = await import("node:fs");
    const outdirAbs = opts.outdir ? resolve(opts.outdir) : null;
    const outdirPrefix = outdirAbs ? `${outdirAbs}${sep}` : null;
    let debounceTimer = null;
    let rebuilding = false;
    const dirty = new Set();

    async function rebuildAppDevCss(changedPath) {
      await appDev.afterBundle({ changedPath });
      hmr?.broadcast({
        type: HMR_MSG.CssUpdate,
        href: appDev.hrefFor(changedPath),
        timestamp: Date.now(),
      });
      if (opts.logLevel !== "silent") console.error("[serve] css updated");
    }

    async function rebuildAppDevFull(dirtyPaths = null) {
      const prepared = await appDev.prepare(dirtyPaths);
      opts.entryPoints = [prepared.entryPath];
      const bundleResult = await runBundle(opts, config);
      appDev.injectBundleCssLinks(bundleResult);
      await appDev.afterBundle();
      hmr?.broadcast({ type: HMR_MSG.FullReload, timestamp: Date.now() });
      if (opts.logLevel !== "silent") console.error("[serve] rebuilt");
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
            if (opts.logLevel !== "silent") console.error("[serve] rebuilt");
            continue;
          }
          // 변경된 path 들이 모두 CSS-only 면 incremental 처리, 그 외엔 full reload.
          const allCssOnly = paths.every(
            (p) => appDev.isCssOnlyChange(p) || appDev.isPostcssConfig(p),
          );
          if (allCssOnly) {
            // postcss config 변경이 섞이면 changedPath 미지정 → 전체 재처리.
            const cssChanges = paths.filter(
              (p) => p.endsWith(".css") && !appDev.isPostcssConfig(p),
            );
            // 단일 non-module `.scss/.sass` 변경 → 그 파일만 재컴파일하고 outdir mirror
            // 후 CssUpdate broadcast (BACKLOG #71). full pipeline rebuild + cpSync 회피.
            if (paths.length === 1 && appDev.isSassOnlyChange(paths[0])) {
              const href = await appDev.rebuildScssIncremental(paths[0]);
              if (href) {
                hmr?.broadcast({ type: HMR_MSG.CssUpdate, href, timestamp: Date.now() });
                if (opts.logLevel !== "silent") console.error("[serve] sass updated");
              } else {
                await rebuildAppDevFull();
              }
            } else if (cssChanges.length === 1 && paths.length === 1) {
              await rebuildAppDevCss(cssChanges[0]);
            } else {
              await appDev.afterBundle();
              hmr?.broadcast({ type: HMR_MSG.CssUpdate, timestamp: Date.now() });
              if (opts.logLevel !== "silent") console.error("[serve] css updated");
            }
          } else {
            await rebuildAppDevFull(paths);
          }
        }
      } catch (err) {
        console.error("[serve] rebuild error:", err);
        hmr?.broadcast({ type: HMR_MSG.FullReload, timestamp: Date.now() });
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
      fsWatch(dir, { recursive: true }, (_event, filename) => {
        if (!filename || filename.includes("node_modules") || filename.includes(".git")) return;
        const absPath = resolve(dir, filename);
        if (outdirAbs && (absPath === outdirAbs || absPath.startsWith(outdirPrefix))) return;
        if (restartTriggers.matches(filename)) {
          void emitRestartAfter(opts, "config 또는 .env 파일 변경 감지", closeServerForRestart);
          return;
        }
        dirty.add(absPath);
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(drain, opts.watchDelay);
      });
    }
  }

  // open browser
  if (opts.open) {
    const url = `${protocol}://${opts.host === "0.0.0.0" ? "localhost" : opts.host}:${opts.port}`;
    const { exec } = await import("node:child_process");
    const cmd =
      process.platform === "darwin" ? "open" : process.platform === "win32" ? "start" : "xdg-open";
    exec(`${cmd} ${url}`);
  }
}

// ─── Build dispatch ───

/**
 * 단일/워크스페이스 흐름 공통 dispatch — 모드별 (`runServe`/`runWatch`/`runBundle`/`runTranspile`)
 * 진입점 호출 + bundle 의 user error 카운트 반환. caller (main / runWorkspace) 가 exit 처리.
 *
 * 반환 형태가 다른 두 호출 사이트의 drift 를 차단 — 모드 분기/추가가 1곳에서 끝남.
 */
async function dispatchBuild(opts, config, configEnv, dotenvVars) {
  if (opts.appCommand === "build") {
    const result = await runAppBuild(opts, config, configEnv, dotenvVars);
    return { errors: result.errors.length };
  }
  if (opts.appCommand === "dev") {
    await runAppDev(opts, config, configEnv, dotenvVars);
    return { errors: 0 };
  }
  if (opts.appCommand === "preview") {
    await runAppPreview(opts);
    return { errors: 0 };
  }
  if (opts.serve) {
    await runServe(opts, config);
    return { errors: 0 };
  }
  if (opts.watch) {
    await runWatch(opts, config);
    return { errors: 0 };
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
 * `zts.workspace.{ts,...}` 가 발견되면 단일 build 대신 워크스페이스 fan-out 으로 전환.
 *
 * 흐름:
 *  1. workspace 파일 로드 → `identifyWorkspaceEntries` (config 로드 없는 식별 단계)
 *  2. `--workspace=<name>` 필터 즉시 적용 — 비싼 TS config 로드를 N-1 회 회피
 *  3. 필터 후 entries 의 config 를 `Promise.all` 로 병렬 로드
 *  4. root config (`zts.config.*`) 가 같은 디렉토리에 있으면 모든 entry 가 상속
 *  5. 각 entry 마다: opts clone → entry config + root config 머지 → entry.cwd 기준 path 정규화 → build
 *
 * `serve`/`watch` 는 워크스페이스에서 의미가 모호 (어느 entry 를 watch?) — 다중 entry 시 reject.
 * `--workspace=<name>` 필터로 단일 entry 만 남기면 serve/watch 허용.
 */
async function runWorkspace(opts, workspacePath) {
  const command = opts.serve ? "serve" : opts.watch ? "watch" : "bundle";
  const mode = opts.mode ?? (command === "bundle" ? "production" : "development");
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

  if (opts.logLevel !== "silent") {
    const filterMsg = opts.workspace ? ` (filtered by name='${opts.workspace}')` : "";
    console.error(
      `@zts/core: workspace ${workspacePath} → ${resolved.length} entr${
        resolved.length === 1 ? "y" : "ies"
      }${filterMsg}`,
    );
  }

  let exitCode = 0;
  for (const w of resolved) {
    if (opts.logLevel !== "silent") {
      console.error(`\n--- workspace: ${w.name} (cwd=${w.cwd}, source=${w.source}) ---`);
    }
    const merged = rootConfig ? mergeUserConfigs(rootConfig, w.config) : w.config;

    if (opts.logLevel !== "silent" && Object.keys(w.config).length > 0) {
      warnUnknownKeys(w.config, KNOWN_CONFIG_KEYS, { sourceLabel: `workspace[${w.name}]` });
    }

    const subOpts = buildSubOpts(opts, w, merged);

    if (subOpts.entryPoints.length === 0 && !subOpts.stdin && !subOpts.serve) {
      if (opts.logLevel !== "silent") {
        console.error(`@zts/core: workspace '${w.name}' has no entryPoints — skipping`);
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

  if ((opts.appCommand === "dev" || opts.appCommand === "build") && !opts.envDir) {
    opts.envDir = resolve(opts.appRoot ?? ".");
  }

  // workspace 자동 탐색 — `--workspace-config <path>` 명시 또는 cwd 의 zts.workspace.*
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
    if (opts.logLevel !== "silent") {
      warnUnknownKeys(config, KNOWN_CONFIG_KEYS, { sourceLabel: "zts.config" });
    }
    mergeConfigIntoOpts(opts, config);
  }
  applyServerDefaults(opts);

  // import.meta.env.* + import.meta.env.MODE/PROD/DEV/SSR 정적 치환을 define 으로
  // 자동 주입. 사용자 명시 define 이 동일 키를 덮어쓰면 그대로 우선.
  const envDefine = envToDefine(
    dotenvVars,
    configEnv.mode,
    normalizeBase(opts.base ?? opts.publicPath ?? "/"),
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
