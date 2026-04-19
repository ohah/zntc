import { describe, test, expect, afterEach } from "bun:test";
import { join } from "node:path";
import { createFixture, runZts } from "./helpers";

// 반드시 `src/codegen/bundle_mangler_preview.zig`의 STDERR_PREFIX와 일치해야 함.
const STDERR_PREFIX = "[mangle-preview] ";

// #1608: bundle-wide slot coloring dry-run.
// `--mangle-preview`는 실제 출력은 바꾸지 않고 stderr로 stats JSON을 내보낸다.
describe("mangler --mangle-preview (#1608)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("stats JSON이 stderr에 출력되고 실제 번들 결과는 변경되지 않는다", async () => {
    const fixture = await createFixture({
      "index.ts": `
        import { compute } from "./lib";
        console.log(compute(3, 4));
      `,
      "lib.ts": `
        function square(n: number): number {
          const tmp = n * n;
          return tmp;
        }
        export function compute(a: number, b: number): number {
          const sumSq = square(a) + square(b);
          return sumSq;
        }
      `,
    });
    cleanup = fixture.cleanup;

    const outPlain = join(fixture.dir, "out-plain.js");
    const outPreview = join(fixture.dir, "out-preview.js");

    const plain = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outPlain,
      "--minify",
      "--platform=node",
    ]);
    expect(plain.exitCode).toBe(0);

    const preview = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outPreview,
      "--minify",
      "--mangle-preview",
      "--platform=node",
    ]);
    expect(preview.exitCode).toBe(0);

    const line = preview.stderr.split("\n").find((l) => l.startsWith(STDERR_PREFIX));
    expect(line, `stderr에 ${STDERR_PREFIX}라인이 있어야 함`).toBeDefined();

    const stats = JSON.parse(line!.slice(STDERR_PREFIX.length));
    expect(stats.module_count).toBeGreaterThanOrEqual(2);
    expect(stats.total_scope_count).toBeGreaterThan(0);
    expect(stats.slot_count).toBeGreaterThan(0);
    expect(stats.mangled_symbol_count).toBeGreaterThanOrEqual(stats.slot_count);
    expect(stats.len1 + stats.len2 + stats.len3 + stats.len4 + stats.len5plus).toBe(
      stats.slot_count,
    );

    // 실제 번들 출력은 변경되지 않아야 함 (dry-run 원칙)
    const plainBytes = await Bun.file(outPlain).arrayBuffer();
    const previewBytes = await Bun.file(outPreview).arrayBuffer();
    expect(previewBytes.byteLength).toBe(plainBytes.byteLength);
    expect(new Uint8Array(previewBytes)).toEqual(new Uint8Array(plainBytes));
  });

  test("--minify 없이도 flag는 허용되며 preview 값이 유효해야 한다", async () => {
    const fixture = await createFixture({
      "index.ts": `
        function f() { const x = 1; return x; }
        console.log(f());
      `,
    });
    cleanup = fixture.cleanup;

    // --mangle-preview는 --minify_identifiers가 켜져 있을 때만 실행된다.
    // 여기서는 minify 없이 호출하고 — stats 라인이 없는 것을 검증.
    const r = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      join(fixture.dir, "out.js"),
      "--mangle-preview",
      "--platform=node",
    ]);
    expect(r.exitCode).toBe(0);
    expect(r.stderr).not.toContain(STDERR_PREFIX);
  });
});
