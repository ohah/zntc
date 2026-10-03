#!/usr/bin/env bash
set -euo pipefail

# Keep the root dependencies: tsc/lint tools and the real-library fixtures used
# by NAPI/integration tests live there. Do not use --production or --omit=optional:
# SWC, browserslist, core-js, Lightning CSS and RN/Babel are test inputs too.
filters=(--filter zntc)
case "${1:-}" in
  lint)
    ;;
  core-build)
    filters+=(--filter @zntc/core --filter @zntc/test-helpers)
    ;;
  core-test|publish)
    filters+=(--filter './packages/*' --filter @zntc/test-helpers)
    ;;
  integration)
    # tree-shake-precision.test.ts uses benchmark libraries and returns early
    # when they are missing. Preserve them even though this is not a benchmark.
    filters+=(--filter './packages/*' --filter @zntc/test-helpers
      --filter @zntc/integration --filter @zntc/benchmark)
    ;;
  e2e)
    # examples-smoke-e2e.test.ts builds examples/web in the browser suite.
    filters+=(--filter './packages/*' --filter @zntc/test-helpers
      --filter @zntc/e2e --filter @zntc/example-web)
    ;;
  benchmark)
    filters+=(--filter @zntc/core --filter @zntc/test-helpers --filter @zntc/benchmark)
    ;;
  wasm)
    filters+=(--filter @zntc/core --filter @zntc/test-helpers --filter @zntc/wasm)
    ;;
  docs)
    # TypeDoc reads packages/core/index.ts and its referenced shared types.
    filters+=(--filter @zntc/core --filter @zntc/test-helpers --filter documents)
    ;;
  *)
    echo "Unknown CI dependency profile: ${1:-<missing>}" >&2
    exit 1
    ;;
esac

# Bun keeps the lockfile frozen and includes dependencies of the selected
# workspaces, while unrelated docs/example/test workspaces stay uninstalled.
bun install --frozen-lockfile "${filters[@]}"
