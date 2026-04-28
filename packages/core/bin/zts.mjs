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
const {
  init,
  transpile,
  build,
  buildSync,
  envToDefine,
  findConfigPath,
  findModeConfigPath,
  importAndResolveDefault,
  loadConfig,
  loadEnv,
  mergeUserConfigs,
} = coreModule;
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
    configPath: undefined, // --config <path> 명시 시 자동 탐색 우회
    mode: undefined, // --mode <name> 함수형 config / mode 별 config 머지 (#2110) 에서 사용
    envPrefixes: undefined, // --env-prefix=VITE_,ZTS_ — undefined 면 loadEnv default 사용
    envDir: undefined, // --env-dir <path> — undefined 면 cwd
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
    if (arg === "--config") {
      opts.configPath = args[++i];
      continue;
    }
    if (arg.startsWith("--config=")) {
      opts.configPath = arg.slice("--config=".length);
      continue;
    }
    if (arg === "--mode") {
      opts.mode = args[++i];
      continue;
    }
    if (arg.startsWith("--mode=")) {
      opts.mode = arg.slice("--mode=".length);
      continue;
    }
    if (arg === "--env-prefix") {
      opts.envPrefixes = args[++i].split(",").filter(Boolean);
      continue;
    }
    if (arg.startsWith("--env-prefix=")) {
      opts.envPrefixes = arg.slice("--env-prefix=".length).split(",").filter(Boolean);
      continue;
    }
    if (arg === "--env-dir") {
      opts.envDir = args[++i];
      continue;
    }
    if (arg.startsWith("--env-dir=")) {
      opts.envDir = arg.slice("--env-dir=".length);
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
    tsconfigPath: opts.project,
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
  const configPath = explicit ?? findConfigPath(process.cwd());

  const command = opts.serve ? "serve" : opts.watch ? "watch" : "bundle";
  const mode = opts.mode ?? (command === "bundle" ? "production" : "development");

  // .env 파일 4단계 우선순위로 로드 (#2106). prefix 미지정 시 default `["VITE_", "ZTS_"]`.
  const envDir = opts.envDir ? resolve(opts.envDir) : process.cwd();
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
  const modeConfigPath = explicit ? null : findModeConfigPath(process.cwd(), mode);

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
    "jobs",
    "outExtensionJs",
    "metafile",
    "outfile",
    "outdir",
    "outbase",
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
    "charsetUtf8",
    "asciiOnly",
    "jsxInJs",
    "jsxDev",
    "preserveModules",
    "verbatimModuleSyntax",
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
    external: opts.external,
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
    sourcemapDebugIds: opts.sourcemapDebugIds,
    sourcesContent: opts.sourcesContent,
    sourceRoot: opts.sourceRoot,
    treeShaking: opts.treeShaking,
    metafile: !!opts.metafile,
    keepNames: opts.keepNames,
    shimMissingExports: opts.shimMissingExports,
    flow: opts.flow,
    jsxInJs: opts.jsxInJs,
    charsetUtf8: opts.charsetUtf8,
    asciiOnly: opts.asciiOnly,
    quotes: opts.quotes,
    drop: opts.drop.length > 0 ? opts.drop : undefined,
    useDefineForClassFields: opts.useDefineForClassFields,
    experimentalDecorators: opts.experimentalDecorators,
    emitDecoratorMetadata: opts.emitDecoratorMetadata,
    verbatimModuleSyntax: opts.verbatimModuleSyntax,
    preserveModules: opts.preserveModules,
    preserveModulesRoot: opts.preserveModulesRoot,
    legalComments: opts.legalComments,
    resolveExtensions: opts.resolveExtensions.length > 0 ? opts.resolveExtensions : undefined,
    mainFields: opts.mainFields.length > 0 ? opts.mainFields : undefined,
    // NAPI 가 tsconfig paths / baseUrl 을 alias 로 변환해 resolver 에 주입하도록 전달.
    tsconfigPath: opts.project,
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
  const envDir = opts.envDir ? resolve(opts.envDir) : process.cwd();
  dirs.add(envDir);

  const explicitConfig = opts.configPath ? resolve(opts.configPath) : null;
  const autoConfig = explicitConfig ?? findConfigPath(process.cwd());
  if (autoConfig) dirs.add(dirname(autoConfig));

  const mode = opts.mode ?? (opts.serve || opts.watch ? "development" : "production");
  // mode-specific config (`zts.config.${mode}.{ext}`) 변경도 restart trigger (#2110).
  const modeConfig = explicitConfig ? null : findModeConfigPath(process.cwd(), mode);
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
  if (opts.watchJson) {
    console.log(JSON.stringify({ type: "restart", reason }));
  } else if (opts.logLevel !== "silent") {
    console.error(`[watch] ${reason} — restarting CLI...`);
  }
  // 자식 프로세스 spawn 후 종료 — 새 프로세스가 fresh config/env 로 시작.
  // stdio inherit 으로 부모의 출력 스트림을 그대로 이어받는다.
  import("node:child_process").then(({ spawn }) => {
    const child = spawn(process.argv[0], process.argv.slice(1), {
      stdio: "inherit",
      env: process.env,
    });
    child.on("exit", (code) => process.exit(code ?? 0));
  });
}

// ─── Serve 모드 ───

async function runServe(opts, config) {
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
    await runBundle(opts, config);

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
    const restartTriggers = computeRestartTriggers(opts);
    for (const dir of restartTriggers.dirs) watchDirs.add(dir);

    for (const dir of watchDirs) {
      fsWatch(dir, { recursive: true }, (_event, filename) => {
        if (!filename || filename.includes("node_modules") || filename.includes(".git")) return;
        if (restartTriggers.matches(filename)) {
          emitRestart(opts, "config 또는 .env 파일 변경 감지");
          return;
        }
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(async () => {
          try {
            await runBundle(opts, config);
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

  // config 자동 탐색 + .env 로드 + 머지 (CLI > config > tsconfig). entry 검사 전에
  // 적용해야 config 의 entryPoints 가 검사 통과에 기여한다.
  // init() 은 entry 검사 후로 미뤄 no-args 경로의 NAPI dlopen 비용을 절감한다.
  // (config 가 .ts 면 loadConfig 내부에서 init() 이 idempotent 하게 호출됨)
  const { config, env: configEnv, dotenvVars } = await loadAutoConfig(opts);
  if (config) {
    mergeConfigIntoOpts(opts, config);
  }

  // import.meta.env.* + import.meta.env.MODE/PROD/DEV/SSR 정적 치환을 define 으로
  // 자동 주입. 사용자 명시 define 이 동일 키를 덮어쓰면 그대로 우선.
  const envDefine = envToDefine(dotenvVars, configEnv.mode);
  for (const [key, value] of Object.entries(envDefine)) {
    if (opts.define[key] === undefined) opts.define[key] = value;
  }

  if (opts.entryPoints.length === 0 && !opts.stdin && !opts.serve) {
    console.error("Usage: zts [options] <file.ts>");
    console.error("       zts --bundle <entry.ts> -o out.js");
    console.error("       zts --serve --bundle <entry.ts>");
    process.exit(1);
  }

  // tsconfig.json 자동 로드 (CLI/config 보다 낮은 우선순위)
  loadTsConfig(opts);
  init();

  try {
    if (opts.serve) {
      await runServe(opts, config);
    } else if (opts.watch) {
      await runWatch(opts, config);
    } else if (opts.bundle) {
      const result = await runBundle(opts, config);
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
