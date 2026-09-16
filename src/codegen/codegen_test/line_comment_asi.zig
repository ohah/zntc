//! `//` 주석이 ASI 제한 위치에 올 때의 회귀 매트릭스 (#4648).
//!
//! `return` / `throw` / `yield` 는 ECMAScript `NoLineTerminator` 제한이 있어서, 피연산자
//! 앞에 줄바꿈이 들어가면 의미가 바뀐다 (`return` 은 undefined 반환, `throw` 는 syntax
//! error, `yield` 는 undefined 를 yield). 예전에는 선두 주석을 **줄바꿈 없이 인라인**으로
//! 붙여 이를 피했는데, 그 전략은 블록 주석에만 유효하다 — `//` 주석을 인라인으로 붙이면
//! 뒤따르는 코드가 전부 주석에 먹힌다.
//!
//! 지금은 줄 주석이 선두에 있으면 **괄호로 감싼다**. 괄호가 줄바꿈을 안전하게 만들어
//! 주석도 살고 ASI 도 안 끊긴다 (swc / babel 과 같은 전략).

const std = @import("std");
const helpers = @import("helpers.zig");
const e2eWithComments = helpers.e2eWithComments;

/// `return` / `throw` / `yield` 뒤에 곧바로 줄 주석이 붙어 뒤를 먹는 형태인지.
/// (`return // c` 처럼 키워드와 주석 사이에 괄호가 없는 경우 = 깨진 출력)
fn swallowsAfterKeyword(output: []const u8, keyword: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, output, i, keyword)) |k| {
        i = k + keyword.len;
        var j = i;
        while (j < output.len and output[j] == ' ') j += 1;
        if (j + 1 < output.len and output[j] == '/' and output[j + 1] == '/') return true;
    }
    return false;
}

test "#4648 return 피연산자 선두 줄 주석 — 괄호로 감싸 ASI 방지" {
    var r = try e2eWithComments(std.testing.allocator, "function f(){ return (\n // c\n 42); }", .{}, ".ts");
    defer r.deinit();
    try std.testing.expect(!swallowsAfterKeyword(r.output, "return"));
    // 주석은 보존되고, 값도 살아 있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "// c") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "42") != null);
}

test "#4648 throw 피연산자 선두 줄 주석" {
    var r = try e2eWithComments(std.testing.allocator, "function f(){ throw (\n // c\n new Error(\"x\")); }", .{}, ".ts");
    defer r.deinit();
    try std.testing.expect(!swallowsAfterKeyword(r.output, "throw"));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "new Error") != null);
}

test "#4648 yield 피연산자 선두 줄 주석 — return/throw 와 같은 제한" {
    var r = try e2eWithComments(std.testing.allocator, "function* g(){ yield (\n // c\n 42); }", .{}, ".ts");
    defer r.deinit();
    try std.testing.expect(!swallowsAfterKeyword(r.output, "yield"));
    // `yield` 뒤 줄바꿈도 ASI 를 유발하므로 괄호 안에 들어가야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield (") != null);
}

test "#4648 블록 주석 경로는 불변 — 인라인 유지 (anti-regression)" {
    // `/* @__PURE__ */` 같은 leading annotation 이 흔한 경로다. 괄호가 새로 생기면 안 된다.
    var r = try e2eWithComments(std.testing.allocator, "function f(){ return (\n /* c */\n 42); }", .{}, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return /* c */ 42") != null);
}

test "#4648 군더더기 괄호 제거는 그대로 (anti-regression)" {
    // 주석이 없으면 #4042 의 "군더더기 괄호 제거" 가 그대로 적용돼야 한다.
    var r = try e2eWithComments(std.testing.allocator, "function f(){ return (1 + 2); }", .{}, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return 1 + 2") != null);
}

test "#4648 괄호가 멤버 접근 대상일 때의 깊은 주석" {
    // 피연산자가 `( ... ).m()` 이면 span 시작이 `(` 라, 괄호만 벗기는 탐색으로는 안쪽
    // 주석을 놓친다 → 나중에 개행과 함께 나가 ASI. leftmost 토큰까지 내려가야 한다.
    var r = try e2eWithComments(std.testing.allocator, "function f(){ return (\n // c\n new Date(0)).getTime(); }", .{}, ".ts");
    defer r.deinit();
    try std.testing.expect(!swallowsAfterKeyword(r.output, "return"));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "getTime") != null);
}

test "#4648 minify — legal 줄 주석(@license) 뒤에도 실제 개행" {
    // `writeNewline` 은 minify 에서 no-op 이라, 줄 주석 뒤 개행을 별도로 강제하지 않으면
    // `return (// @license MIT42);}` 처럼 뒤가 전부 먹힌다. legal 주석은 minify 에서
    // 살아남으므로 실제로 발생하는 경로다.
    var r = try e2eWithComments(std.testing.allocator, "function f(){ return (\n // @license MIT\n 42); }", .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    const idx = std.mem.indexOf(u8, r.output, "// @license MIT") orelse return error.TestUnexpectedResult;
    const rest = r.output[idx + "// @license MIT".len ..];
    try std.testing.expect(rest.len > 0 and rest[0] == '\n');
}

test "#4648 minify — 일반 줄 주석은 버려지고 괄호도 안 생긴다" {
    var r = try e2eWithComments(std.testing.allocator, "function f(){ return (\n // c\n 42); }", .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(){return 42;}", r.output);
}

test "#4468 짝 — 비어 있지 않은 블록의 마지막 statement 뒤 주석이 블록 안에 남는다" {
    var r = try e2eWithComments(std.testing.allocator, "function f(){ return 42;\n // tail\n }", .{}, ".ts");
    defer r.deinit();
    const c = std.mem.indexOf(u8, r.output, "// tail") orelse return error.TestUnexpectedResult;
    const close = std.mem.lastIndexOfScalar(u8, r.output, '}') orelse return error.TestUnexpectedResult;
    // 주석이 닫는 `}` 보다 앞에 있어야 = 함수 밖으로 새지 않았다.
    try std.testing.expect(c < close);
}

test "#4648 yield 는 괄호 안 시퀀스 의미를 보존한다" {
    // `yield (a, b)` 와 `yield a, b` 는 의미가 다르다 — 괄호를 새로 씌우면서 안쪽
    // 시퀀스가 풀리면 안 된다.
    var r = try e2eWithComments(std.testing.allocator, "function* g(){ yield (\n // c\n 1, 2); }", .{}, ".ts");
    defer r.deinit();
    try std.testing.expect(!swallowsAfterKeyword(r.output, "yield"));
    // 시퀀스가 괄호 **안**에 갇혀 있어야 한다 — `yield 1,2` 로 풀리면 `yield 1` 후
    // `2` 를 따로 평가하는 다른 의미가 된다.
    const y = std.mem.indexOf(u8, r.output, "yield (") orelse return error.TestUnexpectedResult;
    const close = std.mem.indexOfScalarPos(u8, r.output, y, ')') orelse return error.TestUnexpectedResult;
    const inside = r.output[y..close];
    try std.testing.expect(std.mem.indexOfScalar(u8, inside, ',') != null);
}
