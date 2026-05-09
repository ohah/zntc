//! Public codegen option types.

const std = @import("std");
const types = @import("../bundler/types.zig");

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
    /// Peephole 출력 최적화 - boolean literal을 `!0`/`!1`로 축약(#1552).
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
    /// JSON을 CJS require()로 소비할 때 synthetic named export declarations를 생략.
    /// default object는 `module.exports = {...}`로 유지한다.
    skip_cjs_named_export_decls: bool = false,
    /// 번들 모드에서 ESM이 아닐 때 import.meta -> {} 치환 (esbuild 호환)
    replace_import_meta: bool = false,
    /// 타겟 플랫폼. import.meta polyfill 방식을 결정한다.
    /// - node: import.meta.url -> require("url").pathToFileURL(__filename).href,
    ///         import.meta.dirname -> __dirname, import.meta.filename -> __filename
    /// - browser/neutral: import.meta.url -> "", import.meta.dirname -> "", import.meta.filename -> ""
    platform: Platform = .browser,
    /// --keep-names: minify 시 함수/클래스의 .name 프로퍼티 보존.
    /// codegen이 rename 감지 후 __name() 호출을 수집, 선언 직후에 append.
    keep_names: bool = false,
    /// ES2023 미만 타겟에서 hashbang (#!) 제거
    strip_hashbang: bool = false,
    // JSX 옵션 제거: Transformer의 jsx_lowering이 JSX -> call_expression 변환을 담당.
    // JsxRuntime enum은 graph.zig/emitter.zig/transpile.zig에서 여전히 사용.
    /// __esm 호이스팅 모드: variable_declaration을 할당문으로 변환 (키워드 제거).
    /// emitter가 var 선언을 래퍼 밖에 별도 배치.
    esm_var_assign_only: bool = false,
    /// circular 모듈 (cycle_group > 0) 의 top-level `const`/`let` 을 `var` 로 강등 (#2198).
    /// 같은 IIFE/scope 안에 hoisted IL 이 그대로 emit 되면 cycle 모듈끼리 정의 전 참조가
    /// 발생해 TDZ ReferenceError 가 throw됨 (esbuild 와 동일 패턴 - var 호이스팅으로
    /// `undefined` fallback). `var` 강등 후엔 ESM live binding 의미를 *대부분* 보존:
    /// cycle init 중 read 는 `undefined`, init 후 read 는 정상 값.
    force_var_for_cycle: bool = false,
    /// dev mode 모듈 ID. 설정 시 import.meta.hot -> __zntc_make_hot("id") 변환.
    dev_module_id: ?[]const u8 = null,
    /// require.context match 의 abs path -> module ID 변환 base.
    /// `__zntc_modules[<id>]` lookup 이 모듈 등록 ID 와 일치해야 하므로 emitter 가 동일
    /// `root_dir` 을 전달. null 이면 변환 없음 (legacy 절대 경로).
    require_context_module_id_root: ?[]const u8 = null,
    /// import.meta.glob 레코드. codegen이 glob 호출을 객체 리터럴로 직접 출력.
    import_records: []const types.ImportRecord = &.{},
    /// Metro x_facebook_sources function map emit 활성화.
    /// --platform=react-native 시 자동 활성화 (PR#3).
    sourcemap_function_map: bool = false,
    /// `new Worker(new URL("./worker.ts", import.meta.url))` 의 specifier->worker chunk filename
    /// 매핑 (per-module). emitNew 가 이 맵을 보고 매칭되면 filename + import.meta.url polyfill
    /// 로 직접 emit. bundler 가 모듈별로 sub-map 을 추출해 주입한다 (graph.worker_entries 에서
    /// 도출). null/empty 면 fast-exit - worker 가 없는 모듈에서 추가 비용 0.
    worker_map: ?*const std.StringHashMap([]const u8) = null,
    /// Debug 빌드 전용 내부 invariant. private syntax downlevel 대상인데 transformer 후
    /// raw private AST가 codegen까지 도달하면 사용자 입력 에러가 아니라 transformer 버그다.
    assert_no_raw_private_syntax: bool = false,
};

/// keepNames 엔트리. codegen이 수집하고 emitter가 __name() 호출로 변환.
pub const KeepNameEntry = struct {
    /// 리네임된 이름 (linker가 부여한 새 이름)
    new_name: []const u8,
    /// 원본 이름 (소스 코드의 함수/클래스 이름)
    original_name: []const u8,
};
