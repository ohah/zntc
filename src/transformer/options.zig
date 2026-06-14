//! Public transformer option types and graph pre-pass gating.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const profile = @import("../profile.zig");
const define_mod = @import("transformer/define.zig");
const codegen_options = @import("../codegen/options.zig");
const regex_lower = @import("regex_lower.zig");

/// define 치환 엔트리. key=식별자 텍스트, value=치환 문자열.
/// `parser.scan_results.DefineEntry` 와 동일 정의 — parser 의 inline scan 도 같은 entries 사용.
pub const DefineEntry = define_mod.DefineEntry;

pub const Plugin = @import("../bundler/plugin.zig").Plugin;

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

    pub const compat = @import("compat.zig");

    /// graph 단계 transformer pre-pass 가 필요한지.
    /// 옵션-side 사유 (drop / define / minify / decorator 등) 를 먼저 cheap 하게 본 뒤,
    /// `unsupported.*` 가 set 된 경우에 한해 AST 노드 사용을 스캔해 실제로 lowering 대상
    /// 문법이 있을 때만 pre-pass 를 강제한다 (예: `target=es5` + 단순 TS strip → skip).
    /// graph-level 플래그 (react_refresh / styled_components / emotion / worklet_transform /
    /// minify_identifiers) 는 ModuleGraph 가 별도로 결합한다.
    /// 새 transformer-driven 옵션을 추가하면 여기에도 반영해야 graph 의 게이트가
    /// silent 하게 fall-through 하지 않는다.
    pub fn requiresGraphPrePass(self: *const TransformOptions, ast: *const Ast) bool {
        if (self.drop_console or self.drop_debugger or self.drop_labels.len > 0) return true;
        if (define_mod.astUsesDefine(ast, self.define)) return true;
        if (self.module_specifier_map.len > 0) return true;
        if (self.minify_syntax or self.minify_whitespace) return true;
        if (!self.use_define_for_class_fields) return true;
        if (self.experimental_decorators or self.emit_decorator_metadata) return true;
        if (self.unsupportedGraphPrePassFeatureUsed(ast)) return true;
        return false;
    }

    fn unsupportedGraphPrePassFeatureUsed(self: *const TransformOptions, ast: *const Ast) bool {
        const u = self.unsupported;
        if (!u.hasAny()) return false;

        var walk_scope = profile.begin(.graph_discover_pm_prepass_decision_unsupported_walk);
        defer walk_scope.end();

        for (ast.nodes.items) |node| {
            switch (node.tag) {
                .arrow_function_expression => {
                    if (u.async_await and hasArrowFlag(ast, node, ast_mod.ArrowFlags.is_async)) return true;
                },
                .function_declaration,
                .function_expression,
                => {
                    const flags = ast.readExtra(node.data.extra, ast_mod.FunctionExtra.flags);
                    if (u.async_await and (flags & ast_mod.FunctionFlags.is_async) != 0) return true;
                    if (u.generator and (flags & ast_mod.FunctionFlags.is_generator) != 0) return true;
                },
                .class_declaration,
                .class_expression,
                => {
                    if (u.requiresPrivateDownlevel() or u.class_static_block) return true;
                },
                .for_of_statement => if (u.for_of) return true,
                .for_await_of_statement => if (u.needsForAwaitOfDownlevel()) return true,
                .spread_element => if (u.spread) return true,
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
                .private_identifier,
                .private_field_expression,
                => if (u.requiresPrivateDownlevel()) return true,
                .static_block => if (u.class_static_block) return true,
                .tagged_template_expression => if (u.template_literal) return true,
                .variable_declaration => {
                    if (u.using and ast.variableDeclarationKind(node).isUsing()) return true;
                },
                .await_expression => if (u.top_level_await) return true,
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
};

/// 점-구분 pragma 의 head segment. `jsx_lowering.makeFactoryCallee` 가 동일하게
/// `factory[0..첫 '.']` 를 root-scope binding 으로 attach 하므로 둘이 일치해야 한다.
fn jsxHeadIdent(spec: []const u8) []const u8 {
    return std.mem.sliceTo(spec, '.');
}
