//! ZNTC Bundler — Orchestrator
//!
//! 번들러의 최상위 공개 API. ResolveCache → ModuleGraph → Emitter 파이프라인을 조율.
//!
//! 사용법:
//!   var bundler = Bundler.init(allocator, .{
//!       .entry_points = &.{"src/index.ts"},
//!       .format = .esm,
//!   });
//!   defer bundler.deinit();
//!   const result = try bundler.bundle();
//!   defer result.deinit(allocator);

const std = @import("std");
const plugin_mod = @import("plugin.zig");
const types = @import("types.zig");
const fs = @import("fs.zig");
const BundlerDiagnostic = types.BundlerDiagnostic;
const ModuleIndex = types.ModuleIndex;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const EmitStore = @import("emit_store.zig").EmitStore;
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const Platform = @import("resolve_cache.zig").Platform;
const emitter = @import("emitter.zig");
const EmitOptions = emitter.EmitOptions;
const OutputFile = emitter.OutputFile;
const graph_assets = @import("graph/assets.zig");
pub const RnAssetMetadata = graph_assets.RnAssetMetadata;
const chunk_mod = @import("chunk.zig");
const linker_mod = @import("linker.zig");
const Linker = linker_mod.Linker;
const MangleReportCollector = linker_mod.MangleReportCollector;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const module_store = @import("module_store.zig");
const runtime_polyfills = @import("runtime_polyfills.zig");
const transpile_mod = @import("../transpile.zig");
const compat = @import("../transformer/transformer.zig").TransformOptions.compat;

/// `--platform=react-native` 프리셋 부울 플래그.
/// CLI(main.zig)와 NAPI(napi_entry.zig) 양쪽에서 단일 소스로 참조되어
/// 향후 플래그 추가/변경 시 한 곳만 수정하면 된다.
pub const ReactNativeBoolPreset = struct {
    flow: bool = true, // RN .js 파일은 Flow + JSX 혼용
    jsx_in_js: bool = true,
    configurable_exports: bool = true, // RN/Hermes: defineProperty에 configurable: true 필요
    strict_execution_order: bool = true, // Babel worklet 호환: 함수 호이스팅 방지
    worklet_transform: bool = true, // Reanimated worklet 네이티브 변환
    entry_error_guard: bool = true, // Metro guardedLoadModule 호환: entry trigger throw → ErrorUtils
    codegen_transform: bool = true, // RN view config inline (#2348) — Fabric early-register race 회피
};
pub const RN_BOOL_PRESET: ReactNativeBoolPreset = .{};

/// RN 프리셋에서 asset_registry 미지정 시 사용할 기본 AssetRegistry 모듈 경로.
/// RN 코어가 제공하는 표준 경로 (Metro와 동일).
pub const RN_DEFAULT_ASSET_REGISTRY: []const u8 = "react-native/Libraries/Image/AssetRegistry";

/// RN 프리셋의 기본 blockList 패턴. Metro의 `metro-config/defaults/exclusionList.js`와 동등.
/// 사용자가 추가 패턴 주면 이 기본값에 append된다.
pub const RN_DEFAULT_BLOCK_LIST: []const []const u8 = &.{
    "\\/android\\/app\\/build\\/",
    "\\/ios\\/Pods\\/",
    "\\/ios\\/build\\/",
    "\\/__tests__\\/",
    "\\/__fixtures__\\/",
};

/// CJS / UMD 출력 시 entry export 형식 — Rollup `output.exports` 호환 (#2159).
///
///  - `auto` (default): default-only → `module.exports = X` 단일, named-only → `exports.X = X`,
///                       mixed → 양쪽 + `__esModule` flag (interop)
///  - `named`         : 항상 named (`exports.X = X` + `__esModule` flag if has default)
///  - `default_`      : `module.exports = X` 단일 — default-only 일 때만, named 섞이면 에러
///  - `none`          : export 출력 안 함
///
/// ESM 출력에서는 무시 (`export { ... }` 그대로 emit). `default_` trailing underscore 는 Zig keyword 회피.
pub const OutputExports = enum {
    auto,
    named,
    default_,
    none,

    /// CLI / NAPI string 입력을 enum 으로 변환. invalid 면 null.
    /// `default` ↔ `.default_` 매핑은 Zig keyword 회피 (`SourceMapMode.inline_` 동일 패턴).
    pub fn fromString(s: []const u8) ?OutputExports {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "named")) return .named;
        if (std.mem.eql(u8, s, "default")) return .default_;
        if (std.mem.eql(u8, s, "none")) return .none;
        return null;
    }
};

/// Module Federation 번들 옵션 (#3318 P1-1). 정의는 `types.zig`
/// (federation.zig ↔ bundler.zig circular import 회피, types 는 양쪽 공통).
pub const MfBundleConfig = types.MfBundleConfig;

pub const BundleOptions = struct {
    entry_points: []const []const u8,
    format: EmitOptions.Format = .esm,
    platform: Platform = .browser,
    external: []const []const u8 = &.{},
    /// Module Federation (#3318 P1-1). null = 비-MF 빌드(영향 0).
    mf: ?MfBundleConfig = null,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    /// 스코프 호이스팅 활성화 (import/export 제거 + 변수 리네임). false면 기존 동작.
    scope_hoist: bool = true,
    /// tree-shaking 활성화 (미사용 export/모듈 제거). scope_hoist가 true일 때만 동작.
    tree_shaking: bool = true,
    /// code splitting 활성화. true이면 dynamic import 경계에서 청크를 분리하고
    /// 공유 모듈을 공통 청크로 추출한다. 결과는 BundleResult.outputs에 다중 파일로 반환.
    code_splitting: bool = false,
    /// Rollup `output.inlineDynamicImports` — dynamic import target 을 importer 와 같은
    /// chunk 로 흡수하고 `import("./x")` 호출을 `__esm` 래퍼 init/exports 호출로 재작성.
    /// `code_splitting=true` 와 조합해야 의미 있음. 결과 번들은 단일 파일로 실행 가능.
    /// 보존 보장: namespace identity (`(await import(x)) === (await import(x))`),
    /// top-level side effect 1회 실행, live binding.
    inline_dynamic_imports: bool = false,
    /// 작은 common 청크 자동 병합 임계(바이트, 모듈 source 합 추정). 0=비활성.
    /// Rollup `output.experimentalMinChunkSize` 류. src.bits⊆dst.bits 인 경우만
    /// 병합해 over-fetch 없음. entry/manual/dynamic 청크는 보존.
    min_chunk_size: usize = 0,
    /// 사용자 정의 청크 분할 (Rollup `manualChunks` 호환 Phase 1 / #1027).
    /// code_splitting=true 일 때만 동작. 매칭된 모듈은 pseudo-entry 로 BFS 에 참여
    /// → transitive dependency 도 같은 청크로, dynamic import target 도 manual 우선.
    manual_chunks: []const types.ManualChunkEntry = &.{},
    /// Rollup `manualChunks(id)` 함수 시그니처 호환 (#1027 Phase 2).
    /// 모듈 경로마다 호출해 반환한 이름으로 동적 manual 청크 생성. null 반환이면 auto.
    /// resolver + record 공존 시 **resolver 결과 우선**.
    manual_chunks_resolver: ?types.ManualChunksResolveFn = null,
    /// resolver 에 전달할 user context (TSFN 핸들, 상태 포인터 등).
    manual_chunks_ctx: ?*anyopaque = null,
    /// dev mode: 각 모듈을 __zntc_register() 팩토리로 래핑하고
    /// HMR 런타임을 주입한다. import.meta.hot API 지원.
    dev_mode: bool = false,
    /// dev mode에서 모듈 ID 생성 시 기준 경로 (상대 경로 계산용).
    root_dir: ?[]const u8 = null,
    /// React Fast Refresh 활성화. $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
    /// styled-components 1st-party transform (compiler.styledComponents).
    styled_components: bool = false,
    /// styled-components.ssr 옵션 — false 면 componentId 생략 (displayName 만).
    /// `@next/swc` 의 compiler.styledComponents.ssr 와 동일.
    styled_components_ssr: bool = true,
    /// styled-components.minify 옵션 — CSS template whitespace collapse.
    styled_components_minify: bool = false,
    /// styled-components.fileName 옵션 — displayName 에 `<basename>__` prefix.
    styled_components_file_name: bool = true,
    /// styled-components.pure 옵션 — `/* @__PURE__ */` annotation 추가 (tree-shaking).
    styled_components_pure: bool = false,
    /// styled-components.namespace 옵션 — componentId 에 `<namespace>__` prefix.
    styled_components_namespace: []const u8 = "",
    /// styled-components.meaninglessFileNames 옵션 — displayName fallback basename list.
    styled_components_meaningless_file_names: []const []const u8 = &.{"index"},
    /// styled-components.topLevelImportPaths 옵션 — vendored fork import source list.
    styled_components_top_level_import_paths: []const []const u8 = &.{},
    /// styled-components.cssProp 옵션 — `<div css={...}>` extract (후속 PR 에서 transform 구현).
    styled_components_css_prop: bool = false,
    /// emotion 1st-party transform (compiler.emotion). 활성 시 css 템플릿에 autoLabel 적용.
    emotion: bool = false,
    /// emotion.autoLabel 모드 — `.never` / `.always` (default) / `.dev_only`.
    emotion_auto_label: @import("../transformer/transformer.zig").AutoLabelMode = .always,
    /// emotion.sourceMap 옵션 — true 면 css 템플릿 끝에 inline sourceMap 주석을 append.
    emotion_source_map: bool = false,
    /// emotion.labelFormat 옵션 — label 이름 포맷 템플릿 (e.g. `[filename]--[local]`).
    emotion_label_format: []const u8 = "",
    /// emotion.importMap re-export 케이스 단순화 — vendored emotion css source list.
    emotion_extra_css_sources: []const []const u8 = &.{},
    /// emotion.importMap re-export 케이스 단순화 — vendored emotion styled source list.
    emotion_extra_styled_sources: []const []const u8 = &.{},
    /// dev mode에서 per-module codes 수집 (HMR rebuild용). 초기 빌드에서는 false로 메모리 절감.
    collect_module_codes: bool = false,
    /// dev_mode + collect_module_codes incremental rebuild 의 풀 bundle output (`output`)
    /// concat 과 sourcemap finalize 를 skip 한다. RN HMR client 는 module_dev_codes 만
    /// 사용하므로 풀 bundle 은 첫 빌드에서만 필요. wall ~57ms 절감 (565 module fixture
    /// 측정). caller 가 outfile 을 dev server 에서 file-based serve 하면 활성화 금지.
    skip_bundle_output: bool = false,
    /// `watch()` API 의 *initial* 빌드 결과를 outdir 에 쓰지 않는다 (#3779 follow-up).
    /// caller 가 이미 별도 `build()` 로 outdir 를 채워 둔 상태에서 watch handle 만 띄울 때
    /// 사용 — runServe 가 그 패턴 (`runBundle` 1회 + `watch()`). incremental rebuild 의 출력
    /// 동작은 `skip_bundle_output` (incremental 자동 설정) 으로 별도 제어되므로, 본 옵션은
    /// 오직 initial 단계만 영향. caller 가 outdir 를 미리 준비하지 않으면 dev server 가
    /// 404 — 위험은 caller 책임. bundler 자체는 이 옵션을 보지 않고 watch.zig 만 사용.
    skip_initial_output: bool = false,
    /// define 글로벌 치환 (--define:KEY=VALUE)
    define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
    /// legacy decorator 변환 (--experimental-decorators / tsconfig)
    experimental_decorators: bool = false,
    /// emitDecoratorMetadata: __metadata 호출 주입 (NestJS/Angular DI)
    emit_decorator_metadata: bool = false,
    /// `import { x } from 'mod'` cherry-pick 분해 매핑. babel-plugin-lodash 동등 (#2393).
    module_specifier_map: []const @import("../transformer/transformer.zig").ModuleSpecifierMapEntry = &.{},
    /// useDefineForClassFields=false (tsconfig)
    use_define_for_class_fields: bool = true,
    /// verbatimModuleSyntax=true (tsconfig/CLI): unused value import를 elide하지 않음.
    verbatim_module_syntax: bool = false,
    /// Unsupported features bitmask (ES/엔진 타겟에서 변환됨)
    unsupported: compat.UnsupportedFeatures = .{},
    /// package.json exports 커스텀 조건 (--conditions, esbuild 호환)
    conditions: []const []const u8 = &.{},
    /// symlink를 따라가지 않고 링크 자체 경로로 해석 (--preserve-symlinks)
    preserve_symlinks: bool = false,
    /// 일반 node_modules 탐색 실패 시 source_dir 의 realpath 디렉토리로 한 번 더 탐색
    /// (RN/pnpm peer sibling fallback). `preserve_symlinks` 와 직교.
    resolve_symlink_siblings: bool = false,
    /// Metro `resolver.disableHierarchicalLookup` 호환 — parent dir walk-up 차단.
    /// monorepo 에서 dependency hoisting 강제 또는 워크스페이스 루트 외부의
    /// `node_modules` 가 탐색되는 것을 차단할 때 사용.
    disable_hierarchical_lookup: bool = false,
    /// import 경로 별칭 (--alias:K=V). resolve 시 specifier 앞부분을 치환.
    alias: []const types.AliasEntry = &.{},
    /// tsconfig `paths` (절대 경로로 정규화된 형태). `*` wildcard + 다중 후보 순차 시도.
    /// alias 보다 먼저 매칭되며, resolver 가 파일 존재 확인까지 수행.
    ts_paths: []const @import("../config.zig").TsConfig.PathEntry = &.{},
    /// Fallback (webpack resolve.fallback / Metro extraNodeModules). 해석 실패 시에만 적용.
    fallback: []const types.FallbackEntry = &.{},
    /// Metro resolver.blockList 호환 — 매칭되는 절대 경로는 해석 차단.
    block_list: []const []const u8 = &.{},
    /// Metro AssetRegistry 모듈 경로. null이면 일반 URL 문자열 export (웹/esbuild 방식).
    /// 설정 시 file/copy 로더가 `module.exports = require("<path>").registerAsset({...})` 형태로 래핑.
    /// RN 플랫폼 프리셋에서 "react-native/Libraries/Image/AssetRegistry"로 자동 설정.
    asset_registry: ?[]const u8 = null,
    /// Metro `projectRoot` 호환 — asset httpServerLocation 계산의 기준 디렉토리.
    /// 미설정 시 entry_dir에서 위로 올라가며 첫 package.json 위치를 자동 감지.
    /// 모노레포의 packages/app/처럼 entry가 깊을 때 정확한 패키지 루트를 잡는다.
    project_root: []const u8 = "",
    /// 에셋/청크 URL prefix (--public-path). 동적 import 경로에 적용.
    public_path: []const u8 = "",
    /// 번들 출력 앞에 삽입할 텍스트 (--banner:js)
    banner_js: ?[]const u8 = null,
    /// 번들 출력 뒤에 삽입할 텍스트 (--footer:js)
    footer_js: ?[]const u8 = null,
    /// 포맷 wrapper 내부 코드 앞에 삽입할 텍스트 (Rollup output.intro)
    intro_js: ?[]const u8 = null,
    /// 포맷 wrapper 내부 코드 뒤에 삽입할 텍스트 (Rollup output.outro)
    outro_js: ?[]const u8 = null,
    /// IIFE 포맷에서 export를 바인딩할 글로벌 변수명 (--global-name)
    global_name: ?[]const u8 = null,
    /// IIFE external → 전역 식별자 매핑 (--globals, rollup `output.globals` 호환, #1824).
    /// emitter 가 IIFE factory 호출 인자로 사용. 매핑되지 않은 external 은 에러.
    globals: []const types.GlobalEntry = &.{},
    /// rollup 식 `output: [...]` multi-format emit 설정. 빈 슬라이스면 기존
    /// `format`/`globals` 를 fallback 으로 단일 default 합성. 길이 ≥ 2 시 같은
    /// module graph 를 N format 으로 reemit (후속 활성). 본 epic 단계에서는 dormant
    /// — bundler 가 항상 단일 emit 경로 사용.
    output: []const types.OutputConfig = &.{},
    /// 출력 파일 확장자 오버라이드 (--out-extension:.js=.mjs)
    out_extension_js: ?[]const u8 = null,
    /// 소스맵 관련 옵션 묶음 (enable/debug_ids/function_map/lazy/source_root/sources_content).
    /// 정의는 `src/codegen/sourcemap.zig` 의 `SourceMapOptions`.
    sourcemap: @import("../codegen/sourcemap.zig").SourceMapOptions = .{},
    /// 출력 파일명 (소스맵 참조용)
    output_filename: []const u8 = "bundle.js",
    /// 출력 디렉터리 (#3795). `watch()` worker 가 outputs[].path 를 outdir-relative 로
    /// 받아도 outdir 정보가 없으면 cwd 기준 fallback — JS 측 caller 가 명시한 outdir 와
    /// 어긋날 위험. 기본 빈 문자열 = "디렉터리 명시 없음". bundler 자체는 path 생성 시
    /// 이 필드를 보지 않고 (entry-relative 그대로), `watch.zig` 의 createFile 호출에서
    /// outdir 와 join 한다.
    outdir: []const u8 = "",
    /// UTF-8 문자를 이스케이프하지 않고 그대로 출력 (--charset=utf8)
    charset_utf8: bool = false,
    /// 엔트리 청크 파일명 패턴 (--entry-names, 기본: "[dir]/[name]")
    /// PR B-4b sub-2 (breaking): default 가 `[name]` 에서 `[dir]/[name]` 로
    /// 변경 (esbuild parity). 두 entry 가 같은 stem (예: pages/a/index.tsx +
    /// pages/b/index.tsx) 일 때 entry_dir 기준 상대 디렉토리(`pages/a`, `pages/b`)
    /// 가 자동으로 출력 경로에 prefix → 청크 path collision 자동 회피. 사용자가
    /// 명시적으로 `--entry-names=[name]` 을 지정하면 옛 평면 동작.
    /// `[dir]` 토큰은 sanitize 거친 entry_dir-relative dir (chunk.zig:
    /// entryRelativeDir) — 빈 dir 이면 leading-slash skip(esbuild parity).
    entry_names: []const u8 = "[dir]/[name]",
    /// 공통 청크 파일명 패턴 (--chunk-names, 기본: "[name]-[hash]")
    /// 일반·manual chunk 는 entry 가 아니라 dir 정보가 없어 `[dir]` 토큰 미사용.
    chunk_names: []const u8 = "[name]-[hash]",
    /// 에셋 파일명 패턴 (--asset-names, 기본: "[name]-[hash]")
    asset_names: []const u8 = "[name]-[hash]",
    /// CSS 출력 파일명 패턴 (--css-names, 기본: "[dir]/[name]")
    /// PR B-4b sub-2: entry_names 와 일관성을 위해 같이 `[dir]/[name]`. CSS
    /// 측 [dir] 토큰 처리는 PR B-2 / B-3 의 applyCssChunkNameWithDir 가 담당.
    css_names: []const u8 = "[dir]/[name]",
    /// 확장자별 로더 오버라이드 (--loader:.png=file)
    loader_overrides: []const types.LoaderOverride = &.{},
    /// legal comments 처리 모드 (--legal-comments)
    legal_comments: types.LegalComments = .default,
    /// metafile JSON 생성 (--metafile)
    metafile: bool = false,
    /// `--mangle-report=<path>` — mangler property 측정 JSON 저장 (#1760).
    /// `minify_identifiers=true` 일 때만 의미 있음 (그 외에는 빈 report).
    mangle_report_path: ?[]const u8 = null,
    /// #3423 P2-3: MF 무결성 sidecar Ed25519 서명 키(raw 32B seed base64
    /// 파일). null=서명 미산출(opt-in).
    mf_sign_key_path: ?[]const u8 = null,
    /// 번들 분석 출력 (--analyze). metafile을 내부적으로 강제 활성화.
    analyze: bool = false,
    /// 모든 모듈에 자동 import (--inject:./file.js). 절대 경로 목록.
    inject: []const []const u8 = &.{},
    /// 엔트리 모듈 직전에 실행할 모듈 (--run-before-main). 절대 경로 목록.
    /// Metro의 runBeforeMainModule과 동일 역할. inject와 같은 메커니즘으로
    /// 엔트리 의존성에 추가되어 먼저 실행된다.
    run_before_main: []const []const u8 = &.{},
    /// core-js runtime polyfill graph plan. JS wrapper computes target candidates,
    /// native graph selects usage-mode roots after parse/semantic.
    runtime_polyfills: ?runtime_polyfills.Plan = null,
    /// 번들 시작 시 즉시 실행 폴리필 (--polyfill). 절대 경로 목록.
    /// 파일 내용을 IIFE로 감싸서 런타임 헬퍼 앞에 인라인. 모듈 그래프에 미포함.
    polyfills: []const []const u8 = &.{},
    /// 예약 전역 식별자 (--global-identifier). scope hoisting 시 이 이름을 모듈 변수로
    /// 사용하지 않도록 리네이밍. RN의 polyfillGlobal()로 등록되는 이름 충돌 방지.
    global_identifiers: []const []const u8 = &.{},
    /// --shim-missing-exports: 존재하지 않는 export를 import할 때 에러 대신 undefined 제공.
    /// 롤다운 호환 — missing export에 대해 `var xxx = void 0;` shim 변수를 생성.
    shim_missing_exports: bool = false,
    /// --keep-names: minify 시 함수/클래스의 .name 프로퍼티 보존
    keep_names: bool = false,
    /// 플러그인 배열 (resolveId, load, transform, renderChunk, generateBundle 훅)
    plugins: []const plugin_mod.Plugin = &.{},
    /// 최대 워커 스레드 수. 0이면 기본값(CPU 코어 수). 1이면 단일 스레드.
    max_threads: u32 = 0,
    /// Flow 모드 강제 활성화 (--flow). @flow pragma 없이도 .js/.jsx를 Flow로 파싱.
    flow: bool = false,
    /// .js 파일에서도 JSX 파싱 활성화 (--platform=react-native 프리셋).
    jsx_in_js: bool = false,
    /// JSX 런타임 모드 (--jsx=classic|automatic|automatic-dev)
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
    /// classic 모드 JSX factory (--jsx-factory)
    jsx_factory: []const u8 = "React.createElement",
    /// classic 모드 Fragment factory (--jsx-fragment)
    jsx_fragment: []const u8 = "React.Fragment",
    /// automatic 모드 import source (--jsx-import-source)
    jsx_import_source: []const u8 = "react",
    /// 커스텀 확장자 탐색 순서 (--resolve-extensions). 비어있으면 기본값 사용.
    resolve_extensions: []const []const u8 = &.{},
    /// package.json 필드 해석 순서 (--main-fields). 비어있으면 기본 (module → main).
    main_fields: []const []const u8 = &.{},
    /// Object.defineProperty에 configurable: true 추가 (RN/Hermes 호환).
    /// --platform=react-native에서 자동 활성화.
    configurable_exports: bool = false,
    /// strict execution order: __esm factory 밖으로 함수 호이스팅 금지.
    /// Babel worklet 등이 function → var로 변환하면 init 순서가 깨지므로,
    /// 모든 코드를 factory 안에 유지. --platform=react-native에서 자동 활성화.
    strict_execution_order: bool = false,
    /// Metro `guardedLoadModule` 호환: entry trigger 호출을 try/catch +
    /// `ErrorUtils.reportFatalError(e)` 로 wrap. 자세한 설명은
    /// `EmitOptions.entry_error_guard`. RN preset 자동 활성.
    entry_error_guard: bool = false,
    /// Prologue 에 `console.error` setter intercept 주입 — RegExp source string 배열 의
    /// 어느 하나라도 match 하면 silent swallow. `entry_error_guard` 와 직교. consumer 가
    /// 환경 (e.g. expo) 감지 후 패턴 주입. 비어있으면 wrap 자체 emit X.
    silent_console_error_patterns: []const []const u8 = &.{},
    /// Reanimated worklet 네이티브 변환. --platform=react-native에서 자동 활성화.
    worklet_transform: bool = false,
    /// worklet의 `__pluginVersion` 값. null이면 ZNTC 기본 상수 사용.
    /// Reanimated dev mode runtime이 jsVersion과 대조하므로 사용자의 react-native-worklets
    /// 패키지 버전을 그대로 전달해야 런타임 mismatch 에러 없음.
    worklet_plugin_version: ?[]const u8 = null,
    /// RN view config codegen — `*NativeComponent.{js,ts}` 의 codegenNativeComponent
    /// 호출을 inline view config 로 교체 (#2348). --platform=react-native 에서 자동 활성.
    codegen_transform: bool = false,
    /// 증분 빌드용 모�� 파싱 캐시. null이면 매번 전체 파싱.
    /// IncrementalBundler가 소유하고 빌드 간 보존한다.
    module_store: ?*@import("module_store.zig").PersistentModuleStore = null,
    /// Watcher 가 이번 rebuild 동안 변경됐다고 보고한 절대경로 set (Issue #1727 §3).
    /// 주입되면 `graph.buildIncremental` 이 set 에 없는 모듈의 mtime stat syscall 을 skip
    /// — cached mtime 을 신뢰. 수백 모듈 규모에서 graphDiscover 주 병목이었음.
    /// null 이면 initial build / CLI / 변경 정보 없음 → 전체 stat (기존 동작).
    changed_files: ?*const std.StringHashMap(void) = null,
    /// Compiled output cache. HMR/watch 에서 변경 안 된 모듈의 emit 을 스킵.
    /// IncrementalBundler 가 소유.
    compiled_cache: ?*@import("compiled_cache.zig").CompiledOutputCache = null,
    /// 활성화할 디버그 로그 카테고리 (ZNTC_DEBUG env 와 합집합).
    /// 예: `&.{"compiled_cache", "hmr"}`. 카테고리 enum 은 `src/debug_log.zig` 참조.
    debug: []const []const u8 = &.{},
    /// --outbase: 엔트리 포인트 공통 기준 경로
    outbase: ?[]const u8 = null,
    /// --packages=external: 모든 bare import를 external 처리
    packages_external: bool = false,
    /// --ignore-annotations: @__PURE__, sideEffects 등 어노테이션 무시
    ignore_annotations: bool = false,
    /// --jsx-side-effects: 미사용 JSX를 tree-shake하지 않음
    jsx_side_effects: bool = false,
    /// --drop-labels: 제거할 labeled statement의 라벨 이름 목록
    drop_labels: []const []const u8 = &.{},
    /// `--drop=console` (#2155). console 호출 expression statement 를 transformer 에서 제거.
    drop_console: bool = false,
    /// `--drop=debugger` (#2155). `debugger;` statement 를 transformer 에서 제거.
    drop_debugger: bool = false,
    /// CJS / UMD entry export 출력 형식 (#2159). ESM 출력에서는 무시.
    output_exports: OutputExports = .auto,
    /// --pure:NAME: 순수 함수로 마킹할 글로벌 함수명 목록
    pure: []const []const u8 = &.{},
    /// --tsconfig-raw: tsconfig.json 인라인 오버라이드 JSON
    tsconfig_raw: ?[]const u8 = null,
    /// --node-paths: NODE_PATH 추가 탐색 경로
    node_paths: []const []const u8 = &.{},
    /// --line-limit: 줄 길이 제한 (0=무제한)
    line_limit: u32 = 0,
    /// --preserve-modules: 모듈 1개 = 출력 파일 1개 (라이브러리 빌드용).
    /// code_splitting과 동일한 다중 파일 출력 경로를 사용한다.
    preserve_modules: bool = false,
    /// --preserve-modules-root: 출력 디렉토리 구조의 기준 경로.
    /// 이 경로를 기준으로 상대 경로를 계산하여 출력 파일 구조를 결정한다.
    /// null이면 엔트리 포인트들의 공통 부모 디렉토리를 자동 계산.
    preserve_modules_root: ?[]const u8 = null,

    pub const AliasEntry = types.AliasEntry;
};

pub const BundleResult = struct {
    /// 번들 출력 내용 (단일 파일). code_splitting=false일 때 사용. allocator 소유.
    output: []const u8,
    /// 소스맵 JSON (V3). null이면 소스맵 미생성 혹은 lazy 경로. allocator 소유.
    sourcemap: ?[]const u8 = null,
    /// Lazy 번들 sourcemap builder (Issue #1727 Phase B).
    /// `BundleOptions.lazy_sourcemap = true` 일 때 `sourcemap` 대신 이 포인터로 builder 를 이관.
    /// NAPI handle 이 보관하고 `getBundleSourceMap()` 호출 시 `generateJSON` 수행.
    /// `BundleResult.deinit` 시 builder.deinit() + destroy.
    sourcemap_builder: ?*@import("../codegen/sourcemap.zig").SourceMapBuilder = null,
    /// 다중 출력 파일. code_splitting=true일 때 사용. allocator 소유.
    /// null이면 단일 파일 모드 (output 필드 사용).
    outputs: ?[]OutputFile = null,
    /// Multi-format emit 결과 (`BundleOptions.output.len >= 2` 시 사용). allocator 소유.
    /// null 이면 단일 format 모드 (`output`/`outputs` 필드 사용). 첫 entry 의 결과가
    /// `output` 필드에 alias 로 노출되어 backward-compat.
    outputs_by_format: ?[]types.FormatOutput = null,
    /// 빌드 중 발생한 진단 메시지들. deep copy — 내부 문자열도 allocator 소유.
    diagnostics: ?[]OwnedDiagnostic,
    /// 번들에 포함된 모든 모듈의 절대 경로. allocator 소유. dev server watch용.
    module_paths: ?[]const []const u8 = null,
    /// dev mode: JS 모듈별 __zntc_register(...) 코드. HMR 모듈 단위 업데이트용.
    /// id로 매칭 (module_paths와 인덱스 대응 아님). allocator 소유.
    module_dev_codes: ?[]const ModuleDevCode = null,
    /// asset 파일 출력 (file/copy 로더). allocator 소유.
    /// JS 청크와 별도로 출력 디렉토리에 복사해야 하는 파일들.
    asset_outputs: ?[]OutputFile = null,
    /// RN AssetRegistry.registerAsset 호출에 emit 된 asset metadata.
    /// `rn-asset-copy` 가 bundle string 파싱 없이 직접 사용.
    /// allocator 소유 (strings + scales slice).
    rn_asset_metadata: ?[]RnAssetMetadata = null,
    /// metafile JSON (--metafile). allocator 소유.
    metafile_json: ?[]const u8 = null,
    /// 파이프라인 단계별 타이밍 (ns). 항상 측정 — 워치 모드 관측성용.
    timings: BundleTimings = .{},
    /// 증분 빌드에서 실제로 재파싱된 모듈 수.
    /// non-incremental 빌드에서는 `null` (전체 파싱). HMR 관측성용.
    reparsed_modules: ?usize = null,
    /// 재파싱된 모듈의 path 목록. allocator 소유, `BundleResult.deinit` 이 해제.
    /// HMR 페이로드에서 cache-hit 모듈을 필터링할 때 사용 — canonical-name
    /// 비결정성으로 rebuild 간 emit 이 달라지는 phantom update 방지.
    reparsed_paths: ?[]const []const u8 = null,

    /// 단계별 빌드 시간 (나노초).
    pub const BundleTimings = struct {
        /// resolve + parse + finalize (graph build)
        graph_ns: u64 = 0,
        /// scope hoisting + linking
        link_ns: u64 = 0,
        /// tree-shaking
        shake_ns: u64 = 0,
        /// transform + codegen
        emit_ns: u64 = 0,
    };

    /// ns → ms 변환 헬퍼 (타이밍 노출 공용).
    pub fn nsToMs(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    }

    /// dev mode에서 모듈별 HMR 업데이트 코드. types.ModuleDevCode의 별칭.
    pub const ModuleDevCode = types.ModuleDevCode;

    /// 문자열 필드를 소유하는 diagnostic (graph 해제 후에도 유효).
    pub const OwnedDiagnostic = struct {
        code: BundlerDiagnostic.ErrorCode,
        severity: BundlerDiagnostic.Severity,
        message: []const u8,
        file_path: []const u8,
        step: BundlerDiagnostic.Step,
        suggestion: ?[]const u8,
    };

    pub fn deinit(self: *const BundleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.sourcemap) |sm| allocator.free(sm);
        if (self.sourcemap_builder) |sm| sm.destroy(allocator);
        if (self.outputs) |outs| {
            for (outs) |o| o.deinit(allocator);
            allocator.free(outs);
        }
        if (self.outputs_by_format) |by| {
            for (by) |fo| {
                // 첫 entry 의 output/sourcemap 은 result.output/sourcemap 으로 move 됐을 수 있음 —
                // 빈 슬라이스 (len 0) free 는 allocator 별 동작 차이 회피.
                if (fo.output.len > 0) allocator.free(fo.output);
                if (fo.sourcemap) |sm| allocator.free(sm);
            }
            allocator.free(by);
        }
        if (self.diagnostics) |diags| {
            for (diags) |d| {
                allocator.free(d.message);
                allocator.free(d.file_path);
                if (d.suggestion) |s| allocator.free(s);
            }
            allocator.free(diags);
        }
        if (self.module_paths) |paths| {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        if (self.reparsed_paths) |paths| {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        if (self.module_dev_codes) |codes| {
            ModuleDevCode.freeAll(codes, allocator);
        }
        if (self.asset_outputs) |outs| {
            for (outs) |o| {
                allocator.free(o.path);
                allocator.free(o.contents);
            }
            allocator.free(outs);
        }
        if (self.rn_asset_metadata) |metas| {
            for (metas) |m| graph_assets.freeRnAssetMetadata(allocator, m);
            allocator.free(metas);
        }
        if (self.metafile_json) |mf| allocator.free(mf);
    }

    pub fn hasErrors(self: *const BundleResult) bool {
        const diags = self.diagnostics orelse return false;
        for (diags) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn getDiagnostics(self: *const BundleResult) []const OwnedDiagnostic {
        return self.diagnostics orelse &[_]OwnedDiagnostic{};
    }
};

/// BundlerDiagnostic 을 allocator-owned OwnedDiagnostic 으로 deep copy 해 `dest` 에 채운다.
/// `filled` 는 이미 채워진 item 수 — 루프 내부에서 매 entry 성공 후 증가한다 (호출자의
/// errdefer 가 부분 할당분을 정확히 해제할 수 있도록).
fn copyDiagnostics(
    allocator: std.mem.Allocator,
    dest: []BundleResult.OwnedDiagnostic,
    src: []const types.BundlerDiagnostic,
    filled: *usize,
) !void {
    for (src) |d| {
        dest[filled.*] = .{
            .code = d.code,
            .severity = d.severity,
            .message = try allocator.dupe(u8, d.message),
            .file_path = try allocator.dupe(u8, d.file_path),
            .step = d.step,
            .suggestion = if (d.suggestion) |s| try allocator.dupe(u8, s) else null,
        };
        filled.* += 1;
    }
}

/// `ZNTC_DEBUG=module_stats` 진단: 모듈 분류 히스토그램 (docs/DEBUG.md §1).
/// node_modules dep 중 JSX/decorator/TS-feature 없는 모듈이 얼마나 되고 그 중 semantic 데이터를
/// 들고 있는지 = 모듈당 작업(semantic/metadata)이 어디 쏠려있는지 파악용.
fn dumpModuleStats(graph: *ModuleGraph) void {
    var total: usize = 0;
    var nm: usize = 0; // node_modules
    var has_sem: usize = 0;
    var prepass_ran: usize = 0; // transform_cache != null
    var w_none: usize = 0;
    var w_cjs: usize = 0;
    var w_esm: usize = 0;
    var jsx: usize = 0;
    var deco: usize = 0;
    var ts_feat: usize = 0;
    var plain_cjs_nm: usize = 0;
    var plain_esm_nm: usize = 0;
    var plain_none_nm: usize = 0;
    var plain_nm_has_sem: usize = 0;
    var type_hist = std.StringHashMap(usize).init(graph.allocator);
    defer type_hist.deinit();

    var it = graph.modulesIterator();
    while (it.next()) |m| {
        total += 1;
        const is_nm = std.mem.indexOf(u8, m.path, "/node_modules/") != null;
        if (is_nm) nm += 1;
        if (m.semantic != null) has_sem += 1;
        if (m.transform_cache != null) prepass_ran += 1;
        switch (m.wrap_kind) {
            .none => w_none += 1,
            .cjs => w_cjs += 1,
            .esm => w_esm += 1,
        }
        var has_jsx_f = false;
        var has_deco_f = false;
        var has_ts_f = false;
        if (m.ast) |ast| {
            has_jsx_f = ast.has_jsx;
            has_deco_f = ast.has_decorator;
            has_ts_f = ast.has_ts_namespace_or_enum or ast.has_ts_import_equals or ast.has_ts_export_equals;
        }
        if (has_jsx_f) jsx += 1;
        if (has_deco_f) deco += 1;
        if (has_ts_f) ts_feat += 1;
        const is_plain = !has_jsx_f and !has_deco_f and !has_ts_f;
        if (is_nm and is_plain) {
            switch (m.wrap_kind) {
                .none => plain_none_nm += 1,
                .cjs => plain_cjs_nm += 1,
                .esm => plain_esm_nm += 1,
            }
            if (m.semantic != null) plain_nm_has_sem += 1;
        }
        const e = type_hist.getOrPut(@tagName(m.module_type)) catch continue;
        if (!e.found_existing) e.value_ptr.* = 0;
        e.value_ptr.* += 1;
    }

    const debug_log = @import("../debug_log.zig");
    const pct = @as(f64, @floatFromInt(nm)) * 100.0 / @as(f64, @floatFromInt(@max(total, 1)));
    debug_log.print(
        .module_stats,
        "module stats\n" ++
            "  total={d}  node_modules={d} ({d:.0}%)  has_semantic={d}  prepass_ran(transform_cache)={d}\n" ++
            "  wrap_kind: none={d} cjs={d} esm={d}\n" ++
            "  features: jsx={d} decorator={d} ts(ns|enum|import=|export=)={d}\n" ++
            "  plain(no jsx/deco/ts) in node_modules: none={d} cjs={d} esm={d}  | of which has_semantic={d}\n" ++
            "  module_type:",
        .{ total, nm, pct, has_sem, prepass_ran, w_none, w_cjs, w_esm, jsx, deco, ts_feat, plain_none_nm, plain_cjs_nm, plain_esm_nm, plain_nm_has_sem },
    );
    var hit = type_hist.iterator();
    while (hit.next()) |e| std.debug.print(" {s}={d}", .{ e.key_ptr.*, e.value_ptr.* });
    std.debug.print("\n", .{});
}

pub const Bundler = struct {
    allocator: std.mem.Allocator,
    options: BundleOptions,
    resolve_cache: ResolveCache,
    /// 외부 소유 ResolveCache 포인터. non-null이면 이것을 사용하고 resolve_cache 필드는 무시.
    resolve_cache_ref: ?*ResolveCache = null,
    /// 외부 소유 ModuleGraph 포인터 (RFC #3933 Sub-PR-B.2). non-null이면 bundle() 가
    /// graph instance 를 init/deinit 하지 않고 그대로 재사용. caller (IncrementalBundler)
    /// 가 빌드 사이 graph 보존 → cache hit 모듈의 replay 단계 short-circuit 가능.
    /// 호출자 wire-up 은 Sub-PR-B.3 에서 — 현재는 API skeleton 만.
    external_graph: ?*ModuleGraph = null,
    /// #3318 ④: MF seam(shared/remote external + 글로벌)을 옵션 레이어가
    /// 아닌 번들러 단일 지점(bundle() 초입)에서 `opts.mf` 로부터 유도한
    /// combined 버퍼. self.allocator 소유 → **deinit 가 유일 free 지점**
    /// (필드 set 이후 errdefer 잔존 0 → bundle() 후속 try 실패+deinit
    /// 이중해제 없음). 원소는 borrow(opts.mf/static). mf 없으면 null.
    /// watch(persistent ResolveCache): 매 bundle() 가 resolve *전*
    /// setExternalPatterns 를 **무조건** 재주입(mf=sx / non-mf=options.
    /// external) → deinit 가 sx 를 free 해도 persistent cache 가 freed
    /// 포인터를 parking 하지 않음(mf→non-mf 전환·조기 resolve 안전).
    mf_eff_external: ?[]const []const u8 = null,
    mf_eff_globals: ?[]const types.GlobalEntry = null,

    /// platform=react-native → Hermes unsupported matrix로 덮어쓰기.
    /// 사용자가 --target으로 지정한 값은 무시된다 (Hermes는 ES 버전으로 표현 불가능한
    /// 부분 지원 조합이라 target 직교성이 깨짐). 관련 이슈: #1283.
    fn applyPlatformPreset(opts: *BundleOptions) void {
        if (opts.platform == .react_native) {
            opts.unsupported = compat.fromHermesPreset();
        }
    }

    pub fn initResolveCacheFromOptions(allocator: std.mem.Allocator, options: BundleOptions) ResolveCache {
        return ResolveCache.init(allocator, .{
            .platform = options.platform,
            .external_patterns = options.external,
            .custom_conditions = options.conditions,
            .preserve_symlinks = options.preserve_symlinks,
            .resolve_symlink_siblings = options.resolve_symlink_siblings,
            .disable_hierarchical_lookup = options.disable_hierarchical_lookup,
            .alias = options.alias,
            .ts_paths = options.ts_paths,
            .fallback = options.fallback,
            .block_list = options.block_list,
            .resolve_extensions = options.resolve_extensions,
            .main_fields = options.main_fields,
            .packages_external = options.packages_external,
            .node_paths = options.node_paths,
        });
    }

    pub fn init(allocator: std.mem.Allocator, options: BundleOptions) Bundler {
        var opts = options;
        applyPlatformPreset(&opts);
        @import("../debug_log.zig").addCategories(opts.debug);
        return .{
            .allocator = allocator,
            .options = opts,
            .resolve_cache = initResolveCacheFromOptions(allocator, opts),
        };
    }

    /// 외부에서 소유하는 ResolveCache를 사용하는 생성자.
    /// resolve_cache_ref 포인터를 저장하므로 얕은 복사 없이 원본을 직접 참조한다.
    pub fn initWithResolveCache(allocator: std.mem.Allocator, options: BundleOptions, rc: *ResolveCache) Bundler {
        var opts = options;
        applyPlatformPreset(&opts);
        @import("../debug_log.zig").addCategories(opts.debug);
        return .{
            .allocator = allocator,
            .options = opts,
            .resolve_cache = rc.*, // resolve_cache_ref가 우선이므로 이 값은 사용 안 됨
            .resolve_cache_ref = rc,
        };
    }

    /// RFC #3933 Sub-PR-B.2 — 외부 owned ModuleGraph + ResolveCache 를 받는 생성자.
    /// bundle() 가 graph 를 init/deinit 하지 않고 그대로 재사용. caller (IncrementalBundler)
    /// 가 빌드 사이 graph 보존하면 cache hit 모듈의 replay 단계 short-circuit 가능 (Sub-PR-B.3).
    /// 사용 전제: caller 가 graph 의 옵션 mirror (dev_mode, defines 등) 가 빌드 사이 일관 유지.
    pub fn initWithGraph(
        allocator: std.mem.Allocator,
        options: BundleOptions,
        rc: *ResolveCache,
        graph: *ModuleGraph,
    ) Bundler {
        var b = initWithResolveCache(allocator, options, rc);
        b.external_graph = graph;
        return b;
    }

    /// 실제 사용할 ResolveCache 포인터를 반환.
    fn getResolveCache(self: *Bundler) *ResolveCache {
        return self.resolve_cache_ref orelse &self.resolve_cache;
    }

    pub fn deinit(self: *Bundler) void {
        if (self.resolve_cache_ref == null) {
            self.resolve_cache.deinit();
        }
        // #3318 ④ combined seam 버퍼(컨테이너만; 원소 borrow).
        if (self.mf_eff_external) |x| self.allocator.free(x);
        if (self.mf_eff_globals) |x| self.allocator.free(x);
    }

    /// BundleOptions → TransformOptions base 변환 (#1961 PR 1f). graph 와 emitter
    /// 양쪽이 동일 base 를 시작점으로 transformer.init 호출 — drift hot spot 단일화.
    /// per-module override (react_refresh / plugins / jsx_transform / jsx_filename /
    /// emit_runtime_helper_imports / borrow_source_ast) 만 caller 가 추가.
    fn buildTransformOptionsBase(self: *const Bundler) @import("../transformer/transformer.zig").TransformOptions {
        return .{
            .define = self.options.define,
            .experimental_decorators = self.options.experimental_decorators,
            .emit_decorator_metadata = self.options.emit_decorator_metadata,
            .module_specifier_map = self.options.module_specifier_map,
            .use_define_for_class_fields = self.options.use_define_for_class_fields,
            .verbatim_module_syntax = self.options.verbatim_module_syntax,
            .unsupported = self.options.unsupported,
            .drop_labels = self.options.drop_labels,
            .drop_console = self.options.drop_console,
            .drop_debugger = self.options.drop_debugger,
            .jsx_side_effects = self.options.jsx_side_effects,
            .ignore_annotations = self.options.ignore_annotations,
            .jsx_runtime = self.options.jsx_runtime,
            .jsx_factory = self.options.jsx_factory,
            .jsx_fragment = self.options.jsx_fragment,
            .jsx_import_source = self.options.jsx_import_source,
            .worklet_plugin_version = self.options.worklet_plugin_version,
            .minify_syntax = self.options.minify_syntax,
            .minify_whitespace = self.options.minify_whitespace,
            .keep_names = self.options.keep_names,
        };
    }

    /// BundleOptions → EmitOptions 변환. 3개 경로(단일/splitting/dev)에서 공용.
    /// transformer 옵션 mirror 필드는 모두 `transform_options_base` 에서 derived —
    /// `self.options` 와 `base` 양쪽이 single source 두 곳이 되는 drift 위험 제거 (#1961 후속).
    fn makeEmitOptions(self: *const Bundler) EmitOptions {
        const base = self.buildTransformOptionsBase();
        return .{
            .transform_options_base = base,
            .format = self.options.format,
            // transformer-mirror 필드는 base 에서 derived (single source).
            .minify_whitespace = base.minify_whitespace,
            .minify_syntax = base.minify_syntax,
            .define = base.define,
            .experimental_decorators = base.experimental_decorators,
            .emit_decorator_metadata = base.emit_decorator_metadata,
            .use_define_for_class_fields = base.use_define_for_class_fields,
            .verbatim_module_syntax = base.verbatim_module_syntax,
            .unsupported = base.unsupported,
            .keep_names = base.keep_names,
            .drop_labels = base.drop_labels,
            .pure = self.options.pure,
            .output_exports = self.options.output_exports,
            .jsx_runtime = base.jsx_runtime,
            .jsx_factory = base.jsx_factory,
            .jsx_fragment = base.jsx_fragment,
            .jsx_import_source = base.jsx_import_source,
            .worklet_plugin_version = base.worklet_plugin_version,
            // emit-only 필드 (transformer 와 무관) — BundleOptions 직접 read.
            .minify_identifiers = self.options.minify_identifiers,
            .platform = self.options.platform,
            .public_path = self.options.public_path,
            .banner_js = self.options.banner_js,
            .footer_js = self.options.footer_js,
            .intro_js = self.options.intro_js,
            .outro_js = self.options.outro_js,
            .global_name = self.options.global_name,
            .globals = self.options.globals,
            .out_extension_js = self.options.out_extension_js,
            .sourcemap = self.options.sourcemap,
            .output_filename = self.options.output_filename,
            .charset_utf8 = self.options.charset_utf8,
            .entry_names = self.options.entry_names,
            .chunk_names = self.options.chunk_names,
            .asset_names = self.options.asset_names,
            .legal_comments = self.options.legal_comments,
            .line_limit = self.options.line_limit,
            .root_dir = self.options.root_dir,
            .plugins = self.options.plugins,
            .polyfills = &.{}, // 호출자가 loadPolyfills()로 설정
            .run_before_main = self.options.run_before_main,
            .configurable_exports = self.options.configurable_exports,
            .strict_execution_order = self.options.strict_execution_order,
            .entry_error_guard = self.options.entry_error_guard,
            .silent_console_error_patterns = self.options.silent_console_error_patterns,
            .worklet_transform = self.options.worklet_transform,
            // codegen_transform 은 graph 만 사용 (load 시점). emitter 에는 전파 안 함.
            .compiled_cache = self.options.compiled_cache,
        };
    }

    const WorkerBuildResult = struct {
        filename: []const u8,
        contents: []const u8,
    };

    /// Worker chunk 의 출력 포맷. Node CJS 빌드일 때만 CJS, 그 외엔 IIFE (브라우저 호환).
    fn workerFormat(self: *const Bundler) EmitOptions.Format {
        return if (self.options.platform == .node and self.options.format == .cjs) .cjs else .iife;
    }

    fn workerExtension(format: EmitOptions.Format) []const u8 {
        return switch (format) {
            .cjs => ".cjs",
            else => ".js",
        };
    }

    /// Worker 파일을 별도 번들로 빌드한다.
    fn buildWorker(self: *Bundler, worker_path: []const u8) !WorkerBuildResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // worker용 resolve cache (부모와 공유하지 않음)
        var worker_resolve_cache = ResolveCache.init(arena_alloc, .{ .platform = self.getResolveCache().platform });

        var worker_graph = ModuleGraph.init(arena_alloc, &worker_resolve_cache);
        worker_graph.loader_overrides = self.options.loader_overrides;
        worker_graph.public_path = self.options.public_path;
        worker_graph.project_root = self.options.project_root;
        worker_graph.pure = self.options.pure;
        worker_graph.ignore_annotations = self.options.ignore_annotations;
        worker_graph.plugins = self.options.plugins;
        worker_graph.max_threads = self.options.max_threads;
        worker_graph.flow = self.options.flow;
        worker_graph.jsx_in_js = self.options.jsx_in_js;
        worker_graph.jsx_runtime = self.options.jsx_runtime;
        worker_graph.jsx_import_source = self.options.jsx_import_source;
        // #1961: worker 모듈도 transformer pre-pass 가 동일 옵션 사용 — drift 방지.
        worker_graph.worklet_transform = self.options.worklet_transform;
        worker_graph.codegen_transform = self.options.codegen_transform;
        worker_graph.react_refresh = self.options.react_refresh;
        worker_graph.styled_components = self.options.styled_components;
        worker_graph.styled_components_ssr = self.options.styled_components_ssr;
        worker_graph.styled_components_minify = self.options.styled_components_minify;
        worker_graph.styled_components_file_name = self.options.styled_components_file_name;
        worker_graph.styled_components_pure = self.options.styled_components_pure;
        worker_graph.styled_components_namespace = self.options.styled_components_namespace;
        worker_graph.styled_components_meaningless_file_names = self.options.styled_components_meaningless_file_names;
        worker_graph.styled_components_top_level_import_paths = self.options.styled_components_top_level_import_paths;
        worker_graph.styled_components_css_prop = self.options.styled_components_css_prop;
        worker_graph.emotion = self.options.emotion;
        worker_graph.emotion_auto_label = self.options.emotion_auto_label;
        worker_graph.emotion_source_map = self.options.emotion_source_map;
        worker_graph.emotion_label_format = self.options.emotion_label_format;
        worker_graph.emotion_extra_css_sources = self.options.emotion_extra_css_sources;
        worker_graph.emotion_extra_styled_sources = self.options.emotion_extra_styled_sources;
        worker_graph.code_splitting = self.options.code_splitting;
        worker_graph.preserve_modules = self.options.preserve_modules;
        worker_graph.minify_identifiers = self.options.minify_identifiers;
        worker_graph.transform_options_base = self.buildTransformOptionsBase();
        defer worker_graph.deinit();

        const entry_path = try arena_alloc.dupe(u8, worker_path);
        const entry_arr: [1][]const u8 = .{entry_path};
        try worker_graph.build(&entry_arr);

        const format = self.workerFormat();

        // 링킹
        var worker_linker = Linker.init(arena_alloc, &worker_graph, format);
        // #1621: worker 청크도 minify 시 preamble 축약 이름 사용.
        worker_linker.minify_whitespace = self.options.minify_whitespace;
        worker_linker.configurable_exports = self.options.configurable_exports;
        worker_linker.inline_requires = self.options.platform == .react_native;
        if (self.options.mf) |*m| worker_linker.mf_remotes = m.remotes; // PR-1 (#3459) 일관
        try worker_linker.link();
        try worker_linker.finalize(.{
            .compute_renames = true,
            .compute_mangling = self.options.minify_identifiers,
        });
        defer worker_linker.deinit();

        // emit
        var emit_opts = self.makeEmitOptions();
        emit_opts.format = format;
        const worker_result = try emitter.emitWithTreeShaking(
            arena_alloc,
            &worker_graph,
            &emit_opts,
            &worker_linker,
            null,
        );
        const worker_output = worker_result.output;

        // content hash로 파일명 생성
        const hash = std.hash.Crc32.hash(worker_output);
        const basename = std.fs.path.stem(std.fs.path.basename(worker_path));
        const filename = try std.fmt.allocPrint(self.allocator, "{s}-{x:0>8}{s}", .{ basename, hash, workerExtension(format) });
        const contents = try self.allocator.dupe(u8, worker_output);

        return .{ .filename = filename, .contents = contents };
    }

    /// 번들 파이프라인 실행: resolve → graph → emit.
    pub fn bundle(self: *Bundler) !BundleResult {
        const profile = @import("../profile.zig");

        var t_graph: u64 = 0;
        var t_link: u64 = 0;
        var t_shake: u64 = 0;
        var t_emit: u64 = 0;

        // Plugin lifecycle (#2156): buildStart 즉시, buildEnd 는 정상 path 끝 또는 errdefer.
        // closeBundle 은 NAPI 경유 시 JS layer (writeOutputFiles 후) 가 dispatch — Rollup
        // 의미 ("write 완료 후") 보존. native Plugin 의 closeBundle 만 여기서 호출.
        // watch 모드 (incremental) 는 매 rebuild 마다 bundle() 재호출 → 자연스럽게 매번 dispatch.
        // errdefer 를 buildStart 호출 *전* 에 등록 — buildStart 가 throw 해도 cleanup 경로 실행.
        const lifecycle_runner = plugin_mod.PluginRunner.init(self.options.plugins);
        // catastrophic error path — build_error 추출 불가하므로 null 전달.
        errdefer {
            lifecycle_runner.runBuildEnd(null);
            lifecycle_runner.runCloseBundle();
        }
        var build_start_ctx: plugin_mod.HookContext = .{};
        defer build_start_ctx.deinit();
        try lifecycle_runner.runBuildStart(&build_start_ctx);

        // 타이머는 항상 동작 (watch 관측성용 — HMR phaseDurations 에 노출).
        // 추가로 `profile` 모듈 activation 시 같은 구간에 .graph/.link/.shake/.emit scope 가 기록된다.
        var timer: ?std.time.Timer = std.time.Timer.start() catch null;

        // 0. RN dev mode: InitializeCore prelude 자동 주입.
        // InitializeCore → setUpReactRefresh에서 injectIntoGlobalHook을 호출한다.
        // __ReactRefresh 글로벌은 HMR 런타임의 __zntc_resolveRefresh()가
        // $RefreshReg$ 첫 호출 시 lazy하게 require("react-refresh/runtime")으로 설정.
        const original_rbm = self.options.run_before_main;
        defer {
            if (self.options.run_before_main.ptr != original_rbm.ptr) {
                self.allocator.free(self.options.run_before_main);
                self.options.run_before_main = original_rbm;
            }
        }
        var auto_init_core_path: ?[]const u8 = null;
        defer if (auto_init_core_path) |p| self.allocator.free(p);

        if (self.options.dev_mode and self.options.react_refresh and
            self.options.platform == .react_native)
        {
            const entry_dir = if (self.options.entry_points.len > 0)
                std.fs.path.dirname(self.options.entry_points[0]) orelse "."
            else
                ".";
            const init_core_rel = "node_modules/react-native/Libraries/Core/InitializeCore.js";

            auto_init_core_path = blk: {
                const full = std.fs.path.join(self.allocator, &.{ entry_dir, init_core_rel }) catch break :blk null;
                // preserve_symlinks=true 에서는 runBeforeMain 도 Metro-style logical path 를
                // 써야 한다. 여기서 realpath 로 주입하면 entry/import 경로의 logical
                // react-native 와 별도 module id 가 되어 InitializeCore 가 중복 실행된다.
                if (self.options.preserve_symlinks) {
                    if (fs.statFile(full)) |stat| {
                        if (stat.kind == .file) break :blk full;
                    } else |_| {}
                }
                // 기본 경로는 fs.realpath 통과 (#1885: VirtualFS 호환).
                if (fs.realpath(self.allocator, full)) |real| {
                    self.allocator.free(full);
                    break :blk real;
                } else |_| {}
                self.allocator.free(full);
                // CWD 기준 탐색
                if (self.options.preserve_symlinks) {
                    if (fs.statFile(init_core_rel)) |stat| {
                        if (stat.kind == .file) {
                            break :blk self.allocator.dupe(u8, init_core_rel) catch break :blk null;
                        }
                    } else |_| {}
                }
                break :blk fs.realpath(self.allocator, init_core_rel) catch null;
            };

            if (auto_init_core_path) |init_path| {
                var already_present = false;
                const init_path_real = fs.realpath(self.allocator, init_path) catch null;
                defer if (init_path_real) |p| self.allocator.free(p);
                for (self.options.run_before_main) |rbm| {
                    if (std.mem.eql(u8, rbm, init_path)) {
                        already_present = true;
                        break;
                    }
                    if (init_path_real) |real| {
                        const rbm_real = fs.realpath(self.allocator, rbm) catch null;
                        defer if (rbm_real) |p| self.allocator.free(p);
                        if (rbm_real) |p| {
                            if (std.mem.eql(u8, p, real)) {
                                already_present = true;
                                break;
                            }
                        }
                    }
                }
                if (!already_present) {
                    const new_rbm = try self.allocator.alloc([]const u8, self.options.run_before_main.len + 1);
                    // InitializeCore를 맨 앞에 배치 (다른 run_before_main보다 먼저 실행)
                    new_rbm[0] = init_path;
                    @memcpy(new_rbm[1..], self.options.run_before_main);
                    self.options.run_before_main = new_rbm;
                }
            }
        }

        // --mangle-report (#1760) property harness. main linker path 에만 연결.
        // mangle_report_enabled=false 여도 storage 는 만들어 두지만 deinit/연결 skip.
        var mangle_collector: MangleReportCollector = .init(self.allocator);
        const mangle_report_enabled = self.options.mangle_report_path != null;
        defer if (mangle_report_enabled) mangle_collector.deinit();

        // PR-2 (#3459): 정적 remote import specifier 수집(metadata.zig 가
        // remote seam 합성 시 append) → emitHostInit async preload-gate.
        var mf_static_remotes: @import("federation.zig").MfStaticRemotes = .{};
        defer mf_static_remotes.deinit(self.allocator);

        // #3318 ④: MF seam 단일 적용점(옵션 레이어가 아닌 번들러 1곳).
        // 소유/수명·watch 불변식은 `mf_eff_external` 필드 doc, 주입이
        // resolve 전이라 안전한 근거는 setExternalPatterns doc 참조.
        // 실패 시 명시 free(잔존 errdefer 0 → 소유권이 필드로 이전된
        // *뒤* bundle() 후속 try 실패해도 이중해제 없음). mf 없으면 미진입.
        if (self.options.mf) |mfb| {
            const mfo = @import("mf_options.zig");
            const se = try mfo.seamExternals(self.allocator, mfb);
            const sx = std.mem.concat(self.allocator, []const u8, &.{ self.options.external, se }) catch |e| {
                self.allocator.free(se);
                return e;
            };
            self.allocator.free(se); // 이후 live = sx
            const sg = mfo.seamGlobals(self.allocator, mfb) catch |e| {
                self.allocator.free(sx);
                return e;
            };
            const gx = std.mem.concat(self.allocator, types.GlobalEntry, &.{ self.options.globals, sg }) catch |e| {
                self.allocator.free(sg);
                self.allocator.free(sx);
                return e;
            };
            self.allocator.free(sg);
            // 소유권을 필드로 이전 — 이후 sx/gx free 는 오직 deinit.
            self.mf_eff_external = sx;
            self.mf_eff_globals = gx;
            self.options.globals = gx; // emit/linker 가 self.options.globals 소비
        }
        // external_patterns 는 매 bundle() **무조건** 재주입(resolve 전):
        // mf 면 combined(sx), 아니면 self.options.external. persistent
        // ResolveCache(watch)가 이전 빌드의 freed sx 를 parking 하지
        // 않게 — mf→non-mf 전환·조기 resolve 에도 dangling 0.
        self.getResolveCache().setExternalPatterns(self.mf_eff_external orelse self.options.external);

        // 1. 모듈 그래프 구축
        var graph_scope = profile.begin(.graph);
        // RFC #3933 Sub-PR-B.2: external_graph 가 있으면 init/deinit skip — caller 보존.
        // 옵션 mirror 는 매 빌드 갱신 (caller 가 빌드 사이 옵션 변경 가능 — idempotent).
        var owned_graph_storage: ModuleGraph = undefined;
        const has_external_graph = self.external_graph != null;
        if (!has_external_graph) {
            owned_graph_storage = ModuleGraph.init(self.allocator, self.getResolveCache());
        }
        const graph: *ModuleGraph = if (self.external_graph) |g| g else &owned_graph_storage;
        // this.emitFile (PR5): plugin 이 emit 한 asset 수집소. graph build 가 plugin hook 을
        // 호출하기 *전* 에 연결해야 한다. emit 된 asset 은 아래에서 OutputFile(kind=.asset)로
        // 복사되어 final_asset_outputs 에 합쳐지고, store 는 scratch 라 bundle() 종료 시 해제.
        var emit_store = EmitStore.init(self.allocator, self.options.asset_names);
        defer emit_store.deinit();
        graph.emit_store = @ptrCast(&emit_store);
        graph.dev_mode = self.options.dev_mode;
        graph.incremental_mode = self.options.module_store != null or
            self.options.changed_files != null or
            self.options.compiled_cache != null;
        graph.inline_dynamic_imports = self.options.inline_dynamic_imports;
        // require.context 등 parser inline scan 의 build-time 정적 평가에 사용 (#1579 Phase 2.6)
        graph.defines = self.options.define;
        // #1961 PR 1f: minify_whitespace 는 graph.transform_options_base 에서 단일 source.
        // (#1621: binary loader 의 `$tb(...)` 축약 등 graph 자체 사용처도 base 에서 read)
        graph.loader_overrides = self.options.loader_overrides;
        graph.public_path = self.options.public_path;
        graph.project_root = self.options.project_root;
        graph.asset_names = self.options.asset_names;
        graph.asset_registry = self.options.asset_registry;
        graph.inject_files = self.options.inject;
        graph.run_before_main_files = self.options.run_before_main;
        graph.runtime_polyfills = self.options.runtime_polyfills;
        graph.pure = self.options.pure;
        graph.ignore_annotations = self.options.ignore_annotations;
        graph.plugins = self.options.plugins;
        graph.max_threads = self.options.max_threads;
        graph.flow = self.options.flow;
        graph.jsx_in_js = self.options.jsx_in_js;
        graph.jsx_runtime = self.options.jsx_runtime;
        graph.jsx_import_source = self.options.jsx_import_source;

        // #1961: transformer pre-pass 옵션 — graph 와 emitter 가 동일한 base 사용
        // (drift hot spot 단일화). graph 가 직접 사용하는 일부 (worklet_transform /
        // react_refresh / code_splitting) 만 별도 mirror.
        graph.worklet_transform = self.options.worklet_transform;
        graph.codegen_transform = self.options.codegen_transform;
        graph.react_refresh = self.options.react_refresh;
        graph.styled_components = self.options.styled_components;
        graph.styled_components_ssr = self.options.styled_components_ssr;
        graph.styled_components_minify = self.options.styled_components_minify;
        graph.styled_components_file_name = self.options.styled_components_file_name;
        graph.styled_components_pure = self.options.styled_components_pure;
        graph.styled_components_namespace = self.options.styled_components_namespace;
        graph.styled_components_meaningless_file_names = self.options.styled_components_meaningless_file_names;
        graph.styled_components_top_level_import_paths = self.options.styled_components_top_level_import_paths;
        graph.styled_components_css_prop = self.options.styled_components_css_prop;
        graph.emotion = self.options.emotion;
        graph.emotion_auto_label = self.options.emotion_auto_label;
        graph.emotion_source_map = self.options.emotion_source_map;
        graph.emotion_label_format = self.options.emotion_label_format;
        graph.emotion_extra_css_sources = self.options.emotion_extra_css_sources;
        graph.emotion_extra_styled_sources = self.options.emotion_extra_styled_sources;
        graph.code_splitting = self.options.code_splitting;
        graph.preserve_modules = self.options.preserve_modules;
        graph.minify_identifiers = self.options.minify_identifiers;
        graph.transform_options_base = self.buildTransformOptionsBase();
        // RFC #3933 Sub-PR-B.2: external_graph 면 deinit skip (caller 보존).
        defer if (!has_external_graph) graph.deinit();

        // graph.build() 또는 buildIncremental() 호출.
        // reparsed_count: 증분 경로(=store 전달)일 때만 set — null은 전체 파싱을 의미.
        // reparsed_paths_out: 재파싱된 모듈의 경로 (self.allocator 소유).
        //   HMR 페이로드 필터링용 — cache-hit 모듈은 canonical-name 비결정성으로
        //   rebuild 간 emit 이 달라져도 HMR update 에서 제외.
        var reparsed_count: ?usize = null;
        var reparsed_paths_out: ?[]const []const u8 = null;
        {
            var gb_scope = profile.begin(.graph_build);
            defer gb_scope.end();
            if (self.options.module_store) |store| {
                const inc_result = try graph.buildIncremental(self.options.entry_points, store, self.options.changed_files);
                reparsed_count = inc_result.reparsed_indices.len;
                if (inc_result.reparsed_indices.len > 0) {
                    const list = try self.allocator.alloc([]const u8, inc_result.reparsed_indices.len);
                    for (inc_result.reparsed_indices, 0..) |mod_idx, i| {
                        // HMR diff 의 source-of-truth — emit 의 `ModuleDevCode.id` (=
                        // `makeModuleId(m.path, root_dir)`) 와 동일 형식으로 채워야 napi_entry
                        // 의 `reparsed_set.contains(dc.id)` 필터가 매칭된다. root_dir 옵션이
                        // 적용된 후엔 절대 경로 (`m.path`) 와 module ID (`dc.id`) 가 달라져
                        // 모든 update 가 silent drop → "no code change" 로 관측됨.
                        const src = if (graph.getModule(mod_idx)) |m|
                            emitter.makeModuleId(m.path, self.options.root_dir)
                        else
                            "";
                        list[i] = try self.allocator.dupe(u8, src);
                    }
                    reparsed_paths_out = list;
                }
                self.allocator.free(inc_result.reparsed_indices);
            } else if (if (self.options.mf) |*mf| mf.exposes.len > 0 else false) {
                // P1-3: exposes 있는 remote → exposes 를 그래프 루트에 합류
                // (독립 루트). chunk gen entry_points 는 불변(exposes 는
                // 동적 lazy 청크로만). host(exposes 없음)는 경로 불변.
                const fed = @import("federation.zig");
                const mf = &self.options.mf.?;
                const be = try fed.entryWithExposes(self.allocator, mf, self.options.entry_points);
                defer fed.freeStrList(self.allocator, be);
                try graph.build(be);
            } else {
                try graph.build(self.options.entry_points);
            }
        }

        // Module Federation 연합 경계 식별 (#3318 P1-1). mf!=null 일 때만 —
        // 비-MF 빌드 영향 0. 표시·안정 ID 만(분석); wrap_kind/출력 불변.
        if (self.options.mf) |*mf| {
            const fed = @import("federation.zig");
            try fed.markBoundary(
                graph,
                mf,
                self.allocator,
                self.options.entry_points,
                self.options.preserve_modules_root,
            );
            // P3-4 (#3439): 소유권 경계 린트 — 경계 모듈이 host-owned
            // store/Provider 자체 생성 시 비-차단 경고. markBoundary 직후
            // (경계 플래그 완료, 동일 graph 순회). 빌드 영향 0(경고만).
            fed.lintOwnershipBoundary(graph);
        }

        if (graph.runtime_polyfill_roots.items.len > 0) {
            const current_rbm = self.options.run_before_main;
            const merged = try self.allocator.alloc([]const u8, graph.runtime_polyfill_roots.items.len + current_rbm.len);
            @memcpy(merged[0..graph.runtime_polyfill_roots.items.len], graph.runtime_polyfill_roots.items);
            @memcpy(merged[graph.runtime_polyfill_roots.items.len..], current_rbm);
            if (current_rbm.len > 0 and current_rbm.ptr != original_rbm.ptr) {
                self.allocator.free(current_rbm);
            }
            self.options.run_before_main = merged;
        }

        // Worker 별도 빌드: new Worker(new URL(...)) 패턴에서 수집된 worker 경로를 독립 IIFE로 빌드
        var worker_output_map = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = worker_output_map.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
            worker_output_map.deinit();
        }
        var worker_output_files: std.ArrayList(OutputFile) = .empty;
        defer worker_output_files.deinit(self.allocator);

        // codegen.emitNew lookup 용 per-module map. outer key = module 절대 경로 (graph 소유),
        // inner key = import_record specifier (graph 소유), value = worker chunk filename
        // (worker_output_map 소유). 본 map 은 reference 만 보관 — deinit 시 inner 만 정리.
        var worker_map_per_module = std.StringHashMap(std.StringHashMap([]const u8)).init(self.allocator);
        defer {
            var oit = worker_map_per_module.valueIterator();
            while (oit.next()) |inner| inner.deinit();
            worker_map_per_module.deinit();
        }

        {
            var gw_scope = profile.begin(.graph_worker);
            defer gw_scope.end();
            for (graph.worker_entries.items) |we| {
                // 같은 worker 파일이 여러 곳에서 참조되면 한 번만 빌드
                if (!worker_output_map.contains(we.resolved_path)) {
                    const worker_result = self.buildWorker(we.resolved_path) catch {
                        continue;
                    };
                    try worker_output_map.put(we.resolved_path, worker_result.filename);
                    try worker_output_files.append(self.allocator, .{
                        .path = try self.allocator.dupe(u8, worker_result.filename),
                        .contents = worker_result.contents,
                    });
                }

                const filename = worker_output_map.get(we.resolved_path) orelse continue;
                const mod = graph.getModule(we.source_module) orelse continue;
                if (we.record_index >= mod.import_records.len) continue;
                const spec = mod.import_records[we.record_index].specifier;

                const entry = try worker_map_per_module.getOrPut(mod.path);
                if (!entry.found_existing) entry.value_ptr.* = std.StringHashMap([]const u8).init(self.allocator);
                try entry.value_ptr.put(spec, filename);
            }
        }

        if (timer) |*t| {
            t_graph = t.read();
            t.reset();
        }
        graph_scope.end();

        // ZNTC_DEBUG=module_stats → 모듈 분류 히스토그램 (docs/DEBUG.md §1).
        if (@import("../debug_log.zig").enabled(.module_stats)) dumpModuleStats(graph);

        // 2. 링킹 (scope hoisting)
        // code_splitting=true일 때는 글로벌 computeRenames를 건너뛴다.
        // 각 청크가 독립된 네임스페이스이므로 emitChunks에서 per-chunk로 처리.
        // tree-shaking 이 돌면 mangling 은 tree-shake 이후로 미룬다 — dead 모듈의
        // binding 이 짧은 이름 풀(54자)을 잠식해 candidate-emit 비율이 떨어지는
        // 회귀 방지. TreeShaker 생성 조건과 동일 predicate.
        const will_tree_shake = !self.options.dev_mode and self.options.scope_hoist and self.options.tree_shaking;
        var link_scope = profile.begin(.link);
        var linker: ?Linker = if (self.options.scope_hoist or self.options.dev_mode) blk: {
            var l = Linker.initWithGlobalIdentifiers(self.allocator, graph, self.options.format, self.options.global_identifiers);
            // Metro+Babel은 named import를 CommonJS property access로 낮추므로, export가
            // 실제로 없어도 런타임 값은 ReferenceError가 아니라 undefined가 된다.
            l.shim_missing_exports = self.options.shim_missing_exports or self.options.platform == .react_native;
            l.dev_mode = self.options.dev_mode;
            l.entry_error_guard = self.options.entry_error_guard;
            l.inline_requires = self.options.platform == .react_native;
            l.strict_execution_order = self.options.strict_execution_order;
            // #1621: preamble/metadata 가 __toESM/__toCommonJS 를 축약 이름으로 emit.
            l.minify_whitespace = self.options.minify_whitespace;
            l.configurable_exports = self.options.configurable_exports;
            // #1791 Phase D: value-ref 0 binding elision 정책을 transformer 와 동기화.
            l.verbatim_module_syntax = self.options.verbatim_module_syntax;
            // per-emit format-dependent state — setter 일원화로 emit 루프에서 매 format 마다 재호출 가능.
            const mf_opt = self.options.mf;
            l.setEmitFormat(self.options.format, .{
                .iife_globals = self.options.globals,
                .mf_remotes = if (mf_opt) |*m| m.remotes else &.{},
                .mf_static_remotes = if (mf_opt) |_| &mf_static_remotes else null,
                .inline_requires = self.options.platform == .react_native,
                .entry_error_guard = self.options.entry_error_guard,
            });
            if (mangle_report_enabled) l.mangle_report = &mangle_collector;
            try l.link();
            // Phase 3b (#1328): populateReExportAliases 가 canonical_name 을 채우려면
            // computeRenames 이후여야 한다. populateImportSymbols / NamespaceAccesses /
            // SymbolRefCounts (tree-shaking companion metric) 까지 한 번에 묶어 emit.
            try l.finalize(.{
                .compute_renames = !self.options.code_splitting,
                .compute_mangling = self.options.minify_identifiers and !will_tree_shake,
            });
            break :blk l;
        } else null;
        defer if (linker) |*l| l.deinit();

        if (timer) |*t| {
            t_link = t.read();
            t.reset();
        }
        link_scope.end();

        // 2.5. Tree-shaking (scope_hoist + tree_shaking 둘 다 켜져 있을 때)
        // dev_mode에서는 tree-shaking 스킵 (개발 중 모든 코드 필요)
        var shake_scope = profile.begin(.shake);
        var shaker: ?TreeShaker = if (will_tree_shake) blk: {
            var s = blk_init: {
                var init_scope = profile.begin(.shake_init);
                defer init_scope.end();
                break :blk_init try TreeShaker.init(self.allocator, graph, &(linker.?));
            };
            {
                var analyze_scope = profile.begin(.shake_analyze);
                defer analyze_scope.end();
                try s.analyze(self.options.entry_points);
            }
            // metadata builder + collectUnifiedInput 가 `Module.is_included` 를 신뢰해
            // tree-shake 된 모듈의 preamble emit + mangle candidate 를 건너뛸 수 있도록
            // plug. post-shake finalize 보다 먼저 켜 두어야 collectUnifiedInput 가드가
            // 활성화된다.
            if (linker) |*l| l.tree_shaker_active = true;

            // ast mutation 이 있었거나 mangle 을 일부러 미뤘던 경우 (will_tree_shake)
            // tree-shake 결과 (`is_included`) 를 반영해 한 번만 mangle 한다.
            const need_post_shake_finalize = !self.options.code_splitting and
                (s.ast_mutated_after_link or will_tree_shake);
            if (need_post_shake_finalize) {
                var post_link_scope = profile.begin(.shake_post_link_finalize);
                defer post_link_scope.end();
                if (self.options.minify_identifiers) {
                    // Mangling ranks depend on fresh semantic symbol IDs and ref counts.
                    try (&(linker.?)).finalize(.{
                        .compute_renames = true,
                        .compute_mangling = true,
                        .clear_first = true,
                        .populate_namespace_accesses = false,
                    });
                } else if (s.ast_mutated_after_link) {
                    // Tree-shake constant folding only removes/replaces references. Graph
                    // resync preserves existing canonical names, so emit only needs import
                    // and re-export metadata refreshed for the final AST snapshot.
                    const l = &(linker.?);
                    l.populateReExportAliases();
                    l.populateImportSymbols();
                }
            }
            break :blk s;
        } else null;
        // tree_shaker pointer 를 linker 로 전달 — namespace force_inline 결정 (3 caller
        // in metadata.zig) 이 `isExportUsed` 로 transitively used 검사. unused
        // namespace re-export 의 X_ns inline literal 생성 skip.
        // clear defer 가 LIFO 로 shaker.deinit 보다 먼저 실행돼 dangling 방지.
        defer if (linker) |*l| {
            l.tree_shaker = null;
        };
        defer if (shaker) |*s| s.deinit();
        if (linker) |*l| if (shaker) |*s| {
            l.tree_shaker = s;
        };

        if (timer) |*t| {
            t_shake = t.read();
            t.reset();
        }
        shake_scope.end();

        var emit_scope = profile.begin(.emit);
        defer emit_scope.end();

        // 2.7. 폴리필 파일 내용 로딩 (--polyfill)
        var polyfill_entries: std.ArrayList(EmitOptions.PolyfillEntry) = .empty;
        defer {
            for (polyfill_entries.items) |e| {
                self.allocator.free(e.content);
                if (e.path) |p| self.allocator.free(p);
            }
            polyfill_entries.deinit(self.allocator);
        }
        var polyfill_scope = profile.begin(.emit_polyfill);
        for (self.options.polyfills) |poly_path| {
            const raw = std.fs.cwd().readFileAlloc(self.allocator, poly_path, 10 * 1024 * 1024) catch |err| {
                std.log.err("zntc: cannot read polyfill file '{s}': {}", .{ poly_path, err });
                continue;
            };
            const basename = std.fs.path.basename(poly_path);
            // 폴리필은 모듈 그래프를 우회해 여기서 직접 읽어 prepend 된다. Flow strip 과
            // (minify 빌드 시) whitespace minify 를 transpile 1회로 처리한다. 그렇지 않으면
            // 폴리필 원본 주석/들여쓰기/줄바꿈이 minify 번들에 그대로 남는다 (#3649).
            //
            // RN console.js 는 @noflow 이며 DevTools console callsite 의 기준 파일이다.
            // 변환하면 originalConsole bridge 의 generated line 이 원본 line 과 어긋나
            // `console.js:<generated>` 로 노출되므로, dev(비-minify) 에선 raw 로 둔다.
            // minify 빌드에선 sourcemap 자체가 단일 line 으로 minify 되어 callsite 보존
            // 의미가 없으므로 console.js 도 transpile 을 허용한다.
            // identifiers/syntax minify 는 폴리필 global 등록 안전성 때문에 제외 — whitespace 만.
            const minify_ws = self.options.minify_whitespace;
            const is_console = std.mem.eql(u8, basename, "console.js");
            const should_transpile = (self.options.flow or minify_ws) and (!is_console or minify_ws);
            const content = if (should_transpile) blk: {
                var result = transpile_mod.transpile(self.allocator, raw, poly_path, .{
                    .flow = self.options.flow,
                    .jsx_in_js = self.options.jsx_in_js,
                    // 폴리필도 verbatim 규칙을 따라야 함 — 그래야 번들 본체와 동일한 import 처리 정책.
                    .verbatim_module_syntax = self.options.verbatim_module_syntax,
                    .minify_whitespace = minify_ws,
                }) catch |err| {
                    // 트랜스파일 실패 시 원본 사용 — 단 진단 없이 조용히 넘어가면 minify 번들에
                    // 원본 주석/들여쓰기가 다시 새는 것을 알아챌 수 없으므로 경고를 남긴다(#3649 후속).
                    std.log.warn("zntc: polyfill '{s}' 트랜스파일 실패 ({s}), 원본 사용", .{ poly_path, @errorName(err) });
                    // raw 는 codegen 종결자(`;`) 보장이 없다. trailing newline 이 없으면 emitter 의
                    // minify IIFE wrap (`...content})();`) 에서 content 마지막 줄 주석/미종결 식이
                    // `})()` 를 같은 줄로 삼켜 SyntaxError 가 날 수 있어 개행을 보장한다.
                    if (raw.len > 0 and raw[raw.len - 1] != '\n') {
                        const padded = std.mem.concat(self.allocator, u8, &.{ raw, "\n" }) catch break :blk raw;
                        self.allocator.free(raw);
                        break :blk padded;
                    }
                    break :blk raw;
                };
                self.allocator.free(raw);
                // result.code 를 content 로 인계. TranspileResult.deinit 은 code 까지 free 하므로
                // code 를 복사해 content 로 쓰고 result 전체를 deinit 한다 — sourcemap/diagnostics/
                // line_offsets 누수 방지(#3649 후속). 직접 필드 free 는 누락 위험이 있어 deinit 에 일임.
                const code = self.allocator.dupe(u8, result.code) catch break :blk result.code;
                result.deinit(self.allocator);
                break :blk code;
            } else raw;
            try polyfill_entries.append(self.allocator, .{
                .name = basename,
                .content = content,
                .path = try self.allocator.dupe(u8, poly_path),
            });
        }
        polyfill_scope.end();

        // 2.8. React Refresh 런타임 주입 (dev mode, 브라우저만)
        var refresh_scope = profile.begin(.emit_refresh);
        // RN: HMR 런타임의 __zntc_resolveRefresh()가 모듈 컨텍스트에서 lazy하게
        //      require("react-refresh/runtime")을 호출하여 __ReactRefresh 글로벌에 캐싱.
        //      polyfill 불필요 (polyfill 시점에는 모듈 시스템 미초기화).
        // 브라우저: react-refresh/runtime을 파일에서 읽어 polyfill로 주입.
        if (self.options.dev_mode and self.options.react_refresh and
            self.options.platform != .react_native)
        blk: {
            const entry_dir = if (self.options.entry_points.len > 0)
                std.fs.path.dirname(self.options.entry_points[0]) orelse "."
            else
                ".";
            const dev_path = "node_modules/react-refresh/cjs/react-refresh-runtime.development.js";
            const raw = blk2: {
                const full_path = std.fs.path.join(self.allocator, &.{ entry_dir, dev_path }) catch break :blk;
                defer self.allocator.free(full_path);
                // fs.realpath / fs.readFile 통과 → wasm VirtualFS 호환 (#1885 Phase 2).
                if (fs.realpath(self.allocator, full_path)) |real| {
                    defer self.allocator.free(real);
                    if (fs.readFile(self.allocator, real, 1024 * 1024)) |r| break :blk2 r.contents else |_| {}
                } else |_| {}
                if (fs.realpath(self.allocator, dev_path)) |real| {
                    defer self.allocator.free(real);
                    if (fs.readFile(self.allocator, real, 1024 * 1024)) |r| break :blk2 r.contents else |_| {}
                } else |_| {}
                std.log.warn("zntc: react-refresh not found — install react-refresh for HMR", .{});
                break :blk;
            };
            const preamble =
                "(function(){" ++
                "var exports = {};" ++
                "var module = { exports: exports };" ++
                "var process = { env: { NODE_ENV: \"development\" } };\n";
            const epilogue =
                "\nvar __r = module.exports;" ++
                "var __g = typeof globalThis !== \"undefined\" ? globalThis : typeof global !== \"undefined\" ? global : window;" ++
                "__g.__ReactRefresh = __r;" ++
                "__g.__REACT_REFRESH_RUNTIME__ = __r;" ++
                "if (__r.injectIntoGlobalHook) __r.injectIntoGlobalHook(__g);" ++
                "})();\n";
            const wrapped = std.mem.concat(self.allocator, u8, &.{ preamble, raw, epilogue }) catch break :blk;
            self.allocator.free(raw);
            try polyfill_entries.append(self.allocator, .{
                .name = "react-refresh-runtime",
                .content = wrapped,
            });
        }

        refresh_scope.end();

        // 3. 번들 출력 생성
        var output_scope = profile.begin(.emit_output);
        var output: []const u8 = "";
        var outputs: ?[]OutputFile = null;
        var outputs_by_format: ?[]types.FormatOutput = null;
        errdefer if (outputs_by_format) |by| {
            for (by) |fo| {
                self.allocator.free(fo.output);
                if (fo.sourcemap) |sm| self.allocator.free(sm);
            }
            self.allocator.free(by);
        };

        // multi-format emit: single 경로만 본 단계에서 지원. dev/splitting 와 조합은 후속.
        const multi_format = self.options.output.len > 1;
        if (multi_format) {
            if (self.options.dev_mode or self.options.code_splitting or self.options.preserve_modules) {
                return error.MultiFormatRequiresSinglePath;
            }
            // Module Federation 은 federation_emit.wrapContainer 가 splitting 경로 전용이라
            // single multi-emit 에서 host/remote container 가 누락 (사일런트 깨짐). MF host 는
            // 단일 IIFE/UMD/AMD 출력 한정.
            if (self.options.mf != null) {
                return error.MultiFormatNotSupportedWithModuleFederation;
            }
        }
        // #3318 P1-5: MF remote 의 mf-manifest.json (wrapContainer 산출,
        // asset_outputs 로 편입). errdefer 로 부분실패 누수 방지.
        var mf_manifest: ?[]const u8 = null;
        errdefer if (mf_manifest) |m| self.allocator.free(m);
        // code splitting 경로에서 청크별로 분리 emit 한 CSS (null = 비-splitting,
        // 이 경우 아래에서 entry 당 단일 CSS 로 fallback). 소비 후 null 로 되돌린다.
        var css_chunk_files: ?[]OutputFile = null;
        errdefer if (css_chunk_files) |f| {
            for (f) |o| {
                self.allocator.free(o.path);
                self.allocator.free(o.contents);
            }
            self.allocator.free(f);
        };

        // dev mode용 per-module codes + sourcemap
        var module_dev_codes_from_emit: ?[]const types.ModuleDevCode = null;
        var dev_sourcemap: ?[]const u8 = null;
        // Lazy sourcemap builder (Issue #1727) — emit 단계에서 JSON 생성을 skip 하고 builder 를
        // BundleResult 로 이관. NAPI handle 이 캐시하고 `/bundle.js.map` 요청 시 직렬화.
        var dev_sourcemap_builder: ?*@import("../codegen/sourcemap.zig").SourceMapBuilder = null;

        if (self.options.dev_mode) {
            // Dev mode: 프로덕션 파이프라인 재사용 (__commonJS/__esm 래핑 + HMR 런타임).
            var dev_emit_opts = self.makeEmitOptions();
            dev_emit_opts.sourcemap.enable = true;
            dev_emit_opts.dev_mode = true;
            dev_emit_opts.react_refresh = self.options.react_refresh;
            dev_emit_opts.collect_module_codes = self.options.collect_module_codes;
            dev_emit_opts.skip_bundle_output = self.options.skip_bundle_output;
            dev_emit_opts.polyfills = polyfill_entries.items;
            dev_emit_opts.run_before_main = self.options.run_before_main;
            dev_emit_opts.worker_map_per_module = &worker_map_per_module;

            const la = graph.linkAccessor();
            for (0..graph.moduleCount()) |i| {
                const idx = ModuleIndex.fromUsize(i);
                const m = graph.getModule(idx) orelse continue;
                la.setDevId(idx, emitter.makeModuleId(m.path, self.options.root_dir));
            }

            const emit_result = try emitter.emitWithTreeShaking(
                self.allocator,
                graph,
                &dev_emit_opts,
                if (linker) |*l| l else null,
                null, // dev mode: tree-shaking 비활성
            );
            output = emit_result.output;
            module_dev_codes_from_emit = emit_result.module_codes;
            dev_sourcemap = emit_result.sourcemap;
            dev_sourcemap_builder = emit_result.sourcemap_builder;
        } else if (self.options.code_splitting or self.options.preserve_modules) {
            // Code splitting / preserve-modules 경로: 청크 그래프 생성 → 다중 파일 출력
            var chunk_graph = if (self.options.preserve_modules)
                try chunk_mod.generatePreserveModulesChunks(
                    self.allocator,
                    graph,
                    self.options.entry_points,
                    if (shaker) |*s| s else null,
                )
            else
                try chunk_mod.generateChunks(self.allocator, graph, self.options.entry_points, .{
                    .shaker = if (shaker) |*s| s else null,
                    .manual_chunks = self.options.manual_chunks,
                    .manual_resolver = self.options.manual_chunks_resolver,
                    .manual_resolver_ctx = self.options.manual_chunks_ctx,
                    .inline_dynamic_imports = self.options.inline_dynamic_imports,
                });
            defer chunk_graph.deinit();

            // 작은 common 청크 병합 (Rollup experimentalMinChunkSize 류).
            // computeCrossChunkLinks *전* — cross-chunk import 가 병합 후 기준 재계산.
            if (!self.options.preserve_modules and self.options.min_chunk_size > 0) {
                chunk_mod.mergeSmallChunks(&chunk_graph, graph, self.options.min_chunk_size);
            }

            try chunk_mod.computeCrossChunkLinks(&chunk_graph, graph, self.allocator, if (linker) |*l| l else null);

            var emit_opts = self.makeEmitOptions();
            emit_opts.preserve_modules = self.options.preserve_modules;
            emit_opts.preserve_modules_root = self.options.preserve_modules_root;
            emit_opts.worker_map_per_module = &worker_map_per_module;

            // CSS 코드스플리팅 계획을 emitChunks *전* 에 세워, 동적 청크가
            // 자기 CSS 를 런타임 <link> 로 로드하는 prologue 를 content-hash
            // 계산 전에 주입한다(JS 청크 해시 무결성). CSS 실패는 번들 실패로
            // 번지지 않게 흡수(기존 css emit 의 관용과 동일).
            const css_emit = @import("css_emitter.zig");
            var css_plan: ?[]css_emit.CssChunkPlanEntry = null;
            errdefer if (css_plan) |p| {
                for (p) |e| {
                    self.allocator.free(e.path);
                    self.allocator.free(e.contents);
                }
                self.allocator.free(p);
            };
            var css_hrefs: ?[]?[]const u8 = null;
            errdefer if (css_hrefs) |h| self.allocator.free(h);
            if (!self.options.preserve_modules) {
                css_plan = css_emit.planCssChunks(self.allocator, graph, &chunk_graph, self.options.css_names) catch null;
                if (css_plan) |p| {
                    css_hrefs = css_emit.planChunkHrefs(self.allocator, p, chunk_graph.chunkCount()) catch null;
                    emit_opts.chunk_css_hrefs = css_hrefs;
                }
            }

            outputs = try emitter.emitChunks(
                self.allocator,
                graph,
                &chunk_graph,
                &emit_opts,
                if (linker) |*l| l else null,
            );
            errdefer if (outputs) |outs| {
                for (outs) |o| {
                    self.allocator.free(o.path);
                    self.allocator.free(o.contents);
                }
                self.allocator.free(outs);
            };

            // P1-3 (#3385): MF container emit — entry 청크 부트스트랩을
            // webpack-style container(init/get, globalName 대입)로 후처리
            // wrap. 게이트는 markBoundary(graph.build 후)와 동일 관례.
            if (self.options.mf) |*mf|
                // #3468: chunk_graph + css_hrefs(planChunkHrefs, 위에서
                // 계산) 전달 → expose CSS 산출을 manifest assets.css 게시.
                mf_manifest = try @import("federation_emit.zig").wrapContainer(self.allocator, outputs.?, mf, graph, &chunk_graph, css_hrefs, self.options.public_path);

            // emitChunks 가 href 를 청크 내용으로 복사 완료 → 이제 plan 의
            // path/contents 소유권을 OutputFile 로 이전(plan 컨테이너만 해제).
            if (css_plan) |p| {
                css_chunk_files = css_emit.planToOutputFiles(self.allocator, p) catch null;
                self.allocator.free(p);
                css_plan = null;
            }
            if (css_hrefs) |h| {
                self.allocator.free(h);
                css_hrefs = null;
            }

            // output은 빈 문자열 — code splitting 시 outputs를 사용
            output = try self.allocator.dupe(u8, "");
        } else if (multi_format) {
            // Multi-format single-path emit. 매 OutputConfig 마다 linker setEmitFormat 으로
            // format-dependent state 갱신, emit 결과 누적. 첫 entry 의 결과를 `output` /
            // `dev_sourcemap` 에 alias 로 노출 (backward-compat).
            //
            // 산출물 정책 (PR-H):
            //   - bundle.js 본문 = format 별 (outputs_by_format[*].output)
            //   - CSS / worker / asset = graph 기반이라 *format 무관, 공유*. result.asset_outputs
            //     가 모든 OutputConfig 와 공유 (한 번만 emit). 사용자가 per-format CSS 원하면
            //     build() 를 두 번 호출.
            //   - mf_manifest = MF + multi-format 거부 (위 validation) 라 항상 null.
            const by = try self.allocator.alloc(types.FormatOutput, self.options.output.len);
            errdefer self.allocator.free(by);
            const mf_opt2 = self.options.mf;
            var filled: usize = 0;
            errdefer {
                var k: usize = 0;
                while (k < filled) : (k += 1) {
                    if (by[k].output.len > 0) self.allocator.free(by[k].output);
                    if (by[k].sourcemap) |sm| self.allocator.free(sm);
                }
            }
            for (self.options.output, 0..) |cfg, i| {
                if (linker) |*l| {
                    l.setEmitFormat(cfg.format, .{
                        .iife_globals = cfg.globals,
                        .mf_remotes = if (mf_opt2) |*m| m.remotes else &.{},
                        .mf_static_remotes = if (mf_opt2) |_| &mf_static_remotes else null,
                        .inline_requires = self.options.platform == .react_native,
                        .entry_error_guard = self.options.entry_error_guard,
                    });
                    l.resetEmitTransients();
                }
                var emit_opts = self.makeEmitOptions();
                emit_opts.format = cfg.format;
                emit_opts.polyfills = polyfill_entries.items;
                emit_opts.worker_map_per_module = &worker_map_per_module;
                if (self.options.sourcemap.enable) emit_opts.sourcemap.enable = true;
                const emit_result = try emitter.emitWithTreeShaking(
                    self.allocator,
                    graph,
                    &emit_opts,
                    if (linker) |*l| l else null,
                    if (shaker) |*s| s else null,
                );
                by[i] = .{
                    .format = cfg.format,
                    .output = emit_result.output,
                    .sourcemap = emit_result.sourcemap,
                };
                filled = i + 1;
            }
            // 첫 entry 의 output/sourcemap 을 result.output / dev_sourcemap 으로 *move* — 동일
            // 메모리 중복 alloc 회피. by[0] 의 슬라이스는 빈 슬라이스로 marker, deinit 의 가드가
            // 빈 슬라이스 free 를 skip. outputs_by_format = by 는 *마지막* statement 로 두어
            // 이후 try 가 없음을 보장 — outer errdefer 가 double-free 트리거하지 않음.
            output = by[0].output;
            by[0].output = &.{};
            if (by[0].sourcemap) |sm| {
                dev_sourcemap = sm;
                by[0].sourcemap = null;
            }
            outputs_by_format = by;
        } else {
            // 단일 파일 경로 (tree shaking + 소스맵 지원)
            var emit_opts = self.makeEmitOptions();
            emit_opts.polyfills = polyfill_entries.items;
            emit_opts.worker_map_per_module = &worker_map_per_module;
            if (self.options.sourcemap.enable) emit_opts.sourcemap.enable = true;
            const emit_result = try emitter.emitWithTreeShaking(
                self.allocator,
                graph,
                &emit_opts,
                if (linker) |*l| l else null,
                if (shaker) |*s| s else null,
            );
            output = emit_result.output;
            dev_sourcemap = emit_result.sourcemap;
            dev_sourcemap_builder = emit_result.sourcemap_builder;
        }
        errdefer self.allocator.free(output);

        if (timer) |*t| {
            t_emit = t.read();
        }

        output_scope.end();

        // 파이프라인 단계별 타이밍 출력은 `--profile` 을 통해 `profile` 모듈이 담당.
        // 이 `t_graph/t_link/t_shake/t_emit` 은 `BundleResult.timings` 를 채워
        // NAPI `WatchRebuildEvent.phaseDurations` 로 노출 (HMR 관측성).

        // 4. 진단 메시지 deep copy (graph.deinit 후에도 문자열 유효하도록).
        // graph.diagnostics + linker.fatal_diagnostics (IIFE unresolved 등, #1791) 병합.
        const link_diag_len = if (linker) |*l| l.fatal_diagnostics.items.len else 0;
        const diagnostics: ?[]BundleResult.OwnedDiagnostic = if (graph.diagnostics.items.len > 0 or link_diag_len > 0) blk: {
            const total = graph.diagnostics.items.len + link_diag_len;
            const diags = try self.allocator.alloc(BundleResult.OwnedDiagnostic, total);
            errdefer self.allocator.free(diags);
            // M1 수정: 부분 할당 후 OOM 시 이미 복사한 문자열 해제
            var filled: usize = 0;
            errdefer for (diags[0..filled]) |d| {
                self.allocator.free(d.message);
                self.allocator.free(d.file_path);
                if (d.suggestion) |s| self.allocator.free(s);
            };
            try copyDiagnostics(self.allocator, diags, graph.diagnostics.items, &filled);
            if (linker) |*l| {
                try copyDiagnostics(self.allocator, diags, l.fatal_diagnostics.items, &filled);
            }
            break :blk diags;
        } else null;

        // 5. 모듈 경로 수집 (dev server watch용)
        const module_paths: ?[]const []const u8 = if (graph.moduleCount() > 0) blk: {
            const paths = try self.allocator.alloc([]const u8, graph.moduleCount());
            errdefer self.allocator.free(paths);
            var path_count: usize = 0;
            errdefer for (paths[0..path_count]) |p| self.allocator.free(p);
            var it = graph.modulesIterator();
            while (it.next()) |m| {
                paths[path_count] = try self.allocator.dupe(u8, m.path);
                path_count += 1;
            }
            break :blk paths;
        } else null;

        // 5.5. Asset 파일 수집 (file/copy 로더 — 출력 디렉토리에 복사할 파일들).
        // scale_variants가 있으면 base + @2x/@3x 각각 별개 OutputFile로 emit해서
        // RN 런타임이 해상도별 파일을 로드할 수 있게 한다.
        const asset_outputs: ?[]OutputFile = blk: {
            var asset_count: usize = 0;
            {
                var it = graph.modulesIterator();
                while (it.next()) |m| {
                    if (m.asset_data) |ad| asset_count += 1 + ad.scale_variants.len;
                }
            }
            if (asset_count == 0) break :blk null;

            const outs = try self.allocator.alloc(OutputFile, asset_count);
            errdefer self.allocator.free(outs);
            var idx: usize = 0;
            var it = graph.modulesIterator();
            while (it.next()) |m| {
                if (m.asset_data) |ad| {
                    outs[idx] = .{
                        .path = try self.allocator.dupe(u8, ad.output_name),
                        .contents = try self.allocator.dupe(u8, ad.raw_content),
                    };
                    idx += 1;
                    for (ad.scale_variants) |v| {
                        outs[idx] = .{
                            .path = try self.allocator.dupe(u8, v.output_name),
                            .contents = try self.allocator.dupe(u8, v.raw_content),
                        };
                        idx += 1;
                    }
                }
            }
            break :blk outs;
        };

        // 6. Dev mode: per-module codes (동일 타입이므로 변환 불필요)
        const module_dev_codes = module_dev_codes_from_emit;

        // 7. Metafile JSON 생성 (--metafile / --analyze)
        var metafile_scope = profile.begin(.emit_metafile);
        const metafile_json: ?[]const u8 = if (self.options.metafile or self.options.analyze)
            try generateMetafileJson(
                self.allocator,
                graph,
                output,
                outputs,
                if (self.options.mf) |*mf| mf else null,
                self.options.mf_sign_key_path != null,
            )
        else
            null;
        metafile_scope.end();

        // PR7-2c: emit chunk(this.emitFile type:'chunk')의 최종 출력 파일명을 emit_store 에
        // back-fill → generateBundle hook 의 this.getFileName(chunkRef) 가 확정된 [name]-[hash]
        // 파일명을 반환(명시 fileName 없는 auto chunk). emit chunk 모듈은 자기 chunk 의 entry 라
        // 그 chunk OutputFile.module_ids 에 chk.id 가 포함된다. 명시 fileName chunk 는 skip.
        if (emit_store.chunks.items.len > 0) {
            if (outputs) |outs| {
                for (emit_store.chunks.items) |chk| {
                    for (outs) |out| {
                        if (out.kind != .chunk) continue;
                        const matched = for (out.module_ids) |mid| {
                            if (std.mem.eql(u8, mid, chk.id)) break true;
                        } else false;
                        if (matched) {
                            emit_store.setChunkFileName(chk.id, out.path) catch {};
                            break;
                        }
                    }
                }
            }
        }

        // 8. Plugin: generateBundle 훅 — 번들 완료 후 모든 플러그인에 알림
        if (self.options.plugins.len > 0) {
            const runner = plugin_mod.PluginRunner.init(self.options.plugins);
            const gen_outputs: []const emitter.OutputFile = if (outputs) |outs|
                outs
            else
                &.{.{ .path = "bundle.js", .contents = output }};
            // PR7-2c: emit_store 를 hook_ctx 로 전달 → generateBundle 의 this.getFileName(chunkRef)
            // 가 back-fill 된 chunk 파일명을 반환(청킹 후라 확정).
            var gen_hook_ctx: plugin_mod.HookContext = .{ .emit_store = @ptrCast(&emit_store) };
            defer gen_hook_ctx.deinit();
            runner.runGenerateBundle(gen_outputs, &gen_hook_ctx);
        }

        // 5.6. CSS 번들 수집 (엔트리별 CSS 모듈 연결)
        var css_scope = profile.begin(.emit_css);
        defer css_scope.end();
        var css_output_files: std.ArrayList(OutputFile) = .empty;
        defer css_output_files.deinit(self.allocator);
        {
            const css_emit = @import("css_emitter.zig");
            if (css_chunk_files) |files| {
                // code splitting: 청크별 CSS 를 그대로 사용 (소유권 이전).
                for (files) |f| {
                    css_output_files.append(self.allocator, f) catch {
                        self.allocator.free(f.path);
                        self.allocator.free(f.contents);
                    };
                }
                self.allocator.free(files);
                css_chunk_files = null;
            } else {
                // 비-splitting / preserve-modules: entry 당 단일 CSS (기존 동작).
                for (self.options.entry_points) |ep| {
                    const resolved = graph.path_to_module.get(ep) orelse continue;
                    if (css_emit.emitCssBundle(self.allocator, graph, resolved, self.options.css_names)) |css_out| {
                        css_output_files.append(self.allocator, css_out) catch {};
                    }
                }
                // 두 entry 가 같은 stem(예: pages/a/index.tsx + pages/b/index.tsx)
                // 이면 emitCssBundle 가 둘 다 같은 path 의 OutputFile 을 반환 →
                // writeFileSync 가 한쪽을 overwrite (silent CSS 손실). splitting
                // 경로(planCssChunks 내부 disambiguatePathCollisions)와 같은
                // 정책으로 비-splitting 경로도 충돌 그룹에 한해 content-hash
                // disambiguator 를 자동 부여한다. CSS 실패는 번들 실패로 번지지
                // 않게 흡수(기존 css emit 의 관용과 동일).
                css_emit.disambiguateOutputFilePaths(self.allocator, css_output_files.items) catch {};
            }
        }

        // this.emitFile (PR5): plugin 이 emit 한 asset 을 OutputFile(kind=.asset)로 변환.
        // path/contents 를 새로 dupe — emit_store 는 scratch 로 deinit 되므로 OutputFile 이
        // 자기 복사본을 소유해야 한다(OutputFile.deinit 이 path+contents 해제).
        var emit_asset_files: std.ArrayList(OutputFile) = .empty;
        defer emit_asset_files.deinit(self.allocator);
        for (emit_store.assets.items) |a| {
            const path = try self.allocator.dupe(u8, a.file_name);
            errdefer self.allocator.free(path);
            const contents = try self.allocator.dupe(u8, a.source);
            errdefer self.allocator.free(contents);
            try emit_asset_files.append(self.allocator, .{ .path = path, .contents = contents, .kind = .asset });
        }
        // 결정성(#3564): emit 순서는 worker 스케줄링(병렬 transform) 의존이라 path 로 정렬해
        // outputFiles 의 asset 순서를 run 간 안정화한다. (MVP 는 fileName 중복 검출 안 함 —
        // 같은 fileName 을 두 번 emit 하면 동일 path OutputFile 2개. Rollup 은 throw, follow-up.)
        std.mem.sort(OutputFile, emit_asset_files.items, {}, struct {
            fn lessThan(_: void, a: OutputFile, b: OutputFile) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);

        // Worker + CSS + emit asset + mf-manifest 출력 파일을 asset_outputs에 합침
        const final_asset_outputs: ?[]OutputFile = if (worker_output_files.items.len > 0 or asset_outputs != null or css_output_files.items.len > 0 or emit_asset_files.items.len > 0 or mf_manifest != null) blk: {
            const existing = if (asset_outputs) |a| a.len else 0;
            const mf_n: usize = if (mf_manifest != null) 1 else 0;
            // P2-2 (#3422): manifest 산출 시 SHA-256 무결성 sidecar 도 1개.
            // P2-3 (#3423): + 키 지정 시 Ed25519 `.sig` 1개 (opt-in).
            const sig_n: usize = if (mf_n == 1 and self.options.mf_sign_key_path != null) 1 else 0;
            const total = existing + worker_output_files.items.len + css_output_files.items.len + emit_asset_files.items.len + mf_n * 2 + sig_n;
            const merged = try self.allocator.alloc(OutputFile, total);
            if (asset_outputs) |a| {
                @memcpy(merged[0..a.len], a);
                self.allocator.free(a);
            }
            for (worker_output_files.items, 0..) |wf, i| {
                merged[existing + i] = wf;
            }
            const css_start = existing + worker_output_files.items.len;
            for (css_output_files.items, 0..) |cf, i| {
                merged[css_start + i] = cf;
            }
            const emit_start = css_start + css_output_files.items.len;
            for (emit_asset_files.items, 0..) |ef, i| {
                merged[emit_start + i] = ef;
            }
            if (mf_manifest) |m| {
                const slot = emit_start + emit_asset_files.items.len;
                // P2-2: manifest + 모든 JS 출력 청크의 SHA-256 SRI sidecar.
                // m(아직 살아있음) + outputs(최종 바이트, placeholder 치환
                // 완료) 입력. sidecar 자신·서명은 미포함(P2-3 서명 자기참조
                // 순환 회피). 컴퓨트→dup 순서 + errdefer 로 부분실패 누수 차단
                // (성공 전 mf_manifest 가 m 소유 → 이중해제 없음).
                const sidecar = try @import("mf_integrity.zig").buildSidecar(
                    self.allocator,
                    "mf-manifest.json",
                    m,
                    outputs orelse &.{},
                );
                errdefer self.allocator.free(sidecar);
                const pm = try self.allocator.dupe(u8, "mf-manifest.json");
                errdefer self.allocator.free(pm);
                const ps = try self.allocator.dupe(u8, "mf-manifest.json.integrity.json");
                errdefer self.allocator.free(ps);
                // P2-3: 키 지정 시 sidecar 를 Ed25519 서명 → 별도 `.sig`
                // (자기참조 순환 회피 — sidecar 불변). 키 오류=fail-fast
                // (보안 의도라 silent skip 금지). 부분실패 누수는 errdefer.
                var sig_json: ?[]const u8 = null;
                errdefer if (sig_json) |s| self.allocator.free(s);
                var psig: ?[]const u8 = null;
                errdefer if (psig) |p| self.allocator.free(p);
                if (self.options.mf_sign_key_path) |keypath| {
                    const key_txt = std.fs.cwd().readFileAlloc(self.allocator, keypath, 4096) catch
                        return error.MfSignKeyRead;
                    defer self.allocator.free(key_txt);
                    const trimmed = std.mem.trim(u8, key_txt, " \t\r\n");
                    const Dec = std.base64.standard.Decoder;
                    var seed: [32]u8 = undefined;
                    if ((Dec.calcSizeForSlice(trimmed) catch return error.MfSignKeyInvalid) != seed.len)
                        return error.MfSignKeyInvalid;
                    Dec.decode(&seed, trimmed) catch return error.MfSignKeyInvalid;
                    sig_json = try @import("mf_integrity.zig").signSidecar(self.allocator, sidecar, seed);
                    psig = try self.allocator.dupe(u8, "mf-manifest.json.integrity.json.sig");
                }
                merged[slot] = .{ .path = pm, .contents = m };
                merged[slot + 1] = .{ .path = ps, .contents = sidecar };
                if (sig_json) |s| {
                    merged[slot + 2] = .{ .path = psig.?, .contents = s };
                    sig_json = null; // 소유권 이전
                    psig = null;
                }
                mf_manifest = null; // 소유권 이전 — errdefer(:1356) 이중해제 방지
            }
            break :blk merged;
        } else asset_outputs;

        // --mangle-report (#1760): 번들 크기 집계 후 JSON 파일 기록.
        if (mangle_report_enabled) {
            var total_bytes: usize = output.len;
            if (outputs) |outs| {
                total_bytes = 0;
                for (outs) |o| total_bytes += o.contents.len;
            }
            mangle_collector.bundle_size_bytes = total_bytes;

            if (self.options.mangle_report_path) |path| write_blk: {
                const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                    std.log.warn("--mangle-report: cannot create '{s}': {s}", .{ path, @errorName(err) });
                    break :write_blk;
                };
                defer file.close();
                mangle_collector.writeJson(file.deprecatedWriter()) catch |err| {
                    std.log.warn("--mangle-report: write failed ({s}): {s}", .{ path, @errorName(err) });
                };
            }
        }

        // 증분 빌드: graph.deinit() 전에 모듈을 store로 이전.
        // putModule이 parse_arena 소유권을 store로 가져가므로
        // graph.deinit()에서 이중 해제가 발생하지 않는다.
        if (self.options.module_store) |store| {
            graph.transferModulesToStore(store);
        }

        var first_err: ?*const types.BundlerDiagnostic = null;
        if (linker) |*l| {
            if (l.fatal_diagnostics.items.len > 0) first_err = &l.fatal_diagnostics.items[0];
        }
        if (first_err == null) {
            for (graph.diagnostics.items) |*d| {
                if (d.severity == .@"error") {
                    first_err = d;
                    break;
                }
            }
        }
        lifecycle_runner.runBuildEnd(first_err);
        lifecycle_runner.runCloseBundle();

        // RN asset metadata ownership 을 graph → BundleResult 로 transfer.
        // graph.deinit 의 free 루프는 toOwnedSlice 후 비어있는 list 를 만남.
        const rn_asset_metadata_out: ?[]RnAssetMetadata =
            if (graph.rn_asset_metadata.items.len > 0)
                try graph.rn_asset_metadata.toOwnedSlice(self.allocator)
            else
                null;

        // #3318 P1-6: host(mf.remotes) — 단일파일 출력에 init prelude +
        // 원격 동적 import→loadRemote 재작성. split 경로(output="" — host
        // 가 동시에 remote 인 niche)는 후속(follow-up). 게이트 = wrapContainer
        // 와 동일 관례(markBoundary).
        if (self.options.mf) |*mf| {
            if (mf.remotes.len > 0 and output.len > 0) {
                // P3-1/P3-2 (#3436/#3437): emit 전 host 계약 빌드타임
                // 검증 — expose 부재·shared singleton 불일치는 fail-fast
                // (S6, 런타임 깨짐 아님), shared 버전 비호환은 경고.
                // resolve 불가 remote 는 skip(정밀 fail-fast).
                const fe = @import("federation_emit.zig");
                const cwd: ?[]const u8 = if (self.options.project_root.len > 0) self.options.project_root else null;
                try fe.verifyHostContract(self.allocator, output, mf, cwd, mf_static_remotes.keys());
                const host_out = try fe.emitHostInit(self.allocator, output, mf, mf_static_remotes.keys());
                self.allocator.free(output);
                output = host_out;
            }
        }

        return .{
            .output = output,
            .sourcemap = dev_sourcemap,
            .sourcemap_builder = dev_sourcemap_builder,
            .outputs = outputs,
            .outputs_by_format = outputs_by_format,
            .diagnostics = diagnostics,
            .module_paths = module_paths,
            .module_dev_codes = module_dev_codes,
            .asset_outputs = final_asset_outputs,
            .rn_asset_metadata = rn_asset_metadata_out,
            .metafile_json = metafile_json,
            .timings = .{
                .graph_ns = t_graph,
                .link_ns = t_link,
                .shake_ns = t_shake,
                .emit_ns = t_emit,
            },
            .reparsed_modules = reparsed_count,
            .reparsed_paths = reparsed_paths_out,
        };
    }
};

/// metafile JSON을 생성한다 (esbuild 호환 형식).
/// inputs: 각 모듈의 경로, 바이트 수, import 목록
/// outputs: 출력 파일의 경로, 바이트 수, 포함된 입력 모듈
fn generateMetafileJson(
    allocator: std.mem.Allocator,
    graph: *const @import("graph.zig").ModuleGraph,
    single_output: []const u8,
    multi_outputs: ?[]const OutputFile,
    mf: ?*const MfBundleConfig,
    mf_signed: bool,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"inputs\": {");

    // inputs
    var first_input = true;
    var mod_it = graph.modulesIterator();
    while (mod_it.next()) |m| {
        if (m.path.len == 0) continue;
        if (!first_input) try buf.appendSlice(allocator, ",");
        first_input = false;
        try buf.appendSlice(allocator, "\n    ");
        try appendJsonString(&buf, allocator, m.path);
        try buf.appendSlice(allocator, ": { \"bytes\": ");
        try appendInt(&buf, allocator, m.source.len);
        // imports
        try buf.appendSlice(allocator, ", \"imports\": [");
        var first_imp = true;
        for (m.import_records) |rec| {
            if (rec.is_external) continue;
            if (rec.resolved.isNone()) continue;
            const dep = graph.getModule(rec.resolved) orelse continue;
            if (!first_imp) try buf.appendSlice(allocator, ", ");
            first_imp = false;
            try buf.appendSlice(allocator, "{ \"path\": ");
            try appendJsonString(&buf, allocator, dep.path);
            try buf.appendSlice(allocator, ", \"kind\": ");
            try appendJsonString(&buf, allocator, @tagName(rec.kind));
            try buf.appendSlice(allocator, " }");
        }
        try buf.appendSlice(allocator, "] }");
    }

    try buf.appendSlice(allocator, "\n  },\n  \"outputs\": {");

    // outputs
    if (multi_outputs) |outs| {
        var first_out = true;
        for (outs) |o| {
            if (!first_out) try buf.appendSlice(allocator, ",");
            first_out = false;
            try buf.appendSlice(allocator, "\n    ");
            try appendJsonString(&buf, allocator, o.path);
            try buf.appendSlice(allocator, ": { \"bytes\": ");
            try appendInt(&buf, allocator, o.contents.len);
            try buf.appendSlice(allocator, " }");
        }
    } else if (single_output.len > 0) {
        try buf.appendSlice(allocator, "\n    \"bundle.js\": { \"bytes\": ");
        try appendInt(&buf, allocator, single_output.len);
        try buf.appendSlice(allocator, " }");
    }

    try buf.appendSlice(allocator, "\n  }");
    // P2-4 (#3424): MF 산출 표식 — additive 최상위 `zntcMf` 키(esbuild
    // 메타파일 스키마는 {inputs,outputs}; 알 수 없는 키는 분석기가 무시 →
    // 호환 불변). exposes>0(=remote-producer, manifest/integrity/sig 산출
    // 시점)일 때만. 산출 파일명은 결정적 상수(P1-5/P2-2/P2-3) — 청크별
    // 매핑은 mf-manifest.json 본문이라 metafile 은 포인터/마커만(중복 회피).
    if (mf) |m| {
        if (m.exposes.len > 0) {
            try buf.appendSlice(allocator, ",\n  \"zntcMf\": { \"name\": ");
            // P1-0 validateMf 가 exposes>0 ⟹ name 강제 → orelse 는 도달
            // 불가 방어(wrapContainer 게이트와 동치).
            try appendJsonString(&buf, allocator, m.name orelse "");
            try buf.appendSlice(allocator, ", \"manifest\": \"mf-manifest.json\", \"integrity\": \"mf-manifest.json.integrity.json\", \"signature\": ");
            if (mf_signed)
                try buf.appendSlice(allocator, "\"mf-manifest.json.integrity.json.sig\"")
            else
                try buf.appendSlice(allocator, "null");
            try buf.appendSlice(allocator, ", \"exposes\": [");
            for (m.exposes, 0..) |kv, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try appendJsonString(&buf, allocator, kv.key);
            }
            try buf.appendSlice(allocator, "], \"shared\": [");
            for (m.shared, 0..) |se, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try appendJsonString(&buf, allocator, se.name);
            }
            try buf.appendSlice(allocator, "], \"remotes\": [");
            for (m.remotes, 0..) |kv, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try appendJsonString(&buf, allocator, kv.key);
            }
            try buf.appendSlice(allocator, "] }");
        }
    }
    try buf.appendSlice(allocator, "\n}\n");
    return buf.toOwnedSlice(allocator);
}

// JSON 문자열 리터럴 단일 소스(metafile + mf-manifest 공유). emitter.zig
// 가 정본 — 양쪽이 import 하는 중립 모듈(circular import 회피, types.zig
// 패턴과 동일 규율).
const appendJsonString = emitter.appendJsonString;

fn appendInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, val: usize) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch unreachable;
    try buf.appendSlice(allocator, s);
}
