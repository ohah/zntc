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
    pub inline fn listSep(self: *const Codegen) []const u8 {
        return if (self.options.minify_whitespace) "," else ", ";
    }

    pub fn write(self: *Codegen, s: []const u8) !void {
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

    pub fn writeByte(self: *Codegen, b: u8) !void {
        try self.buf.append(self.allocator, b);
        if (b == '\n') {
            self.gen_line += 1;
            self.gen_col = 0;
        } else {
            self.gen_col += 1;
        }
    }

    fn trimTrailingSemicolonBeforeMinifyBoundary(self: *Codegen) void {
        if (!self.options.minify_whitespace) return;
        if (!self.options.minify_syntax) return;
        if (self.buf.items.len == 0) return;
        if (self.buf.items[self.buf.items.len - 1] != ';') return;
        _ = self.buf.pop();
        if (self.gen_col > 0) self.gen_col -= 1;
    }

    // ================================================================
    // Function Map 도우미
    // ================================================================

    /// 현재 generated position으로 새 이름 frame에 진입. builder 에 intern 된 owned
    /// slice 를 fn_name_stack 에 borrow push.
    /// 이름이 바뀔 때만 FunctionMapBuilder.push 호출 (중복 제거는 FunctionMapBuilder가 담당).
    fn fnMapEnter(self: *Codegen, name: []const u8) !void {
        if (self.fn_map_builder == null) return;
        const interned = try self.fn_map_builder.?.internedName(name);
        try self.fn_name_stack.append(self.allocator, interned);
        errdefer _ = self.fn_name_stack.pop();
        try self.fn_map_builder.?.push(.{
            .name = interned,
            .line = self.gen_line + 1, // FunctionMapBuilder는 1-based
            .column = self.gen_col,
        });
    }

    /// 현재 generated position으로 frame 종료. fn_name_stack pop (entry 는 builder 가 소유 — free 안 함).
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
    pub fn isFunctionLike(self: *const Codegen, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        return switch (self.ast.getNode(idx).tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .class_declaration, .class_expression => true,
            else => false,
        };
    }

    /// MemberExpression/identifier의 leaf 이름 추출 (assignment left 용). 항상 owned UTF-8
    /// 반환, caller 가 free.
    /// `a.b.c` → "c", `a["str"]` → "str", `a[expr]` → null
    fn resolveMemberLeafName(self: *const Codegen, idx: NodeIndex) !?[]u8 {
        if (idx.isNone()) return null;
        const n = self.ast.getNode(idx);
        return switch (n.tag) {
            .identifier_reference, .assignment_target_identifier, .binding_identifier => try self.allocator.dupe(u8, self.ast.getText(n.data.string_ref)),
            .static_member_expression => blk: {
                const e = n.data.extra;
                if (!self.ast.hasExtra(e, 2)) break :blk null;
                const property = self.ast.readExtraNode(e, 1);
                break :blk try self.ast.staticKeyName(self.allocator, property);
            },
            .computed_member_expression => blk: {
                const e = n.data.extra;
                if (!self.ast.hasExtra(e, 2)) break :blk null;
                const property = self.ast.readExtraNode(e, 1);
                break :blk try self.ast.staticKeyName(self.allocator, property);
            },
            else => null,
        };
    }

    /// fn_name_stack top (현재 class 이름). <global>/<anonymous> 이면 null.
    fn resolveParentClassName(self: *const Codegen) ?[]const u8 {
        const stack = self.fn_name_stack.items;
        if (stack.len == 0) return null;
        const top = stack[stack.len - 1];
        if (std.mem.eql(u8, top, "<global>") or std.mem.eql(u8, top, "<anonymous>")) return null;
        return top;
    }

    /// method_definition 키 + flags → Metro 스타일 이름 생성. 항상 owned UTF-8 반환,
    /// caller 가 free.
    /// getter → "get__name", setter → "set__name", constructor → class 이름.
    /// 부모 class 이름이 있으면 "ClassName#method" / "ClassName.method" 형태.
    fn resolveMethodName(self: *Codegen, key: NodeIndex, flags: u32) ![]u8 {
        const is_getter = flags & ast_mod.MethodFlags.is_getter != 0;
        const is_setter = flags & ast_mod.MethodFlags.is_setter != 0;
        const is_static = flags & ast_mod.MethodFlags.is_static != 0;
        const sep: []const u8 = if (is_static) "." else "#";

        const raw_owned: []u8 = (try self.ast.staticKeyName(self.allocator, key)) orelse
            try self.allocator.dupe(u8, "<anonymous>");
        defer self.allocator.free(raw_owned);
        const raw: []const u8 = raw_owned;

        // constructor → 부모 class 이름
        if (std.mem.eql(u8, raw, "constructor")) {
            const parent = self.resolveParentClassName();
            return try self.allocator.dupe(u8, parent orelse "constructor");
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
        return if (class_name) |cn|
            std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ cn, sep, raw })
        else
            try self.allocator.dupe(u8, raw);
    }

    /// 소스맵 매핑 추가. 노드의 소스 span과 현재 출력 위치를 매핑.
    /// string_table span (bit 31 설정)은 합성 노드이므로 매핑 스킵.
    pub fn addSourceMapping(self: *Codegen, span: Span) !void {
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
            .number => try self.write(cv.number_text),
            .none => {},
        }
    }

    pub fn writeSpan(self: *Codegen, span: Span) !void {
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
    pub fn writeNodeSpan(self: *Codegen, node: Node) !void {
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
    // Statement/comment emission — codegen/statements.zig로 위임
    // ================================================================
    const statement_emit = @import("statements.zig");
    const emitComments = statement_emit.emitComments;
    const isSkipped = statement_emit.isSkipped;
    const evalBooleanCondition = statement_emit.evalBooleanCondition;
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
            self.pending_fn_name = try self.resolveMemberLeafName(node.data.binary.left);
            defer {
                if (self.pending_fn_name) |s| self.allocator.free(s);
                self.pending_fn_name = saved;
            }
            try self.emitNode(right);
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
            if (self.identifierHasRename(key) or self.identifierHasConstValue(key)) {
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
                self.pending_fn_name = try self.ast.staticKeyName(self.allocator, key);
                defer {
                    if (self.pending_fn_name) |s| self.allocator.free(s);
                    self.pending_fn_name = saved;
                }
                try self.emitNode(value);
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

    fn identifierHasConstValue(self: *Codegen, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        if (self.options.linking_metadata) |meta| {
            if (self.resolveSymbolId(idx, meta)) |sym_id| {
                if (meta.const_values.get(sym_id)) |cv| return cv.isSafeToInline();
            }
        }
        return false;
    }

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
                // import.meta.hot → __zntc_make_hot("dev_id") (dev mode HMR)
                if (self.options.dev_module_id) |dev_id| {
                    if (std.mem.eql(u8, prop_text, "hot")) {
                        try self.write("__zntc_make_hot(\"");
                        try self.write(dev_id);
                        try self.write("\")");
                        return;
                    }
                }
                // import.meta.* polyfill (CJS/non-ESM)
                if (self.options.module_format == .cjs or self.options.replace_import_meta) {
                    if (std.mem.eql(u8, prop_text, "url")) {
                        try self.writeImportMetaUrl();
                        return;
                    }
                    if (self.options.platform == .node) {
                        if (std.mem.eql(u8, prop_text, "dirname")) {
                            try self.write("__dirname");
                            return;
                        } else if (std.mem.eql(u8, prop_text, "filename")) {
                            try self.write("__filename");
                            return;
                        }
                    } else {
                        // browser/neutral: 빈 문자열
                        if (std.mem.eql(u8, prop_text, "dirname") or std.mem.eql(u8, prop_text, "filename")) {
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

    // ================================================================
    // Call/new/import.meta/require emission — codegen/calls.zig로 위임
    // ================================================================
    const call_emit = @import("calls.zig");
    const emitCall = call_emit.emitCall;
    const emitNew = call_emit.emitNew;
    const emitMetaProperty = call_emit.emitMetaProperty;
    const emitImportExpr = call_emit.emitImportExpr;
    const resolveImportMetaProp = call_emit.resolveImportMetaProp;
    const writeImportMetaUrl = call_emit.writeImportMetaUrl;
    pub const resolveRequireRewriteSpecifier = call_emit.resolveRequireRewriteSpecifier;
    pub const emitRewriteValue = call_emit.emitRewriteValue;
    pub const emitRequireRewriteOrCall = call_emit.emitRequireRewriteOrCall;

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
        // flags 슬롯 (extras[e+2]) 의 `is_pure` bit 가 켜져 있으면 `/* @__PURE__ */`
        // annotation emit. minifier (Terser/esbuild/rolldown) 가 미사용 tagged template
        // 호출을 dead-code elimination 가능 (styled-components `pure` 옵션 등).
        if (e + 2 < extras.len) {
            const TaggedTemplateFlags = ast_mod.TaggedTemplateFlags;
            const flags = extras[e + 2];
            const is_pure = (flags & TaggedTemplateFlags.is_pure) != 0;
            if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");
        }
        try self.emitNode(@enumFromInt(extras[e]));
        try self.emitNode(@enumFromInt(extras[e + 1]));
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

        // function map: contextual name 소비 후 진입. saved_pending 은 owned 를 보관하다가
        // 종료 시 ownership 복원만 한다 (free 책임은 set 한 caller scope 에 있다).
        const saved_pending = self.pending_fn_name;
        self.pending_fn_name = null;
        defer self.pending_fn_name = saved_pending;
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

        // #1751: assignment 로 변환된 form 은 expression statement 라서 `;` 종결 필요.
        // 다음 statement 가 directive ("use strict") 처럼 ASI 로 구분 안 되는 경우
        // 문법 오류 유발. function declaration 원형은 `}` 로 충분하지만 변환형은 아님.
        if (convert_fn_to_assign) try self.writeByte(';');

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
        defer self.pending_fn_name = saved_pending;
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
        defer self.pending_fn_name = saved_pending;
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

        // #2198: cycle 모듈의 top-level class declaration → `var X = class { ... }`.
        // class declaration 자체가 block-scoped 라 `var` 강등으로는 부족, class
        // expression 으로 변환해야 hoist 가능 (esbuild 호환). decorator 가 있으면
        // 출력 순서가 `var X = ` → decorator → `class` → body 라 결과는
        // `var X = @dec class {...}` — Stage 3 decorator spec 의 inline class
        // expression decorator 가 valid 라서 syntax 깨지지 않음.
        const convert_to_var_class_expr = self.options.force_var_for_cycle and
            !convert_to_assign and
            node.tag == .class_declaration and
            !name.isNone() and
            self.indent_level == 0;

        if (convert_to_assign) {
            try self.emitNode(name);
            try self.write(" = ");
        } else if (convert_to_var_class_expr) {
            try self.write("var ");
            try self.emitNode(name);
            try self.writeSpace();
            try self.writeByte('=');
            try self.writeSpace();
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
        // var X = class { ... } 으로 변환 시 inner name 은 emit 안 함 (anonymous expression).
        // .name 프로퍼티는 spec 의 NamedEvaluation 으로 외부 var 이름 ("X") 으로 fallback.
        if (!name.isNone() and !convert_to_var_class_expr) {
            try self.writeByte(' ');
            try self.emitNode(name);
        }
        if (!super_class.isNone()) {
            try self.write(" extends ");
            try self.emitNode(super_class);
        }
        try self.emitNode(body);

        if (convert_to_assign or convert_to_var_class_expr) {
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
    // 파서 원본 노드는 writeNodeSpan, 합성 노드(span={0,0})와 minify 모드는
    // 마지막 세미콜론 트리밍을 위해 AST 기반으로 출력한다.
    fn emitStaticBlock(self: *Codegen, node: Node) !void {
        const has_parser_span = node.span.start != 0 or node.span.end != 0;
        const minify = self.options.minify_whitespace and self.options.minify_syntax;
        if (has_parser_span and !minify) {
            try self.writeNodeSpan(node);
            return;
        }
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
            defer self.allocator.free(method_name);
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
                self.pending_fn_name = try self.ast.staticKeyName(self.allocator, key);
                defer {
                    if (self.pending_fn_name) |s| self.allocator.free(s);
                    self.pending_fn_name = saved;
                }
                try self.emitNode(value);
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

    fn emitList(self: *Codegen, node: Node, sep: []const u8) !void {
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
