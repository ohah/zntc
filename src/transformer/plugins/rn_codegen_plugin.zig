//! ZNTC Native Codegen Plugin — `@react-native/codegen` 의 view config inline 등가.
//!
//! `*NativeComponent.{js,ts}` spec 파일을 변환:
//!
//! ```ts
//! type NativeProps = $ReadOnly<{ color: ColorValue, ... }>;
//! export default codegenNativeComponent<NativeProps>('MyView');
//! ```
//!
//! → 다음과 같이 통째 교체:
//!
//! ```ts
//! const NativeComponentRegistry = require('react-native/Libraries/NativeComponent/NativeComponentRegistry');
//! let nativeComponentName = 'MyView';
//! const __INTERNAL_VIEW_CONFIG = { ... };
//! export default NativeComponentRegistry.get(nativeComponentName, () => __INTERNAL_VIEW_CONFIG);
//! ```
//!
//! 이렇게 inline 처리하면 RN 런타임이 lazy 등록 race (`View config not found for component
//! 'DebuggingOverlay'` 등 #2348 § 8) 를 회피한다.
//!
//! 파이프라인:
//!   1. 파일명 / `codegenNativeComponent` substring fast-skip
//!   2. 소스 텍스트 스캔으로 type argument 이름 추출 (`<NativeProps>`)
//!   3. ZNTC Parser 로 파싱 → type_index 빌드
//!   4. NativeProps 의 declaration 을 schema_builder 에 넘겨 ComponentShape 빌드
//!   5. view_config_emitter 로 JS 문자열 생성
//!   6. 전체 파일 교체용 wrapper 조립
//!
//! 모든 에러는 silent skip (`return null`) — caller 가 원본 소스 그대로 사용.
//! 실패 케이스 (cross-file type, complex spec 등) 는 RN 런타임의 lazy 등록 path 로
//! fallback (대부분의 라이브러리는 정상 작동, race condition 컴포넌트만 위험).
//!
//! Plugin 훅: `transform` (`bundler/graph.zig:1397` "소스 읽기 후, 파싱 전").

const std = @import("std");
const Plugin = @import("../../bundler/plugin.zig").Plugin;
const PluginError = @import("../../bundler/plugin.zig").PluginError;
const Scanner = @import("../../lexer/scanner.zig").Scanner;
const Parser = @import("../../parser/parser.zig").Parser;
const ast_mod = @import("../../parser/ast.zig");
const es_helpers = @import("../es_helpers.zig");
const NodeIndex = ast_mod.NodeIndex;
const stripQuotes = @import("../../bundler/import_scanner.zig").stripQuotes;

const codegen = @import("rn_codegen/mod.zig");
const type_index_mod = codegen.type_index;
const schema_builder = codegen.schema_builder;
const view_config_emitter = codegen.view_config_emitter;
const stmt_info = @import("../../bundler/stmt_info.zig");

// `@react-native/codegen` (`parsers-commons.js:689,968,1048` + `parsers-primitives.js:538`)
// 와 `babel-plugin-codegen/index.js:74-149` 가 marker 이름을 inline literal 로 직접 비교.
// ZNTC 도 동일 패턴 — 별도 상수 없이 텍스트 스캔 / AST callee 비교에 inline 사용.

pub fn plugin() Plugin {
    return .{
        .name = "rn-codegen",
        .transform = onTransform,
    };
}

fn onTransform(
    ctx: ?*anyopaque,
    code: []const u8,
    id: []const u8,
    alloc: std.mem.Allocator,
) PluginError!?[]const u8 {
    _ = ctx;

    // 확장자 fast-skip — .js/.ts 만 처리 (parser configureFromExtension 의존). spec
    // 파일 식별은 filename suffix 가 아니라 AST 레벨 검증 (`findComponentName`) 으로 결정 —
    // export default codegenNativeComponent(...) 패턴이 정확한 식별자.
    if (!std.mem.endsWith(u8, id, ".js") and !std.mem.endsWith(u8, id, ".ts")) return null;
    if (std.mem.indexOf(u8, code, "codegenNativeComponent") == null) return null;

    const props_type_name = extractTypeArg(code, "codegenNativeComponent") orelse return null;

    var scanner = Scanner.init(alloc, code) catch return null;
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    parser.configureFromExtension(std.fs.path.extension(id));
    if (std.mem.endsWith(u8, id, ".js")) {
        parser.is_flow = true;
        // RN spec 파일은 import/export 사용 — Flow `.js` 도 모듈 모드 필요. configureFromExtension
        // 이 .js 를 Script 로 두므로 명시적 module 모드 토글.
        parser.is_module = true;
        parser.scanner.is_module = true;
    }

    const program = parser.parse() catch return null;
    if (parser.errors.items.len > 0) return null;

    var type_index = type_index_mod.build(&parser.ast, program, alloc) catch return null;
    defer type_index.deinit(alloc);

    const decl_idx = type_index.get(props_type_name) orelse return null;
    const call_idx = findCodegenCall(&parser.ast, program) orelse return null;
    const component_name = extractCallArg0String(&parser.ast, call_idx) orelse return null;
    const paper_component_name = extractPaperComponentName(&parser.ast, call_idx);

    // commands 는 옵셔널 — `export const Commands = codegenNativeCommands<T>(...)` 패턴이
    // 있으면 T 의 interface decl 을 builder 에 전달.
    const commands_type_name = extractTypeArg(code, "codegenNativeCommands");
    const commands_decl_idx = if (commands_type_name) |n| type_index.get(n) else null;

    const shape = schema_builder.build(
        &parser.ast,
        &type_index,
        component_name,
        paper_component_name,
        decl_idx,
        commands_decl_idx,
        alloc,
    ) catch return null;
    defer alloc.free(shape.props);
    defer alloc.free(shape.events);
    defer if (shape.hasCommands()) {
        for (shape.commands) |c| alloc.free(c.type_annotation.params);
        alloc.free(shape.commands);
    };

    const view_config = view_config_emitter.emit(shape, alloc) catch return null;
    defer alloc.free(view_config);

    return assembleFileReplacement(
        shape.nativeName(),
        view_config,
        shape.hasCommands(),
        alloc,
    ) catch return null;
}

/// `<MARKER><TYPE_NAME>` 에서 `TYPE_NAME` 추출 (예: `codegenNativeComponent<NativeProps>`,
/// `codegenNativeCommands<NativeCommands>`). 정상적인 spec 파일은 이 형태이므로 단순
/// 텍스트 스캔으로 충분. AST 레벨에선 type argument 가 expression context 에서
/// speculative parse 후 폐기됨.
fn extractTypeArg(code: []const u8, marker: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, code, search_from, marker)) |m| {
        const after = m + marker.len;
        if (after >= code.len) return null;
        if (code[after] != '<') {
            search_from = after;
            continue;
        }
        const name_start = after + 1;
        const name_end = std.mem.indexOfPos(u8, code, name_start, ">") orelse return null;
        const name = std.mem.trim(u8, code[name_start..name_end], " \t\n");
        if (name.len == 0) return null;
        return name;
    }
    return null;
}

/// program 자식 중 `export default codegenNativeComponent('Name', { ... })` 패턴을
/// 찾아 그 call_expression 의 NodeIndex 반환. 첫 매칭만 — spec 파일은 보통 한 개.
fn findCodegenCall(ast: *const ast_mod.Ast, program_idx: NodeIndex) ?NodeIndex {
    const program = ast.getNode(program_idx);
    if (program.tag != .program) return null;

    const list = program.data.list;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const stmt: NodeIndex = @enumFromInt(ast.extra_data.items[list.start + i]);
        const node = ast.getNode(stmt);
        if (unwrapToCallExpression(ast, stmt, node)) |call_idx| return call_idx;
    }
    return null;
}

/// `export default codegenNativeComponent(...)` 형태에서 call_expression 추출.
/// 실제 RN spec 의 export 가 transparent wrapper (TS as/satisfies/non_null/instantiation,
/// Flow as/type_cast, parenthesize) 로 감싸 있어도 통과 — `es_helpers.unwrapTransparentWrappers`
/// 가 8 종 wrapper 다층 처리 (#2030, #2034 의 super-tag check 와 같은 패턴).
fn unwrapToCallExpression(ast: *const ast_mod.Ast, _: NodeIndex, node: ast_mod.Node) ?NodeIndex {
    if (node.tag != .export_default_declaration) return null;
    const inner_idx = es_helpers.unwrapTransparentWrappersAst(ast, node.data.unary.operand);
    if (inner_idx == .none) return null;
    const inner = ast.getNode(inner_idx);
    if (inner.tag != .call_expression) return null;
    return if (callIsCodegenMarker(ast, inner)) inner_idx else null;
}

fn callIsCodegenMarker(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    const e = node.data.extra;
    if (e >= ast.extra_data.items.len) return false;
    const callee_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
    const callee = ast.getNode(callee_idx);
    if (callee.tag != .identifier_reference) return false;
    return std.mem.eql(u8, ast.getText(callee.span), "codegenNativeComponent");
}

/// call_expression 의 첫 인자가 string literal 이면 unquoted 텍스트 반환.
fn extractCallArg0String(ast: *const ast_mod.Ast, call_idx: NodeIndex) ?[]const u8 {
    const node = ast.getNode(call_idx);
    const e = node.data.extra;
    // call_expression layout: extra = [callee, args_start, args_len, flags]
    if (e + 2 >= ast.extra_data.items.len) return null;
    const args_start = ast.extra_data.items[e + 1];
    const args_len = ast.extra_data.items[e + 2];
    if (args_len == 0) return null;
    const arg0_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    const arg0 = ast.getNode(arg0_idx);
    if (arg0.tag != .string_literal) return null;
    const raw = ast.getText(arg0.data.string_ref);
    return stripQuotes(raw);
}

/// `codegenNativeComponent('Name', { paperComponentName: 'X', ... })` 의 두 번째 인자
/// (options object) 안에서 `paperComponentName` string property 추출. 옵션이 없거나
/// paperComponentName 키가 없으면 null. RN spec 의 Paper(legacy) 호환용 — RN runtime 의
/// `uiViewClassName` 은 이 값을 우선 (없으면 첫 인자 사용).
///
/// 인식 한계: `{ paperComponentName: 'X' }` 와 `{ "paperComponentName": 'X' }` 만.
/// computed key (`{ [k]: 'X' }`), shorthand, escape-bearing string 은 모두 reject —
/// RN spec 에서 등장 가능성 0.
fn extractPaperComponentName(ast: *const ast_mod.Ast, call_idx: NodeIndex) ?[]const u8 {
    const node = ast.getNode(call_idx);
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return null;
    const args_start = ast.extra_data.items[e + 1];
    const args_len = ast.extra_data.items[e + 2];
    if (args_len < 2) return null;
    const arg1_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start + 1]);
    const arg1 = ast.getNode(arg1_idx);
    if (arg1.tag != .object_expression) return null;

    const props = arg1.data.list;
    var i: u32 = 0;
    while (i < props.len) : (i += 1) {
        const prop_idx: NodeIndex = @enumFromInt(ast.extra_data.items[props.start + i]);
        const prop = ast.getNode(prop_idx);
        if (prop.tag != .object_property) continue;
        const key_name = stmt_info.plainObjectKeyName(ast, prop.data.binary.left) orelse continue;
        if (!std.mem.eql(u8, key_name, "paperComponentName")) continue;
        return stmt_info.plainStringLiteralValue(ast, ast_mod.Ast.objectPropertyValue(prop));
    }
    return null;
}

/// 최종 파일 교체 문자열 조립. RN 런타임이 기대하는 정확한 형태:
/// `@react-native/codegen` 의 `GenerateViewConfigJs.generate()` 의 fileTemplate 와 동일.
/// `native_name` 은 caller 가 `shape.nativeName()` 으로 결정 (paper 우선) — 본 함수는
/// 순수 문자열 어셈블리만 담당. `has_commands` true 면 `dispatchCommand` import 도
/// prepend (commands export 가 emit 결과 안에 이미 포함됨).
fn assembleFileReplacement(
    native_name: []const u8,
    view_config_js: []const u8,
    has_commands: bool,
    alloc: std.mem.Allocator,
) ![]u8 {
    const dispatch_import = if (has_commands)
        "const {dispatchCommand} = require(\"react-native/Libraries/ReactNative/RendererProxy\");\n"
    else
        "";
    return std.fmt.allocPrint(
        alloc,
        "const NativeComponentRegistry = require('react-native/Libraries/NativeComponent/NativeComponentRegistry');\n" ++
            "{s}" ++
            "let nativeComponentName = '{s}';\n" ++
            "{s}\n" ++
            "export default NativeComponentRegistry.get(nativeComponentName, () => __INTERNAL_VIEW_CONFIG);\n",
        .{ dispatch_import, native_name, view_config_js },
    );
}
