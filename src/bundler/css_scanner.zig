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

// ============================================================
// CSS 본문 url() 스캐너 (#4466)
// ============================================================

/// CSS url 참조의 종류 — 소비자가 처리를 달리해야 해서 구분한다.
pub const CssUrlKind = enum {
    /// `./f.woff2`, `f.woff2`, `pkg/img.png` — 파일로 resolve 해서 자산으로
    /// 방출하고 url 을 재작성한다.
    relative,
    /// `/logo.png` — 서버 절대경로 (public 디렉토리 규약). 파일로 resolve 하지
    /// **않는다**. app 빌더만 `--base` prefix 를 붙이고, 번들러는 원문 그대로 둔다.
    root_absolute,
};

/// CSS 본문에서 발견된 자산 참조 하나 (`url(./f.woff2)` 또는 image-set() 의
/// bare string). @import 은 CssImportRecord 가 따로 다룬다.
pub const CssUrlRecord = struct {
    /// 경로 — 따옴표와 `?query`/`#fragment` 를 뗀 순수 경로.
    specifier: []const u8,
    /// 재작성 대상 byte 범위. `url(` 과 `)` *사이* 인자 전체(따옴표 포함),
    /// 또는 image-set() 안의 bare string 토큰 전체(따옴표 포함).
    /// emitter 가 이 구간을 `"<새 URL>"` 로 통째 치환하므로 `url(` / `)` 는
    /// 원문 그대로 남는다.
    span: Span,
    /// specifier 뒤에 붙어 있던 `?query` / `#fragment` 원문 (없으면 "").
    /// 재작성된 URL 뒤에 그대로 다시 붙여 IE9 `?#iefix` 훅과 SVG fragment
    /// 참조를 보존한다.
    suffix: []const u8,
    kind: CssUrlKind,
};

/// URI scheme (`data:`, `blob:`, `http:`, `chrome-extension:` …) 으로 시작하는지.
/// RFC3986 scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":".
///
/// 2글자 이상만 scheme 으로 인정 — Windows 드라이브 문자(`C:`)를 scheme 으로
/// 오인해 로컬 경로를 통째로 skip 하는 것을 막는다.
fn hasUriScheme(s: []const u8) bool {
    if (s.len < 3) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ':') return i >= 2;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return false;
}

/// `?query` / `#fragment` 를 경로에서 분리. 둘 중 먼저 나오는 것 기준.
/// app 빌더의 HTML 참조 처리(app/build.zig)도 같은 규칙을 쓴다.
pub fn splitUrlSuffix(s: []const u8) struct { path: []const u8, suffix: []const u8 } {
    const idx = std.mem.indexOfAny(u8, s, "?#") orelse return .{ .path = s, .suffix = "" };
    return .{ .path = s[0..idx], .suffix = s[idx..] };
}

/// 이 url() 참조의 종류를 판정. null = 스캐너가 아예 보고하지 않음(원문 그대로
/// 통과) — esbuild/Vite/rspack 공통 동작.
///
/// null 로 빠지는 것들:
/// - `#gradient` — 같은 문서 안의 SVG filter/gradient/clip-path 참조. **절대**
///   건드리면 안 된다 (파일이 아니다).
/// - `data:` / `http(s):` / `//cdn…` / `blob:` — external.
/// - `url(?foo)` — 경로부가 비어 대상이 없다.
pub fn classifyCssUrl(raw: []const u8) ?CssUrlKind {
    if (raw.len == 0) return null;
    if (raw[0] == '#') return null;
    if (isExternalCssSpecifier(raw)) return null;
    if (hasUriScheme(raw)) return null;
    if (splitUrlSuffix(raw).path.len == 0) return null;
    if (raw[0] == '/') return .root_absolute;
    return .relative;
}

/// 식별자 문자 — `url(` 앞 글자가 이것이면 `myurl(` / `blur(` 같은 다른 함수의
/// 꼬리를 잘못 잡은 것이므로 매칭하지 않는다.
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c >= 0x80;
}

/// pos 에서 keyword(ASCII, 소문자) 가 case-insensitive 하게 시작하고, 그 앞이
/// 식별자 경계인지.
fn matchesFunctionAt(source: []const u8, pos: u32, keyword: []const u8) bool {
    if (pos + keyword.len > source.len) return false;
    if (pos > 0 and isIdentChar(source[pos - 1])) return false;
    return std.ascii.eqlIgnoreCase(source[pos .. pos + keyword.len], keyword);
}

/// CSS 본문(`start` 이후)에서 자산 참조를 모두 추출한다.
///
/// 기존 `@import` 스캐너와 달리 **파일 끝까지** 훑는다. 주석과 문자열을 토큰
/// 단위로 인식하므로 `/* url(x) */` 나 `content: "url(y)"` 같은 위양성이 없다
/// (app/build.zig 의 옛 substring 스캔이 가진 결함).
///
/// 반환 슬라이스의 specifier/suffix 는 source 슬라이스 — caller(parse_arena)
/// 소유. 배열 자체는 allocator 할당. OOM 시 빈 슬라이스.
pub fn extractCssUrls(allocator: std.mem.Allocator, source: []const u8, start: u32) []const CssUrlRecord {
    var out: std.ArrayListUnmanaged(CssUrlRecord) = .empty;
    defer out.deinit(allocator);

    const len: u32 = @intCast(source.len);
    var pos: u32 = @min(start, len);

    // image-set() 안의 *직계* bare string 은 URL 이다 (`image-set("a.png" 1x)`).
    // 단 `type("image/avif")` 처럼 한 단계 더 들어간 괄호 안의 문자열은 URL 이
    // 아니므로, image-set 이 열린 시점의 괄호 depth 를 기억해 두고 그 depth 에
    // 있는 문자열만 URL 로 인정한다.
    var paren_depth: u32 = 0;
    var image_set_depths: [8]u32 = undefined;
    var image_set_len: usize = 0;

    while (pos < len) {
        const c = source[pos];

        // 주석
        if (c == '/' and pos + 1 < len and source[pos + 1] == '*') {
            pos = skipBlockComment(source, pos, len);
            continue;
        }

        // 문자열 토큰
        if (c == '"' or c == '\'') {
            const content_start = pos + 1;
            const content_end = findClosingQuote(source, content_start, len, c);
            const after = if (content_end < len) content_end + 1 else content_end;

            const directly_in_image_set = image_set_len > 0 and
                image_set_depths[image_set_len - 1] == paren_depth;
            if (directly_in_image_set) {
                appendCssUrlRecord(allocator, &out, source, content_start, content_end, pos, after);
            }
            pos = after;
            continue;
        }

        // url( … )
        if ((c == 'u' or c == 'U') and matchesFunctionAt(source, pos, "url(")) {
            pos = scanUrlFunction(allocator, &out, source, pos + 4, len);
            continue;
        }

        // image-set( … ) / -webkit-image-set( … )
        if ((c == 'i' or c == 'I') and matchesFunctionAt(source, pos, "image-set(")) {
            pos += 10;
            paren_depth += 1;
            if (image_set_len < image_set_depths.len) {
                image_set_depths[image_set_len] = paren_depth;
                image_set_len += 1;
            }
            continue;
        }
        if (c == '-' and matchesFunctionAt(source, pos, "-webkit-image-set(")) {
            pos += 18;
            paren_depth += 1;
            if (image_set_len < image_set_depths.len) {
                image_set_depths[image_set_len] = paren_depth;
                image_set_len += 1;
            }
            continue;
        }

        if (c == '(') {
            paren_depth += 1;
        } else if (c == ')') {
            if (image_set_len > 0 and image_set_depths[image_set_len - 1] == paren_depth) {
                image_set_len -= 1;
            }
            if (paren_depth > 0) paren_depth -= 1;
        } else if (c == '{' or c == '}') {
            // 선언 블록 경계에서 괄호 상태를 리셋한다. CSS 값 안의 괄호는 선언을
            // 넘어가지 않으므로, 여기서 depth 가 0 이 아니면 깨진 입력이거나
            // 스캐너가 못 따라간 문법이라는 뜻이다. 리셋하지 않으면 짝 안 맞는
            // `(` 하나가 파일 끝까지 image-set 상태를 물고 가서, 이후의 평범한
            // 문자열들이 전부 URL 로 오인된다 (블록 하나로 피해를 가둔다).
            paren_depth = 0;
            image_set_len = 0;
        }
        pos += 1;
    }

    return out.toOwnedSlice(allocator) catch &.{};
}

/// `url(` 바로 뒤(arg_pos)부터 닫는 `)` 까지 파싱하고, 자산이면 record 를 남긴다.
/// 반환값은 계속 스캔할 다음 위치.
fn scanUrlFunction(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(CssUrlRecord),
    source: []const u8,
    arg_pos: u32,
    len: u32,
) u32 {
    var p = skipWhitespace(source, arg_pos, len);
    if (p >= len) return len;

    const span_start = p;
    var content_start: u32 = undefined;
    var content_end: u32 = undefined;

    if (source[p] == '"' or source[p] == '\'') {
        const quote = source[p];
        p += 1;
        content_start = p;
        content_end = findClosingQuote(source, p, len, quote);
        p = if (content_end < len) content_end + 1 else content_end;
    } else {
        // 따옴표 없는 url-token — 공백/`)` 에서 끝난다. `\` escape 는 한 글자 소비.
        content_start = p;
        while (p < len) {
            const ch = source[p];
            if (ch == '\\') {
                p += 2;
                continue;
            }
            if (ch == ')' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c) break;
            p += 1;
        }
        content_end = @min(p, len);
    }

    const span_end = @min(p, len);
    appendCssUrlRecord(allocator, out, source, content_start, content_end, span_start, span_end);

    // 닫는 `)` 까지 진행 — 여기서 소비해야 바깥 루프의 paren_depth 가 흐트러지지 않는다.
    while (p < len and source[p] != ')') : (p += 1) {}
    if (p < len) p += 1;
    return p;
}

/// content 범위를 자산 참조로 판정하고 record 를 append. 재작성 대상이 아니면 무시.
fn appendCssUrlRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(CssUrlRecord),
    source: []const u8,
    content_start: u32,
    content_end: u32,
    span_start: u32,
    span_end: u32,
) void {
    if (content_end < content_start or content_end > source.len) return;
    const raw = std.mem.trim(u8, source[content_start..content_end], " \t\n\r");
    const kind = classifyCssUrl(raw) orelse return;
    const split = splitUrlSuffix(raw);
    out.append(allocator, .{
        .specifier = split.path,
        .span = .{ .start = span_start, .end = span_end },
        .suffix = split.suffix,
        .kind = kind,
    }) catch return;
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

// ============================================================
// extractCssUrls (#4466)
// ============================================================

/// 헬퍼 — `.relative`(= 자산으로 방출·재작성 대상) specifier 목록만 뽑는다.
/// `.root_absolute` 는 app 빌더 전용이라 여기선 제외.
fn expectUrls(source: []const u8, expected: []const []const u8) !void {
    const urls = extractCssUrls(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(urls);
    var actual: std.ArrayListUnmanaged([]const u8) = .empty;
    defer actual.deinit(std.testing.allocator);
    for (urls) |u| {
        if (u.kind == .relative) try actual.append(std.testing.allocator, u.specifier);
    }
    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "extractCssUrls: @font-face src — 이슈 #4466 재현 케이스" {
    const source = "@font-face { font-family: myicons; src: url(./dummy.ttf) format(\"truetype\"); }";
    try expectUrls(source, &.{"./dummy.ttf"});
}

test "extractCssUrls: 따옴표 3형태 (bare/double/single)" {
    try expectUrls(".a { background: url(./a.png); }", &.{"./a.png"});
    try expectUrls(".b { background: url(\"./b.png\"); }", &.{"./b.png"});
    try expectUrls(".c { background: url('./c.png'); }", &.{"./c.png"});
}

test "extractCssUrls: span 이 url() 인자만 덮는다 (url( 와 ) 는 보존)" {
    const source = ".a { background: url(\"./a.png\"); }";
    const urls = extractCssUrls(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(urls);
    try std.testing.expectEqual(@as(usize, 1), urls.len);
    // span 은 따옴표를 포함하고 url( / ) 는 제외해야 한다.
    try std.testing.expectEqualStrings("\"./a.png\"", source[urls[0].span.start..urls[0].span.end]);
}

test "extractCssUrls: @font-face 다중 src — woff2/woff/ttf/eot 전부" {
    const source =
        \\@font-face {
        \\  font-family: X;
        \\  src: url(./f.eot);
        \\  src: local("X"),
        \\       url("./f.woff2") format("woff2"),
        \\       url('./f.woff') format("woff"),
        \\       url(./f.ttf) format("truetype");
        \\}
    ;
    try expectUrls(source, &.{ "./f.eot", "./f.woff2", "./f.woff", "./f.ttf" });
}

test "extractCssUrls: local() / format() 은 URL 이 아니다" {
    const source = "@font-face { src: local(\"Helvetica\"), url(./h.woff2) format(\"woff2\"); }";
    try expectUrls(source, &.{"./h.woff2"});
}

test "extractCssUrls: 재작성 제외 — external / data / 절대경로 / SVG fragment" {
    try expectUrls(".a { background: url(https://cdn.example.com/a.png); }", &.{});
    try expectUrls(".b { background: url(//cdn.example.com/b.png); }", &.{});
    try expectUrls(".c { background: url(data:image/png;base64,iVBOR); }", &.{});
    try expectUrls(".d { background: url(/public/d.png); }", &.{}); // relative 아님 → 번들러는 손대지 않음
    // SVG filter/gradient 참조 — 파일이 아니므로 절대 건드리면 안 된다
    try expectUrls(".e { filter: url(#blur); clip-path: url(#c); }", &.{});
    try expectUrls(".f { background: url(blob:http://x/y); }", &.{});
}

test "extractCssUrls: 대문자 URL( 과 http 대소문자 혼용" {
    try expectUrls(".a { background: URL(./a.png); }", &.{"./a.png"});
    try expectUrls(".b { background: Url(HTTPS://x.com/b.png); }", &.{});
}

test "extractCssUrls: ?query / #fragment suffix 분리 보존" {
    const source = "@font-face { src: url(./f.eot?#iefix) format(\"embedded-opentype\"), url(./i.svg#icon) format(\"svg\"); }";
    const urls = extractCssUrls(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(urls);
    try std.testing.expectEqual(@as(usize, 2), urls.len);
    try std.testing.expectEqualStrings("./f.eot", urls[0].specifier);
    try std.testing.expectEqualStrings("?#iefix", urls[0].suffix);
    try std.testing.expectEqualStrings("./i.svg", urls[1].specifier);
    try std.testing.expectEqualStrings("#icon", urls[1].suffix);
}

test "extractCssUrls: 주석 안의 url( 은 위양성이 아니다" {
    const source = "/* background: url(./commented.png); */\n.a { background: url(./real.png); }";
    try expectUrls(source, &.{"./real.png"});
}

test "extractCssUrls: 문자열 안의 url( 은 위양성이 아니다" {
    const source = ".a::before { content: \"url(./fake.png)\"; background: url(./real.png); }";
    try expectUrls(source, &.{"./real.png"});
}

test "extractCssUrls: myurl( / blur( 처럼 url 로 끝나는 식별자 오탐 방지" {
    const source = ".a { filter: blur(4px); --myurl: 1; background: url(./real.png); }";
    try expectUrls(source, &.{"./real.png"});
}

test "extractCssUrls: image-set() bare string 은 URL 로 인식" {
    const source = ".a { background-image: image-set(\"./a.png\" 1x, \"./b.png\" 2x); }";
    try expectUrls(source, &.{ "./a.png", "./b.png" });
}

test "extractCssUrls: image-set() 안의 type() 문자열은 URL 이 아니다" {
    const source = ".a { background-image: image-set(\"./a.avif\" type(\"image/avif\"), url(./b.png) 2x); }";
    try expectUrls(source, &.{ "./a.avif", "./b.png" });
}

test "extractCssUrls: -webkit-image-set" {
    const source = ".a { background-image: -webkit-image-set(\"./a.png\" 1x); }";
    try expectUrls(source, &.{"./a.png"});
}

test "extractCssUrls: image-set 밖의 문자열은 URL 이 아니다" {
    const source = ".a { font-family: \"./not-a-url.ttf\"; background: url(./real.png); }";
    try expectUrls(source, &.{"./real.png"});
}

test "extractCssUrls: start offset 이전은 스캔하지 않는다 (@import 영역 제외)" {
    const source = "@import url(./base.css);\n.a { background: url(./real.png); }";
    const body_start: u32 = @intCast(std.mem.indexOf(u8, source, "\n.a").? + 1);
    const urls = extractCssUrls(std.testing.allocator, source, body_start);
    defer std.testing.allocator.free(urls);
    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqualStrings("./real.png", urls[0].specifier);
}

test "extractCssUrls: 여러 규칙에 걸친 다수 url" {
    const source =
        \\.a { background: url(./a.png); }
        \\.b { border-image: url(./b.png) 30; }
        \\.c { cursor: url(./c.cur), auto; }
        \\.d { mask-image: url(./d.svg); }
        \\.e { list-style-image: url(./e.gif); }
    ;
    try expectUrls(source, &.{ "./a.png", "./b.png", "./c.cur", "./d.svg", "./e.gif" });
}

test "extractCssUrls: 자산 없음 / 빈 소스" {
    try expectUrls("body { color: red; }", &.{});
    try expectUrls("", &.{});
}

test "extractCssUrls: 닫히지 않은 url( — 크래시 없이 종료" {
    try expectUrls(".a { background: url(./a.png", &.{"./a.png"});
    try expectUrls(".a { background: url(\"./a.png", &.{"./a.png"});
}

test "classifyCssUrl: 종류 분류" {
    try std.testing.expectEqual(CssUrlKind.relative, classifyCssUrl("./a.png").?);
    try std.testing.expectEqual(CssUrlKind.relative, classifyCssUrl("a.png").?);
    try std.testing.expectEqual(CssUrlKind.relative, classifyCssUrl("../x/a.png").?);
    try std.testing.expectEqual(CssUrlKind.relative, classifyCssUrl("pkg/img.png").?);
    // 서버 절대경로 — 스캐너는 보고하되 파일 resolve 대상이 아니다.
    // app 빌더가 --base prefix 를 붙이는 데 쓴다.
    try std.testing.expectEqual(CssUrlKind.root_absolute, classifyCssUrl("/logo.png").?);
    // 아예 보고 안 함
    try std.testing.expect(classifyCssUrl("#blur") == null);
    try std.testing.expect(classifyCssUrl("data:image/png;base64,x") == null);
    try std.testing.expect(classifyCssUrl("https://cdn/x.png") == null);
    try std.testing.expect(classifyCssUrl("//cdn/x.png") == null);
    try std.testing.expect(classifyCssUrl("") == null);
}

test "extractCssUrls: root-absolute 는 root_absolute 로 보고된다 (app 빌더용)" {
    const urls = extractCssUrls(std.testing.allocator, ".a { background: url(/logo.png); }", 0);
    defer std.testing.allocator.free(urls);
    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqual(CssUrlKind.root_absolute, urls[0].kind);
    try std.testing.expectEqualStrings("/logo.png", urls[0].specifier);
}

test "hasUriScheme: Windows 드라이브 문자를 scheme 으로 오인하지 않는다" {
    try std.testing.expect(hasUriScheme("data:image/png"));
    try std.testing.expect(hasUriScheme("blob:http://x"));
    try std.testing.expect(!hasUriScheme("C:/x/y.png"));
    try std.testing.expect(!hasUriScheme("./a.png"));
    try std.testing.expect(!hasUriScheme("a.png"));
}
