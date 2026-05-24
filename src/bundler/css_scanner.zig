//! CSS @import 추출기
//!
//! CSS 파일 상단의 @import 규칙을 추출하는 경량 스캐너.
//! @charset, 공백, 주석은 건너뛰고, 첫 번째 non-import 규칙에서 중단한다.
//! 전체 CSS 파서 없이 @import 경로만 추출하여 모듈 그래프에 등록하는 용도.

const std = @import("std");
const Span = @import("../lexer/token.zig").Span;

pub const CssImportRecord = struct {
    /// import 경로 (따옴표/url() 제거된 순수 경로)
    specifier: []const u8,
    /// 소스 코드에서의 위치 (@import 시작 ~ 세미콜론)
    span: Span,
    /// External URL (`http:`/`https:`/`//` prefix) 여부. true 면 resolver 가
    /// 건너뛰고 emitter 가 출력 CSS 상단에 그대로 보존한다 (esbuild parity).
    is_external: bool = false,
    /// specifier 끝 이후 ~ `;` 직전 까지의 raw tail (예: ` print`,
    /// ` layer(reset)`, ` supports(display:flex) screen`). leading 공백 포함.
    /// external @import 보존 시 그대로 재출력해 media-query/layer/supports
    /// semantic 을 유지 (esbuild parity). 일반(inline) @import 에선 사용 안 함.
    /// source 슬라이스 — 모듈 수명 내 유효.
    condition_tail: []const u8 = "",
};

/// CSS 파일 상단의 `@charset` / bare `@layer` 선언. strip_end 가 통째로 잘라
/// 버리던 항목들을 캡처해 emitter 가 본문 앞에 보존 emit (#3747).
///
/// `@charset "UTF-8"` — UA 가 인코딩 판정용, 파일 첫 byte 여야 valid. 번들엔
/// 1개만 (첫 모듈 의 것). 추가는 silent drop.
///
/// bare `@layer reset, base, theme` — cascade layer 순서 정의. 본문 규칙
/// 보다 *앞* 에 와야 의도된 순서 효력. 여러 모듈 의 bare @layer 는 source
/// 등장 순서 보존.
pub const CssPrefixDeclKind = enum { charset, layer_bare };
pub const CssPrefixDecl = struct {
    kind: CssPrefixDeclKind,
    /// `@charset "UTF-8"` 또는 `@layer reset, base, theme` 형식의 raw text
    /// (마지막 `;` 미포함 — emitter 가 통일된 `;\n` 부착).
    text: []const u8,
};

/// CSS at-keyword 직후 byte 가 word boundary 인지 판정 — CSS whitespace
/// (`' '`/`'\t'`/`'\n'`/`'\r'`/`'\x0c'`) 또는 `;` 또는 EOF.
/// `startsWithAt(... "charset")` / `startsWithAt(... "layer")` 직후 가드로
/// `@charsetXYZ`/`@layerOTHER` 같은 다른 at-rule 오인 차단 + multi-line
/// `@layer\nreset, base;` 형식 보존.
fn isAtKeywordBoundary(source: []const u8, pos_after_keyword: u32, len: u32) bool {
    if (pos_after_keyword >= len) return true; // EOF
    const c = source[pos_after_keyword];
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == ';';
}

/// ASCII case-insensitive prefix 매칭. RFC3986: URL scheme 은 case-insensitive.
fn startsWithIgnoreCaseAscii(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (std.ascii.toLower(s[i]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

/// CSS `@import` specifier 가 external URL 인지 판정.
/// esbuild 기준: `http:`/`https:` protocol-prefixed 또는 `//` protocol-relative.
/// data: URL 도 spec 상 valid `@import` 대상이라 external 로 처리해 resolver 우회.
/// scheme 은 case-insensitive (RFC3986) — `HTTPS://` 도 external.
pub fn isExternalCssSpecifier(specifier: []const u8) bool {
    if (specifier.len < 2) return false;
    if (std.mem.startsWith(u8, specifier, "//")) return true;
    if (startsWithIgnoreCaseAscii(specifier, "http://")) return true;
    if (startsWithIgnoreCaseAscii(specifier, "https://")) return true;
    if (startsWithIgnoreCaseAscii(specifier, "data:")) return true;
    return false;
}

/// CSS 소스에서 @import 규칙 + @charset/@layer prefix 선언을 추출한다.
/// @charset, bare @layer, 공백, 주석은 건너뛰고, 첫 번째 non-import-like 규칙
/// 에서 중단. 반환된 specifier/text 는 source 의 슬라이스 — caller (parse_arena)
/// 가 소유. 결과 배열은 allocator 로 할당.
///
/// 이전 (#3747 fix 전): @charset / bare @layer 가 strip_end 영역에 들어가
/// silent drop. 본 함수가 두 종류를 prefix_decls 로 캡처해 emitter 가 보존
/// 가능하도록 함.
pub fn extractCssImportsWithPrefixes(allocator: std.mem.Allocator, source: []const u8) struct {
    imports: []const CssImportRecord,
    prefix_decls: []const CssPrefixDecl,
} {
    const MAX_IMPORTS = 64;
    const MAX_PREFIX = 32;
    var imp_buf: [MAX_IMPORTS]CssImportRecord = undefined;
    var pre_buf: [MAX_PREFIX]CssPrefixDecl = undefined;
    var imp_count: usize = 0;
    var pre_count: usize = 0;

    var pos: u32 = 0;
    const len: u32 = @intCast(source.len);

    while (pos < len) {
        // 공백 스킵
        pos = skipWhitespace(source, pos, len);
        if (pos >= len) break;

        // 주석 스킵
        if (pos + 1 < len and source[pos] == '/' and source[pos + 1] == '*') {
            pos = skipBlockComment(source, pos, len);
            continue;
        }

        // @charset 캡처 — 선언 텍스트 보존 (마지막 `;` 미포함)
        // word-boundary 가드: `@charsetXYZ` 같은 다른 at-rule 을 charset 으로
        // 오인하지 않도록 다음 byte 가 CSS whitespace 또는 `;` 또는 EOF 일 때만
        // 진입 (code-review max — Angle B2).
        if (startsWithAt(source, pos, len, "charset") and isAtKeywordBoundary(source, pos + 8, len)) {
            const start = pos;
            const after_semi = skipToSemicolon(source, pos, len);
            // skipToSemicolon 은 `;` *다음* 위치 반환. 텍스트는 `;` 제외.
            const text_end: u32 = if (after_semi > start and after_semi <= len and source[after_semi - 1] == ';')
                after_semi - 1
            else
                after_semi;
            if (pre_count < MAX_PREFIX) {
                pre_buf[pre_count] = .{ .kind = .charset, .text = source[start..text_end] };
                pre_count += 1;
            }
            pos = after_semi;
            continue;
        }

        // @layer (bare, 세미콜론으로 끝나는 형태만) 캡처 — block-form 은 본문 규칙
        if (startsWithAt(source, pos, len, "layer")) {
            // word-boundary: `@layer` 다음은 CSS whitespace(LF/CR 포함) / `;` / EOF
            // 여야 함. `@layerOTHER` 는 break (code-review max — Angle B1 fix:
            // 옛 코드가 `' '/'\\t'/';'` 만 허용 → `@layer\\nreset;` 가 캡처
            // 실패 + 후속 @import 까지 break 로 silent drop).
            if (!isAtKeywordBoundary(source, pos + 6, len)) {
                break; // @layer 가 아닌 다른 at-rule
            }
            // 세미콜론까지 또는 `{` (block-form) 위치 찾기
            const semi_pos = skipToSemicolonOrBrace(source, pos, len);
            if (semi_pos < len and source[semi_pos] == '{') break; // block-form → 본문
            const start = pos;
            // skipToSemicolonOrBrace 는 `;` 발견 시 *다음* 위치 (source[pos-1]==';'),
            // `{` 발견 시 `{` *직전* 위치 반환. 여기선 ; case 만 진입.
            const text_end: u32 = if (semi_pos > start and semi_pos <= len and source[semi_pos - 1] == ';')
                semi_pos - 1
            else
                semi_pos;
            if (pre_count < MAX_PREFIX) {
                pre_buf[pre_count] = .{ .kind = .layer_bare, .text = source[start..text_end] };
                pre_count += 1;
            }
            pos = semi_pos;
            continue;
        }

        // @import 추출
        if (startsWithAt(source, pos, len, "import")) {
            const start = pos;
            pos += 7; // "@import" 길이
            pos = skipWhitespace(source, pos, len);
            if (pos >= len) break;

            // url("...") 또는 "..." 또는 '...' 파싱
            const spec = extractSpecifier(source, pos, len) orelse break;
            const tail_start = spec.end_pos;
            pos = skipToSemicolon(source, spec.end_pos, len);
            // condition_tail = specifier 끝 이후 ~ `;` 직전 까지. external @import
            // 재emit 시 media-query/layer/supports clause 보존용. `;` 자체는 제외
            // — emitter 가 `";\n"` 으로 따로 붙임 (포함하면 double semicolon).
            // `skipToSemicolon` 은 `;` *다음* 위치 반환 (source[pos-1]==';'), 또는
            // `;` 미발견 시 len. trailing 공백/CR 은 함께 잡혀도 valid CSS 라 무해.
            const tail_end: u32 = blk: {
                if (pos > tail_start and pos <= len and source[pos - 1] == ';') break :blk pos - 1;
                break :blk pos;
            };
            const tail_slice: []const u8 = if (tail_end > tail_start)
                source[tail_start..tail_end]
            else
                "";

            if (imp_count < MAX_IMPORTS) {
                const specifier_slice = source[spec.start..spec.end];
                imp_buf[imp_count] = .{
                    .specifier = specifier_slice,
                    .span = .{ .start = start, .end = pos },
                    .is_external = isExternalCssSpecifier(specifier_slice),
                    .condition_tail = tail_slice,
                };
                imp_count += 1;
            }
            continue;
        }

        // 다른 규칙 → @import 영역 종료
        break;
    }

    const imports_out: []const CssImportRecord = if (imp_count == 0)
        &.{}
    else blk: {
        const owned = allocator.alloc(CssImportRecord, imp_count) catch break :blk &.{};
        @memcpy(owned, imp_buf[0..imp_count]);
        break :blk owned;
    };
    const prefix_out: []const CssPrefixDecl = if (pre_count == 0)
        &.{}
    else blk: {
        const owned = allocator.alloc(CssPrefixDecl, pre_count) catch break :blk &.{};
        @memcpy(owned, pre_buf[0..pre_count]);
        break :blk owned;
    };
    return .{ .imports = imports_out, .prefix_decls = prefix_out };
}

/// 기존 호출부 호환 wrapper — @import 만 반환. caller 가 prefix_decls 를 안
/// 보므로 wrapper 가 즉시 해제 (안 하면 caller 의 `defer allocator.free(imports)`
/// 가 prefix_decls 메모리는 그대로 leak — GPA 가 잡음). 신규 콜러는
/// `extractCssImportsWithPrefixes` 사용 권장.
pub fn extractCssImports(allocator: std.mem.Allocator, source: []const u8) []const CssImportRecord {
    const result = extractCssImportsWithPrefixes(allocator, source);
    if (result.prefix_decls.len > 0) allocator.free(result.prefix_decls);
    return result.imports;
}

const SpecifierResult = struct {
    start: u32,
    end: u32,
    end_pos: u32,
};

/// CSS quoted string 의 닫는 quote 위치를 찾는다.
/// CSS spec §4.3.5: `\` 다음 한 글자는 escape 로 specifier 종료 quote 가 아님.
/// `\` 가 source 끝이면 자기 자신만 1바이트 소비 (방어).
fn findClosingQuote(source: []const u8, start: u32, len: u32, quote: u8) u32 {
    var p = start;
    while (p < len) {
        if (source[p] == '\\') {
            // escape 다음 1바이트 skip (data: URL 에 `\"x\"` 같은 패턴 보존).
            p += 2;
            continue;
        }
        if (source[p] == quote) return p;
        p += 1;
    }
    return p;
}

fn extractSpecifier(source: []const u8, pos: u32, len: u32) ?SpecifierResult {
    var p = pos;
    if (p >= len) return null;

    // url("...") 또는 url('...') 또는 url(...)
    if (p + 3 < len and source[p] == 'u' and source[p + 1] == 'r' and source[p + 2] == 'l' and source[p + 3] == '(') {
        p += 4;
        p = skipWhitespace(source, p, len);
        if (p >= len) return null;

        if (source[p] == '"' or source[p] == '\'') {
            const quote = source[p];
            p += 1;
            const start = p;
            p = findClosingQuote(source, p, len, quote);
            const end = p;
            if (p < len) p += 1; // 닫는 따옴표
            p = skipWhitespace(source, p, len);
            if (p < len and source[p] == ')') p += 1;
            return .{ .start = start, .end = end, .end_pos = p };
        } else {
            // url(path) — 따옴표 없는 형태
            const start = p;
            while (p < len and source[p] != ')' and source[p] != ' ' and source[p] != '\t') : (p += 1) {}
            const end = p;
            if (p < len and source[p] == ')') p += 1;
            return .{ .start = start, .end = end, .end_pos = p };
        }
    }

    // "..." 또는 '...'
    if (source[p] == '"' or source[p] == '\'') {
        const quote = source[p];
        p += 1;
        const start = p;
        p = findClosingQuote(source, p, len, quote);
        const end = p;
        if (p < len) p += 1; // 닫는 따옴표
        return .{ .start = start, .end = end, .end_pos = p };
    }

    return null;
}

fn skipWhitespace(source: []const u8, start: u32, len: u32) u32 {
    var p = start;
    while (p < len and (source[p] == ' ' or source[p] == '\t' or source[p] == '\n' or source[p] == '\r')) : (p += 1) {}
    return p;
}

fn skipBlockComment(source: []const u8, start: u32, len: u32) u32 {
    var p = start + 2; // "/*" 이후
    while (p + 1 < len) : (p += 1) {
        if (source[p] == '*' and source[p + 1] == '/') return p + 2;
    }
    return len;
}

fn skipToSemicolon(source: []const u8, start: u32, len: u32) u32 {
    var p = start;
    while (p < len and source[p] != ';') : (p += 1) {}
    if (p < len) p += 1; // 세미콜론 포함
    return p;
}

fn skipToSemicolonOrBrace(source: []const u8, start: u32, len: u32) u32 {
    var p = start;
    while (p < len and source[p] != ';' and source[p] != '{') : (p += 1) {}
    if (p < len and source[p] == ';') p += 1;
    return p;
}

fn startsWithAt(source: []const u8, pos: u32, len: u32, keyword: []const u8) bool {
    if (pos >= len or source[pos] != '@') return false;
    const after = pos + 1;
    if (after + keyword.len > len) return false;
    return std.mem.eql(u8, source[after .. after + keyword.len], keyword);
}

// ============================================================
// 테스트
// ============================================================

test "extractCssImports: basic string import" {
    const source = "@import \"./reset.css\";\nbody { color: red; }";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("./reset.css", imports[0].specifier);
}

test "extractCssImports: url() import" {
    const source = "@import url(\"./base.css\");\n.foo {}";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("./base.css", imports[0].specifier);
}

test "extractCssImports: single-quoted" {
    const source = "@import './theme.css';\n";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("./theme.css", imports[0].specifier);
}

test "extractCssImports: multiple imports" {
    const source = "@import \"./a.css\";\n@import \"./b.css\";\n@import \"./c.css\";\nbody {}";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    try std.testing.expectEqual(@as(usize, 3), imports.len);
    try std.testing.expectEqualStrings("./a.css", imports[0].specifier);
    try std.testing.expectEqualStrings("./b.css", imports[1].specifier);
    try std.testing.expectEqualStrings("./c.css", imports[2].specifier);
}

test "extractCssImports: @charset before import" {
    const source = "@charset \"UTF-8\";\n@import \"./base.css\";\nbody {}";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("./base.css", imports[0].specifier);
}

test "extractCssImports: comment before import" {
    const source = "/* reset */\n@import \"./reset.css\";\nbody {}";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("./reset.css", imports[0].specifier);
}

test "extractCssImports: no imports" {
    const source = "body { color: red; }";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    try std.testing.expectEqual(@as(usize, 0), imports.len);
}

test "extractCssImports: empty source" {
    const imports = extractCssImports(std.testing.allocator, "");
    try std.testing.expectEqual(@as(usize, 0), imports.len);
}

test "extractCssImports: url without quotes" {
    const source = "@import url(./bare.css);\n";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("./bare.css", imports[0].specifier);
}

test "extractCssImports: stops at non-import rule" {
    const source = "@import \"./a.css\";\n.class { color: red; }\n@import \"./b.css\";\n";
    const imports = extractCssImports(std.testing.allocator, source);
    defer std.testing.allocator.free(imports);
    // 두 번째 @import는 non-import 규칙(.class) 이후이므로 무시
    try std.testing.expectEqual(@as(usize, 1), imports.len);
}
