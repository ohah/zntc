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
        \\  --allow-overwrite                Permit output paths to overwrite input files
        \\  --minify                         Minify output
        \\  --format=esm|cjs|iife|umd|amd    Module format (default: esm)
        \\  --drop=console                   Remove console.* calls
        \\  --drop=debugger                  Remove debugger statements
        \\  --pure:CALLEE                    Mark matching call/new expressions as removable when unused
        \\  --define:KEY=VALUE               Replace KEY with VALUE globally
        \\  --sourcemap                      Generate source map (.js.map)
        \\  --sourcemap-debug-ids            Add Sentry debugId to JS and source map
        \\  --ascii-only                     Escape non-ASCII to \uXXXX
        \\  --quotes=<style>                 String quote style (double|single|preserve)
        \\  -w, --watch                      Watch for file changes
        \\  -p, --project <path>             Path to tsconfig.json file or directory
        \\  --tsconfig-path <path>           Alias of -p/--project (matches NAPI `tsconfigPath`)
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
        \\  --external <pkg>                 Exclude package (repeatable)
        \\  --globals SPEC=GLOBAL            IIFE external → global mapping (rollup output.globals)
        \\  --globals=SPEC=GLOBAL[,...]      Same, comma-separated form
        \\  --conditions=<cond,...>          Custom export conditions (e.g. production)
        \\  --platform=browser|node|neutral  Target platform (default: browser)
        \\  --rn-platform=ios|android        RN sub-platform (.ios.*/.android.* extensions)
        \\
        \\TypeScript options:
        \\  --experimental-decorators         Legacy decorator (__decorateClass)
        \\  --use-define-for-class-fields=false  Move fields to constructor (assign semantics)
        \\  --verbatim-module-syntax          Preserve unused value imports (TS 5.0+)
        \\
        \\Flow options:
        \\  --flow                            Enable Flow type stripping (auto-detected via @flow pragma)
        \\
        \\Resolve options:
        \\  --resolve-extensions=<exts>       Comma-separated extension order (e.g. .ios.ts,.ts,.js)
        \\  --main-fields=<fields>            Comma-separated package.json field order (e.g. react-native,browser,main)
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
