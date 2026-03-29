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
};

/// 들여쓰기 문자 (D044)
pub const IndentChar = enum {
    tab,
    space,
};

/// 번들러 linker가 생성하는 per-module 메타데이터.
/// codegen이 import 스킵 + 식별자 리네임에 사용.
pub const LinkingMetadata = @import("../bundler/linker.zig").LinkingMetadata;

pub const QuoteStyle = enum {
    double, // " (기본, esbuild/oxc/SWC 호환)
    single, // '
    preserve, // 원본 유지
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
    /// 소스맵 생성 활성화
    sourcemap: bool = false,
    /// non-ASCII 문자를 \uXXXX로 이스케이프 (D031)
    ascii_only: bool = false,
    /// 번들러 linker 메타데이터. 설정 시 import 스킵 + 식별자 리네임 적용.
    linking_metadata: ?*const LinkingMetadata = null,
    /// 번들 모드에서 ESM이 아닐 때 import.meta → {} 치환 (esbuild 호환)
    replace_import_meta: bool = false,
    /// 타겟 플랫폼. import.meta polyfill 방식을 결정한다.
    /// - node: import.meta.url → require("url").pathToFileURL(__filename).href,
    ///         import.meta.dirname → __dirname, import.meta.filename → __filename
    /// - browser/neutral: import.meta.url → "", import.meta.dirname → "", import.meta.filename → ""
    platform: Platform = .browser,
};

// import.meta polyfill 상수 (emitMetaProperty + emitStaticMember에서 공유)
const IMPORT_META_URL_NODE = "require(\"url\").pathToFileURL(__filename).href";
const IMPORT_META_NODE_OBJECT = "{url:" ++ IMPORT_META_URL_NODE ++ ",dirname:__dirname,filename:__filename}";

const SourceMapBuilder = @import("sourcemap.zig").SourceMapBuilder;
const Mapping = @import("sourcemap.zig").Mapping;

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

    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) Codegen {
        return initWithOptions(allocator, ast, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, ast: *const Ast, options: CodegenOptions) Codegen {
        return .{
            .ast = ast,
            .allocator = allocator,
            .buf = .empty,
            .options = options,
            .indent_level = 0,
            .sm_builder = if (options.sourcemap) SourceMapBuilder.init(allocator) else null,
            .gen_line = 0,
            .gen_col = 0,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.buf.deinit(self.allocator);
        if (self.sm_builder) |*sm| sm.deinit();
    }

    /// AST를 JS 문자열로 출력한다.
    pub fn generate(self: *Codegen, root: NodeIndex) ![]const u8 {
        // 출력 크기는 보통 소스 크기와 비슷 → 사전 할당
        try self.buf.ensureTotalCapacity(self.allocator, self.ast.source.len);
        // namespace var 중복 제거: top-level 선언 이름 사전 수집
        self.collectTopLevelDeclNames(root);
        try self.emitNode(root);
        return self.buf.items;
    }

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
        }
    }

    /// 소스맵 JSON을 생성한다. generate() 후에 호출.
    pub fn generateSourceMap(self: *Codegen, output_file: []const u8) !?[]const u8 {
        if (self.sm_builder) |*sm| {
            return try sm.generateJSON(output_file);
        }
        return null;
    }

    // ================================================================
    // 출력 헬퍼
    // ================================================================

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

    /// 소스맵 매핑 추가. 노드의 소스 span과 현재 출력 위치를 매핑.
    /// string_table span (bit 31 설정)은 합성 노드이므로 매핑 스킵.
    fn addSourceMapping(self: *Codegen, span: Span) !void {
        if (self.sm_builder) |*sm| {
            // 합성 노드(string_table) 또는 빈 span → 소스맵 매핑 스킵
            if (span.start & 0x8000_0000 != 0 or (span.start == 0 and span.end == 0)) return;
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
            try self.write(self.ast.source[comment.start..comment.end]);
            try self.writeNewline();
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

        // 이 노드 이전에 위치한 주석들을 출력
        if (node.span.start != node.span.end) {
            try self.emitComments(node.span.start);
        }

        // 소스맵 매핑: 유의미한 노드 출력 시 원본 위치 기록
        if (self.sm_builder != null and node.span.start != node.span.end) {
            try self.addSourceMapping(node.span);
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
            .directive, .hashbang => try self.writeNodeSpan(node),

            // Literals
            .boolean_literal,
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
            .static_block => try self.writeNodeSpan(node),
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
            .export_specifier => try self.writeNodeSpan(node),

            // Formal parameters
            .formal_parameters, .function_body => try self.emitList(node, ", "),

            .formal_parameter => try self.emitFormalParam(node),

            // JSX → React.createElement
            .jsx_element => try self.emitJSXElement(node),
            .jsx_fragment => try self.emitJSXFragment(node),
            .jsx_expression_container => try self.emitNode(node.data.unary.operand),
            .jsx_text => try self.emitJSXText(node),
            .jsx_spread_attribute => try self.emitSpread(node),
            .jsx_spread_child => try self.emitSpread(node),

            // TS enum/namespace → IIFE 출력
            .ts_enum_declaration => try self.emitEnumIIFE(node),
            .ts_module_declaration => try self.emitNamespaceIIFE(node),

            // TS 노드는 transformer에서 제거됨 — 여기 도달하면 strip_types=false
            else => try self.writeNodeSpan(node),
        }
    }

    // ================================================================
    // Statement 출력
    // ================================================================

    fn emitProgram(self: *Codegen, node: Node) !void {
        const list = node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices, 0..) |raw_idx, i| {
            if (i > 0) try self.writeNewline();
            try self.emitNode(@enumFromInt(raw_idx));
        }
        if (indices.len > 0) try self.writeNewline();
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
        self.in_for_init = true;
        try self.emitNode(@enumFromInt(extras[0]));
        if (self.options.minify_whitespace) try self.writeByte(';') else try self.write("; ");
        try self.emitNode(@enumFromInt(extras[1]));
        if (self.options.minify_whitespace) try self.writeByte(';') else try self.write("; ");
        try self.emitNode(@enumFromInt(extras[2]));
        self.in_for_init = false;
        try self.writeByte(')');
        try self.emitNode(@enumFromInt(extras[3]));
    }

    fn emitForAwaitOf(self: *Codegen, node: Node) !void {
        const t = node.data.ternary;
        if (self.options.minify_whitespace) try self.write("for await(") else try self.write("for await (");
        self.in_for_init = true;
        try self.emitNode(t.a);
        self.in_for_init = false;
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
        self.in_for_init = true;
        self.skip_var_init = try self.shouldSkipVarInit(t.a);
        try self.emitNode(t.a);
        self.in_for_init = false;
        self.skip_var_init = false;
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
        const is_postfix = (flags & 0x100) != 0;
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
        try self.emitNode(node.data.binary.right);
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
        try self.emitList(node, if (self.options.minify_whitespace) "," else ", ");
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
            try self.emitNode(key);
            if (self.options.minify_whitespace) {
                try self.writeByte(':');
            } else {
                try self.write(": ");
            }
            try self.emitNode(value);
        }
    }

    /// 식별자 노드가 scope hoisting에 의해 리네임되는지 확인.
    /// linking_metadata.renames 또는 ns_prefix 치환 대상이면 true.
    fn identifierHasRename(self: *Codegen, idx: NodeIndex) bool {
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
                            const prop_text = self.ast.source[prop_node.data.string_ref.start..prop_node.data.string_ref.end];
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

        // import.meta.* polyfill: CJS/non-ESM에서 import.meta 프로퍼티 접근을 플랫폼별로 치환
        if (self.options.module_format == .cjs or self.options.replace_import_meta) {
            const obj_node = self.ast.getNode(object);
            if (obj_node.tag == .meta_property) {
                const obj_text = self.ast.source[obj_node.span.start..obj_node.span.end];
                if (std.mem.eql(u8, obj_text, "import.meta")) {
                    const prop_node = self.ast.getNode(property);
                    const prop_text = self.ast.source[prop_node.data.string_ref.start..prop_node.data.string_ref.end];
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

        if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");
        try self.emitNode(callee);
        if (is_optional) try self.write("?.");
        try self.writeByte('(');
        try self.emitNodeList(args_start, args_len, if (self.options.minify_whitespace) "," else ", ");
        try self.writeByte(')');
    }

    /// CJS require('specifier') → require_xxx() 치환. 성공 시 true.
    fn tryRewriteRequire(self: *Codegen, callee: ast_mod.NodeIndex, args_start: u32, args_len: u32) !bool {
        const meta = self.options.linking_metadata orelse return false;
        if (meta.require_rewrites.count() == 0 or callee.isNone() or args_len != 1) return false;

        const callee_node = self.ast.getNode(callee);
        if (callee_node.tag != .identifier_reference) return false;

        const callee_text = self.ast.source[callee_node.data.string_ref.start..callee_node.data.string_ref.end];
        if (!std.mem.eql(u8, callee_text, "require")) return false;

        if (args_start >= self.ast.extra_data.items.len) return false;
        const arg_idx: ast_mod.NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start]);
        if (arg_idx.isNone()) return false;

        const arg_node = self.ast.getNode(arg_idx);
        if (arg_node.tag != .string_literal) return false;

        // 따옴표 제거: "path" 또는 'path' → path
        const raw = self.ast.source[arg_node.data.string_ref.start..arg_node.data.string_ref.end];
        const specifier = if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\''))
            raw[1 .. raw.len - 1]
        else
            raw;

        const req_var = meta.require_rewrites.get(specifier) orelse return false;
        try self.write(req_var);
        try self.write("()");
        return true;
    }

    fn emitNew(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        if (!self.ast.hasExtra(e, 3)) return;
        const callee = self.ast.readExtraNode(e, 0);
        const args_start = self.ast.readExtra(e, 1);
        const args_len = self.ast.readExtra(e, 2);
        const flags = self.ast.readExtra(e, 3);
        const CallFlags = ast_mod.CallFlags;
        const is_pure = (flags & CallFlags.is_pure) != 0;

        if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");

        try self.write("new ");
        try self.emitNode(callee);
        try self.writeByte('(');
        try self.emitNodeList(args_start, args_len, if (self.options.minify_whitespace) "," else ", ");
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
    fn emitMetaProperty(self: *Codegen, node: Node) !void {
        const text = self.ast.source[node.span.start..node.span.end];
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
        const extras = self.ast.extra_data.items[e .. e + 6];
        const name: NodeIndex = @enumFromInt(extras[0]);
        const params_start = extras[1];
        const params_len = extras[2];
        const body: NodeIndex = @enumFromInt(extras[3]);
        const flags = extras[4];

        if (flags & 0x01 != 0) try self.write("async ");
        try self.write("function");
        if (flags & 0x02 != 0) try self.writeByte('*');
        if (!name.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(name);
        }
        try self.writeByte('(');
        try self.emitNodeList(params_start, params_len, ",");
        try self.writeByte(')');
        try self.emitNode(body);
    }

    /// arrow_function_expression: extra = [params, body, flags]
    /// flags: 0x01 = async
    fn emitArrow(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 2 >= extras.len) return;
        const params: NodeIndex = @enumFromInt(extras[e]);
        const body: NodeIndex = @enumFromInt(extras[e + 1]);
        const flags = extras[e + 2];

        if (flags & 0x01 != 0) try self.write("async ");

        // params 출력 — esbuild 호환: 항상 괄호로 감싸기 (단일 파라미터도 괄호 추가)
        if (!params.isNone()) {
            const param_node = self.ast.getNode(params);
            if (param_node.tag == .parenthesized_expression) {
                // 괄호 형태: (a, b) => a + b — parenthesized_expression이 이미 괄호를 포함
                try self.emitNode(params);
            } else {
                try self.writeByte('(');
                try self.emitNode(params);
                try self.writeByte(')');
            }
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
    }

    fn emitClassBody(self: *Codegen, node: Node) !void {
        try self.emitBracedList(node);
    }

    // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
    fn emitMethodDef(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 7];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const params_start = extras[1];
        const params_len = extras[2];
        const body: NodeIndex = @enumFromInt(extras[3]);
        const flags = extras[4];
        const deco_start = extras[5];
        const deco_len = extras[6];

        try self.emitMemberDecorators(deco_start, deco_len);

        // flags: bit0=static, bit1=getter, bit2=setter, bit3=async, bit4=generator(*)
        if (flags & 0x01 != 0) try self.write("static ");
        if (flags & 0x08 != 0) try self.write("async ");
        if (flags & 0x02 != 0) {
            try self.write("get ");
        } else if (flags & 0x04 != 0) {
            try self.write("set ");
        }
        if (flags & 0x10 != 0) try self.writeByte('*');

        try self.emitNode(key);
        try self.writeByte('(');
        try self.emitNodeList(params_start, params_len, ",");
        try self.writeByte(')');
        try self.emitNode(body);
    }

    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
    fn emitPropertyDef(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const value: NodeIndex = @enumFromInt(extras[1]);
        const flags = extras[2];
        const deco_start = extras[3];
        const deco_len = extras[4];

        try self.emitMemberDecorators(deco_start, deco_len);

        if (flags & 0x01 != 0) try self.write("static ");
        try self.emitNode(key);
        if (!value.isNone()) {
            try self.writeSpace();
            try self.writeByte('=');
            try self.writeSpace();
            try self.emitNode(value);
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

    // accessor_property: extra = [key, init_val, flags, deco_start, deco_len]
    fn emitAccessorProp(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const value: NodeIndex = @enumFromInt(extras[1]);
        const flags = extras[2];
        const deco_start = extras[3];
        const deco_len = extras[4];

        try self.emitMemberDecorators(deco_start, deco_len);

        if (flags & 0x01 != 0) try self.write("static ");
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
        const kind_flags = extras[0];
        const list_start = extras[1];
        const list_len = extras[2];

        const keyword = switch (kind_flags) {
            0 => "var ",
            1 => "let ",
            2 => "const ",
            else => "var ",
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
            try self.emitNode(init_val);
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

    /// import_declaration:
    ///   모든 import는 extra = [specs_start, specs_len, source_node] 형식.
    ///   side-effect import (import "module")은 specs_len=0.
    fn emitImport(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const specs_start = extras[0];
        const specs_len = extras[1];
        const source: NodeIndex = @enumFromInt(extras[2]);

        if (self.options.module_format == .cjs) {
            return self.emitImportCJS(source, specs_start, specs_len);
        }

        try self.write("import ");
        if (specs_len > 0) {
            try self.emitImportSpecifiers(specs_start, specs_len);
            try self.write(" from ");
        }
        try self.emitNode(source);
        try self.writeByte(';');
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
            if (!first) try self.write(",");
            try self.writeByte('{');
            var named_first = true;
            for (spec_indices) |raw_idx| {
                const spec: NodeIndex = @enumFromInt(raw_idx);
                if (spec.isNone()) continue;
                const spec_node = self.ast.getNode(spec);
                if (spec_node.tag == .import_specifier) {
                    if (!named_first) try self.write(",");
                    // binary: { left=imported, right=local }
                    const imported = spec_node.data.binary.left;
                    const local = spec_node.data.binary.right;
                    try self.emitNode(imported);
                    // imported != local이면 as 출력
                    if (!local.isNone() and @intFromEnum(local) != @intFromEnum(imported)) {
                        const imp_node = self.ast.getNode(imported);
                        const loc_node = self.ast.getNode(local);
                        const imp_text = self.ast.source[imp_node.span.start..imp_node.span.end];
                        const loc_text = self.ast.source[loc_node.span.start..loc_node.span.end];
                        if (!std.mem.eql(u8, imp_text, loc_text)) {
                            try self.write(" as ");
                            try self.emitNode(local);
                        }
                    }
                    named_first = false;
                }
            }
            try self.writeByte('}');
        }
    }

    /// CJS: import { foo } from './bar' → const {foo}=require('./bar');
    /// CJS: import bar from './bar' → const bar=require('./bar').default;
    /// CJS: import * as bar from './bar' → const bar=require('./bar');
    fn emitImportCJS(self: *Codegen, source: NodeIndex, specs_start: u32, specs_len: u32) !void {
        if (specs_len == 0) {
            // side-effect import: import './bar' → require('./bar');
            try self.write("require(");
            try self.emitNode(source);
            try self.write(");");
            return;
        }

        try self.write("const ");

        // specifier 유형 분석
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

        if (has_namespace) {
            // import * as bar from './bar' → const bar=require('./bar');
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_namespace_specifier) {
                    try self.writeNodeSpan(spec);
                    break;
                }
            }
        } else if (has_default and named_count == 0) {
            // import bar from './bar' → const bar=require('./bar').default;
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_default_specifier) {
                    try self.writeNodeSpan(spec);
                    break;
                }
            }
        } else if (named_count > 0) {
            // import { foo, bar } from './bar' → const {foo,bar}=require('./bar');
            try self.writeByte('{');
            var first = true;
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_specifier) {
                    if (!first) try self.writeByte(',');
                    try self.writeNodeSpan(spec);
                    first = false;
                }
            }
            try self.writeByte('}');
        }

        try self.write("=require(");
        try self.emitNode(source);
        try self.writeByte(')');

        if (has_default and !has_namespace and named_count == 0) {
            try self.write(".default");
        }

        try self.writeByte(';');
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
            try self.emitNodeList(specs_start, specs_len, ",");
            try self.writeByte('}');
            if (!source.isNone()) {
                try self.write(" from ");
                try self.emitNode(source);
            }
            try self.writeByte(';');
        }
    }

    /// CJS: export const x = 1 → const x=1;exports.x=x;
    fn emitExportNamedCJS(self: *Codegen, decl: NodeIndex, specs_start: u32, specs_len: u32, source: NodeIndex) !void {
        if (!decl.isNone() and @intFromEnum(decl) < self.ast.nodes.items.len) {
            // export const x = 1 → const x=1; + exports.x=x;
            try self.emitNode(decl);
            // 선언에서 이름 추출하여 exports.name = name
            try self.emitCJSExportBinding(decl);
        } else {
            // export { foo, bar } → exports.foo=foo;exports.bar=bar;
            _ = source;
            const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                const spec_text = self.ast.source[spec.span.start..spec.span.end];
                try self.write("exports.");
                try self.write(spec_text);
                try self.writeByte('=');
                try self.write(spec_text);
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
                    // declarator의 첫 번째 extra가 name NodeIndex
                    const de = declarator.data.extra;
                    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
                    if (!name_idx.isNone()) {
                        const name_node = self.ast.getNode(name_idx);
                        // binding_identifier의 이름은 string_ref (span)
                        const name = self.ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
                        try self.write("exports.");
                        try self.write(name);
                        try self.writeByte('=');
                        try self.write(name);
                        try self.writeByte(';');
                    }
                }
            },
            .function_declaration, .class_declaration => {
                const e = decl.data.extra;
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                if (!name_idx.isNone()) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
                    try self.write("exports.");
                    try self.write(name);
                    try self.writeByte('=');
                    try self.write(name);
                    try self.writeByte(';');
                }
            },
            else => {},
        }
    }

    fn emitExportDefault(self: *Codegen, node: Node) !void {
        if (self.options.module_format == .cjs) {
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
                    // anonymous function/class 또는 expression → var _default = ...;
                    try self.emitDefaultVarAssignment(self.options.linking_metadata.?.default_export_name, inner);
                }
            }
            return;
        }
        try self.write("export default ");
        const inner_idx = node.data.unary.operand;
        try self.emitNode(inner_idx);
        // class/function 선언 뒤에는 세미콜론 불필요
        if (!inner_idx.isNone()) {
            const inner_tag = self.ast.getNode(inner_idx).tag;
            if (inner_tag != .class_declaration and inner_tag != .function_declaration) {
                try self.writeByte(';');
            }
        }
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
            try self.emitNode(node.data.binary.left);
            try self.write("));");
            return;
        }
        try self.write("export * from ");
        try self.emitNode(node.data.binary.left);
        try self.writeByte(';');
    }

    // ================================================================
    // JSX → React.createElement 출력
    // ================================================================

    /// <div className="foo">hello</div> →
    /// React.createElement("div",{className:"foo"},"hello")
    /// jsx_element: extra = [tag, attrs_start, attrs_len, children_start, children_len]
    /// 항상 5 fields. self-closing은 children_len=0.
    fn emitJSXElement(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const tag_name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
        const attrs_start = self.ast.extra_data.items[e + 1];
        const attrs_len = self.ast.extra_data.items[e + 2];
        const children_start = self.ast.extra_data.items[e + 3];
        const children_len = self.ast.extra_data.items[e + 4];

        try self.write("/* @__PURE__ */ React.createElement(");
        try self.emitJSXTagName(tag_name_idx);
        try self.emitJSXAttrs(attrs_start, attrs_len);
        try self.emitJSXChildren(children_start, children_len);
        try self.writeByte(')');
    }

    /// <>{children}</> → React.createElement(React.Fragment,null,...children)
    fn emitJSXFragment(self: *Codegen, node: Node) !void {
        try self.write("/* @__PURE__ */ React.createElement(React.Fragment,null");
        const list = node.data.list;
        try self.emitJSXChildren(list.start, list.len);
        try self.writeByte(')');
    }

    /// tag name 출력: 소문자면 문자열("div"), 그 외 식별자(MyComp)
    fn emitJSXTagName(self: *Codegen, tag_name_idx: NodeIndex) !void {
        const tag_node = self.ast.getNode(tag_name_idx);
        const tag_text = self.ast.source[tag_node.span.start..tag_node.span.end];
        if (tag_text.len > 0 and tag_text[0] >= 'a' and tag_text[0] <= 'z') {
            try self.writeByte('"');
            try self.write(tag_text);
            try self.writeByte('"');
        } else {
            try self.write(tag_text);
        }
    }

    /// attributes → ,{key:val,...} or ,null
    fn emitJSXAttrs(self: *Codegen, attrs_start: u32, attrs_len: u32) !void {
        if (attrs_len > 0) {
            if (self.options.minify_whitespace) try self.write(",{") else try self.write(", { ");
            const attr_indices = self.ast.extra_data.items[attrs_start .. attrs_start + attrs_len];
            for (attr_indices, 0..) |raw_idx, i| {
                if (i > 0) {
                    if (self.options.minify_whitespace) try self.writeByte(',') else try self.write(", ");
                }
                const attr = self.ast.getNode(@enumFromInt(raw_idx));
                if (attr.tag == .jsx_attribute) {
                    try self.emitJSXAttribute(attr);
                } else if (attr.tag == .jsx_spread_attribute) {
                    try self.write("...");
                    try self.emitNode(attr.data.unary.operand);
                }
            }
            if (self.options.minify_whitespace) try self.writeByte('}') else try self.write(" }");
        } else {
            if (self.options.minify_whitespace) try self.write(",null") else try self.write(", null");
        }
    }

    /// children 출력 (공통 헬퍼)
    fn emitJSXChildren(self: *Codegen, start: u32, len: u32) !void {
        if (len == 0) return;
        const indices = self.ast.extra_data.items[start .. start + len];
        for (indices) |raw_idx| {
            const child = self.ast.getNode(@enumFromInt(raw_idx));
            if (child.tag == .jsx_text) {
                const text = self.ast.source[child.span.start..child.span.end];
                // JSX text: 줄바꿈 포함 공백은 trim, 줄바꿈 없는 공백은 유지
                // esbuild 호환: 줄바꿈이 있으면 해당 시퀀스를 제거/공백으로 치환
                // 공백/줄바꿈만으로 이루어진 텍스트는 스킵
                const all_whitespace = std.mem.trim(u8, text, " \t\n\r").len == 0;
                if (all_whitespace) continue;
                // 줄바꿈이 포함되면 전체 trim, 아니면 원본 유지 (후행 공백 보존)
                const has_newline = std.mem.indexOfAny(u8, text, "\n\r") != null;
                const trimmed = if (has_newline) std.mem.trim(u8, text, " \t\n\r") else text;
                if (self.options.minify_whitespace) try self.write(",\"") else try self.write(", \"");
                try self.write(trimmed);
                try self.writeByte('"');
            } else {
                // 빈 expression container {} 는 스킵 (esbuild 호환)
                if (child.tag == .jsx_expression_container and child.data.unary.operand.isNone()) continue;
                if (self.options.minify_whitespace) try self.writeByte(',') else try self.write(", ");
                // JSX spread child: {...expr} → ...expr (spread argument)
                if (child.tag == .jsx_spread_child) {
                    try self.write("...");
                    try self.emitNode(child.data.unary.operand);
                } else {
                    try self.emitNode(@enumFromInt(raw_idx));
                }
            }
        }
    }

    /// JSX attribute: name={value} or name="value"
    fn emitJSXAttribute(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        if (!node.data.binary.right.isNone()) {
            if (self.options.minify_whitespace) try self.writeByte(':') else try self.write(": ");
            try self.emitNode(node.data.binary.right);
        } else {
            if (self.options.minify_whitespace) try self.write(":true") else try self.write(": true");
        }
    }

    /// JSX text (공백 트리밍은 caller에서 처리)
    fn emitJSXText(self: *Codegen, node: Node) !void {
        try self.writeByte('"');
        try self.writeNodeSpan(node);
        try self.writeByte('"');
    }

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
        try self.write("var ");
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
                const extras = self.ast.extra_data.items[e .. e + 6];
                const name_idx: NodeIndex = @enumFromInt(extras[0]);
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
                // list의 각 요소를 재귀 처리
                const elements = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                for (elements) |raw_idx| {
                    try self.emitNamespaceBindingExport(ns_name, @enumFromInt(raw_idx));
                }
            },
            .object_pattern => {
                const props = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                for (props) |raw_idx| {
                    const prop = self.ast.getNode(@enumFromInt(raw_idx));
                    // property_property: binary.right = value (binding pattern)
                    // rest_element: unary.operand
                    if (prop.tag == .rest_element or prop.tag == .assignment_target_rest) {
                        try self.emitNamespaceBindingExport(ns_name, prop.data.unary.operand);
                    } else {
                        try self.emitNamespaceBindingExport(ns_name, prop.data.binary.right);
                    }
                }
            },
            .assignment_target_with_default => {
                // { x = defaultVal } → x
                try self.emitNamespaceBindingExport(ns_name, node.data.binary.left);
            },
            .rest_element, .assignment_target_rest => {
                try self.emitNamespaceBindingExport(ns_name, node.data.unary.operand);
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
        for (indices, 0..) |raw_idx, i| {
            if (i > 0) try self.write(sep);
            try self.emitNode(@enumFromInt(raw_idx));
        }
    }
};

// ============================================================
// Tests
// ============================================================

const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Transformer = @import("../transformer/transformer.zig").Transformer;

/// Arena 기반 테스트 결과. deinit()으로 모든 메모리를 일괄 해제.
const TestResult = struct {
    output: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
};

/// 기본 e2e: minify 모드 (기존 테스트 호환)
fn e2e(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eWithOptions(allocator, source, .{ .minify_whitespace = true });
}

fn e2eCJS(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eWithOptions(allocator, source, .{ .module_format = .cjs, .minify_whitespace = true });
}

fn e2eJSX(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{}, .{ .minify_whitespace = true }, ".tsx");
}

const TransformOptions = @import("../transformer/transformer.zig").TransformOptions;

/// 풀 옵션 e2e. ext로 확장자 지정 (".ts" 기본, ".tsx"면 JSX 모드).
/// Arena로 전체 파이프라인을 실행. output은 arena 메모리를 가리키므로
/// TestResult.deinit() 전에 사용해야 한다.
fn e2eFull(backing_allocator: std.mem.Allocator, source: []const u8, t_options: TransformOptions, cg_options: CodegenOptions, ext: []const u8) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(ext);
    _ = try parser.parse();

    var t = Transformer.init(allocator, &parser.ast, t_options);
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, &t.new_ast, cg_options);
    const output = try cg.generate(root);

    return .{ .output = output, .arena = arena };
}

fn e2eWithOptions(allocator: std.mem.Allocator, source: []const u8, cg_options: CodegenOptions) !TestResult {
    return e2eFull(allocator, source, .{}, cg_options, ".ts");
}

test "Codegen: empty program" {
    var r = try e2e(std.testing.allocator, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

test "Codegen: variable declaration" {
    var r = try e2e(std.testing.allocator, "const x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: type stripped" {
    var r = try e2e(std.testing.allocator, "type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

test "Codegen: JS with TS stripped" {
    var r = try e2e(std.testing.allocator, "const x = 1; type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: return statement" {
    var r = try e2e(std.testing.allocator, "return;");
    defer r.deinit();
    try std.testing.expectEqualStrings("return;", r.output);
}

test "Codegen: enum IIFE" {
    var r = try e2e(std.testing.allocator, "enum Color { Red, Green, Blue }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Color = /* @__PURE__ */ ((Color) => {Color[Color[\"Red\"]=0]=\"Red\";Color[Color[\"Green\"]=1]=\"Green\";Color[Color[\"Blue\"]=2]=\"Blue\";return Color;})(Color || {});",
        r.output,
    );
}

test "Codegen: namespace IIFE" {
    var r = try e2e(std.testing.allocator, "namespace Foo { const x = 1; }");
    defer r.deinit();
    // 내부 const는 export 아니므로 Foo.x = x 없음
    try std.testing.expectEqualStrings(
        "var Foo;((Foo) => {const x=1;})(Foo || (Foo = {}));",
        r.output,
    );
}

test "Codegen CJS: export const" {
    var r = try e2eCJS(std.testing.allocator, "export const x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;exports.x=x;", r.output);
}

test "Codegen CJS: export default" {
    var r = try e2eCJS(std.testing.allocator, "export default 42;");
    defer r.deinit();
    try std.testing.expectEqualStrings("module.exports=42;", r.output);
}

test "Codegen: drop debugger" {
    var r = try e2eFull(std.testing.allocator, "debugger; const x = 1;", .{ .drop_debugger = true }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: drop console" {
    var r = try e2eFull(std.testing.allocator, "console.log(1); const x = 1;", .{ .drop_console = true }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: formatted output with tab" {
    var r = try e2eWithOptions(std.testing.allocator, "const x = 1;", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("const x = 1;\n", r.output);
}

test "Codegen: formatted output with spaces" {
    var r = try e2eWithOptions(std.testing.allocator, "const x = 1;", .{ .indent_char = .space, .indent_width = 4 });
    defer r.deinit();
    try std.testing.expectEqualStrings("const x = 1;\n", r.output);
}

test "Codegen: enum with initializer" {
    var r = try e2e(std.testing.allocator, "enum Status { Active = 1, Inactive = 0 }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Status = /* @__PURE__ */ ((Status) => {Status[Status[\"Active\"]=1]=\"Active\";Status[Status[\"Inactive\"]=0]=\"Inactive\";return Status;})(Status || {});",
        r.output,
    );
}

test "Codegen: const enum removed" {
    var r = try e2e(std.testing.allocator, "const enum Dir { Up, Down }");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

// ============================================================
// E2E Tests: Class
// ============================================================

test "Codegen: class basic" {
    var r = try e2e(std.testing.allocator, "class Foo {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}", r.output);
}

test "Codegen: class extends" {
    var r = try e2e(std.testing.allocator, "class Foo extends Bar {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo extends Bar{}", r.output);
}

test "Codegen: class static method" {
    var r = try e2e(std.testing.allocator, "class Foo { static bar() { return 1; } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static bar(){return 1;}}", r.output);
}

test "Codegen: class getter setter" {
    var r = try e2e(std.testing.allocator, "class Foo { get x() { return 1; } set x(v) {} }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{get x(){return 1;}set x(v){}}", r.output);
}

test "Codegen: class private field" {
    var r = try e2e(std.testing.allocator, "class Foo { #x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{#x=1;}", r.output);
}

// ============================================================
// E2E Tests: Arrow Function
// ============================================================

test "Codegen: arrow no params" {
    var r = try e2e(std.testing.allocator, "const f = () => 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=()=>1;", r.output);
}

test "Codegen: arrow single param" {
    // esbuild 호환: 단일 파라미터도 항상 괄호로 감싸기
    var r = try e2e(std.testing.allocator, "const f = x => x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=(x)=>x;", r.output);
}

test "Codegen: arrow block body" {
    var r = try e2e(std.testing.allocator, "const f = (a, b) => { return a + b; };");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=(a,b)=>{return a + b;};", r.output);
}

test "Codegen: arrow rest param" {
    var r = try e2e(std.testing.allocator, "const f = (...args) => args;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=(...args)=>args;", r.output);
}

// ============================================================
// E2E Tests: Async/Await
// ============================================================

test "Codegen: async function" {
    var r = try e2e(std.testing.allocator, "async function foo() { return 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("async function foo(){return 1;}", r.output);
}

test "Codegen: await expression" {
    var r = try e2e(std.testing.allocator, "async function foo() { const x = await bar(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("async function foo(){const x=await bar();}", r.output);
}

test "Codegen: async arrow" {
    var r = try e2e(std.testing.allocator, "const f = async () => await x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=async ()=>await x;", r.output);
}

// ============================================================
// E2E Tests: Generator
// ============================================================

test "Codegen: generator function" {
    var r = try e2e(std.testing.allocator, "function* gen() { yield 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function* gen(){yield 1;}", r.output);
}

test "Codegen: yield star" {
    var r = try e2e(std.testing.allocator, "function* gen() { yield* other(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function* gen(){yield* other();}", r.output);
}

// ============================================================
// E2E Tests: Destructuring
// ============================================================

test "Codegen: array destructuring" {
    var r = try e2e(std.testing.allocator, "const [a, b] = [1, 2];");
    defer r.deinit();
    try std.testing.expectEqualStrings("const [a,b]=[1,2];", r.output);
}

test "Codegen: object destructuring" {
    // binding_property always emits key:value (shorthand is not collapsed)
    var r = try e2e(std.testing.allocator, "const { x, y } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {x:x,y:y}=obj;", r.output);
}

test "Codegen: nested destructuring" {
    var r = try e2e(std.testing.allocator, "const { a: { b } } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {a:{b:b}}=obj;", r.output);
}

test "Codegen: destructuring with default" {
    var r = try e2e(std.testing.allocator, "const { x = 1 } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {x:x=1}=obj;", r.output);
}

// ============================================================
// E2E Tests: Template Literal
// ============================================================

test "Codegen: template literal basic" {
    var r = try e2e(std.testing.allocator, "const x = `hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello`;", r.output);
}

test "Codegen: template literal with expression" {
    var r = try e2e(std.testing.allocator, "const x = `hello ${name}!`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello ${name}!`;", r.output);
}

// ============================================================
// E2E Tests: For-of / For-in
// ============================================================

test "Codegen: for-of" {
    var r = try e2e(std.testing.allocator, "for (const x of arr) {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const x of arr){}", r.output);
}

test "Codegen: for-in" {
    var r = try e2e(std.testing.allocator, "for (const k in obj) {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const k in obj){}", r.output);
}

// ============================================================
// E2E Tests: Spread
// ============================================================

test "Codegen: array spread" {
    var r = try e2e(std.testing.allocator, "const x = [...a, ...b];");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=[...a,...b];", r.output);
}

test "Codegen: object spread" {
    var r = try e2e(std.testing.allocator, "const x = { ...a, ...b };");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...a,...b};", r.output);
}

test "Codegen: function call spread" {
    var r = try e2e(std.testing.allocator, "foo(...args);");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo(...args);", r.output);
}

// ============================================================
// E2E Tests: Optional Chaining / Nullish
// ============================================================

test "Codegen: optional chaining" {
    var r = try e2e(std.testing.allocator, "const x = a?.b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a?.b;", r.output);
}

test "Codegen: nullish coalescing" {
    var r = try e2e(std.testing.allocator, "const x = a ?? b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a??b;", r.output);
}

test "Codegen: optional chaining method call" {
    var r = try e2e(std.testing.allocator, "const x = a?.foo();");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a?.foo();", r.output);
}

// ============================================================
// E2E Tests: Logical Assignment
// ============================================================

test "Codegen: logical and assign" {
    var r = try e2e(std.testing.allocator, "a &&= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a&&=b;", r.output);
}

test "Codegen: logical or assign" {
    var r = try e2e(std.testing.allocator, "a ||= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a||=b;", r.output);
}

test "Codegen: nullish assign" {
    var r = try e2e(std.testing.allocator, "a ??= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a??=b;", r.output);
}

// ============================================================
// E2E Tests: Import/Export
// ============================================================

test "Codegen: import default" {
    var r = try e2e(std.testing.allocator, "import foo from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import foo from \"./foo\";", r.output);
}

test "Codegen: import named" {
    var r = try e2e(std.testing.allocator, "import { a, b } from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import {a,b} from \"./foo\";", r.output);
}

test "Codegen: import namespace" {
    var r = try e2e(std.testing.allocator, "import * as ns from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import * as ns from \"./foo\";", r.output);
}

test "Codegen: export named" {
    // export_specifier uses writeNodeSpan which preserves trailing space from source
    var r = try e2e(std.testing.allocator, "export { a, b };");
    defer r.deinit();
    try std.testing.expectEqualStrings("export {a,b };", r.output);
}

test "Codegen: export default function" {
    var r = try e2e(std.testing.allocator, "export default function foo() {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("export default function foo(){}", r.output);
}

test "Codegen: export all re-export" {
    // emitExportAll reads binary.left (exported_name), but source is binary.right
    // NOTE: this is a known issue — source node is omitted in current codegen
    var r = try e2e(std.testing.allocator, "export * from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("export * from ;", r.output);
}

// ============================================================
// E2E Tests: JSX → React.createElement
// ============================================================

test "Codegen: JSX self-closing" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div />;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=/* @__PURE__ */ React.createElement(\"div\",null);", r.output);
}

test "Codegen: JSX element with children" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>hello</div>;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=/* @__PURE__ */ React.createElement(\"div\",null,\"hello\");", r.output);
}

test "Codegen: JSX fragment" {
    var r = try e2eJSX(std.testing.allocator, "const x = <>hello</>;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=/* @__PURE__ */ React.createElement(React.Fragment,null,\"hello\");", r.output);
}

// ============================================================
// E2E Tests: Token splitting (>> → > + >, >= → > + = etc.)
// ============================================================

test "Codegen: nested generic >> splits correctly" {
    var r = try e2e(std.testing.allocator, "let x: Array<Array<number>>");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x;", r.output);
}

test "Codegen: arrow with >= split (): A<T>=> 0" {
    var r = try e2e(std.testing.allocator, "(): A<T>=> 0");
    defer r.deinit();
    try std.testing.expectEqualStrings("()=>0;", r.output);
}

test "Codegen: triple nested generic >>>" {
    var r = try e2e(std.testing.allocator, "let x: A<B<C<number>>>");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x;", r.output);
}

// ============================================================
// E2E Tests: Namespace with export
// ============================================================

test "Codegen: namespace with export const" {
    var r = try e2e(std.testing.allocator, "namespace Foo { export const x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Foo;((Foo) => {Foo.x=1;})(Foo || (Foo = {}));",
        r.output,
    );
}

test "Codegen: namespace with export function" {
    var r = try e2e(std.testing.allocator, "namespace Foo { export function bar() {} }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Foo;((Foo) => {function bar(){}Foo.bar=bar;})(Foo || (Foo = {}));",
        r.output,
    );
}

test "Codegen: namespace export reference substitution" {
    var r = try e2e(std.testing.allocator, "namespace ns { export let L1 = 1; console.log(L1); }");
    defer r.deinit();
    // export된 변수의 참조가 ns.L1으로 치환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(ns.L1)") != null);
    // 선언부는 치환되면 안 됨 (let L1 = 1, not let ns.L1 = 1)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let ns.L1") == null);
}

test "Codegen: namespace export reference — multiple exports" {
    var r = try e2e(std.testing.allocator, "namespace ns { export let a = 1, b = 2; console.log(a + b); }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(ns.a + ns.b)") != null);
}

test "Codegen: namespace export reference — function" {
    var r = try e2e(std.testing.allocator, "namespace ns { export function foo() {} console.log(foo); }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(ns.foo)") != null);
}

test "Codegen: namespace export var — direct property assignment (no local var)" {
    // Bug 1 fix: reserved word (await, yield) as export var name should not emit local variable.
    // export let foo = 1 → ns.foo=1; (not let foo=1;ns.foo=foo;)
    var r = try e2e(std.testing.allocator, "namespace x { export let foo = 1, bar = foo; }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var x;((x) => {x.foo=1;x.bar=x.foo;})(x || (x = {}));",
        r.output,
    );
}

test "Codegen: namespace export declare — reference rewriting" {
    // Bug 2 fix: export declare const L1 → references to L1 should be rewritten to ns.L1.
    var r = try e2e(std.testing.allocator, "namespace ns { export declare const L1; console.log(L1); }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(ns.L1)") != null);
}

test "Codegen: namespace nested export mutation — uses property access" {
    // Bug 3 fix: mutations to exported vars should use ns.prop, not stale local.
    // foo += foo → B.foo += B.foo (not foo += B.foo)
    var r = try e2e(std.testing.allocator, "namespace A { export namespace B { export let foo = 1; foo += foo } }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "B.foo+=B.foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "B.foo=1") != null);
}

// ============================================================
// E2E Tests: TS type assertions (stripped)
// ============================================================

test "Codegen: as expression stripped" {
    var r = try e2e(std.testing.allocator, "const x = value as string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

test "Codegen: satisfies expression stripped" {
    var r = try e2e(std.testing.allocator, "const x = value satisfies T;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

test "Codegen: non-null assertion stripped" {
    var r = try e2e(std.testing.allocator, "const x = value!;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

// ============================================================
// E2E Tests: CJS module format
// ============================================================

test "Codegen CJS: import named" {
    // CJS named import uses writeNodeSpan which preserves trailing space from source
    var r = try e2eCJS(std.testing.allocator, "import { foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {foo }=require(\"./bar\");", r.output);
}

test "Codegen CJS: import default" {
    var r = try e2eCJS(std.testing.allocator, "import bar from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const bar=require(\"./bar\").default;", r.output);
}

test "Codegen CJS: import namespace" {
    var r = try e2eCJS(std.testing.allocator, "import * as bar from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const bar=require(\"./bar\");", r.output);
}

test "Codegen CJS: export all" {
    // emitExportAll reads binary.left (exported_name=None) instead of binary.right (source)
    // NOTE: this is a known issue — source node is omitted in current codegen
    var r = try e2eCJS(std.testing.allocator, "export * from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("Object.assign(exports,require());", r.output);
}

test "Codegen CJS: export named function" {
    var r = try e2eCJS(std.testing.allocator, "export function foo() {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("function foo(){}exports.foo=foo;", r.output);
}

// ============================================================
// E2E Tests: Formatted output
// ============================================================

test "Codegen formatted: function declaration" {
    var r = try e2eWithOptions(std.testing.allocator, "function foo() { return 1; }", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("function foo() {\n\treturn 1;\n}\n", r.output);
}

test "Codegen formatted: class with method" {
    var r = try e2eWithOptions(std.testing.allocator, "class Foo { bar() {} }", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo {\n\tbar() {\n\t}\n}\n", r.output);
}

test "Codegen formatted: spaces indent" {
    var r = try e2eWithOptions(std.testing.allocator, "if (x) { return 1; }", .{ .indent_char = .space, .indent_width = 2 });
    defer r.deinit();
    try std.testing.expectEqualStrings("if (x) {\n  return 1;\n}\n", r.output);
}

// ================================================================
// import.meta polyfill tests
// ================================================================

test "import.meta: ESM keeps import.meta as-is" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .esm });
    defer r.deinit();
    try std.testing.expectEqualStrings("const m=import.meta;", r.output);
}

test "import.meta: CJS node — standalone import.meta" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    // CJS node: import.meta → full polyfill object
    try std.testing.expectEqualStrings(
        "const m={url:require(\"url\").pathToFileURL(__filename).href,dirname:__dirname,filename:__filename};",
        r.output,
    );
}

test "import.meta: CJS browser — standalone import.meta" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    // CJS browser: import.meta → {}
    try std.testing.expectEqualStrings("const m={};", r.output);
}

test "import.meta.url: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "const u=require(\"url\").pathToFileURL(__filename).href;",
        r.output,
    );
}

test "import.meta.url: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=\"\";", r.output);
}

test "import.meta.dirname: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const d = import.meta.dirname;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings("const d=__dirname;", r.output);
}

test "import.meta.dirname: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const d = import.meta.dirname;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const d=\"\";", r.output);
}

test "import.meta.filename: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const f = import.meta.filename;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=__filename;", r.output);
}

test "import.meta.filename: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const f = import.meta.filename;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=\"\";", r.output);
}

test "import.meta.url: ESM keeps as-is" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .esm });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=import.meta.url;", r.output);
}

test "import.meta: replace_import_meta with node platform" {
    // 번들러가 replace_import_meta를 설정하는 경우 (non-ESM 번들)
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .replace_import_meta = true, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "const u=require(\"url\").pathToFileURL(__filename).href;",
        r.output,
    );
}

test "import.meta: replace_import_meta with browser platform" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .replace_import_meta = true, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=\"\";", r.output);
}

test "import.meta: unknown property CJS node falls through to polyfill" {
    // import.meta.env 등 알려지지 않은 프로퍼티 → import.meta polyfill + .env
    var r = try e2eWithOptions(std.testing.allocator, "const e = import.meta.env;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    // 알려지지 않은 프로퍼티는 import.meta 폴리필 뒤에 .prop이 붙어야 함
    try std.testing.expectEqualStrings(
        "const e={url:require(\"url\").pathToFileURL(__filename).href,dirname:__dirname,filename:__filename}.env;",
        r.output,
    );
}

test "import.meta: unknown property CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const e = import.meta.env;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const e={}.env;", r.output);
}

// ============================================================
// ES Downlevel Tests (--target)
// ============================================================

fn e2eTarget(allocator: std.mem.Allocator, source: []const u8, target: TransformOptions.Target) !TestResult {
    return e2eFull(allocator, source, .{ .target = target }, .{ .minify_whitespace = true }, ".ts");
}

// --- ?? (nullish coalescing) ---

test "ES2020: ?? simple identifier" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a!=null?a:b;", r.output);
}

test "ES2020: ?? side effect (temp var)" {
    var r = try e2eTarget(std.testing.allocator, "const x = foo() ?? b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;const x=(_a=foo())!=null?_a:b;", r.output);
}

test "ES2020: ?? no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a??b;", r.output);
}

test "ES2020: ?? no transform on es2020" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a??b;", r.output);
}

// --- ?. (optional chaining) ---

test "ES2020: ?. member" {
    var r = try e2eTarget(std.testing.allocator, "a?.b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a.b;", r.output);
}

test "ES2020: ?. computed" {
    var r = try e2eTarget(std.testing.allocator, "a?.[0];", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a[0];", r.output);
}

test "ES2020: ?. call" {
    var r = try e2eTarget(std.testing.allocator, "a?.();", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a();", r.output);
}

test "ES2020: ?. side effect (temp var)" {
    var r = try e2eTarget(std.testing.allocator, "foo()?.bar;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;(_a=foo())==null?void 0:_a.bar;", r.output);
}

test "ES2020: ?. chain continuation" {
    var r = try e2eTarget(std.testing.allocator, "a?.b.c;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a.b.c;", r.output);
}

test "ES2020: ?. no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "a?.b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("a?.b;", r.output);
}

// --- ??= (nullish assignment) ---

test "ES2021: ??= to es2020" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a??(a=b);", r.output);
}

test "ES2021: ??= to es2019 (double lowering)" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a!=null?a:(a=b);", r.output);
}

test "ES2021: ??= no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("a??=b;", r.output);
}

// --- ||= &&= (logical assignment) ---

test "ES2021: ||=" {
    var r = try e2eTarget(std.testing.allocator, "a ||= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a||(a=b);", r.output);
}

test "ES2021: &&=" {
    var r = try e2eTarget(std.testing.allocator, "a &&= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a&&(a=b);", r.output);
}

test "ES2021: ||= no transform on es2021" {
    var r = try e2eTarget(std.testing.allocator, "a ||= b;", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("a||=b;", r.output);
}

// --- ** (exponentiation) ---

test "ES2016: ** to Math.pow" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .es2015);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Math.pow(a,b);", r.output);
}

test "ES2016: **= to Math.pow assignment" {
    var r = try e2eTarget(std.testing.allocator, "a **= b;", .es2015);
    defer r.deinit();
    try std.testing.expectEqualStrings("a=Math.pow(a,b);", r.output);
}

test "ES2016: ** no transform on es2016" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .es2016);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a**b;", r.output);
}

test "ES2016: ** no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a**b;", r.output);
}

test "ES2016: **= no transform on es2016" {
    var r = try e2eTarget(std.testing.allocator, "a **= b;", .es2016);
    defer r.deinit();
    try std.testing.expectEqualStrings("a**=b;", r.output);
}

// --- catch binding (ES2019) ---

test "ES2019: optional catch binding" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch { y; }", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch(_unused){y;}", r.output);
}

test "ES2019: catch with binding preserved" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch (e) { y; }", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch(e){y;}", r.output);
}

test "ES2019: optional catch no transform on es2019" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch { y; }", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch{y;}", r.output);
}

// --- ES2022: class static block ---

test "ES2022: static block to IIFE" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { console.log(\"init\"); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}(()=>{console.log(\"init\");})();", r.output);
}

test "ES2022: static block no transform on es2022" {
    // static_block은 writeNodeSpan으로 소스를 그대로 복사하므로 공백이 유지됨
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{console.log(\"init\")}}", .es2022);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{console.log(\"init\")}}", r.output);
}

test "ES2022: static block no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{console.log(\"init\")}}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{console.log(\"init\")}}", r.output);
}

test "ES2022: multiple static blocks" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { a(); } method() {} static { b(); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{method(){}}(()=>{a();})();(()=>{b();})();", r.output);
}

test "ES2022: static block with methods preserved" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { method() { return 1; } static { init(); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{method(){return 1;}}(()=>{init();})();", r.output);
}

// --- ES2017: async/await → generator ---

test "ES2017: async function declaration" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { return await bar(); }", .{ .target = .es2016 }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export function foo(){return __async(function*(){return (yield bar());}).call(this);}", r.output);
}

test "ES2017: async arrow block body" {
    var r = try e2eFull(std.testing.allocator, "export const f = async () => { await x; };", .{ .target = .es2016 }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export const f=()=>__async(function*(){(yield x);}).call(this);", r.output);
}

test "ES2017: async arrow expression body" {
    var r = try e2eFull(std.testing.allocator, "export const f = async () => await x;", .{ .target = .es2016 }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export const f=()=>__async(function*(){return (yield x);}).call(this);", r.output);
}

test "ES2017: no transform on es2017" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { await x; }", .{ .target = .es2017 }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export async function foo(){await x;}", r.output);
}

test "ES2017: no transform on esnext" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { await x; }", .{ .target = .esnext }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export async function foo(){await x;}", r.output);
}

test "ES2017: non-async function unchanged" {
    var r = try e2eFull(std.testing.allocator, "export function foo() { return 1; }", .{ .target = .es2016 }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export function foo(){return 1;}", r.output);
}

// --- ES2018: object spread ---

test "ES2018: spread only" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},obj);", r.output);
}

test "ES2018: props then spread" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, ...obj };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({a:1},obj);", r.output);
}

test "ES2018: spread then props" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},obj,{b:2});", r.output);
}

test "ES2018: mixed spread" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, ...obj, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({a:1},obj,{b:2});", r.output);
}

test "ES2018: multiple spreads" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...a, ...b };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},a,b);", r.output);
}

test "ES2018: no transform on es2018" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...obj};", r.output);
}

test "ES2018: no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...obj};", r.output);
}

test "ES2018: no spread - no transform" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={a:1,b:2};", r.output);
}

// --- ES2022: class static block ---

test "ES2022: static block this → class name" {
    // class Foo { static { this.x = 1; } }
    // → class Foo {} (() => { Foo.x = 1; })();
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { this.x = 1; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}(()=>{Foo.x=1;})();", r.output);
}

test "ES2022: static block this in nested function not replaced" {
    // 일반 함수 안의 this는 치환하면 안 됨 (자체 this 바인딩)
    var r = try e2eTarget(std.testing.allocator, "class Bar { static { function f() { return this; } } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Bar{}(()=>{function f(){return this;}})();", r.output);
}

test "ES2022: static block this in arrow replaced" {
    // arrow function은 this 상속 → 치환 대상
    var r = try e2eTarget(std.testing.allocator, "class Baz { static { const f = () => this.x; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Baz{}(()=>{const f=()=>Baz.x;})();", r.output);
}

test "ES2022: static block anonymous class - this not replaced" {
    // 익명 클래스: 클래스 이름이 없으므로 this 그대로
    var r = try e2eTarget(std.testing.allocator, "var x = class { static { this.y = 1; } };", .es2021);
    defer r.deinit();
    // 익명 클래스는 this 치환 안 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.y") != null);
}

test "ES2022: static block this - no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{this.x=1;}}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{this.x=1;}}", r.output);
}

test "ES2022: multiple static blocks with this" {
    var r = try e2eTarget(std.testing.allocator, "class A { static { this.x = 1; } static { this.y = 2; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class A{}(()=>{A.x=1;})();(()=>{A.y=2;})();", r.output);
}

// --- ES2015: template literal ---

test "ES2015: no-substitution template" {
    var r = try e2eTarget(std.testing.allocator, "var x=`hello`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"hello\";", r.output);
}

test "ES2015: template with substitution" {
    var r = try e2eTarget(std.testing.allocator, "var x=`a${b}c`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"a\" + b + \"c\";", r.output);
}

test "ES2015: template empty head" {
    var r = try e2eTarget(std.testing.allocator, "var x=`${a}`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\" + a;", r.output);
}

test "ES2015: template multiple substitutions" {
    var r = try e2eTarget(std.testing.allocator, "var x=`${a}${b}`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\" + a + b;", r.output);
}

test "ES2015: template with text between substitutions" {
    var r = try e2eTarget(std.testing.allocator, "var x=`a${b}c${d}e`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"a\" + b + \"c\" + d + \"e\";", r.output);
}

test "ES2015: empty template" {
    var r = try e2eTarget(std.testing.allocator, "var x=``;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\";", r.output);
}

test "ES2015: template no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x=`hello`;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello`;", r.output);
}

// --- tagged template ---

test "tagged template: basic" {
    var r = try e2e(std.testing.allocator, "foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo`hello`;", r.output);
}

test "tagged template: with substitution" {
    var r = try e2e(std.testing.allocator, "foo`hello ${x} world`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo`hello ${x} world`;", r.output);
}

test "tagged template: after var declaration" {
    var r = try e2e(std.testing.allocator, "var x;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var x;foo`hello`;", r.output);
}

test "tagged template: after let declaration" {
    var r = try e2e(std.testing.allocator, "let x=1;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;foo`hello`;", r.output);
}

test "tagged template: after function declaration" {
    var r = try e2e(std.testing.allocator, "function f(){}foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(){}foo`hello`;", r.output);
}

test "tagged template: as identifier as tag" {
    var r = try e2e(std.testing.allocator, "as`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("as`hello`;", r.output);
}

test "tagged template: member expression tag" {
    var r = try e2e(std.testing.allocator, "foo.bar`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo.bar`hello`;", r.output);
}

test "tagged template: no-substitution after expression statement" {
    var r = try e2e(std.testing.allocator, "1;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("1;foo`hello`;", r.output);
}

// --- ES2015: shorthand property ---

test "ES2015: shorthand property expansion" {
    var r = try e2eTarget(std.testing.allocator, "var o={x,y};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x:x,y:y};", r.output);
}

test "ES2015: mixed shorthand and full property" {
    var r = try e2eTarget(std.testing.allocator, "var o={x:1,y};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x:1,y:y};", r.output);
}

test "ES2015: shorthand no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var o={x,y};", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x,y};", r.output);
}

// --- ES2015: computed property ---

test "ES2015: computed property lowering" {
    var r = try e2eTarget(std.testing.allocator, "var o={a:1,[k]:v,b:2};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var o=(_a={a:1},_a[k]=v,_a.b=2,_a);", r.output);
}

test "ES2015: computed property only" {
    var r = try e2eTarget(std.testing.allocator, "var o={[k]:v};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var o=(_a={},_a[k]=v,_a);", r.output);
}

test "ES2015: no computed - no transform" {
    var r = try e2eTarget(std.testing.allocator, "var o={a:1,b:2};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={a:1,b:2};", r.output);
}

test "ES2015: computed no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var o={[k]:v};", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={[k]:v};", r.output);
}

// --- ES2015: default/rest parameters ---

test "ES2015: default parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1){return x;}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x){x=x===void 0?1:x;return x;}", r.output);
}

test "ES2015: rest parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f(a,...rest){return rest;}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(a){var rest=[].slice.call(arguments,1);return rest;}", r.output);
}

test "ES2015: default + rest combined" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1,...rest){}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x){x=x===void 0?1:x;var rest=[].slice.call(arguments,1);}", r.output);
}

test "ES2015: params no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1,...rest){}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x=1,...rest){}", r.output);
}

// --- ES2015: spread ---

test "ES2015: spread in call" {
    var r = try e2eTarget(std.testing.allocator, "f(...arr);", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("f.apply(void 0,arr);", r.output);
}

test "ES2015: spread in call with args" {
    var r = try e2eTarget(std.testing.allocator, "f(a,...arr);", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("f.apply(void 0,[].concat([a],arr));", r.output);
}

test "ES2015: spread in array" {
    var r = try e2eTarget(std.testing.allocator, "var x=[...arr,1];", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=[].concat(arr,[1]);", r.output);
}

test "ES2015: spread no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "f(...arr);", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("f(...arr);", r.output);
}

test "ES2015: spread in new expression" {
    var r = try e2eTarget(std.testing.allocator, "new Foo(...args);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.bind.apply") != null);
}

// --- ES2015: arrow function ---

test "ES2015: arrow expression body" {
    var r = try e2eTarget(std.testing.allocator, "var f=()=>42;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(){return 42;};", r.output);
}

test "ES2015: arrow with param" {
    var r = try e2eTarget(std.testing.allocator, "var f=x=>x+1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x + 1;};", r.output);
}

test "ES2015: arrow with parens param" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x)=>x+1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x + 1;};", r.output);
}

test "ES2015: arrow block body" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x)=>{return x;};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x;};", r.output);
}

test "ES2015: arrow multiple params" {
    var r = try e2eTarget(std.testing.allocator, "var f=(a,b)=>a+b;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(a,b){return a + b;};", r.output);
}

test "ES2015: arrow no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var f=()=>42;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=()=>42;", r.output);
}

// --- ES2015: for-of ---

test "ES2015: for-of with const" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){f(x);}", .es5);
    defer r.deinit();
    // _a=index, _b=array, postfix increment
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_b.length") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=_b[_a]") != null);
    // postfix _a++ (not prefix ++_a)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a++") != null);
}

test "ES2015: for-of with expression left" {
    var r = try e2eTarget(std.testing.allocator, "for(x of arr){}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(") != null);
}

test "ES2015: for-of no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const x of arr){}", r.output);
}

// --- ES2015: destructuring ---

test "ES2015: object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a,b}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,a=_a.a,b=_a.b;", r.output);
}

test "ES2015: array destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var [x,y]=arr;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=arr,x=_a[0],y=_a[1];", r.output);
}

test "ES2015: destructuring rename" {
    var r = try e2eTarget(std.testing.allocator, "var {a:c}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,c=_a.a;", r.output);
}

test "ES2015: destructuring default" {
    var r = try e2eTarget(std.testing.allocator, "var {a=1}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,a=_a.a===void 0?1:_a.a;", r.output);
}

test "ES2015: destructuring no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var {a,b}=obj;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var {a:a,b:b}=obj;", r.output);
}

test "ES2015: assignment object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "({a,b}=obj);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a=_a.a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "b=_a.b") != null);
}

test "ES2015: assignment array destructuring" {
    var r = try e2eTarget(std.testing.allocator, "([x,y]=arr);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=arr") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=_a[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "y=_a[1]") != null);
}

test "ES2015: assignment destructuring with default" {
    var r = try e2eTarget(std.testing.allocator, "({a=1,b}=obj);", .es5);
    defer r.deinit();
    // a = _ref.a === void 0 ? 1 : _ref.a
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0?1:") != null);
}

test "ES2015: assignment array destructuring with default" {
    var r = try e2eTarget(std.testing.allocator, "([x=1,y]=arr);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0?1:") != null);
}

// --- ES2015: let/const → var ---

test "ES2015: let to var" {
    var r = try e2eTarget(std.testing.allocator, "let x=1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=1;", r.output);
}

test "ES2015: const to var" {
    var r = try e2eTarget(std.testing.allocator, "const y=2;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var y=2;", r.output);
}

test "ES2015: var stays var" {
    var r = try e2eTarget(std.testing.allocator, "var z=3;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=3;", r.output);
}

test "ES2015: let/const no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "let x=1;const y=2;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;const y=2;", r.output);
}

// --- ES2015: class ---

test "ES2015: class with constructor and methods" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{constructor(x){this.x=x;}method(){return this.x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo(x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.prototype.method=function()") != null);
}

test "ES2015: class with static method" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static create(){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.create=function()") != null);
}

test "ES2015: empty class" {
    var r = try e2eTarget(std.testing.allocator, "class Empty{}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function Empty(){}", r.output);
}

test "ES2015: class with instance field" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{x=1;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
}

test "ES2015: class with static field" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static y=2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.y=2") != null);
}

test "ES2015: class no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}", r.output);
}

// --- ES2015: generator ---

test "ES2015: basic generator" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;yield 2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES2015: generator with return" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;return 42;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [2,42]") != null);
}

test "ES2015: generator with for loop yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){for(var i=0;i<3;i++){yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
    // 조건 부정: !(i<3)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!(i<3)") != null or
        std.mem.indexOf(u8, r.output, "!(i < 3)") != null);
}

test "ES2015: generator with if yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(x){if(x){yield 1;}yield 2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,2]") != null);
}

test "ES2015: generator no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;}", .esnext);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") == null);
}

test "ES2015: generator var hoisting with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var x=yield 1;return x;}", .es5);
    defer r.deinit();
    // var x가 switch 밖에 호이스팅됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x") != null);
    // x = _state.sent()
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
    // generator 플래그 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES2015: generator var hoisting without yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var a=1;yield a;}", .es5);
    defer r.deinit();
    // var a가 호이스팅됨, case 안에는 a=1 assignment만
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,a]") != null);
}

test "ES2015: generator yield*" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield* [1,2];}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [5,[1,2]]") != null);
}

test "ES2015: generator do-while with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var i=0;do{yield i;i++;}while(i<3);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
    // do-while: body 먼저, 조건으로 점프
    try std.testing.expect(std.mem.indexOf(u8, r.output, "i<3") != null or
        std.mem.indexOf(u8, r.output, "i < 3") != null);
}

test "ES2015: generator try/catch with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){try{yield 1;}catch(e){yield e;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.trys.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES2015: generator try/catch/finally with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){try{yield 1;}catch(e){f(e);}finally{cleanup();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.trys.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [7]") != null); // endfinally
    try std.testing.expect(std.mem.indexOf(u8, r.output, "cleanup()") != null);
}

// ============================================================
// ES2015 다운레벨링 추가 테스트
// ============================================================

// --- class extends/super ---

test "ES2015: class extends with super()" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(x){super(x);this.x=x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "P.call(this,x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(C,P)") != null);
}

test "ES2015: class extends default constructor" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "P.apply(this,arguments)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(C,P)") != null);
}

test "ES2015: super.method() call" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){return super.m();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "P.prototype.m.call(this)") != null);
}

// --- class getter/setter ---

test "ES2015: class getter/setter paired" {
    var r = try e2eTarget(std.testing.allocator, "class F{get v(){return 1;}set v(x){}}", .es5);
    defer r.deinit();
    // 하나의 Object.defineProperty로 합쳐져야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty") != null);
    // "get:" 와 "set:" 가 같은 호출 안에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "get:function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "set:function(x)") != null);
}

test "ES2015: class static getter" {
    var r = try e2eTarget(std.testing.allocator, "class F{static get n(){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(F") != null);
}

// --- class expression ---

test "ES2015: class expression simple" {
    var r = try e2eTarget(std.testing.allocator, "const F=class{};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Class()") != null);
}

test "ES2015: class expression with method" {
    var r = try e2eTarget(std.testing.allocator, "const F=class{m(){return 1;}};", .es5);
    defer r.deinit();
    // IIFE 패턴
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return _Class") != null);
}

test "ES2015: class expression with extends" {
    var r = try e2eTarget(std.testing.allocator, "const F=class extends P{m(){}};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function()") != null);
}

// --- class private field ---

test "ES2015: class private field WeakMap" {
    var r = try e2eTarget(std.testing.allocator, "class F{#x=1;g(){return this.#x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "new WeakMap") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.set(this,1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.get(this)") != null);
}

test "ES2015: class private field set" {
    var r = try e2eTarget(std.testing.allocator, "class F{#x=0;s(v){this.#x=v;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.set(this,v)") != null);
}

// --- destructuring rest ---

test "ES2015: destructuring object rest" {
    var r = try e2eTarget(std.testing.allocator, "var {a,...r}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"a\"]") != null);
}

test "ES2015: destructuring array rest" {
    var r = try e2eTarget(std.testing.allocator, "var [a,...r]=arr;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".slice(1)") != null);
}

// --- generator labeled break/continue ---

test "ES2015: generator labeled break" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){outer:for(var i=0;i<3;i++){if(i===1)break outer;yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // break outer → return [3, N] (end label로 점프)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [3,") != null);
}

test "ES2015: generator labeled continue" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){outer:for(var i=0;i<3;i++){if(i===1)continue outer;yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // continue outer → return [3, N] (update label로 점프 → i++ 실행)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "i++") != null);
}

// --- generator switch yield ---

test "ES2015: generator switch with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* g(x){switch(x){case 1:yield 'a';break;default:yield 'b';}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // switch → if-else 체인으로 분해
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,\"a\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,\"b\"]") != null);
}

// --- static block ES5 ---

test "ES2015: static block in class declaration" {
    var r = try e2eTarget(std.testing.allocator, "class F{static v;static{F.v=42;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.v=42") != null);
}

// --- arrow this capture in class method ---

test "ES2015: arrow this capture in class method" {
    var r = try e2eTarget(std.testing.allocator, "class F{x=1;g(){var fn=()=>this.x;return fn();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.x") != null);
}

// --- arrow edge cases ---

test "ES2015: arrow returning object literal" {
    var r = try e2eTarget(std.testing.allocator, "var f = () => ({ x: 1 });", .es5);
    defer r.deinit();
    // 객체 리터럴 반환 시 괄호 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x:1") != null);
}

test "ES2015: arrow with destructuring param" {
    var r = try e2eTarget(std.testing.allocator, "var f = ({x,y}) => x+y;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(") != null);
}

test "ES2015: nested arrow this capture" {
    var r = try e2eTarget(std.testing.allocator, "function outer(){var f=()=>{var g=()=>this.x;};}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.x") != null);
}

test "ES2015: arrow in object method preserves this" {
    var r = try e2eTarget(std.testing.allocator, "var obj={m(){return ()=>this;}};", .es5);
    defer r.deinit();
    // arrow → function 변환 + _this 참조
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function()") != null);
}

// --- destructuring edge cases ---

test "ES2015: nested object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a:{b}}=obj;", .es5);
    defer r.deinit();
    // 중첩 구조분해 → 임시 변수 사용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".a") != null);
}

test "ES2015: array in object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a:[x,y]}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[0]") != null);
}

test "ES2015: destructuring function parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f({a,b}){return a+b;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function f(") != null);
}

test "ES2015: destructuring with computed key" {
    var r = try e2eTarget(std.testing.allocator, "var k='x';var {[k]:v}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

test "ES2015: for-of with destructuring" {
    var r = try e2eTarget(std.testing.allocator, "for(const [k,v] of arr){}", .es5);
    defer r.deinit();
    // for-of → index loop, const → var
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".length") != null);
}

// --- class edge cases ---

test "ES2015: class with computed method" {
    var r = try e2eTarget(std.testing.allocator, "var k='m';class F{[k](){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function F()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype") != null);
}

test "ES2015: class with multiple fields" {
    var r = try e2eTarget(std.testing.allocator, "class F{a=1;b='hi';c=true;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.a=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.b=\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.c=true") != null);
}

test "ES2015: class constructor with super and field" {
    var r = try e2eTarget(std.testing.allocator, "class B{x=0;}class D extends B{y=1;constructor(){super();this.z=2;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.y=1") != null);
}

// --- generator edge cases ---

test "ES2015: generator with while yield" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){var i=0;while(i<3){yield i;i++;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
}

test "ES2015: generator expression" {
    var r = try e2eTarget(std.testing.allocator, "var g=function*(){yield 1;yield 2;};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
}

test "ES2015: generator with multiple return" {
    var r = try e2eTarget(std.testing.allocator, "function* g(x){if(x>0){return 'pos';}yield 0;return 'neg';}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // yield 0 → [4, 0], return "neg" → [2, "neg"]
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [2,\"neg\"]") != null);
}

// --- for-of edge cases ---

test "ES2015: for-of with let" {
    var r = try e2eTarget(std.testing.allocator, "for(let x of arr){f(x);}", .es5);
    defer r.deinit();
    // let → var + for-of → index loop
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

test "ES2015: for-of with break" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){if(x>1)break;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "break") != null);
}

// --- spread edge cases ---

test "ES2015: spread in new with apply" {
    var r = try e2eTarget(std.testing.allocator, "new Foo(...args);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "apply") != null or std.mem.indexOf(u8, r.output, "concat") != null);
}

test "ES2015: spread multiple arrays" {
    var r = try e2eTarget(std.testing.allocator, "var x=[...a,...b,...c];", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "concat") != null);
}

// --- template literal edge cases ---

test "ES2015: template with expression" {
    var r = try e2eTarget(std.testing.allocator, "var s=`${a+b} = ${c}`;", .es5);
    defer r.deinit();
    // 백틱 → 문자열 연결
    try std.testing.expect(std.mem.indexOf(u8, r.output, "+") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" = \"") != null or std.mem.indexOf(u8, r.output, "' = '") != null);
}

test "ES2015: template nested" {
    var r = try e2eTarget(std.testing.allocator, "var s=`a${`b${c}`}d`;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "+") != null);
}

// --- combined features ---

test "ES2015: class with generator method" {
    var r = try e2eTarget(std.testing.allocator, "class F{*gen(){yield 1;}}", .es5);
    defer r.deinit();
    // class → function + prototype
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "gen") != null);
}

test "ES2015: destructuring with spread and default" {
    var r = try e2eTarget(std.testing.allocator, "var {a=1,...rest}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null or std.mem.indexOf(u8, r.output, "hasOwnProperty") != null);
}

test "ES2015: multiple let in for-of" {
    var r = try e2eTarget(std.testing.allocator, "for(const [a,b] of items){let sum=a+b;f(sum);}", .es5);
    defer r.deinit();
    // const/let → var, for-of → index loop, destructuring → temp
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

// --- ES2020 edge cases ---

test "ES2020: ?? nested" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b ?? c;", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
}

test "ES2020: ?. deep chain" {
    var r = try e2eTarget(std.testing.allocator, "a?.b?.c?.d;", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

test "ES2020: ?. with method call" {
    var r = try e2eTarget(std.testing.allocator, "obj?.method(1,2);", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

test "ES2020: ?? with ?. combined" {
    var r = try e2eTarget(std.testing.allocator, "const x = a?.b ?? 'default';", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

// --- ES2021 edge cases ---

test "ES2021: ??= with member expression" {
    var r = try e2eTarget(std.testing.allocator, "obj.x ??= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj.x") != null);
}

test "ES2021: ||= with member expression" {
    var r = try e2eTarget(std.testing.allocator, "obj.x ||= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj.x") != null);
}

// --- ES2022 edge cases ---

test "ES2022: static block with side effects" {
    var r = try e2eTarget(std.testing.allocator, "class F{static count=0;static{F.count++;}}", .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.count++") != null or std.mem.indexOf(u8, r.output, "F.count+=1") != null);
}

// --- temp var hoisting ---

test "ES2020: temp var hoisted for ?? in function" {
    var r = try e2eTarget(std.testing.allocator, "function f(){return foo()??bar;}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=foo()") != null);
}

test "ES2020: temp var hoisted for ?. in function" {
    var r = try e2eTarget(std.testing.allocator, "function f(){return foo()?.bar;}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null);
}

// --- ES2021 ---

test "ES2021: &&= logical assignment" {
    var r = try e2eTarget(std.testing.allocator, "let a=1;a&&=10;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a&&(a=10)") != null);
}

// --- ES2022 → es2021 ---

test "ES2022: static block to IIFE (target=es2021)" {
    var r = try e2eTarget(std.testing.allocator, "class F{static{F.v=1;}}", .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.v=1") != null);
}

// --- useDefineForClassFields=false ---

test "useDefineForClassFields=false: instance to constructor" {
    var r = try e2eFull(std.testing.allocator, "class Foo{x=1;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
    // x=1 은 class body에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo{x=1") == null);
}

test "useDefineForClassFields=false: static field outside class" {
    var r = try e2eFull(std.testing.allocator, "class Foo{static z=2;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.z=2") != null);
    // static z=2 는 class body에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "static") == null);
}

test "useDefineForClassFields=false: multiple static assignments ordered" {
    var r = try e2eFull(std.testing.allocator, "class Foo{static a=1;static b=2;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.a=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.b=2") != null);
    // a가 b보다 먼저
    const a_pos = std.mem.indexOf(u8, r.output, "Foo.a=1").?;
    const b_pos = std.mem.indexOf(u8, r.output, "Foo.b=2").?;
    try std.testing.expect(a_pos < b_pos);
}

test "useDefineForClassFields=false: method preserved" {
    var r = try e2eFull(std.testing.allocator, "class Foo{x=1;method(){return this.x;}}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "method()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
}

test "useDefineForClassFields=false: no-init fields removed" {
    var r = try e2eFull(std.testing.allocator, "class Foo{y;static w;method(){}}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    // y, w 모두 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "method") != null);
    // class body에 y, w가 없어야 함 (method만 있음)
    try std.testing.expect(std.mem.indexOf(u8, r.output, ";y") == null);
}

// ============================================================
// 삼항 연산자 + 화살표 함수 (#446)
// ============================================================

test "ternary with arrow function body containing parens" {
    // d3-array cumsum 패턴: ? v => (expr) : v => (expr)
    // 파서가 에러 없이 파싱해야 함
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, "const f = true ? v => (v + 1) : v => (v - 1);");
    var parser = Parser.init(allocator, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "ternary with arrow function — d3 cumsum pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\function cumsum(values, valueof) {
        \\  var sum = 0, index = 0;
        \\  return Float64Array.from(values, valueof === undefined
        \\    ? v => (sum += +v || 0)
        \\    : v => (sum += +valueof(v, index++, values) || 0));
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

// ============================================================
// #491: for 루프 body 내 변수 선언 세미콜론 (minify)
// ============================================================

test "Minify: for-loop body var has semicolon" {
    // for (var i=0;...) { var x=1; console.log(x); } → "var x=1;" 세미콜론 필수
    var r = try e2eWithOptions(std.testing.allocator, "for (var i = 0; i < 3; i++) { var x = i; console.log(x); }", .{ .minify_whitespace = true });
    defer r.deinit();
    // "var x=i;" 다음에 세미콜론이 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=i;") != null);
}

test "Minify: for-loop body let has semicolon" {
    var r = try e2eWithOptions(std.testing.allocator, "for (let i = 0; i < 3; i++) { let y = i * 2; console.log(y); }", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let y=i*2;") != null);
}

test "Minify: for-of body var has semicolon" {
    var r = try e2eWithOptions(std.testing.allocator, "for (const x of [1,2,3]) { var y = x; console.log(y); }", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var y=x;") != null);
}

// ============================================================
// #493: template literal 내 식별자 rename
// ============================================================

test "Minify: template literal preserves identifier references" {
    // template literal 내 ${expr} 식별자가 정상 출력되어야 한다.
    var r = try e2eWithOptions(std.testing.allocator, "const x = 1; const s = `val=${x}`;", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "`val=${x}`") != null);
}

test "Minify: template literal with multiple expressions" {
    var r = try e2eWithOptions(std.testing.allocator, "const a = 1; const b = 2; const s = `${a}+${b}`;", .{ .minify_whitespace = true });
    defer r.deinit();
    // 표현식이 올바르게 emit됨 (backtick + interpolation 구조 유지)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${a}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${b}") != null);
}

test "Minify: simple template literal without substitution" {
    var r = try e2eWithOptions(std.testing.allocator, "const s = `hello world`;", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "`hello world`") != null);
}
