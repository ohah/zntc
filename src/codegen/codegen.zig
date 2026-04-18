//! ZTS Codegen — AST를 JS 문자열로 출력
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
const module_parser = @import("../parser/module.zig");
const Kind = @import("../lexer/token.zig").Kind;
const Comment = @import("../lexer/scanner.zig").Comment;

/// 모듈 출력 형식
pub const ModuleFormat = enum {
    esm, // ESM (import/export 그대로)
    cjs, // CommonJS (require/exports 변환)
};

/// 타겟 플랫폼 (import.meta polyfill 등에 사용)
pub const Platform = enum {
    browser,
    node,
    neutral,
    react_native,

    /// browser와 동일한 동작을 하는 플랫폼인지 (Node 빌트인 대체, browser 필드 등).
    pub fn isBrowserLike(self: Platform) bool {
        return self == .browser or self == .react_native;
    }
};

/// 들여쓰기 문자 (D044)
pub const IndentChar = enum {
    tab,
    space,
};

/// 번들러 linker가 생성하는 per-module 메타데이터.
/// codegen이 import 스킵 + 식별자 리네임에 사용.
const linker_mod = @import("../bundler/linker.zig");
pub const LinkingMetadata = linker_mod.LinkingMetadata;

pub const QuoteStyle = enum {
    double, // " (기본, esbuild/oxc/SWC 호환)
    single, // '
    preserve, // 원본 유지
};

/// JSX 런타임 모드. tsconfig "jsx" 필드 또는 CLI --jsx 옵션으로 결정.
pub const JsxRuntime = enum {
    /// React.createElement (또는 커스텀 factory). import 자동 주입 없음.
    classic,
    /// jsx/jsxs from "<importSource>/jsx-runtime". import 자동 주입.
    automatic,
    /// jsxDEV from "<importSource>/jsx-dev-runtime". source info 포함.
    automatic_dev,
};

pub const CodegenOptions = struct {
    module_format: ModuleFormat = .esm,
    /// 문자열 따옴표 스타일 (기본: 쌍따옴표, esbuild/oxc 호환)
    quote_style: QuoteStyle = .double,
    /// 들여쓰기 문자 (D044: Tab 기본)
    indent_char: IndentChar = .tab,
    /// Space일 때 들여쓰기 너비 (기본 2)
    indent_width: u8 = 2,
    /// 줄바꿈 문자 (D045: \n 기본, Windows는 \r\n)
    newline: []const u8 = "\n",
    /// 공백/줄바꿈/들여쓰기 최소화
    minify_whitespace: bool = false,
    /// Peephole 출력 최적화 — boolean literal을 `!0`/`!1`로 축약(#1552).
    /// `minify_whitespace`와 독립적으로 켤 수 있음(transformer의 AST fold와 별개).
    minify_syntax: bool = false,
    /// 소스맵 생성 활성화
    sourcemap: bool = false,
    /// non-ASCII 문자를 \uXXXX로 이스케이프 (D031)
    ascii_only: bool = false,
    /// 소스맵 sourceRoot 필드
    source_root: []const u8 = "",
    /// 소스맵에 sourcesContent 포함 여부 (기본: true)
    sources_content: bool = true,
    /// 번들러 linker 메타데이터. 설정 시 import 스킵 + 식별자 리네임 적용.
    linking_metadata: ?*const LinkingMetadata = null,
    /// __esm 래핑 모듈: CJS import 변환 시 const 대신 var 사용.
    /// ESM의 import는 hoisted이지만 CJS 변환 시 선언 위치에 출력되어 TDZ 발생.
    use_var_for_imports: bool = false,
    /// __esm 래핑 모듈: CJS export 출력 억제 (exports.x, module.exports).
    /// __esm 모듈의 export는 emitter의 __export()가 처리하므로 codegen에서 생성하면 안 됨.
    skip_cjs_exports: bool = false,
    /// 번들 모드에서 ESM이 아닐 때 import.meta → {} 치환 (esbuild 호환)
    replace_import_meta: bool = false,
    /// 타겟 플랫폼. import.meta polyfill 방식을 결정한다.
    /// - node: import.meta.url → require("url").pathToFileURL(__filename).href,
    ///         import.meta.dirname → __dirname, import.meta.filename → __filename
    /// - browser/neutral: import.meta.url → "", import.meta.dirname → "", import.meta.filename → ""
    platform: Platform = .browser,
    /// --keep-names: minify 시 함수/클래스의 .name 프로퍼티 보존.
    /// codegen이 rename 감지 후 __name() 호출을 수집, 선언 직후에 append.
    keep_names: bool = false,
    /// ES2023 미만 타겟에서 hashbang (#!) 제거
    strip_hashbang: bool = false,
    // JSX 옵션 제거: Transformer의 jsx_lowering이 JSX → call_expression 변환을 담당.
    // JsxRuntime enum은 graph.zig/emitter.zig/transpile.zig에서 여전히 사용.
    /// __esm 호이스팅 모드: variable_declaration을 할당문으로 변환 (키워드 제거).
    /// emitter가 var 선언을 래퍼 밖에 별도 배치.
    esm_var_assign_only: bool = false,
    /// dev mode 모듈 ID. 설정 시 import.meta.hot → __zts_make_hot("id") 변환.
    dev_module_id: ?[]const u8 = null,
    /// import.meta.glob 레코드. codegen이 glob 호출을 객체 리터럴로 직접 출력.
    import_records: []const @import("../bundler/types.zig").ImportRecord = &.{},
    /// Metro x_facebook_sources function map emit 활성화.
    /// --platform=react-native 시 자동 활성화 (PR#3).
    sourcemap_function_map: bool = false,
};

/// keepNames 엔트리. codegen이 수집하고 emitter가 __name() 호출로 변환.
pub const KeepNameEntry = struct {
    /// 리네임된 이름 (linker가 부여한 새 이름)
    new_name: []const u8,
    /// 원본 이름 (소스 코드의 함수/클래스 이름)
    original_name: []const u8,
};

// import.meta polyfill 상수 (emitMetaProperty + emitStaticMember에서 공유)
const IMPORT_META_URL_NODE = "require(\"url\").pathToFileURL(__filename).href";
const IMPORT_META_NODE_OBJECT = "{url:" ++ IMPORT_META_URL_NODE ++ ",dirname:__dirname,filename:__filename}";

const SourceMapBuilder = @import("sourcemap.zig").SourceMapBuilder;
const Mapping = @import("sourcemap.zig").Mapping;
const FunctionMapBuilder = @import("function_map.zig").FunctionMapBuilder;
const RangeMapping = @import("function_map.zig").RangeMapping;

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
    /// function map 이름 스택. enter 시 push, exit 시 pop. last()가 현재 scope 이름.
    fn_name_stack: std.ArrayList([]const u8) = .empty,
    /// 다음 function/arrow/class에 적용할 contextual name.
    /// parent emit(VariableDeclarator, Assignment, ObjectProperty 등)에서 설정,
    /// emitFunction/emitArrow/emitClass 진입 시 소비 후 null 로 초기화.
    pending_fn_name: ?[]const u8 = null,

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
            // JSX 필드 제거: Transformer가 JSX lowering 담당
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.buf.deinit(self.allocator);
        self.declared_names.deinit(self.allocator);
        self.keep_names_entries.deinit(self.allocator);
        if (self.sm_builder) |*sm| sm.deinit();
        if (self.fn_map_builder) |*fm| fm.deinit();
        self.fn_name_stack.deinit(self.allocator);
    }

    /// 특정 statement 노드 목록만 코드로 생성한다 (__esm var 호이스팅용).
    /// root는 collectTopLevelDeclNames에만 사용. 실제 출력은 stmt_indices에서.
    pub fn generateStatements(self: *Codegen, root: NodeIndex, stmt_indices: []const u32) ![]const u8 {
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
        // 출력 크기는 보통 소스 크기와 비슷 → 사전 할당
        try self.buf.ensureTotalCapacity(self.allocator, self.ast.source.len);

        // namespace var 중복 제거: top-level 선언 이름 사전 수집
        self.collectTopLevelDeclNames(root);

        // function map: program 진입 시 <global> frame
        if (self.fn_map_builder != null) try self.fnMapEnter("<global>");
        try self.emitNode(root);
        if (self.fn_map_builder != null) try self.fnMapExit();

        // keepNames: 수집된 entries를 코드 끝에 __name() 호출로 append (복사 없음)
        for (self.keep_names_entries.items) |entry| {
            try self.write("__name(");
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

    /// byte offset → 소스 줄/열 변환 (이진 탐색).
    fn getOriginalLineColumn(self: *const Codegen, offset: u32) struct { line: u32, column: u32 } {
        const offsets = self.line_offsets;
        if (offsets.len == 0) return .{ .line = 0, .column = offset };
        var lo: u32 = 0;
        var hi: u32 = @intCast(offsets.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (offsets[mid] <= offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line_idx = if (lo > 0) lo - 1 else 0;
        return .{
            .line = line_idx,
            .column = offset - offsets[line_idx],
        };
    }

    /// 소스맵에 소스 파일을 등록한다. generate() 전에 호출.
    pub fn addSourceFile(self: *Codegen, source_name: []const u8) !void {
        if (self.sm_builder) |*sm| {
            _ = try sm.addSource(source_name);
            // sourcesContent 옵션이 켜져 있으면 소스 내용도 추가
            if (self.options.sources_content) {
                try sm.addSourceContent(self.ast.source);
            }
        }
    }

    /// 소스맵 JSON을 생성한다. generate() 후에 호출.
    pub fn generateSourceMap(self: *Codegen, output_file: []const u8) !?[]const u8 {
        if (self.sm_builder) |*sm| {
            return try sm.generateJSON(output_file);
        }
        return null;
    }

    /// 소스맵 JSON + x_facebook_sources를 함께 생성한다. generate() 후에 호출.
    /// fn_map_builder가 없으면 generateSourceMap과 동일.
    pub fn generateSourceMapWithFunctionMap(self: *Codegen, output_file: []const u8) !?[]const u8 {
        const sm = &(self.sm_builder orelse return null);
        if (self.fn_map_builder) |*fm| {
            return try sm.generateJSONWithFunctionMap(self.allocator, output_file, fm);
        }
        return try sm.generateJSON(output_file);
    }

    // ================================================================
    // 출력 헬퍼
    // ================================================================

    /// 리스트 구분자: minify_whitespace=true면 "," 아니면 ", ".
    /// formal_parameters, arguments, array literal 등에서 공용.
    inline fn listSep(self: *const Codegen) []const u8 {
        return if (self.options.minify_whitespace) "," else ", ";
    }

    fn write(self: *Codegen, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
        // 줄/열 추적
        for (s) |c| {
            if (c == '\n') {
                self.gen_line += 1;
                self.gen_col = 0;
            } else {
                self.gen_col += 1;
            }
        }
    }

    fn writeByte(self: *Codegen, b: u8) !void {
        try self.buf.append(self.allocator, b);
        if (b == '\n') {
            self.gen_line += 1;
            self.gen_col = 0;
        } else {
            self.gen_col += 1;
        }
    }

    // ================================================================
    // Function Map 도우미
    // ================================================================

    /// 현재 generated position으로 새 이름 frame에 진입. fn_name_stack push.
    /// 이름이 바뀔 때만 FunctionMapBuilder.push 호출 (중복 제거는 FunctionMapBuilder가 담당).
    fn fnMapEnter(self: *Codegen, name: []const u8) !void {
        if (self.fn_map_builder == null) return;
        try self.fn_map_builder.?.push(.{
            .name = name,
            .line = self.gen_line + 1, // FunctionMapBuilder는 1-based
            .column = self.gen_col,
        });
        try self.fn_name_stack.append(self.allocator, name);
    }

    /// 현재 generated position으로 frame 종료. fn_name_stack pop 후 부모 이름으로 복귀.
    fn fnMapExit(self: *Codegen) !void {
        if (self.fn_map_builder == null) return;
        if (self.fn_name_stack.items.len == 0) return;
        _ = self.fn_name_stack.pop();
        if (self.fn_name_stack.items.len == 0) return;
        const parent = self.fn_name_stack.items[self.fn_name_stack.items.len - 1];
        try self.fn_map_builder.?.push(.{
            .name = parent,
            .line = self.gen_line + 1,
            .column = self.gen_col,
        });
    }

    /// 노드가 function/arrow/class 인지 확인.
    fn isFunctionLike(self: *const Codegen, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        return switch (self.ast.getNode(idx).tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .class_declaration, .class_expression => true,
            else => false,
        };
    }

    /// binding_identifier 노드에서 이름 추출.
    fn resolveBindingName(self: *const Codegen, idx: NodeIndex) ?[]const u8 {
        if (idx.isNone()) return null;
        const n = self.ast.getNode(idx);
        return switch (n.tag) {
            .binding_identifier => self.ast.getText(n.data.string_ref),
            else => null,
        };
    }

    /// MemberExpression/identifier의 leaf 이름 추출 (assignment left 용).
    /// `a.b.c` → "c", `a["str"]` → "str", `a[expr]` → null
    fn resolveMemberLeafName(self: *const Codegen, idx: NodeIndex) ?[]const u8 {
        if (idx.isNone()) return null;
        const n = self.ast.getNode(idx);
        return switch (n.tag) {
            .identifier_reference, .assignment_target_identifier, .binding_identifier => self.ast.getText(n.data.string_ref),
            .static_member_expression => blk: {
                const e = n.data.extra;
                if (!self.ast.hasExtra(e, 2)) break :blk null;
                const property = self.ast.readExtraNode(e, 1);
                break :blk self.resolveIdentifierText(property);
            },
            .computed_member_expression => blk: {
                const e = n.data.extra;
                if (!self.ast.hasExtra(e, 2)) break :blk null;
                const property = self.ast.readExtraNode(e, 1);
                break :blk self.resolveKeyName(property);
            },
            else => null,
        };
    }

    /// object/method key 노드에서 이름 추출.
    /// identifier → 이름, string_literal → 값(따옴표 제거), numeric → 텍스트,
    /// computed(literal) → 값, computed(expr) → null
    fn resolveKeyName(self: *const Codegen, idx: NodeIndex) ?[]const u8 {
        if (idx.isNone()) return null;
        const n = self.ast.getNode(idx);
        return switch (n.tag) {
            .identifier_reference, .binding_identifier, .private_identifier => self.ast.getText(n.data.string_ref),
            .string_literal => self.resolveStringLiteralValue(n),
            .numeric_literal => self.ast.getText(n.span),
            .computed_property_key => blk: {
                const inner = n.data.unary.operand;
                if (inner.isNone()) break :blk null;
                const inner_n = self.ast.getNode(inner);
                // 리터럴만 이름으로 사용 (변수 참조는 런타임 값 → anonymous)
                break :blk switch (inner_n.tag) {
                    .string_literal => self.resolveStringLiteralValue(inner_n),
                    .numeric_literal => self.ast.getText(inner_n.span),
                    else => null,
                };
            },
            else => null,
        };
    }

    fn resolveIdentifierText(self: *const Codegen, idx: NodeIndex) ?[]const u8 {
        if (idx.isNone()) return null;
        const n = self.ast.getNode(idx);
        return switch (n.tag) {
            .identifier_reference, .binding_identifier, .private_identifier => self.ast.getText(n.data.string_ref),
            else => null,
        };
    }

    /// string_literal 노드에서 따옴표를 제거한 값 반환.
    fn resolveStringLiteralValue(self: *const Codegen, n: Node) ?[]const u8 {
        const text = self.ast.getText(n.span);
        return if (text.len >= 2) text[1 .. text.len - 1] else null;
    }

    /// fn_name_stack top (현재 class 이름). <global>/<anonymous> 이면 null.
    fn resolveParentClassName(self: *const Codegen) ?[]const u8 {
        const stack = self.fn_name_stack.items;
        if (stack.len == 0) return null;
        const top = stack[stack.len - 1];
        if (std.mem.eql(u8, top, "<global>") or std.mem.eql(u8, top, "<anonymous>")) return null;
        return top;
    }

    /// method_definition 키 + flags → Metro 스타일 이름 생성.
    /// getter → "get__name", setter → "set__name", constructor → class 이름.
    /// 부모 class 이름이 있으면 "ClassName#method" / "ClassName.method" 형태.
    fn resolveMethodName(self: *Codegen, key: NodeIndex, flags: u32) ![]const u8 {
        const is_getter = flags & ast_mod.MethodFlags.is_getter != 0;
        const is_setter = flags & ast_mod.MethodFlags.is_setter != 0;
        const is_static = flags & ast_mod.MethodFlags.is_static != 0;
        const sep: []const u8 = if (is_static) "." else "#";

        const raw = self.resolveKeyName(key) orelse "<anonymous>";

        // constructor → 부모 class 이름
        if (std.mem.eql(u8, raw, "constructor")) {
            return self.resolveParentClassName() orelse "constructor";
        }

        const class_name = self.resolveParentClassName();

        if (is_getter) {
            return if (class_name) |cn|
                std.fmt.allocPrint(self.allocator, "{s}{s}get__{s}", .{ cn, sep, raw })
            else
                std.fmt.allocPrint(self.allocator, "get__{s}", .{raw});
        }
        if (is_setter) {
            return if (class_name) |cn|
                std.fmt.allocPrint(self.allocator, "{s}{s}set__{s}", .{ cn, sep, raw })
            else
                std.fmt.allocPrint(self.allocator, "set__{s}", .{raw});
        }
        // 일반 메서드: class 컨텍스트 없으면 기존 슬라이스 그대로 반환 (할당 불필요)
        return if (class_name) |cn|
            std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ cn, sep, raw })
        else
            raw;
    }

    /// 소스맵 매핑 추가. 노드의 소스 span과 현재 출력 위치를 매핑.
    /// string_table span (bit 31 설정)은 합성 노드이므로 매핑 스킵.
    fn addSourceMapping(self: *Codegen, span: Span) !void {
        if (self.sm_builder) |*sm| {
            // 합성 노드(string_table) 또는 빈 span → 소스맵 매핑 스킵
            if (span.start & Ast.STRING_TABLE_BIT != 0 or (span.start == 0 and span.end == 0)) return;
            // byte offset → 줄/열 변환 (Scanner의 line_offsets 사용)
            const lc = self.getOriginalLineColumn(span.start);
            try sm.addMapping(.{
                .generated_line = self.gen_line,
                .generated_column = self.gen_col,
                .source_index = 0,
                .original_line = lc.line,
                .original_column = lc.column,
            });
        }
    }

    /// 줄바꿈 출력. minify 모드에서는 아무것도 출력하지 않음.
    fn writeNewline(self: *Codegen) !void {
        if (self.options.minify_whitespace) return;
        try self.write(self.options.newline);
    }

    /// 현재 들여쓰기 레벨만큼 들여쓰기 출력.
    fn writeIndent(self: *Codegen) !void {
        if (self.options.minify_whitespace) return;
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) {
            switch (self.options.indent_char) {
                .tab => try self.writeByte('\t'),
                .space => {
                    var j: u8 = 0;
                    while (j < self.options.indent_width) : (j += 1) {
                        try self.writeByte(' ');
                    }
                },
            }
        }
    }

    /// 공백 출력. minify에서는 생략.
    fn writeSpace(self: *Codegen) !void {
        if (!self.options.minify_whitespace) try self.writeByte(' ');
    }

    /// span 범위의 텍스트를 출력한다.
    /// source 또는 string_table에서 투명하게 읽는다 (getText 사용).
    const ConstValue = @import("../semantic/symbol.zig").ConstValue;

    /// ConstValue를 리터럴 문자열로 출력한다.
    fn writeConstValue(self: *Codegen, cv: ConstValue) !void {
        switch (cv.kind) {
            .true_ => try self.write("true"),
            .false_ => try self.write("false"),
            .null_ => try self.write("null"),
            .undefined_ => try self.write("void 0"),
            .none => {},
        }
    }

    fn writeSpan(self: *Codegen, span: Span) !void {
        const text = self.ast.getText(span);
        if (self.options.ascii_only) {
            try self.writeAsciiOnly(text);
        } else {
            try self.write(text);
        }
    }

    /// non-ASCII 문자를 \uXXXX로 이스케이프하여 출력.
    fn writeAsciiOnly(self: *Codegen, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const b = text[i];
            if (b < 0x80) {
                // ASCII
                try self.writeByte(b);
                i += 1;
            } else {
                // UTF-8 → codepoint → \uXXXX
                const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                if (i + cp_len <= text.len) {
                    const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
                        try self.writeByte(b);
                        i += 1;
                        continue;
                    };
                    if (cp <= 0xFFFF) {
                        var hex_buf: [6]u8 = undefined;
                        _ = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{cp}) catch unreachable;
                        try self.buf.appendSlice(self.allocator, &hex_buf);
                    } else {
                        // 서로게이트 페어
                        const adjusted = cp - 0x10000;
                        const high: u16 = @intCast((adjusted >> 10) + 0xD800);
                        const low: u16 = @intCast((adjusted & 0x3FF) + 0xDC00);
                        var hex_buf: [12]u8 = undefined;
                        _ = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}\\u{x:0>4}", .{ high, low }) catch unreachable;
                        try self.buf.appendSlice(self.allocator, &hex_buf);
                    }
                    // 줄/열 추적
                    if (cp <= 0xFFFF) {
                        self.gen_col += 6;
                    } else {
                        self.gen_col += 12;
                    }
                    i += cp_len;
                } else {
                    try self.writeByte(b);
                    i += 1;
                }
            }
        }
    }

    /// 노드의 소스 텍스트를 출력.
    fn writeNodeSpan(self: *Codegen, node: Node) !void {
        try self.writeSpan(node.span);
    }

    /// 문자열 리터럴 출력. quote_style에 따라 따옴표를 변환하고
    /// 내부 이스케이프를 재조정한다 (\' ↔ \").
    fn writeStringLiteral(self: *Codegen, span: Span) !void {
        const text = self.ast.getText(span);
        if (text.len < 2) {
            try self.write(text);
            return;
        }

        const src_quote = text[0];
        const target_quote: u8 = switch (self.options.quote_style) {
            .double => '"',
            .single => '\'',
            .preserve => src_quote,
        };

        // 따옴표가 같으면 writeSpan에 위임 (ascii_only 포함)
        if (src_quote == target_quote) {
            try self.writeSpan(span);
            return;
        }

        // 따옴표 변환: batch write로 연속 구간을 한 번에 출력
        try self.writeByte(target_quote);
        const content = text[1 .. text.len - 1];
        var flush_start: usize = 0;
        var i: usize = 0;
        while (i < content.len) {
            const c = content[i];
            if (c == '\\' and i + 1 < content.len) {
                if (content[i + 1] == src_quote) {
                    // \' → ' (double 변환 시): 원본 따옴표 이스케이프 제거
                    try self.write(content[flush_start..i]);
                    try self.writeByte(src_quote);
                    i += 2;
                    flush_start = i;
                } else if (content[i + 1] == target_quote) {
                    // \" 이미 이스케이프됨 → 그대로 유지
                    i += 2;
                } else {
                    // 다른 이스케이프 시퀀스 → 통째로 유지
                    i += 2;
                }
            } else if (c == target_quote) {
                // target 따옴표가 내용에 있으면 이스케이프 추가
                try self.write(content[flush_start..i]);
                try self.writeByte('\\');
                try self.writeByte(c);
                i += 1;
                flush_start = i;
            } else if (c >= 0x80 and self.options.ascii_only) {
                try self.write(content[flush_start..i]);
                const cp_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const end = @min(i + cp_len, content.len);
                try self.writeAsciiOnly(content[i..end]);
                i = end;
                flush_start = i;
            } else {
                i += 1;
            }
        }
        // 남은 구간 flush
        try self.write(content[flush_start..content.len]);
        try self.writeByte(target_quote);
    }

    // ================================================================
    // 주석 출력
    // ================================================================

    /// 주석 출력. pos가 null이면 남은 모든 주석 출력 (trailing).
    /// minify 모드에서는 legal comment (@license, @preserve, /*!)만 보존 (D022).
    fn emitComments(self: *Codegen, pos: ?u32) !void {
        while (self.next_comment_idx < self.comments.len) {
            const comment = self.comments[self.next_comment_idx];
            if (pos) |p| {
                if (comment.start > p) break;
            }
            // minify 모드: legal comment만 출력
            if (self.options.minify_whitespace and !comment.is_legal) {
                self.next_comment_idx += 1;
                continue;
            }
            // 주석은 lexer가 직접 수집한 원문 span — 합성 노드 아님 (#1407 safe).
            try self.write(self.ast.source[comment.start..comment.end]);
            try self.writeNewline();
            // writeNewline 이 indent 를 먹으므로 후속 content 위해 복원 (#1508).
            try self.writeIndent();
            self.next_comment_idx += 1;
        }
    }

    // ================================================================
    // 노드 출력
    // ================================================================

    pub const Error = std.mem.Allocator.Error;

    fn emitNode(self: *Codegen, idx: NodeIndex) Error!void {
        if (idx.isNone()) return;

        // 번들 모드: skip_nodes에 있으면 출력하지 않음 (import/export 제거)
        if (self.options.linking_metadata) |meta| {
            const node_idx = @intFromEnum(idx);
            if (node_idx < meta.skip_nodes.capacity() and meta.skip_nodes.isSet(node_idx)) return;
        }

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
            .directive => try self.writeNodeSpan(node),
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
    // Statement 출력
    // ================================================================

    fn emitProgram(self: *Codegen, node: Node) !void {
        const list = node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        var emitted = false;
        for (indices) |raw_idx| {
            const node_idx: NodeIndex = @enumFromInt(raw_idx);
            if (node_idx.isNone()) continue;
            if (emitted) try self.writeNewline();
            try self.emitNode(node_idx);
            emitted = true;
        }
        if (emitted) try self.writeNewline();
        // 파일 끝에 남은 주석들 출력
        try self.emitComments(null);
    }

    fn emitBlock(self: *Codegen, node: Node) !void {
        try self.emitBracedList(node);
    }

    /// { item1 item2 ... } — 블록과 클래스 바디 공통.
    /// `{` 앞 공백: 마지막 바이트가 공백/줄바꿈이 아니면 자동 추가 (이중 공백 방지).
    fn emitBracedList(self: *Codegen, node: Node) !void {
        if (!self.options.minify_whitespace and self.buf.items.len > 0) {
            const last = self.buf.items[self.buf.items.len - 1];
            if (last != ' ' and last != '\n' and last != '\t') {
                try self.writeByte(' ');
            }
        }
        try self.writeByte('{');
        const list = node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        if (indices.len > 0) {
            self.indent_level += 1;
            for (indices) |raw_idx| {
                try self.writeNewline();
                try self.writeIndent();
                try self.emitNode(@enumFromInt(raw_idx));
            }
            self.indent_level -= 1;
        }
        try self.writeNewline();
        try self.writeIndent();
        try self.writeByte('}');
    }

    fn emitExpressionStatement(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(';');
    }

    fn emitReturn(self: *Codegen, node: Node) !void {
        try self.write("return");
        if (!node.data.unary.operand.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(node.data.unary.operand);
        }
        try self.writeByte(';');
    }

    fn emitThrow(self: *Codegen, node: Node) !void {
        try self.write("throw ");
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(';');
    }

    fn emitIf(self: *Codegen, node: Node) !void {
        const t = node.data.ternary;
        // 상수 조건 DCE: if (false) → else만 출력, if (true) → then만 출력
        if (self.options.linking_metadata != null) {
            if (self.evalBooleanCondition(t.a)) |known| {
                if (!known) {
                    // if (false) { ... } else { alt } → alt만 출력
                    if (!t.c.isNone()) {
                        try self.emitNode(t.c);
                    }
                    return;
                } else {
                    // if (true) { ... } → then만 출력
                    try self.emitNode(t.b);
                    return;
                }
            }
        }
        if (self.options.minify_whitespace) try self.write("if(") else try self.write("if (");
        try self.emitNode(t.a);
        try self.writeByte(')');
        try self.emitNode(t.b);
        if (!t.c.isNone()) {
            // else 분기가 DCE로 완전히 제거되는 if문이면 else 키워드 자체를 생략
            if (self.isDeadIfNode(t.c)) return;
            if (self.options.minify_whitespace) {
                const next_node = self.ast.getNode(t.c);
                if (next_node.tag == .block_statement) {
                    try self.write("else");
                } else {
                    try self.write("else ");
                }
            } else {
                try self.write(" else ");
            }
            try self.emitNode(t.c);
        }
    }

    /// else 분기의 if_statement가 상수 조건 DCE로 아무것도 출력하지 않는지 재귀 확인.
    /// `else if (false) { ... }` → dead, `else if (false) { ... } else if (false) { ... }` → dead
    fn isDeadIfNode(self: *Codegen, node_idx: NodeIndex) bool {
        return self.isDeadIfNodeDepth(node_idx, 0);
    }

    fn isDeadIfNodeDepth(self: *Codegen, node_idx: NodeIndex, depth: u32) bool {
        if (depth >= 128) return false;
        if (self.options.linking_metadata == null) return false;
        if (node_idx.isNone() or @intFromEnum(node_idx) >= self.ast.nodes.items.len) return false;
        const n = self.ast.getNode(node_idx);
        if (n.tag != .if_statement) return false;
        const t = n.data.ternary;
        const known = self.evalBooleanCondition(t.a) orelse return false;
        if (known) return false;
        if (t.c.isNone()) return true;
        return self.isDeadIfNodeDepth(t.c, depth + 1);
    }

    /// 조건 노드가 컴파일 타임 boolean으로 확정되면 값을 반환한다.
    fn evalBooleanCondition(self: *Codegen, cond_idx: NodeIndex) ?bool {
        return self.evalBooleanConditionDepth(cond_idx, 0);
    }

    fn evalBooleanConditionDepth(self: *Codegen, cond_idx: NodeIndex, depth: u8) ?bool {
        if (depth >= 8) return null;
        if (cond_idx.isNone() or @intFromEnum(cond_idx) >= self.ast.nodes.items.len) return null;
        const cond = self.ast.getNode(cond_idx);
        return switch (cond.tag) {
            .boolean_literal => {
                const text = self.ast.getText(cond.span);
                return std.mem.eql(u8, text, "true");
            },
            .identifier_reference => {
                const meta = self.options.linking_metadata orelse return null;
                const sym_id = self.resolveSymbolId(cond_idx, meta) orelse return null;
                const cv = meta.const_values.get(sym_id) orelse return null;
                return switch (cv.kind) {
                    .true_ => true,
                    .false_ => false,
                    else => null,
                };
            },
            .null_literal => false,
            .numeric_literal => {
                const text = self.ast.getText(cond.span);
                const n = std.fmt.parseFloat(f64, text) catch return null;
                return n != 0;
            },
            .logical_expression => {
                const left = self.evalBooleanConditionDepth(cond.data.binary.left, depth + 1) orelse return null;
                const log_op: Kind = @enumFromInt(cond.data.binary.flags);
                if (log_op == .amp2 and !left) return false;
                if (log_op == .pipe2 and left) return true;
                return null;
            },
            .unary_expression => {
                // unary_expression은 extra 저장: extra_data[e] = operand, extra_data[e+1] = operator
                const e = cond.data.extra;
                const extras = self.ast.extra_data.items;
                if (e + 1 >= extras.len) return null;
                const operand_idx: NodeIndex = @enumFromInt(extras[e]);
                const op: Kind = @enumFromInt(@as(u8, @truncate(extras[e + 1])));
                if (op == .bang) {
                    if (self.evalBooleanConditionDepth(operand_idx, depth + 1)) |v| return !v;
                }
                return null;
            },
            else => null,
        };
    }

    fn emitWhile(self: *Codegen, node: Node) !void {
        if (self.options.minify_whitespace) try self.write("while(") else try self.write("while (");
        try self.emitNode(node.data.binary.left);
        try self.writeByte(')');
        try self.emitNode(node.data.binary.right);
    }

    fn emitDoWhile(self: *Codegen, node: Node) !void {
        try self.write("do");
        // block body는 emitBracedList가 { 앞 공백 관리, non-block은 공백 필수 (dox++ 방지)
        if (node.data.binary.right.isNone() or self.ast.getNode(node.data.binary.right).tag != .block_statement) {
            try self.writeByte(' ');
        }
        try self.emitNode(node.data.binary.right);
        if (self.options.minify_whitespace) try self.write("while(") else try self.write(" while (");
        try self.emitNode(node.data.binary.left);
        try self.write(");");
    }

    fn emitFor(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 4];
        if (self.options.minify_whitespace) try self.write("for(") else try self.write("for (");
        // in_for_init을 save/restore로 관리: init 안에 중첩된 for/for-in/for-of가 있으면
        // 내부 for가 끝날 때 plain assignment로 되돌리지 않도록 해야 한다. (#1564 Case 1)
        const saved_for_init = self.in_for_init;
        self.in_for_init = true;
        try self.emitNode(@enumFromInt(extras[0]));
        if (self.options.minify_whitespace) try self.writeByte(';') else try self.write("; ");
        self.in_for_init = saved_for_init;
        try self.emitNode(@enumFromInt(extras[1]));
        if (self.options.minify_whitespace) try self.writeByte(';') else try self.write("; ");
        try self.emitNode(@enumFromInt(extras[2]));
        try self.writeByte(')');
        try self.emitNode(@enumFromInt(extras[3]));
    }

    fn emitForAwaitOf(self: *Codegen, node: Node) !void {
        const t = node.data.ternary;
        // for-in/of 와 동일한 var initializer hoist/skip 처리.
        // ES2015 block-scoping 다운레벨이 `const/let x` → `var x = void 0` 로 바꾼
        // 경우 for-await 헤드에 `var x = void 0 of ...` 가 그대로 출력되면 문법 오류.
        if (try self.tryHoistForInVarInit(t.a)) {
            try self.writeNewline();
            try self.writeIndent();
        }
        if (self.options.minify_whitespace) try self.write("for await(") else try self.write("for await (");
        const saved_for_init = self.in_for_init;
        const saved_skip_var_init = self.skip_var_init;
        self.in_for_init = true;
        self.skip_var_init = try self.shouldSkipVarInit(t.a);
        try self.emitNode(t.a);
        self.in_for_init = saved_for_init;
        self.skip_var_init = saved_skip_var_init;
        try self.write(" of ");
        try self.emitNode(t.b);
        try self.writeByte(')');
        try self.emitNode(t.c);
    }

    fn emitForInOf(self: *Codegen, node: Node, keyword: []const u8) !void {
        const t = node.data.ternary;

        // for-in var initializer hoisting (esbuild 호환):
        // `for (var x = expr in y)` → `x = expr;\nfor (var x in y)`
        // TS에서 `for (var x = Array<number> in y)` 같은 패턴에서 타입 인자가
        // 스트리핑되어 initializer가 남을 수 있다. 이를 별도 문장으로 hoisting.
        if (try self.tryHoistForInVarInit(t.a)) {
            try self.writeNewline();
            try self.writeIndent();
        }

        if (self.options.minify_whitespace) try self.write("for(") else try self.write("for (");
        const saved_for_init = self.in_for_init;
        const saved_skip_var_init = self.skip_var_init;
        self.in_for_init = true;
        self.skip_var_init = try self.shouldSkipVarInit(t.a);
        try self.emitNode(t.a);
        self.in_for_init = saved_for_init;
        self.skip_var_init = saved_skip_var_init;
        try self.writeByte(' ');
        try self.write(keyword);
        try self.writeByte(' ');
        try self.emitNode(t.b);
        try self.writeByte(')');
        try self.emitNode(t.c);
    }

    /// for-in var initializer가 있으면 `name = init;`를 hoisting 출력.
    /// 출력했으면 true, 아니면 false.
    fn tryHoistForInVarInit(self: *Codegen, left: NodeIndex) !bool {
        if (left.isNone()) return false;
        const left_node = self.ast.getNode(left);
        if (left_node.tag != .variable_declaration) return false;

        const extras = self.ast.extra_data.items;
        const e = left_node.data.extra;
        const list_start = extras[e + 1];
        const list_len = extras[e + 2];
        if (list_len == 0) return false;

        const first_decl: NodeIndex = @enumFromInt(extras[list_start]);
        if (first_decl.isNone()) return false;
        const decl_node = self.ast.getNode(first_decl);
        if (decl_node.tag != .variable_declarator) return false;

        const name: NodeIndex = @enumFromInt(extras[decl_node.data.extra]);
        const init_val: NodeIndex = @enumFromInt(extras[decl_node.data.extra + 2]);
        if (init_val.isNone()) return false;

        // name = init;
        try self.emitNode(name);
        try self.writeSpace();
        try self.writeByte('=');
        try self.writeSpace();
        try self.emitNode(init_val);
        try self.writeByte(';');
        return true;
    }

    /// for-in left가 initializer를 가진 var declaration인지 확인.
    /// hoisting된 경우 emitVariableDeclarator에서 init를 스킵하기 위함.
    fn shouldSkipVarInit(self: *Codegen, left: NodeIndex) !bool {
        if (left.isNone()) return false;
        const left_node = self.ast.getNode(left);
        if (left_node.tag != .variable_declaration) return false;

        const extras = self.ast.extra_data.items;
        const e = left_node.data.extra;
        const list_start = extras[e + 1];
        const list_len = extras[e + 2];
        if (list_len == 0) return false;

        const first_decl: NodeIndex = @enumFromInt(extras[list_start]);
        if (first_decl.isNone()) return false;
        const decl_node = self.ast.getNode(first_decl);
        if (decl_node.tag != .variable_declarator) return false;

        const init_val: NodeIndex = @enumFromInt(extras[decl_node.data.extra + 2]);
        return !init_val.isNone();
    }

    fn emitSwitch(self: *Codegen, node: Node) !void {
        // 파서 구조: extra = [discriminant, cases_start, cases_len]
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const discriminant: NodeIndex = @enumFromInt(extras[0]);
        const cases_start = extras[1];
        const cases_len = extras[2];

        if (self.options.minify_whitespace) try self.write("switch(") else try self.write("switch (");
        try self.emitNode(discriminant);
        try self.writeByte(')');
        try self.writeSpace();
        try self.writeByte('{');
        if (cases_len > 0) {
            self.indent_level += 1;
            const case_indices = self.ast.extra_data.items[cases_start .. cases_start + cases_len];
            for (case_indices) |raw_idx| {
                try self.writeNewline();
                try self.writeIndent();
                try self.emitNode(@enumFromInt(raw_idx));
            }
            self.indent_level -= 1;
            try self.writeNewline();
            try self.writeIndent();
        }
        try self.writeByte('}');
    }

    fn emitSwitchCase(self: *Codegen, node: Node) !void {
        // 파서 구조: extra = [test_expr, stmts_start, stmts_len]
        // test_expr가 none이면 default:
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const test_expr: NodeIndex = @enumFromInt(extras[0]);
        const stmts_start = extras[1];
        const stmts_len = extras[2];

        if (test_expr.isNone()) {
            try self.write("default:");
        } else {
            try self.write("case ");
            try self.emitNode(test_expr);
            try self.writeByte(':');
        }

        if (stmts_len > 0) {
            self.indent_level += 1;
            const stmt_indices = self.ast.extra_data.items[stmts_start .. stmts_start + stmts_len];
            for (stmt_indices) |raw_idx| {
                try self.writeNewline();
                try self.writeIndent();
                try self.emitNode(@enumFromInt(raw_idx));
            }
            self.indent_level -= 1;
        }
    }

    fn emitSimpleStmt(self: *Codegen, node: Node, keyword: []const u8) !void {
        try self.write(keyword);
        // label이 있으면 출력
        if (!node.data.unary.operand.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(node.data.unary.operand);
        }
        try self.writeByte(';');
    }

    fn emitTry(self: *Codegen, node: Node) !void {
        const t = node.data.ternary;
        try self.write("try");
        try self.writeSpace();
        try self.emitNode(t.a); // block
        if (!t.b.isNone()) {
            try self.writeSpace();
            try self.emitNode(t.b); // catch
        }
        if (!t.c.isNone()) {
            try self.writeSpace();
            try self.write("finally");
            try self.writeSpace();
            try self.emitNode(t.c);
        }
    }

    fn emitCatch(self: *Codegen, node: Node) !void {
        try self.write("catch");
        if (!node.data.binary.left.isNone()) {
            if (self.options.minify_whitespace) try self.writeByte('(') else try self.write(" (");
            try self.emitNode(node.data.binary.left);
            try self.writeByte(')');
        }
        try self.emitNode(node.data.binary.right);
    }

    fn emitLabeled(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeByte(':');
        try self.emitNode(node.data.binary.right);
    }

    fn emitWith(self: *Codegen, node: Node) !void {
        try self.write("with(");
        try self.emitNode(node.data.binary.left);
        try self.writeByte(')');
        try self.emitNode(node.data.binary.right);
    }

    // ================================================================
    // Expression 출력
    // ================================================================

    fn emitUnary(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 1 >= extras.len) return;
        const operand: NodeIndex = @enumFromInt(extras[e]);
        const op: Kind = @enumFromInt(@as(u8, @truncate(extras[e + 1])));
        // !false → true, !true → false
        if (op == .bang and self.options.linking_metadata != null) {
            if (self.evalBooleanCondition(operand)) |v| {
                try self.write(if (!v) "true" else "false");
                return;
            }
        }
        try self.write(op.symbol());
        if (op == .kw_typeof or op == .kw_void or op == .kw_delete) try self.writeByte(' ');
        try self.emitNode(operand);
    }

    fn emitUpdate(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 1 >= extras.len) return;
        const operand: NodeIndex = @enumFromInt(extras[e]);
        const flags = extras[e + 1];
        const is_postfix = (flags & ast_mod.UnaryFlags.postfix) != 0;
        const op: Kind = @enumFromInt(@as(u8, @truncate(flags)));
        if (!is_postfix) try self.write(op.symbol());
        try self.emitNode(operand);
        if (is_postfix) try self.write(op.symbol());
    }

    fn emitBinary(self: *Codegen, node: Node) !void {
        const op: Kind = @enumFromInt(node.data.binary.flags);
        // false && ... → false, true || ... → true (short-circuit 폴딩)
        if (self.options.linking_metadata != null and node.tag == .logical_expression) {
            if (self.evalBooleanCondition(node.data.binary.left)) |left_val| {
                if ((op == .amp2 and !left_val) or
                    (op == .pipe2 and left_val))
                {
                    try self.write(if (left_val) "true" else "false");
                    return;
                }
                // true && expr → expr, false || expr → expr
                try self.emitNode(node.data.binary.right);
                return;
            }
        }
        try self.emitNode(node.data.binary.left);
        // 키워드 연산자(in, instanceof)와 +/- 는 minify에서도 공백 필수
        // in/instanceof: 공백 없으면 식별자와 붙음 (xinstanceofy)
        // +/-: 공백 없으면 ++/-- 와 혼동 (a+ +b → a++b)
        if (op == .kw_in or op == .kw_instanceof or op == .plus or op == .minus) {
            try self.writeByte(' ');
        } else {
            try self.writeSpace();
        }
        try self.write(op.symbol());
        if (op == .kw_in or op == .kw_instanceof or op == .plus or op == .minus) {
            try self.writeByte(' ');
        } else {
            try self.writeSpace();
        }
        try self.emitNode(node.data.binary.right);
    }

    fn emitAssignment(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeSpace();
        if (node.data.binary.flags != 0) {
            const op: Kind = @enumFromInt(node.data.binary.flags);
            try self.write(op.symbol());
        } else {
            try self.writeByte('=');
        }
        try self.writeSpace();
        const right = node.data.binary.right;
        // contextual name: 단순 할당(=)이고 오른쪽이 function-like → left leaf 이름 사용.
        // flags == 0: 트랜스포머 합성 = 노드, flags == Kind.eq: 파서 생성 = 노드.
        const is_simple_assign = node.data.binary.flags == 0 or
            @as(Kind, @enumFromInt(node.data.binary.flags)) == .eq;
        if (self.fn_map_builder != null and is_simple_assign and self.isFunctionLike(right)) {
            const saved = self.pending_fn_name;
            self.pending_fn_name = self.resolveMemberLeafName(node.data.binary.left);
            try self.emitNode(right);
            self.pending_fn_name = saved;
        } else {
            try self.emitNode(right);
        }
    }

    fn emitConditional(self: *Codegen, node: Node) !void {
        const t = node.data.ternary;
        // false ? x : y → y, true ? x : y → x
        if (self.options.linking_metadata != null) {
            if (self.evalBooleanCondition(t.a)) |cond| {
                try self.emitNode(if (cond) t.b else t.c);
                return;
            }
        }
        try self.emitNode(t.a);
        try self.writeSpace();
        try self.writeByte('?');
        try self.writeSpace();
        try self.emitNode(t.b);
        try self.writeSpace();
        try self.writeByte(':');
        try self.writeSpace();
        try self.emitNode(t.c);
    }

    fn emitSequence(self: *Codegen, node: Node) !void {
        try self.emitList(node, ",");
    }

    fn emitParen(self: *Codegen, node: Node) !void {
        try self.writeByte('(');
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(')');
    }

    fn emitSpread(self: *Codegen, node: Node) !void {
        try self.write("...");
        try self.emitNode(node.data.unary.operand);
    }

    fn emitAwait(self: *Codegen, node: Node) !void {
        try self.write("await ");
        try self.emitNode(node.data.unary.operand);
    }

    fn emitYield(self: *Codegen, node: Node) !void {
        try self.write("yield");
        if (node.data.unary.flags & 1 != 0) try self.writeByte('*');
        if (!node.data.unary.operand.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(node.data.unary.operand);
        }
    }

    fn emitArray(self: *Codegen, node: Node) !void {
        try self.writeByte('[');
        try self.emitList(node, self.listSep());
        try self.writeByte(']');
    }

    fn emitObject(self: *Codegen, node: Node) !void {
        const list = node.data.list;
        if (list.len == 0) {
            try self.write("{}");
            return;
        }
        if (self.options.minify_whitespace) {
            try self.writeByte('{');
            try self.emitList(node, ",");
            try self.writeByte('}');
        } else {
            try self.write("{ ");
            try self.emitList(node, ", ");
            try self.write(" }");
        }
    }

    /// object_property: binary = { left=key, right=value, flags }
    fn emitObjectProperty(self: *Codegen, node: Node) !void {
        const key = node.data.binary.left;
        const value = node.data.binary.right;
        if (key.isNone()) return;
        if (value.isNone()) {
            // shorthand: { x } — key만 출력.
            // 단, scope hoisting으로 식별자가 리네임된 경우 shorthand를 풀어야 함:
            // { x } → { x: x$1 }  (프로퍼티 이름은 원본, 값은 리네임된 이름)
            if (self.identifierHasRename(key)) {
                const key_node = self.ast.getNode(key);
                try self.writeSpan(key_node.data.string_ref);
                if (self.options.minify_whitespace) {
                    try self.writeByte(':');
                } else {
                    try self.write(": ");
                }
                try self.emitNode(key);
            } else {
                try self.emitNode(key);
            }
        } else {
            // ES2015 shorthand 확장으로 key가 identifier_reference가 되면
            // scope hoisting rename이 적용되므로 원본 span으로 출력하여 방지.
            const key_node = self.ast.getNode(key);
            if (key_node.tag == .identifier_reference) {
                try self.writeSpan(key_node.data.string_ref);
            } else {
                try self.emitNode(key);
            }
            if (self.options.minify_whitespace) {
                try self.writeByte(':');
            } else {
                try self.write(": ");
            }
            // contextual name: 값이 function-like → key 이름 사용
            if (self.fn_map_builder != null and self.isFunctionLike(value)) {
                const saved = self.pending_fn_name;
                self.pending_fn_name = self.resolveKeyName(key);
                try self.emitNode(value);
                self.pending_fn_name = saved;
            } else {
                try self.emitNode(value);
            }
        }
    }

    /// 식별자 노드가 scope hoisting에 의해 리네임되는지 확인.
    /// linking_metadata.renames 또는 ns_prefix 치환 대상이면 true.
    fn identifierHasRename(self: *Codegen, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        const key_node = self.ast.getNode(idx);
        // linking_metadata renames 확인
        if (self.options.linking_metadata) |meta| {
            if (self.resolveSymbolId(idx, meta)) |sym_id| {
                if (meta.renames.get(sym_id) != null) return true;
            }
        }
        // ns_prefix 치환 확인
        if (self.ns_prefix) |_| {
            if (key_node.tag == .identifier_reference or key_node.tag == .assignment_target_identifier) {
                const name = self.ast.getText(key_node.data.string_ref);
                if (self.ns_exports) |exports| {
                    if (exports.contains(name)) return true;
                }
            }
        }
        return false;
    }

    /// identifier 노드의 symbol_id를 해결.
    /// symbol_ids[node_i]에서 직접 조회 (트랜스포머의 propagateSymbolId로 전파된 값).
    fn resolveSymbolId(_: *Codegen, idx: NodeIndex, meta: *const LinkingMetadata) ?u32 {
        const node_i = @intFromEnum(idx);
        if (node_i < meta.symbol_ids.len) {
            return meta.symbol_ids[node_i];
        }
        return null;
    }

    /// export default X에서 X의 (rename된) 이름이 def_name과 같은지 확인.
    /// 같으면 할당문(def_name = X)이 불필요한 self-reference.
    fn isExportDefaultSelfRef(self: *Codegen, inner: NodeIndex, def_name: []const u8) bool {
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

    /// keepNames: name 노드가 rename되었으면 (original_name, new_name) 쌍을 수집.
    /// emitter가 코드젠 완료 후 __name(newName, "originalName") 호출을 append.
    fn collectKeepNameEntry(self: *Codegen, name_idx: NodeIndex) void {
        const meta = self.options.linking_metadata orelse return;
        const sym_id = self.resolveSymbolId(name_idx, meta) orelse return;
        const new_name = meta.renames.get(sym_id) orelse return;
        const name_node = self.ast.getNode(name_idx);
        const original_name = self.ast.getText(name_node.data.string_ref);
        if (std.mem.eql(u8, new_name, original_name)) return;
        // OOM 시 append 실패 → __name() 미삽입. arena 할당이므로 현실적으로 발생하지 않음.
        self.keep_names_entries.append(self.allocator, .{
            .new_name = new_name,
            .original_name = original_name,
        }) catch return;
    }

    fn emitComputedKey(self: *Codegen, node: Node) !void {
        try self.writeByte('[');
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(']');
    }

    fn emitStaticMember(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        if (!self.ast.hasExtra(e, 2)) return;
        const object = self.ast.readExtraNode(e, 0);
        const property = self.ast.readExtraNode(e, 1);
        const flags = self.ast.readExtra(e, 2);
        const MemberFlags = ast_mod.MemberFlags;

        // namespace member rewrite: ns.prop → canonical_name (esbuild 방식)
        if (self.options.linking_metadata) |meta| {
            if (flags & MemberFlags.optional_chain == 0) { // optional chain은 리라이트 안 함
                const obj_node_i = @intFromEnum(object);
                if (obj_node_i < meta.symbol_ids.len) {
                    if (meta.symbol_ids[obj_node_i]) |obj_sym_id| {
                        if (meta.ns_member_rewrites.get(obj_sym_id)) |inner_map| {
                            const prop_node = self.ast.getNode(property);
                            const prop_text = self.ast.getText(prop_node.data.string_ref);
                            if (inner_map.get(prop_text)) |canonical_name| {
                                // 인라인 객체({...})는 statement 위치에서 block으로
                                // 파싱되므로 괄호로 감싸야 함: ({a: a}).prop
                                if (canonical_name.len > 0 and canonical_name[0] == '{') {
                                    try self.writeByte('(');
                                    try self.write(canonical_name);
                                    try self.writeByte(')');
                                } else {
                                    try self.write(canonical_name);
                                }
                                return;
                            }
                        }
                    }
                }
            }
        }

        // import.meta.* 프로퍼티 감지: hot (HMR) + polyfill (CJS/non-ESM)
        if (self.options.dev_module_id != null or self.options.module_format == .cjs or self.options.replace_import_meta) {
            if (self.resolveImportMetaProp(object, property)) |prop_text| {
                // import.meta.hot → __zts_make_hot("dev_id") (dev mode HMR)
                if (self.options.dev_module_id) |dev_id| {
                    if (std.mem.eql(u8, prop_text, "hot")) {
                        try self.write("__zts_make_hot(\"");
                        try self.write(dev_id);
                        try self.write("\")");
                        return;
                    }
                }
                // import.meta.* polyfill (CJS/non-ESM)
                if (self.options.module_format == .cjs or self.options.replace_import_meta) {
                    if (self.options.platform == .node) {
                        // Node.js CJS polyfill
                        if (std.mem.eql(u8, prop_text, "url")) {
                            try self.write(IMPORT_META_URL_NODE);
                            return;
                        } else if (std.mem.eql(u8, prop_text, "dirname")) {
                            try self.write("__dirname");
                            return;
                        } else if (std.mem.eql(u8, prop_text, "filename")) {
                            try self.write("__filename");
                            return;
                        }
                    } else {
                        // browser/neutral: 빈 문자열
                        if (std.mem.eql(u8, prop_text, "url") or
                            std.mem.eql(u8, prop_text, "dirname") or
                            std.mem.eql(u8, prop_text, "filename"))
                        {
                            try self.write("\"\"");
                            return;
                        }
                    }
                    // 알려지지 않은 프로퍼티 → 기본 import.meta polyfill + .prop
                }
            }
        }

        try self.emitNode(object);
        if (flags & MemberFlags.optional_chain != 0) {
            try self.write("?.");
        } else {
            try self.writeByte('.');
        }
        try self.emitNode(property);
    }

    fn emitComputedMember(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        if (!self.ast.hasExtra(e, 2)) return;
        const object = self.ast.readExtraNode(e, 0);
        const property = self.ast.readExtraNode(e, 1);
        const flags = self.ast.readExtra(e, 2);
        const MemberFlags = ast_mod.MemberFlags;
        try self.emitNode(object);
        if (flags & MemberFlags.optional_chain != 0) {
            try self.write("?.");
        }
        try self.writeByte('[');
        try self.emitNode(property);
        try self.writeByte(']');
    }

    fn emitCall(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        if (!self.ast.hasExtra(e, 3)) return;
        const callee = self.ast.readExtraNode(e, 0);
        const args_start = self.ast.readExtra(e, 1);
        const args_len = self.ast.readExtra(e, 2);
        const flags = self.ast.readExtra(e, 3);
        const CallFlags = ast_mod.CallFlags;
        const is_optional = (flags & CallFlags.optional_chain) != 0;
        const is_pure = (flags & CallFlags.is_pure) != 0;

        // CJS require() 치환: require('specifier') → require_xxx()
        if (try self.tryRewriteRequire(callee, args_start, args_len)) return;

        // import.meta.glob() → 객체 리터럴 직접 출력
        if (try self.tryEmitGlobObject(callee, args_start, args_len)) return;

        if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");
        try self.emitNode(callee);
        if (is_optional) try self.write("?.");
        try self.writeByte('(');
        try self.emitNodeList(args_start, args_len, self.listSep());
        try self.writeByte(')');
    }

    /// import.meta.glob("pattern") 호출을 감지하고 매칭 파일 객체 리터럴을 직접 출력한다.
    /// AST 수준 교체: 문자열 후처리보다 안전 (minify, 문자열 리터럴 내 패턴에 영향 안 받음).
    fn tryEmitGlobObject(self: *Codegen, callee: ast_mod.NodeIndex, args_start: u32, args_len: u32) !bool {
        if (self.options.import_records.len == 0) return false;
        if (callee.isNone() or @intFromEnum(callee) >= self.ast.nodes.items.len) return false;

        // callee: static_member_expression(import.meta.glob)
        const callee_node = self.ast.getNode(callee);
        if (callee_node.tag != .static_member_expression) return false;

        const extras = self.ast.extra_data.items;
        if (callee_node.data.extra + 2 >= extras.len) return false;

        const obj_idx = @as(ast_mod.NodeIndex, @enumFromInt(extras[callee_node.data.extra]));
        const prop_idx = @as(ast_mod.NodeIndex, @enumFromInt(extras[callee_node.data.extra + 1]));
        if (obj_idx.isNone() or prop_idx.isNone()) return false;
        if (@intFromEnum(obj_idx) >= self.ast.nodes.items.len or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) return false;

        const obj_node = self.ast.getNode(obj_idx);
        if (obj_node.tag != .meta_property or obj_node.data.none != 0) return false;

        const prop_node = self.ast.getNode(prop_idx);
        const prop_name = self.ast.getText(prop_node.span);
        if (!std.mem.eql(u8, prop_name, "glob")) return false;

        // 첫 번째 인수에서 패턴 추출
        if (args_len == 0 or args_start >= extras.len) return false;
        const arg0_idx = @as(ast_mod.NodeIndex, @enumFromInt(extras[args_start]));
        if (arg0_idx.isNone() or @intFromEnum(arg0_idx) >= self.ast.nodes.items.len) return false;
        const arg0_node = self.ast.getNode(arg0_idx);
        if (arg0_node.tag != .string_literal) return false;
        const raw = self.ast.getText(arg0_node.span);
        const pattern = Ast.stripStringQuotes(raw);

        // import_records에서 매칭되는 glob 레코드 찾기
        const ImportRecord = @import("../bundler/types.zig").ImportRecord;
        for (self.options.import_records) |rec| {
            if (rec.kind != .glob) continue;
            if (!std.mem.eql(u8, rec.specifier, pattern)) continue;

            // 매칭 → 객체 리터럴 출력
            if (rec.glob_matches) |matches| {
                try self.write("{\n");
                for (matches, 0..) |match_path, i| {
                    if (i > 0) try self.write(",\n");
                    try self.write("  \"");
                    try self.write(match_path);
                    try self.write("\": ");

                    if (rec.glob_eager) {
                        if (rec.glob_import_name) |import_name| {
                            // eager + import: (await import("./a.ts")).setup
                            try self.write("(await import(\"");
                            try self.write(match_path);
                            try self.write("\")).");
                            try self.write(import_name);
                        } else {
                            // eager: await import("./a.ts")
                            try self.write("await import(\"");
                            try self.write(match_path);
                            try self.write("\")");
                        }
                    } else {
                        if (rec.glob_import_name) |import_name| {
                            // lazy + import: () => import("./a.ts").then(m => m.setup)
                            try self.write("() => import(\"");
                            try self.write(match_path);
                            try self.write("\").then(m => m.");
                            try self.write(import_name);
                            try self.write(")");
                        } else {
                            // lazy (default): () => import("./a.ts")
                            try self.write("() => import(\"");
                            try self.write(match_path);
                            try self.write("\")");
                        }
                    }
                }
                try self.write("\n}");
            } else {
                try self.write("{}");
            }
            return true;
        }
        _ = ImportRecord;

        return false;
    }

    /// string_literal 노드에서 specifier를 추출하고 require_rewrites 맵에서 조회.
    /// 매칭되면 변수명 반환, 아니면 null. 출력은 하지 않음.
    fn resolveRequireRewrite(self: *Codegen, source: ast_mod.NodeIndex) ?[]const u8 {
        const meta = self.options.linking_metadata orelse return null;
        if (meta.require_rewrites.count() == 0 or source.isNone()) return null;

        const node = self.ast.getNode(source);
        if (node.tag != .string_literal) return null;

        const raw = self.ast.getText(node.data.string_ref);
        const specifier = Ast.stripStringQuotes(raw);

        return meta.require_rewrites.get(specifier);
    }

    /// rewrite 값을 출력한다. 값이 완전한 표현식('('로 시작)이면 그대로,
    /// 변수명이면 "()"를 붙여 호출한다.
    fn emitRewriteValue(self: *Codegen, req_var: []const u8) !void {
        try self.write(req_var);
        // (init_xxx(), __toCommonJS(...)) 같은 완전한 표현식은 ()를 붙이지 않음
        if (req_var.len == 0 or req_var[0] != '(') {
            try self.write("()");
        }
    }

    /// require_xxx() 또는 (init_xxx(), __toCommonJS(...))를 출력. 성공 시 true.
    fn emitRequireRewriteOrCall(self: *Codegen, source: ast_mod.NodeIndex) !bool {
        if (self.resolveRequireRewrite(source)) |req_var| {
            try self.emitRewriteValue(req_var);
            return true;
        }
        try self.write("require(");
        try self.emitNode(source);
        try self.writeByte(')');
        return false;
    }

    /// CJS require('specifier') → require_xxx() 치환. 성공 시 true.
    fn tryRewriteRequire(self: *Codegen, callee: ast_mod.NodeIndex, args_start: u32, args_len: u32) !bool {
        if (callee.isNone() or args_len != 1) return false;

        const callee_node = self.ast.getNode(callee);
        if (callee_node.tag != .identifier_reference) return false;

        const callee_text = self.ast.getText(callee_node.data.string_ref);
        if (!std.mem.eql(u8, callee_text, "require")) return false;

        if (args_start >= self.ast.extra_data.items.len) return false;
        const arg_idx: ast_mod.NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start]);

        if (self.resolveRequireRewrite(arg_idx)) |req_var| {
            try self.emitRewriteValue(req_var);
            return true;
        }
        return false;
    }

    /// `new MemberExpression Arguments` 문법상 callee 는 MemberExpression 이어야 함.
    /// callee 의 member chain 안에 call_expression 이 있으면 `new A(x)` 가 `new (A)(x)` 로
    /// 잘못 파싱되어 뒤따르는 `()` 가 외부 call 로 붙음 (#1507). 감싸서 Primary 로 승격.
    fn newCalleeNeedsParens(self: *Codegen, idx: NodeIndex) bool {
        var cur = idx;
        while (true) {
            const n = self.ast.getNode(cur);
            switch (n.tag) {
                .call_expression => return true,
                .static_member_expression, .computed_member_expression, .private_field_expression => {
                    cur = self.ast.readExtraNode(n.data.extra, 0);
                },
                else => return false,
            }
        }
    }

    fn emitNew(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        if (!self.ast.hasExtra(e, 3)) return;
        var callee = self.ast.readExtraNode(e, 0);
        const args_start = self.ast.readExtra(e, 1);
        const args_len = self.ast.readExtra(e, 2);
        const flags = self.ast.readExtra(e, 3);
        const CallFlags = ast_mod.CallFlags;
        const is_pure = (flags & CallFlags.is_pure) != 0;

        if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");

        try self.write("new ");
        // 원본의 잉여 parens 제거 (#1586): callee가 `(inner)` 형태이고 inner를
        // 직접 새 callee로 써도 `new MemberExpression` 문법이 깨지지 않으면 벗긴다.
        // newCalleeNeedsParens가 이미 call-chain 안전성을 판정하므로 재사용.
        if (self.options.minify_syntax) {
            while (true) {
                const cn = self.ast.getNode(callee);
                if (cn.tag != .parenthesized_expression) break;
                const inner = cn.data.unary.operand;
                if (self.newCalleeNeedsParens(inner)) break;
                callee = inner;
            }
        }
        const needs_parens = self.newCalleeNeedsParens(callee);
        if (needs_parens) try self.writeByte('(');
        try self.emitNode(callee);
        if (needs_parens) try self.writeByte(')');
        try self.writeByte('(');
        try self.emitNodeList(args_start, args_len, self.listSep());
        try self.writeByte(')');
    }

    /// template literal을 child node 단위로 emit.
    /// rename/mangling이 적용되려면 expression을 개별 emitNode로 처리해야 한다.
    fn emitTemplateLiteral(self: *Codegen, node: Node) !void {
        // substitution 없는 단순 template은 data.none=0 (list가 아님).
        // extern union이므로 list.start로 읽으면 none 값과 동일 — 0이면 raw span.
        if (node.data.none == 0) {
            try self.writeNodeSpan(node);
            return;
        }
        const items = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
        for (items) |item_idx| {
            const child: NodeIndex = @enumFromInt(item_idx);
            const child_node = self.ast.nodes.items[@intFromEnum(child)];
            if (child_node.tag == .template_element) {
                try self.writeNodeSpan(child_node);
            } else {
                try self.emitNode(child);
            }
        }
    }

    fn emitTaggedTemplate(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 1 >= extras.len) return;
        try self.emitNode(@enumFromInt(extras[e]));
        try self.emitNode(@enumFromInt(extras[e + 1]));
    }

    /// import.meta → 플랫폼별 polyfill.
    /// - ESM 출력: 그대로 유지
    /// - CJS/번들 non-ESM + node: {url:require("url").pathToFileURL(__filename).href,dirname:__dirname,filename:__filename}
    /// - CJS/번들 non-ESM + browser/neutral: {}
    /// Node.js는 import.meta를 보면 ESM으로 재파싱하므로 제거 필요
    /// import.meta.X 접근인지 확인하고 프로퍼티 이름을 반환. 아니면 null.
    fn resolveImportMetaProp(self: *const Codegen, object: NodeIndex, property: NodeIndex) ?[]const u8 {
        const obj_node = self.ast.getNode(object);
        if (obj_node.tag != .meta_property) return null;
        const obj_text = self.ast.getText(obj_node.span);
        if (!std.mem.eql(u8, obj_text, "import.meta")) return null;
        const prop_node = self.ast.getNode(property);
        return self.ast.getText(prop_node.data.string_ref);
    }

    fn emitMetaProperty(self: *Codegen, node: Node) !void {
        const text = self.ast.getText(node.span);
        if (std.mem.eql(u8, text, "import.meta")) {
            if (self.options.module_format == .cjs or self.options.replace_import_meta) {
                if (self.options.platform == .node) {
                    try self.write(IMPORT_META_NODE_OBJECT);
                } else {
                    try self.write("{}");
                }
                return;
            }
        }
        try self.writeNodeSpan(node);
    }

    fn emitImportExpr(self: *Codegen, node: Node) !void {
        try self.write("import(");
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(')');
    }

    // ================================================================
    // Function / Class 출력
    // ================================================================

    fn emitFunction(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        // function_expression은 ret_type 없이 4 slots, function_declaration/function은 5 slots.
        // 공통 [name(0), params(1), body(2), flags(3)]만 읽는다.
        const extras = self.ast.extra_data.items[e .. e + 4];
        const name: NodeIndex = @enumFromInt(extras[0]);
        const params_list = self.ast.functionParamsList(node);
        const params_start = params_list.start;
        const params_len = params_list.len;
        const body: NodeIndex = @enumFromInt(extras[2]);
        const flags = extras[3];

        // function map: contextual name 소비 후 진입
        const saved_pending = self.pending_fn_name;
        self.pending_fn_name = null;
        if (self.fn_map_builder != null) {
            const fn_name: []const u8 = if (!name.isNone())
                self.ast.getText(self.ast.getNode(name).data.string_ref)
            else
                saved_pending orelse "<anonymous>";
            try self.fnMapEnter(fn_name);
        }
        defer if (self.fn_map_builder != null) {
            self.fnMapExit() catch {}; // defer는 오류 전파 불가 — OOM 시 상위 emit이 이미 실패했으므로 무시
        };

        // strict execution order: function declaration → 할당식으로 변환.
        // `function foo() {...}` → `foo = function() {...};`
        // var foo; 선언은 esm_wrap에서 hoisted_var_names로 이미 top-level에 배치됨.
        const convert_fn_to_assign = self.options.esm_var_assign_only and
            node.tag == .function_declaration and !name.isNone() and
            self.indent_level == 0;

        if (convert_fn_to_assign) {
            try self.emitNode(name);
            try self.write(" = ");
        }

        if (flags & ast_mod.FunctionFlags.is_async != 0) try self.write("async ");
        try self.write("function");
        if (flags & ast_mod.FunctionFlags.is_generator != 0) try self.writeByte('*');
        if (!name.isNone() and !convert_fn_to_assign) {
            try self.writeByte(' ');
            try self.emitNode(name);
        }
        try self.writeByte('(');
        try self.emitNodeList(params_start, params_len, ",");
        try self.writeByte(')');
        try self.emitNode(body);

        // keepNames: function_declaration에서 이름이 rename된 경우 entry 수집
        if (self.options.keep_names and node.tag == .function_declaration and !name.isNone()) {
            self.collectKeepNameEntry(name);
        }
    }

    /// arrow_function_expression: extra = [params, body, flags]
    fn emitArrow(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 2 >= extras.len) return;
        const params: NodeIndex = @enumFromInt(extras[e]);
        const body: NodeIndex = @enumFromInt(extras[e + 1]);
        const flags = extras[e + 2];

        // function map: 화살표 함수는 항상 익명 — contextual name 사용
        const saved_pending = self.pending_fn_name;
        self.pending_fn_name = null;
        if (self.fn_map_builder != null) {
            try self.fnMapEnter(saved_pending orelse "<anonymous>");
        }
        defer if (self.fn_map_builder != null) {
            self.fnMapExit() catch {}; // defer는 오류 전파 불가 — OOM 시 상위 emit이 이미 실패했으므로 무시
        };

        if (flags & ast_mod.ArrowFlags.is_async != 0) try self.write("async ");

        // params 출력 — #1283 이후 항상 formal_parameters 노드. 괄호는 codegen이 부착.
        if (!params.isNone()) {
            try self.writeByte('(');
            try self.emitNode(params);
            try self.writeByte(')');
        } else {
            try self.write("()");
        }
        try self.writeSpace();
        try self.write("=>");
        // block body는 emitBlock이 { 앞 공백을 관리, non-block은 여기서 추가
        if (body.isNone() or self.ast.getNode(body).tag != .block_statement) {
            try self.writeSpace();
        }
        try self.emitNode(body);
    }

    /// class: extra = [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len]
    fn emitClass(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const name: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
        const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
        const deco_start = self.ast.extra_data.items[e + 6];
        const deco_len = self.ast.extra_data.items[e + 7];

        // function map: class도 frame (Metro는 Class를 Function처럼 처리)
        const saved_pending = self.pending_fn_name;
        self.pending_fn_name = null;
        if (self.fn_map_builder != null) {
            const class_name: []const u8 = if (!name.isNone())
                self.ast.getText(self.ast.getNode(name).data.string_ref)
            else
                saved_pending orelse "<anonymous>";
            try self.fnMapEnter(class_name);
        }
        defer if (self.fn_map_builder != null) {
            self.fnMapExit() catch {}; // defer는 오류 전파 불가 — OOM 시 상위 emit이 이미 실패했으므로 무시
        };

        // class는 block-scoped → __esm 콜백 밖 __export getter가 접근 불가.
        // variable_declaration과 동일하게 할당문으로 변환. (emitter가 var 선언을 밖에 배치)
        const convert_to_assign = self.options.esm_var_assign_only and
            node.tag == .class_declaration and
            !name.isNone() and
            self.indent_level == 0;

        if (convert_to_assign) {
            try self.emitNode(name);
            try self.write(" = ");
        }

        // decorator 출력: @log @validate class Foo {} (esbuild 호환: 공백 구분)
        if (deco_len > 0) {
            const deco_indices = self.ast.extra_data.items[deco_start .. deco_start + deco_len];
            for (deco_indices) |raw_idx| {
                try self.emitNode(@enumFromInt(raw_idx));
                try self.writeByte(' ');
            }
        }

        try self.write("class");
        if (!name.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(name);
        }
        if (!super_class.isNone()) {
            try self.write(" extends ");
            try self.emitNode(super_class);
        }
        try self.emitNode(body);

        if (convert_to_assign) {
            try self.writeByte(';');
        }

        // keepNames: class_declaration에서 이름이 rename된 경우 entry 수집
        if (self.options.keep_names and node.tag == .class_declaration and !name.isNone()) {
            self.collectKeepNameEntry(name);
        }
    }

    fn emitClassBody(self: *Codegen, node: Node) !void {
        try self.emitBracedList(node);
    }

    // static_block: unary = { operand = body(block_statement) }
    // 파서 노드는 writeNodeSpan으로 처리하지만,
    // transformer가 생성한 합성 노드(span={0,0})는 AST 기반으로 출력한다.
    fn emitStaticBlock(self: *Codegen, node: Node) !void {
        if (node.span.start != 0 or node.span.end != 0) {
            // 파서 원본 노드 → 소스 텍스트 그대로 출력
            try self.writeNodeSpan(node);
            return;
        }
        // 합성 노드 → AST 기반 출력
        try self.write("static");
        try self.writeSpace();
        try self.emitNode(node.data.unary.operand);
    }

    fn emitMethodDef(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 6];
        const key: NodeIndex = @enumFromInt(extras[ast_mod.MethodExtra.key]);
        const params_list = self.ast.functionParamsList(node);
        const params_start = params_list.start;
        const params_len = params_list.len;
        const body: NodeIndex = @enumFromInt(extras[ast_mod.MethodExtra.body]);
        const flags = extras[ast_mod.MethodExtra.flags];
        const deco_start = extras[ast_mod.MethodExtra.deco_start];
        const deco_len = extras[ast_mod.MethodExtra.deco_len];

        // function map: ClassName#method / ClassName.method / get__name / set__name
        if (self.fn_map_builder != null) {
            const method_name = try self.resolveMethodName(key, flags);
            try self.fnMapEnter(method_name);
        }
        defer if (self.fn_map_builder != null) {
            self.fnMapExit() catch {}; // defer는 오류 전파 불가 — OOM 시 상위 emit이 이미 실패했으므로 무시
        };

        try self.emitMemberDecorators(deco_start, deco_len);

        if (flags & ast_mod.MethodFlags.is_static != 0) try self.write("static ");
        if (flags & ast_mod.MethodFlags.is_async != 0) try self.write("async ");
        if (flags & ast_mod.MethodFlags.is_getter != 0) {
            try self.write("get ");
        } else if (flags & ast_mod.MethodFlags.is_setter != 0) {
            try self.write("set ");
        }
        if (flags & ast_mod.MethodFlags.is_generator != 0) try self.writeByte('*');

        try self.emitNode(key);
        try self.writeByte('(');
        try self.emitNodeList(params_start, params_len, ",");
        try self.writeByte(')');
        try self.emitNode(body);
    }

    fn emitPropertyDef(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const key: NodeIndex = @enumFromInt(extras[ast_mod.PropertyExtra.key]);
        const value: NodeIndex = @enumFromInt(extras[ast_mod.PropertyExtra.init]);
        const flags = extras[ast_mod.PropertyExtra.flags];
        const deco_start = extras[ast_mod.PropertyExtra.deco_start];
        const deco_len = extras[ast_mod.PropertyExtra.deco_len];

        try self.emitMemberDecorators(deco_start, deco_len);

        if (flags & ast_mod.PropertyFlags.is_static != 0) try self.write("static ");
        try self.emitNode(key);
        if (!value.isNone()) {
            try self.writeSpace();
            try self.writeByte('=');
            try self.writeSpace();
            // contextual name: class property = function-like → key 이름 사용
            if (self.fn_map_builder != null and self.isFunctionLike(value)) {
                const saved = self.pending_fn_name;
                self.pending_fn_name = self.resolveKeyName(key);
                try self.emitNode(value);
                self.pending_fn_name = saved;
            } else {
                try self.emitNode(value);
            }
        }
        try self.writeByte(';');
    }

    fn emitDecorator(self: *Codegen, node: Node) !void {
        try self.writeByte('@');
        try self.emitNode(node.data.unary.operand);
    }

    /// decorator 리스트 출력 (member decorator 공용 헬퍼).
    /// deco_len > 0이면 각 decorator를 출력 후 줄바꿈 + 들여쓰기.
    fn emitMemberDecorators(self: *Codegen, deco_start: u32, deco_len: u32) !void {
        if (deco_len == 0) return;
        const deco_indices = self.ast.extra_data.items[deco_start .. deco_start + deco_len];
        for (deco_indices) |raw_idx| {
            try self.emitNode(@enumFromInt(raw_idx));
            try self.writeByte('\n');
            try self.writeIndent();
        }
    }

    fn emitAccessorProp(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const key: NodeIndex = @enumFromInt(extras[ast_mod.PropertyExtra.key]);
        const value: NodeIndex = @enumFromInt(extras[ast_mod.PropertyExtra.init]);
        const flags = extras[ast_mod.PropertyExtra.flags];
        const deco_start = extras[ast_mod.PropertyExtra.deco_start];
        const deco_len = extras[ast_mod.PropertyExtra.deco_len];

        try self.emitMemberDecorators(deco_start, deco_len);

        if (flags & ast_mod.PropertyFlags.is_static != 0) try self.write("static ");
        try self.write("accessor ");
        try self.emitNode(key);
        if (!value.isNone()) {
            try self.writeSpace();
            try self.writeByte('=');
            try self.writeSpace();
            try self.emitNode(value);
        }
        try self.writeByte(';');
    }

    // ================================================================
    // Pattern 출력
    // ================================================================

    fn emitAssignmentPattern(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeByte('=');
        try self.emitNode(node.data.binary.right);
    }

    fn emitBindingProperty(self: *Codegen, node: Node) !void {
        // key는 원본 span 출력 (프로퍼티 이름이므로 rename 적용 안 함).
        // computed property key ([expr])는 내부 표현식에 rename이 필요하므로 emitNode 사용.
        const key_node = self.ast.getNode(node.data.binary.left);
        if (key_node.tag == .computed_property_key) {
            try self.emitNode(node.data.binary.left);
        } else {
            try self.writeSpan(key_node.span);
        }
        // shorthand: right가 none이면 {key} 형태 — 콜론 생략
        if (!node.data.binary.right.isNone()) {
            // shorthand_with_default: { x = val } → x:x=val
            // cover grammar에서 assignment_target_property_identifier로 변환된 경우,
            // right가 default value이고 key가 binding name이다.
            // 출력: key:key=default (TS 모드의 binding_property와 동일한 형태)
            const shorthand_with_default: u16 = 0x01; // Parser.shorthand_with_default과 동일
            const is_shorthand_default = (node.data.binary.flags & shorthand_with_default) != 0;
            if (is_shorthand_default and node.tag == .assignment_target_property_identifier) {
                try self.writeByte(':');
                try self.writeSpan(key_node.span);
                try self.writeByte('=');
                try self.emitNode(node.data.binary.right);
            } else {
                try self.writeByte(':');
                try self.emitNode(node.data.binary.right);
            }
        }
    }

    fn emitRest(self: *Codegen, node: Node) !void {
        try self.write("...");
        try self.emitNode(node.data.unary.operand);
    }

    // ================================================================
    // Declaration 출력
    // ================================================================

    fn emitVariableDeclaration(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const kind = self.ast.variableDeclarationKind(node);
        const list_start = extras[1];
        const list_len = extras[2];

        // __esm 호이스팅: top-level 단순 변수 선언만 키워드 제거 (할당문으로 변환).
        // indent_level == 0: factory body의 top-level에서만 적용.
        // 함수 안의 const/let/var는 그대로 유지해야 함.
        // destructuring 패턴이 있으면 normal 경로 (키워드 필요).
        if (self.options.esm_var_assign_only and self.indent_level == 0 and !self.in_for_init) {
            const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
            // destructuring 여부 확인: 하나라도 binding_identifier가 아니면 normal 경로
            var has_destructuring = false;
            for (declarators) |raw_decl_idx| {
                const decl_node = self.ast.nodes.items[raw_decl_idx];
                const dextras2 = self.ast.extra_data.items[decl_node.data.extra .. decl_node.data.extra + 3];
                const n_idx: NodeIndex = @enumFromInt(dextras2[0]);
                if (!n_idx.isNone() and self.ast.nodes.items[@intFromEnum(n_idx)].tag != .binding_identifier) {
                    has_destructuring = true;
                    break;
                }
            }
            if (!has_destructuring) {
                var has_output = false;
                for (declarators) |raw_decl_idx| {
                    const decl_node = self.ast.nodes.items[raw_decl_idx];
                    const de = decl_node.data.extra;
                    const dextras = self.ast.extra_data.items[de .. de + 3];
                    const name_idx: NodeIndex = @enumFromInt(dextras[0]);
                    const init_idx: NodeIndex = @enumFromInt(dextras[2]);
                    if (!init_idx.isNone()) {
                        if (has_output) try self.writeNewline();
                        try self.emitNode(name_idx);
                        try self.writeSpace();
                        try self.writeByte('=');
                        try self.writeSpace();
                        try self.emitNode(init_idx);
                        try self.writeByte(';');
                        has_output = true;
                    }
                }
                return;
            }
            // destructuring → fall through to normal path (var 키워드 유지)
        }

        const keyword = switch (kind) {
            .@"var" => "var ",
            .let => "let ",
            .@"const" => "const ",
            .using => "using ",
            .await_using => "await using ",
        };
        try self.write(keyword);
        try self.emitNodeList(list_start, list_len, ",");
        // for문 init 위치에서는 세미콜론을 emitFor가 직접 출력하므로 생략
        if (!self.in_for_init) {
            try self.writeByte(';');
        }
    }

    fn emitVariableDeclarator(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const name: NodeIndex = @enumFromInt(extras[0]);
        // extras[1] = type_ann (스킵)
        const init_val: NodeIndex = @enumFromInt(extras[2]);

        try self.emitNode(name);
        // skip_var_init: for-in hoisting으로 init가 별도 문장에 출력된 경우 스킵
        if (!init_val.isNone() and !self.skip_var_init) {
            try self.writeSpace();
            try self.writeByte('=');
            try self.writeSpace();
            // contextual name: binding_identifier = function/arrow/class → 변수명을 이름으로
            if (self.fn_map_builder != null and self.isFunctionLike(init_val)) {
                const saved = self.pending_fn_name;
                self.pending_fn_name = self.resolveBindingName(name);
                try self.emitNode(init_val);
                self.pending_fn_name = saved;
            } else {
                try self.emitNode(init_val);
            }
        }
    }

    fn emitFormalParam(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        // extra = [pattern, type_ann, default, flags, deco_start, deco_len]
        const extras = self.ast.extra_data.items[e .. e + 6];
        const pattern: NodeIndex = @enumFromInt(extras[0]);
        // extras[1] = type_ann (스킵), extras[3] = flags (스킵), extras[4..5] = decorators (스킵)
        const default_val: NodeIndex = @enumFromInt(extras[2]);

        try self.emitNode(pattern);
        if (!default_val.isNone()) {
            try self.writeByte('=');
            try self.emitNode(default_val);
        }
    }

    // ================================================================
    // Import/Export 출력
    // ================================================================

    fn emitImport(self: *Codegen, node: Node) !void {
        const x = module_parser.readImportDeclExtras(self.ast, node.data.extra);

        if (self.options.module_format == .cjs) {
            return self.emitImportCJS(x.source, x.specs_start, x.specs_len);
        }

        try self.write("import ");
        switch (x.phase) {
            .defer_ => try self.write("defer "),
            .source => try self.write("source "),
            .none => {},
        }
        if (x.specs_len > 0) {
            try self.emitImportSpecifiers(x.specs_start, x.specs_len);
            try self.write(" from ");
        }
        try self.emitNode(x.source);
        if (x.attrs_len > 0) {
            try self.write(" with ");
            try self.emitImportAttributes(x.attrs_start, x.attrs_len);
        }
        try self.writeByte(';');
    }

    fn emitImportAttributes(self: *Codegen, attrs_start: u32, attrs_len: u32) !void {
        try self.writeByte('{');
        const indices = self.ast.extra_data.items[attrs_start .. attrs_start + attrs_len];
        for (indices, 0..) |raw_idx, i| {
            if (i > 0) try self.write(", ");
            const attr_node = self.ast.getNode(@enumFromInt(raw_idx));
            // 키는 identifier 또는 string literal — string_literal emit의 quote-strip을 피해 raw span 사용.
            const key_node = self.ast.getNode(attr_node.data.binary.left);
            try self.writeNodeSpan(key_node);
            try self.write(": ");
            const value = attr_node.data.binary.right;
            if (!value.isNone()) try self.emitNode(value);
        }
        try self.writeByte('}');
    }

    /// import specifiers를 타입별로 출력한다.
    /// default → 이름만, namespace → * as 이름, named → { a, b }
    fn emitImportSpecifiers(self: *Codegen, specs_start: u32, specs_len: u32) !void {
        const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
        var first = true;
        var has_named = false;

        // 1단계: default, namespace 출력
        for (spec_indices) |raw_idx| {
            const spec: NodeIndex = @enumFromInt(raw_idx);
            if (spec.isNone()) continue;
            const spec_node = self.ast.getNode(spec);
            switch (spec_node.tag) {
                .import_default_specifier => {
                    if (!first) try self.write(",");
                    try self.writeNodeSpan(spec_node);
                    first = false;
                },
                .import_namespace_specifier => {
                    if (!first) try self.write(",");
                    try self.write("* as ");
                    try self.writeNodeSpan(spec_node);
                    first = false;
                },
                .import_specifier => {
                    has_named = true;
                },
                else => {},
            }
        }

        // 2단계: named specifiers를 { } 감싸서 출력
        if (has_named) {
            if (!first) try self.write(", ");
            try self.writeByte('{');
            if (!self.options.minify_whitespace) try self.writeByte(' ');
            const sep: []const u8 = self.listSep();
            var named_first = true;
            for (spec_indices) |raw_idx| {
                const spec: NodeIndex = @enumFromInt(raw_idx);
                if (spec.isNone()) continue;
                const spec_node = self.ast.getNode(spec);
                if (spec_node.tag == .import_specifier) {
                    if (!named_first) try self.write(sep);
                    try self.emitImportSpecifierRename(spec_node, " as ");
                    named_first = false;
                }
            }
            if (!self.options.minify_whitespace) try self.writeByte(' ');
            try self.writeByte('}');
        }
    }

    /// CJS: import { foo } from './bar' → const {foo}=require('./bar');
    /// CJS: import bar from './bar' → const bar=require('./bar').default;
    /// CJS: import * as bar from './bar' → const bar=require('./bar');
    /// __esm 래핑 모듈: const → var (호이스팅 지원)
    fn emitImportCJS(self: *Codegen, source: NodeIndex, specs_start: u32, specs_len: u32) !void {
        if (specs_len == 0) {
            _ = try self.emitRequireRewriteOrCall(source);
            try self.writeByte(';');
            return;
        }

        // specifier 유형 분석 (키워드 생략 판단에 필요)
        const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
        var has_default = false;
        var has_namespace = false;
        var named_count: u32 = 0;

        for (spec_indices) |raw_idx| {
            const spec = self.ast.getNode(@enumFromInt(raw_idx));
            switch (spec.tag) {
                .import_default_specifier => has_default = true,
                .import_namespace_specifier => has_namespace = true,
                .import_specifier => named_count += 1,
                else => {},
            }
        }

        // namespace 접근 패턴: named import만 있고, 모든 named binding이
        // __ns_N.prop 형태의 rename을 가지면 이 import 선언을 skip한다.
        // preamble에서 이미 ns_var = __toESM(require_xxx())가 생성되었으므로
        // body의 destructuring assignment는 불필요.
        if (named_count > 0 and !has_default and !has_namespace and self.options.linking_metadata != null) {
            const meta = self.options.linking_metadata.?;
            var all_ns_renamed = true;
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag != .import_specifier) continue;
                const local_idx = spec.data.binary.right;
                if (!local_idx.isNone()) {
                    if (self.resolveSymbolId(local_idx, meta)) |sid| {
                        if (meta.renames.get(sid)) |rename| {
                            if (!std.mem.startsWith(u8, rename, linker_mod.NS_VAR_PREFIX)) {
                                all_ns_renamed = false;
                                break;
                            }
                        } else {
                            all_ns_renamed = false;
                            break;
                        }
                    } else {
                        all_ns_renamed = false;
                        break;
                    }
                }
            }
            if (all_ns_renamed) return;
        }

        // __esm 호이스팅: var 선언이 래퍼 밖에 있으므로 body에서는 할당만.
        // named import ({a, b})는 destructuring assignment — var 생략 시 ({a,b}=expr) 괄호 필요.
        const skip_keyword = self.options.esm_var_assign_only;
        if (!skip_keyword)
            try self.write(if (self.options.use_var_for_imports) "var " else "const ");

        // named destructuring assignment: ({a,b}=expr); — 괄호 없으면 block으로 파싱됨
        // default+named 동시 (import Foo, {Bar}) 도 named 경로로 들어가므로 괄호 필요
        const needs_paren = skip_keyword and named_count > 0 and !has_namespace;
        if (needs_paren) try self.writeByte('(');

        if (has_namespace) {
            // import * as bar from './bar' → [var] bar=require('./bar');
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_namespace_specifier) {
                    try self.emitSpecifierWithRename(@enumFromInt(raw_idx), spec);
                    break;
                }
            }
        } else if (has_default and named_count == 0) {
            // import bar from './bar' → [var] bar=require('./bar').default;
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_default_specifier) {
                    try self.emitSpecifierWithRename(@enumFromInt(raw_idx), spec);
                    break;
                }
            }
        } else if (named_count > 0) {
            // import { foo, bar as baz } from './bar' → const {foo,bar:baz}=require('./bar');
            // import Foo, { bar } from './bar' → const {"default":Foo,bar}=require('./bar');
            try self.writeByte('{');
            var first = true;
            if (has_default) {
                for (spec_indices) |raw_idx| {
                    const spec = self.ast.getNode(@enumFromInt(raw_idx));
                    if (spec.tag == .import_default_specifier) {
                        try self.write("\"default\":");
                        try self.emitSpecifierWithRename(@enumFromInt(raw_idx), spec);
                        first = false;
                        break;
                    }
                }
            }
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_specifier) {
                    if (!first) try self.writeByte(',');
                    try self.emitImportSpecifierRename(spec, ":");
                    first = false;
                }
            }
            try self.writeByte('}');
        }

        try self.writeByte('=');

        // __esm body에서 default/namespace import: __toESM(require_xxx()) 래핑 필요.
        // CJS module.exports = fn 패턴에서 .default 프로퍼티가 없으므로 __toESM이
        // 모듈 전체를 default로 설정해준다. default+named 혼합 시에도 적용 —
        // __toESM이 __esModule 체크 후 프로퍼티를 복사하므로 named 접근도 정상 동작.
        const wrap_toesm = self.options.esm_var_assign_only and (has_default or has_namespace);
        if (wrap_toesm) try self.write("__toESM(");
        _ = try self.emitRequireRewriteOrCall(source);
        if (wrap_toesm) try self.writeByte(')');

        if (has_default and !has_namespace and named_count == 0) {
            try self.write(".default");
        }

        if (needs_paren) try self.writeByte(')');
        try self.writeByte(';');
    }

    /// import_default_specifier / import_namespace_specifier의 이름을 renames 적용하여 출력.
    /// 이 노드들은 identifier_reference가 아니라 별도 태그이므로 emitNode에서 renames를 거치지 않음.
    fn emitSpecifierWithRename(self: *Codegen, idx: NodeIndex, spec: Node) !void {
        if (self.options.linking_metadata) |meta| {
            const ni = @intFromEnum(idx);
            if (ni < meta.symbol_ids.len) {
                if (meta.symbol_ids[ni]) |sid| {
                    if (meta.renames.get(sid)) |renamed| {
                        try self.write(renamed);
                        return;
                    }
                }
            }
        }
        try self.writeSpan(spec.data.string_ref);
    }

    /// import specifier의 imported + rename separator + local 출력.
    /// ESM은 " as ", CJS는 ":" 를 separator로 사용한다.
    /// imported 쪽은 항상 원본 이름을 사용 (exports 객체의 프로퍼티 키).
    /// local 쪽은 rename 적용 (로컬 변수명).
    fn emitImportSpecifierRename(self: *Codegen, spec_node: Node, sep: []const u8) !void {
        const imported = spec_node.data.binary.left;
        const local = spec_node.data.binary.right;
        // imported: 항상 원본 이름 (exports 객체 키 = rename 전 이름)
        try self.writeSpan(self.ast.getNode(imported).span);
        // local이 rename 되었거나 원본 imported와 다른 경우 → separator + local 출력
        const needs_rename = blk: {
            if (local.isNone() or @intFromEnum(local) == @intFromEnum(imported)) break :blk false;
            // 원본 텍스트가 다르면 항상 rename 필요 (import { foo as bar })
            const imp_text = self.ast.getText(self.ast.getNode(imported).span);
            const loc_text = self.ast.getText(self.ast.getNode(local).span);
            if (!std.mem.eql(u8, imp_text, loc_text)) break :blk true;
            // 원본 텍스트가 같아도 linker가 rename했으면 separator 필요
            // (e.g., import { Foo } → {Foo: Foo$1})
            if (self.options.linking_metadata) |meta| {
                if (self.resolveSymbolId(local, meta)) |sid| {
                    if (meta.renames.get(sid)) |_| break :blk true;
                }
            }
            break :blk false;
        };
        if (needs_rename) {
            try self.write(sep);
            try self.emitNode(local);
        }
    }

    fn emitExportNamed(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 4];
        const decl: NodeIndex = @enumFromInt(extras[0]);
        const specs_start = extras[1];
        const specs_len = extras[2];
        const source: NodeIndex = @enumFromInt(extras[3]);

        if (self.options.module_format == .cjs) {
            return self.emitExportNamedCJS(decl, specs_start, specs_len, source);
        }

        // 번들 모드: export 키워드 생략, declaration만 출력
        if (self.options.linking_metadata != null and !decl.isNone()) {
            try self.emitNode(decl);
            return;
        }

        try self.write("export ");
        if (!decl.isNone()) {
            try self.emitNode(decl);
        } else {
            try self.writeByte('{');
            if (self.options.minify_whitespace) {
                try self.emitNodeList(specs_start, specs_len, ",");
            } else {
                try self.writeByte(' ');
                try self.emitNodeList(specs_start, specs_len, ", ");
                try self.writeByte(' ');
            }
            try self.writeByte('}');
            if (!source.isNone()) {
                try self.write(" from ");
                try self.emitNode(source);
            }
            try self.writeByte(';');
        }
    }

    /// ESM export specifier: `foo` 또는 `foo as bar`
    /// writeNodeSpan 대신 사용 — 원본 span에 공백이 포함될 수 있으므로 구조적으로 출력.
    fn emitExportSpecifier(self: *Codegen, node: Node) !void {
        const local_idx = node.data.binary.left;
        const exported_idx = node.data.binary.right;
        const local_node = self.ast.getNode(local_idx);
        const exported_node = self.ast.getNode(exported_idx);
        const local_text = self.ast.getText(local_node.span);
        const exported_text = self.ast.getText(exported_node.span);
        try self.write(local_text);
        if (!std.mem.eql(u8, local_text, exported_text)) {
            try self.write(" as ");
            try self.write(exported_text);
        }
    }

    /// CJS: export const x = 1 → const x=1;exports.x=x;
    /// CJS: export { foo } → exports.foo=foo;
    /// CJS: export { foo, default as Bar } from './bar' → exports.foo=require("./bar").foo;exports.Bar=require("./bar").default;
    fn emitExportNamedCJS(self: *Codegen, decl: NodeIndex, specs_start: u32, specs_len: u32, source: NodeIndex) !void {
        if (!decl.isNone() and @intFromEnum(decl) < self.ast.nodes.items.len) {
            // export const x = 1 → const x=1; (+ exports.x=x; unless __esm)
            try self.emitNode(decl);
            if (!self.options.skip_cjs_exports)
                try self.emitCJSExportBinding(decl);
            return;
        } else if (self.options.skip_cjs_exports) {
            // __esm 모듈: export { } 구문은 __export()가 처리하므로 생략
            return;
        } else {
            const has_source = !source.isNone() and @intFromEnum(source) < self.ast.nodes.items.len;
            const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag != .export_specifier) continue;

                // export_specifier: { left=local/imported, right=exported }
                // alias 없으면 exported == local (파서가 동일 인덱스 할당)
                const local_idx = spec.data.binary.left;
                const exported_idx = spec.data.binary.right;
                const exported_text = self.ast.getText(self.ast.getNode(exported_idx).span);
                const local_text = self.ast.getText(self.ast.getNode(local_idx).span);

                try self.write("exports.");
                try self.write(exported_text);
                try self.writeByte('=');
                if (has_source) {
                    try self.write("require(");
                    try self.emitNode(source);
                    try self.write(").");
                }
                try self.write(local_text);
                try self.writeByte(';');
            }
        }
    }

    /// 변수/함수/클래스 선언에서 이름을 추출하여 exports.name=name; 출력.
    /// variable_declarator의 이름은 span 텍스트에서 직접 추출 (extra 경유 불필요).
    fn emitCJSExportBinding(self: *Codegen, decl_idx: NodeIndex) !void {
        const decl = self.ast.getNode(decl_idx);
        switch (decl.tag) {
            .variable_declaration => {
                const e = decl.data.extra;
                const list_start = self.ast.extra_data.items[e + 1];
                const list_len = self.ast.extra_data.items[e + 2];
                const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
                for (declarators) |raw_idx| {
                    const declarator = self.ast.getNode(@enumFromInt(raw_idx));
                    const de = declarator.data.extra;
                    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
                    if (!name_idx.isNone()) {
                        const name_node = self.ast.getNode(name_idx);
                        const name = self.ast.getText(name_node.data.string_ref);
                        // linker가 rename한 경우 변수 참조는 rename된 이름을 사용해야 함
                        // (예: JSON named export에서 $id → $id$1로 충돌 회피 시)
                        const ref_name = if (self.options.linking_metadata) |meta|
                            if (self.resolveSymbolId(name_idx, meta)) |sid|
                                (meta.renames.get(sid) orelse name)
                            else
                                name
                        else
                            name;
                        try self.write("exports.");
                        try self.write(name);
                        try self.writeByte('=');
                        try self.write(ref_name);
                        try self.writeByte(';');
                    }
                }
            },
            .function_declaration, .class_declaration => {
                const e = decl.data.extra;
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                if (!name_idx.isNone()) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.getText(name_node.data.string_ref);
                    const ref_name = if (self.options.linking_metadata) |meta|
                        if (self.resolveSymbolId(name_idx, meta)) |sid|
                            (meta.renames.get(sid) orelse name)
                        else
                            name
                    else
                        name;
                    try self.write("exports.");
                    try self.write(name);
                    try self.writeByte('=');
                    try self.write(ref_name);
                    try self.writeByte(';');
                }
            },
            else => {},
        }
    }

    fn emitExportDefault(self: *Codegen, node: Node) !void {
        if (self.options.module_format == .cjs) {
            if (self.options.skip_cjs_exports) {
                // __esm 모듈: export는 __export()가 처리.
                // named decl (export default function foo) → 선언만 출력
                // named ref (export default NativeModules) → 이미 선언됨, 무시
                // anonymous expr (export default {...}) → var _default = expr;
                const inner = node.data.unary.operand;
                if (!inner.isNone()) {
                    const inner_node = self.ast.getNode(inner);
                    const is_named_decl = (inner_node.tag == .function_declaration or inner_node.tag == .class_declaration) and
                        !(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[inner_node.data.extra]))).isNone();
                    if (is_named_decl) {
                        // export default function foo() {} → 선언만 출력
                        try self.emitNode(inner);
                    } else {
                        const def_name = if (self.options.linking_metadata) |md| md.default_export_name else "_default";
                        if (std.mem.startsWith(u8, def_name, "_default")) {
                            // 합성 변수 (_default, _default$1 등): var 선언 + 할당 필요.
                            if (!self.options.esm_var_assign_only) try self.write("var ");
                            try self.write(def_name);
                            try self.writeByte('=');
                            try self.emitNode(inner);
                            try self.writeByte(';');
                        } else if (!self.isExportDefaultSelfRef(inner, def_name)) {
                            // namespace import이면 ns var name을 직접 사용 (rename과 다름).
                            if (!(try self.tryEmitNsVarAssignment(def_name, inner))) {
                                // mangling으로 이름이 바뀐 경우 (View → View$44) 할당 필요.
                                try self.write(def_name);
                                try self.writeByte('=');
                                try self.emitNode(inner);
                                try self.writeByte(';');
                            }
                        }
                    }
                }
                return;
            }
            try self.write("module.exports=");
            try self.emitNode(node.data.unary.operand);
            try self.writeByte(';');
            return;
        }
        // 번들 모드: export default 키워드 생략, 내부 선언만 출력
        if (self.options.linking_metadata != null) {
            const inner = node.data.unary.operand;
            if (!inner.isNone()) {
                const inner_node = self.ast.getNode(inner);
                // 이름이 있는 function/class → 그대로 출력
                const is_named_decl = (inner_node.tag == .function_declaration or inner_node.tag == .class_declaration) and
                    !(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[inner_node.data.extra]))).isNone();
                if (is_named_decl) {
                    try self.emitNode(inner);
                } else {
                    const def_name = self.options.linking_metadata.?.default_export_name;
                    if (!self.isExportDefaultSelfRef(inner, def_name)) {
                        // namespace import는 실제 값이 `X_ns` 변수에 저장되므로
                        // `def_name = X_ns;` 로 할당. 일반 케이스는 inner 표현식 직접 대입.
                        if (!(try self.tryEmitNsVarAssignment(def_name, inner))) {
                            try self.emitDefaultVarAssignment(def_name, inner);
                        }
                    }
                }
            }
            return;
        }
        try self.write("export default ");
        const inner_idx = node.data.unary.operand;
        // contextual name: 익명 function/arrow/class → "default"
        if (self.fn_map_builder != null and self.isFunctionLike(inner_idx)) {
            const saved = self.pending_fn_name;
            self.pending_fn_name = "default";
            try self.emitNode(inner_idx);
            self.pending_fn_name = saved;
        } else {
            try self.emitNode(inner_idx);
        }
        // class/function 선언 뒤에는 세미콜론 불필요
        if (!inner_idx.isNone()) {
            const inner_tag = self.ast.getNode(inner_idx).tag;
            if (inner_tag != .class_declaration and inner_tag != .function_declaration) {
                try self.writeByte(';');
            }
        }
    }

    /// inner가 namespace import (`import * as X`) 를 참조하면 `<def_name> = <X_ns>;` 할당을 emit.
    /// 성공 시 true, namespace import가 아니면 false (caller가 기본 emit 수행).
    /// `var Animated$6;` 선언과 `Animated_ns = {...}` 객체 사이 연결을 복원해 default getter가
    /// 올바른 namespace 객체를 반환하도록 한다 (#1208).
    fn tryEmitNsVarAssignment(self: *Codegen, def_name: []const u8, inner: NodeIndex) !bool {
        const md = self.options.linking_metadata orelse return false;
        const inner_node = self.ast.getNode(inner);
        if (inner_node.tag != .identifier_reference) return false;
        const sid = self.resolveSymbolId(inner, md) orelse return false;
        const entry = md.ns_inline_objects.get(sid) orelse return false;

        if (!self.options.esm_var_assign_only) try self.write("var ");
        try self.write(def_name);
        if (self.options.minify_whitespace) {
            try self.writeByte('=');
        } else {
            try self.write(" = ");
        }
        try self.write(entry.var_name);
        try self.writeByte(';');
        return true;
    }

    /// `var <name> = <inner>;` 출력 (export default 변환용).
    fn emitDefaultVarAssignment(self: *Codegen, name: []const u8, inner: NodeIndex) !void {
        if (self.options.minify_whitespace) {
            try self.write("var ");
            try self.write(name);
            try self.writeByte('=');
        } else {
            try self.write("var ");
            try self.write(name);
            try self.write(" = ");
        }
        try self.emitNode(inner);
        try self.writeByte(';');
    }

    fn emitExportAll(self: *Codegen, node: Node) !void {
        if (self.options.module_format == .cjs) {
            // export * from './bar' → Object.assign(exports,require('./bar'));
            try self.write("Object.assign(exports,require(");
            try self.emitNode(node.data.binary.right);
            try self.write("));");
            return;
        }
        // export * as ns from './foo' → left=ns, right=source
        // export * from './foo'       → left=none, right=source
        if (node.data.binary.left != .none) {
            try self.write("export * as ");
            try self.emitNode(node.data.binary.left);
            try self.write(" from ");
        } else {
            try self.write("export * from ");
        }
        try self.emitNode(node.data.binary.right);
        try self.writeByte(';');
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
    // TS enum → IIFE 출력
    // ================================================================

    /// enum Color { Red, Green = 5, Blue } →
    /// var Color;((Color) => {Color[Color["Red"]=0]="Red";Color[Color["Green"]=5]="Green";Color[Color["Blue"]=6]="Blue";})(Color || (Color = {}));
    fn emitEnumIIFE(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
        const members_start = self.ast.extra_data.items[e + 1];
        const members_len = self.ast.extra_data.items[e + 2];
        // extras[3] = flags (0=일반, 1=const). const enum은 transformer에서 삭제됨.

        // enum 이름 텍스트 가져오기
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.getText(name_node.span);

        // 각 멤버의 resolved 값을 수집 (멤버 간 참조 인라이닝용)
        const member_indices = self.ast.extra_data.items[members_start .. members_start + members_len];

        // 멤버 이름→값 매핑 (enum 자기 참조 인라이닝용)
        var member_values: std.StringHashMapUnmanaged(EnumMemberValue) = .{};
        defer member_values.deinit(self.allocator);

        // 1차 패스에서 needs_rename도 같이 판별 (별도 순회 불필요)
        var needs_rename = false;

        // TS 식별자는 실전에서 256자를 넘지 않음
        var param_buf: [256]u8 = undefined;

        // 1차 패스: 멤버 값 수집 + needs_rename 판별 (출력 전에 실행)
        {
            var auto_value: i64 = 0;
            var auto_valid = true;
            for (member_indices) |raw_idx| {
                const member = self.ast.getNode(@enumFromInt(raw_idx));
                const member_name = self.ast.getNode(member.data.binary.left);
                const raw_text = self.ast.getText(member_name.span);
                const mt = stripStringQuotes(raw_text);
                const member_init_idx = member.data.binary.right;

                if (!needs_rename and std.mem.eql(u8, mt, name_text)) {
                    needs_rename = true;
                }

                if (!member_init_idx.isNone()) {
                    const init_node = self.ast.getNode(member_init_idx);
                    if (init_node.tag == .numeric_literal) {
                        const num_text = self.ast.getText(init_node.span);
                        if (std.fmt.parseInt(i64, num_text, 10)) |v| {
                            try member_values.put(self.allocator, mt, .{ .int = v });
                            auto_value = v + 1;
                            auto_valid = true;
                        } else |_| {
                            try member_values.put(self.allocator, mt, .{ .raw = num_text });
                            auto_valid = false;
                        }
                    } else if (init_node.tag == .identifier_reference) {
                        const ref_text = self.ast.getText(init_node.span);
                        if (member_values.get(ref_text)) |resolved| {
                            try member_values.put(self.allocator, mt, resolved);
                            switch (resolved) {
                                .int => |v| {
                                    auto_value = v + 1;
                                    auto_valid = true;
                                },
                                .raw, .str => {
                                    auto_valid = false;
                                },
                            }
                        } else {
                            auto_valid = false;
                        }
                    } else if (init_node.tag == .string_literal) {
                        const str_text = self.ast.getText(init_node.span);
                        try member_values.put(self.allocator, mt, .{ .str = str_text });
                        auto_valid = false;
                    } else {
                        auto_valid = false;
                    }
                } else {
                    if (auto_valid) {
                        try member_values.put(self.allocator, mt, .{ .int = auto_value });
                        auto_value += 1;
                    }
                }
            }
        }

        const param_name = if (needs_rename) blk: {
            const len = @min(name_text.len + 1, param_buf.len);
            param_buf[0] = '_';
            @memcpy(param_buf[1..len], name_text[0 .. len - 1]);
            break :blk param_buf[0..len];
        } else name_text;

        // var Color = /* @__PURE__ */ ((Color) => { ...; return Color; })(Color || {});
        // esm_var_assign_only: var 선언은 이미 __esm 밖 top-level에 hoisted.
        // factory 안에서는 할당만 출력.
        if (!self.options.esm_var_assign_only) try self.write("var ");
        try self.write(name_text);
        try self.write(" = /* @__PURE__ */ ((");
        try self.write(param_name);
        try self.write(") => {");

        // 2차 패스: 각 멤버 출력
        var auto_value: i64 = 0;
        for (member_indices) |raw_idx| {
            const member = self.ast.getNode(@enumFromInt(raw_idx));
            // ts_enum_member: binary = { left=name, right=init_val }
            const member_name_idx = member.data.binary.left;
            const member_init_idx = member.data.binary.right;

            const member_name = self.ast.getNode(member_name_idx);
            const raw_text = self.ast.getText(member_name.span);
            // 문자열 리터럴 키의 따옴표 제거: 'a' → a, "a b" → a b
            const member_text = stripStringQuotes(raw_text);

            // Color[Color["Red"] = 0] = "Red";
            try self.write(param_name);
            try self.writeByte('[');
            try self.write(param_name);
            try self.write("[\"");
            try self.write(member_text);
            try self.write("\"]=");

            if (!member_init_idx.isNone()) {
                const init_node = self.ast.getNode(member_init_idx);
                // enum 멤버가 다른 멤버를 참조하는 경우 → 인라이닝
                if (init_node.tag == .identifier_reference) {
                    const ref_text = self.ast.getText(init_node.span);
                    if (member_values.get(ref_text)) |resolved| {
                        // 인라인된 값 출력 + 원본을 주석으로
                        switch (resolved) {
                            .int => |v| try self.emitInt(v),
                            .raw => |r| try self.write(r),
                            .str => |s| try self.write(s),
                        }
                        try self.write(" /* ");
                        try self.write(ref_text);
                        try self.write(" */");
                    } else {
                        try self.emitNode(member_init_idx);
                    }
                } else {
                    // 이니셜라이저가 있으면 그대로 출력
                    try self.emitNode(member_init_idx);
                }
                // auto_value 갱신: 1차 패스의 resolved 값을 사용 (identifier_reference 인라인 포함)
                if (member_values.get(member_text)) |resolved| {
                    switch (resolved) {
                        .int => |v| {
                            auto_value = v + 1;
                        },
                        .raw, .str => {},
                    }
                }
            } else {
                // 자동 증가 값 출력
                try self.emitInt(auto_value);
                auto_value += 1;
            }

            try self.write("]=\"");
            try self.write(member_text);
            try self.write("\";");
        }

        // return Color;})(Color || {});
        try self.write("return ");
        try self.write(param_name);
        try self.write(";})(");
        try self.write(name_text);
        try self.write(" || {});");
    }

    /// 문자열 리터럴의 외부 따옴표를 제거한다.
    /// 'a' → a, "a b" → a b, Red → Red (따옴표 없으면 그대로)
    fn stripStringQuotes(text: []const u8) []const u8 {
        if (text.len >= 2) {
            const first = text[0];
            const last = text[text.len - 1];
            if ((first == '\'' or first == '"') and first == last) {
                return text[1 .. text.len - 1];
            }
        }
        return text;
    }

    const EnumMemberValue = union(enum) {
        int: i64,
        raw: []const u8, // float 등 숫자 원본 텍스트
        str: []const u8, // 문자열 리터럴 원본 텍스트
    };

    // ================================================================
    // TS namespace → IIFE 출력
    // ================================================================

    /// namespace Foo { export const x = 1; } →
    /// var Foo;((Foo) => {const x=1;Foo.x=x;})(Foo || (Foo = {}));
    ///
    /// 현재 단순 구현: 내부 문을 그대로 출력하고, export 문은 Foo.name = name으로 변환.
    fn emitNamespaceIIFE(self: *Codegen, node: Node) !void {
        return self.emitNamespaceIIFEInner(node, null);
    }

    /// parent_ns: 부모 namespace 이름 (중첩 시 foo.bar 경로 생성용)
    fn emitNamespaceIIFEInner(self: *Codegen, node: Node, parent_ns: ?[]const u8) !void {
        const name_idx = node.data.binary.left;
        const body_idx = node.data.binary.right;

        // 중첩 namespace (A.B.C)인 경우: right가 ts_module_declaration
        const body_node = self.ast.getNode(body_idx);
        if (body_node.tag == .ts_module_declaration) {
            const name_node = self.ast.getNode(name_idx);
            const name_text = self.ast.getText(name_node.span);

            // 부모가 있으면 let, 없으면 var
            if (parent_ns != null) {
                try self.write("let ");
            } else {
                try self.write("var ");
            }
            try self.write(name_text);
            try self.writeByte(';');
            try self.write("((");
            try self.write(name_text);
            try self.write(") => {");
            // 내부 namespace를 재귀 출력 (부모 이름 전달)
            try self.emitNamespaceIIFEInner(body_node, name_text);
            // 중첩 closing: (bar = foo.bar || (foo.bar = {}))
            if (parent_ns) |pns| {
                try self.write("})(");
                try self.write(name_text);
                try self.write(" = ");
                try self.write(pns);
                try self.writeByte('.');
                try self.write(name_text);
                try self.write(" || (");
                try self.write(pns);
                try self.writeByte('.');
                try self.write(name_text);
                try self.write(" = {}));");
            } else {
                try self.emitIIFEClosing(name_text);
            }
            return;
        }

        // body가 block_statement인 경우 (일반 namespace)
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.getText(name_node.span);

        // 부모가 있으면 let, 없으면 var (esbuild 호환)
        // 같은 이름이 이미 선언되었으면 var/let 생략 (function + namespace 병합 등)
        if (!self.declared_names.contains(name_text)) {
            if (parent_ns != null) {
                try self.write("let ");
            } else {
                try self.write("var ");
            }
            try self.write(name_text);
            try self.writeByte(';');
        }
        self.declared_names.put(self.allocator, name_text, {}) catch {};

        // 1단계: export된 이름 수집 (IIFE 열기 전에 — 파라미터 충돌 감지용)
        var ns_export_map: std.StringHashMapUnmanaged(void) = .{};
        defer ns_export_map.deinit(self.allocator);
        if (body_node.tag == .block_statement) {
            const list = body_node.data.list;
            const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
            for (indices) |raw_idx| {
                const stmt_node = self.ast.getNode(@enumFromInt(raw_idx));
                if (stmt_node.tag == .export_named_declaration) {
                    const e = stmt_node.data.extra;
                    const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                    if (!decl_idx.isNone()) {
                        self.collectExportNames(&ns_export_map, decl_idx) catch {};
                    }
                }
            }
        }

        // 파라미터 이름: export 변수와 충돌하면 _ 접두사 (esbuild 호환)
        // namespace a { export var a = 123 } → ((_a) => { _a.a = 123 })(a || (a = {}))
        var param_buf: [256]u8 = undefined;
        const param_name = if (ns_export_map.contains(name_text)) blk: {
            const len = @min(name_text.len + 1, param_buf.len);
            param_buf[0] = '_';
            @memcpy(param_buf[1..len], name_text[0 .. len - 1]);
            break :blk param_buf[0..len];
        } else name_text;

        // ((Foo) => { ... })(Foo || (Foo = {}));
        try self.write("((");
        try self.write(param_name);
        try self.write(") => {");

        // 2단계: ns_prefix 설정 (identifier 출력 시 치환 활성화)
        const saved_prefix = self.ns_prefix;
        const saved_exports = self.ns_exports;
        if (ns_export_map.count() > 0) {
            self.ns_prefix = param_name;
            self.ns_exports = ns_export_map;
        }
        defer {
            self.ns_prefix = saved_prefix;
            self.ns_exports = saved_exports;
        }

        // 3단계: body 출력 (export 문은 Foo.name = expr 형태로 변환)
        if (body_node.tag == .block_statement) {
            const list = body_node.data.list;
            const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
            for (indices) |raw_idx| {
                const stmt_node = self.ast.getNode(@enumFromInt(raw_idx));
                switch (stmt_node.tag) {
                    .export_named_declaration => {
                        const e = stmt_node.data.extra;
                        const extras = self.ast.extra_data.items[e .. e + 4];
                        const decl_idx: NodeIndex = @enumFromInt(extras[0]);
                        if (!decl_idx.isNone()) {
                            const decl_node = self.ast.getNode(decl_idx);
                            // export namespace bar {} → 중첩 namespace (부모 이름 전달)
                            if (decl_node.tag == .ts_module_declaration) {
                                try self.emitNamespaceIIFEInner(decl_node, param_name);
                            } else if (decl_node.tag == .variable_declaration) {
                                // 단순 바인딩(identifier)은 직접 프로퍼티 할당: ns.a=1;
                                // destructuring(array_pattern/object_pattern)은 폴백: var [...]=ref; ns.a=a;
                                if (self.isSimpleVarDeclaration(decl_idx)) {
                                    try self.emitNamespaceVarDirectAssign(param_name, decl_idx);
                                } else {
                                    try self.emitNode(decl_idx);
                                    try self.emitNamespaceExport(param_name, decl_idx);
                                }
                            } else {
                                try self.emitNode(decl_idx);
                                try self.emitNamespaceExport(param_name, decl_idx);
                            }
                        }
                    },
                    .export_default_declaration => {
                        try self.write(param_name);
                        try self.write(".default=");
                        try self.emitNode(stmt_node.data.unary.operand);
                        try self.writeByte(';');
                    },
                    .ts_module_declaration => {
                        try self.emitNamespaceIIFEInner(stmt_node, param_name);
                    },
                    else => try self.emitNode(@enumFromInt(raw_idx)),
                }
            }
        }

        // 부모가 있으면 중첩 closing: (name = parent.name || (parent.name = {}))
        if (parent_ns) |pns| {
            try self.write("})(");
            try self.write(name_text);
            try self.write(" = ");
            try self.write(pns);
            try self.writeByte('.');
            try self.write(name_text);
            try self.write(" || (");
            try self.write(pns);
            try self.writeByte('.');
            try self.write(name_text);
            try self.write(" = {}));");
        } else {
            try self.emitIIFEClosing(name_text);
        }
    }

    /// enum/namespace IIFE 닫는 부분: })(name || (name = {}));
    fn emitIIFEClosing(self: *Codegen, name_text: []const u8) !void {
        try self.write("})(");
        try self.write(name_text);
        try self.write(" || (");
        try self.write(name_text);
        try self.write(" = {}));");
    }

    /// namespace 내부의 export 선언에서 이름을 추출하여 Foo.name = name; 형태로 출력.
    fn emitNamespaceExport(self: *Codegen, ns_name: []const u8, decl_idx: NodeIndex) !void {
        const decl = self.ast.getNode(decl_idx);
        switch (decl.tag) {
            .variable_declaration => {
                // const x = 1, y = 2; → Foo.x = x; Foo.y = y;
                // var [a, b] = ref; → Foo.a = a; Foo.b = b;
                const e = decl.data.extra;
                const extras = self.ast.extra_data.items[e .. e + 3];
                const list_start = extras[1];
                const list_len = extras[2];
                const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
                for (declarators) |raw_idx| {
                    const declarator = self.ast.getNode(@enumFromInt(raw_idx));
                    const de = declarator.data.extra;
                    const d_extras = self.ast.extra_data.items[de .. de + 3];
                    const name_idx: NodeIndex = @enumFromInt(d_extras[0]);
                    try self.emitNamespaceBindingExport(ns_name, name_idx);
                }
            },
            .function_declaration, .class_declaration => {
                // function foo() {} → Foo.foo = foo;
                const e = decl.data.extra;
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                if (!name_idx.isNone()) {
                    const fn_name_node = self.ast.getNode(name_idx);
                    const fn_name = self.ast.getText(fn_name_node.span);
                    try self.write(ns_name);
                    try self.writeByte('.');
                    try self.write(fn_name);
                    try self.writeByte('=');
                    try self.write(fn_name);
                    try self.writeByte(';');
                }
            },
            else => {},
        }
    }

    /// 바인딩 패턴에서 모든 binding_identifier를 추출하여 ns.name = name; 형태로 출력.
    /// binding_identifier → ns.x = x;
    /// array_pattern → 각 요소 재귀
    /// object_pattern → 각 프로퍼티의 value 재귀
    fn emitNamespaceBindingExport(self: *Codegen, ns_name: []const u8, name_idx: NodeIndex) !void {
        if (name_idx.isNone()) return;
        const node = self.ast.getNode(name_idx);
        switch (node.tag) {
            .binding_identifier => {
                const var_name = self.ast.getText(node.span);
                try self.write(ns_name);
                try self.writeByte('.');
                try self.write(var_name);
                try self.writeByte('=');
                try self.write(var_name);
                try self.writeByte(';');
            },
            .array_pattern => {
                const split = self.ast.nodeListSplitRest(node.data.list);
                for (split.elements) |raw_idx| {
                    try self.emitNamespaceBindingExport(ns_name, @enumFromInt(raw_idx));
                }
                if (split.rest_operand) |op| {
                    try self.emitNamespaceBindingExport(ns_name, op);
                }
            },
            .object_pattern => {
                const split = self.ast.nodeListSplitRest(node.data.list);
                for (split.elements) |raw_idx| {
                    const prop = self.ast.getNode(@enumFromInt(raw_idx));
                    // property_property: binary.right = value (binding pattern)
                    try self.emitNamespaceBindingExport(ns_name, prop.data.binary.right);
                }
                if (split.rest_operand) |op| {
                    try self.emitNamespaceBindingExport(ns_name, op);
                }
            },
            .assignment_target_with_default => {
                // { x = defaultVal } → x
                try self.emitNamespaceBindingExport(ns_name, node.data.binary.left);
            },
            else => {},
        }
    }

    /// variable_declaration의 모든 declarator가 단순 binding_identifier인지 확인.
    /// destructuring (array_pattern, object_pattern)이 있으면 false.
    fn isSimpleVarDeclaration(self: *const Codegen, decl_idx: NodeIndex) bool {
        const decl = self.ast.getNode(decl_idx);
        const e = decl.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const list_start = extras[1];
        const list_len = extras[2];
        const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
        for (declarators) |raw_idx| {
            const declarator = self.ast.getNode(@enumFromInt(raw_idx));
            const de = declarator.data.extra;
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
            const name_node = self.ast.getNode(name_idx);
            if (name_node.tag != .binding_identifier) return false;
        }
        return true;
    }

    /// namespace 내부의 export variable_declaration을 직접 ns.prop = init 형태로 출력.
    /// local 변수를 만들지 않으므로 reserved word 문제(let await)와 stale local 문제를 모두 해결.
    /// 예: export let a = 1, b = a → ns.a=1;ns.b=ns.a;
    fn emitNamespaceVarDirectAssign(self: *Codegen, ns_name: []const u8, decl_idx: NodeIndex) !void {
        const decl = self.ast.getNode(decl_idx);
        const e = decl.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const list_start = extras[1];
        const list_len = extras[2];
        const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
        for (declarators) |raw_idx| {
            const declarator = self.ast.getNode(@enumFromInt(raw_idx));
            const de = declarator.data.extra;
            const d_extras = self.ast.extra_data.items[de .. de + 3];
            const name_idx: NodeIndex = @enumFromInt(d_extras[0]);
            const init_idx: NodeIndex = @enumFromInt(d_extras[2]);
            // init이 없으면 할당할 값이 없으므로 스킵 (esbuild 호환)
            if (init_idx.isNone()) continue;
            const var_name_node = self.ast.getNode(name_idx);
            const var_name = self.ast.getText(var_name_node.span);
            try self.write(ns_name);
            try self.writeByte('.');
            try self.write(var_name);
            try self.writeByte('=');
            try self.emitNode(init_idx);
            try self.writeByte(';');
        }
    }

    /// export 선언에서 이름을 추출하여 ns_export_map에 등록.
    fn collectExportNames(self: *Codegen, map: *std.StringHashMapUnmanaged(void), decl_idx: NodeIndex) !void {
        const decl = self.ast.getNode(decl_idx);
        switch (decl.tag) {
            .variable_declaration => {
                const e = decl.data.extra;
                const list_start = self.ast.extra_data.items[e + 1];
                const list_len = self.ast.extra_data.items[e + 2];
                const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
                for (declarators) |raw_idx| {
                    const declarator = self.ast.getNode(@enumFromInt(raw_idx));
                    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[declarator.data.extra]);
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.getText(name_node.span);
                    try map.put(self.allocator, name, {});
                }
            },
            .function_declaration, .class_declaration => {
                const e = decl.data.extra;
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                if (!name_idx.isNone()) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.getText(name_node.span);
                    try map.put(self.allocator, name, {});
                }
            },
            else => {},
        }
    }

    fn emitInt(self: *Codegen, value: i64) !void {
        var buf: [20]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try self.buf.appendSlice(self.allocator, result);
    }

    // ================================================================
    // 리스트 헬퍼
    // ================================================================

    fn emitList(self: *Codegen, node: Node, sep: []const u8) !void {
        const list = node.data.list;
        try self.emitNodeList(list.start, list.len, sep);
    }

    fn emitNodeList(self: *Codegen, start: u32, len: u32, sep: []const u8) !void {
        if (len == 0) return;
        const indices = self.ast.extra_data.items[start .. start + len];
        var first = true;
        for (indices) |raw_idx| {
            const node_idx: NodeIndex = @enumFromInt(raw_idx);
            if (node_idx.isNone()) continue;
            if (!first) try self.write(sep);
            first = false;
            try self.emitNode(node_idx);
        }
    }
};
