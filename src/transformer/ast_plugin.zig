//! AST Plugin 타입 + 유틸리티
//!
//! Plugin(plugin.zig)의 AST 훅(onFunction 등)이 사용하는 타입과 컨텍스트.
//! FunctionInfo, AstTransformCtx를 정의하고, 플러그인이 AST를 안전하게 조작하는 API를 제공.
//!
//! 사용 예:
//!   const plugins = [_]Plugin{ worklet_plugin.plugin() };
//!   var t = Transformer.init(alloc, ast, .{ .plugins = &plugins });

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
pub const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

// forward declaration — transformer.zig에서 실제 타입을 import
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

// worklet 유틸리티 (기존 코드 재사용)
pub const worklet_mod = @import("transformer/worklet.zig");

// ================================================================
// FunctionInfo — 읽기 전용 함수 정보
// ================================================================

/// onFunction 훅에 전달되는 함수 노드 정보.
/// 읽기 전용 — 수정은 AstTransformCtx API를 통해 수행.
pub const FunctionInfo = struct {
    /// 변환된 함수 노드의 인덱스
    node_idx: NodeIndex,
    /// 노드 태그 (function_declaration / function_expression / arrow_function_expression)
    node_tag: Tag,
    /// 함수 이름 (null = 익명 함수/화살표)
    name: ?[]const u8,
    /// 함수 body 노드 인덱스 (변환 후)
    body_idx: NodeIndex,
    /// 파라미터 extra_data 시작 위치 (변환 후)
    params_start: u32,
    /// 파라미터 수 (변환 후)
    params_len: u32,
    /// 원본 (변환 전) — Babel과 동일하게 변환 전 AST로 closure 분석
    original_params_start: u32,
    original_params_len: u32,
    original_body_idx: NodeIndex,
    /// 함수 플래그 (bit 0=async, bit 1=generator)
    flags: u32,
    /// 소스 파일 경로 (__initData.location 등에 사용)
    source_path: []const u8,
    /// auto-workletization으로 활성화된 경우 true.
    /// 'worklet' 디렉티브 없이도 worklet 변환이 필요한 함수.
    is_auto_worklet: bool = false,
};

// ================================================================
// AstTransformCtx — 플러그인 API
// ================================================================

/// AST 변환 컨텍스트.
/// 플러그인이 AST를 안전하게 읽고/쓰는 API를 제공한다.
/// 내부적으로 Transformer를 위임 호출하므로 별도 상태를 가지지 않는다.
pub const AstTransformCtx = struct {
    transformer: *Transformer,

    /// 플러그인이 body를 수정한 경우 새 body 인덱스.
    /// dispatcher가 이 값을 확인하여 result 노드의 extra_data를 패치한다.
    modified_body: ?NodeIndex = null,

    /// 플러그인이 함수 노드 전체를 교체한 경우 새 노드 인덱스.
    /// function_expression worklet → IIFE factory 변환 등에 사용.
    replaced_node: ?NodeIndex = null,

    // --- 디렉티브 ---

    /// 함수 body의 첫 문장이 지정된 디렉티브인지 확인.
    /// 예: hasDirective(body, "worklet") → true/false
    pub fn hasDirective(self: *AstTransformCtx, body_idx: NodeIndex, directive: []const u8) bool {
        return worklet_mod.isWorkletDirectiveGeneric(self.transformer, body_idx, directive);
    }

    /// 함수 body에서 첫 디렉티브 문장을 제거한 새 body를 반환.
    /// 동시에 modified_body를 설정하여 dispatcher가 result 노드를 패치할 수 있게 한다.
    pub fn stripDirective(self: *AstTransformCtx, body_idx: NodeIndex) Error!NodeIndex {
        const new_body = try worklet_mod.stripWorkletDirective(self.transformer, body_idx);
        self.modified_body = new_body;
        return new_body;
    }

    // --- 스코프 분석 ---

    /// 함수 body에서 closure 변수(외부 참조)를 추출.
    /// func_name: 함수 이름 (자기 참조 제외용). null이면 무시.
    /// 반환된 슬라이스는 caller가 getAllocator().free()로 해제해야 한다.
    pub fn getClosureVars(
        self: *AstTransformCtx,
        body_idx: NodeIndex,
        params_start: u32,
        params_len: u32,
        func_name: ?[]const u8,
    ) Error![]const worklet_mod.ClosureVar {
        return worklet_mod.collectClosureVars(self.transformer, body_idx, params_start, params_len, func_name);
    }

    // --- AST 노드 생성 (Transformer/Ast 위임) ---

    pub fn addNode(self: *AstTransformCtx, node: Node) Error!NodeIndex {
        return self.transformer.ast.addNode(node);
    }

    pub fn addString(self: *AstTransformCtx, text: []const u8) Error!Span {
        return self.transformer.ast.addString(text);
    }

    pub fn addExtraNode(self: *AstTransformCtx, tag: Tag, span: Span, extras: []const u32) Error!NodeIndex {
        return self.transformer.addExtraNode(tag, span, extras);
    }

    pub fn addNodeList(self: *AstTransformCtx, items: []const NodeIndex) Error!NodeList {
        return self.transformer.ast.addNodeList(items);
    }

    // --- 코드 삽입 ---

    /// 현재 노드 뒤에 문장을 삽입한다.
    /// visitExtraList의 trailing_nodes 메커니즘을 통해 부모 리스트에 추가.
    pub fn addTrailingStatement(self: *AstTransformCtx, stmt: NodeIndex) Error!void {
        try self.transformer.trailing_nodes.append(self.transformer.allocator, stmt);
    }

    /// body 앞에 문장들을 삽입한 새 body를 반환.
    pub fn prependToBody(self: *AstTransformCtx, body: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
        return self.transformer.prependStatementsToBody(body, stmts);
    }

    // --- AST 읽기 ---

    pub fn getNode(self: *AstTransformCtx, idx: NodeIndex) Node {
        return self.transformer.ast.getNode(idx);
    }

    pub fn getText(self: *AstTransformCtx, span: Span) []const u8 {
        return self.transformer.ast.getText(span);
    }

    pub fn getSource(self: *AstTransformCtx) []const u8 {
        return self.transformer.ast.source;
    }

    pub fn getAllocator(self: *AstTransformCtx) std.mem.Allocator {
        return self.transformer.allocator;
    }

    // --- 코드 파싱 (JS AST 플러그인용) ---

    /// 코드 문자열을 파싱하여 statement NodeIndex 배열을 반환한다.
    /// JS AST 플러그인의 trailingCode 문자열을 AST 노드로 변환하는 데 사용.
    /// 반환된 슬라이스는 caller가 getAllocator().free()로 해제해야 한다.
    pub fn parseAndInjectStatements(self: *AstTransformCtx, code: []const u8) Error![]const NodeIndex {
        const Scanner = @import("../lexer/scanner.zig").Scanner;
        const Parser = @import("../parser/parser.zig").Parser;
        const alloc = self.transformer.allocator;

        const scanner_ptr = alloc.create(Scanner) catch return error.OutOfMemory;
        scanner_ptr.* = Scanner.init(alloc, code) catch return error.OutOfMemory;
        defer {
            scanner_ptr.deinit();
            alloc.destroy(scanner_ptr);
        }

        const parser_ptr = alloc.create(Parser) catch return error.OutOfMemory;
        parser_ptr.* = Parser.init(alloc, scanner_ptr);
        defer {
            parser_ptr.deinit();
            alloc.destroy(parser_ptr);
        }

        _ = parser_ptr.parse() catch return error.OutOfMemory;

        const root_idx = parser_ptr.ast.nodes.items.len - 1;
        const root = parser_ptr.ast.nodes.items[root_idx];
        if (root.tag != .program) return &.{};

        const list = root.data.list;
        if (list.len == 0) return &.{};

        // 파싱된 노드를 transformer의 AST에 복사
        var result = alloc.alloc(NodeIndex, list.len) catch return error.OutOfMemory;
        var count: usize = 0;
        var si: u32 = 0;
        while (si < list.len) : (si += 1) {
            const stmt_raw = parser_ptr.ast.extra_data.items[list.start + si];
            const stmt_idx: NodeIndex = @enumFromInt(stmt_raw);
            if (stmt_idx.isNone()) continue;

            // 파싱된 AST의 노드를 transformer AST에 복사
            const copied = self.copyNodeFromParsedAst(&parser_ptr.ast, stmt_idx) catch continue;
            result[count] = copied;
            count += 1;
        }

        if (count == 0) {
            alloc.free(result);
            return &.{};
        }
        return result[0..count];
    }

    /// 파싱된 AST에서 노드를 재귀적으로 transformer AST에 복사한다.
    fn copyNodeFromParsedAst(self: *AstTransformCtx, src_ast: *const Ast, src_idx: NodeIndex) Error!NodeIndex {
        if (src_idx.isNone()) return .none;
        const src_node = src_ast.nodes.items[@intFromEnum(src_idx)];

        // 소스 텍스트 참조 → string_table로 복사 (span이 src_ast.source를 참조하므로)
        var new_span = src_node.span;
        if (src_node.span.start & 0x8000_0000 == 0 and
            src_node.span.start < src_node.span.end and
            src_node.span.end <= @as(u32, @intCast(src_ast.source.len)))
        {
            const text = src_ast.source[src_node.span.start..src_node.span.end];
            new_span = self.transformer.ast.addString(text) catch return error.OutOfMemory;
        }

        // data 복사는 태그에 따라 다름 — 간단한 노드만 지원
        return switch (src_node.tag) {
            // 리프 노드: data를 그대로 복사하되 span 갱신
            .identifier_reference,
            .string_literal,
            .numeric_literal,
            .boolean_literal,
            .null_literal,
            .this_expression,
            => self.transformer.ast.addNode(.{
                .tag = src_node.tag,
                .span = new_span,
                .data = .{ .string_ref = new_span },
            }),

            // 단항: operand 재귀 복사
            .expression_statement,
            .return_statement,
            .throw_statement,
            => blk: {
                const new_operand = try self.copyNodeFromParsedAst(src_ast, src_node.data.unary.operand);
                break :blk self.transformer.ast.addNode(.{
                    .tag = src_node.tag,
                    .span = new_span,
                    .data = .{ .unary = .{ .operand = new_operand, .flags = src_node.data.unary.flags } },
                });
            },

            // 이항: left/right 재귀 복사
            .assignment_expression,
            .binary_expression,
            .object_property,
            => blk: {
                const new_left = try self.copyNodeFromParsedAst(src_ast, src_node.data.binary.left);
                const new_right = try self.copyNodeFromParsedAst(src_ast, src_node.data.binary.right);
                break :blk self.transformer.ast.addNode(.{
                    .tag = src_node.tag,
                    .span = new_span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = src_node.data.binary.flags } },
                });
            },

            // 리스트: 각 요소 재귀 복사
            .object_expression,
            .array_expression,
            .sequence_expression,
            => blk: {
                const src_list = src_node.data.list;
                const scratch_top = self.transformer.scratch.items.len;
                defer self.transformer.scratch.shrinkRetainingCapacity(scratch_top);
                var i: u32 = 0;
                while (i < src_list.len) : (i += 1) {
                    const elem_raw = src_ast.extra_data.items[src_list.start + i];
                    const copied = try self.copyNodeFromParsedAst(src_ast, @enumFromInt(elem_raw));
                    try self.transformer.scratch.append(self.transformer.allocator, copied);
                }
                const new_list = try self.transformer.ast.addNodeList(
                    self.transformer.scratch.items[scratch_top..],
                );
                break :blk self.transformer.ast.addNode(.{
                    .tag = src_node.tag,
                    .span = new_span,
                    .data = .{ .list = new_list },
                });
            },

            // extra 노드 (static_member_expression, call_expression 등):
            // extra_data를 복사하되, 자식 노드 인덱스는 재귀 복사
            .static_member_expression => blk: {
                const e = src_node.data.extra;
                const obj = try self.copyNodeFromParsedAst(src_ast, @enumFromInt(src_ast.extra_data.items[e]));
                const prop = try self.copyNodeFromParsedAst(src_ast, @enumFromInt(src_ast.extra_data.items[e + 1]));
                const flags = src_ast.extra_data.items[e + 2];
                break :blk self.addExtraNode(.static_member_expression, new_span, &.{
                    @intFromEnum(obj), @intFromEnum(prop), flags,
                });
            },

            // 지원하지 않는 노드: data에 AST 인덱스가 포함될 수 있으므로
            // raw 복사는 dangling index 위험. 안전하게 스킵.
            else => .none,
        };
    }

    // --- 코드 생성 ---

    /// 함수 body를 self-contained 코드 문자열로 직렬화.
    /// closure 변수가 있으면 `const {v1, v2} = this.__closure;`를 body 앞에 삽입.
    /// 반환된 슬라이스는 caller가 getAllocator().free()로 해제해야 한다.
    pub fn generateCode(
        self: *AstTransformCtx,
        func_name: []const u8,
        body_idx: NodeIndex,
        closure_vars: []const worklet_mod.ClosureVar,
        params_start: u32,
        params_len: u32,
        flags: u32,
    ) Error![]const u8 {
        return worklet_mod.generateInitCode(
            self.transformer,
            func_name,
            body_idx,
            closure_vars,
            params_start,
            params_len,
            flags,
        );
    }
};
