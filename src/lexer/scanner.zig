//! ZTS Lexer Scanner
//!
//! 소스 코드를 순회하며 토큰을 하나씩 생성하는 핵심 모듈.
//! 파서가 `next()`를 호출하면 다음 토큰을 스캔한다 (D036).
//!
//! 설계:
//! - UTF-8 소스를 직접 순회 (D035)
//! - byte offset으로 위치 추적 (D015)
//! - line offset 테이블을 구축하여 line/column을 lazy 계산
//! - BOM 스킵, 줄 끝 문자 전부 인식 (D019)
//!
//! 참고: references/bun/src/js_lexer.zig, references/esbuild/internal/js_lexer/js_lexer.go

const std = @import("std");
const token = @import("token.zig");
const unicode = @import("unicode.zig");
const regexp_mod = @import("../regexp/mod.zig");
const profile = @import("../profile.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = token.Span;

/// 스캔 중 발견된 주석 하나를 나타낸다.
/// start/end는 소스 코드의 byte offset이며, 구분자(// 또는 /* */)를 포함한다.
pub const Comment = struct {
    /// 주석 시작 byte offset (첫 번째 `/` 위치)
    start: u32,
    /// 주석 끝 byte offset (single-line: 줄바꿈 직전, multi-line: `*/` 직후)
    end: u32,
    /// true이면 `/* ... */`, false이면 `// ...`
    is_multiline: bool,
    /// legal comment: @license, @preserve, 또는 /*! 로 시작 (D022)
    /// minify 모드에서도 보존해야 하는 주석
    is_legal: bool = false,
};

/// 소스 코드를 토큰으로 분리하는 렉서.
///
/// 사용법:
/// ```zig
/// var lexer = Scanner.init(source);
/// lexer.next(); // 첫 토큰 스캔
/// while (lexer.token.kind != .eof) {
///     // 토큰 처리
///     lexer.next();
/// }
/// ```
pub const Scanner = struct {
    /// 메모리 할당자. ArrayList 메서드 호출에 사용한다.
    allocator: std.mem.Allocator,

    /// 소스 코드 (UTF-8)
    source: []const u8,

    /// 현재 읽기 위치 (byte offset). 다음에 읽을 바이트를 가리킨다.
    current: u32 = 0,

    /// 현재 토큰의 시작 위치 (byte offset)
    start: u32 = 0,

    /// 현재 토큰
    token: Token = .{},

    /// 줄 번호 (0-based). 줄바꿈을 만날 때마다 증가.
    line: u32 = 0,

    /// 현재 줄의 시작 byte offset. column = current - line_start.
    line_start: u32 = 0,

    /// 줄 시작 offset 테이블 (소스맵, 에러 메시지용).
    /// line_offsets[i] = i번째 줄의 시작 byte offset.
    /// line 0은 항상 offset 0이므로 초기값 포함.
    line_offsets: std.ArrayList(u32),

    /// 템플릿 리터럴 중첩 깊이 스택.
    /// 템플릿 안의 `${` 마다 brace depth를 push하고, 대응하는 `}`에서 pop한다.
    /// 스택이 비어있지 않으면 `}`를 만났을 때 템플릿 중간/끝으로 스캔해야 한다.
    template_depth_stack: std.ArrayList(u32),

    /// 현재 brace depth. `{`이면 +1, `}`이면 -1.
    brace_depth: u32 = 0,

    /// 이전 토큰의 종류. regex vs division 판별에 사용 (slashIsRegex).
    prev_token_kind: Kind = .eof,

    /// JSX pragma (D026): 파일 상단 주석에서 감지.
    /// `@jsx h` → jsx_pragma = "h"
    jsx_pragma: ?[]const u8 = null,
    /// `@jsxFrag Fragment` → jsx_frag_pragma = "Fragment"
    jsx_frag_pragma: ?[]const u8 = null,
    /// `@jsxRuntime automatic` → jsx_runtime_pragma = "automatic"
    jsx_runtime_pragma: ?[]const u8 = null,
    /// `@jsxImportSource preact` → jsx_import_source_pragma = "preact"
    jsx_import_source_pragma: ?[]const u8 = null,

    /// Flow pragma 감지: 파일 상단 주석에서 `@flow` 또는 `@flow strict`를 발견하면 true.
    /// 파서가 is_flow 모드를 결정하는 데 사용한다.
    has_flow_pragma: bool = false,

    /// Flow comment 모드: `/*::` 또는 `/*:` 주석 안의 코드를 토큰으로 공급 중.
    /// `*/`를 만나면 false로 복귀하고 다음 토큰을 스캔한다.
    in_flow_comment: bool = false,

    /// 스캔 중 발견된 주석 리스트 (소스 순서).
    /// codegen에서 주석 보존에 사용한다.
    comments: std.ArrayList(Comment),

    /// 이스케이프 디코딩 버퍼 (decodeIdentifierEscapes에서 사용).
    /// Scanner 필드에 두어 dangling pointer 방지. 키워드 최대 길이(~12)+여유.
    decode_buf: [64]u8 = undefined,

    /// ECMAScript Annex B: HTML-like 주석 (<!-- 및 -->).
    /// module 모드에서는 금지, non-module(script)에서만 주석으로 처리.
    /// 파서가 configureFromExtension()에서 설정한다.
    is_module: bool = false,

    /// 입력의 시작 부분인지 (아직 실제 토큰이 생성되지 않은 상태).
    /// --> HTML close comment가 파일 첫 줄에서 허용되는 조건 판별에 사용.
    at_start_of_input: bool = true,

    /// 소스를 UTF-8로 읽고 Scanner를 초기화한다.
    /// BOM이 있으면 스킵한다 (D019).
    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Scanner {
        // 4GB 이상의 소스는 u32 offset으로 표현 불가 (D015)
        std.debug.assert(source.len <= std.math.maxInt(u32));

        var line_offsets: std.ArrayList(u32) = .empty;
        // 첫 번째 줄의 시작 offset은 항상 0. 이 append가 실패하면 getLineColumn()이 동작 불가.
        try line_offsets.append(allocator, 0);

        var scanner = Scanner{
            .allocator = allocator,
            .source = source,
            .line_offsets = line_offsets,
            .template_depth_stack = .empty,
            .comments = .empty,
        };

        // UTF-8 BOM 스킵 (0xEF 0xBB 0xBF)
        if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) {
            scanner.current = 3;
            scanner.start = 3;
            scanner.line_start = 3;
            // line_offsets[0]도 BOM 이후로 업데이트
            scanner.line_offsets.items[0] = 3;
        }

        return scanner;
    }

    pub fn deinit(self: *Scanner) void {
        self.line_offsets.deinit(self.allocator);
        self.template_depth_stack.deinit(self.allocator);
        self.comments.deinit(self.allocator);
    }

    // ====================================================================
    // 기본 읽기 함수
    // ====================================================================

    /// 현재 위치의 바이트를 반환한다. 끝이면 0을 반환.
    fn peek(self: *const Scanner) u8 {
        if (self.current >= self.source.len) return 0;
        return self.source[self.current];
    }

    /// 현재 위치 + offset의 바이트를 반환한다. 끝이면 0을 반환.
    fn peekAt(self: *const Scanner, offset: u32) u8 {
        const pos = self.current + offset;
        if (pos >= self.source.len) return 0;
        return self.source[pos];
    }

    /// 현재 위치를 1바이트 전진하고 이전 바이트를 반환한다.
    fn advance(self: *Scanner) u8 {
        if (self.current >= self.source.len) return 0;
        const byte = self.source[self.current];
        self.current += 1;
        return byte;
    }

    /// 소스 끝에 도달했는지.
    fn isAtEnd(self: *const Scanner) bool {
        return self.current >= self.source.len;
    }

    /// 현재 토큰의 소스 텍스트를 반환한다.
    pub fn tokenText(self: *const Scanner) []const u8 {
        return self.source[self.start..self.current];
    }

    /// byte offset으로부터 line과 column을 계산한다 (0-based).
    /// line_offsets 테이블에서 이진 탐색.
    pub fn getLineColumn(self: *const Scanner, offset: u32) struct { line: u32, column: u32 } {
        // 이진 탐색: offset보다 작거나 같은 가장 큰 line_start를 찾는다
        const offsets = self.line_offsets.items;
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
        const line_idx = lo - 1;
        return .{
            .line = line_idx,
            .column = offset - offsets[line_idx],
        };
    }

    // ====================================================================
    // 줄바꿈 처리
    // ====================================================================

    /// 현재 위치가 U+2028 (LS) 또는 U+2029 (PS)인지 확인한다.
    /// UTF-8: E2 80 A8 또는 E2 80 A9.
    fn isLineSeparator(self: *const Scanner) bool {
        return self.current + 2 < self.source.len and
            self.source[self.current] == 0xE2 and
            self.source[self.current + 1] == 0x80 and
            (self.source[self.current + 2] == 0xA8 or self.source[self.current + 2] == 0xA9);
    }

    /// 현재 바이트가 줄바꿈의 시작 바이트인지 (빠른 체크).
    fn isNewlineStart(c: u8) bool {
        return c == '\n' or c == '\r' or c == 0xE2;
    }

    /// 줄 offset 테이블에 새 줄을 기록한다.
    fn recordNewline(self: *Scanner) !void {
        self.line += 1;
        self.line_start = self.current;
        try self.line_offsets.append(self.allocator, self.current);
    }

    /// 줄바꿈 문자를 처리한다.
    /// \n, \r\n, \r, U+2028 (LS), U+2029 (PS) 전부 인식 (D019).
    /// 줄바꿈이면 true를 반환하고 current를 전진시킨다.
    fn handleNewline(self: *Scanner) !bool {
        const c = self.peek();
        if (c == '\n') {
            self.current += 1;
            try self.recordNewline();
            return true;
        }
        if (c == '\r') {
            self.current += 1;
            if (self.peek() == '\n') self.current += 1;
            try self.recordNewline();
            return true;
        }
        if (self.isLineSeparator()) {
            self.current += 3;
            try self.recordNewline();
            return true;
        }
        return false;
    }

    // ====================================================================
    // 공백 스킵
    // ====================================================================

    /// SIMD로 16바이트씩 스캔하여 sentinel 문자가 아닌 바이트를 건너뜀.
    /// 첫 번째 sentinel 위치에서 멈추거나, 남은 바이트가 16 미만이면 종료.
    /// comptime sentinels는 컴파일 타임 상수, extra는 런타임 값(예: quote 문자).
    inline fn simdSkipUntilAny(self: *Scanner, comptime sentinels: []const u8, extra: ?u8) void {
        while (self.current + 16 <= self.source.len) {
            const chunk: @Vector(16, u8) = self.source[self.current..][0..16].*;
            var mask: @Vector(16, bool) = @splat(false);
            inline for (sentinels) |s| {
                mask = mask | (chunk == @as(@Vector(16, u8), @splat(s)));
            }
            if (extra) |e| {
                mask = mask | (chunk == @as(@Vector(16, u8), @splat(e)));
            }
            const bits = @as(u16, @bitCast(mask));
            if (bits == 0) {
                self.current += 16;
            } else {
                self.current += @ctz(bits);
                return;
            }
        }
    }

    /// 공백 문자를 스킵한다.
    /// 줄바꿈을 만나면 has_newline_before를 true로 설정.
    fn skipWhitespace(self: *Scanner) !void {
        // SIMD fast path: 16바이트씩 ASCII 공백/탭 스킵
        while (self.current + 16 <= self.source.len) {
            const chunk: @Vector(16, u8) = self.source[self.current..][0..16].*;
            // 공백(' '=0x20) 또는 탭('\t'=0x09) 이외의 문자가 있으면 중단
            const spaces = chunk == @as(@Vector(16, u8), @splat(@as(u8, ' ')));
            const tabs = chunk == @as(@Vector(16, u8), @splat(@as(u8, '\t')));
            const ws_mask = @as(u16, @bitCast(spaces | tabs));
            if (ws_mask == 0xFFFF) {
                // 16바이트 모두 공백/탭
                self.current += 16;
            } else {
                // 첫 번째 비공백 위치로 이동
                const skip = @ctz(~ws_mask);
                self.current += skip;
                break;
            }
        }

        // 스칼라 루프: 나머지 + 줄바꿈/유니코드 공백 처리
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', 0x0B, 0x0C => {
                    // 일반 공백: space, tab, vertical tab, form feed
                    self.current += 1;
                },
                '\n', '\r' => {
                    // 줄바꿈
                    _ = try self.handleNewline();
                    self.token.has_newline_before = true;
                },
                0xE2 => {
                    // U+2028 (LS), U+2029 (PS) — 줄바꿈
                    if (try self.handleNewline()) {
                        self.token.has_newline_before = true;
                    } else if (self.current + 2 < self.source.len) {
                        // Unicode Space_Separator (USP): U+2000-U+200A, U+202F, U+205F
                        const b1 = self.source[self.current + 1];
                        const b2 = self.source[self.current + 2];
                        if (b1 == 0x80 and b2 >= 0x80 and b2 <= 0x8A) {
                            // U+2000-U+200A (EN QUAD, EM QUAD, EN SPACE, EM SPACE, etc.)
                            self.current += 3;
                        } else if (b1 == 0x80 and b2 == 0xAF) {
                            // U+202F (NARROW NO-BREAK SPACE)
                            self.current += 3;
                        } else if (b1 == 0x81 and b2 == 0x9F) {
                            // U+205F (MEDIUM MATHEMATICAL SPACE)
                            self.current += 3;
                        } else {
                            return;
                        }
                    } else {
                        return;
                    }
                },
                0xC2 => {
                    // U+00A0 (NBSP) = C2 A0
                    if (self.peekAt(1) == 0xA0) {
                        self.current += 2;
                    } else {
                        return;
                    }
                },
                0xE3 => {
                    // U+3000 (IDEOGRAPHIC SPACE) = E3 80 80
                    if (self.peekAt(1) == 0x80 and self.peekAt(2) == 0x80) {
                        self.current += 3;
                    } else {
                        return;
                    }
                },
                0xE1 => {
                    // U+1680 (OGHAM SPACE MARK) = E1 9A 80
                    if (self.peekAt(1) == 0x9A and self.peekAt(2) == 0x80) {
                        self.current += 3;
                    } else {
                        return;
                    }
                },
                0xEF => {
                    // U+FEFF (BOM/ZWNBSP) = EF BB BF
                    if (self.peekAt(1) == 0xBB and self.peekAt(2) == 0xBF) {
                        self.current += 3;
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    // ====================================================================
    // 메인 스캔 루프
    // ====================================================================

    /// 다음 토큰을 스캔한다.
    /// 파서가 이 함수를 반복 호출하여 토큰을 소비한다.
    pub fn next(self: *Scanner) !void {
        var scope = profile.begin(.scan);
        defer scope.end();

        self.token.has_newline_before = false;
        self.token.has_pure_comment_before = false;
        self.token.has_no_side_effects_comment = false;
        self.token.has_escape = false;
        self.token.has_legacy_octal = false;

        // 주석을 만나면 스킵하고 다시 스캔해야 하므로 루프
        while (true) {
            // 공백 스킵 (줄바꿈 추적 포함)
            try self.skipWhitespace();

            // Flow comment 모드: `*/`를 만나면 모드 종료 후 다음 토큰으로
            if (self.in_flow_comment and self.current + 1 < self.source.len and
                self.source[self.current] == '*' and self.source[self.current + 1] == '/')
            {
                self.current += 2; // skip */
                self.in_flow_comment = false;
                continue;
            }

            // 토큰 시작 위치 기록
            self.start = self.current;

            // 소스 끝 도달
            if (self.isAtEnd()) {
                self.token.kind = .eof;
                self.token.span = .{ .start = self.start, .end = self.current };
                return;
            }

            const c = self.advance();

            self.token.kind = switch (c) {
                // 단일 문자 토큰
                '(' => .l_paren,
                ')' => .r_paren,
                '[' => .l_bracket,
                ']' => .r_bracket,
                '{' => blk: {
                    self.brace_depth += 1;
                    break :blk .l_curly;
                },
                '}' => blk: {
                    // brace depth 감소
                    if (self.brace_depth > 0) self.brace_depth -= 1;
                    // 감소 후 스택 top과 비교: 템플릿 리터럴 안의 `}` 인지 확인
                    if (self.template_depth_stack.items.len > 0 and
                        self.brace_depth == self.template_depth_stack.items[self.template_depth_stack.items.len - 1])
                    {
                        break :blk try self.scanTemplateContinuation();
                    }
                    break :blk .r_curly;
                },
                ';' => .semicolon,
                ',' => .comma,
                '~' => .tilde,
                '@' => .at,
                ':' => .colon,

                // 후속 문자에 따라 분기하는 토큰 — 추후 PR에서 구현
                // 현재는 단일 문자만 처리
                '.' => self.scanDot(),
                '+' => self.scanPlus(),
                '-' => try self.scanMinus(),
                '*' => self.scanStar(),
                '/' => try self.scanSlash(),
                '%' => self.scanPercent(),
                '<' => try self.scanLAngle(),
                '>' => self.scanRAngle(),
                '=' => self.scanEquals(),
                '!' => self.scanBang(),
                '&' => self.scanAmp(),
                '|' => self.scanPipe(),
                '^' => self.scanCaret(),
                '?' => self.scanQuestion(),

                // 리터럴 — 추후 PR에서 세부 구현
                '0'...'9' => self.scanNumericLiteral(c),
                '\'', '"' => try self.scanStringLiteral(c),
                '`' => try self.scanTemplateLiteral(),

                '#' => blk: {
                    // hashbang (파일 시작) 또는 private identifier
                    if (self.start == 0 or (self.start == 3 and std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF"))) {
                        if (self.peek() == '!') {
                            self.scanHashbang();
                            break :blk .hashbang_comment;
                        }
                    }
                    // private identifier — # 뒤에 IdentifierStart가 있어야 함
                    // ECMAScript: PrivateName :: # IdentifierName
                    // IdentifierName :: IdentifierStart IdentifierName IdentifierPart
                    // ZWNJ (U+200C), ZWJ (U+200D) 는 IdentifierPart이지 IdentifierStart가 아님.
                    // 따라서 #\u200C_X 같은 형태는 SyntaxError.
                    const before_start = self.current;
                    if (!self.scanPrivateIdentifierStart()) {
                        // # 뒤에 유효한 IdentifierStart 없음 → syntax error
                        break :blk .syntax_error;
                    }
                    // IdentifierStart가 확인되었으면 나머지 IdentifierPart를 스캔
                    if (self.current != before_start) {
                        self.scanIdentifierTail();
                    }
                    break :blk .private_identifier;
                },

                else => blk: {
                    // ASCII 식별자 시작
                    if (isAsciiIdentStart(c)) {
                        self.scanIdentifierTail();
                        const text = self.tokenText();
                        // escape가 포함되어 있으면 디코딩 후 키워드 매칭
                        if (std.mem.indexOfScalar(u8, text, '\\') != null) {
                            self.token.has_escape = true;
                            const decoded = self.decodeIdentifierEscapes(text);
                            if (decoded) |name| {
                                if (token.keywords.get(name)) |kw| {
                                    // reserved keyword/literal → escaped_keyword (항상 식별자 사용 불가)
                                    // strict mode reserved (let, yield, implements 등) → escaped_strict_reserved
                                    // contextual keyword (async, from 등) → identifier
                                    break :blk if (kw.isReservedKeyword() or kw.isLiteralKeyword())
                                        .escaped_keyword
                                    else if (kw.isStrictModeReserved() or kw == .kw_let or kw == .kw_yield)
                                        .escaped_strict_reserved
                                    else
                                        .identifier;
                                }
                            }
                            break :blk .identifier;
                        }
                        break :blk token.keywords.get(text) orelse .identifier;
                    }
                    // \u 유니코드 이스케이프로 시작하는 식별자
                    if (c == '\\') {
                        self.token.has_escape = true;
                        // advance()에서 이미 \ 를 소비했으므로 current-1 부터
                        self.current -= 1; // put back '\'
                        const esc_start = self.current;
                        if (self.scanIdentifierEscape()) {
                            // 식별자 시작: 디코딩된 코드포인트가 ID_Start인지 검증
                            const esc_text = self.source[esc_start..self.current];
                            const start_cp = self.decodeEscapeCodepoint(esc_text);
                            if (start_cp) |cp| {
                                if (cp < 0x80) {
                                    if (!isAsciiIdentStart(@intCast(cp))) {
                                        self.current = esc_start + 1;
                                        break :blk .syntax_error;
                                    }
                                } else if (cp <= 0x10FFFF) {
                                    if (!unicode.isIdentifierStart(@intCast(cp))) {
                                        self.current = esc_start + 1;
                                        break :blk .syntax_error;
                                    }
                                }
                            } else {
                                // 디코딩 실패 (예: \u{00_76}) → 유효하지 않은 이스케이프
                                self.current = esc_start + 1;
                                break :blk .syntax_error;
                            }
                            self.scanIdentifierTail();
                            // 이스케이프를 디코딩하여 키워드인지 판별.
                            // 키워드면 escaped_keyword (식별자로 사용 불가),
                            // 아니면 일반 identifier.
                            const raw = self.tokenText();
                            const decoded = self.decodeIdentifierEscapes(raw);
                            if (decoded) |name| {
                                if (token.keywords.get(name)) |kw| {
                                    break :blk if (kw.isReservedKeyword() or kw.isLiteralKeyword())
                                        .escaped_keyword
                                    else if (kw.isStrictModeReserved() or kw == .kw_let or kw == .kw_yield)
                                        .escaped_strict_reserved
                                    else
                                        .identifier;
                                }
                            }
                            break :blk .identifier;
                        }
                        self.current += 1; // re-consume '\'
                        break :blk .syntax_error;
                    }
                    // Non-ASCII 유니코드 식별자
                    if (c >= 0x80) {
                        // advance()에서 1바이트 소비했으므로 나머지 UTF-8 바이트 소비
                        const start_pos = self.current - 1;
                        const remaining = self.source[start_pos..];
                        const decoded = unicode.decodeUtf8(remaining);
                        if (unicode.isIdentifierStart(decoded.codepoint)) {
                            self.current = @intCast(start_pos + decoded.len);
                            self.scanIdentifierTail();
                            const text = self.tokenText();
                            break :blk token.keywords.get(text) orelse .identifier;
                        }
                    }
                    break :blk .syntax_error;
                },
            };

            // 주석(undetermined)이면 루프를 돌아 다음 토큰 스캔
            if (self.token.kind != .undetermined) {
                self.token.span = .{ .start = self.start, .end = self.current };
                self.prev_token_kind = self.token.kind;
                self.at_start_of_input = false;
                return;
            }
        }
    }

    // ====================================================================
    // JSX 모드 스캔 (파서가 JSX 컨텍스트에서 호출)
    /// 현재 `/` 또는 `/=` 토큰을 regexp literal로 재스캔한다.
    /// 파서가 `yield` 뒤 등 regexp context에서 호출한다.
    pub fn rescanAsRegexp(self: *Scanner) void {
        // 현재 토큰의 시작 위치로 되돌린다 (/ 또는 /= 의 시작)
        self.current = self.start + 1; // opening / 직후
        self.token.kind = self.scanRegExp();
        self.token.span = .{ .start = self.start, .end = self.current };
        self.prev_token_kind = self.token.kind;
    }

    // ====================================================================

    /// JSX 태그 내부의 다음 토큰을 스캔한다.
    /// JSX 태그 안에서는 식별자에 하이픈(-)을 허용하고 (data-value),
    /// 속성 값 문자열은 이스케이프를 처리하지 않는다.
    /// 파서가 `<` 뒤에서 이 함수를 호출한다.
    pub fn nextInsideJSXElement(self: *Scanner) !void {
        var scope = profile.begin(.scan);
        defer scope.end();

        self.token.has_newline_before = false;

        // JSX element 내에서 주석 스킵 (// line comment, /* block comment */)
        while (true) {
            try self.skipWhitespace();
            if (self.current + 1 < self.source.len and self.source[self.current] == '/') {
                if (self.source[self.current + 1] == '/') {
                    // line comment: 줄 끝까지 스킵
                    self.current += 2;
                    while (self.current < self.source.len and
                        self.source[self.current] != '\n' and self.source[self.current] != '\r')
                    {
                        self.current += 1;
                    }
                    self.token.has_newline_before = true;
                    continue;
                } else if (self.source[self.current + 1] == '*') {
                    // block comment: */ 까지 스킵
                    self.current += 2;
                    while (self.current + 1 < self.source.len) {
                        if (self.source[self.current] == '*' and self.source[self.current + 1] == '/') {
                            self.current += 2;
                            break;
                        }
                        if (self.source[self.current] == '\n') self.token.has_newline_before = true;
                        self.current += 1;
                    }
                    continue;
                }
            }
            break;
        }

        self.start = self.current;

        if (self.isAtEnd()) {
            self.token.kind = .eof;
            self.token.span = .{ .start = self.start, .end = self.current };
            return;
        }

        const c = self.advance();
        self.token.kind = switch (c) {
            '>' => .r_angle,
            '<' => .l_angle, // TS JSX type arguments: <Foo<T>/>
            '/' => .slash,
            '=' => .eq,
            '{' => blk: {
                self.brace_depth += 1;
                break :blk .l_curly;
            },
            '\'', '"' => self.scanJSXStringLiteral(c),
            '.' => .dot,
            ':' => .colon,
            else => blk: {
                // JSX 식별자: 하이픈 허용 (data-value, aria-label)
                if (isAsciiIdentStart(c) or c >= 0x80) {
                    self.scanJSXIdentifierTail();
                    break :blk .jsx_identifier;
                }
                break :blk .syntax_error;
            },
        };

        self.token.span = .{ .start = self.start, .end = self.current };
        self.prev_token_kind = self.token.kind;
    }

    /// JSX 자식 위치에서 다음 토큰을 스캔한다 (태그 사이의 텍스트).
    /// `<` 또는 `{`를 만날 때까지 텍스트를 소비한다.
    pub fn nextJSXChild(self: *Scanner) !void {
        var scope = profile.begin(.scan);
        defer scope.end();

        self.token.has_newline_before = false;
        self.start = self.current;

        if (self.isAtEnd()) {
            self.token.kind = .eof;
            self.token.span = .{ .start = self.start, .end = self.current };
            return;
        }

        const c = self.peek();
        if (c == '<') {
            self.current += 1;
            self.token.kind = .l_angle;
        } else if (c == '{') {
            self.current += 1;
            self.brace_depth += 1;
            self.token.kind = .l_curly;
        } else {
            // JSX 텍스트: < 또는 { 또는 EOF 전까지 전부 소비
            try self.scanJSXText();
            self.token.kind = .jsx_text;
        }

        self.token.span = .{ .start = self.start, .end = self.current };
        self.prev_token_kind = self.token.kind;
    }

    /// JSX 텍스트를 스캔한다. `<`, `{`, `}` 전까지 소비.
    fn scanJSXText(self: *Scanner) !void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '<' or c == '{' or c == '}') break;
            if (isNewlineStart(c)) {
                if (try self.handleNewline()) {
                    self.token.has_newline_before = true;
                } else {
                    self.current += 1; // 0xE2이지만 줄바꿈이 아닌 경우
                }
            } else {
                self.current += 1;
            }
        }
    }

    /// JSX 식별자의 나머지를 스캔한다.
    /// 일반 식별자와 달리 하이픈(-)을 허용한다 (data-value, aria-label).
    fn scanJSXIdentifierTail(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isAsciiIdentContinue(c) or c == '-') {
                self.current += 1;
            } else if (c >= 0x80) {
                const remaining = self.source[self.current..];
                const decoded = unicode.decodeUtf8(remaining);
                if (decoded.len == 0) break;
                if (unicode.isIdentifierContinue(decoded.codepoint)) {
                    self.current += decoded.len;
                } else break;
            } else break;
        }
    }

    /// JSX 속성 문자열을 스캔한다.
    /// JS 문자열과 달리 이스케이프 시퀀스를 처리하지 않는다 (\ 는 리터럴).
    fn scanJSXStringLiteral(self: *Scanner, quote: u8) Kind {
        while (!self.isAtEnd()) {
            if (self.peek() == quote) {
                self.current += 1;
                return .string_literal;
            }
            self.current += 1;
        }
        return .syntax_error;
    }

    // ====================================================================
    // 복합 연산자 스캔
    // ====================================================================

    fn scanDot(self: *Scanner) Kind {
        if (self.peek() == '.' and self.peekAt(1) == '.') {
            self.current += 2;
            return .dot3;
        }
        // .5 같은 숫자 리터럴
        const next_char = self.peek();
        if (next_char >= '0' and next_char <= '9') {
            return self.scanDecimalAfterDot();
        }
        return .dot;
    }

    fn scanPlus(self: *Scanner) Kind {
        if (self.peek() == '+') {
            self.current += 1;
            return .plus2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .plus_eq;
        }
        return .plus;
    }

    fn scanMinus(self: *Scanner) !Kind {
        if (self.peek() == '-') {
            // ECMAScript Annex B: --> HTML close comment (non-module only)
            // HTMLCloseComment :: WhiteSpace_opt SingleLineDelimitedCommentSequence_opt --> SingleLineCommentChars_opt
            // `-` 이미 소비됨, 다음이 `->` 이고 줄 시작(has_newline_before) 또는 파일 시작이면 주석.
            // at_start_of_input: 아직 토큰이 생성되지 않은 상태 (whitespace/comments만 있었음).
            const at_line_start = self.token.has_newline_before or self.at_start_of_input;
            if (!self.is_module and self.peekAt(1) == '>' and at_line_start) {
                self.current += 2; // skip ->
                try self.skipLineAndRecordComment(false);
                return .undetermined;
            }
            self.current += 1;
            return .minus2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .minus_eq;
        }
        return .minus;
    }

    fn scanStar(self: *Scanner) Kind {
        // Flow comment 모드: `*/`는 주석 종료 마커.
        // `*`를 되돌리고 .undetermined를 반환하여 next() 루프에서 `*/`를 처리하게 한다.
        if (self.in_flow_comment and self.peek() == '/') {
            self.current -= 1; // advance에서 소비된 `*`를 되돌림
            return .undetermined;
        }
        if (self.peek() == '*') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .star2_eq;
            }
            return .star2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .star_eq;
        }
        return .star;
    }

    fn scanSlash(self: *Scanner) !Kind {
        const next_char = self.peek();
        if (next_char == '/') {
            try self.scanSingleLineComment();
            return .undetermined;
        }
        if (next_char == '*') {
            if (try self.scanMultiLineComment()) return .syntax_error; // 미닫힌 주석
            return .undetermined;
        }

        // regex vs division: 이전 토큰에 기반하여 판별.
        // regex 컨텍스트에서는 /=.../ 도 유효한 regex (`/=/g` 등).
        if (self.prev_token_kind.slashIsRegex()) {
            return self.scanRegExp();
        }

        // division 컨텍스트에서만 /= 대입 연산자
        if (next_char == '=') {
            self.current += 1;
            return .slash_eq;
        }

        return .slash;
    }

    /// 정규식 리터럴을 스캔한다 (/pattern/flags).
    /// opening `/`는 이미 소비된 상태.
    ///
    /// 규칙:
    /// - `\/` 이스케이프된 slash → 정규식 계속
    /// - `[...]` character class 안에서는 `/`가 정규식을 끝내지 않음
    /// - 줄바꿈은 정규식 안에서 불허
    fn scanRegExp(self: *Scanner) Kind {
        var in_class = false; // [...] character class 안인지
        const pattern_start = self.current; // opening `/` 바로 다음 byte

        while (!self.isAtEnd()) {
            const c = self.peek();

            if (c == '\\') {
                // 이스케이프: 다음 문자가 줄바꿈이면 에러 (ECMAScript 12.9.5)
                // RegularExpressionBackslashSequence :: \ RegularExpressionNonTerminator
                // RegularExpressionNonTerminator :: SourceCharacter but not LineTerminator
                self.current += 1;
                if (!self.isAtEnd()) {
                    const next_ch = self.peek();
                    if (next_ch == '\n' or next_ch == '\r' or self.isLineSeparator()) {
                        return .syntax_error;
                    }
                    self.current += 1;
                }
                continue;
            }

            if (c == '[') {
                in_class = true;
                self.current += 1;
                continue;
            }

            if (c == ']' and in_class) {
                in_class = false;
                self.current += 1;
                continue;
            }

            if (c == '/' and !in_class) {
                const pattern_end = self.current;
                self.current += 1; // consume closing /

                const flags_start = self.current;
                self.scanRegExpFlags();
                const flags_end = self.current;

                // 패턴 + 플래그 검증 (ECMAScript 21.2.1)
                const pattern_text = self.source[pattern_start..pattern_end];
                const flag_text = self.source[flags_start..flags_end];
                if (regexp_mod.validate(pattern_text, flag_text) != null) {
                    return .syntax_error;
                }
                return .regexp_literal;
            }

            // 줄바꿈은 정규식 안에서 불허 (U+2028/U+2029 포함)
            if (c == '\n' or c == '\r' or self.isLineSeparator()) {
                return .syntax_error;
            }

            self.current += 1;
        }

        // EOF까지 닫히지 않은 정규식
        return .syntax_error;
    }

    /// 정규식 플래그를 스캔한다 (/pattern/ 뒤의 문자들).
    fn scanRegExpFlags(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                self.current += 1;
            } else break;
        }
    }

    /// single-line comment를 스캔한다 (// ... \n).
    /// JSX pragma (@jsx, @jsxFrag, @jsxRuntime, @jsxImportSource)를 감지한다 (D026).
    /// 현재 위치부터 줄 끝(LF/CR/U+2028/U+2029)까지 스킵하고 주석을 기록한다.
    /// // 주석, <!-- 주석, --> 주석에서 공통으로 사용.
    fn skipLineAndRecordComment(self: *Scanner, check_pure: bool) !void {
        const comment_start = self.current;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '\n' or c == '\r') break;
            if (c == 0xE2 and self.current + 2 < self.source.len and
                self.source[self.current + 1] == 0x80 and
                (self.source[self.current + 2] == 0xA8 or self.source[self.current + 2] == 0xA9))
            {
                break;
            }
            self.current += 1;
        }
        const comment_text = self.source[comment_start..self.current];
        if (check_pure) self.checkPureComment(comment_text);
        try self.comments.append(self.allocator, .{
            .start = self.start,
            .end = self.current,
            .is_multiline = false,
            .is_legal = isLegalComment(comment_text, false),
        });
    }

    fn scanSingleLineComment(self: *Scanner) !void {
        self.current += 1; // skip second '/'
        try self.skipLineAndRecordComment(true);
    }

    /// multi-line comment를 스캔한다 (/* ... */).
    /// Flow comment (`/*::` / `/*:`) 감지: has_flow_pragma가 true이면
    /// 주석 내용을 코드로 처리하기 위해 flow comment 모드로 전환한다.
    /// @__PURE__ / @__NO_SIDE_EFFECTS__ 주석을 감지한다 (D025).
    /// @license / @preserve 주석도 감지한다 (D022, 추후 코드젠에서 활용).
    /// 미닫힌 주석이면 true(에러)를 반환.
    fn scanMultiLineComment(self: *Scanner) !bool {
        self.current += 1; // skip '*'

        // Flow comment 감지: /*:: (블록) 또는 /*: (인라인 타입)
        if (self.has_flow_pragma and self.current < self.source.len and self.source[self.current] == ':') {
            if (self.current + 1 < self.source.len and self.source[self.current + 1] == ':') {
                // /*:: — 블록 flow comment. 내용은 전부 type-only 선언이므로
                // 스트리핑 대상 → 파싱하지 않고 */ 까지 통째로 스킵.
                while (self.current + 1 < self.source.len) {
                    if (self.source[self.current] == '*' and self.source[self.current + 1] == '/') {
                        self.current += 2; // skip */
                        break;
                    }
                    self.current += 1;
                }
                return false;
            }
            // /*: — 인라인 flow comment (: Type */). colon부터 코드로 파싱.
            self.in_flow_comment = true;
            return false;
        }

        const comment_start = self.current;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '*' and self.peekAt(1) == '/') {
                const comment_text = self.source[comment_start..self.current];
                self.current += 2; // skip */
                self.checkPureComment(comment_text);

                // 주석을 기록한다 (start = 첫 번째 '/' 위치, end = '*/' 직후)
                try self.comments.append(self.allocator, .{
                    .start = self.start,
                    .end = self.current,
                    .is_multiline = true,
                    .is_legal = isLegalComment(comment_text, true),
                });

                return false; // 정상 종료
            }
            // 줄바꿈 추적 (소스맵 정확성)
            if (isNewlineStart(c)) {
                if (try self.handleNewline()) {
                    self.token.has_newline_before = true;
                } else {
                    self.current += 1;
                }
            } else {
                self.current += 1;
            }
        }
        // EOF까지 닫히지 않은 주석
        return true;
    }

    /// legal comment 감지 (D022): @license, @preserve, /*! (multi-line only)
    fn isLegalComment(comment_text: []const u8, is_multiline: bool) bool {
        if (is_multiline and comment_text.len > 0 and comment_text[0] == '!') return true;
        return std.mem.indexOf(u8, comment_text, "@license") != null or
            std.mem.indexOf(u8, comment_text, "@preserve") != null;
    }

    /// 주석 내용에서 @__PURE__ / #__PURE__ / @__NO_SIDE_EFFECTS__ 어노테이션을 확인한다.
    fn checkPureComment(self: *Scanner, comment_text: []const u8) void {
        // 빠른 reject: '@' 또는 '#' 포함하지 않으면 스킵
        if (std.mem.indexOf(u8, comment_text, "@") == null and
            std.mem.indexOf(u8, comment_text, "#") == null) return;

        if (std.mem.indexOf(u8, comment_text, "@__PURE__") != null or
            std.mem.indexOf(u8, comment_text, "#__PURE__") != null)
        {
            self.token.has_pure_comment_before = true;
        }

        if (std.mem.indexOf(u8, comment_text, "@__NO_SIDE_EFFECTS__") != null or
            std.mem.indexOf(u8, comment_text, "#__NO_SIDE_EFFECTS__") != null)
        {
            self.token.has_no_side_effects_comment = true;
        }

        // Flow pragma 감지: @flow 또는 @flow strict
        self.checkFlowPragma(comment_text);

        // JSX pragma 감지 (D026)
        self.checkJSXPragma(comment_text);
    }

    /// 주석에서 @flow pragma를 감지한다.
    /// Flow 컴파일러 호환: 주석의 첫 비공백 토큰이 `@flow`인 경우만 인식.
    /// `// @flow`, `/* @flow */`, `/** @flow strict */` 등.
    /// 주석 중간에 등장하는 `@flow`는 무시한다 (예: "enables @flow support").
    fn checkFlowPragma(self: *Scanner, comment_text: []const u8) void {
        if (self.has_flow_pragma) return; // 이미 감지됨

        // 선행 공백과 `*`(doc comment의 ` * @flow`)을 스킵
        var pos: usize = 0;
        while (pos < comment_text.len) : (pos += 1) {
            const c = comment_text[pos];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != '*') break;
        }

        // 주석의 첫 비공백 토큰이 @flow인지 확인
        const remaining = comment_text[pos..];
        if (!std.mem.startsWith(u8, remaining, "@flow")) return;

        // @flow 뒤에 아무것도 없거나, 공백/*/줄바꿈이면 유효한 pragma
        const after_pos = "@flow".len;
        if (after_pos >= remaining.len) {
            self.has_flow_pragma = true;
            return;
        }
        const next_char = remaining[after_pos];
        if (next_char == ' ' or next_char == '\t' or next_char == '\n' or
            next_char == '\r' or next_char == '*')
        {
            self.has_flow_pragma = true;
        }
    }

    /// 주석에서 JSX pragma 디렉티브를 감지한다 (D026).
    /// `@jsx`, `@jsxFrag`, `@jsxRuntime`, `@jsxImportSource` 뒤의 값을 추출.
    fn checkJSXPragma(self: *Scanner, comment_text: []const u8) void {
        // @jsxImportSource 먼저 (더 긴 접두사를 먼저 체크)
        if (extractPragmaValue(comment_text, "@jsxImportSource")) |val| {
            self.jsx_import_source_pragma = val;
        }
        if (extractPragmaValue(comment_text, "@jsxRuntime")) |val| {
            self.jsx_runtime_pragma = val;
        }
        if (extractPragmaValue(comment_text, "@jsxFrag")) |val| {
            self.jsx_frag_pragma = val;
        }
        // @jsx는 @jsxFrag 등과 겹치지 않도록 마지막에 체크
        if (extractPragmaValue(comment_text, "@jsx")) |val| {
            // @jsxFrag, @jsxRuntime, @jsxImportSource가 아닌 경우만
            if (!std.mem.startsWith(u8, val, "Frag") and
                !std.mem.startsWith(u8, val, "Runtime") and
                !std.mem.startsWith(u8, val, "ImportSource"))
            {
                self.jsx_pragma = val;
            }
        }
    }

    /// 주석 텍스트에서 `@directive value` 형태의 값을 추출한다.
    /// 공백으로 구분된 첫 번째 단어를 반환.
    fn extractPragmaValue(comment_text: []const u8, directive: []const u8) ?[]const u8 {
        const idx = std.mem.indexOf(u8, comment_text, directive) orelse return null;
        const after = comment_text[idx + directive.len ..];

        // directive 바로 뒤에 공백이 있어야 함
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) return null;

        // 공백 스킵
        var start: usize = 0;
        while (start < after.len and (after[start] == ' ' or after[start] == '\t')) {
            start += 1;
        }
        if (start >= after.len) return null;

        // 값 끝 찾기 (공백, *, / 에서 멈춤)
        var end = start;
        while (end < after.len and after[end] != ' ' and after[end] != '\t' and
            after[end] != '*' and after[end] != '/' and after[end] != '\n' and after[end] != '\r')
        {
            end += 1;
        }

        if (end == start) return null;
        return after[start..end];
    }

    fn scanPercent(self: *Scanner) Kind {
        if (self.peek() == '=') {
            self.current += 1;
            return .percent_eq;
        }
        return .percent;
    }

    fn scanLAngle(self: *Scanner) !Kind {
        // ECMAScript Annex B: <!-- HTML open comment (non-module only)
        // SingleLineHTMLOpenComment :: <!-- SingleLineCommentChars_opt
        // `<` 이미 소비됨, 다음이 `!--`이면 줄 끝까지 주석으로 처리.
        if (!self.is_module and self.peek() == '!' and self.peekAt(1) == '-' and self.peekAt(2) == '-') {
            self.current += 3; // skip !--
            try self.skipLineAndRecordComment(false);
            return .undetermined;
        }

        if (self.peek() == '<') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .shift_left_eq;
            }
            return .shift_left;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .lt_eq;
        }
        return .l_angle;
    }

    fn scanRAngle(self: *Scanner) Kind {
        if (self.peek() == '>') {
            self.current += 1;
            if (self.peek() == '>') {
                self.current += 1;
                if (self.peek() == '=') {
                    self.current += 1;
                    return .shift_right3_eq;
                }
                return .shift_right3;
            }
            if (self.peek() == '=') {
                self.current += 1;
                return .shift_right_eq;
            }
            return .shift_right;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .gt_eq;
        }
        return .r_angle;
    }

    fn scanEquals(self: *Scanner) Kind {
        if (self.peek() == '=') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .eq3;
            }
            return .eq2;
        }
        if (self.peek() == '>') {
            self.current += 1;
            return .arrow;
        }
        return .eq;
    }

    fn scanBang(self: *Scanner) Kind {
        if (self.peek() == '=') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .neq2;
            }
            return .neq;
        }
        return .bang;
    }

    fn scanAmp(self: *Scanner) Kind {
        if (self.peek() == '&') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .amp2_eq;
            }
            return .amp2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .amp_eq;
        }
        return .amp;
    }

    fn scanPipe(self: *Scanner) Kind {
        if (self.peek() == '|') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .pipe2_eq;
            }
            return .pipe2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .pipe_eq;
        }
        return .pipe;
    }

    fn scanCaret(self: *Scanner) Kind {
        if (self.peek() == '=') {
            self.current += 1;
            return .caret_eq;
        }
        return .caret;
    }

    fn scanQuestion(self: *Scanner) Kind {
        if (self.peek() == '?') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .question2_eq;
            }
            return .question2;
        }
        if (self.peek() == '.') {
            // ?. 은 optional chaining이지만 ?.5 는 ternary + 숫자
            const next_byte = self.peekAt(1);
            if (next_byte < '0' or next_byte > '9') {
                self.current += 1;
                return .question_dot;
            }
        }
        return .question;
    }

    // ====================================================================
    // 리터럴 스캔 (placeholder — 추후 PR에서 세부 구현)
    // ====================================================================

    /// 숫자 리터럴을 스캔한다.
    /// 첫 번째 숫자 문자(c)는 이미 advance()로 소비된 상태.
    ///
    /// 처리하는 형식:
    /// - 10진수: 123, 1_000_000
    /// - 소수: 1.5, .5
    /// - 지수: 1e10, 1e+10, 1e-10
    /// - 16진수: 0xFF, 0XFF
    /// - 8진수: 0o77, 0O77
    /// - 2진수: 0b1010, 0B1010
    /// - BigInt: 123n, 0xFFn, 0o77n, 0b1010n
    /// - 숫자 구분자: 1_000, 0xFF_FF
    fn scanNumericLiteral(self: *Scanner, first_char: u8) Kind {
        // 0으로 시작하면 접두사 확인
        if (first_char == '0') {
            const prefix = self.peek();
            switch (prefix) {
                'x', 'X' => {
                    self.current += 1;
                    return self.checkNumericEnd(self.scanHexLiteral());
                },
                'o', 'O' => {
                    self.current += 1;
                    return self.checkNumericEnd(self.scanOctalLiteral());
                },
                'b', 'B' => {
                    self.current += 1;
                    return self.checkNumericEnd(self.scanBinaryLiteral());
                },
                // 0_ → numeric separator in leading zero literal is invalid
                '_' => return .syntax_error,
                // 0 뒤에 숫자가 오면 legacy octal (00, 07) 또는 non-octal decimal (08, 09)
                // 둘 다 strict mode에서 금지 (ECMAScript 12.8.3.1)
                // Numeric separator(_)는 legacy octal/non-octal decimal에서 금지 (ECMAScript 12.8.3)
                '0'...'9' => {
                    self.token.has_legacy_octal = true;
                    // Legacy octal/non-octal decimal에서는 separator 없이 숫자만 소비
                    if (self.scanLegacyOctalDigits()) return .syntax_error;
                    // 소수점 (legacy octal 뒤에도 소수점 가능: 010.5 → 10.5)
                    if (self.peek() == '.') {
                        if (!(self.peekAt(1) == '.' and self.peekAt(2) == '.')) {
                            self.current += 1;
                            if (self.scanDecimalDigits()) return .syntax_error;
                            return self.checkNumericEnd(self.scanExponentPart(.float));
                        }
                    }
                    return self.checkNumericEnd(self.scanExponentPart(.decimal));
                },
                else => {},
            }
        }

        // 10진수 정수부 소비 (first_char가 이미 숫자 하나를 제공)
        if (self.scanDecimalDigitsEx(true)) return .syntax_error;

        // 소수점
        if (self.peek() == '.') {
            // 1..toString()에서 첫 번째 '.'은 소수점, 두 번째 '.'은 멤버 접근.
            // '...'(spread)이면 소수점이 아님.
            if (self.peekAt(1) == '.' and self.peekAt(2) == '.') {
                // 1... → 1 다음에 spread operator → 소수점 아님
            } else {
                self.current += 1;
                if (self.scanDecimalDigits()) return .syntax_error;
                return self.checkNumericEnd(self.scanExponentPart(.float));
            }
        }

        // 지수
        return self.checkNumericEnd(self.scanExponentPart(.decimal));
    }

    /// 소수점 이후를 스캔한다 (.5, .123e10 등).
    /// '.'은 이미 소비된 상태. ('.' 자체는 scanDot에서 감지)
    fn scanDecimalAfterDot(self: *Scanner) Kind {
        if (self.scanDecimalDigits()) return .syntax_error;
        return self.checkNumericEnd(self.scanExponentPart(.float));
    }

    /// scanDecimalDigitsEx의 wrapper. 선행 숫자 없음.
    fn scanDecimalDigits(self: *Scanner) bool {
        return self.scanDecimalDigitsEx(false);
    }

    /// 10진수 숫자 시퀀스를 소비한다 (separator '_' 포함).
    /// 숫자가 하나도 없거나 separator가 잘못된 위치면 true를 반환 (에러).
    /// has_preceding_digit: 호출 전에 이미 숫자가 소비되었으면 true.
    fn scanDecimalDigitsEx(self: *Scanner, has_preceding_digit: bool) bool {
        var has_digits = has_preceding_digit;
        var prev_was_separator = false;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c >= '0' and c <= '9') {
                self.current += 1;
                has_digits = true;
                prev_was_separator = false;
            } else if (c == '_') {
                if (!has_digits or prev_was_separator) {
                    // 선행 _ 또는 연속 __ → 에러
                    return true;
                }
                self.current += 1;
                prev_was_separator = true;
            } else {
                break;
            }
        }
        // 후행 _ → 에러
        if (prev_was_separator) return true;
        return false;
    }

    /// 지수부(e/E)를 스캔하고, BigInt suffix(n)도 확인한다.
    /// base_kind: 지수가 없을 때의 기본 Kind (.decimal 또는 .float)
    fn scanExponentPart(self: *Scanner, base_kind: Kind) Kind {
        const c = self.peek();
        if (c == 'e' or c == 'E') {
            self.current += 1;
            const sign = self.peek();
            const is_negative = sign == '-';
            if (sign == '+' or sign == '-') {
                self.current += 1;
            }
            if (self.scanDecimalDigits()) return .syntax_error;
            // 지수 뒤에 BigInt suffix 'n'이 오면 에러 (0e0n, 1e1n 등)
            // ECMAScript 스펙: BigInt는 지수 표기를 허용하지 않음
            if (self.peek() == 'n') {
                self.current += 1;
                return .syntax_error;
            }
            return if (is_negative) .negative_exponential else .positive_exponential;
        }

        // BigInt suffix 'n'
        if (c == 'n') {
            // float에 BigInt suffix는 에러 (.0001n, 2017.8n 등)
            // ECMAScript 스펙: BigInt의 MV는 정수여야 함
            if (base_kind == .float) {
                self.current += 1;
                return .syntax_error;
            }
            // legacy octal / non-octal decimal에 BigInt suffix는 에러 (00n, 01n, 08n 등)
            // ECMAScript 스펙: DecimalBigIntegerLiteral은 0n 또는 NonZeroDigit... 만 허용
            if (self.token.has_legacy_octal) {
                self.current += 1;
                return .syntax_error;
            }
            self.current += 1;
            return .decimal_bigint;
        }

        return self.checkNumericEnd(base_kind);
    }

    /// 숫자 리터럴 직후에 IdentifierStart 문자가 오는지 확인한다.
    /// ECMAScript 명세: "The source character immediately following a NumericLiteral
    /// must not be an IdentifierStart or DecimalDigit." (12.8.3)
    /// 예: `3in []`, `0\u006f0`, `1\u005F0` 등은 SyntaxError.
    fn checkNumericEnd(self: *Scanner, kind: Kind) Kind {
        if (kind == .syntax_error) return kind;
        if (self.isAtEnd()) return kind;
        const c = self.peek();
        // ASCII IdentifierStart: a-z, A-Z, _, $
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$') {
            return .syntax_error;
        }
        // Unicode escape (\uXXXX) — IdentifierStart를 unicode escape로 표현한 경우도 에러
        if (c == '\\') {
            return .syntax_error;
        }
        // Non-ASCII UTF-8 시작 바이트 — unicode IdentifierStart일 수 있음
        if (c >= 0x80) {
            const decoded = unicode.decodeUtf8(self.source[self.current..]);
            if (decoded.len > 0 and unicode.isIdentifierStart(decoded.codepoint)) {
                return .syntax_error;
            }
        }
        return kind;
    }

    /// Legacy octal/non-octal decimal 숫자 시퀀스를 소비한다.
    /// 00, 01, 07 (legacy octal) 또는 08, 09 (non-octal decimal) 이후의 숫자만 소비.
    /// Numeric separator '_'는 금지 — 만나면 true(에러)를 반환.
    /// 소수점과 지수는 호출자(scanNumericLiteral)에서 처리.
    fn scanLegacyOctalDigits(self: *Scanner) bool {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c >= '0' and c <= '9') {
                self.current += 1;
            } else if (c == '_') {
                // Legacy octal/non-octal decimal에서 separator는 금지
                return true;
            } else {
                break;
            }
        }
        return false;
    }

    /// 16진수 리터럴을 스캔한다 (0x 이후).
    fn scanHexLiteral(self: *Scanner) Kind {
        if (self.scanHexDigits()) return .syntax_error;
        if (self.peek() == 'n') {
            self.current += 1;
            return self.checkNumericEnd(.hex_bigint);
        }
        return self.checkNumericEnd(.hex);
    }

    /// 8진수 리터럴을 스캔한다 (0o 이후).
    fn scanOctalLiteral(self: *Scanner) Kind {
        if (self.scanOctalDigits()) return .syntax_error;
        if (self.peek() == 'n') {
            self.current += 1;
            return self.checkNumericEnd(.octal_bigint);
        }
        return self.checkNumericEnd(.octal);
    }

    /// 2진수 리터럴을 스캔한다 (0b 이후).
    fn scanBinaryLiteral(self: *Scanner) Kind {
        if (self.scanBinaryDigits()) return .syntax_error;
        if (self.peek() == 'n') {
            self.current += 1;
            return self.checkNumericEnd(.binary_bigint);
        }
        return self.checkNumericEnd(.binary);
    }

    /// 16진수 숫자를 스캔. 숫자가 없거나 separator 오류면 true 반환.
    fn scanHexDigits(self: *Scanner) bool {
        var has_digits = false;
        var prev_was_separator = false;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                self.current += 1;
                has_digits = true;
                prev_was_separator = false;
            } else if (c == '_') {
                if (!has_digits or prev_was_separator) return true;
                self.current += 1;
                prev_was_separator = true;
            } else break;
        }
        if (prev_was_separator) return true;
        return !has_digits; // 숫자가 없으면 에러 (0x; → error)
    }

    /// 8진수 숫자를 스캔. 숫자가 없거나 separator 오류면 true 반환.
    fn scanOctalDigits(self: *Scanner) bool {
        var has_digits = false;
        var prev_was_separator = false;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c >= '0' and c <= '7') {
                self.current += 1;
                has_digits = true;
                prev_was_separator = false;
            } else if (c == '_') {
                if (!has_digits or prev_was_separator) return true;
                self.current += 1;
                prev_was_separator = true;
            } else break;
        }
        if (prev_was_separator) return true;
        return !has_digits;
    }

    /// 2진수 숫자를 스캔. 숫자가 없거나 separator 오류면 true 반환.
    fn scanBinaryDigits(self: *Scanner) bool {
        var has_digits = false;
        var prev_was_separator = false;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '0' or c == '1') {
                self.current += 1;
                has_digits = true;
                prev_was_separator = false;
            } else if (c == '_') {
                if (!has_digits or prev_was_separator) return true;
                self.current += 1;
                prev_was_separator = true;
            } else break;
        }
        if (prev_was_separator) return true;
        return !has_digits;
    }

    /// 문자열 리터럴을 스캔한다 (opening quote는 이미 소비됨).
    ///
    /// 처리하는 이스케이프 시퀀스:
    /// - 단순: \n \r \t \\ \' \" \0
    /// - 16진수: \xHH
    /// - 유니코드: \uHHHH, \u{H...H}
    /// - 줄 연속: \ + 줄바꿈 (줄바꿈이 문자열에 포함되지 않음)
    ///
    /// 에러 감지:
    /// - 닫히지 않은 문자열 → syntax_error
    /// - 문자열 안 줄바꿈 (JS 스펙 위반) → syntax_error
    fn scanStringLiteral(self: *Scanner, quote: u8) !Kind {
        while (!self.isAtEnd()) {
            // SIMD fast path: quote/\/\n/\r 이외의 일반 문자를 16바이트씩 건너뜀
            self.simdSkipUntilAny(&.{ '\\', '\n', '\r' }, quote);
            if (self.isAtEnd()) break;

            const c = self.peek();

            if (c == quote) {
                self.current += 1; // consume closing quote
                return .string_literal;
            }

            // 이스케이프 시퀀스
            if (c == '\\') {
                self.current += 1; // consume '\'
                if (self.isAtEnd()) break; // '\' at EOF

                const escaped = self.peek();
                switch (escaped) {
                    // 단순 이스케이프: 1바이트 스킵
                    'n', 'r', 't', '\\', '\'', '"', 'b', 'f', 'v' => {
                        self.current += 1;
                    },
                    // \0: 뒤에 숫자가 없으면 NUL, 있으면 legacy octal
                    '0' => {
                        self.current += 1;
                        if (!self.isAtEnd() and self.peek() >= '0' and self.peek() <= '9') {
                            self.token.has_legacy_octal = true;
                        }
                    },
                    // \1..\9: legacy octal escape (strict mode에서 금지)
                    '1'...'9' => {
                        self.token.has_legacy_octal = true;
                        self.current += 1;
                    },
                    // 16진수 이스케이프: \xHH
                    'x' => {
                        self.current += 1;
                        if (self.skipHexEscape(2)) return .syntax_error;
                    },
                    // 유니코드 이스케이프: \uHHHH 또는 \u{H...H}
                    'u' => {
                        self.current += 1;
                        if (self.peek() == '{') {
                            // \u{H...H} — 가변 길이, 각 문자가 hex digit이어야 함
                            self.current += 1;
                            var has_hex = false;
                            while (!self.isAtEnd() and self.peek() != '}') {
                                const hc = self.peek();
                                if ((hc >= '0' and hc <= '9') or (hc >= 'a' and hc <= 'f') or (hc >= 'A' and hc <= 'F')) {
                                    has_hex = true;
                                    self.current += 1;
                                } else {
                                    return .syntax_error; // non-hex (예: '_' numeric separator)
                                }
                            }
                            if (!has_hex) return .syntax_error;
                            if (!self.isAtEnd()) self.current += 1; // consume '}'
                        } else {
                            // \uHHHH — 고정 4자리
                            if (self.skipHexEscape(4)) return .syntax_error;
                        }
                    },
                    // 줄 연속: \ 뒤에 줄바꿈이 오면 줄바꿈을 건너뜀
                    '\n' => {
                        _ = try self.handleNewline();
                    },
                    '\r' => {
                        _ = try self.handleNewline();
                    },
                    // 그 외: legacy octal (\1..\7) 또는 알 수 없는 이스케이프 → 1바이트 스킵
                    // (엄격한 에러 검사는 파서에서)
                    else => {
                        self.current += 1;
                    },
                }
                continue;
            }

            // \n, \r은 문자열 안에서 불허 (줄바꿈 = 미닫힌 문자열)
            // 단, U+2028/U+2029는 ES2019부터 문자열 안에서 허용
            if (c == '\n' or c == '\r') {
                return .syntax_error;
            }

            // 일반 문자: UTF-8 바이트 스킵
            self.current += 1;
        }

        // EOF까지 닫히지 않은 문자열
        return .syntax_error;
    }

    /// hex 이스케이프의 지정된 자릿수만큼 스킵한다.
    /// hex escape를 스킵한다. count자리를 소비. 부족하면 true (에러).
    fn skipHexEscape(self: *Scanner, count: u32) bool {
        var i: u32 = 0;
        while (i < count and !self.isAtEnd()) : (i += 1) {
            const c = self.peek();
            if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                self.current += 1;
            } else return true; // 에러: non-hex character
        }
        return i < count; // 에러: 자릿수 부족 (EOF)
    }

    /// 템플릿 리터럴을 스캔한다 (opening backtick은 이미 소비됨).
    ///
    /// 반환:
    /// - no_substitution_template: `string` (보간 없음)
    /// - template_head: `text${ (보간 시작)
    /// - syntax_error: 닫히지 않은 템플릿
    fn scanTemplateLiteral(self: *Scanner) !Kind {
        return try self.scanTemplateContent(.no_substitution_template, .template_head);
    }

    /// 템플릿 중간/끝을 스캔한다 (}에서 호출).
    ///
    /// 반환:
    /// - template_middle: }text${ (보간 계속)
    /// - template_tail: }text` (템플릿 끝)
    /// - syntax_error: 닫히지 않은 템플릿
    fn scanTemplateContinuation(self: *Scanner) !Kind {
        // 스택에서 현재 템플릿 depth를 pop
        _ = self.template_depth_stack.pop();
        return try self.scanTemplateContent(.template_tail, .template_middle);
    }

    /// 템플릿 내용을 스캔하는 공통 로직.
    /// backtick을 만나면 complete_kind, ${를 만나면 interpolation_kind를 반환.
    fn scanTemplateContent(self: *Scanner, complete_kind: Kind, interpolation_kind: Kind) !Kind {
        while (!self.isAtEnd()) {
            // SIMD fast path: backtick/$/\/\n/\r 이외의 일반 문자를 16바이트씩 건너뜀
            self.simdSkipUntilAny(&.{ '`', '$', '\\', '\n', '\r' }, null);
            if (self.isAtEnd()) break;

            const c = self.peek();

            if (c == '`') {
                self.current += 1;
                return complete_kind;
            }

            if (c == '$' and self.peekAt(1) == '{') {
                self.current += 2; // skip ${
                // 현재 brace depth를 스택에 push (나중에 }에서 매칭)
                try self.template_depth_stack.append(self.allocator, self.brace_depth);
                self.brace_depth += 1;
                return interpolation_kind;
            }

            if (c == '\\') {
                self.current += 1; // skip '\'
                if (!self.isAtEnd()) {
                    const escaped = self.peek();
                    switch (escaped) {
                        // 단순 이스케이프: 1바이트 스킵
                        'n', 'r', 't', '\\', '\'', '"', 'b', 'f', 'v', '`', '$' => {
                            self.current += 1;
                        },
                        // \0 — 뒤에 숫자가 오면 legacy octal → invalid
                        '0' => {
                            self.current += 1;
                            if (!self.isAtEnd() and self.peek() >= '0' and self.peek() <= '9') {
                                self.token.has_invalid_escape = true;
                                self.current += 1;
                            }
                        },
                        // legacy octal \1..\9 → template에서는 항상 invalid
                        '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                            self.token.has_invalid_escape = true;
                            self.current += 1;
                        },
                        // 16진수 이스케이프: \xHH
                        'x' => {
                            self.current += 1;
                            if (self.skipHexEscape(2)) {
                                self.token.has_invalid_escape = true;
                            }
                        },
                        // 유니코드 이스케이프: \uHHHH 또는 \u{H...H}
                        'u' => {
                            self.current += 1;
                            if (!self.isAtEnd() and self.peek() == '{') {
                                // \u{H...H} — 가변 길이, 닫는 }가 있어야 유효, 값 ≤ 0x10FFFF
                                self.current += 1;
                                var has_hex = false;
                                var code_point: u32 = 0;
                                var overflow = false;
                                while (!self.isAtEnd() and self.peek() != '}') {
                                    const hc = self.peek();
                                    const digit: u32 = if (hc >= '0' and hc <= '9')
                                        hc - '0'
                                    else if (hc >= 'a' and hc <= 'f')
                                        hc - 'a' + 10
                                    else if (hc >= 'A' and hc <= 'F')
                                        hc - 'A' + 10
                                    else {
                                        // 비-hex 문자 → invalid (문자를 소비하지 않음 — 템플릿 구분자일 수 있음)
                                        self.token.has_invalid_escape = true;
                                        break;
                                    };
                                    has_hex = true;
                                    // overflow 방지: 0x10FFFF는 21비트이므로 24비트 이상이면 overflow
                                    if (code_point > 0x10FFFF) {
                                        overflow = true;
                                    }
                                    code_point = (code_point << 4) | digit;
                                    self.current += 1;
                                }
                                if (!self.isAtEnd() and self.peek() == '}') {
                                    self.current += 1; // consume '}'
                                    if (!has_hex or overflow or code_point > 0x10FFFF) {
                                        self.token.has_invalid_escape = true;
                                    }
                                } else {
                                    self.token.has_invalid_escape = true;
                                }
                            } else {
                                // \uHHHH — 고정 4자리
                                if (self.skipHexEscape(4)) {
                                    self.token.has_invalid_escape = true;
                                }
                            }
                        },
                        // 줄바꿈 이스케이프 처리 (템플릿에서는 유효)
                        '\n', '\r' => {
                            _ = try self.handleNewline();
                        },
                        // 그 외: non-escape character (유효)
                        else => {
                            self.current += 1;
                        },
                    }
                }
                continue;
            }

            // 줄바꿈: 템플릿 리터럴에서는 허용됨 (일반 문자열과 다름)
            // has_newline_before는 설정하지 않음 — 토큰 사이의 줄바꿈만 추적해야 함
            // template literal 내부 줄바꿈으로 ASI가 발생하면 안 됨
            if (c == '\n' or c == '\r') {
                _ = try self.handleNewline();
                continue;
            }

            self.current += 1;
        }

        // EOF까지 닫히지 않은 템플릿
        return .syntax_error;
    }

    fn scanHashbang(self: *Scanner) void {
        // #! 이후 줄 끝까지 스킵
        self.current += 1; // skip '!'
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '\n' or c == '\r') break;
            if (self.isLineSeparator()) break;
            self.current += 1;
        }
    }

    /// private identifier (#) 뒤의 첫 문자가 유효한 IdentifierStart인지 확인한다.
    /// IdentifierStart는 $, _, UnicodeIDStart, \uXXXX(IdentifierStart 코드포인트) 만 허용.
    /// ZWNJ (U+200C), ZWJ (U+200D) 등 IdentifierPart 전용 문자는 거부한다.
    fn scanPrivateIdentifierStart(self: *Scanner) bool {
        if (self.isAtEnd()) return false;
        const c = self.peek();
        if (c < 0x80) {
            // ASCII: a-z, A-Z, _, $
            if (isAsciiIdentStart(c)) {
                self.current += 1;
                return true;
            }
            if (c == '\\') {
                // \uXXXX 유니코드 이스케이프 — IdentifierStart인지 검증
                const esc_pos = self.current;
                if (!self.scanIdentifierEscape()) return false;
                const esc_slice = self.source[esc_pos..self.current];
                const cp = self.decodeEscapeCodepoint(esc_slice);
                if (cp) |codepoint| {
                    if (codepoint < 0x80) {
                        if (!isAsciiIdentStart(@intCast(codepoint))) {
                            self.current = esc_pos;
                            return false;
                        }
                    } else if (codepoint <= 0x10FFFF) {
                        if (!unicode.isIdentifierStart(@intCast(codepoint))) {
                            self.current = esc_pos;
                            return false;
                        }
                    }
                } else {
                    self.current = esc_pos;
                    return false;
                }
                return true;
            }
            return false;
        }
        // Non-ASCII: UTF-8 디코딩 후 UnicodeIDStart 확인
        const remaining = self.source[self.current..];
        const decoded = unicode.decodeUtf8(remaining);
        if (decoded.len == 0) return false;
        if (unicode.isIdentifierStart(decoded.codepoint)) {
            self.current += decoded.len;
            return true;
        }
        return false;
    }

    /// 식별자의 나머지 부분을 스캔한다. 유니코드 문자와 \u 이스케이프를 처리.
    fn scanIdentifierTail(self: *Scanner) void {
        // SIMD fast path: 16바이트씩 ASCII identifier continue 스캔
        // [a-zA-Z0-9_$] 범위를 벡터 비교로 판별
        while (self.current + 16 <= self.source.len) {
            const chunk: @Vector(16, u8) = self.source[self.current..][0..16].*;
            // ASCII identifier continue: [a-z] | [A-Z] | [0-9] | _ | $
            const ge_a = chunk >= @as(@Vector(16, u8), @splat(@as(u8, 'a')));
            const le_z = chunk <= @as(@Vector(16, u8), @splat(@as(u8, 'z')));
            const ge_A = chunk >= @as(@Vector(16, u8), @splat(@as(u8, 'A')));
            const le_Z = chunk <= @as(@Vector(16, u8), @splat(@as(u8, 'Z')));
            const ge_0 = chunk >= @as(@Vector(16, u8), @splat(@as(u8, '0')));
            const le_9 = chunk <= @as(@Vector(16, u8), @splat(@as(u8, '9')));
            const is_under = chunk == @as(@Vector(16, u8), @splat(@as(u8, '_')));
            const is_dollar = chunk == @as(@Vector(16, u8), @splat(@as(u8, '$')));
            const id_mask = @as(u16, @bitCast(
                (ge_a & le_z) | (ge_A & le_Z) | (ge_0 & le_9) | is_under | is_dollar,
            ));
            if (id_mask == 0xFFFF) {
                self.current += 16;
            } else {
                self.current += @ctz(~id_mask);
                break;
            }
        }

        while (!self.isAtEnd()) {
            const c = self.peek();
            // ASCII fast path
            if (c < 0x80) {
                if (isAsciiIdentContinue(c)) {
                    self.current += 1;
                } else if (c == '\\') {
                    // \uXXXX 유니코드 이스케이프
                    const esc_pos = self.current;
                    if (!self.scanIdentifierEscape()) break;
                    // 디코딩된 코드포인트가 ID_Continue인지 검증
                    const esc_slice = self.source[esc_pos..self.current];
                    const cp = self.decodeEscapeCodepoint(esc_slice);
                    if (cp) |codepoint| {
                        if (codepoint < 0x80) {
                            if (!isAsciiIdentContinue(@intCast(codepoint))) {
                                self.current = esc_pos;
                                break;
                            }
                        } else if (codepoint <= 0x10FFFF) {
                            if (!unicode.isIdentifierContinue(@intCast(codepoint))) {
                                self.current = esc_pos;
                                break;
                            }
                        }
                    } else {
                        // 디코딩 실패 → 유효하지 않은 이스케이프
                        self.current = esc_pos;
                        break;
                    }
                } else {
                    break;
                }
            } else {
                // Non-ASCII: UTF-8 디코딩 후 유니코드 ID_Continue 확인
                const remaining = self.source[self.current..];
                const decoded = unicode.decodeUtf8(remaining);
                if (decoded.len == 0) break;
                if (unicode.isIdentifierContinue(decoded.codepoint)) {
                    self.current += decoded.len;
                } else {
                    break;
                }
            }
        }
    }

    /// 식별자 안의 \uXXXX 또는 \u{XXXX} 이스케이프를 스캔한다.
    /// 성공하면 true, 유효하지 않으면 false.
    fn scanIdentifierEscape(self: *Scanner) bool {
        if (self.peek() != '\\') return false;
        if (self.peekAt(1) != 'u') return false;
        self.current += 2; // skip \u

        if (self.peek() == '{') {
            self.current += 1;
            while (!self.isAtEnd() and self.peek() != '}') {
                self.current += 1;
            }
            if (!self.isAtEnd()) self.current += 1; // skip }
        } else {
            _ = self.skipHexEscape(4);
        }
        return true;
    }

    /// 단일 유니코드 이스케이프 시퀀스 (\uXXXX 또는 \u{XXXX})에서 코드포인트를 추출한다.
    /// 식별자 시작/계속 문자의 유효성 검증에 사용한다.
    fn decodeEscapeCodepoint(_: *Scanner, raw: []const u8) ?u32 {
        // raw가 \uXXXX 또는 \u{XXXX} 형태인지 확인
        if (raw.len < 2) return null;
        var i: usize = 0;
        // 여러 이스케이프가 연결된 경우 첫 번째만 추출
        if (raw[i] != '\\' or raw[i + 1] != 'u') return null;
        i += 2;
        var codepoint: u32 = 0;
        if (i < raw.len and raw[i] == '{') {
            i += 1;
            while (i < raw.len and raw[i] != '}') {
                const digit = std.fmt.charToDigit(raw[i], 16) catch return null;
                codepoint = codepoint * 16 + digit;
                i += 1;
            }
        } else {
            var j: usize = 0;
            while (j < 4 and i < raw.len) : (j += 1) {
                const digit = std.fmt.charToDigit(raw[i], 16) catch return null;
                codepoint = codepoint * 16 + digit;
                i += 1;
            }
        }
        // Unicode 유효 범위 검증 (U+10FFFF 초과 거부)
        if (codepoint > 0x10FFFF) return null;
        return codepoint;
    }

    /// 이스케이프가 포함된 식별자 텍스트를 디코딩하여 실제 문자열을 반환한다.
    /// \uXXXX 와 \u{XXXX} 형태를 처리. BMP 문자만 지원 (키워드 매칭에 충분).
    /// 인스턴스의 decode_buf를 사용하여 dangling pointer 방지.
    pub fn decodeIdentifierEscapes(self: *Scanner, raw: []const u8) ?[]const u8 {
        // 이스케이프가 없으면 그대로 반환 (소스 텍스트 포인터, 항상 유효)
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;

        var out: usize = 0;
        var i: usize = 0;

        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == 'u') {
                i += 2; // skip \u
                var codepoint: u32 = 0;
                if (i < raw.len and raw[i] == '{') {
                    i += 1; // skip {
                    while (i < raw.len and raw[i] != '}') {
                        const digit = std.fmt.charToDigit(raw[i], 16) catch return null;
                        codepoint = codepoint * 16 + digit;
                        i += 1;
                    }
                    if (i < raw.len) i += 1; // skip }
                } else {
                    // \uXXXX — 4자리 고정
                    var j: usize = 0;
                    while (j < 4 and i < raw.len) : (j += 1) {
                        const digit = std.fmt.charToDigit(raw[i], 16) catch return null;
                        codepoint = codepoint * 16 + digit;
                        i += 1;
                    }
                }
                // BMP 문자만 (키워드는 전부 ASCII)
                if (codepoint < 0x80) {
                    if (out >= self.decode_buf.len) return null;
                    self.decode_buf[out] = @intCast(codepoint);
                    out += 1;
                } else {
                    return null; // non-ASCII codepoint → 키워드 아님
                }
            } else {
                if (out >= self.decode_buf.len) return null;
                self.decode_buf[out] = raw[i];
                out += 1;
                i += 1;
            }
        }

        return self.decode_buf[0..out];
    }

    // ====================================================================
    // 문자 분류
    // ====================================================================

    /// ASCII 식별자 시작 문자인지.
    fn isAsciiIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            c == '_' or c == '$';
    }

    /// ASCII 식별자 계속 문자인지.
    fn isAsciiIdentContinue(c: u8) bool {
        return isAsciiIdentStart(c) or (c >= '0' and c <= '9');
    }
};
