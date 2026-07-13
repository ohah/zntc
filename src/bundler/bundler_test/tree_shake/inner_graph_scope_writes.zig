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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 write 사이 read → 첫 write 보존.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LOOP_READBETWEEN_FIRST") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LOOP_READBETWEEN_SECOND") != null);
}

test "TreeShaking: #4503 preserves store read by a closure via a call between the stores" {
    // #4503 핵심 재현: 두 store 사이의 `flush()` 호출이 클로저로 `buf` 를 읽는다.
    // read 의 *소스 위치* 는 두 store 밖(앞)이라 ref_pos 기반 "사이에 read 없음" 판정이
    // 통과했고, 살아 있는 `buf = t` 가 삭제됐다(무성 오컴파일).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let buf = "";
        \\const out = [];
        \\function flush() { out.push(buf); }
        \\function emit(t) {
        \\  buf = t;
        \\  flush();
        \\  buf = "";
        \\}
        \\emit("CLOSURE_READ_ARG");
        \\console.log(out.join("|"));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // `buf = t` 가 남아야 한다 — emit 본문에 파라미터 대입이 보존됐는지로 확인.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "out.push(buf)") != null);
    // 삭제되면 emit 본문이 `{flush();buf=""}` 로 줄어든다. 대입이 2개(=t, ="") 있어야 한다.
    var writes: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, i, "buf = ")) |pos| : (i = pos + 1) writes += 1;
    try std.testing.expect(writes >= 2);
}

test "TreeShaking: #4503 preserves declaration initializer read by a closure" {
    // 선언 초기화자도 store 다. 뒤 재대입 사이에서 클로저가 읽으면 초기화자를 지우면 안 된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let buf = "CLOSURE_READ_INIT";
        \\const out = [];
        \\function flush() { out.push(buf); }
        \\flush();
        \\buf = "CLOSURE_READ_AFTER";
        \\flush();
        \\console.log(out.join("|"));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CLOSURE_READ_INIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CLOSURE_READ_AFTER") != null);
}

test "TreeShaking: #4503 preserves store when abrupt completion skips the overwrite" {
    // `x = 1; if (c) break lbl; x = 2;` — break 경로에서 뒤 store 가 실행되지 않아
    // 앞 store 가 살아남는다. 소스 순서 분석은 그 경로를 보지 못한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function f(c) {
        \\  let x = 0;
        \\  let pad1 = 5;
        \\  let pad2 = 7;
        \\  lbl: { x = "ABRUPT_FIRST_WRITE"; if (c) break lbl; x = "ABRUPT_SECOND_WRITE"; }
        \\  return [x, pad1, pad2];
        \\}
        \\console.log(f(true));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ABRUPT_FIRST_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ABRUPT_SECOND_WRITE") != null);
}

test "TreeShaking: #4503 guard does not over-preserve — unrelated closure keeps DSE working" {
    // 과잉 보수 방지: 사이에 클로저 호출이 있어도 그 클로저가 *다른* 심볼만 읽으면
    // 대상 심볼의 dead store 는 계속 제거돼야 한다 (size 회귀 방지).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const other = "OTHER";
        \\function log() { console.log(other); }
        \\function f() {
        \\  let x;
        \\  x = "UNRELATED_CLOSURE_DEAD";
        \\  log();
        \\  x = "UNRELATED_CLOSURE_LIVE";
        \\  return x;
        \\}
        \\console.log(f());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // x 를 읽는 클로저는 없다 → 첫 store 는 진짜 dead → 제거 유지.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNRELATED_CLOSURE_DEAD") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNRELATED_CLOSURE_LIVE") != null);
}

test "TreeShaking: #4503 preserves store on an outer var re-entered by recursion" {
    // 재진입: read/write 가 같은 함수(run) 안이라 "다른 실행 단위 read" 가드로는 못 잡는다.
    // 하지만 cur 은 run 밖(module)에 선언돼 호출이 겹치면 바인딩을 공유한다 — 두 store 사이의
    // inner() 가 run 을 다시 부르면 *다른 활성화* 가 앞 store 의 값을 읽는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let cur = null;
        \\const out = [];
        \\let done = false;
        \\function inner() { if (!done) { done = true; run("RECURSE_SECOND"); } }
        \\function run(v) {
        \\  out.push(cur);
        \\  cur = v;
        \\  inner();
        \\  cur = null;
        \\}
        \\run("RECURSE_FIRST");
        \\console.log(JSON.stringify(out));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // `cur = v` 가 살아 있어야 한다 — 지우면 out 이 [null, null] 이 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "cur = v") != null);
}

test "TreeShaking: #4503 preserves store on an outer var across await (interleaving)" {
    // await 지점에서 다른 호출이 끼어들면 module-level buf 를 공유한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let buf = "";
        \\const out = [];
        \\const tick = () => Promise.resolve();
        \\async function f(v) {
        \\  out.push("AWAIT_BEFORE=" + buf);
        \\  buf = v;
        \\  await tick();
        \\  buf = "";
        \\}
        \\Promise.all([f("a"), f("b")]).then(() => console.log(out.join("|")));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "buf = v") != null);
}

test "TreeShaking: #4503 guard does not over-preserve — break bound to a nested switch/loop" {
    // 창 안에 *완전히 포함된* loop/switch 에 묶이는 라벨 없는 break/continue 는 바깥 흐름을
    // 끊지 않는다 → 진짜 dead store 는 계속 제거돼야 한다 (size 회귀 방지).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function f(v) {
        \\  let x;
        \\  x = "NESTED_BREAK_DEAD";
        \\  switch (v) { case 1: console.log(1); break; default: break; }
        \\  for (const q of [1]) { if (q) break; }
        \\  const o = { m() { return 1; } };
        \\  o.m();
        \\  x = "NESTED_BREAK_LIVE";
        \\  return x;
        \\}
        \\console.log(f(1));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 중첩 switch 의 break, 중첩 loop 의 break, 객체 메서드의 return 은 전부 바깥 흐름과 무관.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NESTED_BREAK_DEAD") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NESTED_BREAK_LIVE") != null);
}
