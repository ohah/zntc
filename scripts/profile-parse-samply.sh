#!/usr/bin/env bash
# samply 로 zntc 의 transpile 핫스팟을 sampling profile 한다.
#
# 사용법:
#   scripts/profile-parse-samply.sh                                 # 기본 fixture(typescript.js 9MB) x 5 iter
#   scripts/profile-parse-samply.sh <fixture.ts> <iters> <rate_hz>  # 인자 커스텀
#
# 출력:
#   /tmp/zntc-samply/profile.json.gz
#   /tmp/zntc-samply/profile.json.syms.json
#
# 분석:
#   scripts/analyze-samply.py /tmp/zntc-samply
#   samply load /tmp/zntc-samply/profile.json.gz    # Firefox profiler UI
#
# 전제: `cargo install samply` 또는 `brew install samply`.
# docs/PERF_PROFILING.md 참고.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_FIXTURE="${1:-tests/benchmark/node_modules/node_modules/typescript/lib/typescript.js}"
ITERS="${2:-5}"
RATE="${3:-4000}"
OUT_DIR="${ZNTC_SAMPLY_OUT:-/tmp/zntc-samply}"

# Resolve fixture against the caller's cwd before we cd into the repo root.
# Otherwise `./foo.ts` would be looked up under $REPO_ROOT and the "not found"
# error message wouldn't hint that the path was relative.
if [[ "$RAW_FIXTURE" = /* ]]; then
  FIXTURE="$RAW_FIXTURE"
elif [[ -e "$RAW_FIXTURE" ]]; then
  FIXTURE="$(cd "$(dirname "$RAW_FIXTURE")" && pwd)/$(basename "$RAW_FIXTURE")"
else
  # Relative path that doesn't exist in the caller's cwd — try $REPO_ROOT next.
  FIXTURE="$REPO_ROOT/$RAW_FIXTURE"
fi

if ! command -v samply >/dev/null 2>&1; then
  echo "error: samply not found. install via 'cargo install samply' or 'brew install samply'" >&2
  exit 1
fi

# --unstable-presymbolicate is samply ≥0.12 (released 2024). Detect via --help
# rather than parsing a version so future renames don't silently break.
if ! samply record --help 2>&1 | grep -q -- "--unstable-presymbolicate"; then
  echo "error: installed samply lacks --unstable-presymbolicate (need samply ≥0.12)." >&2
  echo "       upgrade via 'cargo install --force samply' or 'brew upgrade samply'." >&2
  exit 1
fi

cd "$REPO_ROOT"

echo "==> building zntc (-Doptimize=ReleaseFast -Dkeep-debug=true) ..."
zig build -Doptimize=ReleaseFast -Dkeep-debug=true

# macOS: regenerate .dSYM unconditionally. The `-nt` mtime check is unreliable
# because `zig build` can hardlink a cache-hit binary while leaving an older
# dSYM in place (e.g. previous run used -Dkeep-debug=false). Re-running dsymutil
# costs a few seconds and guarantees the dSYM matches the binary we just built.
if [[ "$OSTYPE" == "darwin"* ]]; then
  echo "==> running dsymutil to produce zntc.dSYM ..."
  dsymutil zig-out/bin/zntc
fi

if [[ ! -f "$FIXTURE" ]]; then
  echo "error: fixture not found: $FIXTURE" >&2
  echo "  (resolved from: '$RAW_FIXTURE')" >&2
  echo "  hint: 'cd tests/benchmark && bun install' to populate node_modules" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# Warm filesystem cache so the first iteration is not cold I/O biased.
echo "==> warming filesystem cache ..."
./zig-out/bin/zntc "$FIXTURE" -o /dev/null >/dev/null 2>&1 || true

echo "==> recording $ITERS iterations at ${RATE}Hz on fixture: $FIXTURE"
samply record \
  --save-only \
  --no-open \
  --output "$OUT_DIR/profile.json.gz" \
  --rate "$RATE" \
  --iteration-count "$ITERS" \
  --unstable-presymbolicate \
  -- ./zig-out/bin/zntc "$FIXTURE" -o /dev/null

echo
echo "done. analyze with:"
echo "  python3 scripts/analyze-samply.py $OUT_DIR"
echo "  samply load $OUT_DIR/profile.json.gz   # Firefox profiler UI"
