# @zntc/init

Overlay ZNTC onto an existing React Native CLI project.

```bash
npx @zntc/init
```

Show the available options:

```bash
npx @zntc/init --help
```

## Help

```text
Usage: zntc-init [react-native] [options]

Overlay ZNTC onto an existing React Native CLI project.

Options:
  --root <dir>               Project root (default: cwd)
  --platform <ios|android>   Default platform for the start script (default: ios)
  --zntc-version <range>     Version range for @zntc packages (default: latest)
  --package-manager <pm>     Install command hint: bun, npm, pnpm, or yarn
  --no-metro-fallback        Do not add Metro fallback scripts
  --force                    Overwrite an existing zntc.config.ts
  --dry-run                  Print planned changes without writing files
  --help, -h                 Show this help message
```

## Options

- `--root <dir>` — Project root. Defaults to the current working directory.
- `--platform <ios|android>` — Default platform for the ZNTC start script. Defaults to `ios`.
- `--zntc-version <range>` — Version range for `@zntc/core` and `@zntc/react-native`. Defaults to `latest`.
- `--package-manager <bun|npm|pnpm|yarn>` — Install command hint shown after writes.
- `--no-metro-fallback` — Do not add `start:metro` / `bundle:metro:*` scripts.
- `--force` — Overwrite an existing `zntc.config.ts`.
- `--dry-run` — Print planned file changes without writing.
- `--help`, `-h` — Show help.

The initializer keeps the React Native project structure intact. It adds ZNTC
dependencies, ZNTC-first scripts, Metro fallback scripts, and a `zntc.config.ts`
file when one does not already exist.

Expo projects are intentionally out of scope.
