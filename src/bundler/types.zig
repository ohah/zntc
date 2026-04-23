//! ZTS Bundler — 공유 타입 정의
//!
//! 번들러의 모든 모듈이 공유하는 기본 타입.
//! D066 (에러 핸들링), D070 (모듈 ID), D073 (모듈 타입), D079 (import 추출) 설계 반영.

const std = @import("std");
const Span = @import("../lexer/token.zig").Span;
const SourceMapBuilder = @import("../codegen/sourcemap.zig").SourceMapBuilder;

/// dev mode에서 모듈별 HMR 업데이트 코드 (per-module code).
/// emitter, bundler, incremental 모듈에서 공유.
pub const ModuleDevCode = struct {
    id: []const u8,
    code: []const u8,
    /// Eager 모듈별 standalone source map (V3 JSON). null이면 sourcemap 미수집 혹은 lazy 경로.
    /// HMR 클라이언트가 eval한 코드에 sourceMappingURL data URL로 부착하여
    /// 전체 번들 sourcemap을 재생성하지 않고도 디버거 매핑을 유지한다 (Issue #1248).
    map: ?[]const u8 = null,
    /// Lazy per-module sourcemap builder (Issue #1727 Phase B).
    /// `EmitOptions.lazy_sourcemap = true` 일 때 JSON 을 사전 생성하지 않고 builder 를 이관하여
    /// NAPI getter (`getHmrSourceMap(moduleId)`) 호출 시점에 generateJSON 을 수행한다.
    /// `map` 과 상호 배타 — lazy 경로에선 `sm_builder` 만, eager 경로에선 `map` 만 채워진다.
    sm_builder: ?*SourceMapBuilder = null,

    pub fn freeAll(codes: []const ModuleDevCode, allocator: std.mem.Allocator) void {
        for (codes) |c| {
            allocator.free(c.id);
            allocator.free(c.code);
            if (c.map) |m| allocator.free(m);
            if (c.sm_builder) |sm| sm.destroy(allocator);
        }
        allocator.free(codes);
    }
};

// ============================================================
// 모듈 ID (D070)
// ============================================================

/// 모듈 그래프에서 모듈을 식별하는 인덱스.
/// NodeIndex, SymbolId, ScopeId와 동일한 u32 enum 패턴.
pub const ModuleIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: ModuleIndex) bool {
        return self == .none;
    }

    /// `modules[m.index.toU32()]` 형태의 인덱스 접근용.
    /// `@intFromEnum(m.index)`를 호출부마다 반복하지 않도록 한다 (#1553 항목 2).
    /// `none`에는 호출하지 말 것 — u32::MAX가 반환됨.
    pub inline fn toU32(self: ModuleIndex) u32 {
        return @intFromEnum(self);
    }

    /// usize 인덱서(ArrayList 등)용 편의.
    pub inline fn toUsize(self: ModuleIndex) usize {
        return @intCast(@intFromEnum(self));
    }
};

// ============================================================
// Alias (resolve.alias)
// ============================================================

/// import 경로 별칭. resolve 시 specifier 앞부분을 치환.
/// 정확 매칭: "react" → "preact/compat"
/// 접두사 매칭: "react/hooks" → "preact/compat/hooks"
pub const AliasEntry = struct {
    from: []const u8,
    to: []const u8,
};

/// Fallback 엔트리 (webpack `resolve.fallback` / Metro `resolver.extraNodeModules` 호환).
/// alias와 달리 일반 해석이 **실패했을 때만** 적용된다 — 설치된 실제 패키지가 있으면 그것이 우선.
/// `to == null`이면 빈 모듈로 대체 (webpack `false` 의미).
pub const FallbackEntry = struct {
    from: []const u8,
    to: ?[]const u8,
};

// ============================================================
// Import 종류
// ============================================================

/// import문의 종류. 모듈 그래프 엣지 분류에 사용.
pub const ImportKind = enum {
    /// import x from "./foo" / import { a } from "./foo"
    static_import,
    /// import("./foo")
    dynamic_import,
    /// export { x } from "./foo" / export * from "./foo"
    re_export,
    /// import "./foo" (specifier만, 바인딩 없음)
    side_effect,
    /// require("./foo") (CJS)
    require,
    /// new Worker(new URL('./worker.ts', import.meta.url))
    worker,
    /// import.meta.glob("./pages/*.tsx") — Vite 호환
    glob,
    /// require.context("./pages", true, /\.tsx$/, "sync") — webpack/Metro 호환 (#1579)
    require_context,
};

/// require.context mode. Metro/webpack 명세상 4가지.
pub const RequireContextMode = enum {
    /// 즉시 모든 매칭 파일 require (default, Expo Router 등)
    sync,
    /// dynamic import 로 포함하지만 번들엔 동기 로드 (sync 와 사실상 동일)
    eager,
    /// 각 파일이 개별 chunk (code splitting 필요)
    lazy,
    /// 전체가 하나의 chunk
    lazy_once,
};

// ============================================================
// Export 방식 (CJS/ESM 판별)
// ============================================================

/// 모듈의 export 방식. CJS/ESM 판별에 사용 (esbuild ExportsKind).
pub const ExportsKind = enum {
    /// 아직 결정되지 않음 (script, no module system)
    none,
    /// CommonJS (require, module.exports, exports.x)
    commonjs,
    /// ESM (import/export)
    esm,
    /// ESM + CJS 혼용 (export * from cjs 등)
    esm_with_dynamic_fallback,
};

/// 모듈 래핑 방식 (esbuild WrapKind).
pub const WrapKind = enum {
    /// 래핑 없음 — ESM 모듈, 스코프 호이스팅 적용
    none,
    /// CJS 래핑 — var require_foo = __commonJS({ ... })
    cjs,
    /// ESM 래핑 — var init_foo = __esm({ ... })
    /// ESM 모듈이 require()로 소비될 때 사용. 지연 초기화 + live binding 보존.
    /// top-level var/function은 래퍼 밖으로 호이스팅, 초기화 코드만 __esm 안에.
    /// CJS 참조: (init_foo(), __toCommonJS(foo_exports))
    /// ESM 참조: init_foo(); 직접 변수 참조
    esm,

    /// 래핑되는 모듈인지 (cjs 또는 esm). scope hoisting 대상이 아님.
    pub fn isWrapped(self: WrapKind) bool {
        return self != .none;
    }
};

/// CJS → ESM interop 모드 (Rolldown Interop).
/// importer의 모듈 정의 형식에 따라 __toESM 호출 방식이 결정됨.
pub const Interop = enum {
    /// __toESM(require_foo()) — __esModule 플래그 존중
    babel,
    /// __toESM(require_foo(), 1) — Node.js ESM 명세 호환 (항상 default: mod 설정)
    node,
};

/// 모듈 정의 형식 (Rolldown ModuleDefFormat).
/// 파일 확장자 또는 package.json "type" 필드로 결정.
/// CJS → ESM interop 시 Node 모드 활성화 여부에 사용.
pub const ModuleDefFormat = enum {
    /// 형식 미확정
    unknown,
    /// .cjs 확장자
    cjs,
    /// .cts 확장자
    cts,
    /// package.json "type": "commonjs"
    cjs_package_json,
    /// .mjs 확장자
    esm_mjs,
    /// .mts 확장자
    esm_mts,
    /// package.json "type": "module"
    esm_package_json,

    pub fn isEsm(self: ModuleDefFormat) bool {
        return self == .esm_mjs or self == .esm_mts or self == .esm_package_json;
    }

    pub fn isCommonjs(self: ModuleDefFormat) bool {
        return self == .cjs or self == .cts or self == .cjs_package_json;
    }
};

// ============================================================
// 청크 인덱스 (Code Splitting)
// ============================================================

/// 청크 그래프에서 청크를 식별하는 인덱스.
pub const ChunkIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: ChunkIndex) bool {
        return self == .none;
    }
};

// ============================================================
// 모듈 타입 (D073)
// ============================================================

/// 파일 확장자 또는 설정에 의해 결정되는 모듈 타입.
/// ParserAndGenerator 패턴(rspack)의 기반.
pub const ModuleType = enum {
    javascript,
    json,
    css,
    asset,
    unknown,

    /// 파일 확장자로부터 모듈 타입을 추론한다.
    pub fn fromExtension(ext: []const u8) ModuleType {
        if (std.mem.eql(u8, ext, ".ts") or
            std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".jsx") or
            std.mem.eql(u8, ext, ".mjs") or
            std.mem.eql(u8, ext, ".mts") or
            std.mem.eql(u8, ext, ".cjs") or
            std.mem.eql(u8, ext, ".cts"))
        {
            return .javascript;
        }
        if (std.mem.eql(u8, ext, ".json")) return .json;
        if (std.mem.eql(u8, ext, ".css")) return .css;
        return .unknown;
    }
};

// ============================================================
// Legal Comments
// ============================================================

/// 라이센스 주석 (@license, @preserve, /*!) 처리 모드.
pub const LegalComments = enum {
    /// 기본: minify 시 eof, 아니면 inline
    default,
    /// 모든 legal 주석 제거
    none,
    /// 원래 위치에 보존 (현재 기본 동작)
    @"inline",
    /// 파일 끝에 모아서 출력
    eof,
    /// eof + 별도 .LEGAL.txt 파일에 링크 주석 추가
    linked,
    /// 별도 .LEGAL.txt 파일로만 추출
    external,

    pub fn fromString(s: []const u8) ?LegalComments {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "inline")) return .@"inline";
        if (std.mem.eql(u8, s, "eof")) return .eof;
        if (std.mem.eql(u8, s, "linked")) return .linked;
        if (std.mem.eql(u8, s, "external")) return .external;
        return null;
    }
};

// ============================================================
// 출력 포맷
// ============================================================

/// 번들 출력 모듈 포맷.
pub const Format = enum {
    esm,
    cjs,
    iife,
    umd,
    amd,

    /// IIFE 계열 포맷 (iife, umd, amd) — 함수 래핑 필요
    pub fn isWrappedFormat(self: Format) bool {
        return switch (self) {
            .iife, .umd, .amd => true,
            .esm, .cjs => false,
        };
    }
};

// ============================================================
// 로더 (Asset Loader)
// ============================================================

/// 모듈의 로딩 방식. ModuleType(파일의 본질)과 별개로,
/// 번들러가 파일을 어떻게 처리할지 결정한다.
/// --loader:.png=file 같은 CLI 옵션으로 확장자별 오버라이드 가능.
/// 플러그인 API의 load 훅과 1:1 대응 (docs/PLUGINS.md 참고).
pub const Loader = enum {
    /// 기본값 — JS/TS 파싱 파이프라인
    javascript,
    /// JSON 모듈 (기존 처리)
    json,
    /// CSS (미구현, 향후 CSS 번들링)
    css,
    /// 파일을 출력 디렉토리에 복사하고 URL 문자열을 export.
    /// export default "/assets/logo-a1b2c3.png"
    file,
    /// 파일을 base64 data URL로 인라인.
    /// export default "data:image/png;base64,..."
    dataurl,
    /// 파일을 UTF-8 문자열로 export.
    /// export default "file contents..."
    text,
    /// 파일을 base64 인코딩 + __toBinary 런타임 헬퍼로 Uint8Array export.
    /// export default __toBinary("base64...")
    binary,
    /// file과 동일하되 원본 디렉토리 구조를 유지.
    copy,
    /// 빈 모듈 (무시)
    empty,
    /// 알 수 없는 로더 (에러 발생)
    none,

    /// 확장자에서 기본 로더를 추론한다.
    /// JS/JSON/CSS는 해당 로더, 나머지는 .none (--loader로 명시 필요).
    pub fn fromExtension(ext: []const u8) Loader {
        if (std.mem.eql(u8, ext, ".ts") or
            std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".jsx") or
            std.mem.eql(u8, ext, ".mjs") or
            std.mem.eql(u8, ext, ".mts") or
            std.mem.eql(u8, ext, ".cjs") or
            std.mem.eql(u8, ext, ".cts"))
        {
            return .javascript;
        }
        if (std.mem.eql(u8, ext, ".json")) return .json;
        if (std.mem.eql(u8, ext, ".css")) return .css;
        if (std.mem.eql(u8, ext, ".txt")) return .text;
        return .none;
    }

    /// 문자열에서 Loader enum으로 변환 (CLI 파싱용).
    /// "file", "dataurl", "text", "binary", "copy", "json", "css", "empty" 지원.
    pub fn fromString(s: []const u8) ?Loader {
        if (std.mem.eql(u8, s, "file")) return .file;
        if (std.mem.eql(u8, s, "dataurl")) return .dataurl;
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "binary")) return .binary;
        if (std.mem.eql(u8, s, "copy")) return .copy;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "css")) return .css;
        if (std.mem.eql(u8, s, "empty")) return .empty;
        if (std.mem.eql(u8, s, "js")) return .javascript;
        if (std.mem.eql(u8, s, "jsx")) return .javascript;
        if (std.mem.eql(u8, s, "ts")) return .javascript;
        if (std.mem.eql(u8, s, "tsx")) return .javascript;
        return null;
    }

    /// asset 로더인지 (file/dataurl/text/binary/copy/empty).
    /// JS/JSON/CSS가 아닌 로더.
    pub fn isAsset(self: Loader) bool {
        return switch (self) {
            .file, .dataurl, .text, .binary, .copy, .empty => true,
            else => false,
        };
    }
};

/// --loader:.ext=type CLI 옵션 하나를 나타내는 쌍.
pub const LoaderOverride = struct {
    /// 확장자 (dot 포함, 예: ".png")
    ext: []const u8,
    /// 적용할 로더
    loader: Loader,
};

// ============================================================
// Import 레코드 (D079)
// ============================================================

/// AST에서 추출한 단일 import/export 정보.
/// import_scanner가 AST 순회로 수집하고, 모듈 그래프가 resolve에 사용.
pub const ImportRecord = struct {
    /// 원본 import 경로 (예: "./foo", "react", "../utils")
    specifier: []const u8,
    /// import 종류
    kind: ImportKind,
    /// 소스 코드에서의 위치 (에러 메시지용)
    span: Span,
    /// worker: new URL(...) 전체 범위 (리라이트 대상)
    url_span: ?Span = null,
    /// resolve 완료 후 채워지는 모듈 인덱스
    resolved: ModuleIndex = .none,
    /// --external로 명시적으로 제외된 모듈 (resolve 실패와 구분)
    is_external: bool = false,
    /// glob: eager import 여부 (import.meta.glob의 { eager: true } 옵션)
    glob_eager: bool = false,
    /// glob: import할 export 이름 (import.meta.glob의 { import: "default" } 옵션)
    glob_import_name: ?[]const u8 = null,
    /// glob: 확장된 매칭 파일 목록 (resolve 후 graph가 설정)
    glob_matches: ?[]const []const u8 = null,
    /// require.context: recursive flag (default true) — `require.context(dir, recursive)` 두 번째 인자
    context_recursive: bool = true,
    /// require.context: filter regex 패턴 본문 (slashes 제외, default `^\./.*$`).
    /// `/foo\.tsx?$/i` 의 `foo\.tsx?$` 부분.
    context_filter: ?[]const u8 = null,
    /// require.context: filter regex flags (default 빈 string).
    /// `/foo/im` 의 `im` 부분. flags 차이로 dependency identity 가 달라진다 (Metro 동작).
    context_filter_flags: ?[]const u8 = null,
    /// require.context: code splitting mode (default sync)
    context_mode: RequireContextMode = .sync,
    /// require.context: invalid arguments 발견 시 reason. graph 단계에서 BundlerDiagnostic 으로
    /// 변환되어 사용자에게 표시. null 이면 valid.
    context_invalid_reason: ?[]const u8 = null,
    /// require.context: 매칭된 파일 목록. host plugin (`resolveContext`) 또는 내장 fallback 이
    /// graph 단계에서 채운다. codegen 이 이 목록을 보고 webpackContext 함수를 emit (Phase 3).
    /// null = 아직 평가 안 됨, &.{} = 매칭 0개 (empty context).
    context_matches: ?[]const []const u8 = null,
};

// ============================================================
// 번들러 진단 정보 (D066)
// ============================================================

/// 번들러 에러/경고.
/// esbuild의 suggestion + Bun의 step enum 설계.
pub const BundlerDiagnostic = struct {
    /// 에러 코드 (프로그래밍적 처리용)
    code: ErrorCode,
    /// 심각도
    severity: Severity,
    /// 에러 메시지
    message: []const u8,
    /// 에러가 발생한 파일 경로
    file_path: []const u8,
    /// 소스 코드에서의 위치
    span: Span,
    /// 어느 단계에서 발생했는지 (Bun ParseTask.Error.Step 참고)
    step: Step,
    /// 해결 제안 (예: "Did you mean './foo.js'?")
    suggestion: ?[]const u8 = null,

    pub const ErrorCode = enum {
        /// import 경로를 resolve할 수 없음
        unresolved_import,
        /// export 이름을 찾을 수 없음
        missing_export,
        /// 순환 참조 감지
        circular_dependency,
        /// re-export source가 자기 자신으로 resolve (alias/plugin 잘못)
        circular_reexport,
        /// 파일 파싱 실패
        parse_error,
        /// 파일 읽기 실패
        read_error,
        /// resolve 중 메모리 부족
        resolve_error,
        /// JSON 파싱 실패
        json_parse_error,
        /// 확장자에 대한 로더 미설정 (esbuild 호환: "No loader is configured for ...")
        no_loader,
        /// require.context 인자가 invalid (Phase 1 의 context_invalid_reason 노출). #1579
        require_context_invalid,
        /// require.context 매칭 핸들러 미구현 (host plugin resolveContext hook 없음). #1579 / #1771
        require_context_no_handler,
    };

    pub const Severity = enum {
        @"error",
        warning,
        info,
    };

    pub const Step = enum {
        resolve,
        parse,
        transform,
        link,
        emit,
    };
};

// ============================================================
// 공유 유틸리티
// ============================================================

/// []const u8 문자열을 사전순으로 비교하는 comparator.
/// 결정론적 출력을 위한 정렬에 사용 (cross-chunk import/export 이름 등).
pub fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// 모듈 경로에서 prefix_xxx 형태의 변수명을 생성한다.
/// 공통 로직: node_modules 이후 경로 추출 → 확장자 제거 → 비식별자 문자를 _로 치환.
fn makeVarNameWithPrefix(allocator: std.mem.Allocator, path: []const u8, prefix: []const u8) ![]const u8 {
    const nm = "node_modules" ++ std.fs.path.sep_str;
    const significant = if (std.mem.lastIndexOf(u8, path, nm)) |pos|
        path[pos + nm.len ..]
    else
        std.fs.path.basename(path);

    const without_ext = if (std.mem.lastIndexOf(u8, significant, ".")) |dot|
        significant[0..dot]
    else
        significant;

    var name: std.ArrayList(u8) = .empty;
    try name.appendSlice(allocator, prefix);
    for (without_ext) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try name.append(allocator, c);
        } else {
            try name.append(allocator, '_');
        }
    }
    return name.toOwnedSlice(allocator);
}

/// CJS 래핑용 변수명. "lib/foo-bar.cjs" → "require_foo_bar"
pub fn makeRequireVarName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return makeVarNameWithPrefix(allocator, path, "require_");
}

/// WrapESM 모듈의 init 함수 변수명 생성 (e.g. "init_foo_bar")
pub fn makeInitVarName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return makeVarNameWithPrefix(allocator, path, "init_");
}

/// WrapESM 모듈의 exports namespace 변수명 생성 (e.g. "foo_bar_exports")
pub fn makeExportsVarName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return makeVarNameWithPrefix(allocator, path, "exports_");
}

/// dev mode: `(__zts_modules["<dev_id>"].fn(), __toCommonJS(__zts_modules["<dev_id>"].exports))`
/// HMR에서 new Function()이 번들 스코프 밖에서 실행되므로 레지스트리 동적 lookup 사용.
/// require_rewrites(metadata.zig) 및 default re-export(esm_wrap.zig)에서 공유.
pub fn fmtDevRequireExpr(allocator: std.mem.Allocator, dev_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "(__zts_modules[\"{s}\"].fn(), __toCommonJS(__zts_modules[\"{s}\"].exports))", .{ dev_id, dev_id });
}

/// npm 패키지 specifier를 UMD/AMD factory 매개변수명으로 변환.
/// "react" → "React", "react-dom" → "ReactDOM", "lodash/fp" → "LodashFp"
/// PascalCase 변환 + 특수문자 제거. 호출자가 반환값을 소유.
pub fn specifierToParamName(allocator: std.mem.Allocator, specifier: []const u8) ![]const u8 {
    // 스코프 패키지: @scope/name → name 부분만 사용
    const base = if (std.mem.indexOfScalar(u8, specifier, '/')) |slash| blk: {
        if (specifier.len > 0 and specifier[0] == '@') {
            break :blk specifier[slash + 1 ..];
        }
        break :blk specifier;
    } else specifier;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var capitalize_next = true; // PascalCase: 첫 글자 대문자
    for (base) |c| {
        if (c == '-' or c == '/' or c == '.' or c == '@') {
            capitalize_next = true;
            continue;
        }
        if (capitalize_next) {
            try buf.append(allocator, std.ascii.toUpper(c));
            capitalize_next = false;
        } else {
            try buf.append(allocator, c);
        }
    }
    if (buf.items.len == 0) return try allocator.dupe(u8, specifier);
    return try buf.toOwnedSlice(allocator);
}

/// Span을 u64 키로 변환. 번들러 전역에서 식별자/노드를 고유 식별하는 데 사용.
/// binding_scanner, linker 등에서 동일 함수를 공유하여 키 불일치 방지.
pub fn spanKey(span: Span) u64 {
    return @as(u64, span.start) << 32 | span.end;
}

/// 모듈 인덱스 + 이름 → 복합 키 (힙 할당). linker/tree_shaker의 export 맵에서 사용.
/// 형식: [4 bytes module_index][0x00][name bytes]
pub fn makeModuleKey(allocator: std.mem.Allocator, module_index: u32, name: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, 4 + 1 + name.len);
    @memcpy(buf[0..4], std.mem.asBytes(&module_index));
    buf[4] = 0;
    @memcpy(buf[5..], name);
    return buf;
}

/// 모듈 인덱스 + 이름 → 복합 키 (스택 버퍼, 조회용). 할당 없음.
/// name이 4091바이트를 초과하면 assert 실패.
pub fn makeModuleKeyBuf(buf: *[4096]u8, module_index: u32, name: []const u8) []const u8 {
    const total = 5 + name.len;
    std.debug.assert(total <= 4096);
    @memcpy(buf[0..4], std.mem.asBytes(&module_index));
    buf[4] = 0;
    @memcpy(buf[5 .. 5 + name.len], name);
    return buf[0..total];
}
