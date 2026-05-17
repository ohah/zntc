//! ZNTC Codegen — AST를 JS 문자열로 출력
//!
//! 작동 원리:
//!   1. AST의 루트(program) 노드부터 시작
//!   2. 각 노드의 tag를 switch로 분기
//!   3. 소스 코드의 span을 참조하여 식별자/리터럴을 zero-copy 출력
//!   4. 구문 구조(키워드, 괄호, 세미콜론)는 직접 생성
//!
//! 참고:
//! - references/esbuild/internal/js_printer/js_printer.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const Comment = @import("../lexer/scanner.zig").Comment;
const rt = @import("../bundler/runtime_helpers.zig");
const options_mod = @import("options.zig");
const writer_emit = @import("writer.zig");
const debug_metadata = @import("debug_metadata.zig");

pub const ModuleFormat = options_mod.ModuleFormat;
pub const Platform = options_mod.Platform;
pub const IndentChar = options_mod.IndentChar;
pub const LinkingMetadata = options_mod.LinkingMetadata;
pub const QuoteStyle = options_mod.QuoteStyle;
pub const JsxRuntime = options_mod.JsxRuntime;
pub const CodegenOptions = options_mod.CodegenOptions;
pub const KeepNameEntry = options_mod.KeepNameEntry;

const SourceMapBuilder = @import("sourcemap.zig").SourceMapBuilder;
const FunctionMapBuilder = @import("function_map.zig").FunctionMapBuilder;

pub const Codegen = struct {
    ast: *const Ast,
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    options: CodegenOptions,
    /// 현재 들여쓰기 레벨
    indent_level: u32 = 0,
    /// 소스맵 빌더 (sourcemap 옵션 활성화 시)
    sm_builder: ?SourceMapBuilder = null,
    /// 소스의 줄 오프셋 테이블 (Scanner에서 전달, 소스맵 줄/열 계산용)
    line_offsets: []const u32 = &.{},
    /// 출력의 현재 줄/열 (소스맵 매핑용)
    gen_line: u32 = 0,
    gen_col: u32 = 0,
    /// 소스에서 수집한 주석 리스트 (소스 순서, scanner.comments.items)
    comments: []const Comment = &.{},
    /// 다음으로 출력할 주석의 인덱스
    next_comment_idx: usize = 0,
    /// for문 init 위치에서 variable_declaration 출력 시 세미콜론 생략
    in_for_init: bool = false,
    /// for-in var initializer hoisting: emitVariableDeclarator에서 init 스킵
    skip_var_init: bool = false,
    /// namespace IIFE 내부에서 export된 변수의 참조를 ns.name으로 치환하기 위한 상태.
    /// emitNamespaceIIFE에서 설정되고, emitNode의 identifier 출력에서 참조.
    ns_prefix: ?[]const u8 = null,
    ns_exports: ?std.StringHashMapUnmanaged(void) = null,
    /// top-level에서 선언된 이름 추적 (namespace var 중복 제거용).
    /// function/class/var/let/const/enum 선언 시 등록, namespace 출력 시 이미 있으면 var 생략.
    declared_names: std.StringHashMapUnmanaged(void) = .{},
    /// keepNames: rename된 함수/클래스 선언 정보. generate() 완료 후 emitter에서 __name() 호출 생성에 사용.
    keep_names_entries: std.ArrayList(KeepNameEntry) = .empty,
    // JSX 필드 제거: Transformer의 jsx_lowering이 JSX → call_expression 변환을 담당.
    // codegen은 더 이상 JSX AST 노드를 처리하지 않음.

    /// Metro function map 빌더 (sourcemap_function_map 활성화 시).
    fn_map_builder: ?FunctionMapBuilder = null,
    /// function map 이름 스택. entries 는 `fn_map_builder.names` 의 owned slice 를
    /// borrow — builder 가 모든 unique name 의 단일 ownership.
    fn_name_stack: std.ArrayList([]const u8) = .empty,
    /// 다음 function/arrow/class에 적용할 contextual name. owned UTF-8 — set 시 dupe,
    /// 소비/save-restore/codegen.deinit 시 free.
    pending_fn_name: ?[]u8 = null,
    /// hot-path fast-exit 플래그. tryEmitGlobObject/tryEmitRequireContextObject 가
    /// 모든 call expression 에 대해 호출되므로, 해당 종류의 record 가 없으면 O(1) 로 빠짐.
    has_glob_records: bool = false,
    has_require_context_records: bool = false,
    /// Legacy `cjs_wrap_substitute` path 에서 module body 의 unresolved `module`
    /// reference 를 substitute 한 적이 있는지 추적.
    cjs_wrap_module_used: bool = false,
    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) Codegen {
        return initWithOptions(allocator, ast, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, ast: *const Ast, options: CodegenOptions) Codegen {
        var sm = if (options.sourcemap) SourceMapBuilder.init(allocator) else null;
        if (sm) |*builder| {
            builder.source_root = options.source_root;
            builder.sources_content = options.sources_content;
        }
        const fm = if (options.sourcemap_function_map) FunctionMapBuilder.init(allocator) else null;

        var has_glob = false;
        var has_ctx = false;
        for (options.import_records) |rec| {
            switch (rec.kind) {
                .glob => has_glob = true,
                .require_context => has_ctx = true,
                else => {},
            }
            if (has_glob and has_ctx) break;
        }

        return .{
            .ast = ast,
            .allocator = allocator,
            .buf = .empty,
            .options = options,
            .indent_level = 0,
            .sm_builder = sm,
            .fn_map_builder = fm,
            .gen_line = 0,
            .gen_col = 0,
            .has_glob_records = has_glob,
            .has_require_context_records = has_ctx,
            // JSX 필드 제거: Transformer가 JSX lowering 담당
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.buf.deinit(self.allocator);
        self.declared_names.deinit(self.allocator);
        self.keep_names_entries.deinit(self.allocator);
        if (self.sm_builder) |*sm| sm.deinit();
        if (self.fn_map_builder) |*fm| fm.deinit();
        // fn_name_stack 의 entries 는 fn_map_builder.names 의 owned slice 를 borrow —
        // builder.deinit() 가 이미 해제하므로 stack 자체만 deinit.
        self.fn_name_stack.deinit(self.allocator);
        if (self.pending_fn_name) |s| self.allocator.free(s);
    }

    /// 특정 statement 노드 목록만 코드로 생성한다 (__esm var 호이스팅용).
    /// root는 collectTopLevelDeclNames에만 사용. 실제 출력은 stmt_indices에서.
    pub fn generateStatements(self: *Codegen, root: NodeIndex, stmt_indices: []const u32) ![]const u8 {
        if (self.options.assert_no_raw_private_syntax) {
            for (stmt_indices) |raw_idx| {
                std.debug.assert(!hasRawPrivateSyntax(self.ast, @enumFromInt(raw_idx)));
            }
        }
        try self.buf.ensureTotalCapacity(self.allocator, self.ast.source.len / 2);
        self.collectTopLevelDeclNames(root);
        var emitted = false;
        for (stmt_indices) |raw_idx| {
            const node_idx: NodeIndex = @enumFromInt(raw_idx);
            if (node_idx.isNone()) continue;
            if (emitted) try self.writeNewline();
            try self.emitNode(node_idx);
            emitted = true;
        }
        if (emitted) try self.writeNewline();
        return self.buf.items;
    }

    /// AST를 JS 문자열로 출력한다.
    pub fn generate(self: *Codegen, root: NodeIndex) ![]const u8 {
        var scope = @import("../profile.zig").begin(.codegen);
        defer scope.end();

        if (self.options.assert_no_raw_private_syntax) {
            std.debug.assert(!hasRawPrivateSyntax(self.ast, root));
        }

        // 출력 크기는 보통 소스 크기와 비슷 → 사전 할당
        try self.buf.ensureTotalCapacity(self.allocator, self.ast.source.len);

        // namespace var 중복 제거: top-level 선언 이름 사전 수집
        self.collectTopLevelDeclNames(root);
        // function map: program 진입 시 <global> frame
        if (self.fn_map_builder != null) try self.fnMapEnter("<global>");
        try self.emitNode(root);
        if (self.fn_map_builder != null) try self.fnMapExit();

        // keepNames: 수집된 entries를 코드 끝에 __name() 호출로 append (복사 없음)
        // #1621: minify 시 __name → $nm 축약.
        const keep_name: []const u8 = if (self.options.minify_whitespace) rt.NAMES.NAME_MIN else "__name";
        for (self.keep_names_entries.items) |entry| {
            try self.write(keep_name);
            try self.write("(");
            try self.write(entry.new_name);
            try self.write(", \"");
            try self.write(entry.original_name);
            if (self.options.minify_whitespace) {
                try self.write("\");");
            } else {
                try self.write("\");\n");
            }
        }

        // JSX import 주입 제거: Transformer의 jsx_import_info로 transpile.zig에서 처리.

        return self.buf.items;
    }

    // buildJsxImport 제거: Transformer의 jsx_import_info가 대체.
    // 트랜스파일: transpile.zig에서 처리, 번들: graph.zig synthetic import로 처리.

    /// top-level function/class/var/let/const 이름을 declared_names에 수집.
    /// namespace/enum IIFE 출력 시 같은 이름이면 var 선언을 생략하기 위함.
    fn collectTopLevelDeclNames(self: *Codegen, root: NodeIndex) void {
        if (root.isNone()) return;
        const root_node = self.ast.getNode(root);
        if (root_node.tag != .program) return;
        const list = root_node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            const stmt = self.ast.getNode(@enumFromInt(raw_idx));
            switch (stmt.tag) {
                .function_declaration => {
                    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[stmt.data.extra]);
                    if (!name_idx.isNone()) {
                        const n = self.ast.getText(self.ast.getNode(name_idx).span);
                        self.declared_names.put(self.allocator, n, {}) catch {};
                    }
                },
                .class_declaration => {
                    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[stmt.data.extra]);
                    if (!name_idx.isNone()) {
                        const n = self.ast.getText(self.ast.getNode(name_idx).span);
                        self.declared_names.put(self.allocator, n, {}) catch {};
                    }
                },
                .variable_declaration => {
                    const e = stmt.data.extra;
                    const vlist_start = self.ast.extra_data.items[e + 1];
                    const vlist_len = self.ast.extra_data.items[e + 2];
                    const decls = self.ast.extra_data.items[vlist_start .. vlist_start + vlist_len];
                    for (decls) |d_idx| {
                        const decl = self.ast.getNode(@enumFromInt(d_idx));
                        const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decl.data.extra]);
                        if (!name_idx.isNone()) {
                            const n = self.ast.getText(self.ast.getNode(name_idx).span);
                            self.declared_names.put(self.allocator, n, {}) catch {};
                        }
                    }
                },
                else => {},
            }
        }
    }

    pub const addSourceFile = debug_metadata.addSourceFile;
    pub const generateSourceMap = debug_metadata.generateSourceMap;
    pub const generateSourceMapWithFunctionMap = debug_metadata.generateSourceMapWithFunctionMap;
    pub const addSourceMapping = debug_metadata.addSourceMapping;
    pub const addSourceMappingWithName = debug_metadata.addSourceMappingWithName;
    const fnMapEnter = debug_metadata.fnMapEnter;
    const fnMapExit = debug_metadata.fnMapExit;
    pub const isFunctionLike = debug_metadata.isFunctionLike;
    pub const resolveMemberLeafName = debug_metadata.resolveMemberLeafName;

    // ================================================================
    // 출력 헬퍼
    // ================================================================

    /// 리스트 구분자: minify_whitespace=true면 "," 아니면 ", ".
    /// formal_parameters, arguments, array literal 등에서 공용.
    pub inline fn listSep(self: *const Codegen) []const u8 {
        return if (self.options.minify_whitespace) "," else ", ";
    }

    pub const write = writer_emit.write;
    pub const writeByte = writer_emit.writeByte;
    pub const trimTrailingSemicolonBeforeMinifyBoundary = writer_emit.trimTrailingSemicolonBeforeMinifyBoundary;
    pub const writeNewline = writer_emit.writeNewline;
    pub const writeIndent = writer_emit.writeIndent;
    pub const writeSpace = writer_emit.writeSpace;
    pub const writeConstValue = writer_emit.writeConstValue;
    pub const writeSpan = writer_emit.writeSpan;
    pub const writeAsciiOnly = writer_emit.writeAsciiOnly;
    pub const writeNodeSpan = writer_emit.writeNodeSpan;
    pub const writeStringLiteral = writer_emit.writeStringLiteral;

    // ================================================================
    // Statement/comment emission — codegen/statements.zig로 위임
    // ================================================================
    const statement_emit = @import("statements.zig");
    const isSkipped = statement_emit.isSkipped;
    pub const evalBooleanCondition = statement_emit.evalBooleanCondition;

    // ================================================================
    // 노드 출력
    // ================================================================

    pub const Error = std.mem.Allocator.Error;
    const node_dispatch_emit = @import("node_dispatch.zig");
    pub const emitNode = node_dispatch_emit.emitNode;

    /// identifier 노드의 symbol_id를 해결.
    /// symbol_ids[node_i]에서 직접 조회 (트랜스포머의 propagateSymbolId로 전파된 값).
    pub fn resolveSymbolId(_: *Codegen, idx: NodeIndex, meta: *const LinkingMetadata) ?u32 {
        const node_i = @intFromEnum(idx);
        if (node_i < meta.symbol_ids.len) {
            return meta.symbol_ids[node_i];
        }
        return null;
    }

    /// export default X에서 X의 (rename된) 이름이 def_name과 같은지 확인.
    /// 같으면 할당문(def_name = X)이 불필요한 self-reference.
    pub fn isExportDefaultSelfRef(self: *Codegen, inner: NodeIndex, def_name: []const u8) bool {
        const inner_node = self.ast.getNode(inner);
        if (inner_node.tag != .identifier_reference) return false;
        if (self.options.linking_metadata) |md| {
            if (self.resolveSymbolId(inner, md)) |sid| {
                // namespace import(`import * as X`)는 rename 이름(`X$N`)에 값이 할당되지 않고
                // 별도 ns var(`X_ns`)에 object literal이 저장된다. 따라서 self-ref 아님 —
                // `export default X`는 반드시 `X$N = X_ns` 할당이 필요.
                if (md.ns_inline_objects.get(sid) != null) return false;
                if (md.renames.get(sid)) |renamed| {
                    return std.mem.eql(u8, renamed, def_name);
                }
            }
        }
        const ref_text = self.ast.getText(inner_node.span);
        return std.mem.eql(u8, ref_text, def_name);
    }

    // ================================================================
    // Call/new/import.meta/require emission — codegen/calls.zig로 위임
    // ================================================================
    const call_emit = @import("calls.zig");
    pub const resolveImportMetaProp = call_emit.resolveImportMetaProp;
    pub const writeImportMetaUrl = call_emit.writeImportMetaUrl;
    pub const resolveRequireRewriteSpecifier = call_emit.resolveRequireRewriteSpecifier;
    pub const emitRewriteValue = call_emit.emitRewriteValue;
    pub const emitRequireRewriteOrCall = call_emit.emitRequireRewriteOrCall;

    // JSX 출력 함수 제거: Transformer의 jsx_lowering이 JSX → call_expression 변환을 담당.
    // emitJSXElement, emitJSXFragment, emitJSXTagName, emitJSXAttrsClassic,
    // emitJSXPropsAutomatic, emitJSXChildrenClassic, emitJSXChildrenAutomatic,
    // emitJSXSingleChild, emitJSXDevSource, emitJSXAttribute, emitJSXText,
    // emitJSXFactoryWithRename, resolveJSXRename, buildJsxImport,
    // writeJSXTextEscaped, namedEntityToCodepoint, trimJSXText,
    // countEffectiveChildren, findJSXKeyAttr, jsx_entity_map, writeCodepointEscaped
    // — 모두 제거됨.

    // (아래는 원래 코드 ~800줄이 있었으나, Phase 2에서 Transformer가
    //  번들 모드에서도 JSX lowering을 처리하게 되면서 codegen의 JSX 코드 전체 삭제.)
    // 삭제된 함수 목록: emitJSXElement, emitJSXFragment 등 20개 함수 + jsx_entity_map.

    // NOTE: emitNode에서 .jsx_element, .jsx_fragment 등은 unreachable로 설정됨.

    // ================================================================
    // 리스트 헬퍼
    // ================================================================

    pub fn emitList(self: *Codegen, node: Node, sep: []const u8) !void {
        const list = node.data.list;
        try self.emitNodeList(list.start, list.len, sep);
    }

    pub fn emitNodeList(self: *Codegen, start: u32, len: u32, sep: []const u8) !void {
        try emitNodeListImpl(self, start, len, sep, false);
    }

    pub fn emitExpressionList(self: *Codegen, node: Node, sep: []const u8) !void {
        const list = node.data.list;
        try emitNodeListImpl(self, list.start, list.len, sep, true);
    }

    pub fn emitExpressionNodeList(self: *Codegen, start: u32, len: u32, sep: []const u8) !void {
        try emitNodeListImpl(self, start, len, sep, true);
    }

    // `wrap_sequences` 가 true 이면 a, b 형태의 sequence_expression 항목을 괄호로 감싼다.
    // call/new arg list, array literal 처럼 콤마가 항목 구분자인 컨텍스트에서만 필요.
    fn emitNodeListImpl(self: *Codegen, start: u32, len: u32, sep: []const u8, comptime wrap_sequences: bool) !void {
        if (len == 0) return;
        const indices = self.ast.extra_data.items[start .. start + len];
        var first = true;
        for (indices) |raw_idx| {
            const node_idx: NodeIndex = @enumFromInt(raw_idx);
            if (node_idx.isNone()) continue;
            if (self.isSkipped(node_idx)) continue;
            if (!first) try self.write(sep);
            first = false;
            const wrap = wrap_sequences and self.ast.getNode(node_idx).tag == .sequence_expression;
            if (wrap) try self.writeByte('(');
            try self.emitNode(node_idx);
            if (wrap) try self.writeByte(')');
        }
    }
};

pub const hasRawPrivateSyntax = @import("../parser/ast_walk.zig").hasRawPrivateSyntax;
