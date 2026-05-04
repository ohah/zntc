import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, extname, isAbsolute, join, resolve } from "node:path";

export type RuntimePolyfillMode = "auto" | "usage" | "entry";
export type RuntimePolyfillProvider = "core-js";

export interface RuntimePolyfillOptions {
  /**
   * Runtime polyfill injection strategy.
   *
   * `auto` and `usage` scan statically detectable API usage, while `entry`
   * injects all target-required core-js ES/Web modules.
   */
  mode?: RuntimePolyfillMode;
  /** Polyfill provider. Only `core-js` is currently supported. */
  provider?: RuntimePolyfillProvider;
  /**
   * Browserslist targets for core-js-compat, matching Rspack/SWC `env.targets`.
   *
   * Examples: `["chrome >= 87", "edge >= 88", "firefox >= 78", "safari >= 14"]`.
   * Physical device names such as `"iPhone 8"` and compact shorthands such as
   * `"ios12"` are rejected.
   */
  targets?: string | string[];
  /** core-js version used for compatibility calculation, matching Rspack/SWC `env.coreJs`. */
  coreJs?: string;
  /** Additional core-js modules to force into the synthetic prelude. */
  include?: string[];
  /** core-js modules to remove after target and usage calculation. */
  exclude?: string[];
  /** Include proposal polyfills when querying core-js-compat. */
  proposals?: boolean;
}

export type RuntimePolyfillsOption = "off" | RuntimePolyfillMode | RuntimePolyfillOptions;

export interface RuntimePolyfillBuildOptions {
  entryPoints: string[];
  platform?: string;
  target?: string;
  browserslist?: string | string[];
  runtimePolyfills?: RuntimePolyfillsOption;
  coreJs?: string;
  runBeforeMain?: string[];
  resolveExtensions?: string[];
}

interface NormalizedRuntimePolyfills {
  mode: RuntimePolyfillMode;
  provider: RuntimePolyfillProvider;
  targets: CoreJsTargets;
  include: string[];
  exclude: string[];
  proposals: boolean;
  coreJsVersion?: string;
}

type CoreJsTargetObject = Record<string, string | number>;
type CoreJsTargets = string | string[] | CoreJsTargetObject;

type RuntimeRequire = ReturnType<typeof createRequire>;

type CoreJsCompat = (options: {
  targets: CoreJsTargets;
  version?: string;
  modules?: string[] | RegExp;
  proposals?: boolean;
}) => { list: string[] };

type BabelParser = {
  parse(source: string, options: Record<string, unknown>): unknown;
};

let runtimeRequireOverride: RuntimeRequire | null = null;

function getRuntimeRequire(): RuntimeRequire {
  return runtimeRequireOverride ?? createRequire(import.meta.url);
}

/** @internal */
export const __runtimePolyfillTestHooks = {
  reset() {
    coreJsCompatCache = undefined;
    babelParserCache = undefined;
    coreJsVersionCache = undefined;
    runtimeRequireOverride = null;
  },
  setRuntimeRequire(runtimeRequire: RuntimeRequire | null) {
    coreJsCompatCache = undefined;
    babelParserCache = undefined;
    coreJsVersionCache = undefined;
    runtimeRequireOverride = runtimeRequire;
  },
};

const ES_TARGETS = new Set([
  "es5",
  "es2015",
  "es2016",
  "es2017",
  "es2018",
  "es2019",
  "es2020",
  "es2021",
  "es2022",
  "es2023",
  "es2024",
  "es2025",
  "esnext",
]);

const DEVICE_TARGET_RE =
  /\b(?:iphone|ipad|ipod|galaxy|pixel|nexus|oneplus|xiaomi|redmi|huawei|motorola|moto)\b/i;

const SOURCE_EXTENSIONS = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"];

let coreJsCompatCache: CoreJsCompat | null | undefined;
let babelParserCache: BabelParser | null | undefined;
let coreJsVersionCache: string | null | undefined;

export function isEsTarget(target: string | undefined): boolean {
  return target !== undefined && ES_TARGETS.has(target);
}

function loadCoreJsCompat(): CoreJsCompat {
  if (coreJsCompatCache !== undefined) {
    if (coreJsCompatCache) return coreJsCompatCache;
    throwCoreJsCompatMissing();
  }
  try {
    const req = getRuntimeRequire();
    coreJsCompatCache = req("core-js-compat") as CoreJsCompat;
    return coreJsCompatCache;
  } catch {
    coreJsCompatCache = null;
    throwCoreJsCompatMissing();
  }
}

function throwCoreJsCompatMissing(): never {
  throw new Error(
    "@zts/core: runtimePolyfills requires the optional 'core-js-compat' package. Install it with `bun add core-js core-js-compat`.",
  );
}

function loadBabelParser(): BabelParser {
  if (babelParserCache !== undefined) {
    if (babelParserCache) return babelParserCache;
    throwBabelParserMissing();
  }
  try {
    const req = getRuntimeRequire();
    babelParserCache = req("@babel/parser") as BabelParser;
    return babelParserCache;
  } catch {
    babelParserCache = null;
    throwBabelParserMissing();
  }
}

function throwBabelParserMissing(): never {
  throw new Error(
    "@zts/core: runtimePolyfills auto/usage mode requires the optional '@babel/parser' package. Install it with `bun add @babel/parser`.",
  );
}

function readInstalledCoreJsVersion(): string | undefined {
  if (coreJsVersionCache !== undefined) return coreJsVersionCache ?? undefined;
  try {
    const req = getRuntimeRequire();
    const pkgPath = req.resolve("core-js/package.json");
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as { version?: string };
    coreJsVersionCache = pkg.version ?? null;
  } catch {
    coreJsVersionCache = null;
  }
  return coreJsVersionCache ?? undefined;
}

function assertNotPhysicalDeviceTarget(raw: string): void {
  if (!DEVICE_TARGET_RE.test(raw)) return;
  throw new Error(
    `@zts/core: unsupported runtime target '${raw}'. Physical device names are not supported; use Browserslist targets such as 'ios_saf 12', 'chrome >= 85', or 'node 18'.`,
  );
}

function assertNotCompactRuntimeTarget(raw: string): void {
  const compact = raw.match(
    /^(ios_saf|ios|safari|chrome|android|samsung|hermes|node)v?\d+(?:\.\d+)*$/i,
  );
  if (!compact) return;
  throw new Error(
    `@zts/core: unsupported runtime target '${raw}'. Compact runtime target shorthands are not supported; use Browserslist targets such as 'ios_saf 12', 'chrome >= 85', or 'node 18'.`,
  );
}

function assertBrowserslistRuntimeTarget(raw: string): void {
  if (!/^(?:hermes|react-native|reactnative)\b/i.test(raw)) return;
  throw new Error(
    `@zts/core: unsupported runtime target '${raw}'. runtimePolyfills.targets follows Rspack/SWC env.targets and accepts Browserslist queries; use platform: 'react-native' for the default Hermes runtime target.`,
  );
}

function normalizeRuntimeTargetString(raw: string): string {
  const value = raw.trim();
  assertNotPhysicalDeviceTarget(value);
  assertNotCompactRuntimeTarget(value);
  assertBrowserslistRuntimeTarget(value);
  return value;
}

export function normalizeRuntimeTargets(targets: string | string[]): string | string[] {
  if (Array.isArray(targets)) return targets.map(normalizeRuntimeTargetString);
  return normalizeRuntimeTargetString(targets);
}

function normalizeBuildTargetForRuntime(target: string | undefined): CoreJsTargets | undefined {
  if (!target || isEsTarget(target)) return undefined;
  const nodeTarget = target.match(/^node(\d+(?:\.\d+)*)$/i);
  if (nodeTarget) return { node: nodeTarget[1] };
  const hermesTarget = target.match(/^hermes(\d+(?:\.\d+)*)$/i);
  if (hermesTarget) return { hermes: hermesTarget[1] };
  return normalizeRuntimeTargets(target);
}

function defaultRuntimeTargets(options: RuntimePolyfillBuildOptions): CoreJsTargets {
  if (options.platform === "node") {
    const [major, minor = "0"] = process.versions.node.split(".");
    return { node: `${major}.${minor}` };
  }
  if (options.platform === "react-native") return { hermes: "0.7" };
  return "defaults";
}

function chooseRuntimeTargets(
  options: RuntimePolyfillBuildOptions,
  runtime: RuntimePolyfillOptions,
): CoreJsTargets {
  const raw = runtime.targets ?? (options.browserslist ? options.browserslist : undefined);
  if (raw !== undefined) return normalizeRuntimeTargets(raw);
  const target = normalizeBuildTargetForRuntime(options.target);
  if (target !== undefined) return target;
  return defaultRuntimeTargets(options);
}

function normalizeCoreJsModuleName(raw: string): string {
  let value = raw.trim();
  if (value.startsWith("core-js/modules/")) value = value.slice("core-js/modules/".length);
  if (value.endsWith(".js")) value = value.slice(0, -3);
  if (!/^(?:es|web)\.[a-z0-9.-]+$/i.test(value)) {
    throw new Error(
      `@zts/core: invalid core-js module '${raw}'. Expected e.g. 'es.string.replace-all'.`,
    );
  }
  return value;
}

export function normalizeRuntimePolyfillOptions(
  options: RuntimePolyfillBuildOptions,
): NormalizedRuntimePolyfills | null {
  const raw = options.runtimePolyfills;
  if (raw === undefined || raw === "off") return null;

  const runtime: RuntimePolyfillOptions = typeof raw === "string" ? { mode: raw } : { ...raw };
  const mode = runtime.mode ?? "auto";
  if (mode !== "auto" && mode !== "usage" && mode !== "entry") {
    throw new Error("@zts/core: runtimePolyfills.mode must be 'auto', 'usage', or 'entry'.");
  }
  const provider = runtime.provider ?? "core-js";
  if (provider !== "core-js") {
    throw new Error("@zts/core: runtimePolyfills.provider currently supports only 'core-js'.");
  }

  return {
    mode,
    provider,
    targets: chooseRuntimeTargets(options, runtime),
    include: (runtime.include ?? []).map(normalizeCoreJsModuleName),
    exclude: (runtime.exclude ?? []).map(normalizeCoreJsModuleName),
    proposals: runtime.proposals === true,
    coreJsVersion: runtime.coreJs ?? options.coreJs ?? readInstalledCoreJsVersion(),
  };
}

export function computeCoreJsCompatModules(
  targets: CoreJsTargets,
  modules: string[] | RegExp,
  options: { version?: string; proposals?: boolean } = {},
): string[] {
  const compat = loadCoreJsCompat();
  const result = compat({
    targets,
    modules,
    version: options.version,
    proposals: options.proposals,
  });
  return result.list.map(normalizeCoreJsModuleName).sort();
}

function parseSource(source: string, filename: string): unknown {
  const parser = loadBabelParser();
  const baseOptions = {
    sourceType: "unambiguous",
    sourceFilename: filename,
    errorRecovery: true,
  };
  try {
    return parser.parse(source, {
      ...baseOptions,
      plugins: [
        "typescript",
        "jsx",
        "classProperties",
        "classPrivateProperties",
        "classPrivateMethods",
        "decorators-legacy",
        "dynamicImport",
        "importAttributes",
        "topLevelAwait",
      ],
    });
  } catch {
    return parser.parse(source, {
      ...baseOptions,
      plugins: [
        "flow",
        "jsx",
        "classProperties",
        "classPrivateProperties",
        "classPrivateMethods",
        "decorators-legacy",
        "dynamicImport",
        "importAttributes",
        "topLevelAwait",
      ],
    });
  }
}

function isNode(value: unknown): value is Record<string, unknown> {
  return (
    value !== null &&
    typeof value === "object" &&
    typeof (value as { type?: unknown }).type === "string"
  );
}

function stringLiteralValue(value: unknown): string | null {
  if (!isNode(value)) return null;
  if (value.type === "StringLiteral" || value.type === "Literal") {
    const raw = value.value;
    return typeof raw === "string" ? raw : null;
  }
  return null;
}

function memberName(member: Record<string, unknown>): string | null {
  const property = member.property;
  if (!isNode(property)) return null;
  if (property.type === "Identifier" && member.computed !== true) {
    return typeof property.name === "string" ? property.name : null;
  }
  return stringLiteralValue(property);
}

function identifierName(node: unknown): string | null {
  return isNode(node) && node.type === "Identifier" && typeof node.name === "string"
    ? node.name
    : null;
}

function recordIdentifierUsage(name: string, out: Set<string>): void {
  if (name === "Map") out.add("es.map");
  else if (name === "Set") out.add("es.set");
  else if (name === "Promise") out.add("es.promise");
  else if (name === "structuredClone") out.add("web.structured-clone");
}

function recordMemberUsage(member: Record<string, unknown>, out: Set<string>): void {
  const prop = memberName(member);
  if (prop === "replaceAll") out.add("es.string.replace-all");
  else if (prop === "at") out.add("es.array.at");
  else if (prop === "hasOwn" && identifierName(member.object) === "Object") {
    out.add("es.object.has-own");
  }

  const objName = identifierName(member.object);
  if (objName) recordIdentifierUsage(objName, out);
}

function shouldSkipIdentifier(
  node: Record<string, unknown>,
  parent: Record<string, unknown> | null,
): boolean {
  if (!parent) return false;
  if (parent.type === "MemberExpression" && parent.property === node && parent.computed !== true)
    return true;
  if (parent.type === "ObjectProperty" && parent.key === node && parent.computed !== true)
    return true;
  if (parent.type === "ObjectMethod" && parent.key === node && parent.computed !== true)
    return true;
  if (parent.type === "VariableDeclarator" && parent.id === node) return true;
  if (parent.type === "FunctionDeclaration" && parent.id === node) return true;
  if (parent.type === "FunctionExpression" && parent.id === node) return true;
  if (parent.type === "ClassDeclaration" && parent.id === node) return true;
  if (parent.type === "ClassExpression" && parent.id === node) return true;
  if (parent.type === "ImportSpecifier" || parent.type === "ImportDefaultSpecifier") return true;
  if (parent.type === "ImportNamespaceSpecifier") return true;
  return false;
}

function visitAst(
  node: unknown,
  parent: Record<string, unknown> | null,
  cb: (node: Record<string, unknown>, parent: Record<string, unknown> | null) => void,
): void {
  if (!isNode(node)) return;
  cb(node, parent);
  for (const [key, value] of Object.entries(node)) {
    if (
      key === "loc" ||
      key === "start" ||
      key === "end" ||
      key === "range" ||
      key === "leadingComments" ||
      key === "trailingComments" ||
      key === "innerComments"
    ) {
      continue;
    }
    if (Array.isArray(value)) {
      for (const item of value) visitAst(item, node, cb);
    } else {
      visitAst(value, node, cb);
    }
  }
}

function scanAst(ast: unknown): { used: Set<string>; specifiers: string[] } {
  const used = new Set<string>();
  const specifiers: string[] = [];
  visitAst(ast, null, (node, parent) => {
    if (node.type === "MemberExpression") {
      recordMemberUsage(node, used);
      return;
    }
    if (node.type === "NewExpression" || node.type === "CallExpression") {
      const name = identifierName(node.callee);
      if (name) recordIdentifierUsage(name, used);
      if (node.type === "CallExpression" && name === "require") {
        const args = Array.isArray(node.arguments) ? node.arguments : [];
        const spec = stringLiteralValue(args[0]);
        if (spec) specifiers.push(spec);
      }
      return;
    }
    if (node.type === "Identifier" && !shouldSkipIdentifier(node, parent)) {
      const name = identifierName(node);
      if (name) recordIdentifierUsage(name, used);
      return;
    }
    if (
      (node.type === "ImportDeclaration" ||
        node.type === "ExportNamedDeclaration" ||
        node.type === "ExportAllDeclaration") &&
      node.source
    ) {
      const spec = stringLiteralValue(node.source);
      if (spec) specifiers.push(spec);
    }
  });
  return { used, specifiers };
}

export function scanRuntimePolyfillUsage(source: string, filename = "input.js"): string[] {
  const { used } = scanAst(parseSource(source, filename));
  return [...used].sort();
}

function isRelativeSpecifier(specifier: string): boolean {
  return specifier.startsWith("./") || specifier.startsWith("../") || isAbsolute(specifier);
}

function isSourceFile(path: string): boolean {
  return SOURCE_EXTENSIONS.includes(extname(path));
}

function tryFile(path: string): string | null {
  try {
    if (statSync(path).isFile() && isSourceFile(path)) return path;
  } catch {}
  return null;
}

function resolveSourceImport(
  importer: string,
  specifier: string,
  resolveExtensions: readonly string[] | undefined,
): string | null {
  if (!isRelativeSpecifier(specifier)) return null;
  const base = isAbsolute(specifier) ? specifier : resolve(dirname(importer), specifier);
  const explicit = tryFile(base);
  if (explicit) return explicit;

  const extensions = [
    ...(resolveExtensions?.filter((ext) => SOURCE_EXTENSIONS.includes(ext)) ?? []),
    ...SOURCE_EXTENSIONS,
  ];
  for (const ext of extensions) {
    const found = tryFile(base + ext);
    if (found) return found;
  }

  try {
    if (statSync(base).isDirectory()) {
      for (const ext of extensions) {
        const found = tryFile(join(base, "index" + ext));
        if (found) return found;
      }
    }
  } catch {}
  return null;
}

export function collectRuntimePolyfillUsageFromFiles(
  entryPoints: readonly string[],
  options: { resolveExtensions?: readonly string[] } = {},
): string[] {
  const queue = entryPoints.map((entry) => resolve(entry));
  const seen = new Set<string>();
  const used = new Set<string>();

  for (let head = 0; head < queue.length; head++) {
    const file = queue[head]!;
    if (seen.has(file) || !isSourceFile(file)) continue;
    let source: string;
    try {
      source = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    seen.add(file);
    const { used: fileUsed, specifiers } = scanAst(parseSource(source, file));
    for (const moduleName of fileUsed) used.add(moduleName);
    for (const specifier of specifiers) {
      const resolved = resolveSourceImport(file, specifier, options.resolveExtensions);
      if (resolved && !seen.has(resolved)) queue.push(resolved);
    }
  }

  return [...used].sort();
}

function computeRuntimePolyfillModules(
  options: RuntimePolyfillBuildOptions,
  runtime: NormalizedRuntimePolyfills,
): string[] {
  const include = new Set(runtime.include);
  const exclude = new Set(runtime.exclude);
  let modules: string[];

  if (runtime.mode === "entry") {
    modules = computeCoreJsCompatModules(runtime.targets, /^(?:es|web)\./, {
      version: runtime.coreJsVersion,
      proposals: runtime.proposals,
    });
  } else {
    const used = collectRuntimePolyfillUsageFromFiles(options.entryPoints, {
      resolveExtensions: options.resolveExtensions,
    });
    modules = computeCoreJsCompatModules(runtime.targets, used, {
      version: runtime.coreJsVersion,
      proposals: runtime.proposals,
    });
  }

  const out = new Set(modules);
  for (const moduleName of include) out.add(moduleName);
  for (const moduleName of exclude) out.delete(moduleName);
  return [...out].sort();
}

function buildCoreJsResolver(entryPoints: readonly string[]): (moduleName: string) => string {
  const override = runtimeRequireOverride;
  const requires: RuntimeRequire[] = [];
  if (override) {
    requires.push(override);
  } else {
    const entry = entryPoints[0];
    if (entry) requires.push(createRequire(resolve(dirname(resolve(entry)), "package.json")));
    requires.push(createRequire(import.meta.url));
  }
  return (moduleName: string) => {
    const specifier = `core-js/modules/${moduleName}.js`;
    let firstError: string | undefined;
    for (const req of requires) {
      try {
        return req.resolve(specifier);
      } catch (err) {
        firstError ??= err instanceof Error ? err.message : String(err);
      }
    }
    throw new Error(
      `@zts/core: runtimePolyfills could not resolve '${specifier}'. Install core-js with \`bun add core-js\`.\n${firstError ?? ""}`,
    );
  };
}

export function createRuntimePolyfillPrelude(
  modules: readonly string[],
  options: RuntimePolyfillBuildOptions,
): { path: string; cleanup: () => void } | null {
  if (modules.length === 0) return null;
  const resolveCoreJs = buildCoreJsResolver(options.entryPoints);
  const dir = mkdtempSync(join(tmpdir(), "zts-runtime-polyfills-"));
  const path = join(dir, "prelude.mjs");
  const imports = modules
    .map((moduleName) => `import ${JSON.stringify(resolveCoreJs(moduleName))};`)
    .join("\n");
  writeFileSync(path, `${imports}\n`, "utf8");
  return {
    path,
    cleanup() {
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

export function applyRuntimePolyfillsToNapiOptions(
  napiOptions: Record<string, unknown>,
  options: RuntimePolyfillBuildOptions,
): { cleanup: () => void; modules: string[] } {
  delete napiOptions.runtimePolyfills;
  delete napiOptions.coreJs;

  if (options.target && !isEsTarget(options.target)) delete napiOptions.target;

  const runtime = normalizeRuntimePolyfillOptions(options);
  if (!runtime) return { cleanup: () => {}, modules: [] };

  const modules = computeRuntimePolyfillModules(options, runtime);
  const prelude = createRuntimePolyfillPrelude(modules, options);
  if (!prelude) return { cleanup: () => {}, modules };

  const existing = Array.isArray(options.runBeforeMain) ? options.runBeforeMain : [];
  napiOptions.runBeforeMain = [prelude.path, ...existing];
  return { cleanup: prelude.cleanup, modules };
}
