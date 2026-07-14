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
const Kind = @import("../lexer/token.zig").Kind;
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
    declared_names: std.StringHashMapUnmanaged(void) = .empty,
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
    /// 다음에 emit 할 member expression 이 assignment/update 의 *타겟*(lvalue)인지.
    /// emitAssignment/emitUpdate 가 operand emit 직전 set, emitStaticMember 가 진입
    /// 즉시 읽고 리셋(중첩 object 위치는 rvalue 라 영향 X). 미존재 namespace 멤버를
    /// `(void 0)` 으로 재작성할 때, lvalue 위치(`ns.x = 1` → `(void 0)=1`)면 SyntaxError
    /// 가 되므로 그 경우엔 재작성을 건너뛴다.
    member_assign_target: bool = false,
    /// statement-start 모호성 추적 (esbuild `stmtStart`/`exportDefaultStart`/
    /// `arrowExprStart`). 각 컨텍스트의 첫 토큰을 출력하기 직전 현재 `buf.items.len`
    /// 으로 마킹하고, expression emitter 가 진입 시 `buf.items.len` 이 마크와 같으면
    /// "내가 그 컨텍스트의 첫 토큰" 으로 판정해 괄호를 친다 (`({}).x`,
    /// `(function(){})()`, `(class{})`). `maxInt` = 미마킹(절대 매치 안 됨).
    /// (for-of init `let`/`async` wrap 은 sloppy `.js` 전용 + identifier early-return
    ///  충돌로 미구현 — 필요 시 `for_of_init_start` 필드 재도입.)
    stmt_start: usize = std.math.maxInt(usize),
    export_default_start: usize = std.math.maxInt(usize),
    arrow_expr_start: usize = std.math.maxInt(usize),
    /// 직전에 출력한 numeric literal 이 정수 형태(`42`)라 바로 뒤 `.` 가 소수점으로
    /// 오파싱될 수 있는 위치. emit 직후 `buf.items.len` 으로 마킹하고, static member
    /// 의 `.` emit 직전 위치가 일치하면 공백을 끼운다(`42 .toString()`). esbuild
    /// `needSpaceBeforeDot`. `maxInt` = 미마킹(절대 매치 안 됨).
    need_space_before_dot: usize = std.math.maxInt(usize),
    /// 직전에 출력한 **연산자 토큰**과 그 끝 위치 (esbuild `prevOp`/`prevOpEnd`).
    /// 인접 토큰이 `++`/`--`/`<!--` 로 잘못 합쳐지는 것을 막는 공백을 넣을지 판정한다
    /// (`printSpaceBeforeOperator`). AST 태그가 아니라 **실제 출력 바이트** 기준이라,
    /// 상수 폴딩/치환으로 emit 되는 노드가 바뀌어도(`x - (ON ? -1 : 1)` → `x- -1`)
    /// 정확하다 (#4482). `maxInt` = 미마킹(절대 매치 안 됨).
    prev_op: Kind = .eof,
    prev_op_end: usize = std.math.maxInt(usize),
    /// `undefinedPeepholeApplies` 의 모듈 단위 캐시. null = 아직 스캔 안 함.
    undefined_shadowed: ?bool = null,

    /// `undefined` → `void 0` peephole 을 이 식별자에 적용할 수 있는가.
    ///
    /// peephole 은 **unbound global** `undefined` 참조에만 유효하다. 지역 바인딩이
    /// 섀도잉하면(`let undefined = x`) `void 0` 은 값이 **틀린다**.
    ///
    /// 예전 가드는 `sym_id == null` 하나였는데, `sym_id` 는 `linking_metadata` 가 있을
    /// 때만(=번들 모드) 채워진다. transpile 모드엔 metadata 가 없어 sym_id 가 **항상**
    /// null → "unbound" 판정이 무조건 참 → 섀도잉된 `undefined` 까지 `void 0` 으로
    /// 바뀌었다. 그래서 이 모듈에 `undefined` 라는 이름의 **바인딩**이 하나라도 있으면
    /// peephole 을 끈다. 섀도잉은 극히 드물어 size 영향은 사실상 0 이다.
    ///
    /// node_dispatch(식별자 case) 와 expressions(`identifierEmitsSubstituted`) 가 **같은**
    /// 술어를 봐야 shorthand 확장 판단이 어긋나지 않는다 — 그래서 여기 한 곳에 둔다.
    pub fn undefinedPeepholeApplies(self: *Codegen, n: Node, sym_id: ?u32) bool {
        if (!self.options.minify_syntax) return false;
        if (n.tag != .identifier_reference) return false;
        if (sym_id != null) return false; // 번들 모드: 해석된 심볼 = 지역 바인딩
        if (!std.mem.eql(u8, self.ast.identifierNameText(n), "undefined")) return false;
        return !self.undefinedIsShadowed();
    }

    /// 이 모듈 AST 에 `undefined` 라는 이름의 바인딩이 있는가 (모듈당 1회 스캔·캐시).
    /// peephole 이 실제로 `undefined` 텍스트를 만났을 때만 호출되므로 대부분의 모듈은
    /// 스캔조차 하지 않는다.
    ///
    /// **import 바인딩도 포함해야 한다.** `import { v as undefined }` 의 local 은 별도
    /// `binding_identifier` 노드가 아니라 `import_specifier` 의 오른쪽 자식이고, 그 태그는
    /// `identifier_reference` 다(`parseIdentifierName`). 그래서 binding_identifier 만 훑으면
    /// 이 바인딩이 안 보이고, 게다가 그 local 노드 자신이 peephole 을 맞아
    /// `import { v as void 0 }` — **파싱 불가** 산출물이 나온다.
    fn undefinedIsShadowed(self: *Codegen) bool {
        if (self.undefined_shadowed) |v| return v;
        var found = false;
        for (self.ast.nodes.items) |n| {
            const named: ?Node = switch (n.tag) {
                // `let/var/const` · 파라미터 · catch · function/class 이름
                .binding_identifier => n,
                // `import undefined from` · `import * as undefined` — 이름이 노드 자신
                .import_default_specifier, .import_namespace_specifier => n,
                // `import { v as undefined }` — local 은 오른쪽 자식(identifier_reference)
                .import_specifier => blk: {
                    const local = n.data.binary.right;
                    if (local.isNone() or @intFromEnum(local) >= self.ast.nodes.items.len) break :blk null;
                    break :blk self.ast.getNode(local);
                },
                else => continue,
            };
            const name_node = named orelse continue;
            if (std.mem.eql(u8, self.ast.identifierNameText(name_node), "undefined")) {
                found = true;
                break;
            }
        }
        self.undefined_shadowed = found;
        return found;
    }

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
        const profile = @import("../profile.zig");
        var scope = profile.begin(.codegen);
        defer scope.end();

        if (self.options.assert_no_raw_private_syntax) {
            std.debug.assert(!hasRawPrivateSyntax(self.ast, root));
        }

        // (C1 도구 보강 + review fix) sub-phase 측정 — review P1: defer 패턴으로 OOM 시
        // scope leak 방지. fnMap enter/exit 는 emit_scope 안으로 옮겨 sub-phase 합 정확화.
        {
            var setup_scope = profile.begin(.codegen_setup);
            defer setup_scope.end();
            // 출력 크기는 보통 소스 크기와 비슷 → 사전 할당
            try self.buf.ensureTotalCapacity(self.allocator, self.ast.source.len);
            // namespace var 중복 제거: top-level 선언 이름 사전 수집
            self.collectTopLevelDeclNames(root);
        }
        {
            var emit_scope = profile.begin(.codegen_emit);
            defer emit_scope.end();
            // function map: program 진입 시 <global> frame — sub-phase 합 정확성 위해
            // emit_scope 안에 포함 (review P2).
            if (self.fn_map_builder != null) try self.fnMapEnter("<global>");
            try self.emitNode(root);
            if (self.fn_map_builder != null) try self.fnMapExit();
        }

        var finalize_scope = profile.begin(.codegen_finalize);
        defer finalize_scope.end();

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
    pub const printSpaceBeforeOperator = writer_emit.printSpaceBeforeOperator;
    pub const recordOperatorToken = writer_emit.recordOperatorToken;
    pub const writeConstValue = writer_emit.writeConstValue;
    pub const writeSpan = writer_emit.writeSpan;
    pub const writeAsciiOnly = writer_emit.writeAsciiOnly;
    pub const writeNodeSpan = writer_emit.writeNodeSpan;
    pub const writeIdentifierSpan = writer_emit.writeIdentifierSpan;
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
    pub const emitExpr = node_dispatch_emit.emitExpr;
    pub const exprNeedsParens = node_dispatch_emit.exprNeedsParens;

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

    /// statement-start 모호성 마크 4종의 현재 활성 여부 스냅샷 (esbuild
    /// `exprStartFlags`). prefix(주석/`/* @__PURE__ */`)를 출력해 버퍼 위치가
    /// 밀리기 전에 캡처하고, 출력 직후 `restoreExprStartFlags` 로 마크를 새 위치로
    /// 옮겨 prefix 뒤의 expression 이 여전히 "그 컨텍스트의 첫 토큰" 으로 판정되게 한다.
    pub const ExprStartFlags = packed struct {
        stmt_start: bool = false,
        export_default_start: bool = false,
        arrow_expr_start: bool = false,
    };

    /// 현재 출력 위치에서 어떤 statement-start 마크가 활성인지 캡처 (esbuild
    /// `saveExprStartFlags`).
    pub fn saveExprStartFlags(self: *Codegen) ExprStartFlags {
        const n = self.buf.items.len;
        return .{
            .stmt_start = self.stmt_start == n,
            .export_default_start = self.export_default_start == n,
            .arrow_expr_start = self.arrow_expr_start == n,
        };
    }

    /// 캡처해 둔 마크를 현재 출력 위치로 복원 (esbuild `restoreExprStartFlags`).
    /// prefix 출력 후 호출해 마크가 prefix 뒤 토큰을 가리키게 한다.
    pub fn restoreExprStartFlags(self: *Codegen, flags: ExprStartFlags) void {
        const n = self.buf.items.len;
        if (flags.stmt_start) self.stmt_start = n;
        if (flags.export_default_start) self.export_default_start = n;
        if (flags.arrow_expr_start) self.arrow_expr_start = n;
    }

    /// 현재 위치가 statement-start 또는 arrow expression body-start 마크와 일치하는지.
    /// object literal(`({})`)·destructuring 할당(`({a}=b)`) wrap 판정에 쓴다.
    pub fn atStmtOrArrowStart(self: *Codegen) bool {
        const n = self.buf.items.len;
        return self.stmt_start == n or self.arrow_expr_start == n;
    }

    /// 현재 위치가 statement-start 또는 export-default-start 마크와 일치하는지.
    /// function/class expression(`(function(){})`·`(class{})`) wrap 판정에 쓴다.
    pub fn atStmtOrExportDefaultStart(self: *Codegen) bool {
        const n = self.buf.items.len;
        return self.stmt_start == n or self.export_default_start == n;
    }

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
            // expression list(call args/array items)는 argument 위치 → .comma.
            // sequence(.comma) 는 .comma wrap 으로 괄호(`f((a,b))`, esbuild parity) — 이전의
            // wrap_sequences ad-hoc 괄호는 precedence wrap 으로 대체되어 제거(이중괄호 방지).
            // statement list(formal params/function body 등)는 emitNode(.lowest) 유지.
            if (wrap_sequences) {
                try self.emitExpr(node_idx, .comma, .{});
            } else {
                try self.emitNode(node_idx);
            }
        }
    }
};

pub const hasRawPrivateSyntax = @import("../parser/ast_walk.zig").hasRawPrivateSyntax;
