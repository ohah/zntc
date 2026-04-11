//! AST Plugin System — Zig 네이티브 + JS/NAPI 공통 인터페이스
//!
//! SWC의 Rust VisitMut trait처럼 AST 노드 레벨에서 변환을 수행하는 플러그인 시스템.
//! 기존 string-based Plugin(resolveId/load/transform)과 별개로,
//! transformer 내부에서 AST 노드 방문 시 호출된다.
//!
//! 사용 예 (Zig 플러그인):
//!   const worklet = @import("plugins/worklet_plugin.zig");
//!   const plugins = [_]AstPlugin{ worklet.plugin() };
//!   var t = Transformer.init(alloc, ast, .{ .ast_plugins = &plugins });
//!
//! 향후 JS/NAPI 플러그인:
//!   build.onAstFunction({ filter: /\.tsx?$/ }, (info) => { ... });

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

// forward declaration — transformer.zig에서 실제 타입을 import
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

// worklet 유틸리티 (기존 코드 재사용)
const worklet_mod = @import("transformer/worklet.zig");

// ================================================================
// AstPlugin — 플러그인 등록 단위
// ================================================================

/// AST 변환 플러그인.
/// 각 훅은 optional 함수 포인터 — null이면 해당 훅을 구현하지 않음.
/// context 필드로 플러그인 상태를 전달 (stateless 플러그인은 null).
pub const AstPlugin = struct {
    /// 플러그인 이름 (디버깅/로깅용)
    name: []const u8,
    /// 플러그인 상태를 전달하는 opaque 포인터.
    context: ?*anyopaque = null,

    /// 함수 노드 방문 훅. visitFunction 완료 후 호출.
    /// function_declaration, function_expression, arrow_function_expression 모두 대상.
    onFunction: ?*const fn (
        ctx: ?*anyopaque,
        api: *AstTransformCtx,
        func: FunctionInfo,
    ) Error!void = null,

    // 향후 확장:
    // onClass: ?*const fn(ctx: ?*anyopaque, api: *AstTransformCtx, class: ClassInfo) Error!void = null,
    // onNode: ?*const fn(ctx: ?*anyopaque, api: *AstTransformCtx, node: NodeInfo) Error!void = null,
};

// ================================================================
// FunctionInfo — 읽기 전용 함수 정보
// ================================================================

/// onFunction 훅에 전달되는 함수 노드 정보.
/// 읽기 전용 — 수정은 AstTransformCtx API를 통해 수행.
pub const FunctionInfo = struct {
    /// 변환된 함수 노드의 인덱스
    node_idx: NodeIndex,
    /// 함수 이름 (null = 익명 함수/화살표)
    name: ?[]const u8,
    /// 함수 body 노드 인덱스 (block_statement/function_body)
    body_idx: NodeIndex,
    /// 파라미터 extra_data 시작 위치
    params_start: u32,
    /// 파라미터 수
    params_len: u32,
    /// 함수 플래그 (bit 0=async, bit 1=generator)
    flags: u32,
    /// 소스 파일 경로 (__initData.location 등에 사용)
    source_path: []const u8,
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
    /// 반환된 슬라이스는 caller가 getAllocator().free()로 해제해야 한다.
    pub fn getClosureVars(
        self: *AstTransformCtx,
        body_idx: NodeIndex,
        params_start: u32,
        params_len: u32,
    ) Error![]const []const u8 {
        return worklet_mod.collectClosureVars(self.transformer, body_idx, params_start, params_len);
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

    // --- 코드 생성 ---

    /// 함수 body를 self-contained 코드 문자열로 직렬화.
    /// closure 변수가 있으면 `const {v1, v2} = this.__closure;`를 body 앞에 삽입.
    /// 반환된 슬라이스는 caller가 getAllocator().free()로 해제해야 한다.
    pub fn generateCode(
        self: *AstTransformCtx,
        func_name: []const u8,
        body_idx: NodeIndex,
        closure_vars: []const []const u8,
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
