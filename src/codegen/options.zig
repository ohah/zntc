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
    /// JSX 를 변환 없이 그대로 출력 (tsc `"jsx": "preserve"` 동등). TypeScript
    /// 어노테이션만 strip. downstream tool (`@vitejs/plugin-react` /
    /// `@preact/preset-vite` / `vite-plugin-solid` 등) 이 JSX 처리 담당하도록
    /// 위임할 때 사용 — vite/rollup plugin chain 안에서 ZNTC 가 먼저 처리해도
    /// JSX 가 raw 로 남아 후속 plugin 이 정상 변환 가능.
    preserve,

    /// CLI / NAPI string 입력을 enum 으로 변환. invalid 면 null — caller 가
    /// strict throw (NAPI) 또는 default fallback (CLI) 정책을 결정.
    /// tsconfig vocab (`react` / `react-jsx` / `react-jsxdev` / `react-native`)
    /// 은 받지 않음 — `tsconfig_merge.mapTsConfigJsxToRuntime` 가 처리.
    pub fn fromString(s: []const u8) ?JsxRuntime {
        if (std.mem.eql(u8, s, "classic")) return .classic;
        if (std.mem.eql(u8, s, "automatic")) return .automatic;
        if (std.mem.eql(u8, s, "automatic-dev")) return .automatic_dev;
        if (std.mem.eql(u8, s, "preserve")) return .preserve;
        return null;
    }
};

/// CJS wrapper `exports`/`module` 식별자 기본 이름. 옵션 default 와 PR-2
/// free-ref 가드의 "기본값이면 no-op(회귀 0)" 판정이 이 단일 소스를 공유 —
/// 리터럴 중복 시 default 변경이 회귀 0 불변식을 silent 로 깨므로 const 화.
pub const default_cjs_exports_name = "exports";
pub const default_cjs_module_name = "module";

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
    /// #4243: identifier 위치의 `\u{...}` brace escape(ES2015)를 es5 호환 `\uXXXX`
    /// 로 다운레벨. unicode_brace_escape 미지원 타겟(es5)일 때 transform 이 set.
    /// codegen 이 모든 identifier/property/key emit funnel 에서 일괄 적용(소스/
    /// 합성/디스트럭처링/클래스필드 구분 없이 한 지점).
    lower_unicode_brace: bool = false,
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
    /// CJS wrapper 본문의 `exports`/`module` 식별자 이름. `exports`/`module`
    /// 은 `__commonJS` wrapper 의 arrow 파라미터(`(exports,module)=>{...}`)라
    /// 순수 함수 지역 바인딩 — 호출자(`cb((mod={exports:{}}).exports,mod)`)
    /// 와 무관해 이름만 바꿔도 의미 불변. 기본값은 원본 그대로라 옵션 미주입
    /// 시 바이트 동일(회귀 0). emitter 가 wrapper 파라미터와 같은 값을 주입해
    /// codegen 합성 구문(`exports.x=`, `module.exports=`)과 본문 free 참조를
    /// 단일 소스로 동기화한다.
    cjs_exports_name: []const u8 = default_cjs_exports_name,
    cjs_module_name: []const u8 = default_cjs_module_name,
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
    // JSX 옵션 제거: Transformer의 jsx_lowering이 JSX -> call_expression 변환을 담당.
    // JsxRuntime enum은 graph.zig/emitter.zig/transpile.zig에서 여전히 사용.
    /// __esm 호이스팅 모드: variable_declaration을 할당문으로 변환 (키워드 제거).
    /// emitter가 var 선언을 래퍼 밖에 별도 배치.
    esm_var_assign_only: bool = false,
    /// (#4587 target a) preserve-modules + CJS unwrapped 모듈: 재할당되는 export 바인딩이
    /// `exports.<name>` 로 rename 됐을 때(linking_metadata.renames 가 `"exports."` prefix),
    /// 그 선언(`let A = init`)을 `exports.A = init;` 할당으로 낮춘다(`let exports.A` = SyntaxError
    /// 회피). 이 flag 는 top-level 선언 emit 의 renames 조회를 흔한 ESM 경로에서 건너뛰게 하는
    /// cheap 게이트 — pm-cjs 아닌 경로엔 오버헤드 0.
    pm_cjs_storage: bool = false,
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
    /// require.context match 의 init-call 참조 문자열 — import_records 와 같은 인덱스로
    /// [record_index][match_index]. emitter 가 linker 로 미리 계산해 전달
    /// (`(init_X(),__toCommonJS(exports_X))`). code_splitting / production 단일번들에서
    /// `__zntc_modules[id]`(dev HMR 전용) 대신 사용(issue #4039 + production require.context).
    /// 비어있으면(dev 단일번들) codegen 이 `__zntc_modules` fallback. element null = resolve 실패.
    require_context_init_refs: []const []const ?[]const u8 = &.{},
    /// import.meta.glob 레코드. codegen이 glob 호출을 객체 리터럴로 직접 출력.
    import_records: []const types.ImportRecord = &.{},
    /// Metro x_facebook_sources function map emit 활성화.
    /// --platform=react-native 시 자동 활성화 (PR#3).
    sourcemap_function_map: bool = false,
    /// `new Worker(new URL("./worker.ts", import.meta.url))` 의 specifier->worker chunk filename
    /// 매핑 (per-module). emitNew 가 이 맵을 보고 매칭되면 filename + import.meta.url polyfill
    /// 로 직접 emit. bundler 가 모듈별로 sub-map 을 추출해 주입한다 (graph.worker_entries 에서
    /// 도출). null/empty 면 fast-exit - worker 가 없는 모듈에서 추가 비용 0.
    worker_map: ?*const std.StringHashMapUnmanaged([]const u8) = null,
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
