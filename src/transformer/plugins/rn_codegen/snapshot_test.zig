//! RN 버전별 spec snapshot 에 대해 ZTS rn_codegen_plugin 의 출력이
//! `@react-native/codegen` reference 와 **의미적으로** 동등한지 검증.
//!
//! 비교 단위: view config 객체에 등록되는 키 set (= RN runtime contract) +
//! runtime contract 에 영향을 주는 핵심 value:
//!   - top-level: uiViewClassName, validAttributes, directEventTypes, bubblingEventTypes
//!   - validAttributes 의 attribute 이름 set
//!   - directEventTypes / bubblingEventTypes 의 event name set
//!   - **uiViewClassName value** (RN native 측의 등록 클래스 이름과 1:1 매칭 필수 —
//!     `paperComponentName` 옵션이 있으면 그 값이 와야 함)
//!   - **`export const Commands` 존재 여부** (codegenNativeCommands → dispatchCommand
//!     변환이 누락되면 imperative API 가 깨짐)
//!
//! cosmetic 차이 (quote style / prop order / trailing comma / value formatting / Object.assign +
//! ConditionallyIgnoredEventHandlers wrapper) 는 무시 — 양쪽이 같은 attribute / event 를
//! 등록하면 RN runtime 동작 동등.
//!
//! 본 PR 시점에는 모든 spec 의 key set 이 일치해야 통과 — ZTS 가 attribute 누락하면 fail.
//!
//! 디렉토리 구조: `tests/codegen-snapshots/rn-<version>/{fixtures,golden}/`. 새 RN
//! 버전 추가는 디렉토리 생성 + golden 재생성 + 본 파일에 test block 추가.

const std = @import("std");
const codegen_plugin = @import("../rn_codegen_plugin.zig");

const SNAPSHOTS_ROOT = "tests/codegen-snapshots";

fn loadFile(
    alloc: std.mem.Allocator,
    suite: []const u8,
    sub: []const u8,
    name: []const u8,
) ![]u8 {
    const path = try std.fs.path.join(alloc, &.{ SNAPSHOTS_ROOT, suite, sub, name });
    defer alloc.free(path);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, 1 << 20);
}

/// `__INTERNAL_VIEW_CONFIG = ` 다음의 object literal (`{...}`) 본체 반환. brace 카운팅 —
/// string literal 안의 brace 무시 (single/double quote + backslash escape 인식).
fn extractViewConfig(src: []const u8) ?[]const u8 {
    const marker = "__INTERNAL_VIEW_CONFIG";
    const m = std.mem.indexOf(u8, src, marker) orelse return null;
    var i = m + marker.len;
    while (i < src.len and src[i] != '{') : (i += 1) {}
    if (i >= src.len) return null;

    const start = i;
    var depth: usize = 0;
    var in_string: u8 = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < src.len) {
                i += 1;
            } else if (c == in_string) {
                in_string = 0;
            }
            continue;
        }
        switch (c) {
            '\'', '"' => in_string = c,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return src[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn isIdStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}
fn isIdCont(c: u8) bool {
    return isIdStart(c) or (c >= '0' and c <= '9');
}

/// expression body 에서 RN runtime 이 보는 attribute / event 키 set 추출.
///   - `{ ... }` (object literal) — top-level key 들 + spread/inner-call 평탄화
///   - `(args)` (call form, `Object.assign(A, B)` 같은 reference-only wrapper) — args
///     순회하며 object literal 인 인자의 키 평탄화
///   - 그 외 (string / ident.member / number) — 빈 set (= 등록 attribute 없음)
fn parseKeysFromExpr(
    alloc: std.mem.Allocator,
    body: []const u8,
) !std.StringArrayHashMapUnmanaged(void) {
    var keys: std.StringArrayHashMapUnmanaged(void) = .{};
    errdefer keys.deinit(alloc);
    if (body.len < 2) return keys;

    if (body[0] == '{' and body[body.len - 1] == '}') {
        try collectKeysIntoSet(alloc, body[1 .. body.len - 1], &keys);
    } else if (body[0] == '(' and body[body.len - 1] == ')') {
        try collectFromCallArgs(alloc, body[1 .. body.len - 1], &keys);
    }
    return keys;
}

const CollectError = std.mem.Allocator.Error;

/// 본체 (without outer braces) 에서 depth 0 의 `key:` 들 + spread/call 풀어 모음.
fn collectKeysIntoSet(
    alloc: std.mem.Allocator,
    body: []const u8,
    keys: *std.StringArrayHashMapUnmanaged(void),
) CollectError!void {
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < body.len) {
        const c = body[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < body.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                in_string = c;
                i += 1;
            },
            '{', '[', '(' => {
                i = skipBalanced(body, i) orelse body.len;
            },
            '.' => {
                // spread `...X(...)` 또는 member access. spread 면 argument object 풀어 평탄화.
                if (i + 2 < body.len and body[i + 1] == '.' and body[i + 2] == '.') {
                    i = try collectFromSpread(alloc, body, i + 3, keys);
                } else {
                    i += 1;
                }
            },
            else => {
                if (isIdStart(c)) {
                    const start = i;
                    while (i < body.len and isIdCont(body[i])) i += 1;
                    const ident = body[start..i];
                    // 다음 non-ws 가 `:` 이면 object key.
                    var j = i;
                    while (j < body.len and std.ascii.isWhitespace(body[j])) j += 1;
                    if (j < body.len and body[j] == ':') {
                        try keys.put(alloc, ident, {});
                    }
                } else {
                    i += 1;
                }
            },
        }
    }
}

/// spread 직후 위치 (점 3 개 다음) — `Object.assign(A, B, ...)` 또는 `Foo({...})` 같은 형태.
/// argument 들을 순회해 object literal 발견 시 그 안의 키를 keys 에 평탄화.
fn collectFromSpread(
    alloc: std.mem.Allocator,
    body: []const u8,
    spread_start: usize,
    keys: *std.StringArrayHashMapUnmanaged(void),
) CollectError!usize {
    var i = spread_start;
    while (i < body.len and isIdCont(body[i])) i += 1;
    // skip member access
    while (i < body.len and (body[i] == '.' or isIdCont(body[i]))) i += 1;
    if (i >= body.len or body[i] != '(') {
        return i;
    }
    const args_end = skipBalanced(body, i) orelse return body.len;
    const args = body[i + 1 .. args_end - 1];
    try collectFromCallArgs(alloc, args, keys);
    return args_end;
}

/// 콤마로 분리된 인자 list. 각 인자가 object literal 이면 키 평탄화.
fn collectFromCallArgs(
    alloc: std.mem.Allocator,
    args: []const u8,
    keys: *std.StringArrayHashMapUnmanaged(void),
) CollectError!void {
    var i: usize = 0;
    var in_string: u8 = 0;
    var arg_start: usize = 0;
    while (i < args.len) {
        const c = args[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < args.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                in_string = c;
                i += 1;
            },
            '{', '[', '(' => {
                i = skipBalanced(args, i) orelse args.len;
            },
            ',' => {
                try maybeFlattenArg(alloc, args[arg_start..i], keys);
                i += 1;
                arg_start = i;
            },
            else => i += 1,
        }
    }
    if (arg_start < args.len) try maybeFlattenArg(alloc, args[arg_start..], keys);
}

fn maybeFlattenArg(
    alloc: std.mem.Allocator,
    arg: []const u8,
    keys: *std.StringArrayHashMapUnmanaged(void),
) CollectError!void {
    const trimmed = std.mem.trim(u8, arg, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return;
    try collectKeysIntoSet(alloc, trimmed[1 .. trimmed.len - 1], keys);
}

/// `body[start]` 가 여는 괄호 (`{`/`[`/`(`) 일 때, 매칭하는 닫는 괄호 다음 위치 반환.
/// string literal escape 인식.
fn skipBalanced(body: []const u8, start: usize) ?usize {
    if (start >= body.len) return null;
    const open = body[start];
    const close: u8 = switch (open) {
        '{' => '}',
        '[' => ']',
        '(' => ')',
        else => return null,
    };
    var i = start + 1;
    var depth: usize = 1;
    var in_string: u8 = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < body.len) {
                i += 1;
            } else if (c == in_string) {
                in_string = 0;
            }
            continue;
        }
        switch (c) {
            '\'', '"' => in_string = c,
            '{', '[', '(' => depth += 1,
            '}', ']', ')' => {
                if (c == close) {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                } else {
                    depth -= 1;
                }
            },
            else => {},
        }
    }
    return null;
}

/// top-level body 에서 특정 key 의 value 본체 (object literal 또는 call expression) 추출.
/// 예: `extractSection(body, "validAttributes")` → `{ ... }` body string.
fn extractSection(body: []const u8, key: []const u8) ?[]const u8 {
    if (body.len < 2 or body[0] != '{' or body[body.len - 1] != '}') return null;
    const inner = body[1 .. body.len - 1];

    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < inner.len) {
                i += 2;
                continue;
            }
            if (c == in_string) in_string = 0;
            i += 1;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                in_string = c;
                i += 1;
            },
            '{', '[', '(' => {
                i = skipBalanced(inner, i) orelse return null;
            },
            else => {
                if (isIdStart(c)) {
                    const start = i;
                    while (i < inner.len and isIdCont(inner[i])) i += 1;
                    const ident = inner[start..i];
                    var j = i;
                    while (j < inner.len and std.ascii.isWhitespace(inner[j])) j += 1;
                    if (j < inner.len and inner[j] == ':' and std.mem.eql(u8, ident, key)) {
                        // value 시작 위치
                        var v = j + 1;
                        while (v < inner.len and std.ascii.isWhitespace(inner[v])) v += 1;
                        if (v >= inner.len) return null;
                        // value 가 object literal / array / call 이면 매칭 본체 반환.
                        // 그 외 (string / ident.member / number) 면 다음 콤마/끝 까지.
                        if (inner[v] == '{' or inner[v] == '[' or inner[v] == '(') {
                            const end = skipBalanced(inner, v) orelse return null;
                            return inner[v..end];
                        }
                        var k = v;
                        var s: u8 = 0;
                        while (k < inner.len) : (k += 1) {
                            const cc = inner[k];
                            if (s != 0) {
                                if (cc == '\\' and k + 1 < inner.len) k += 1 else if (cc == s) s = 0;
                                continue;
                            }
                            if (cc == '\'' or cc == '"') s = cc else if (cc == ',') break;
                        }
                        return inner[v..k];
                    }
                } else {
                    i += 1;
                }
            },
        }
    }
    return null;
}

fn formatKeyDiff(
    alloc: std.mem.Allocator,
    section: []const u8,
    a: *const std.StringArrayHashMapUnmanaged(void),
    b: *const std.StringArrayHashMapUnmanaged(void),
    label_a: []const u8,
    label_b: []const u8,
) !void {
    var only_a: std.ArrayList([]const u8) = .empty;
    defer only_a.deinit(alloc);
    var only_b: std.ArrayList([]const u8) = .empty;
    defer only_b.deinit(alloc);

    var it_a = a.iterator();
    while (it_a.next()) |e| if (!b.contains(e.key_ptr.*)) try only_a.append(alloc, e.key_ptr.*);
    var it_b = b.iterator();
    while (it_b.next()) |e| if (!a.contains(e.key_ptr.*)) try only_b.append(alloc, e.key_ptr.*);

    if (only_a.items.len == 0 and only_b.items.len == 0) return;

    std.debug.print("[{s}] key mismatch\n", .{section});
    if (only_a.items.len > 0) {
        std.debug.print("  in {s} only: ", .{label_a});
        for (only_a.items, 0..) |k, idx| {
            if (idx > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{k});
        }
        std.debug.print("\n", .{});
    }
    if (only_b.items.len > 0) {
        std.debug.print("  in {s} only: ", .{label_b});
        for (only_b.items, 0..) |k, idx| {
            if (idx > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{k});
        }
        std.debug.print("\n", .{});
    }
}

fn compareKeySets(
    alloc: std.mem.Allocator,
    section: []const u8,
    ref_body: []const u8,
    zts_body: []const u8,
) !void {
    var ref_keys = try parseKeysFromExpr(alloc, ref_body);
    defer ref_keys.deinit(alloc);
    var zts_keys = try parseKeysFromExpr(alloc, zts_body);
    defer zts_keys.deinit(alloc);

    if (ref_keys.count() == zts_keys.count()) {
        var match = true;
        var it = ref_keys.iterator();
        while (it.next()) |e| {
            if (!zts_keys.contains(e.key_ptr.*)) {
                match = false;
                break;
            }
        }
        if (match) return;
    }
    try formatKeyDiff(alloc, section, &ref_keys, &zts_keys, "reference", "ZTS");
    return error.TestKeySetMismatch;
}

/// `uiViewClassName: 'X'` 의 X 추출. quote 종류 무시. 없으면 null.
fn extractUiViewClassName(obj_body: []const u8) ?[]const u8 {
    const v = extractSection(obj_body, "uiViewClassName") orelse return null;
    const trimmed = std.mem.trim(u8, v, " \t\n\r");
    if (trimmed.len < 2) return null;
    const q = trimmed[0];
    if (q != '\'' and q != '"') return null;
    if (trimmed[trimmed.len - 1] != q) return null;
    return trimmed[1 .. trimmed.len - 1];
}

/// `export const Commands` 가 source 어디든 등장하는지 — codegenNativeCommands 가
/// dispatchCommand 래퍼로 변환됐는지 검증. value 자체는 비교 안 함 (cosmetic 차이 큼).
fn hasCommandsExport(src: []const u8) bool {
    return std.mem.indexOf(u8, src, "export const Commands") != null;
}

fn compareCase(suite: []const u8, fixture_name: []const u8, golden_name: []const u8) !void {
    const alloc = std.testing.allocator;

    const fixture = try loadFile(alloc, suite, "fixtures", fixture_name);
    defer alloc.free(fixture);
    const golden = try loadFile(alloc, suite, "golden", golden_name);
    defer alloc.free(golden);

    const plugin = codegen_plugin.plugin();
    const zts_out = (try plugin.transform.?(plugin.context, fixture, fixture_name, alloc)) orelse {
        std.debug.print("[{s}] ZTS plugin returned null — fixture not transformed\n", .{fixture_name});
        return error.TestUnexpectedNull;
    };
    defer alloc.free(zts_out);

    const zts_obj = extractViewConfig(zts_out) orelse {
        std.debug.print("[{s}] ZTS output has no __INTERNAL_VIEW_CONFIG\n", .{fixture_name});
        return error.TestExpectedExtraction;
    };
    const ref_obj = extractViewConfig(golden) orelse {
        std.debug.print("[{s}] golden has no __INTERNAL_VIEW_CONFIG\n", .{fixture_name});
        return error.TestExpectedExtraction;
    };

    // top-level: uiViewClassName / validAttributes / directEventTypes / bubblingEventTypes 가
    // 모두 같은 set 으로 등록되었는지.
    try compareKeySets(alloc, fixture_name, ref_obj, zts_obj);

    // 각 section 의 attribute / event 이름 set. 한 쪽만 section 이 있으면 silent skip
    // 이 아니라 명시적 fail — 회귀 보호 신호 누락 방지.
    try compareSectionKeySets(alloc, "validAttributes", ref_obj, zts_obj);
    try compareSectionKeySets(alloc, "directEventTypes", ref_obj, zts_obj);
    try compareSectionKeySets(alloc, "bubblingEventTypes", ref_obj, zts_obj);

    // uiViewClassName value 일치 — `paperComponentName` 옵션이 있는 spec 에서 잘못된
    // 클래스 이름을 emit 하면 RN native 측에서 컴포넌트 not found.
    const ref_cls = extractUiViewClassName(ref_obj);
    const zts_cls = extractUiViewClassName(zts_obj);
    if (ref_cls == null or zts_cls == null or !std.mem.eql(u8, ref_cls.?, zts_cls.?)) {
        std.debug.print(
            "[{s}] uiViewClassName mismatch — ref={s} zts={s}\n",
            .{ fixture_name, ref_cls orelse "<missing>", zts_cls orelse "<missing>" },
        );
        return error.TestUiViewClassNameMismatch;
    }

    // `codegenNativeCommands` 호출이 fixture 에 있으면 reference 가 `export const Commands`
    // 를 emit. ZTS 가 같은 emit 을 안 하면 imperative `Commands.X(ref, ...)` 호출이 깨짐.
    const ref_has_cmds = hasCommandsExport(golden);
    const zts_has_cmds = hasCommandsExport(zts_out);
    if (ref_has_cmds != zts_has_cmds) {
        std.debug.print(
            "[{s}] Commands export presence mismatch — ref={s} zts={s}\n",
            .{
                fixture_name,
                if (ref_has_cmds) "present" else "missing",
                if (zts_has_cmds) "present" else "missing",
            },
        );
        return error.TestCommandsExportMismatch;
    }
}

fn compareSectionKeySets(
    alloc: std.mem.Allocator,
    section: []const u8,
    ref_obj: []const u8,
    zts_obj: []const u8,
) !void {
    const ref_sec = extractSection(ref_obj, section);
    const zts_sec = extractSection(zts_obj, section);
    if (ref_sec == null and zts_sec == null) return;
    if (ref_sec == null or zts_sec == null) {
        std.debug.print("[{s}] section presence mismatch — ref={s} zts={s}\n", .{
            section,
            if (ref_sec) |_| "present" else "missing",
            if (zts_sec) |_| "present" else "missing",
        });
        return error.TestSectionPresenceMismatch;
    }
    try compareKeySets(alloc, section, ref_sec.?, zts_sec.?);
}

test "snapshot rn-0.85: ScreenNativeComponent semantic-eq @react-native/codegen" {
    try compareCase("rn-0.85", "ScreenNativeComponent.ts", "ScreenNativeComponent.golden.js");
}

test "snapshot rn-0.85: ModalScreenNativeComponent semantic-eq @react-native/codegen" {
    try compareCase("rn-0.85", "ModalScreenNativeComponent.ts", "ModalScreenNativeComponent.golden.js");
}

test "snapshot rn-0.85: ScreenStackHeaderConfigNativeComponent semantic-eq @react-native/codegen" {
    try compareCase("rn-0.85", "ScreenStackHeaderConfigNativeComponent.ts", "ScreenStackHeaderConfigNativeComponent.golden.js");
}

test "snapshot rn-0.85: BottomTabsScreenNativeComponent semantic-eq @react-native/codegen" {
    try compareCase("rn-0.85", "BottomTabsScreenNativeComponent.ts", "BottomTabsScreenNativeComponent.golden.js");
}
