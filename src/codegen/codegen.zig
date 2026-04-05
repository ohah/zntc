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
pub const LinkingMetadata = @import("../bundler/linker.zig").LinkingMetadata;

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
    /// JSX 런타임 모드 (classic / automatic / automatic_dev)
    jsx_runtime: JsxRuntime = .classic,
    /// classic 모드 JSX factory (기본: "React.createElement")
    jsx_factory: []const u8 = "React.createElement",
    /// classic 모드 Fragment factory (기본: "React.Fragment")
    jsx_fragment: []const u8 = "React.Fragment",
    /// automatic 모드 import source (기본: "react")
    jsx_import_source: []const u8 = "react",
    /// 현재 파일 경로 (jsxDEV의 fileName 출력용)
    jsx_filename: []const u8 = "",
    /// __esm 호이스팅 모드: variable_declaration을 할당문으로 변환 (키워드 제거).
    /// emitter가 var 선언을 래퍼 밖에 별도 배치.
    esm_var_assign_only: bool = false,
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
    /// automatic JSX: 사용된 헬퍼 추적 (import 주입용)
    jsx_used_jsx: bool = false,
    jsx_used_jsxs: bool = false,
    jsx_used_jsxDEV: bool = false,
    jsx_used_fragment: bool = false,
    jsx_used_createElement: bool = false,
    /// classic JSX: 번들러 리네이밍이 반영된 factory/fragment 문자열.
    /// 초기화 시 한 번만 계산 (모듈당 O(N) → O(1) per JSX element).
    resolved_jsx_factory: ?[]const u8 = null,
    resolved_jsx_fragment: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) Codegen {
        return initWithOptions(allocator, ast, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, ast: *const Ast, options: CodegenOptions) Codegen {
        var sm = if (options.sourcemap) SourceMapBuilder.init(allocator) else null;
        if (sm) |*builder| {
            builder.source_root = options.source_root;
            builder.sources_content = options.sources_content;
        }
        return .{
            .ast = ast,
            .allocator = allocator,
            .buf = .empty,
            .options = options,
            .indent_level = 0,
            .sm_builder = sm,
            .gen_line = 0,
            .gen_col = 0,
            .resolved_jsx_factory = resolveJSXRename(ast, options.linking_metadata, options.jsx_factory, allocator),
            .resolved_jsx_fragment = resolveJSXRename(ast, options.linking_metadata, options.jsx_fragment, allocator),
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.buf.deinit(self.allocator);
        if (self.sm_builder) |*sm| sm.deinit();
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
        try self.emitNode(root);

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

        // automatic JSX: 사용된 헬퍼의 import문을 output 선두에 결합.
        // 번들 모드에서는 linker가 import를 처리하므로 주입하지 않음.
        if (self.options.jsx_runtime != .classic and self.options.linking_metadata == null) {
            if (self.buildJsxImport()) |import_str| {
                // import문 + 기존 출력을 새 버퍼에 결합 (insertSlice(0) O(n) memmove 회피)
                var combined: std.ArrayList(u8) = .empty;
                try combined.ensureTotalCapacity(self.allocator, import_str.len + self.buf.items.len);
                combined.appendSliceAssumeCapacity(import_str);
                combined.appendSliceAssumeCapacity(self.buf.items);
                self.buf.deinit(self.allocator);
                self.buf = combined;
            }
        }

        return self.buf.items;
    }

    /// automatic JSX import문을 생성. 사용된 헬퍼가 없으면 null.
    fn buildJsxImport(self: *Codegen) ?[]const u8 {
        if (!self.jsx_used_jsx and !self.jsx_used_jsxs and !self.jsx_used_jsxDEV and !self.jsx_used_fragment and !self.jsx_used_createElement) return null;

        var import_buf: std.ArrayList(u8) = .empty;
        const is_dev = self.options.jsx_runtime == .automatic_dev;
        const source = self.options.jsx_import_source;

        // jsx-runtime (또는 jsx-dev-runtime) import
        if (self.jsx_used_jsx or self.jsx_used_jsxs or self.jsx_used_jsxDEV or self.jsx_used_fragment) {
            import_buf.appendSlice(self.allocator, "import { ") catch return null;
            var first = true;
            if (is_dev) {
                if (self.jsx_used_jsxDEV) {
                    import_buf.appendSlice(self.allocator, "jsxDEV as _jsxDEV") catch return null;
                    first = false;
                }
            } else {
                if (self.jsx_used_jsx) {
                    import_buf.appendSlice(self.allocator, "jsx as _jsx") catch return null;
                    first = false;
                }
                if (self.jsx_used_jsxs) {
                    if (!first) import_buf.appendSlice(self.allocator, ", ") catch return null;
                    import_buf.appendSlice(self.allocator, "jsxs as _jsxs") catch return null;
                    first = false;
                }
            }
            if (self.jsx_used_fragment) {
                if (!first) import_buf.appendSlice(self.allocator, ", ") catch return null;
                import_buf.appendSlice(self.allocator, "Fragment as _Fragment") catch return null;
            }
            import_buf.appendSlice(self.allocator, " } from \"") catch return null;
            import_buf.appendSlice(self.allocator, source) catch return null;
            if (is_dev) {
                import_buf.appendSlice(self.allocator, "/jsx-dev-runtime\";\n") catch return null;
            } else {
                import_buf.appendSlice(self.allocator, "/jsx-runtime\";\n") catch return null;
            }
        }

        // createElement import (key-after-spread 폴백용)
        if (self.jsx_used_createElement) {
            import_buf.appendSlice(self.allocator, "import { createElement as _createElement } from \"") catch return null;
            import_buf.appendSlice(self.allocator, source) catch return null;
            import_buf.appendSlice(self.allocator, "\";\n") catch return null;
        }

        return import_buf.items;
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

            // Flow match expression — transformer에서 if-else IIFE로 변환됨
            // 변환되지 않은 경우 (non-bundle 등) span 텍스트 그대로 출력
            .flow_match_expression => try self.writeNodeSpan(node),

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
            try self.emitNode(value);
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

    /// string_literal 노드에서 specifier를 추출하고 require_rewrites 맵에서 조회.
    /// 매칭되면 변수명 반환, 아니면 null. 출력은 하지 않음.
    fn resolveRequireRewrite(self: *Codegen, source: ast_mod.NodeIndex) ?[]const u8 {
        const meta = self.options.linking_metadata orelse return null;
        if (meta.require_rewrites.count() == 0 or source.isNone()) return null;

        const node = self.ast.getNode(source);
        if (node.tag != .string_literal) return null;

        const raw = self.ast.source[node.data.string_ref.start..node.data.string_ref.end];
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

        // keepNames: function_declaration에서 이름이 rename된 경우 entry 수집
        if (self.options.keep_names and node.tag == .function_declaration and !name.isNone()) {
            self.collectKeepNameEntry(name);
        }
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

        // __esm 호이스팅: top-level 단순 변수 선언만 키워드 제거 (할당문으로 변환).
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
                    try self.emitImportSpecifierRename(spec_node, " as ");
                    named_first = false;
                }
            }
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
            const imp_text = self.ast.source[self.ast.getNode(imported).span.start..self.ast.getNode(imported).span.end];
            const loc_text = self.ast.source[self.ast.getNode(local).span.start..self.ast.getNode(local).span.end];
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
                        const name = self.ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
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
                    const name = self.ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
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
                        // default_export_name이 _default(합성 변수)이면 var 선언 필요.
                        // 실제 변수명(stringifySafe 등)이면 이미 선언되어 있으므로 생성 불필요.
                        if (std.mem.startsWith(u8, def_name, "_default")) {
                            if (!self.options.esm_var_assign_only) try self.write("var ");
                            try self.write(def_name);
                            try self.writeByte('=');
                            try self.emitNode(inner);
                            try self.writeByte(';');
                        }
                        // 그 외: __export getter가 이미 선언된 변수를 직접 참조. 생략.
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
                    // anonymous function/class 또는 expression → var _default = ...;
                    // self-reference 방지: export default X에서 X가 이미 같은 이름의
                    // const로 선언되어 있으면 var X = X; 재선언이 불필요
                    const def_name = self.options.linking_metadata.?.default_export_name;
                    const is_self_ref = blk: {
                        if (inner_node.tag == .identifier_reference) {
                            const md = self.options.linking_metadata.?;
                            // rename된 이름으로 비교 (ES5 lowering 시 원본 span과 def_name이 다를 수 있음)
                            if (self.resolveSymbolId(inner, md)) |sid| {
                                if (md.renames.get(sid)) |renamed| {
                                    break :blk std.mem.eql(u8, renamed, def_name);
                                }
                            }
                            const ref_text = self.ast.source[inner_node.span.start..inner_node.span.end];
                            break :blk std.mem.eql(u8, ref_text, def_name);
                        }
                        break :blk false;
                    };
                    if (!is_self_ref) {
                        try self.emitDefaultVarAssignment(def_name, inner);
                    }
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

    // ================================================================
    // JSX 출력 — classic / automatic / automatic_dev 3모드 지원
    // ================================================================

    /// jsx_element: extra = [tag, attrs_start, attrs_len, children_start, children_len]
    fn emitJSXElement(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const tag_name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
        const attrs_start = self.ast.extra_data.items[e + 1];
        const attrs_len = self.ast.extra_data.items[e + 2];
        const children_start = self.ast.extra_data.items[e + 3];
        const children_len = self.ast.extra_data.items[e + 4];

        switch (self.options.jsx_runtime) {
            .classic => {
                try self.write("/* @__PURE__ */ ");
                try self.emitJSXFactoryWithRename(self.options.jsx_factory);
                try self.writeByte('(');
                try self.emitJSXTagName(tag_name_idx);
                try self.emitJSXAttrsClassic(attrs_start, attrs_len);
                try self.emitJSXChildrenClassic(children_start, children_len);
                try self.writeByte(')');
            },
            .automatic, .automatic_dev => {
                // key가 spread 뒤에 오면 automatic 모드 대신 classic(createElement) 폴백
                const key_result = self.findJSXKeyAttr(attrs_start, attrs_len);
                if (key_result.key_after_spread) {
                    // createElement 폴백: React.createElement(tag, {...props, key: value}, children)
                    try self.write("/* @__PURE__ */ ");
                    self.jsx_used_createElement = true;
                    try self.write("_createElement(");
                    try self.emitJSXTagName(tag_name_idx);
                    try self.emitJSXAttrsClassic(attrs_start, attrs_len);
                    try self.emitJSXChildrenClassic(children_start, children_len);
                    try self.writeByte(')');
                    return;
                }

                const effective_children = self.countEffectiveChildren(children_start, children_len);
                const is_static = effective_children > 1;
                const is_dev = self.options.jsx_runtime == .automatic_dev;
                const key_idx = key_result.key_idx;

                try self.write("/* @__PURE__ */ ");
                if (is_dev) {
                    self.jsx_used_jsxDEV = true;
                    try self.write("_jsxDEV(");
                } else if (is_static) {
                    self.jsx_used_jsxs = true;
                    try self.write("_jsxs(");
                } else {
                    self.jsx_used_jsx = true;
                    try self.write("_jsx(");
                }
                try self.emitJSXTagName(tag_name_idx);
                try self.write(", ");

                try self.emitJSXPropsAutomatic(attrs_start, attrs_len, children_start, children_len, key_idx, effective_children);

                // key argument
                if (is_dev) {
                    try self.write(", ");
                    if (key_idx) |ki| {
                        const key_attr = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[attrs_start + ki]));
                        try self.emitNode(key_attr.data.binary.right);
                    } else {
                        try self.write("undefined");
                    }
                    // isStaticChildren
                    if (is_static) try self.write(", true") else try self.write(", false");
                    // source info: { fileName, lineNumber, columnNumber }
                    try self.emitJSXDevSource(node.span);
                    // __self: esbuild는 최상위 스코프에서 undefined, 함수/클래스 안에서 this를 전달.
                    // ZTS는 함수 단위 코드젠이므로 항상 this가 유효. 최상위 JSX는 RN에서 거의 없어 현재 동작 유지.
                    try self.write(", this");
                } else if (key_idx != null) {
                    try self.write(", ");
                    const key_attr = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[attrs_start + key_idx.?]));
                    try self.emitNode(key_attr.data.binary.right);
                }

                try self.writeByte(')');
            },
        }
    }

    /// Fragment: <>{children}</>
    fn emitJSXFragment(self: *Codegen, node: Node) !void {
        const list = node.data.list;
        switch (self.options.jsx_runtime) {
            .classic => {
                try self.write("/* @__PURE__ */ ");
                try self.emitJSXFactoryWithRename(self.options.jsx_factory);
                try self.writeByte('(');
                try self.emitJSXFactoryWithRename(self.options.jsx_fragment);
                if (self.options.minify_whitespace) try self.write(",null") else try self.write(", null");
                try self.emitJSXChildrenClassic(list.start, list.len);
                try self.writeByte(')');
            },
            .automatic, .automatic_dev => {
                self.jsx_used_fragment = true;
                const effective_children = self.countEffectiveChildren(list.start, list.len);
                const is_static = effective_children > 1;
                const is_dev = self.options.jsx_runtime == .automatic_dev;

                try self.write("/* @__PURE__ */ ");
                if (is_dev) {
                    self.jsx_used_jsxDEV = true;
                    try self.write("_jsxDEV(");
                } else if (is_static) {
                    self.jsx_used_jsxs = true;
                    try self.write("_jsxs(");
                } else {
                    self.jsx_used_jsx = true;
                    try self.write("_jsx(");
                }
                try self.write("_Fragment, ");
                // props with children
                try self.emitJSXPropsAutomatic(0, 0, list.start, list.len, null, effective_children);
                if (is_dev) {
                    try self.write(", undefined, ");
                    if (is_static) try self.write("true") else try self.write("false");
                    try self.emitJSXDevSource(node.span);
                    // __self: 최상위 스코프 최적화는 수정 3 코멘트 참조 (emitJSXElement)
                    try self.write(", this");
                }
                try self.writeByte(')');
            },
        }
    }

    fn emitJSXFactoryWithRename(self: *Codegen, factory: []const u8) !void {
        if (factory.ptr == self.options.jsx_factory.ptr) {
            try self.write(self.resolved_jsx_factory orelse factory);
        } else {
            try self.write(self.resolved_jsx_fragment orelse factory);
        }
    }

    /// 초기화 시 한 번만 호출: jsx_factory/fragment의 prefix를 리네이밍된 이름으로 교체.
    fn resolveJSXRename(ast: *const Ast, meta_opt: ?*const LinkingMetadata, factory: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
        const meta = meta_opt orelse return null;
        const dot_pos = std.mem.indexOf(u8, factory, ".") orelse return null;
        const prefix = factory[0..dot_pos];
        const suffix = factory[dot_pos..];

        // 1차: rename된 식별자 탐색 (React → React$84)
        for (meta.symbol_ids, 0..) |maybe_sid, node_i| {
            const sid = maybe_sid orelse continue;
            const new_name = meta.renames.get(sid) orelse continue;
            const node_idx: NodeIndex = @enumFromInt(node_i);
            const node = ast.getNode(node_idx);
            if (node.tag != .identifier_reference and node.tag != .binding_identifier) continue;
            if (std.mem.eql(u8, ast.getText(node.data.string_ref), prefix)) {
                return std.fmt.allocPrint(allocator, "{s}{s}", .{ new_name, suffix }) catch null;
            }
        }

        // 2차: rename 안 된 식별자라도 symbol_id가 있으면 스코프에 존재 → null (원본 사용)
        // symbol_id가 없으면 이 모듈에 해당 import가 없으므로
        // 다른 모듈의 rename된 이름을 찾아야 함
        var has_unrenamed = false;
        for (meta.symbol_ids, 0..) |maybe_sid, node_i| {
            const sid = maybe_sid orelse continue;
            if (meta.renames.get(sid) != null) continue; // 이미 rename된 건 스킵
            const node_idx: NodeIndex = @enumFromInt(node_i);
            const node = ast.getNode(node_idx);
            if (node.tag != .identifier_reference and node.tag != .binding_identifier) continue;
            if (std.mem.eql(u8, ast.getText(node.data.string_ref), prefix)) {
                has_unrenamed = true;
                break;
            }
        }
        if (has_unrenamed) return null; // 원본 이름이 스코프에 있으므로 그대로 사용

        // 3차: 이 모듈에 React import가 없고, 다른 모듈이 rename했을 수 있음
        // renames 맵 전체에서 "React$" 패턴의 rename을 찾아 사용
        var it = meta.renames.iterator();
        while (it.next()) |entry| {
            const new_name = entry.value_ptr.*;
            // "React$1", "React$84" 등 prefix + "$" + 숫자 패턴
            if (new_name.len > prefix.len and std.mem.startsWith(u8, new_name, prefix) and new_name[prefix.len] == '$') {
                return std.fmt.allocPrint(allocator, "{s}{s}", .{ new_name, suffix }) catch null;
            }
        }

        return null;
    }

    /// tag name 출력: 소문자면 문자열("div"), 그 외 식별자(MyComp)
    fn emitJSXTagName(self: *Codegen, tag_name_idx: NodeIndex) !void {
        const tag_node = self.ast.getNode(tag_name_idx);

        // jsx_member_expression: <Foo.Bar> → Foo.Bar (왼쪽은 rename 반영)
        if (tag_node.tag == .jsx_member_expression) {
            try self.emitJSXTagName(tag_node.data.binary.left);
            try self.writeByte('.');
            const right_node = self.ast.getNode(tag_node.data.binary.right);
            try self.writeSpan(right_node.data.string_ref);
            return;
        }

        const tag_text = self.ast.source[tag_node.span.start..tag_node.span.end];
        if (tag_text.len > 0 and tag_text[0] >= 'a' and tag_text[0] <= 'z') {
            // 소문자 → HTML 태그 → 문자열
            try self.writeByte('"');
            try self.write(tag_text);
            try self.writeByte('"');
        } else {
            // 대문자 → 컴포넌트 → 번들러 rename 반영
            if (self.options.linking_metadata) |meta| {
                const sym_id = self.resolveSymbolId(tag_name_idx, meta);
                if (sym_id) |sid| {
                    if (meta.renames.get(sid)) |new_name| {
                        try self.write(new_name);
                        return;
                    }
                }
            }
            try self.write(tag_text);
        }
    }

    /// classic 모드: attributes → ,{key:val,...} or ,null
    fn emitJSXAttrsClassic(self: *Codegen, attrs_start: u32, attrs_len: u32) !void {
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

    /// automatic 모드: { ...attrs(key제외), children } props 객체 출력
    fn emitJSXPropsAutomatic(self: *Codegen, attrs_start: u32, attrs_len: u32, children_start: u32, children_len: u32, key_idx: ?u32, effective_children: u32) !void {
        const has_attrs = attrs_len > (if (key_idx != null) @as(u32, 1) else @as(u32, 0));

        if (!has_attrs and effective_children == 0) {
            try self.write("{}");
            return;
        }

        try self.write("{ ");
        var first = true;

        // attrs (key 제외)
        if (attrs_len > 0) {
            const attr_indices = self.ast.extra_data.items[attrs_start .. attrs_start + attrs_len];
            for (attr_indices, 0..) |raw_idx, i| {
                if (key_idx != null and i == key_idx.?) continue;
                if (!first) try self.write(", ");
                first = false;
                const attr = self.ast.getNode(@enumFromInt(raw_idx));
                if (attr.tag == .jsx_attribute) {
                    try self.emitJSXAttribute(attr);
                } else if (attr.tag == .jsx_spread_attribute) {
                    try self.write("...");
                    try self.emitNode(attr.data.unary.operand);
                }
            }
        }

        // children
        if (effective_children > 0) {
            if (!first) try self.write(", ");
            try self.write("children: ");
            if (effective_children > 1) {
                try self.writeByte('[');
                try self.emitJSXChildrenAutomatic(children_start, children_len);
                try self.writeByte(']');
            } else {
                // 단일 child: 배열 아닌 값으로
                try self.emitJSXSingleChild(children_start, children_len);
            }
        }

        try self.write(" }");
    }

    /// classic 모드: children을 가변 인수로 출력
    fn emitJSXChildrenClassic(self: *Codegen, start: u32, len: u32) !void {
        if (len == 0) return;
        const indices = self.ast.extra_data.items[start .. start + len];
        for (indices) |raw_idx| {
            const child = self.ast.getNode(@enumFromInt(raw_idx));
            if (child.tag == .jsx_text) {
                const trimmed = self.trimJSXText(child);
                if (trimmed.len == 0) continue;
                if (self.options.minify_whitespace) try self.write(",\"") else try self.write(", \"");
                try self.writeJSXTextEscaped(trimmed);
                try self.writeByte('"');
            } else {
                if (child.tag == .jsx_expression_container and child.data.unary.operand.isNone()) continue;
                if (self.options.minify_whitespace) try self.writeByte(',') else try self.write(", ");
                if (child.tag == .jsx_spread_child) {
                    try self.write("...");
                    try self.emitNode(child.data.unary.operand);
                } else {
                    try self.emitNode(@enumFromInt(raw_idx));
                }
            }
        }
    }

    /// automatic 모드: children을 배열 요소로 출력 (쉼표 구분)
    fn emitJSXChildrenAutomatic(self: *Codegen, start: u32, len: u32) !void {
        if (len == 0) return;
        var first = true;
        const indices = self.ast.extra_data.items[start .. start + len];
        for (indices) |raw_idx| {
            const child = self.ast.getNode(@enumFromInt(raw_idx));
            if (child.tag == .jsx_text) {
                const trimmed = self.trimJSXText(child);
                if (trimmed.len == 0) continue;
                if (!first) try self.write(", ");
                first = false;
                try self.writeByte('"');
                try self.writeJSXTextEscaped(trimmed);
                try self.writeByte('"');
            } else {
                if (child.tag == .jsx_expression_container and child.data.unary.operand.isNone()) continue;
                if (!first) try self.write(", ");
                first = false;
                if (child.tag == .jsx_spread_child) {
                    try self.write("...");
                    try self.emitNode(child.data.unary.operand);
                } else {
                    try self.emitNode(@enumFromInt(raw_idx));
                }
            }
        }
    }

    /// 단일 child를 출력 (배열 아닌 값)
    fn emitJSXSingleChild(self: *Codegen, start: u32, len: u32) !void {
        const indices = self.ast.extra_data.items[start .. start + len];
        for (indices) |raw_idx| {
            const child = self.ast.getNode(@enumFromInt(raw_idx));
            if (child.tag == .jsx_text) {
                const trimmed = self.trimJSXText(child);
                if (trimmed.len == 0) continue;
                try self.writeByte('"');
                try self.writeJSXTextEscaped(trimmed);
                try self.writeByte('"');
                return;
            }
            if (child.tag == .jsx_expression_container and child.data.unary.operand.isNone()) continue;
            if (child.tag == .jsx_spread_child) {
                try self.write("...");
                try self.emitNode(child.data.unary.operand);
            } else {
                try self.emitNode(@enumFromInt(raw_idx));
            }
            return;
        }
    }

    /// JSX text 공백 트리밍 (esbuild 호환).
    /// 줄바꿈 있으면 전체 trim, 없으면 원본 유지. 공백만이면 빈 문자열.
    /// JSX 텍스트: 줄바꿈+주변 공백을 단일 스페이스로 정규화, HTML entity 디코딩, 특수문자 이스케이프.
    /// esbuild의 fixWhitespaceAndDecodeJSXEntities 알고리즘:
    /// 1. 라인별로 처리 (개행으로 분할)
    /// 2. 각 라인의 첫 비공백~마지막 비공백까지만 취함 (라인별 trim)
    /// 3. 라인 간에는 공백 1개만 삽입
    /// 4. 첫 라인이 공백만이면 생략, 마지막 라인이 공백만이면 생략
    fn writeJSXTextEscaped(self: *Codegen, text: []const u8) !void {
        // 라인별로 처리
        var line_start: usize = 0;
        var first_non_empty_line = true;
        var line_idx: usize = 0;

        while (line_start <= text.len) {
            // 현재 라인의 끝 찾기
            var line_end = line_start;
            while (line_end < text.len and text[line_end] != '\n' and text[line_end] != '\r') {
                line_end += 1;
            }

            const line = text[line_start..line_end];
            const is_first_line = (line_idx == 0);

            // 다음 라인 시작 위치 계산
            var next_start = line_end;
            if (next_start < text.len) {
                if (text[next_start] == '\r' and next_start + 1 < text.len and text[next_start + 1] == '\n') {
                    next_start += 2; // \r\n
                } else {
                    next_start += 1; // \n or \r
                }
            }

            // 마지막 라인인지 확인
            const is_last_line = (next_start >= text.len);

            // 라인별 trim
            const trimmed = std.mem.trim(u8, line, " \t");

            if (trimmed.len > 0) {
                // 라인 간 공백 삽입 (첫 비어있지 않은 라인이 아닌 경우)
                if (!first_non_empty_line) {
                    try self.writeByte(' ');
                }
                first_non_empty_line = false;

                // 첫 라인이면 leading whitespace 보존, 마지막 라인이면 trailing whitespace 보존
                const output_text = if (is_first_line and is_last_line)
                    line // 단일 라인이면 원본 그대로
                else if (is_first_line)
                    std.mem.trimRight(u8, line, " \t") // 첫 라인: trailing만 trim
                else if (is_last_line)
                    std.mem.trimLeft(u8, line, " \t") // 마지막 라인: leading만 trim
                else
                    trimmed; // 중간 라인: 양쪽 trim

                try self.writeJSXLineContent(output_text);
            }

            if (next_start <= line_start and line_end >= text.len) break;
            line_start = next_start;
            line_idx += 1;
            if (line_start > text.len) break;
        }
    }

    /// JSX 텍스트 라인 하나의 내용을 출력 (entity 디코딩 + 이스케이프)
    fn writeJSXLineContent(self: *Codegen, line: []const u8) !void {
        var i: usize = 0;
        while (i < line.len) {
            const c = line[i];
            if (c == '&') {
                // HTML entity 디코딩 시도
                if (self.tryDecodeHTMLEntity(line, i)) |result| {
                    try self.writeCodepointEscaped(result.codepoint);
                    i = result.end;
                    continue;
                }
            }
            switch (c) {
                '"' => {
                    try self.write("\\\"");
                    i += 1;
                },
                '\\' => {
                    try self.write("\\\\");
                    i += 1;
                },
                else => {
                    try self.writeByte(c);
                    i += 1;
                },
            }
        }
    }

    const EntityResult = struct { codepoint: u21, end: usize };

    /// `&...;` 패턴을 파싱하여 codepoint와 끝 위치를 반환. 매칭 실패 시 null.
    fn tryDecodeHTMLEntity(_: *Codegen, text: []const u8, start: usize) ?EntityResult {
        // start는 '&' 위치
        const after_amp = start + 1;
        if (after_amp >= text.len) return null;

        // ';' 찾기 (최대 10자 이내)
        const max_end = @min(after_amp + 10, text.len);
        var semi_pos: ?usize = null;
        for (after_amp..max_end) |j| {
            if (text[j] == ';') {
                semi_pos = j;
                break;
            }
        }
        const semi = semi_pos orelse return null;
        const entity_body = text[after_amp..semi];

        if (entity_body.len >= 2 and entity_body[0] == '#') {
            // numeric entity
            if (entity_body[1] == 'x' or entity_body[1] == 'X') {
                // hex: &#xHH;
                const hex_str = entity_body[2..];
                if (hex_str.len == 0) return null;
                const cp = std.fmt.parseInt(u21, hex_str, 16) catch return null;
                return .{ .codepoint = cp, .end = semi + 1 };
            } else {
                // decimal: &#NNN;
                const dec_str = entity_body[1..];
                if (dec_str.len == 0) return null;
                const cp = std.fmt.parseInt(u21, dec_str, 10) catch return null;
                return .{ .codepoint = cp, .end = semi + 1 };
            }
        }

        // named entities
        const cp = namedEntityToCodepoint(entity_body) orelse return null;
        return .{ .codepoint = cp, .end = semi + 1 };
    }

    /// 잘 알려진 named HTML entity를 codepoint로 변환
    fn namedEntityToCodepoint(name: []const u8) ?u21 {
        const Map = struct {
            n: []const u8,
            cp: u21,
        };
        const entities = [_]Map{
            .{ .n = "amp", .cp = '&' },
            .{ .n = "lt", .cp = '<' },
            .{ .n = "gt", .cp = '>' },
            .{ .n = "quot", .cp = '"' },
            .{ .n = "apos", .cp = '\'' },
            .{ .n = "nbsp", .cp = 0xA0 },
            .{ .n = "copy", .cp = 0xA9 },
            .{ .n = "reg", .cp = 0xAE },
            .{ .n = "trade", .cp = 0x2122 },
            .{ .n = "mdash", .cp = 0x2014 },
            .{ .n = "ndash", .cp = 0x2013 },
            .{ .n = "laquo", .cp = 0xAB },
            .{ .n = "raquo", .cp = 0xBB },
            .{ .n = "bull", .cp = 0x2022 },
            .{ .n = "hellip", .cp = 0x2026 },
            .{ .n = "ensp", .cp = 0x2002 },
            .{ .n = "emsp", .cp = 0x2003 },
            .{ .n = "thinsp", .cp = 0x2009 },
            .{ .n = "zwnj", .cp = 0x200C },
            .{ .n = "zwj", .cp = 0x200D },
        };
        for (entities) |e| {
            if (std.mem.eql(u8, name, e.n)) return e.cp;
        }
        return null;
    }

    /// codepoint를 UTF-8로 인코딩하여 출력. `"`, `\`는 이스케이프.
    fn writeCodepointEscaped(self: *Codegen, cp: u21) !void {
        if (cp == '"') {
            try self.write("\\\"");
            return;
        }
        if (cp == '\\') {
            try self.write("\\\\");
            return;
        }
        // ASCII 범위
        if (cp < 0x80) {
            try self.writeByte(@intCast(cp));
            return;
        }
        // UTF-8 인코딩
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.write(buf[0..len]);
    }

    fn trimJSXText(self: *Codegen, child: Node) []const u8 {
        const text = self.ast.source[child.span.start..child.span.end];
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed.len == 0) return "";
        if (std.mem.indexOfAny(u8, text, "\n\r") == null) return text;
        return trimmed;
    }

    /// 유효 children 수 카운트 (공백만인 text 제외)
    fn countEffectiveChildren(self: *Codegen, start: u32, len: u32) u32 {
        if (len == 0) return 0;
        var count: u32 = 0;
        const indices = self.ast.extra_data.items[start .. start + len];
        for (indices) |raw_idx| {
            const child = self.ast.getNode(@enumFromInt(raw_idx));
            if (child.tag == .jsx_text) {
                if (self.trimJSXText(child).len == 0) continue;
            } else if (child.tag == .jsx_expression_container and child.data.unary.operand.isNone()) {
                continue;
            }
            count += 1;
        }
        return count;
    }

    const KeySearchResult = struct {
        key_idx: ?u32,
        key_after_spread: bool,
    };

    /// attrs에서 key={...} 속성의 인덱스를 찾는다 (automatic 모드에서 분리용).
    /// key_after_spread: key가 spread attribute 뒤에 위치하면 true (createElement 폴백 필요).
    fn findJSXKeyAttr(self: *Codegen, attrs_start: u32, attrs_len: u32) KeySearchResult {
        if (attrs_len == 0) return .{ .key_idx = null, .key_after_spread = false };
        var seen_spread = false;
        const attr_indices = self.ast.extra_data.items[attrs_start .. attrs_start + attrs_len];
        for (attr_indices, 0..) |raw_idx, i| {
            const attr = self.ast.getNode(@enumFromInt(raw_idx));
            if (attr.tag == .jsx_spread_attribute) {
                seen_spread = true;
            } else if (attr.tag == .jsx_attribute) {
                const key_node = self.ast.getNode(attr.data.binary.left);
                const name = self.ast.source[key_node.span.start..key_node.span.end];
                if (std.mem.eql(u8, name, "key")) {
                    return .{ .key_idx = @intCast(i), .key_after_spread = seen_spread };
                }
            }
        }
        return .{ .key_idx = null, .key_after_spread = false };
    }

    /// jsxDEV source info 출력: , { fileName: "...", lineNumber: N, columnNumber: N }
    fn emitJSXDevSource(self: *Codegen, span: Span) !void {
        try self.write(", { fileName: \"");
        try self.write(self.options.jsx_filename);
        try self.write("\", lineNumber: ");
        const loc = self.spanToLineCol(span.start);
        try self.writeU32(loc.line);
        try self.write(", columnNumber: ");
        try self.writeU32(loc.col);
        try self.write(" }");
    }

    fn writeU32(self: *Codegen, n: u32) !void {
        var buf: [10]u8 = undefined;
        var len: u8 = 0;
        var v = n;
        if (v == 0) {
            try self.writeByte('0');
            return;
        }
        while (v > 0) : (v /= 10) {
            buf[9 - len] = @intCast('0' + @as(u8, @intCast(v % 10)));
            len += 1;
        }
        try self.write(buf[10 - len .. 10]);
    }

    const LineLoc = struct { line: u32, col: u32 };

    fn spanToLineCol(self: *Codegen, offset: u32) LineLoc {
        if (self.line_offsets.len == 0) return .{ .line = 1, .col = 1 };
        // binary search for line
        var lo: u32 = 0;
        var hi: u32 = @intCast(self.line_offsets.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_offsets[mid] <= offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line = lo; // 1-based
        const line_start = if (line > 1) self.line_offsets[line - 1] else 0;

        // UTF-16 code unit 기준 column 계산 (JSX devtools 호환)
        const source = self.ast.source;
        var col: u32 = 0;
        var i: u32 = line_start;
        while (i < offset and i < source.len) {
            const byte = source[i];
            if (byte < 0x80) {
                col += 1;
                i += 1;
            } else if (byte < 0xC0) {
                // continuation byte (잘못된 시작이면 스킵)
                i += 1;
            } else if (byte < 0xE0) {
                col += 1; // 2-byte UTF-8 → 1 UTF-16 unit
                i += 2;
            } else if (byte < 0xF0) {
                col += 1; // 3-byte UTF-8 → 1 UTF-16 unit
                i += 3;
            } else {
                col += 2; // 4-byte UTF-8 → 2 UTF-16 units (surrogate pair)
                i += 4;
            }
        }
        return .{ .line = line, .col = col + 1 }; // 1-based
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
        const text = self.ast.source[node.span.start..node.span.end];
        try self.writeByte('"');
        try self.writeJSXTextEscaped(text);
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
