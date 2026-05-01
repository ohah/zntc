//! ZTS Native Codegen Plugin — `@react-native/codegen` 의 view config inline 등가.
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
//!   3. ZTS Parser 로 파싱 → type_index 빌드
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
const NodeIndex = ast_mod.NodeIndex;
const stripQuotes = @import("../../bundler/import_scanner.zig").stripQuotes;

const codegen = @import("codegen/mod.zig");
const type_index_mod = codegen.type_index;
const schema_builder = codegen.schema_builder;
const view_config_emitter = codegen.view_config_emitter;

const CODEGEN_MARKER = "codegenNativeComponent";

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
    if (std.mem.indexOf(u8, code, CODEGEN_MARKER) == null) return null;

    const props_type_name = extractTypeArg(code) orelse return null;

    var scanner = Scanner.init(alloc, code) catch return null;
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    parser.configureFromExtension(std.fs.path.extension(id));
    if (std.mem.endsWith(u8, id, ".js")) parser.is_flow = true;

    const program = parser.parse() catch return null;
    if (parser.errors.items.len > 0) return null;

    var type_index = type_index_mod.build(&parser.ast, program, alloc) catch return null;
    defer type_index.deinit(alloc);

    const decl_idx = type_index.get(props_type_name) orelse return null;
    const component_name = findComponentName(&parser.ast, program) orelse return null;

    const shape = schema_builder.build(&parser.ast, &type_index, component_name, decl_idx, alloc) catch return null;
    defer alloc.free(shape.props);
    defer alloc.free(shape.events);

    const view_config = view_config_emitter.emit(shape, alloc) catch return null;
    defer alloc.free(view_config);

    return assembleFileReplacement(component_name, view_config, alloc) catch return null;
}

/// `codegenNativeComponent<TYPE_NAME>` 에서 `TYPE_NAME` 추출.
/// 정상적인 spec 파일은 이 형태이므로 단순 텍스트 스캔으로 충분.
/// AST 레벨에선 type argument 가 expression context 에서 speculative parse 후 폐기됨.
fn extractTypeArg(code: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, code, search_from, CODEGEN_MARKER)) |marker| {
        const after = marker + CODEGEN_MARKER.len;
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

/// program 자식 중 `export default codegenNativeComponent('Name', ...)` 패턴을 찾아
/// 첫 string 인자 (component name) 추출. quote 는 벗긴다.
fn findComponentName(ast: *const ast_mod.Ast, program_idx: NodeIndex) ?[]const u8 {
    const program = ast.getNode(program_idx);
    if (program.tag != .program) return null;

    const list = program.data.list;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const stmt: NodeIndex = @enumFromInt(ast.extra_data.items[list.start + i]);
        const node = ast.getNode(stmt);
        const call_idx = unwrapToCallExpression(ast, stmt, node) orelse continue;
        if (extractCallArg0String(ast, call_idx)) |name| return name;
    }
    return null;
}

/// `export default codegenNativeComponent(...)` 형태에서 call_expression 추출.
fn unwrapToCallExpression(ast: *const ast_mod.Ast, _: NodeIndex, node: ast_mod.Node) ?NodeIndex {
    if (node.tag != .export_default_declaration) return null;
    const inner_idx = node.data.unary.operand;
    if (inner_idx == .none) return null;
    const inner = ast.getNode(inner_idx);

    return switch (inner.tag) {
        .call_expression => if (callIsCodegenMarker(ast, inner)) inner_idx else null,
        else => null,
    };
}

fn callIsCodegenMarker(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    const e = node.data.extra;
    if (e >= ast.extra_data.items.len) return false;
    const callee_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
    const callee = ast.getNode(callee_idx);
    if (callee.tag != .identifier_reference) return false;
    const name = ast.getText(callee.span);
    return std.mem.eql(u8, name, CODEGEN_MARKER);
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

/// 최종 파일 교체 문자열 조립. RN 런타임이 기대하는 정확한 형태:
/// `@react-native/codegen` 의 `GenerateViewConfigJs.generate()` 의 fileTemplate 와 동일.
fn assembleFileReplacement(
    component_name: []const u8,
    view_config_js: []const u8,
    alloc: std.mem.Allocator,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "const NativeComponentRegistry = require('react-native/Libraries/NativeComponent/NativeComponentRegistry');\n" ++
            "let nativeComponentName = '{s}';\n" ++
            "{s}\n" ++
            "export default NativeComponentRegistry.get(nativeComponentName, () => __INTERNAL_VIEW_CONFIG);\n",
        .{ component_name, view_config_js },
    );
}
