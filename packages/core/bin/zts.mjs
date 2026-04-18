#!/usr/bin/env node

/**
 * ZTS CLI — Node.js/Bun 호환 CLI
 *
 * 내부적으로 @zts/core NAPI 바인딩을 사용하여 트랜스파일/번들링을 수행.
 * Watch/Serve는 JS 레이어에서 구현.
 */

// Node.js: dist/index.js, Bun: index.ts 직접
let coreModule;
try {
  coreModule = await import("../dist/index.js");
} catch {
  coreModule = await import("../index.ts");
}
const { init, transpile, build, buildSync } = coreModule;
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from "node:fs";
import { resolve, dirname, basename, extname, join } from "node:path";
import { createServer } from "node:http";
import { createServer as createHttpsServer } from "node:https";

// ─── CLI 인자 파싱 ───

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    entryPoints: [],
    outfile: null,
    outdir: null,
    bundle: false,
    watch: false,
    watchJson: false,
    watchDelay: 100,
    serve: false,
    serveDir: ".",
    port: 12300,
    host: "localhost",
    open: false,
    proxy: {},
    format: undefined,
    platform: undefined,
    minify: false,
    minifyWhitespace: false,
    minifyIdentifiers: false,
    minifySyntax: false,
    sourcemap: false,
    sourcemapDebugIds: false,
    sourcesContent: true,
    splitting: false,
    metafile: undefined,
    analyze: false,
    treeShaking: true,
    external: [],
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
    charsetUtf8: false,
    asciiOnly: false,
    quotes: undefined,
    inject: [],
    plugins: [],
    pluginPaths: [],
    stdin: false,
    project: undefined,
    logLevel: "info",
    jobs: undefined,
    clean: false,
    preserveModules: false,
    preserveModulesRoot: undefined,
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
    drop: [],
    certfile: undefined,
    keyfile: undefined,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    // stdin
    if (arg === "-") {
      opts.stdin = true;
      continue;
    }

    // positional (파일 경로)
    if (!arg.startsWith("-")) {
      opts.entryPoints.push(arg);
      continue;
    }

    // flags
    if (arg === "--bundle") {
      opts.bundle = true;
      continue;
    }
    if (arg === "-w" || arg === "--watch") {
      opts.watch = true;
      continue;
    }
    if (arg === "--watch-json") {
      opts.watch = true;
      opts.watchJson = true;
      continue;
    }
    if (arg === "--serve") {
      opts.serve = true;
      // 다음 인자가 디렉토리 경로면 serveDir로 사용
      if (i + 1 < args.length && !args[i + 1].startsWith("-")) {
        opts.serveDir = args[++i];
      }
      continue;
    }
    if (arg === "--open") {
      opts.open = true;
      continue;
    }
    if (arg === "--minify") {
      opts.minify = true;
      continue;
    }
    if (arg === "--sourcemap") {
      opts.sourcemap = true;
      continue;
    }
    if (arg === "--sourcemap-debug-ids") {
      opts.sourcemapDebugIds = true;
      continue;
    }
    if (arg === "--splitting") {
      opts.splitting = true;
      continue;
    }
    if (arg === "--metafile") {
      opts.metafile = "meta.json";
      continue;
    }
    if (arg === "--analyze") {
      opts.analyze = true;
      opts.metafile = "meta.json";
      continue;
    }
    if (arg === "--flow") {
      opts.flow = true;
      continue;
    }
    if (arg === "--experimental-decorators") {
      opts.experimentalDecorators = true;
      continue;
    }
    if (arg === "--keep-names") {
      opts.keepNames = true;
      continue;
    }
    if (arg === "--shim-missing-exports") {
      opts.shimMissingExports = true;
      continue;
    }
    if (arg === "--ascii-only") {
      opts.asciiOnly = true;
      continue;
    }
    if (arg === "--preserve-symlinks") {
      continue;
    } // TODO
    if (arg === "--preserve-modules") {
      opts.preserveModules = true;
      continue;
    }
    if (arg === "--jsx-dev") {
      opts.jsxDev = true;
      continue;
    }
    if (arg === "--clean") {
      opts.clean = true;
      continue;
    }
    if (arg === "--minify-whitespace") {
      opts.minifyWhitespace = true;
      continue;
    }
    if (arg === "--minify-identifiers") {
      opts.minifyIdentifiers = true;
      continue;
    }
    if (arg === "--minify-syntax") {
      opts.minifySyntax = true;
      continue;
    }

    // --key=value
    if (arg.startsWith("--format=")) {
      opts.format = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--platform=")) {
      opts.platform = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--jsx=")) {
      opts.jsx = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--jsx-factory=")) {
      opts.jsxFactory = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--jsx-fragment=")) {
      opts.jsxFragment = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--jsx-import-source=")) {
      opts.jsxImportSource = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--global-name=")) {
      opts.globalName = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--public-path=")) {
      opts.publicPath = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--banner:js=")) {
      opts.banner = arg.split("=").slice(1).join("=");
      continue;
    }
    if (arg.startsWith("--footer:js=")) {
      opts.footer = arg.split("=").slice(1).join("=");
      continue;
    }
    if (arg.startsWith("--entry-names=")) {
      opts.entryNames = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--chunk-names=")) {
      opts.chunkNames = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--asset-names=")) {
      opts.assetNames = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--quotes=")) {
      opts.quotes = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--log-level=")) {
      opts.logLevel = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--charset=")) {
      if (arg.split("=")[1] === "utf8") opts.charsetUtf8 = true;
      continue;
    }
    if (arg.startsWith("--sources-content=")) {
      opts.sourcesContent = arg.split("=")[1] !== "false";
      continue;
    }
    if (arg.startsWith("--use-define-for-class-fields=")) {
      opts.useDefineForClassFields = arg.split("=")[1] !== "false";
      continue;
    }
    if (arg.startsWith("--legal-comments=")) {
      opts.legalComments = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--preserve-modules-root=")) {
      opts.preserveModulesRoot = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--out-extension:.js=")) {
      opts.outExtensionJs = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--source-root=")) {
      opts.sourceRoot = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--watch-delay=")) {
      opts.watchDelay = parseInt(arg.split("=")[1]);
      continue;
    }
    if (arg.startsWith("--rn-platform=")) {
      opts.rnPlatform = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--port=")) {
      opts.port = parseInt(arg.split("=")[1]);
      continue;
    }
    if (arg.startsWith("--host=")) {
      opts.host = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--metafile=")) {
      opts.metafile = arg.split("=")[1];
      continue;
    }
    if (arg.startsWith("--jobs=")) {
      opts.jobs = parseInt(arg.split("=")[1]);
      continue;
    }

    // --key value
    if (arg === "-o" || arg === "--outfile") {
      opts.outfile = args[++i];
      continue;
    }
    if (arg === "--outdir") {
      opts.outdir = args[++i];
      continue;
    }
    if (arg === "--port") {
      opts.port = parseInt(args[++i]);
      continue;
    }
    if (arg === "--host") {
      opts.host = args[++i] || "0.0.0.0";
      continue;
    }
    if (arg === "--certfile") {
      opts.certfile = args[++i];
      continue;
    }
    if (arg === "--keyfile") {
      opts.keyfile = args[++i];
      continue;
    }
    if (arg === "-p" || arg === "--project" || arg === "--tsconfig-path") {
      // `-p`, `--project` (tsc 전통), `--tsconfig-path` (NAPI `tsconfigPath` 와 이름 통일)
      opts.project = args[++i];
      continue;
    }
    if (arg.startsWith("--tsconfig-path=")) {
      opts.project = arg.slice("--tsconfig-path=".length);
      continue;
    }
    if (arg === "--plugin") {
      opts.pluginPaths.push(args[++i]);
      continue;
    }

    // repeatable
    if (arg === "--external") {
      opts.external.push(args[++i]);
      continue;
    }
    if (arg.startsWith("--external=")) {
      opts.external.push(arg.split("=")[1]);
      continue;
    }
    if (arg.startsWith("--inject:")) {
      opts.inject.push(arg.split(":")[1]);
      continue;
    }
    if (arg.startsWith("--define:")) {
      const [k, ...v] = arg.slice("--define:".length).split("=");
      opts.define[k] = v.join("=");
      continue;
    }
    if (arg.startsWith("--alias:")) {
      const [k, ...v] = arg.slice("--alias:".length).split("=");
      opts.alias[k] = v.join("=");
      continue;
    }
    if (arg.startsWith("--loader:")) {
      const [ext, type] = arg.slice("--loader:".length).split("=");
      opts.loader[ext] = type;
      continue;
    }
    if (arg.startsWith("--drop=")) {
      opts.drop.push(arg.split("=")[1]);
      continue;
    }
    if (arg.startsWith("--proxy")) {
      const [path, target] =
        arg.split("=").length > 1
          ? [arg.split(" ")[0].replace("--proxy", "").replace("=", ""), args[i].split("=")[1]]
          : [args[++i]?.split("=")[0], args[i]?.split("=")[1]];
      if (path && target) opts.proxy[path] = target;
      continue;
    }
    if (arg.startsWith("--resolve-extensions=")) {
      opts.resolveExtensions = arg.split("=")[1].split(",");
      continue;
    }
    if (arg.startsWith("--main-fields=")) {
      opts.mainFields = arg.split("=")[1].split(",");
      continue;
    }

    // unknown
    if (opts.logLevel !== "silent") {
      console.error(`warning: unknown option '${arg}'`);
    }
  }

  // jsx-dev 단축어
  if (opts.jsxDev) opts.jsx = "automatic-dev";

  // drop 처리
  for (const d of opts.drop) {
    if (d === "console") opts.define["console.log"] = "undefined";
    if (d === "debugger") opts.define["debugger"] = "";
  }

  return opts;
}

// ─── tsconfig.json 로드 ───

function loadTsConfig(opts) {
  // --project/--tsconfig-path 로 지정하거나 자동 탐색
  let tsconfigPath = opts.project;
  // 경로가 디렉토리면 내부의 tsconfig.json 을 대상 파일로 보정 (NAPI `loadFromPath` 와 동일 규칙).
  if (tsconfigPath && existsSync(tsconfigPath)) {
    try {
      const { statSync } = require("node:fs");
      if (statSync(tsconfigPath).isDirectory()) {
        tsconfigPath = join(tsconfigPath, "tsconfig.json");
      }
    } catch {}
  }
  if (!tsconfigPath) {
    // 엔트리 파일 기준으로 상위 디렉토리 탐색
    const startDir =
      opts.entryPoints.length > 0 ? dirname(resolve(opts.entryPoints[0])) : process.cwd();
    let dir = startDir;
    while (true) {
      const candidate = join(dir, "tsconfig.json");
      if (existsSync(candidate)) {
        tsconfigPath = candidate;
        break;
      }
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }

  if (!tsconfigPath || !existsSync(tsconfigPath)) return;

  try {
    // JSON with comments 파싱 — 문자열 리터럴 내의 // 를 보호
    const raw = readFileSync(resolve(tsconfigPath), "utf8");
    const stripped = raw.replace(/"(?:[^"\\]|\\.)*"|\/\/.*$|\/\*[\s\S]*?\*\//gm, (m) =>
      m.startsWith('"') ? m : "",
    );
    const config = JSON.parse(stripped);
    const co = config.compilerOptions;
    if (!co) return;

    // CLI 옵션이 명시적으로 지정되지 않은 경우에만 tsconfig 값 적용
    if (co.experimentalDecorators && !opts.experimentalDecorators) {
      opts.experimentalDecorators = true;
    }
    if (co.emitDecoratorMetadata) {
      opts.emitDecoratorMetadata = true;
    }
    if (co.useDefineForClassFields === false) {
      opts.useDefineForClassFields = false;
    }
    // verbatimModuleSyntax (TS 5.0+): 미사용 값 import 보존. CLI 이 설정 안 했으면 tsconfig 반영.
    if (co.verbatimModuleSyntax === true && opts.verbatimModuleSyntax === undefined) {
      opts.verbatimModuleSyntax = true;
    }

    // jsx: "react" → classic, "react-jsx" → automatic, "react-jsxdev" → automatic-dev
    if (co.jsx && !opts.jsx) {
      const jsxMap = {
        react: "classic",
        "react-jsx": "automatic",
        "react-jsxdev": "automatic-dev",
        preserve: undefined, // ZTS가 기본적으로 preserve하지 않으므로 무시
      };
      const mapped = jsxMap[co.jsx];
      if (mapped) opts.jsx = mapped;
    }

    if (co.jsxFactory && !opts.jsxFactory) opts.jsxFactory = co.jsxFactory;
    if (co.jsxFragmentFactory && !opts.jsxFragment) opts.jsxFragment = co.jsxFragmentFactory;
    if (co.jsxImportSource && !opts.jsxImportSource) opts.jsxImportSource = co.jsxImportSource;

    // target → ES 다운레벨 (transpile의 target 옵션)
    if (co.target && !opts.target) {
      const targetMap = {
        es5: "es5",
        es6: "es2015",
        es2015: "es2015",
        es2016: "es2016",
        es2017: "es2017",
        es2018: "es2018",
        es2019: "es2019",
        es2020: "es2020",
        es2021: "es2021",
        es2022: "es2022",
        es2023: "es2023",
        es2024: "es2024",
        esnext: "esnext",
      };
      opts.target = targetMap[co.target.toLowerCase()] || undefined;
    }
  } catch {
    // tsconfig 파싱 실패는 무시 (경고만)
    if (opts.logLevel !== "silent") {
      console.error(`warning: failed to parse ${tsconfigPath}`);
    }
  }
}

// ─── 파일 출력 ───

function writeOutputFiles(outputFiles, outfile, outdir) {
  if (outfile) {
    mkdirSync(dirname(resolve(outfile)), { recursive: true });
    writeFileSync(resolve(outfile), outputFiles[0].text);
    if (outputFiles.length > 1) {
      // sourcemap
      writeFileSync(resolve(outfile + ".map"), outputFiles[1].text);
    }
  } else if (outdir) {
    mkdirSync(resolve(outdir), { recursive: true });
    for (const file of outputFiles) {
      const outPath = join(resolve(outdir), basename(file.path));
      writeFileSync(outPath, file.text);
    }
  }
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
    experimentalDecorators: opts.experimentalDecorators,
    useDefineForClassFields: opts.useDefineForClassFields,
    verbatimModuleSyntax: opts.verbatimModuleSyntax,
    asciiOnly: opts.asciiOnly,
    charsetUtf8: opts.charsetUtf8,
    quotes: opts.quotes,
    format: opts.format,
    platform: opts.platform,
    dropConsole: opts.drop.includes("console"),
    dropDebugger: opts.drop.includes("debugger"),
    target: opts.target,
  });

  if (opts.outfile) {
    mkdirSync(dirname(resolve(opts.outfile)), { recursive: true });
    writeFileSync(resolve(opts.outfile), result.code);
    if (result.map) {
      writeFileSync(resolve(opts.outfile + ".map"), result.map);
    }
  } else if (opts.outdir) {
    mkdirSync(resolve(opts.outdir), { recursive: true });
    const name = basename(opts.entryPoints[0]).replace(/\.[^.]+$/, ".js");
    writeFileSync(join(resolve(opts.outdir), name), result.code);
  } else {
    process.stdout.write(result.code);
  }
}

// ─── Bundle 모드 ───

async function runBundle(opts) {
  // 플러그인 로드
  const plugins = [];
  for (const pluginPath of opts.pluginPaths) {
    const absPath = resolve(pluginPath);
    const mod = await import(absPath);
    const config = mod.default || mod;
    if (config.plugins) {
      plugins.push(...config.plugins);
    } else if (typeof config.setup === "function") {
      plugins.push(config);
    }
  }

  const buildOpts = {
    entryPoints: opts.entryPoints.map((e) => resolve(e)),
    format: opts.format,
    platform: opts.platform,
    external: opts.external,
    minify: opts.minify,
    minifyWhitespace: opts.minifyWhitespace,
    minifyIdentifiers: opts.minifyIdentifiers,
    minifySyntax: opts.minifySyntax,
    splitting: opts.splitting,
    sourcemap: opts.sourcemap,
    sourcemapDebugIds: opts.sourcemapDebugIds,
    sourcesContent: opts.sourcesContent,
    treeShaking: opts.treeShaking,
    metafile: !!opts.metafile,
    keepNames: opts.keepNames,
    shimMissingExports: opts.shimMissingExports,
    flow: opts.flow,
    jsxInJs: opts.jsxInJs,
    charsetUtf8: opts.charsetUtf8,
    useDefineForClassFields: opts.useDefineForClassFields,
    experimentalDecorators: opts.experimentalDecorators,
    verbatimModuleSyntax: opts.verbatimModuleSyntax,
    banner: opts.banner,
    footer: opts.footer,
    globalName: opts.globalName,
    publicPath: opts.publicPath,
    entryNames: opts.entryNames,
    chunkNames: opts.chunkNames,
    assetNames: opts.assetNames,
    jsx: opts.jsx,
    jsxFactory: opts.jsxFactory,
    jsxFragment: opts.jsxFragment,
    jsxImportSource: opts.jsxImportSource,
    inject: opts.inject.map((p) => resolve(p)),
    jobs: opts.jobs,
    plugins: plugins.length > 0 ? plugins : undefined,
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
    writeOutputFiles(result.outputFiles, opts.outfile, opts.outdir);
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

async function runWatch(opts) {
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
      const result = await runBundle(opts);
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

  for (const dir of watchDirs) {
    watch(dir, { recursive: true }, (_event, filename) => {
      if (!filename) return;
      // node_modules, .git, 출력 디렉토리 무시
      if (filename.includes("node_modules") || filename.includes(".git")) return;
      if (opts.outdir && filename.startsWith(basename(resolve(opts.outdir)))) return;

      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(rebuild, opts.watchDelay);
    });
  }
}

// ─── Serve 모드 ───

async function runServe(opts) {
  const isBun = typeof globalThis.Bun !== "undefined";
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
    await runBundle(opts);

    // watch도 같이
    if (!opts.watch) {
      opts.watch = true;
    }
  }

  const serveDir = resolve(opts.outdir || opts.serveDir);

  function handleRequest(reqUrl) {
    let pathname = new URL(reqUrl, "http://localhost").pathname;
    if (pathname === "/") pathname = "/index.html";

    const filePath = join(serveDir, pathname);
    if (!existsSync(filePath)) {
      return { status: 404, body: "Not Found", type: "text/plain" };
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
      fetch(req) {
        // 프록시 처리
        const url = new URL(req.url);
        for (const [prefix, target] of Object.entries(opts.proxy)) {
          if (url.pathname.startsWith(prefix)) {
            return fetch(target + url.pathname.slice(prefix.length) + url.search);
          }
        }

        const { status, body, type } = handleRequest(req.url);
        return new Response(body, {
          status,
          headers: {
            "Content-Type": type,
            "Access-Control-Allow-Origin": "*",
          },
        });
      },
    };
    if (useTls) {
      serveOpts.tls = {
        cert: globalThis.Bun.file(opts.certfile),
        key: globalThis.Bun.file(opts.keyfile),
      };
    }
    globalThis.Bun.serve(serveOpts);
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

      const { status, body, type } = handleRequest(req.url);
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
    server.listen(opts.port, opts.host);
  }

  const protocol = useTls ? "https" : "http";
  if (opts.logLevel !== "silent") {
    console.error(`[serve] ${protocol}://${opts.host}:${opts.port}`);
  }

  // watch 시작 (번들 모드일 때)
  if (opts.watch && opts.bundle) {
    const { watch: fsWatch } = await import("node:fs");
    let debounceTimer = null;

    const watchDirs = new Set();
    for (const entry of opts.entryPoints) {
      watchDirs.add(dirname(resolve(entry)));
    }

    for (const dir of watchDirs) {
      fsWatch(dir, { recursive: true }, (_event, filename) => {
        if (!filename || filename.includes("node_modules") || filename.includes(".git")) return;
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(async () => {
          try {
            await runBundle(opts);
            if (opts.logLevel !== "silent") console.error("[serve] rebuilt");
          } catch (err) {
            console.error("[serve] rebuild error:", err);
          }
        }, opts.watchDelay);
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

// ─── Main ───

async function main() {
  const opts = parseArgs(process.argv);

  if (opts.entryPoints.length === 0 && !opts.stdin && !opts.serve) {
    console.error("Usage: zts [options] <file.ts>");
    console.error("       zts --bundle <entry.ts> -o out.js");
    console.error("       zts --serve --bundle <entry.ts>");
    process.exit(1);
  }

  // tsconfig.json 자동 로드 (CLI 옵션보다 낮은 우선순위)
  loadTsConfig(opts);

  init();

  try {
    if (opts.serve) {
      await runServe(opts);
    } else if (opts.watch) {
      await runWatch(opts);
    } else if (opts.bundle) {
      const result = await runBundle(opts);
      if (result.errors.length > 0) process.exit(1);
    } else {
      await runTranspile(opts);
    }
  } catch (err) {
    console.error(`error: ${err.message}`);
    process.exit(1);
  }
}

main();
