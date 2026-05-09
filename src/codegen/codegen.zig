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
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;
const Kind = @import("../lexer/token.zig").Kind;
const Comment = @import("../lexer/scanner.zig").Comment;
const rt = @import("../bundler/runtime_helpers.zig");
const options_mod = @import("options.zig");
const module_emit = @import("modules.zig");
const type_runtime_emit = @import("type_runtime.zig");
const writer_emit = @import("writer.zig");
const debug_metadata = @import("debug_metadata.zig");
const expression_emit = @import("expressions.zig");

pub const ModuleFormat = options_mod.ModuleFormat;
pub const Platform = options_mod.Platform;
pub const IndentChar = options_mod.IndentChar;
pub const LinkingMetadata = options_mod.LinkingMetadata;
pub const QuoteStyle = options_mod.QuoteStyle;
pub const JsxRuntime = options_mod.JsxRuntime;
pub const CodegenOptions = options_mod.CodegenOptions;
pub const KeepNameEntry = options_mod.KeepNameEntry;

const SourceMapBuilder = @import("sourcemap.zig").SourceMapBuilder;
const Mapping = @import("sourcemap.zig").Mapping;
const FunctionMapBuilder = @import("function_map.zig").FunctionMapBuilder;
const RangeMapping = @import("function_map.zig").RangeMapping;

pub const Codegen = struct {
    const emitImport = module_emit.emitImport;
    const emitExportNamed = module_emit.emitExportNamed;
    const emitExportSpecifier = module_emit.emitExportSpecifier;
    const emitExportDefault = module_emit.emitExportDefault;
    const emitExportAll = module_emit.emitExportAll;

    const emitEnumIIFE = type_runtime_emit.emitEnumIIFE;
    const emitFlowEnum = type_runtime_emit.emitFlowEnum;
    const emitNamespaceIIFE = type_runtime_emit.emitNamespaceIIFE;

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
    const emitComments = statement_emit.emitComments;
    const isSkipped = statement_emit.isSkipped;
    pub const evalBooleanCondition = statement_emit.evalBooleanCondition;
    const emitProgram = statement_emit.emitProgram;
    const emitBlock = statement_emit.emitBlock;
    const emitBracedList = statement_emit.emitBracedList;
    const emitExpressionStatement = statement_emit.emitExpressionStatement;
    const emitReturn = statement_emit.emitReturn;
    const emitThrow = statement_emit.emitThrow;
    const emitIf = statement_emit.emitIf;
    const emitWhile = statement_emit.emitWhile;
    const emitDoWhile = statement_emit.emitDoWhile;
    const emitFor = statement_emit.emitFor;
    const emitForAwaitOf = statement_emit.emitForAwaitOf;
    const emitForInOf = statement_emit.emitForInOf;
    const emitSwitch = statement_emit.emitSwitch;
    const emitSwitchCase = statement_emit.emitSwitchCase;
    const emitSimpleStmt = statement_emit.emitSimpleStmt;
    const emitTry = statement_emit.emitTry;
    const emitCatch = statement_emit.emitCatch;
    const emitLabeled = statement_emit.emitLabeled;
    const emitWith = statement_emit.emitWith;

    // ================================================================
    // 노드 출력
    // ================================================================

    pub const Error = std.mem.Allocator.Error;

    pub fn emitNode(self: *Codegen, idx: NodeIndex) Error!void {
        if (idx.isNone()) return;

        // 번들 모드: skip_nodes에 있으면 출력하지 않음 (import/export 제거)
        if (self.isSkipped(idx)) return;

        const node = self.ast.getNode(idx);

        // 이 노드 이전에 위치한 주석들을 출력.
        // STRING_TABLE_BIT가 설정된 span은 합성 노드(string_table 참조)이므로
        // 원본 소스 위치가 아님 → 주석 위치 비교를 건너뛴다.
        if (node.span.start != node.span.end and node.span.start & Ast.STRING_TABLE_BIT == 0) {
            try self.emitComments(node.span.start);
        }

        // 소스맵 매핑: 유의미한 노드 출력 시 원본 위치 기록.
        // 컨테이너 노드(program, block, function_body)는 자식의 매핑을 오염시키므로 제외.
        if (self.sm_builder != null and node.span.start != node.span.end) {
            switch (node.tag) {
                .program,
                .block_statement,
                .function_body,
                .class_body,
                .static_block,
                .switch_statement,
                .try_statement,
                => {},
                else => try self.addSourceMapping(node.span),
            }
        }

        switch (node.tag) {
            .program => try self.emitProgram(node),
            .block_statement => try self.emitBlock(node),
            .empty_statement => try self.writeByte(';'),
            .expression_statement => try self.emitExpressionStatement(node),
            .variable_declaration => try self.emitVariableDeclaration(node),
            .variable_declarator => try self.emitVariableDeclarator(node),
            .return_statement => try self.emitReturn(node),
            .throw_statement => try self.emitThrow(node),
            .if_statement => try self.emitIf(node),
            .while_statement => try self.emitWhile(node),
            .do_while_statement => try self.emitDoWhile(node),
            .for_statement => try self.emitFor(node),
            .for_in_statement => try self.emitForInOf(node, "in"),
            .for_of_statement => try self.emitForInOf(node, "of"),
            .for_await_of_statement => try self.emitForAwaitOf(node),
            .switch_statement => try self.emitSwitch(node),
            .switch_case => try self.emitSwitchCase(node),
            .break_statement => try self.emitSimpleStmt(node, "break"),
            .continue_statement => try self.emitSimpleStmt(node, "continue"),
            .debugger_statement => try self.write("debugger;"),
            .try_statement => try self.emitTry(node),
            .catch_clause => try self.emitCatch(node),
            .labeled_statement => try self.emitLabeled(node),
            .with_statement => try self.emitWith(node),
            .directive => {
                // span 은 문자열 리터럴 범위 (따옴표 포함). quote_style 정규화를 적용해
                // `'use server'` → `"use server"` 같은 변환이 일반 string_literal 과 동일하게
                // 일어나도록 writeStringLiteral 사용. 항상 `;` 를 붙여 ASI 의존을 피한다.
                try self.writeStringLiteral(node.span);
                try self.writeByte(';');
            },
            .hashbang => {
                if (!self.options.strip_hashbang) try self.writeNodeSpan(node);
            },

            // Literals
            .boolean_literal => {
                // Peephole: true → !0, false → !1 (minify_syntax 활성화 시).
                // #1552: 각 리터럴당 2-3 byte 절감. 출현 빈도 높아 총 크기 영향 있음.
                // span의 첫 byte는 `t` 또는 `f`로 고정(렉서 불변식) — 한 byte 검사로 판별.
                if (self.options.minify_syntax) {
                    const text = self.ast.getText(node.span);
                    try self.write(if (text.len > 0 and text[0] == 't') "!0" else "!1");
                } else {
                    try self.writeNodeSpan(node);
                }
            },
            .null_literal,
            .numeric_literal,
            .bigint_literal,
            .regexp_literal,
            => try self.writeNodeSpan(node),

            .string_literal => try self.writeStringLiteral(node.span),

            // Identifiers — 번들 모드에서 symbol_id 기반 리네임 적용
            .identifier_reference,
            .private_identifier,
            .binding_identifier,
            .assignment_target_identifier,
            => {
                // Peephole: global `undefined` → `(void 0)` (minify_syntax 활성화 시).
                // 9 bytes → 8 bytes, 1 byte 절감. parens는 member/call/new 등 모든 parent
                // context에서 안전하게 해석되도록 유지 — `undefined.x`/`undefined()` 같은
                // 경로를 간단한 치환으로 깨지 않기 위함 (`void 0.x`는 `void (0.x)`로 오파싱).
                // global binding일 때만 치환 (shadow rebind 드물지만 보호).
                if (self.options.minify_syntax and node.tag == .identifier_reference) {
                    const text = self.ast.getText(node.span);
                    if (std.mem.eql(u8, text, "undefined")) {
                        const is_global = if (self.options.linking_metadata) |meta|
                            self.resolveSymbolId(idx, meta) == null
                        else
                            true;
                        if (is_global) {
                            try self.write("(void 0)");
                            return;
                        }
                    }
                }

                if (self.options.linking_metadata) |meta| {
                    const sym_id = self.resolveSymbolId(idx, meta);
                    if (sym_id) |sid| {
                        // 상수 인라인: import symbol이 상수이면 리터럴로 대체
                        if (node.tag == .identifier_reference) {
                            if (meta.const_values.get(sid)) |cv| {
                                try self.writeConstValue(cv);
                                return;
                            }
                        }
                        // namespace 변수 참조: ns를 값으로 사용 → 변수명으로 치환
                        if (meta.ns_inline_objects.get(sid)) |entry| {
                            try self.write(entry.var_name);
                            return;
                        }
                        if (meta.renames.get(sid)) |new_name| {
                            try self.write(new_name);
                            return;
                        }
                    }
                }
                // namespace IIFE 내부: export된 변수의 "참조"를 ns.name으로 치환.
                // identifier_reference(값 참조)와 assignment_target_identifier(대입 대상) 모두 치환.
                // binding_identifier(선언 위치)는 치환하지 않음 — 선언은 emitNamespaceVarDirectAssign에서 처리.
                if (self.ns_prefix) |prefix| {
                    if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
                        const name = self.ast.getText(node.data.string_ref);
                        if (self.ns_exports) |exports| {
                            if (exports.contains(name)) {
                                try self.write(prefix);
                                try self.writeByte('.');
                                try self.write(name);
                                return;
                            }
                        }
                    }
                }
                try self.writeSpan(node.data.string_ref);
            },

            .this_expression => try self.write("this"),
            .super_expression => try self.write("super"),

            // Expressions
            .unary_expression => try self.emitUnary(node),
            .update_expression => try self.emitUpdate(node),
            .binary_expression, .logical_expression => try self.emitBinary(node),
            .assignment_expression => try self.emitAssignment(node),
            .conditional_expression => try self.emitConditional(node),
            .sequence_expression => try self.emitSequence(node),
            .parenthesized_expression => try self.emitParen(node),
            .spread_element => try self.emitSpread(node),
            .await_expression => try self.emitAwait(node),
            .yield_expression => try self.emitYield(node),
            .array_expression => try self.emitArray(node),
            .object_expression => try self.emitObject(node),
            .object_property => try self.emitObjectProperty(node),
            .computed_property_key => try self.emitComputedKey(node),
            .static_member_expression => try self.emitStaticMember(node),
            .computed_member_expression => try self.emitComputedMember(node),
            .private_field_expression => try self.emitStaticMember(node),
            .call_expression => try self.emitCall(node),
            .new_expression => try self.emitNew(node),
            .template_literal => try self.emitTemplateLiteral(node),
            .template_element => try self.writeNodeSpan(node),
            .tagged_template_expression => try self.emitTaggedTemplate(node),
            .import_expression => try self.emitImportExpr(node),
            .meta_property => try self.emitMetaProperty(node),
            .chain_expression => try self.emitNode(node.data.unary.operand),

            // Functions / Classes
            .function_declaration, .function_expression, .function => try self.emitFunction(node),
            .arrow_function_expression => try self.emitArrow(node),
            .class_declaration, .class_expression => try self.emitClass(node),
            .class_body => try self.emitClassBody(node),
            .method_definition => try self.emitMethodDef(node),
            .property_definition => try self.emitPropertyDef(node),
            .static_block => try self.emitStaticBlock(node),
            .decorator => try self.emitDecorator(node),
            .accessor_property => try self.emitAccessorProp(node),

            // Patterns
            .array_pattern, .array_assignment_target => try self.emitArray(node),
            .object_pattern, .object_assignment_target => try self.emitObject(node),
            .assignment_pattern => try self.emitAssignmentPattern(node),
            .binding_property => try self.emitBindingProperty(node),
            .rest_element, .binding_rest_element, .assignment_target_rest => try self.emitRest(node),
            .assignment_target_with_default => try self.emitAssignmentPattern(node),
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            => try self.emitBindingProperty(node),
            .elision => {},

            // Import/Export
            .import_declaration => try self.emitImport(node),
            .import_specifier,
            .import_default_specifier,
            .import_namespace_specifier,
            .import_attribute,
            => try self.writeNodeSpan(node),
            .export_named_declaration => try self.emitExportNamed(node),
            .export_default_declaration => try self.emitExportDefault(node),
            .export_all_declaration => try self.emitExportAll(node),
            .export_specifier => try self.emitExportSpecifier(node),

            // Formal parameters
            .formal_parameters, .function_body => try self.emitList(node, self.listSep()),

            .formal_parameter => try self.emitFormalParam(node),

            // Flow match expression — transformer에서 if-else IIFE로 변환됨
            // 변환되지 않은 경우 (non-bundle 등) span 텍스트 그대로 출력
            .flow_match_expression => try self.writeNodeSpan(node),

            // JSX: Transformer의 jsx_lowering이 call_expression으로 변환 완료.
            // codegen은 JSX AST 노드를 만나지 않아야 함.
            .jsx_element,
            .jsx_fragment,
            .jsx_expression_container,
            .jsx_text,
            .jsx_spread_attribute,
            .jsx_spread_child,
            => unreachable,

            // TS enum/namespace → IIFE 출력
            .ts_enum_declaration => try self.emitEnumIIFE(node),
            .ts_module_declaration => try self.emitNamespaceIIFE(node),
            // Flow enum (#2401) → `const Name = Object.freeze({...})` 출력. members 의
            // init expression 이 없으면 base_type 에 따라 default value (string/number/...).
            .flow_enum_declaration => try self.emitFlowEnum(node),

            // TS/Flow expression 노드: operand만 출력 (type 부분 스트리핑).
            // pre-visit body를 codegen할 때 (e.g. worklet __initData.code) TS/Flow 노드가 남아있을 수 있음.
            .ts_as_expression,
            .ts_satisfies_expression,
            .ts_non_null_expression,
            .ts_type_assertion,
            .ts_instantiation_expression,
            .flow_as_expression,
            .flow_type_cast_expression,
            => try self.emitNode(node.data.unary.operand),

            // TS 타입 전용 노드: 출력 안 함
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_import_equals_declaration,
            => {},

            // 그 외 — 소스 텍스트 그대로 출력
            else => try self.writeNodeSpan(node),
        }
    }

    // ================================================================
    // Expression 출력
    // ================================================================

    const emitUnary = expression_emit.emitUnary;
    const emitUpdate = expression_emit.emitUpdate;
    const emitBinary = expression_emit.emitBinary;
    const emitAssignment = expression_emit.emitAssignment;
    const emitConditional = expression_emit.emitConditional;
    const emitSequence = expression_emit.emitSequence;
    const emitParen = expression_emit.emitParen;
    const emitSpread = expression_emit.emitSpread;
    const emitAwait = expression_emit.emitAwait;
    const emitYield = expression_emit.emitYield;
    const emitArray = expression_emit.emitArray;
    const emitObject = expression_emit.emitObject;
    const emitObjectProperty = expression_emit.emitObjectProperty;
    const emitComputedKey = expression_emit.emitComputedKey;
    const emitStaticMember = expression_emit.emitStaticMember;
    const emitComputedMember = expression_emit.emitComputedMember;

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
    const emitCall = call_emit.emitCall;
    const emitNew = call_emit.emitNew;
    const emitMetaProperty = call_emit.emitMetaProperty;
    const emitImportExpr = call_emit.emitImportExpr;
    pub const resolveImportMetaProp = call_emit.resolveImportMetaProp;
    pub const writeImportMetaUrl = call_emit.writeImportMetaUrl;
    pub const resolveRequireRewriteSpecifier = call_emit.resolveRequireRewriteSpecifier;
    pub const emitRewriteValue = call_emit.emitRewriteValue;
    pub const emitRequireRewriteOrCall = call_emit.emitRequireRewriteOrCall;

    // ================================================================
    // Template / Function / Class emission — codegen/function_class.zig로 위임
    // ================================================================
    const function_class_emit = @import("function_class.zig");
    const emitTemplateLiteral = function_class_emit.emitTemplateLiteral;
    const emitTaggedTemplate = function_class_emit.emitTaggedTemplate;
    const emitFunction = function_class_emit.emitFunction;
    const emitArrow = function_class_emit.emitArrow;
    const emitClass = function_class_emit.emitClass;
    const emitClassBody = function_class_emit.emitClassBody;
    const emitStaticBlock = function_class_emit.emitStaticBlock;
    const emitMethodDef = function_class_emit.emitMethodDef;
    const emitPropertyDef = function_class_emit.emitPropertyDef;
    const emitDecorator = function_class_emit.emitDecorator;
    const emitAccessorProp = function_class_emit.emitAccessorProp;

    // ================================================================
    // Pattern/declaration emission — codegen/bindings.zig로 위임
    // ================================================================
    const binding_emit = @import("bindings.zig");
    const emitAssignmentPattern = binding_emit.emitAssignmentPattern;
    const emitBindingProperty = binding_emit.emitBindingProperty;
    const emitRest = binding_emit.emitRest;
    const emitVariableDeclaration = binding_emit.emitVariableDeclaration;
    const emitVariableDeclarator = binding_emit.emitVariableDeclarator;
    const emitFormalParam = binding_emit.emitFormalParam;

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
        if (len == 0) return;
        const indices = self.ast.extra_data.items[start .. start + len];
        var first = true;
        for (indices) |raw_idx| {
            const node_idx: NodeIndex = @enumFromInt(raw_idx);
            if (node_idx.isNone()) continue;
            if (self.isSkipped(node_idx)) continue;
            if (!first) try self.write(sep);
            first = false;
            try self.emitNode(node_idx);
        }
    }
};

pub const hasRawPrivateSyntax = @import("../parser/ast_walk.zig").hasRawPrivateSyntax;
