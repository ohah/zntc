//! Public transformer option types and graph pre-pass gating.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const module_parser = @import("../parser/module.zig");
const token_mod = @import("../lexer/token.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const profile = @import("../profile.zig");
const define_mod = @import("transformer/define.zig");
const drop_scan = @import("drop_scan.zig");
const codegen_options = @import("../codegen/options.zig");
const regex_lower = @import("regex_lower.zig");

/// define 치환 엔트리. key=식별자 텍스트, value=치환 문자열.
/// `parser.scan_results.DefineEntry` 와 동일 정의 — parser 의 inline scan 도 같은 entries 사용.
pub const DefineEntry = define_mod.DefineEntry;

pub const Plugin = @import("../bundler/plugin.zig").Plugin;

const ArrowCaptureScanItem = struct {
    node: ast_mod.NodeIndex,
    inside_arrow: bool,
};

/// `import { x } from 'mod'` 의 cherry-pick 매핑 — `babel-plugin-lodash` 동등.
///
/// `template` 내 `{name}` placeholder 가 specifier 이름으로 치환. 예:
///   `.{ .module = "lodash", .template = "lodash/{name}" }`
///   → `import { map, filter } from 'lodash'` 가
///     `import map from 'lodash/map'; import filter from 'lodash/filter'` 로 분해.
pub const ModuleSpecifierMapEntry = struct {
    module: []const u8,
    template: []const u8,
};

/// Standalone transpile fast path에서 named import elision만 판단하기 위한 최소 binding 정보.
/// full semantic analyzer의 symbols/references를 대체하지 않고 import specifier 보존 여부만
/// `isImportSpecifierUnused`에서 소비한다.
pub const BindingLite = struct {
    named_imports: []NamedImport = &.{},

    pub const NamedImport = struct {
        local_name: []const u8,
        used_as_value: bool = false,
    };

    pub fn namedImportValueUse(self: *const BindingLite, local_name: []const u8) ?bool {
        for (self.named_imports) |binding| {
            if (std.mem.eql(u8, binding.local_name, local_name)) return binding.used_as_value;
        }
        return null;
    }
};

/// emotion.autoLabel 모드. 다른 emotion 도구들 (`@emotion/babel-plugin` 등) 의
/// `'always' | 'dev-only' | 'never'` 와 동일 의미.
pub const AutoLabelMode = enum {
    /// label 적용 안 함.
    never,
    /// 항상 label 적용 (ZNTC 기본 — 기존 사용자 영향 없음).
    always,
    /// `process.env.NODE_ENV` define 이 `"production"` 이면 .never, 아니면 .always.
    /// runtime conditional 이 아니라 compile-time 단정 — `--define:process.env.NODE_ENV=...`
    /// 가 설정돼 있어야 의미 있음.
    dev_only,
};

/// Transformer 설정.
pub const TransformOptions = struct {
    /// 청크 레벨 async factory 가 top-level await 를 대신 처리하는지 (#4598).
    ///
    /// IIFE + async 지원 타겟에서만 켠다. 그 조합에서는 모듈 단위 래핑이 해롭다 —
    /// `export` 가 래퍼 밖에 남아 스코프가 갈리고, 같은 번들 소비자도 래퍼 밖 최상위에
    /// 놓여 값을 못 본다(scope-hoisted 출력이라 live binding 이 없다).
    ///
    /// ⚠️ UMD/AMD/CJS 로 넓히면 안 된다 — async factory 를 만들지 않아 감쌀 것이 없어진다.
    /// ⚠️ async 미지원 타겟(es5)도 안 된다 — factory 가 generator 여야 하는데 `for await`
    /// 다운레벨이 내부에 `await` 를 그대로 내보내 generator 안에서 SyntaxError 가 된다.
    tla_chunk_wrapped: bool = false,
    /// #4598: 이 빌드가 top-level await 모듈을 **async `__esm` factory** 로 평가해
    /// 소비자가 그 init promise 를 기다리는지(`promoteAsyncConeToEsmWrap` 와 같은 조건).
    ///
    /// 그렇다면 `lowerProgram` 은 모듈을 async IIFE 로 쪼개지 않는다 — await 는 factory
    /// 안에 그대로 남고, factory 가 최상위 바인딩을 끌어올리며 문장 순서를 지킨다.
    /// 쪼개면 IIFE 밖 export 가 안쪽 지역 변수를 못 보고(`export function f() { return
    /// config }`) 순서가 뒤집혀 TDZ 가 났다(#5570). 기다려 줄 기계가 **없는 빌드 위상**
    /// (splitting·preserve-modules·비-ESM·async 미지원)에서는 기존 IIFE 경로를 쓴다.
    tla_export_decl_deferrable: bool = false,
    /// #5575: a top-level-await module lowered to an async IIFE whose result the
    /// bundle waits for before running later modules (single-file ESM output
    /// awaits `__zntc_tla`). Like webpack's async module, every statement after
    /// the first await then runs inside the wrapper in source order — export
    /// declarations included — and only bindings stay outside. Without that
    /// wait, exports keep their place after the wrapper so importers that run
    /// right away still see a value.
    tla_module_awaited: bool = false,
    /// #4598: es5 등 async 문법이 없는 타겟 + 비-ESM 출력. 최상위 await 를 기다릴 수단이
    /// async 초기화 함수(`__esm({ async "m"() {…} })` + `await init_m()`)뿐이라, webpack 처럼
    /// 그 래퍼만 네이티브 async 로 내고 경고한다. 모듈 본문은 그대로 타겟에 맞게 낮춘다.
    tla_async_init_fallback: bool = false,
    /// TS 타입 스트리핑 활성화 (기본: true)
    strip_types: bool = true,
    /// console.* 호출 제거 (--drop=console)
    drop_console: bool = false,
    /// debugger 문 제거 (--drop=debugger)
    drop_debugger: bool = false,
    /// 특정 라벨의 labeled statement 제거 (--drop-labels=DEV,TEST)
    drop_labels: []const []const u8 = &.{},
    /// define 글로벌 치환 (D020). 예: process.env.NODE_ENV → "production"
    define: []const DefineEntry = &.{},
    /// React Fast Refresh 활성화. 컴포넌트에 $RefreshReg$ 주입.
    react_refresh: bool = false,
    /// `react_refresh` 위에 hook signature ($RefreshSig$) emit 까지 활성화.
    /// default false — Metro 정책 (registration only) 보존. opt-in 시 babel-plugin-
    /// react-refresh 동등 (component body 에 `_s()` + 모듈 끝 `_s(Comp, "sig")`).
    react_refresh_hook_signatures: bool = false,
    /// styled-components 1st-party transform 활성화 (compiler.styledComponents).
    /// 활성 시 `const X = styled.div\`...\`` 같은 선언에 displayName 자동 부여.
    /// componentId / SSR / CSS minify 등 추가 변환은 후속 PR.
    styled_components: bool = false,
    /// styled-components.ssr 옵션 — false 면 componentId 생략 (displayName 만).
    /// 비-SSR 프로젝트에서 file-hash + counter 기반 deterministic ID 비용 회피.
    /// `@next/swc` 의 `compiler.styledComponents.ssr` 와 동일 surface.
    styled_components_ssr: bool = true,
    /// styled-components.minify 옵션 — true 면 CSS template 의 whitespace collapse.
    /// no-interp 템플릿 (`\`color: red;\``) 만 우선 처리. interp 있는 경우는 후속.
    /// `babel-plugin-styled-components.minify` 와 동일 의도, default 는 false (안전).
    styled_components_minify: bool = false,
    /// styled-components.fileName 옵션 (default true, babel 와 동일) — displayName 에
    /// `<basename>__<var_name>` prefix. `index.tsx` 같은 의미 없는 이름은 parent dir
    /// 명으로 fallback. false 면 `<var_name>` 만.
    styled_components_file_name: bool = true,
    /// styled-components.pure 옵션 (default false) — styled component 생성 expression 에
    /// `/* @__PURE__ */` annotation 추가. 미사용 styled component 의 dead-code elimination
    /// (tree shaking) 활성. babel-plugin-styled-components 의 `pure` 옵션과 동일.
    styled_components_pure: bool = false,
    /// styled-components.namespace 옵션 (default "" 비활성) — componentId 에 prefix 부여:
    /// `<namespace>__sc-<hash>-<counter>`. monorepo / library 환경에서 같은 styled-components
    /// 가 다른 의존성 트리에 들어가도 componentId 충돌 회피. babel-plugin 동일 동작.
    styled_components_namespace: []const u8 = "",
    /// styled-components.meaninglessFileNames 옵션 — `<basename>__<var>` displayName 의
    /// basename 이 의미 없는 이름 (default `index`) 이면 parent dir 명으로 fallback.
    /// babel-plugin-styled-components 의 동일 옵션과 동등 — 빈 array 면 fallback 비활성.
    styled_components_meaningless_file_names: []const []const u8 = &.{"index"},
    /// styled-components.topLevelImportPaths 옵션 — vendored fork 인식 (e.g. `@my-org/styled`,
    /// `@my-org/*`, `@{my-org,co}/*`). picomatch 호환 glob: `*` (0+ chars), `?` (1 char),
    /// `[abc]`/`[a-z]`/`[!abc]` (bracket class + negation), `{a,b}` (brace expansion, nested).
    styled_components_top_level_import_paths: []const []const u8 = &.{},
    /// styled-components.cssProp 옵션 — `<div css={...}>` JSX prop 을 module-level
    /// hoisted styled component 로 추출. babel-plugin-styled-components default true 와
    /// 동등하지만 ZNTC 는 후속 PR 에서 단계별 transform 구현 — 현재는 옵션 surface 만 노출.
    /// transform 미구현 상태에서 true 켜도 no-op (사용자 코드 안전).
    styled_components_css_prop: bool = false,
    /// emotion 1st-party transform (compiler.emotion).
    /// 활성 시 `const X = css\`...\`` 같은 선언에 `label:X;` 자동 prepend (autoLabel).
    /// `import { css } from "@emotion/react"` 의 named binding 추적.
    emotion: bool = false,
    /// emotion.autoLabel 옵션. 3 모드:
    ///   - `.always` — 항상 label 적용 (기본).
    ///   - `.never` — 절대 label 적용 안 함.
    ///   - `.dev_only` — `process.env.NODE_ENV` define 이 `"production"` 이면 .never,
    ///     아니면 .always (compile-time 결정 — runtime conditional emit 아님).
    /// `compiler.emotion: { autoLabel: "always" | "dev-only" | "never" | false (=never) }`.
    emotion_auto_label: AutoLabelMode = .always,
    /// emotion.sourceMap 옵션 — true 면 css 템플릿 끝에 inline sourceMap 주석을 append.
    /// `compiler.emotion: { sourceMap: true }`. babel-plugin-emotion 동작과 일치 —
    /// DevTools 에서 CSS 위치 → source 위치 추적 가능.
    emotion_source_map: bool = false,
    /// emotion.labelFormat 옵션 — label 이름 포맷 템플릿. 토큰: `[local]` (변수명),
    /// `[filename]` (확장자 제외 basename), `[dirname]` (parent dir). 빈 문자열이면
    /// `[local]` 동작 (기본). babel-plugin-emotion 동작과 동일 — invalid CSS char
    /// (`!"#$%&'()*+,./:;<=>?@[]^|}~{`) 는 `-` 로 sanitize.
    emotion_label_format: []const u8 = "",
    /// emotion.importMap 의 vendored re-export 케이스 단순화 — `@emotion/react|css|core`
    /// 의 named import (`{ css, keyframes, Global, ClassNames, injectGlobal }`) 를
    /// re-export 하는 사용자 패키지를 emotion 으로 인식. babel-plugin-emotion 의
    /// `importMap[source][name].canonicalImport` 가 emotion 의 css source 를 가리키는
    /// 가장 흔한 케이스를 커버.
    emotion_extra_css_sources: []const []const u8 = &.{},
    /// emotion.importMap 의 vendored re-export 케이스 단순화 — `@emotion/styled` 의
    /// default import (styled) 를 re-export 하는 사용자 패키지. babel-plugin-emotion
    /// 의 `importMap[source].default.canonicalImport == ["@emotion/styled","default"]`
    /// 케이스 동등.
    emotion_extra_styled_sources: []const []const u8 = &.{},
    /// useDefineForClassFields=false: instance field를 constructor의 this.x = value 할당으로 변환.
    /// true(기본값)이면 class field를 그대로 유지 (TC39 [[Define]] semantics).
    /// false이면 TS 4.x 이전 동작 — field를 constructor body로 이동 ([[Set]] semantics).
    use_define_for_class_fields: bool = true,
    /// experimentalDecorators: legacy decorator를 __decorateClass 호출로 변환.
    /// false(기본값)이면 decorator를 TC39 Stage 3 형태로 그대로 출력.
    /// true이면 class/method/property decorator를 esbuild 호환 __decorateClass 호출로 변환.
    experimental_decorators: bool = false,
    /// emitDecoratorMetadata: __metadata("design:paramtypes", [...]) 호출 주입.
    /// NestJS, Angular, TypeORM 등 reflect-metadata 기반 DI에 필요.
    emit_decorator_metadata: bool = false,
    /// `import { x } from 'mod'` → `import x from 'mod/x'` cherry-pick 분해. babel-plugin-lodash
    /// 등 라이브러리별 babel plugin 의 ZNTC 동등 — 사용자가 라이브러리 매핑 제공, ZNTC 가
    /// generic 하게 적용. 매핑 안 된 source 는 unchanged.
    ///
    /// 변환 조건 (안전):
    ///   - source 가 매핑 entry 의 module 과 일치 (정확 매칭)
    ///   - 모든 specifier 가 named (default/namespace 아님), alias 없음, value (type-only 아님)
    ///   조건 미충족 시 unchanged — fallback (라이브러리가 path import 미지원 시 안전).
    module_specifier_map: []const ModuleSpecifierMapEntry = &.{},
    /// verbatimModuleSyntax (TS 5.0+): true면 값 import를 elide하지 않는다.
    /// `import type`만 제거되고 `import { foo } from "./bar"`는 foo가 미사용이라도 보존.
    /// esbuild/vite/swc(isolatedModules) 표준 동작. 기본 false (tsc 기본과 동일).
    verbatim_module_syntax: bool = false,
    /// Unsupported features bitmask. feature별로 다운레벨링 여부를 결정.
    /// ESTarget(es2020) 또는 엔진 버전(chrome80,safari14)에서 변환됨.
    unsupported: compat.UnsupportedFeatures = .{},

    // --- JSX lowering (Phase 1: 트랜스파일 모드) ---
    /// JSX AST → call_expression 변환 활성화
    jsx_transform: bool = false,
    /// JSX lowering 결과 call_expression 에 pure flag 를 붙이지 않음.
    jsx_side_effects: bool = false,
    /// @__PURE__ / package sideEffects 등 annotation 기반 DCE 신호 무시.
    ignore_annotations: bool = false,
    /// JSX 런타임 모드 (codegen.JsxRuntime과 동일 enum 사용)
    jsx_runtime: codegen_options.JsxRuntime = .classic,
    /// classic 모드 factory (기본: "React.createElement")
    jsx_factory: []const u8 = "React.createElement",
    /// classic 모드 fragment (기본: "React.Fragment")
    jsx_fragment: []const u8 = "React.Fragment",
    /// automatic 모드 import source (기본: "react")
    jsx_import_source: []const u8 = "react",
    /// jsxDEV의 fileName 출력용 파일 경로
    jsx_filename: []const u8 = "",

    /// 플러그인 배열. string-based 훅과 AST 훅을 모두 포함하는 통합 인터페이스.
    /// transformer는 AST 훅(onFunction 등)만 사용.
    plugins: []const Plugin = &.{},

    /// Reanimated worklet plugin의 substituteWebPlatformChecks 옵션 포팅.
    /// true일 때 `isWeb()` / `shouldBeUseWeb()` 호출을 `true` 리터럴로 정적 치환.
    /// web build에서 플랫폼 체크 코드가 항상 true로 평가되므로 dead code 제거 효과.
    substitute_web_platform_checks: bool = false,

    /// Reanimated worklet plugin의 `globals` 옵션 포팅.
    /// 사용자가 지정한 이름은 closure 분석에서 제외 (전역으로 간주).
    /// 예: `globals: ['__DEV__']` → worklet 내 `__DEV__` 참조가 __closure에 포함 안 됨.
    worklet_globals: []const []const u8 = &.{},

    /// worklet 함수의 `__pluginVersion` 값. null이면 기본 ZNTC 상수 사용.
    /// Reanimated dev mode (`serializable.native.ts:464`)에서 `jsVersion`과 대조.
    worklet_plugin_version: ?[]const u8 = null,

    /// Reanimated worklet plugin의 `disableWorkletClasses` 옵션 포팅.
    /// true일 때 worklet body의 `new X()` 감지 시 `X__classFactory`를 closure에 자동 주입하지 않음.
    disable_worklet_classes: bool = false,

    /// `--minify-syntax` 활성화 — AST 레벨 의미 보존 축약을 허용 (#1587 등).
    /// 예: 미참조 class expression name 익명화, 잉여 parens 제거(codegen).
    minify_syntax: bool = false,

    /// `--minify-whitespace` 활성화 — #1621 runtime helper 축약 이름 사용.
    /// es_helpers.makeRuntimeHelperRef 가 이 플래그를 읽어 `__extends` → `$eX`
    /// 같은 단축 이름으로 AST identifier 를 생성. bundler preamble 의 `var $eX=...`
    /// 와 정의부가 매칭된다. dev_mode 에선 __zntc_g 경로라 무관.
    minify_whitespace: bool = false,

    /// `--keep-names` 활성화 — 함수/클래스 이름을 `.name` 프로퍼티로 보존해야 하므로
    /// minify_syntax 기반 이름 제거 최적화를 비활성화.
    keep_names: bool = false,

    /// #1961: transform() 끝에서 set 된 RuntimeHelpers 비트마다
    /// `import { __helper } from "\x00zntc:runtime/<short>"` 노드를 program 앞에 prepend.
    /// graph parse 단계의 transformer pre-pass 만 true 로 set — emitter 의 in-place
    /// transformer 호출은 false 유지 (grafh 통합 없이 helper specifier 가 출력에 새는
    /// 사고 방지). 자세한 매핑은 `runtime_helper_imports.zig`.
    emit_runtime_helper_imports: bool = false,

    /// Standalone transpile can bind runtime helper identities during lowering
    /// and defer their output spelling until all generated symbols are known.
    /// Low-level Transformer callers keep the legacy collision-aware spelling
    /// unless they explicitly provide a final SymbolId name map.
    defer_runtime_helper_name_resolution: bool = false,

    /// standalone transpile 에서 JSX automatic runtime import 를 AST 노드로 prepend.
    /// bundler 는 `emit_runtime_helper_imports` 경로에서 함께 처리하므로 이 옵션은
    /// 단일 파일 변환 전용이다. 문자열 prepend 대신 semantic edit 가 import binding 과
    /// JSX call reference 를 같은 SymbolId 로 연결하도록 한다.
    emit_jsx_runtime_imports: bool = false,

    pub const compat = @import("compat.zig");

    /// graph 단계 transformer pre-pass 가 필요한지.
    /// graph-visible helper/global 이나 최종 이름 결정에 쓸 합성 SymbolId 가 생기는지 확인한다.
    /// 옵션-side 사유 (drop / define / minify / decorator 등) 를 먼저 cheap 하게 본 뒤,
    /// `unsupported.*` 가 set 된 경우에 한해 AST 노드 사용을 스캔해 실제로 lowering 대상
    /// 문법이 있을 때만 pre-pass 를 강제한다 (예: `target=es5` + 단순 TS strip → skip).
    /// graph-level 플래그 (react_refresh / styled_components / emotion / worklet_transform /
    /// minify_identifiers) 는 ModuleGraph 가 별도로 결합한다.
    /// 새 transformer-driven 옵션을 추가하면 여기에도 반영해야 graph 의 게이트가
    /// silent 하게 fall-through 하지 않는다.
    /// TLA 모듈 초기화를 async `__esm` 래퍼로 기다려도 되는지 — 타겟이 async 를 지원하거나
    /// 비-ESM es5 대체 경로(`tla_async_init_fallback`)일 때.
    pub fn asyncInitWrappersAllowed(self: *const TransformOptions) bool {
        return !self.unsupported.async_await or self.tla_async_init_fallback;
    }

    /// `isAwaitableInit` 에 넘길 기능 집합 — 대체 경로에서는 async 래퍼를 허용한 것으로 본다.
    pub fn tlaWaitUnsupported(self: *const TransformOptions) compat.UnsupportedFeatures {
        var unsupported = self.unsupported;
        if (self.tla_async_init_fallback) unsupported.async_await = false;
        return unsupported;
    }

    /// Legacy decorators use assign field semantics in every Transformer
    /// constructor. Graph planning must observe that same effective option.
    pub fn effectiveUseDefineForClassFields(self: *const TransformOptions) bool {
        return self.use_define_for_class_fields and !self.experimental_decorators;
    }

    pub fn requiresGraphPrePass(self: *const TransformOptions, ast: *const Ast) bool {
        if (drop_scan.hasDroppedTransformStatement(ast, self.drop_console, self.drop_debugger, self.drop_labels)) return true;
        if (define_mod.astUsesDefine(ast, self.define)) return true;
        if (astHasMappedImportToSplit(ast, self.module_specifier_map)) return true;
        // Whitespace-only minification changes emission, not the AST or graph.
        // Any syntax that creates helper identities has its own pre-pass gate.
        if (self.minify_syntax) return true;
        if (!self.effectiveUseDefineForClassFields() and astHasClassFieldSyntax(ast)) return true;
        if ((self.experimental_decorators or self.emit_decorator_metadata) and ast.has_decorator) return true;
        if (self.unsupportedGraphPrePassFeatureUsed(ast)) return true;
        return false;
    }

    /// True when a static import matches a cherry-pick map and the transformer
    /// will split its unaliased value specifiers. Configured maps on imports the
    /// transformer leaves unchanged must not force semantic graph reanalysis.
    pub fn hasMappedImportToSplit(self: *const TransformOptions, ast: *const Ast) bool {
        return astHasMappedImportToSplit(ast, self.module_specifier_map);
    }

    pub fn unsupportedGraphPrePassFeatureUsed(self: *const TransformOptions, ast: *const Ast) bool {
        const u = self.unsupported;
        if (!u.hasAny()) return false;

        var walk_scope = profile.begin(.graph_discover_pm_prepass_decision_unsupported_walk);
        defer walk_scope.end();

        var saw_named_definition = false;
        var saw_lexical = false;
        var saw_named_assignment = false;
        var saw_arrow = false;
        for (ast.nodes.items) |node| {
            switch (node.tag) {
                .arrow_function_expression => {
                    saw_arrow = true;
                    if (u.async_await and hasArrowFlag(ast, node, ast_mod.ArrowFlags.is_async)) return true;
                },
                .function_declaration,
                .function_expression,
                => {
                    if (node.tag == .function_declaration) saw_named_definition = true;
                    const flags = ast.readExtra(node.data.extra, ast_mod.FunctionExtra.flags);
                    if (functionNeedsDownlevel(u, (flags & ast_mod.FunctionFlags.is_async) != 0, (flags & ast_mod.FunctionFlags.is_generator) != 0)) return true;
                },
                // 객체·클래스 메서드는 function 노드가 아니라 method_definition 에 비트를 둔다.
                // 예전엔 여기를 안 봐서 `{ async m(){} }` 가 es2016 이하에서 pre-pass 를 건너뛰고
                // `__async` 호출만 남았다(클래스는 private 게이트에 우연히 걸려 멀쩡했다). (#4727)
                .method_definition => {
                    const flags = ast.readExtra(node.data.extra, ast_mod.MethodExtra.flags);
                    if (functionNeedsDownlevel(u, (flags & ast_mod.MethodFlags.is_async) != 0, (flags & ast_mod.MethodFlags.is_generator) != 0)) return true;
                },
                .class_declaration,
                .class_expression,
                => {
                    if (u.class or u.requiresPrivateDownlevel() or u.class_static_block) return true;
                },
                // Public field lowering can synthesize constructor bindings
                // and runtime-helper references even while class syntax stays
                // native. Keep this gate tied to its own feature bit instead
                // of relying on target-version ordering with static blocks.
                .property_definition => {
                    if (u.class_field) {
                        const key = ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.key);
                        if (!key.isNone() and ast.getNode(key).tag != .private_identifier) return true;
                    }
                },
                .for_of_statement => if (u.for_of) return true,
                // 최상위 `for await` 도 top-level await 다 — 아래 await_expression 과 같이 TLA 를
                // 낮춰야 하면 pre-pass 가 래퍼 promise 를 기록해야 importer 가 기다린다 (#4598).
                .for_await_of_statement => if (u.needsForAwaitOfDownlevel() or u.top_level_await) return true,
                .spread_element => if (u.spread) return true,
                .object_expression => {
                    if (u.object_extensions) {
                        // Lowering a method/shorthand named __proto__ needs
                        // an own-data-property helper, even without a source
                        // computed key. Register that provider before linking.
                        var properties = ast.iterateExtraList(node.data.list);
                        while (properties.next()) |property| {
                            const member = ast.getNode(property);
                            const key = switch (member.tag) {
                                .object_property => if (member.data.binary.right.isNone()) member.data.binary.left else continue,
                                .method_definition => blk: {
                                    const flags = ast.readExtra(member.data.extra, ast_mod.MethodExtra.flags);
                                    if (flags & (ast_mod.MethodFlags.is_getter | ast_mod.MethodFlags.is_setter) != 0) continue;
                                    break :blk ast.readExtraNode(member.data.extra, ast_mod.MethodExtra.key);
                                },
                                else => continue,
                            };
                            const name = ast.directStaticKeyName(ast.allocator, key) catch return true;
                            defer if (name) |value| ast.allocator.free(value);
                            if (name != null and std.mem.eql(u8, name.?, "__proto__")) return true;
                        }
                    }
                    if (u.object_spread) {
                        // Object spread lowers to a generated Object.assign
                        // global reference; reserve it before linking so a
                        // source binding named Object cannot capture the call.
                        var properties = ast.iterateExtraList(node.data.list);
                        while (properties.next()) |property| {
                            if (ast.getNode(property).tag == .spread_element) return true;
                        }
                    }
                },
                .object_pattern,
                .object_assignment_target,
                => {
                    if (u.destructuring) return true;
                    // #4248: object rest (`{...r}`, ES2018) 는 object_spread 로
                    // lowering(__rest 헬퍼). destructuring 지원 타겟(es2017 등)에서도
                    // rest 가 있으면 prepass 필요 — 누락 시 bundle 에서 __rest 미등록
                    // ReferenceError. rest 실재 시만 검사(plain `{a}` 과트리거 회피).
                    if (u.object_spread and
                        ast.nodeListSplitRest(node.data.list).rest_operand != null) return true;
                },
                .array_pattern,
                .array_assignment_target,
                .assignment_target_with_default,
                .binding_rest_element,
                .assignment_target_rest,
                => if (u.destructuring) return true,
                // Parameter-environment aliases preserve anonymous defaults'
                // inferred names with __name. Discover that helper before
                // linking even when this is a plain default-only function.
                .assignment_pattern => if (u.default_params) return true,
                .formal_parameter => {
                    if (u.default_params and !ast.readExtraNode(node.data.extra, ast_mod.FormalParameterExtra.default).isNone()) return true;
                },
                // `catch {}` becomes a generated catch binding and needs its
                // exact identity before the bundler links the transformed AST.
                .catch_clause => if (u.optional_catch_binding and node.data.binary.left.isNone()) return true,
                .private_identifier => if (u.requiresPrivateDownlevel()) return true,
                .private_field_expression => {
                    if (u.requiresPrivateDownlevel()) return true;
                    if (u.optional_chaining and
                        (ast.readExtra(node.data.extra, 2) & ast_mod.MemberFlags.optional_chain) != 0) return true;
                },
                // These operator lowerings can introduce temporary bindings and
                // references. Discover them before the bundler assigns exact
                // identities, even when no other unsupported syntax is present.
                .static_member_expression,
                .computed_member_expression,
                => if (u.optional_chaining and
                    (ast.readExtra(node.data.extra, 2) & ast_mod.MemberFlags.optional_chain) != 0) return true,
                .call_expression => if (u.optional_chaining and
                    (ast.readExtra(node.data.extra, 3) & ast_mod.CallFlags.optional_chain) != 0) return true,
                .static_block => if (u.class_static_block) return true,
                // An object literal lowered after its first computed key names
                // its members with `__name`; discover the helper before linking.
                .computed_property_key => if (u.object_extensions) return true,
                // class 를 낮추는 타겟은 객체 리터럴 메서드의 `super` 도 `__superGet`/`__superSet`
                // 으로 낮춘다 — 클래스가 없는 모듈도 헬퍼 등록이 필요하다 (#4729).
                .super_expression => if (u.class) return true,
                .tagged_template_expression => if (u.template_literal) return true,
                .variable_declaration => {
                    if (u.using and ast.variableDeclarationKind(node).isUsing()) return true;
                    if (ast.variableDeclarationKind(node).isLexical()) {
                        saw_named_definition = true;
                        saw_lexical = true;
                    }
                },
                .await_expression => if (u.top_level_await) return true,
                // Named-function `new.target` lowering reuses the source
                // function binding for its generated reference. Trigger the
                // identity pre-pass even without minification so that
                // reference is attached to its exact source SymbolId.
                .meta_property => if (u.new_target and node.data.none == 1) return true,
                // Exponentiation lowering emits a free `Math.pow` reference.
                // Discover it before linking even though it adds no helper
                // import, so the linker can reserve the generated global.
                .binary_expression => {
                    if (u.exponentiation and
                        node.data.binary.flags == @backingInt(token_mod.Kind.star2)) return true;
                },
                .logical_expression => {
                    if (u.nullish_coalescing and
                        node.data.binary.flags == @backingInt(token_mod.Kind.question2)) return true;
                },
                .assignment_expression => {
                    if (u.exponentiation and
                        node.data.binary.flags == @backingInt(token_mod.Kind.star2_eq)) return true;
                    if (u.logical_assignment) {
                        const op: token_mod.Kind = @fromBackingInt(@intCast(node.data.binary.flags));
                        if (op == .amp2_eq or op == .pipe2_eq or op == .question2_eq) return true;
                    }
                    if (ast.isAnonymousFunctionDefinition(node.data.binary.right)) saw_named_assignment = true;
                },
                // regex 다운레벨 (named capture, dotall, sticky, unicode brace escape).
                // named capture 는 wrap 변환에 helper module import 필요 — prepass 거쳐야
                // graph 가 helper module 을 등록.
                .regexp_literal => {
                    if (u.regex_dotall or u.regex_named_groups or u.regex_sticky or
                        u.unicode_brace_escape) return true;
                    // dup-gate 만 set 인 es2018~es2024 에선 named group 후보가 있을
                    // 때만 prepass — 일반 regex 모듈에 graph prepass 비용 미부과 (#4199).
                    if (u.regex_duplicate_named_groups and
                        std.mem.indexOf(u8, ast.getText(node.span), "(?<") != null) return true;
                    // #4210: modifier-gate 만 set 인 es2024↓ 에서도 modifier 그룹이 실재할
                    // 때만 prepass — run() 이 loud 진단을 띄운다 (lowering 은 미구현이라
                    // regexp 는 passthrough, 출력 무변경). hasModifierGroup 으로 후보 게이트.
                    if (u.regex_modifiers and
                        regex_lower.hasModifierGroup(ast.getText(node.span))) return true;
                },
                else => {},
            }
        }
        if (u.arrow and saw_arrow and hasLoweredArrowCapture(ast)) return true;
        // ES5 output renames a colliding block function or lexical binding and
        // restores the source `.name` with `__name`, so the helper must be
        // discovered before linking (#5454).
        if (u.block_scoping and saw_named_definition and hasBlockLevelNamedDefinition(ast)) return true;
        // A renamed lexical binding can also be assigned a function later.
        if (u.block_scoping and saw_lexical and saw_named_assignment) return true;
        return false;
    }

    /// A lowered arrow needs graph pre-pass when it must materialize a lexical
    /// capture binding. The emitter's legacy transform path deliberately has
    /// semantic editing disabled, so those generated bindings would otherwise
    /// reach codegen without exact SymbolIds.
    fn hasLoweredArrowCapture(ast: *const Ast) bool {
        if (ast.nodes.items.len == 0) return true;
        const root: ast_mod.NodeIndex = ast.transformed_root orelse @fromBackingInt(@intCast(
            @as(u32, @intCast(ast.nodes.items.len - 1)),
        ));
        if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or
            ast.nodes.items[@backingInt(root)].tag != .program) return true;

        var stack: std.ArrayList(ArrowCaptureScanItem) = .empty;
        defer stack.deinit(ast.allocator);
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(ast.allocator);
        stack.append(ast.allocator, .{ .node = root, .inside_arrow = false }) catch return true;

        while (stack.pop()) |item| {
            const idx = item.node;
            if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) continue;
            const raw = @backingInt(idx);
            const visit_key = (@as(u64, raw) << 1) | @intFromBool(item.inside_arrow);
            if (seen.contains(visit_key)) continue;
            seen.put(ast.allocator, visit_key, {}) catch return true;
            const node = ast.nodes.items[raw];
            const inside_arrow = item.inside_arrow or node.tag == .arrow_function_expression;

            switch (node.tag) {
                .this_expression, .super_expression => if (inside_arrow) return true,
                .meta_property => if (inside_arrow and node.data.none == 1) return true,
                .identifier_reference => if (inside_arrow) {
                    const raw_name = ast.identifierNameText(node);
                    var decode_buffer: [64]u8 = undefined;
                    const name = Scanner.decodeIdentifierEscapesInto(raw_name, &decode_buffer) orelse raw_name;
                    if (std.mem.eql(u8, name, "arguments")) return true;
                },
                // Descend into normal functions with a fresh lexical context
                // so arrows nested in their bodies are still checked.
                .function_declaration, .function_expression, .function => {
                    var children = ast_walk.children(ast, node);
                    while (children.next()) |child| {
                        stack.append(ast.allocator, .{ .node = child, .inside_arrow = false }) catch return true;
                    }
                    continue;
                },
                // A method's key/decorators are evaluated in the surrounding
                // context, while its params/body start a new `this`/`super` scope.
                .method_definition => {
                    if (!pushDecoratorExpressions(
                        ast,
                        &stack,
                        node.data.extra,
                        ast_mod.MethodExtra.deco_start,
                        ast_mod.MethodExtra.deco_len,
                        item.inside_arrow,
                    )) return true;
                    stack.append(ast.allocator, .{
                        .node = ast.readExtraNode(node.data.extra, ast_mod.MethodExtra.key),
                        .inside_arrow = item.inside_arrow,
                    }) catch return true;
                    stack.append(ast.allocator, .{
                        .node = ast.readExtraNode(node.data.extra, ast_mod.MethodExtra.params),
                        .inside_arrow = false,
                    }) catch return true;
                    stack.append(ast.allocator, .{
                        .node = ast.readExtraNode(node.data.extra, ast_mod.MethodExtra.body),
                        .inside_arrow = false,
                    }) catch return true;
                    continue;
                },
                // Field initializers own class `this`; computed keys and
                // decorators are still evaluated in the enclosing context.
                .property_definition, .accessor_property => {
                    if (!pushDecoratorExpressions(
                        ast,
                        &stack,
                        node.data.extra,
                        ast_mod.PropertyExtra.deco_start,
                        ast_mod.PropertyExtra.deco_len,
                        item.inside_arrow,
                    )) return true;
                    stack.append(ast.allocator, .{
                        .node = ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.key),
                        .inside_arrow = item.inside_arrow,
                    }) catch return true;
                    stack.append(ast.allocator, .{
                        .node = ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.init),
                        .inside_arrow = false,
                    }) catch return true;
                    continue;
                },
                // Arrows inside a static block still need their own capture
                // bindings; reset only the block's direct lexical values.
                .static_block => {
                    var children = ast_walk.children(ast, node);
                    while (children.next()) |child| {
                        stack.append(ast.allocator, .{ .node = child, .inside_arrow = false }) catch return true;
                    }
                    continue;
                },
                else => {},
            }

            var children = ast_walk.children(ast, node);
            while (children.next()) |child| {
                stack.append(ast.allocator, .{ .node = child, .inside_arrow = inside_arrow }) catch return true;
            }
        }
        return false;
    }

    fn pushDecoratorExpressions(
        ast: *const Ast,
        stack: *std.ArrayList(ArrowCaptureScanItem),
        extra: u32,
        start_offset: u32,
        len_offset: u32,
        inside_arrow: bool,
    ) bool {
        if (!ast.hasExtra(extra, @max(start_offset, len_offset))) return false;
        const list = ast_mod.NodeList{
            .start = ast.readExtra(extra, start_offset),
            .len = ast.readExtra(extra, len_offset),
        };
        if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return false;
        var iter = ast.iterateExtraList(list);
        while (iter.next()) |decorator| {
            stack.append(ast.allocator, .{ .node = decorator, .inside_arrow = inside_arrow }) catch return false;
        }
        return true;
    }

    fn hasBlockLevelNamedDefinition(ast: *const Ast) bool {
        var bodies: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer bodies.deinit(ast.allocator);
        for (ast.nodes.items) |node| {
            const body = ast.functionBodyBlock(node) orelse continue;
            bodies.put(ast.allocator, @backingInt(body), {}) catch return true;
        }
        const extras = ast.extra_data.items;
        for (ast.nodes.items, 0..) |node, raw| {
            const list: ast_mod.NodeList = switch (node.tag) {
                .block_statement => if (bodies.contains(@intCast(raw))) continue else node.data.list,
                .switch_case => if (ast.hasExtra(node.data.extra, 2))
                    .{ .start = extras[node.data.extra + 1], .len = extras[node.data.extra + 2] }
                else
                    continue,
                .for_statement => {
                    if (ast.hasExtra(node.data.extra, 0) and isNamedDefinition(ast, extras[node.data.extra])) return true;
                    continue;
                },
                else => continue,
            };
            if (list.start > extras.len or list.len > extras.len - list.start) return true;
            for (extras[list.start .. list.start + list.len]) |stmt| {
                if (isNamedDefinition(ast, stmt)) return true;
            }
        }
        return false;
    }

    /// A function declaration, or a lexical declaration whose initializer
    /// takes its `.name` from the binding.
    fn isNamedDefinition(ast: *const Ast, raw: u32) bool {
        if (raw >= ast.nodes.items.len) return false;
        const node = ast.nodes.items[raw];
        if (node.tag == .function_declaration) return true;
        if (node.tag != .variable_declaration or !ast.variableDeclarationKind(node).isLexical()) return false;
        if (!ast.hasExtra(node.data.extra, 2)) return true;
        const start = ast.extra_data.items[node.data.extra + 1];
        const len = ast.extra_data.items[node.data.extra + 2];
        if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return true;
        for (ast.extra_data.items[start .. start + len]) |declarator| {
            if (declarator >= ast.nodes.items.len) return true;
            const decl = ast.nodes.items[declarator];
            if (decl.tag != .variable_declarator or !ast.hasExtra(decl.data.extra, 2)) continue;
            if (ast.isAnonymousFunctionDefinition(ast.readExtraNode(decl.data.extra, 2))) return true;
        }
        return false;
    }

    /// 함수·메서드의 async/generator 조합이 이 타겟에서 낮춰져야 하는지.
    /// `async function*` 은 async·generator 와 **따로** 도입된 기능(es2018)이라, 두 비트를
    /// 각각 보면 async 는 되고 async generator 는 안 되는 타겟(es2017·node8 등)을 놓친다.
    fn functionNeedsDownlevel(u: compat.UnsupportedFeatures, is_async: bool, is_generator: bool) bool {
        if (is_async and is_generator and u.async_generator) return true;
        if (is_async and u.async_await) return true;
        if (is_generator and u.generator) return true;
        return false;
    }

    fn hasArrowFlag(ast: *const Ast, node: Node, flag: u32) bool {
        const e = node.data.extra;
        return ast.hasExtra(e, ast_mod.ArrowExtra.flags) and (ast.readExtra(e, ast_mod.ArrowExtra.flags) & flag) != 0;
    }

    /// JSX 노드를 call_expression 으로 lowering 할지 판단.
    /// preserve 모드는 lowering 을 skip 하고 codegen 이 raw source slice 를 emit 한다.
    pub fn shouldLowerJsx(self: @This()) bool {
        return self.jsx_transform and self.jsx_runtime != .preserve;
    }

    /// classic JSX lowering 이 참조하는 factory 의 head identifier
    /// (`React.createElement` → `React`, `h` → `h`). 이 식별자는 source 에 직접
    /// 쓰이지 않으므로 import elision 이 별도로 살아있는 것으로 취급해야 한다 (#3063).
    pub fn jsxClassicFactoryHead(self: @This()) []const u8 {
        return jsxHeadIdent(self.jsx_factory);
    }

    /// classic JSX `<>...</>` lowering 이 참조하는 fragment 의 head identifier.
    pub fn jsxClassicFragmentHead(self: @This()) []const u8 {
        return jsxHeadIdent(self.jsx_fragment);
    }

    /// per-file JSX pragma 주석 (D026) 을 적용한 module-local 옵션 사본.
    /// `@jsxRuntime` → runtime, `@jsx` → factory, `@jsxFrag` → fragment,
    /// `@jsxImportSource` → import source. 우선순위는 file pragma > tsconfig/CLI
    /// (esbuild / TypeScript 동일). pragma 가 없는 항목은 그대로 둔다. transform 의
    /// 모든 진입점 (graph pre-pass, transpile) 이 이 함수 하나를 거쳐 module 의
    /// effective JSX 설정을 확정한다.
    pub fn withModuleJsxPragmas(self: @This(), ast: *const Ast) @This() {
        var out = self;
        if (ast.jsx_pragma_runtime) |s| {
            if (codegen_options.JsxRuntime.fromString(s)) |rt| out.jsx_runtime = rt;
        }
        if (ast.jsx_pragma_factory) |s| out.jsx_factory = s;
        if (ast.jsx_pragma_fragment) |s| out.jsx_fragment = s;
        if (ast.jsx_pragma_import_source) |s| out.jsx_import_source = s;
        return out;
    }

    /// `@jsx` / `@jsxFrag` pragma 가 있는데 (pragma·tsconfig·CLI 머지 후) effective
    /// runtime 이 automatic 이면 classic factory 가 무시된다 — caller 가 warning 을 띄운다.
    pub fn jsxClassicPragmaIgnoredUnderAutomatic(self: @This(), ast: *const Ast) bool {
        if (!ast.has_jsx) return false;
        if (self.jsx_runtime != .automatic and self.jsx_runtime != .automatic_dev) return false;
        return ast.jsx_pragma_factory != null or ast.jsx_pragma_fragment != null;
    }

    /// `jsxClassicPragmaIgnoredUnderAutomatic` 가 true 일 때 caller 가 띄우는 메시지.
    /// graph pre-pass(structured diagnostic) 와 transpile(`std.log.warn`) 양쪽이 공유.
    pub const jsx_pragma_ignored_msg =
        "@jsx / @jsxFrag pragma ignored — the effective JSX runtime is automatic; " ++
        "add /** @jsxRuntime classic */ to use a custom factory, or remove the pragma";

    /// ES2025 inline modifier(#4210) 중 다운레벨 못한 잔여가 보존됐을 때 caller 가
    /// 띄우는 메시지. 진단은 transform-driven(`transformer.used_unsupported_modifier`)
    /// — graph pre-pass(structured diagnostic) 와 transpile(`std.log.warn`) 공유.
    pub const regex_modifier_unsupported_msg =
        "regular expression inline modifier group ((?i:...) / (?ims-ims:...)) is an " ++
        "ES2025 feature not supported by the configured target — it is emitted unchanged " ++
        "and will throw a SyntaxError on older engines. Raise the target to es2025+, or " ++
        "rewrite the pattern without inline modifiers.";

    /// Downlevel exponentiation cannot safely use a generated Math binding when a
    /// dynamic root scope makes generated bindings observable to direct eval.
    /// Preserve the original operator and make the configured target limitation explicit.
    pub const exponentiation_dynamic_scope_msg =
        "exponentiation is emitted unchanged because a dynamic scope prevents safe downleveling without exposing generated bindings; the configured target may not support **.";

    /// A lexical-capturing arrow cannot be represented by ordinary function
    /// syntax inside `with` without changing dynamic identifier lookup. Its
    /// containing class or object literal may also need to remain native to
    /// retain lexical `super`.
    pub const object_accessor_eval_msg =
        "object literal with a computed accessor is emitted unchanged because opaque direct eval can intercept generated builtin/helper bindings; the configured target may not support syntax retained inside it.";

    pub const object_accessor_with_msg =
        "object literal with a computed accessor is emitted unchanged inside with because dynamic lookup can intercept generated builtin/helper bindings; the configured target may not support syntax retained inside it.";

    pub const arrow_dynamic_scope_msg =
        "a lexical-capturing arrow or its containing class/object literal inside a with statement is emitted unchanged because dynamic lookup can intercept generated capture bindings or erase lexical super context; the configured target may not support syntax retained inside it.";

    /// Moving an initializer loses its class lexical environment and inherited
    /// strictness; a bounded safe eval expression is the only admitted exception.
    pub const static_initializer_dynamic_scope_msg =
        "class initializer or extracted private method cannot be lowered because direct eval or with can observe a class lexical environment that the selected target cannot preserve; select a target and class-field options that retain that class code natively.";

    pub const arrow_private_dynamic_scope_msg =
        "native syntax retained to preserve dynamic lexical capture contains private class syntax that the configured target requires to lower; select a target supporting native private classes or remove the dynamic with/eval capture.";

    /// Dynamic source passed to direct eval can observe an arbitrary generated
    /// lexical-capture name, so retain the arrow instead of guessing a suffix.
    pub const arrow_dynamic_eval_msg =
        "a lexical-capturing arrow is emitted unchanged because a non-literal direct eval argument can observe generated capture bindings; the configured target may not support arrow syntax retained inside it.";
};

fn astHasMappedImportToSplit(ast: *const Ast, entries: []const ModuleSpecifierMapEntry) bool {
    if (entries.len == 0) return false;
    const statements = ast_walk.topLevelStatementIndices(ast) orelse return true;
    for (statements) |raw_stmt| {
        if (raw_stmt >= ast.nodes.items.len) return true;
        const node = ast.nodes.items[raw_stmt];
        if (node.tag != ast_mod.Node.Tag.import_declaration) continue;
        const extra = node.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 6) return true;
        const import = module_parser.readImportDeclExtras(ast, extra);
        if (import.is_type_only or import.attrs_len != 0 or import.phase != .none or import.specs_len == 0) continue;
        const source_idx = import.source;
        if (source_idx.isNone() or @backingInt(source_idx) >= ast.nodes.items.len) return true;
        const source = ast.getNode(source_idx);
        if (source.tag != .string_literal) continue;
        const module_name = Ast.stripStringQuotes(ast.getText(source.data.string_ref));
        var source_is_mapped = false;
        for (entries) |entry| {
            if (std.mem.eql(u8, module_name, entry.module)) {
                source_is_mapped = true;
                break;
            }
        }
        if (!source_is_mapped) continue;

        if (import.specs_start > ast.extra_data.items.len or
            import.specs_len > ast.extra_data.items.len - import.specs_start) return true;

        var can_split = true;
        for (ast.extra_data.items[import.specs_start .. import.specs_start + import.specs_len]) |raw_spec| {
            if (raw_spec >= ast.nodes.items.len) return true;
            const spec = ast.getNode(@fromBackingInt(@intCast(raw_spec)));
            if (spec.tag != .import_specifier or
                (spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0 or
                spec.data.binary.left != spec.data.binary.right)
            {
                can_split = false;
                break;
            }
        }
        if (can_split) return true;
    }
    return false;
}

fn astHasClassFieldSyntax(ast: *const Ast) bool {
    for (ast.nodes.items) |node| {
        if (node.tag == .property_definition) return true;
    }
    return false;
}

/// 점-구분 pragma 의 head segment. `jsx_lowering.makeFactoryCallee` 가 동일하게
/// `factory[0..첫 '.']` 를 root-scope binding 으로 attach 하므로 둘이 일치해야 한다.
fn jsxHeadIdent(spec: []const u8) []const u8 {
    return std.mem.sliceTo(spec, '.');
}

test "whitespace minification alone skips graph pre-pass while syntax minification retains it" {
    const Parser = @import("../parser/parser.zig").Parser;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var scanner = try Scanner.init(arena.allocator(), "const answer = 42; console.log(answer);");
    var parser = Parser.init(arena.allocator(), &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();

    const whitespace_only: TransformOptions = .{ .minify_whitespace = true };
    try std.testing.expect(!whitespace_only.requiresGraphPrePass(&parser.ast));

    const syntax_minification: TransformOptions = .{ .minify_whitespace = true, .minify_syntax = true };
    try std.testing.expect(syntax_minification.requiresGraphPrePass(&parser.ast));
}

test "useDefineForClassFields false requires graph pre-pass only when class fields are present" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct { source: []const u8, expected: bool }{
        .{ .source = "const answer = 42;", .expected = false },
        .{ .source = "class Example { method() { return 1; } }", .expected = false },
        .{ .source = "class Example { value = 1; }", .expected = true },
    };

    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".js");
        _ = try parser.parse();

        const options: TransformOptions = .{ .use_define_for_class_fields = false };
        try std.testing.expectEqual(fixture.expected, options.requiresGraphPrePass(&parser.ast));
    }
}

test "drop debugger requires graph pre-pass only when debugger statements are present" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct { source: []const u8, expected: bool }{
        .{ .source = "const answer = 42;", .expected = false },
        .{ .source = "function run() { debugger; }", .expected = true },
    };

    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".js");
        _ = try parser.parse();

        const options: TransformOptions = .{ .drop_debugger = true };
        try std.testing.expectEqual(fixture.expected, options.requiresGraphPrePass(&parser.ast));
    }
}

test "drop console requires graph pre-pass only when matching calls are present" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct { source: []const u8, expected: bool }{
        .{ .source = "const answer = 42;", .expected = false },
        .{ .source = "console.log(42);", .expected = true },
        .{ .source = "console[method](42);", .expected = false },
    };

    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".js");
        _ = try parser.parse();

        const options: TransformOptions = .{ .drop_console = true };
        try std.testing.expectEqual(fixture.expected, options.requiresGraphPrePass(&parser.ast));
    }
}

test "drop labels requires graph pre-pass only when a configured label is present" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct {
        source: []const u8,
        labels: []const []const u8,
        expected: bool,
    }{
        .{ .source = "const answer = 42;", .labels = &.{"DEV"}, .expected = false },
        .{ .source = "TEST: { const answer = 42; }", .labels = &.{"DEV"}, .expected = false },
        .{ .source = "DEV: { const answer = 42; }", .labels = &.{"DEV"}, .expected = true },
        .{ .source = "OUTER: { DEV: {} }", .labels = &.{"DEV"}, .expected = true },
        .{ .source = "DEV: {}", .labels = &.{}, .expected = false },
    };

    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".js");
        _ = try parser.parse();

        const options: TransformOptions = .{ .drop_labels = fixture.labels };
        try std.testing.expectEqual(fixture.expected, options.requiresGraphPrePass(&parser.ast));
    }
}

test "combined drop options require graph pre-pass only for a matching statement" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct { source: []const u8, expected: bool }{
        .{ .source = "const answer = 42;", .expected = false },
        .{ .source = "console.log(42);", .expected = true },
        .{ .source = "function run() { debugger; }", .expected = true },
        .{ .source = "DEV: { const answer = 42; }", .expected = true },
        .{ .source = "TEST: { const answer = 42; }", .expected = false },
        .{ .source = "console[method](42);", .expected = false },
    };

    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".js");
        _ = try parser.parse();

        const options: TransformOptions = .{
            .drop_console = true,
            .drop_debugger = true,
            .drop_labels = &.{"DEV"},
        };
        try std.testing.expectEqual(fixture.expected, options.requiresGraphPrePass(&parser.ast));
    }
}

test "decorator options require graph pre-pass only when decorators are present" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct {
        source: []const u8,
        options: TransformOptions,
        expected: bool,
    }{
        .{ .source = "const answer = 42;", .options = .{ .experimental_decorators = true }, .expected = false },
        .{ .source = "const answer = 42;", .options = .{ .emit_decorator_metadata = true }, .expected = false },
        .{ .source = "@mark class Example {}", .options = .{ .experimental_decorators = true }, .expected = true },
        .{ .source = "@mark class Example {}", .options = .{ .emit_decorator_metadata = true }, .expected = true },
    };

    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();

        try std.testing.expectEqual(fixture.expected, fixture.options.requiresGraphPrePass(&parser.ast));
    }
}

test "lowered syntax discovers helpers and generated globals before linking" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct { source: []const u8, es5_prepass: bool }{
        .{ .source = "function f(x = function(){}) { function x(){} }", .es5_prepass = true },
        .{ .source = "function f(x: number = 1) { return x; }", .es5_prepass = true },
        .{ .source = "function f(x: number) { return x; }", .es5_prepass = false },
        .{ .source = "var {x = 3} = input;", .es5_prepass = true },
        .{ .source = "function square(value) { return value ** 2; }", .es5_prepass = true },
        .{ .source = "function square(value) { value **= 2; }", .es5_prepass = true },
        .{ .source = "function Plain() { return new.target; }", .es5_prepass = true },
        // A renamed block function restores `.name` with `__name` (#5454).
        .{ .source = "function f() { { function g() {} } }", .es5_prepass = true },
        .{ .source = "switch (k) { case 1: function g() {} }", .es5_prepass = true },
        .{ .source = "function f() { function g() {} if (f) { g(); } }", .es5_prepass = false },
        .{ .source = "{ let g = () => {}; }", .es5_prepass = true },
        .{ .source = "for (let g = function () {}; ;) break;", .es5_prepass = true },
        .{ .source = "{ let g = function named() {}, h = 1; }", .es5_prepass = false },
        .{ .source = "const g = () => {}; { let h = 1; }", .es5_prepass = false },
        .{ .source = "{ let h; h = () => {}; }", .es5_prepass = true },
        .{ .source = "var h; h = () => {};", .es5_prepass = false },
        .{ .source = "var o = { [k]: 1, get x() { return 1; } };", .es5_prepass = true },
    };
    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        const es5: TransformOptions = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) };
        const native: TransformOptions = .{ .unsupported = TransformOptions.compat.fromESTarget(.es2020) };
        try std.testing.expectEqual(fixture.es5_prepass, es5.requiresGraphPrePass(&parser.ast));
        try std.testing.expect(!native.requiresGraphPrePass(&parser.ast));
    }
}

test "module specifier maps require a graph pre-pass only for imports that split" {
    const Parser = @import("../parser/parser.zig").Parser;
    const map: []const ModuleSpecifierMapEntry = &.{
        .{ .module = "lodash", .template = "lodash/{name}" },
    };
    const options: TransformOptions = .{ .module_specifier_map = map };
    const fixtures = [_]struct { source: []const u8, needs_prepass: bool }{
        .{ .source = "import { map } from 'lodash';", .needs_prepass = true },
        .{ .source = "import { map, filter } from 'lodash';", .needs_prepass = true },
        .{ .source = "import { map as localMap } from 'lodash';", .needs_prepass = false },
        .{ .source = "import map from 'lodash';", .needs_prepass = false },
        .{ .source = "import * as lodash from 'lodash';", .needs_prepass = false },
        .{ .source = "import 'lodash';", .needs_prepass = false },
        .{ .source = "import {} from 'lodash';", .needs_prepass = false },
        .{ .source = "import type { map } from 'lodash';", .needs_prepass = false },
        .{ .source = "import { type map } from 'lodash';", .needs_prepass = false },
        .{ .source = "import { map } from 'lodash' with { type: 'json' };", .needs_prepass = false },
        .{ .source = "import defer { map } from 'lodash';", .needs_prepass = false },
        .{ .source = "import { map } from 'react';", .needs_prepass = false },
        .{ .source = "function f() { return 1; } import { map } from 'lodash';", .needs_prepass = true },
        .{ .source = "const packageName = 'lodash';", .needs_prepass = false },
    };
    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        try std.testing.expectEqual(
            fixture.needs_prepass,
            options.hasMappedImportToSplit(&parser.ast),
        );
        try std.testing.expectEqual(
            fixture.needs_prepass,
            options.requiresGraphPrePass(&parser.ast),
        );
    }
}

test "arrow capture bindings require graph pre-pass but ordinary arrows do not" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct { source: []const u8, needs_prepass: bool }{
        .{ .source = "const plain = () => 1;", .needs_prepass = false },
        .{ .source = "const captured = () => this;", .needs_prepass = true },
        .{ .source = "function f() { return () => arguments[0]; }", .needs_prepass = true },
        .{ .source = "function f(options = { [globalThis.key]: () => this }) { return options; }", .needs_prepass = true },
        .{ .source = "function f() { return () => argum\\u0065nts[0]; }", .needs_prepass = true },
        .{ .source = "function f() { return () => new.target; }", .needs_prepass = true },
        .{ .source = "function f() { return () => function nested() { return this; }; }", .needs_prepass = false },
        .{ .source = "const C = () => class { field = this; method() { return arguments[0]; } };", .needs_prepass = false },
        .{ .source = "const C = () => class { [this.key]() {} };", .needs_prepass = true },
        .{ .source = "class C extends Base { method() { return () => super.value; } }", .needs_prepass = true },
        .{ .source = "function f() { return () => () => new.target; }", .needs_prepass = true },
    };
    const options: TransformOptions = .{ .unsupported = .{ .arrow = true } };
    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(
            fixture.needs_prepass,
            options.requiresGraphPrePass(&parser.ast),
        );
    }
}

test "class and public-field lowering independently require graph pre-pass" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct {
        source: []const u8,
        unsupported: @import("compat.zig").UnsupportedFeatures,
        needs_prepass: bool,
    }{
        .{
            .source = "class C { method() {} }",
            .unsupported = .{ .class = true },
            .needs_prepass = true,
        },
        .{
            .source = "const C = class { method() {} };",
            .unsupported = .{ .class = true },
            .needs_prepass = true,
        },
        .{
            .source = "const value = 1;",
            .unsupported = .{ .class = true },
            .needs_prepass = false,
        },
        .{
            .source = "class C { value = 1; }",
            .unsupported = .{ .class_field = true },
            .needs_prepass = true,
        },
        .{
            .source = "class C { static value = 1; }",
            .unsupported = .{ .class_field = true },
            .needs_prepass = true,
        },
        .{
            .source = "class C { method() {} }",
            .unsupported = .{ .class_field = true },
            .needs_prepass = false,
        },
        .{
            .source = "class C { #value = 1; }",
            .unsupported = .{ .class_field = true },
            .needs_prepass = false,
        },
    };
    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        const options: TransformOptions = .{ .unsupported = fixture.unsupported };
        try std.testing.expectEqual(
            fixture.needs_prepass,
            options.requiresGraphPrePass(&parser.ast),
        );
    }
}

test "ES2020 and logical-assignment lowering independently require graph pre-pass" {
    const Parser = @import("../parser/parser.zig").Parser;
    const UnsupportedFeatures = @import("compat.zig").UnsupportedFeatures;
    const fixtures = [_]struct {
        source: []const u8,
        unsupported: UnsupportedFeatures,
        needs_prepass: bool,
    }{
        .{
            .source = "const value = object?.property;",
            .unsupported = .{ .optional_chaining = true },
            .needs_prepass = true,
        },
        .{
            .source = "const value = object?.method();",
            .unsupported = .{ .optional_chaining = true },
            .needs_prepass = true,
        },
        .{
            .source = "const value = object.property;",
            .unsupported = .{ .optional_chaining = true },
            .needs_prepass = false,
        },
        .{
            .source = "const value = left ?? right;",
            .unsupported = .{ .nullish_coalescing = true },
            .needs_prepass = true,
        },
        .{
            .source = "const value = left || right;",
            .unsupported = .{ .nullish_coalescing = true },
            .needs_prepass = false,
        },
        .{
            .source = "let value; value ||= 1;",
            .unsupported = .{ .logical_assignment = true },
            .needs_prepass = true,
        },
        .{
            .source = "let value; value &&= 1;",
            .unsupported = .{ .logical_assignment = true },
            .needs_prepass = true,
        },
        .{
            .source = "let value; value ??= 1;",
            .unsupported = .{ .logical_assignment = true },
            .needs_prepass = true,
        },
        .{
            .source = "let value; value += 1;",
            .unsupported = .{ .logical_assignment = true },
            .needs_prepass = false,
        },
    };
    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        const options: TransformOptions = .{ .unsupported = fixture.unsupported };
        try std.testing.expectEqual(
            fixture.needs_prepass,
            options.requiresGraphPrePass(&parser.ast),
        );
    }
}

test "optional catch binding lowering independently requires graph pre-pass" {
    const Parser = @import("../parser/parser.zig").Parser;
    const UnsupportedFeatures = @import("compat.zig").UnsupportedFeatures;
    const fixtures = [_]struct {
        source: []const u8,
        needs_prepass: bool,
    }{
        .{ .source = "try { throw 1; } catch { consume(); }", .needs_prepass = true },
        .{ .source = "try { throw 1; } catch (error) { consume(error); }", .needs_prepass = false },
        .{ .source = "consume();", .needs_prepass = false },
    };
    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        const options: TransformOptions = .{ .unsupported = UnsupportedFeatures{ .optional_catch_binding = true } };
        try std.testing.expectEqual(
            fixture.needs_prepass,
            options.requiresGraphPrePass(&parser.ast),
        );
    }
}

test "object spread expression lowering independently requires graph pre-pass" {
    const Parser = @import("../parser/parser.zig").Parser;
    const UnsupportedFeatures = @import("compat.zig").UnsupportedFeatures;
    const fixtures = [_]struct {
        source: []const u8,
        needs_prepass: bool,
    }{
        .{ .source = "var source = {}; var copy = { ...source };", .needs_prepass = true },
        .{ .source = "var copy = { value: 1 };", .needs_prepass = false },
        .{ .source = "var copy = [...source];", .needs_prepass = false },
        .{ .source = "var { value, ...rest } = source;", .needs_prepass = true },
    };
    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        const options: TransformOptions = .{ .unsupported = UnsupportedFeatures{ .object_spread = true } };
        try std.testing.expectEqual(
            fixture.needs_prepass,
            options.requiresGraphPrePass(&parser.ast),
        );
    }
}

test "native private initializer legacy normalized field semantics require graph pre-pass" {
    const Parser = @import("../parser/parser.zig").Parser;
    const fixtures = [_]struct { source: []const u8, expected: bool }{
        .{ .source = "const answer = 42;", .expected = false },
        .{ .source = "class Example { method() { return 1; } }", .expected = false },
        .{ .source = "class Example { value = 1; }", .expected = true },
        .{ .source = "class Example { #value = 1; constructor(value=this.#value){} }", .expected = true },
    };
    for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scanner = try Scanner.init(arena.allocator(), fixture.source);
        var parser = Parser.init(arena.allocator(), &scanner);
        _ = try parser.parse();
        const legacy: TransformOptions = .{ .experimental_decorators = true };
        try std.testing.expect(!legacy.effectiveUseDefineForClassFields());
        try std.testing.expectEqual(fixture.expected, legacy.requiresGraphPrePass(&parser.ast));
        const metadata: TransformOptions = .{ .emit_decorator_metadata = true };
        try std.testing.expect(metadata.effectiveUseDefineForClassFields());
        try std.testing.expect(!metadata.requiresGraphPrePass(&parser.ast));
    }
}
