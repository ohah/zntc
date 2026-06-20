//! CLI usage text.

pub fn printUsage(writer: anytype) !void {
    try writer.print(
        \\zntc v0.1.0 - Zig Native Transpiler & Compiler
        \\
        \\Usage:
        \\  zntc <file.ts>                    Transpile to stdout
        \\  zntc <file.ts> -o <out.js>        Transpile to file
        \\  zntc <dir/> --outdir <out/>       Transpile directory recursively
        \\  zntc --bundle <entry.ts>          Bundle to stdout
        \\  zntc --bundle <entry.ts> -o out   Bundle to file
        \\  zntc --bundle <entry.ts> --splitting --outdir dist  Code splitting
        \\  zntc dev [root]                  Serve an app from index.html
        \\  zntc build [root]                Build an app from index.html
        \\  zntc preview [outdir]            Serve built static files
        \\  zntc - < input.ts                 Read from stdin
        \\  zntc bench --phase=<CATS> <file>  Benchmark a specific phase (see below)
        \\
        \\Options:
        \\  -o, --out-file <path>            Output file path
        \\  --outdir <path>                  Output directory (for directory input)
        \\  --outbase=<dir>                  Common parent dir for entry points (preserves tree under --outdir)
        \\  --allow-overwrite                Permit output paths to overwrite input files
        \\  --minify                         Minify output (whitespace + identifiers + syntax)
        \\  --minify-whitespace              Remove whitespace only
        \\  --minify-identifiers             Mangle identifiers only
        \\  --minify-syntax                  Apply AST-level syntax minification only
        \\  --keep-names                     Preserve `.name` of fn/class under minification (__name helper)
        \\  --target=<spec>                  ES version or engine matrix (esnext|es2015..|chrome80,safari14,...)
        \\  --browserslist=<query>           Engine targets in Browserslist syntax ('chrome >= 87, firefox 78'). Stat queries (defaults / last 2 versions) need the JS wrapper.
        \\  --format=esm|cjs|iife|umd|amd    Module format (default: esm)
        \\  --drop=console                   Remove console.* calls
        \\  --drop=debugger                  Remove debugger statements
        \\  --drop-labels=A,B                Remove labeled blocks named A or B
        \\  --pure:CALLEE                    Mark matching call/new expressions as removable when unused
        \\  --ignore-annotations             Ignore /* @__PURE__ */ and `sideEffects` field
        \\  --define:KEY=VALUE               Replace KEY with VALUE globally
        \\  --sourcemap                      Generate source map (.js.map)
        \\  --sourcemap=<mode>               external | inline | linked | both | none
        \\  --sourcemap-debug-ids            Add Sentry debugId to JS and source map
        \\  --ascii-only                     Escape non-ASCII to \uXXXX
        \\  --charset=utf8                   Force UTF-8 output (no \uXXXX escape)
        \\  --quotes=<style>                 String quote style (double|single|preserve)
        \\  --legal-comments=<mode>          none | inline | eof — license/legal comment placement
        \\  -w, --watch                      Watch for file changes
        \\  --watch-delay=<ms>               Debounce window for file events (default: 16)
        \\  -p, --project <path>             Path to tsconfig.json file or directory
        \\  --tsconfig-path <path>           Alias of -p/--project (matches NAPI `tsconfigPath`)
        \\  --tsconfig-raw=<json>            Inline tsconfig JSON (overrides file/auto-discovery)
        \\  --tokenize                       Print tokens instead of transpiling
        \\  --test262 <dir>                  Run Test262 tests
        \\  -h, --help                       Show this help
        \\
        \\Dev server:
        \\  --serve [dir]                    Start static file server (default: .)
        \\  --serve --bundle <entry.ts>      Bundle and serve entry point
        \\  --port <number>                  Server port (default: 3000)
        \\
        \\App builder:
        \\  --entry-html <file>              HTML entry relative to root (default: index.html)
        \\  --public-dir <dir|false>         Copy public dir to output root (default: public)
        \\  --base <path>                    Base URL prefix for HTML/assets (default: /)
        \\  --mode <name>                    Env mode (dev=development, build=production)
        \\  --env-dir <dir>                  Directory for .env files (default: app root)
        \\  --env-prefix <csv>               Exposed env prefixes (default: VITE_,ZNTC_)
        \\
        \\Bundle options:
        \\  --bundle                         Enable bundle mode
        \\  --splitting                      Enable code splitting (requires --outdir)
        \\  --preserve-modules               One file per module (library builds, requires --outdir)
        \\  --preserve-modules-root=<dir>    Root directory for output structure
        \\  --inline-dynamic-imports         Force dynamic import() into the main chunk
        \\  --external <pkg>                 Exclude package (repeatable, also: --external=pkg, --external:pkg)
        \\  --packages=external              Treat every bare import as external
        \\  --globals SPEC=GLOBAL            UMD/AMD/IIFE external → global mapping (rollup output.globals)
        \\  --globals=SPEC=GLOBAL[,...]      Same, comma-separated form
        \\  --global-name=<name>             IIFE/UMD container global identifier
        \\  --alias:K=V                      Force-rewrite import specifier K → V (resolve전)
        \\  --fallback:K=V                   Map K → V only when normal resolve fails (`=false` → empty)
        \\  --banner:js=<text>               Prepend text to the JS output
        \\  --footer:js=<text>               Append text to the JS output
        \\  --inject:KEY=PATH                Auto-import PATH and bind to KEY in every entry
        \\  --loader:.ext=<type>             Per-extension loader (js|ts|jsx|tsx|json|text|file|dataurl|binary|copy|css|empty)
        \\  --public-path=<url>              URL prefix for assets/chunks
        \\  --entry-names=<pattern>          Entry filename pattern (e.g. `[name]-[hash]`)
        \\  --chunk-names=<pattern>          Chunk filename pattern
        \\  --asset-names=<pattern>          Asset filename pattern
        \\  --metafile                       Emit build metadata to stderr
        \\  --metafile=<path>                Emit build metadata to file (esbuild compat)
        \\  --analyze                        Print bundle analyzer summary
        \\  --shim-missing-exports           Stub-export missing named imports (rolldown compat)
        \\  --disk-cache                     Persist parse/semantic to node_modules/.cache/zntc (faster cold rebuilds)
        \\  --cache-dir <path>               Disk cache directory (implies --disk-cache)
        \\  --conditions=<cond,...>          Custom export conditions (e.g. production)
        \\  --platform=browser|node|neutral  Target platform (default: browser)
        \\  --rn-platform=ios|android        RN sub-platform (.ios.*/.android.* extensions)
        \\  --rn-version=<spec>              RN version target (implies platform=react-native). Downlevels per the RN
        \\                                   javascript-environment docs instead of the blunt ES5 preset. Accepts
        \\                                   '0.80', '>=0.74', '<=0.84', '==0.76' (>= / bare = that version; <= = most conservative).
        \\
        \\TypeScript options:
        \\  --experimental-decorators         Legacy decorator (__decorateClass)
        \\  --use-define-for-class-fields=false  Move fields to constructor (assign semantics)
        \\  --verbatim-module-syntax          Preserve unused value imports (TS 5.0+)
        \\
        \\JSX options:
        \\  --jsx=<mode>                      classic | automatic | automatic-dev | preserve
        \\  --jsx-dev                         Shortcut for --jsx=automatic-dev
        \\  --jsx-factory=<name>              Element factory (classic, default: React.createElement)
        \\  --jsx-fragment=<name>             Fragment factory (classic, default: React.Fragment)
        \\  --jsx-import-source=<pkg>         Runtime import source (automatic, default: react)
        \\  --jsx-side-effects                Preserve unused JSX expressions
        \\
        \\Flow options:
        \\  --flow                            Enable Flow type stripping (auto-detected via @flow pragma)
        \\
        \\Resolve options:
        \\  --resolve-extensions=<exts>       Comma-separated extension order (e.g. .ios.ts,.ts,.js)
        \\  --main-fields=<fields>            Comma-separated package.json field order (e.g. react-native,browser,main)
        \\  --node-paths=<dirs>               Comma-separated extra bare-specifier search dirs (NODE_PATH-like)
        \\  --preserve-symlinks               Resolve symlinks to the link path itself
        \\  --resolve-symlink-siblings        On lookup miss, retry from the source_dir realpath
        \\                                    (RN/pnpm peer sibling fallback)
        \\
        \\Profiling (pipeline timing):
        \\  --profile=<CATS>                  Categories to profile. CSV of:
        \\                                      all, none, scan, parse, semantic, resolve, graph,
        \\                                      link, shake, transform, codegen, metadata, emit,
        \\                                      hmr, cache (dot notation for sub-phases:
        \\                                      parse.ast_build, transform.jsx,
        \\                                      shake.const.prepass.build.facts, ...).
        \\                                      Parent category activates all children.
        \\                                      Examples:
        \\                                        --profile=all
        \\                                        --profile=parse,transform
        \\                                        --profile=shake.const.prepass.build.facts,shake.const.prepass.replace
        \\  --profile-level=<L>               Detail level: summary | detailed | per-module | per-pass
        \\                                      (default: summary)
        \\  --profile-format=<F>              Output format: table | tree | json | csv
        \\                                      (default: table)
        \\  --stop-after=<P>                  Stop pipeline after the given phase (debug / profile):
        \\                                      scan | parse | semantic | transform | codegen
        \\                                      Output is empty; useful for isolating phase cost with --profile.
        \\                                      Examples:
        \\                                        zntc input.ts --stop-after=parse --profile=parse
        \\                                        zntc input.ts --stop-after=semantic --profile=all
        \\
        \\  Env equivalents:
        \\    ZNTC_PROFILE=<CATS>              Same as --profile
        \\    ZNTC_PROFILE_LEVEL=<L>           Same as --profile-level
        \\
        \\  See `docs/design/profile-infrastructure.md` for full reference.
        \\
        \\Benchmark subcommand (`zntc bench`):
        \\  Run a specific phase N times and emit statistics (mean/median/p95/p99/stddev).
        \\  Useful for optimization work: measure before, change, measure after.
        \\
        \\  Options:
        \\    --phase=<CATS>                  Phase categories (comma-separated; required).
        \\                                      e.g. --phase=parse
        \\                                           --phase=scan,parse,transform
        \\                                      `all` / `none` are NOT allowed here (must be specific).
        \\    --iterations=<N>                Iterations after warmup (default: 100).
        \\    --warmup=<N>                    Warmup iterations discarded (default: 10).
        \\    --profile-level=<L>             summary | detailed (default: summary).
        \\    --format=<F>                    table | json | csv (default: table).
        \\    --save=<PATH>                   Save result as baseline for future --compare.
        \\    --compare=<PATH>                Compare against a saved baseline.
        \\
        \\  Examples:
        \\    zntc bench --phase=parse ./src/App.tsx
        \\    zntc bench --phase=parse ./src/App.tsx --iterations=50
        \\    zntc bench --phase=parse,transform --format=json ./src/App.tsx
        \\    zntc bench --phase=parse ./src/App.tsx --save=./perf/baseline.json
        \\    zntc bench --phase=parse ./src/App.tsx --compare=./perf/baseline.json
        \\
    , .{});
}
