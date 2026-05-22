const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "TreeShaking: innerGraph prunes overwritten assignment inside ESM exported function body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export function runAll() {
        \\  let value;
        \\  value = "INNER_GRAPH_ESM_FN_DEAD_WRITE";
        \\  value = "INNER_GRAPH_ESM_FN_FINAL_WRITE";
        \\  return value;
        \\}
        \\console.log(runAll());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_FN_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_FN_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph prunes overwritten assignment inside ESM exported arrow body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const runAll = () => {
        \\  let value;
        \\  value = "INNER_GRAPH_ESM_ARROW_DEAD_WRITE";
        \\  value = "INNER_GRAPH_ESM_ARROW_FINAL_WRITE";
        \\  return value;
        \\};
        \\console.log(runAll());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_ARROW_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_ARROW_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph preserves destructuring declaration initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let { value } = { value: "INNER_GRAPH_DESTRUCT_INIT" };
        \\value = "INNER_GRAPH_DESTRUCT_FINAL";
        \\console.log(value);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_DESTRUCT_INIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_DESTRUCT_FINAL") != null);
}

test "TreeShaking: innerGraph preserves multi-declarator declaration initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let first = "INNER_GRAPH_MULTI_INIT", second = "INNER_GRAPH_MULTI_SECOND";
        \\first = "INNER_GRAPH_MULTI_FINAL";
        \\console.log(first, second);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_MULTI_INIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_MULTI_SECOND") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_MULTI_FINAL") != null);
}

test "TreeShaking: innerGraph prunes overwritten assignment inside function body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function read() {
        \\  let value;
        \\  value = "INNER_GRAPH_FN_DEAD_WRITE";
        \\  value = "INNER_GRAPH_FN_FINAL_WRITE";
        \\  return value;
        \\}
        \\console.log(read());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FN_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FN_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph prunes overwritten declaration initializer inside function body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function read() {
        \\  let value = "INNER_GRAPH_FN_DEAD_INIT";
        \\  value = "INNER_GRAPH_FN_INIT_FINAL";
        \\  return value;
        \\}
        \\console.log(read());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FN_INIT_FINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FN_DEAD_INIT") == null);
}

test "TreeShaking: innerGraph prunes overwritten assignment inside block body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\{
        \\  let value;
        \\  value = "INNER_GRAPH_BLOCK_DEAD_WRITE";
        \\  value = "INNER_GRAPH_BLOCK_FINAL_WRITE";
        \\  console.log(value);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_BLOCK_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_BLOCK_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph prunes overwritten declaration initializer inside block body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\{
        \\  let value = "INNER_GRAPH_BLOCK_DEAD_INIT";
        \\  value = "INNER_GRAPH_BLOCK_INIT_FINAL";
        \\  console.log(value);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_BLOCK_INIT_FINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_BLOCK_DEAD_INIT") == null);
}

test "TreeShaking: innerGraph preserves function body assignment captured by closure before overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function read() {
        \\  let value;
        \\  value = "INNER_GRAPH_CAPTURED_WRITE";
        \\  const capture = () => value;
        \\  value = "INNER_GRAPH_AFTER_CAPTURE";
        \\  return [capture(), value];
        \\}
        \\console.log(read());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_CAPTURED_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_AFTER_CAPTURE") != null);
}

test "TreeShaking: innerGraph prunes overwritten assignment inside control-flow block (b1)" {
    // innerGraph (ROADMAP b1): control-flow 블록 *내부* 의 straight-line dead store 도 제거한다.
    // if-블록 본문에서 value 가 즉시 덮어써지므로 첫 write 는 dead → 제거, FINAL 은 유지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value;
        \\if (Math.random()) {
        \\  value = "INNER_GRAPH_IF_BLOCK_WRITE";
        \\  value = "INNER_GRAPH_IF_BLOCK_FINAL";
        \\  console.log(value);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 덮어써진 첫 write 는 제거.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_IF_BLOCK_WRITE") == null);
    // 최종 값은 유지(console.log 가 읽음).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_IF_BLOCK_FINAL") != null);
}

test "TreeShaking: innerGraph keeps cross-branch write (b1 soundness — no CFG)" {
    // soundness: `if(c) v=A; v=B; use(v)` 에서 v=A 는 else 경로에서 살아있어(B 만 실행 안 됨)
    // 제거하면 안 된다. (b1) 은 *블록 내부* straight-line 만 보므로 분기 경계의 v=A 를 건드리지
    // 않는다 — cross-branch DCE 미시도. v=A 가 보존돼야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let v = "CROSS_BRANCH_BASE";
        \\if (Math.random()) { v = "CROSS_BRANCH_IF"; }
        \\console.log(v);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 분기 밖 base write 는 else 경로에서 관측되므로 보존(cross-branch 미제거).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CROSS_BRANCH_BASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CROSS_BRANCH_IF") != null);
}

test "TreeShaking: innerGraph keeps overwritten write inside try block (b1 soundness — throw observability)" {
    // soundness(code-review 실증): try 안에서 두 write 사이 throw 가능 statement 가 있으면 첫
    // write 는 catch 에서 관측될 수 있다 — throw 시 두번째 write 가 실행 안 되므로. (b1) 은 try/
    // catch/finally 를 분석 대상에서 제외하므로 x=LIVE 가 보존돼야 한다(제거 시 catch 가 undefined).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let x;
        \\try {
        \\  x = "TRY_BLOCK_LIVE";
        \\  globalThis.mayThrow();
        \\  x = "TRY_BLOCK_DEAD";
        \\} catch (e) {
        \\  console.log(x);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // throw 시 catch 가 읽는 첫 write 는 제거하면 안 된다(silent miscompile 방지).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TRY_BLOCK_LIVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TRY_BLOCK_DEAD") != null);
}

test "TreeShaking: innerGraph keeps read-between write inside control-flow block (b1 soundness)" {
    // soundness: 블록 내부라도 두 write 사이에 read 가 있으면 첫 write 는 살아있다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let v;
        \\for (let i = 0; i < 1; i++) {
        \\  v = "LOOP_READBETWEEN_FIRST";
        \\  console.log(v);
        \\  v = "LOOP_READBETWEEN_SECOND";
        \\}
        \\console.log(v);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 write 사이 read → 첫 write 보존.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LOOP_READBETWEEN_FIRST") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LOOP_READBETWEEN_SECOND") != null);
}
