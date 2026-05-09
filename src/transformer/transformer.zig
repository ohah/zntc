//! ZNTC Transformer — 핵심 변환 엔진
//!
//! 단일 AST를 append-only로 변환한다.
//!
//! 작동 원리:
//!   1. 파서 AST를 cloneForTransformer()로 복제
//!   2. 파서 노드(0..parser_node_count-1)를 읽기 전용으로 탐색
//!   3. 변환된 노드를 같은 AST 끝에 append
//!   4. string_table이 하나이므로 파서에서 만든 합성 이름도 codegen에서 읽을 수 있음
//!
//! 메모리:
//!   - ast는 트랜스포머 allocator로 복제됨 (원본 module.ast 보존)
//!   - 변환 완료 후 원본 AST는 해제 가능
//!   - source는 원본과 같은 슬라이스를 참조 (zero-copy)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const Data = Node.Data;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const module_parser = @import("../parser/module.zig");
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const plugin_state = @import("plugin_state.zig");
const PluginState = plugin_state.PluginState;
const profile = @import("../profile.zig");
const es2016 = @import("es2016.zig");
const es2018 = @import("es2018.zig");
const es2017_mod = @import("es2017.zig");
const es2019 = @import("es2019.zig");
const es2020 = @import("es2020.zig");
const es2021 = @import("es2021.zig");
const es2022 = @import("es2022.zig");
const es2015_template = @import("es2015_template.zig");
const es2015_shorthand = @import("es2015_shorthand.zig");
const es2015_computed = @import("es2015_computed.zig");
const es2015_object_methods = @import("es2015_object_methods.zig");
const es2015_params = @import("es2015_params.zig");
const es2015_spread = @import("es2015_spread.zig");
const es2015_arrow = @import("es2015_arrow.zig");
const es2015_for_of = @import("es2015_for_of.zig");
const es2018_for_await = @import("es2018_for_await.zig");
const es2015_destructuring = @import("es2015_destructuring.zig");
const es2015_block_scoping = @import("es2015_block_scoping.zig");
const es2015_class = @import("es2015_class.zig");
const es2015_generator = @import("es2015_generator.zig");
const es2025_using = @import("es2025_using.zig");
const regex_lower = @import("regex_lower.zig");
const unicode_escape_lower = @import("unicode_escape_lower.zig");
const es2022_tla = @import("es2022_tla.zig");
const jsx_lowering_mod = @import("jsx_lowering.zig");
const es_helpers = @import("es_helpers.zig");
const Symbol = @import("../semantic/symbol.zig").Symbol;
const worklet_mod = @import("transformer/worklet.zig");
const styled_components_mod = @import("transformer/styled_components.zig");
const emotion_mod = @import("transformer/emotion.zig");
const tagged_template_mod = @import("transformer/tagged_template.zig");
pub const ast_plugin_mod = @import("ast_plugin.zig");
pub const AstTransformCtx = ast_plugin_mod.AstTransformCtx;
pub const FunctionInfo = ast_plugin_mod.FunctionInfo;
const plugin_mod = @import("../bundler/plugin.zig");
pub const Plugin = plugin_mod.Plugin;

/// define 치환 엔트리. key=식별자 텍스트, value=치환 문자열.
/// `parser.scan_results.DefineEntry` 와 동일 정의 — parser 의 inline scan 도 같은 entries 사용.
pub const DefineEntry = @import("../parser/scan_results.zig").DefineEntry;

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

/// 정규화 버퍼 크기. `process.env.NODE_ENV`류 식별자 체인은 훨씬 짧지만 여유.
/// 초과 시 normalizeOptionalChain은 null을 반환해 치환을 스킵한다.
const DEFINE_KEY_NORM_BUF: usize = 256;

/// 번들 맥락에서 의미 없는 global root 접두어.
/// `globalThis.X`, `window.X`, `self.X` → X로 간주해 define 키와 매칭.
const GLOBAL_ROOT_PREFIXES = [_][]const u8{ "globalThis.", "window.", "self." };

/// optional chaining 토큰 `?.`를 `.`로 치환한 정규화 문자열을 buf에 쓴다.
/// 정규화된 길이가 buf 용량을 초과하면 null (극히 드문 경로 — 치환 포기).
fn normalizeOptionalChain(text: []const u8, buf: []u8) ?[]const u8 {
    const needed = std.mem.replacementSize(u8, text, "?.", ".");
    if (needed > buf.len) return null;
    _ = std.mem.replace(u8, text, "?.", ".", buf);
    return buf[0..needed];
}

/// define 키 매칭 — 엄격 일치 또는 GLOBAL_ROOT_PREFIXES 제거 후 일치.
/// 예: `globalThis.process.env.NODE_ENV`를 키 `process.env.NODE_ENV`로 매치.
fn matchDefineKey(text: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, text, key)) return true;
    for (GLOBAL_ROOT_PREFIXES) |pfx| {
        if (std.mem.startsWith(u8, text, pfx) and std.mem.eql(u8, text[pfx.len..], key)) return true;
    }
    return false;
}

fn getDefineCandidateText(ast: *const Ast, node: Node) ?[]const u8 {
    return switch (node.tag) {
        .identifier_reference,
        .static_member_expression,
        .chain_expression,
        => ast.getText(node.span),
        else => null,
    };
}

fn astUsesDefine(ast: *const Ast, defines: []const DefineEntry) bool {
    if (defines.len == 0) return false;

    for (ast.nodes.items) |node| {
        const raw_text = getDefineCandidateText(ast, node) orelse continue;

        // tryDefineReplace와 동일하게 optional chain을 정규화한 뒤 define key와 매칭한다.
        var norm_buf: [DEFINE_KEY_NORM_BUF]u8 = undefined;
        const text = if (std.mem.indexOfScalar(u8, raw_text, '?') != null)
            normalizeOptionalChain(raw_text, &norm_buf) orelse continue
        else
            raw_text;

        for (defines) |entry| {
            if (matchDefineKey(text, entry.key)) return true;
        }
    }
    return false;
}

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
    /// React Fast Refresh 활성화. 컴포넌트에 $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
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
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
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
        if (astUsesDefine(ast, self.define)) return true;
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
                .array_pattern,
                .object_pattern,
                .array_assignment_target,
                .object_assignment_target,
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
                else => {},
            }
        }
        return false;
    }

    fn hasArrowFlag(ast: *const Ast, node: Node, flag: u32) bool {
        const e = node.data.extra;
        return ast.hasExtra(e, ast_mod.ArrowExtra.flags) and (ast.readExtra(e, ast_mod.ArrowExtra.flags) & flag) != 0;
    }
};

/// 런타임 헬퍼 사용 추적 비트맵.
/// transformer가 각 변환 시 해당 비트를 설정하고,
/// 번들러 emitter가 필요한 헬퍼만 출력에 주입한다.
pub const RuntimeHelpers = packed struct(u32) {
    /// __async: async/await → generator wrapper (ES2017)
    async_helper: bool = false,
    /// __extends: class 상속 prototype chain (ES2015)
    extends: bool = false,
    /// __spreadArray: spread 연산 (ES2015)
    spread_array: bool = false,
    /// __generator: generator 상태 머신 (ES2015)
    generator: bool = false,
    /// __rest: destructuring rest (ES2015)
    rest: bool = false,
    /// __values: for-of iterator protocol (ES2015)
    values: bool = false,
    /// __toBinary: base64 → Uint8Array (binary 로더)
    to_binary: bool = false,
    /// __name: 함수/클래스 .name 프로퍼티 보존 (--keep-names)
    keep_names: bool = false,
    /// __classPrivateMethodInit: private method brand check (WeakSet.add with error)
    class_private_method_init: bool = false,
    /// __classPrivateMethodGet: private method access with brand check
    class_private_method_get: bool = false,
    /// __classCallCheck: class를 new 없이 호출 방지 (ES2015 스펙)
    class_call_check: bool = false,
    /// __callSuper: Reflect.construct 기반 super() 호출 (네이티브 클래스 extends 지원)
    call_super: bool = false,
    /// __taggedTemplateLiteral: tagged template 객체 생성 (ES2015)
    tagged_template_literal: bool = false,
    /// __using/__callDispose: using/await using 변환 (ES2025)
    using_ctx: bool = false,
    /// __classStaticPrivateFieldSpecGet/Set: static private field accessor
    class_static_private_field: bool = false,
    /// __esDecorate/__runInitializers: TC39 Stage 3 decorator 변환 (TypeScript 5.0+)
    es_decorator: bool = false,
    /// __asyncValues: for-await-of → while 루프 변환 (ES2018)
    async_values: bool = false,
    /// __superGet: super property get receiver 보존 (ES2015 class)
    super_get: bool = false,
    /// __superSet: super property set receiver 보존 (ES2015 class)
    super_set: bool = false,
    /// __assertThisInitialized/__assertThisUninitialized/__possibleConstructorReturn: derived constructor this 상태 검사
    derived_constructor: bool = false,
    /// __classPrivateFieldSet: instance private field set with return value (#1488).
    class_private_field_set: bool = false,
    /// __asyncGenerator: `async function*` → Symbol.asyncIterator 객체 (ES2018, #1911)
    async_generator: bool = false,
    /// __await: async generator body 안 await 표현 wrapper (ES2018, #1911)
    await_helper: bool = false,
    /// __tdz: default initializer / block scope TDZ read
    tdz: bool = false,
    /// __read: array destructuring iterable protocol read
    read: bool = false,
    /// __decorateClass: TS legacy `experimentalDecorators` 변환 (#2194).
    /// transpile-only 모드에서도 헬퍼 정의가 출력에 inline 되도록 transformer 가
    /// 호출 emit 시 함께 set 한다.
    legacy_decorator: bool = false,
    _padding: u6 = 0,

    /// 어떤 helper flag 라도 set 됐는지 — emitter 의 prepend 분기에서 빈 helper 시
    /// no-op 결정에 사용.
    pub fn hasAny(self: @This()) bool {
        return @as(u32, @bitCast(self)) != 0;
    }
};

/// 단일 AST append-only 변환기.
///
/// 사용법:
/// ```zig
/// var t = try Transformer.init(allocator, &source_ast, .{});
/// const new_root = try t.transform();
/// // t.ast 에 변환된 AST가 들어있다
/// ```
pub const Transformer = struct {
    /// 통합 AST. 파서 노드(0..parser_node_count-1)는 읽기 전용,
    /// 트랜스포머가 추가한 노드(parser_node_count..)는 append-only.
    /// `*Ast` — Transformer 가 소유권을 가진다 (clone 경로). D1b-2 의 `initInPlace` 는
    /// 외부 소유 AST 를 borrow 하는 variant 로 같은 필드를 공유.
    ast: *Ast,

    /// 파서 노드 수. transform() 시작 시 루트 인덱스(parser_node_count - 1) 계산에 사용.
    parser_node_count: u32,

    /// ast ownership — `init` 은 owned (clone 후 transformer 가 free), `initBorrow` 는
    /// borrowed (외부 owner 가 free). deinit 분기에 사용 (#1961 후속).
    ast_ownership: AstOwnership = .owned,

    /// 설정
    options: TransformOptions,

    /// allocator (ArrayList 호출에 필요)
    allocator: std.mem.Allocator,

    /// 임시 버퍼 (리스트 변환 시 재사용)
    scratch: std.ArrayList(NodeIndex),

    /// 보류 노드 버퍼 (1→N 노드 확장용).
    /// enum/namespace 변환 시 원래 노드 앞에 삽입할 문장(예: `var Color;`)을 저장.
    /// visitExtraList가 각 자식 방문 후 이 버퍼를 드레인하여 리스트에 삽입한다.
    pending_nodes: std.ArrayList(NodeIndex),

    /// 통합 symbol_ids. 파서 노드 영역은 semantic analyzer가 채우고,
    /// 트랜스포머 노드 영역은 propagateSymbolId/copySymbolId가 채운다.
    /// 빈 슬라이스이면 symbol 전파 비활성.
    symbol_ids: std.ArrayList(?u32) = .empty,

    /// semantic analyzer의 심볼 테이블 (unused import 판별용).
    /// 비어 있으면 unused import 제거 비활성.
    symbols: []const Symbol = &.{},

    /// #1791 per-reference 기록 (`semantic/analyzer::SemanticAnalyzer.references`).
    /// import binding elision 판정은 `Symbol.reference_count` 대신 여기서 symbol 별
    /// Reference 를 돌며 **value-use 가 하나라도 있는지** 로 판단한다. 비어있으면
    /// elision 비활성 (보수적 보존). caller 가 symbols 와 함께 설정.
    references: []const @import("../semantic/symbol.zig").Reference = &.{},

    /// Full semantic을 건너뛰는 standalone transpile 경로에서 named import elision만
    /// 판단하기 위한 lightweight binding facts.
    binding_lite: ?*const BindingLite = null,

    /// ES 다운레벨링 임시 변수 카운터.
    /// `foo() ?? bar` → `(_a = foo()) != null ? _a : bar`에서 _a, _b, _c, ... 생성에 사용.
    temp_var_counter: u32 = 0,

    /// ES2022 static block: `this` → 클래스 이름 치환을 위한 컨텍스트.
    /// static block body를 visit하는 동안만 설정된다.
    /// null이면 치환 비활성, 값이 있으면 해당 Span의 이름으로 this를 치환.
    static_block_class_name: ?Span = null,

    /// static block 안에서 일반 함수(non-arrow) 깊이 추적.
    /// 0이면 static block 최상위 (this 치환 대상), >0이면 중첩 함수 안 (치환 안 함).
    /// arrow function은 this를 상속하므로 depth를 올리지 않는다.
    this_depth: u32 = 0,

    /// ES2015 arrow function this/arguments 캡처.
    /// arrow_this_depth > 0이면 현재 다운레벨링 중인 arrow function body 안에 있으므로
    /// this → _this, arguments → _arguments로 치환한다.
    /// 일반 함수 진입 시 0으로 리셋 (자체 this/arguments 바인딩).
    arrow_this_depth: u32 = 0,

    /// ES2015 new.target: 현재 함수의 종류 (new.target 변환에 사용).
    /// constructor: this.constructor, method: void 0,
    /// function_named: this instanceof Fn ? this.constructor : void 0
    new_target_ctx: NewTargetCtx = .none,

    /// ES2015 class extends: 현재 클래스의 super class 이름 Span.
    /// class body 방문 중 설정되어, super() → Parent.call(this),
    /// super.method() → Parent.prototype.method.call(this) 변환에 사용.
    current_super_class: ?Span = null,
    current_super_class_old_idx: NodeIndex = .none,
    /// 현재 super member 접근이 static class element 안에서 발생하는지 여부.
    /// static method/field/block 에서는 super base가 Parent.prototype이 아니라 Parent constructor다.
    current_super_is_static: bool = false,
    /// static field/block 처럼 `this` 표현식이 사라지는 위치에서 super receiver로 사용할 class 이름.
    current_super_static_receiver: ?Span = null,

    /// ES2015 generator: labeled break/continue를 위한 label 스택.
    /// labeled_statement 진입 시 push, 퇴장 시 pop.
    generator_label_stack: std.ArrayList(GeneratorLabelEntry) = .empty,

    /// ES2015 generator: for loop의 update label (labeled continue 대상).
    /// collectForOperations에서 update nop 추가 직전에 설정.
    generator_for_update_label: ?u32 = null,

    /// ES2015 generator: for-of 변환에서 생성한 임시 변수 span.
    /// buildGeneratorBody에서 호이스팅 변수에 추가.
    generator_temp_var_spans: std.ArrayList(token_mod.Span) = .empty,

    /// ES2015 class private fields: "#name" → "_name" 매핑.
    /// class body 방문 중 설정되어, this.#x → _x.get(this), this.#x = v → _x.set(this, v) 변환에 사용.
    current_private_fields: []const PrivateFieldMapping = &.{},

    /// ES2022 class private methods: "#name" → WeakSet + standalone function 매핑.
    /// class body 방문 중 설정되어, this.#method() → _method_fn.call(this) 변환에 사용.
    current_private_methods: []const PrivateMethodMapping = &.{},

    /// 현재 함수 스코프에서 arrow body가 this를 사용하여 var _this = this 삽입이 필요한지.
    needs_this_var: bool = false,

    /// 현재 함수 스코프에서 arrow body가 arguments를 사용하여 var _arguments = arguments 삽입이 필요한지.
    needs_arguments_var: bool = false,

    /// ES2015 class constructor에서 super() 호출 후 this → _this 별칭이 필요한지.
    /// __callSuper가 Reflect.construct를 사용하면 새 객체를 반환하므로,
    /// super() 이후의 this 참조를 _this로 교체해야 한다.
    super_call_this_alias: bool = false,

    /// for-in/for-of/for-await-of 헤더의 left(variable_declaration)를 방문 중인지.
    /// true면 let/const → var 다운레벨 시 `= void 0` init 주입을 생략.
    /// 헤더에선 루프가 매 반복 바인딩에 쓰므로 TDZ 흉내가 불필요하고,
    /// `var k = void 0` 를 hoist해 `k = void 0; for(var k in ...)` 로 뽑아내면
    /// strict mode에서 `var k` 선언 전 접근으로 ReferenceError (#1386).
    in_for_in_of_header: bool = false,

    /// 플러그인별 runtime state. 각 plugin은 자기 sub-struct만 접근.
    /// 상세 규칙은 `plugin_state.zig` 참조.
    plugins: PluginState = .{},

    /// 런타임 헬퍼 사용 추적.
    /// 각 변환이 헬퍼를 사용하면 해당 비트를 설정한다.
    /// 번들러 emitter가 이 비트맵을 읽어 필요한 헬퍼만 출력에 주입한다.
    runtime_helpers: RuntimeHelpers = .{},

    /// 런타임 헬퍼를 ES5 문법으로 출력 (arrow, rest params 제거).
    /// unsupported.arrow일 때 자동 설정.
    runtime_es5_compat: bool = false,

    /// ES2015 tagged template: 호이스팅할 _templateObject 캐싱 함수 목록.
    /// 모듈 root 방문 완료 시 program body 맨 앞에 삽입.
    tagged_template_fns: std.ArrayList(NodeIndex) = .empty,

    /// ES2015 tagged template: _templateObject 카운터 (1부터: _templateObject2, _templateObject3, ...).
    tagged_template_counter: u32 = 0,

    /// ES2015 block scoping: _loop 함수명 카운터 (_loop, _loop2, ...)
    loop_counter: u32 = 0,

    /// ES2015 block scoping 격리: 블록 내부 let/const 변수가 외부 스코프와
    /// 이름 충돌 시 리네이밍 (x → x$1). 스택으로 중첩 블록 지원.
    block_rename_stack: std.ArrayList(BlockRenameEntry) = .empty,

    /// 현재 함수 스코프에서 선언된 모든 변수 이름 (var 호이스팅 범위).
    /// 블록 진입 시 내부 let/const와 비교하여 충돌 감지에 사용.
    scope_var_names: std.ArrayList([]const u8) = .empty,

    /// block rename suffix 카운터.
    block_rename_counter: u32 = 0,

    /// JSX lowering: 사용된 import 추적 (automatic 모드에서 import문 생성용)
    jsx_import_info: jsx_lowering_mod.JsxImportInfo = .{},

    /// 소스의 줄 오프셋 테이블 (Scanner에서 전달). jsxDEV source info 계산용.
    line_offsets: []const u32 = &.{},

    /// 후행 노드 버퍼 (함수 뒤에 프로퍼티 할당문 삽입용).
    /// pending_nodes가 자식 앞에 삽입되는 것과 대칭: trailing_nodes는 자식 뒤에 삽입.
    /// visitExtraList가 각 자식 방문 후 이 버퍼를 드레인하여 리스트에 삽입한다.
    trailing_nodes: std.ArrayList(NodeIndex) = .empty,

    /// TS const enum: 선언 시 멤버 값을 미리 평가하여 보관.
    /// 후속 visitMemberExpression에서 `E.A` 형태 참조를 literal로 인라인.
    const_enums: std.ArrayList(ConstEnumDecl) = .empty,

    /// `const re = /.../;` 형태로 선언된 regex literal 추적.
    /// key=symbol_id, value=pattern 텍스트 (`/`/flags 제외 owned slice).
    /// `String.replace(re, "$<name>...")` 같은 호출에서 named group 매핑 lookup 에 사용 (#1473).
    /// const 바인딩만 추적 (let/var 는 재할당 가능).
    regex_var_map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    pub const BlockRenameEntry = struct {
        old_name: []const u8,
        new_name: []const u8,
    };

    pub const GeneratorLabelEntry = struct {
        name: []const u8,
        break_label: u32,
        continue_label: ?u32,
    };

    pub const NewTargetCtx = union(enum) {
        none,
        constructor, // class constructor: new.target → this.constructor
        method, // class method: new.target → void 0
        function_named: Span, // function Fn: new.target → this instanceof Fn ? this.constructor : void 0
    };

    pub const ConstEnumValue = union(enum) {
        number: f64, // ECMAScript Number — 소수/큰 정수 모두 표현 가능
        /// quote 미포함 raw 문자열. AST 출력 시 quote 추가.
        string: []const u8,
    };

    pub const ConstEnumMember = struct {
        name: []const u8,
        value: ConstEnumValue,
    };

    pub const ConstEnumDecl = struct {
        name: []const u8,
        members: []const ConstEnumMember,
        /// enum binding 의 symbol_id. shadowing 검사 — identifier_reference 의 symbol_id 가
        /// 일치할 때만 인라인 (같은 스코프의 다른 변수 잘못 변환 방지). null이면 symbol 정보 없음 → 이름으로만 매칭.
        symbol_id: ?u32,
    };

    /// `class_name` 으로 instance/static 을 구분 — null 이면 instance (WeakMap 기반),
    /// non-null 이면 static (descriptor 객체 + class brand check).
    pub const PrivateFieldMapping = struct {
        original_name: []const u8, // "#x"
        var_name: []const u8, // "_x"
        class_name: ?[]const u8 = null, // null → instance, non-null → static (brand check 클래스명)
    };

    /// `class_name` 으로 instance/static 을 구분 — null 이면 instance (WeakSet 기반),
    /// non-null 이면 static (descriptor 객체 + class brand check).
    pub const PrivateMethodMapping = struct {
        original_name: []const u8, // "#method" (원본 소스 텍스트)
        weakset_name: []const u8, // "_method" (WeakSet 변수명 — 같은 name 의 getter/setter 공유)
        func_name: []const u8, // kind 에 따라 "_method_fn" / "_method_get" / "_method_set"
        member_idx: NodeIndex = NodeIndex.none, // method_definition 노드 (ES2015 경로에서 사용)
        // standalone function_declaration 의 span 으로 사용 — leading comment 가
        // `function _fn()` 뒤가 아니라 함수 앞에서 flush 되도록 (#1516).
        member_span: Span = .{ .start = 0, .end = 0 },
        /// method / getter / setter (#1523).
        kind: @import("es_helpers.zig").PrivateMethodKind = .method,
        class_name: ?[]const u8 = null, // null → instance, non-null → static
    };

    // RefreshRegistration / RefreshSignature 타입 정의는 plugin_state.zig로 이사.
    // 외부 모듈 (refresh.zig 등)에서 `Transformer.RefreshRegistration`로 접근 가능하도록 alias 제공.
    pub const RefreshRegistration = plugin_state.RefreshRegistration;
    pub const RefreshSignature = plugin_state.RefreshSignature;

    /// 파서 AST 를 transformer 가 별도 cell 에 복제 후 transform — 원본 보존 모드.
    /// 일반적인 single-shot transpile / emit 단계의 first-time transform 진입점.
    /// super 참조가 Parent.prototype.* / Parent.* 호출 형태로 lowering 되어야 하는지 판정.
    /// - `unsupported.class`: ES2015 미만 타겟이라 class 자체가 lowering 됨
    /// - `current_super_is_static`: target 이 class 를 지원해도 static field init/static block 은
    ///   IIFE/`Class.foo = …` 로 들어내져 super 가 더 이상 lexical 로 의미를 가지지 않음
    /// - `current_super_class != null`: derived class 안 (extends 가 있어 super 의미 자체가 존재)
    pub inline fn needsSuperLowering(self: *const Transformer) bool {
        return (self.options.unsupported.class or self.current_super_is_static) and self.current_super_class != null;
    }

    /// 현재 scope 의 private field 가 `WeakMap.get/set` lowering 대상인지 판정.
    /// `class` / `class_private_field` 옵션 둘 중 하나라도 켜져 있고, 현재 visit 중인
    /// class 가 private field 를 갖고 있을 때 true.
    pub inline fn hasActivePrivateFieldLowering(self: *const Transformer) bool {
        return (self.options.unsupported.class or self.options.unsupported.class_private_field) and self.current_private_fields.len > 0;
    }

    pub fn init(allocator: std.mem.Allocator, source_ast: *const Ast, options: TransformOptions) Error!Transformer {
        var opts = options;
        if (opts.experimental_decorators) opts.use_define_for_class_fields = false;

        const ast_ptr = try allocator.create(Ast);
        errdefer allocator.destroy(ast_ptr);
        ast_ptr.* = try Ast.cloneForTransformer(source_ast, allocator);
        // D1 (RFC #1672): parser/transformer 영역 경계 스냅샷.
        ast_ptr.transform_boundary = @intCast(ast_ptr.nodes.items.len);

        return finishInit(allocator, ast_ptr, opts, .owned);
    }

    /// 이미 transform 된 ast 를 borrow — `cloneForTransformer` skip (#1961 PR 1d).
    /// graph parse 단계의 transformer pre-pass 가 in-place 로 transform 한 ast 를
    /// emit 단계 transformer 가 그대로 사용. transform() 은 `ast.transformed_root`
    /// cache hit 분기로 즉시 cached root 반환 → 수백 KB AST 의 전량 memcpy 회피.
    /// `ast` 는 caller 가 owner — transformer.deinit 은 ast 를 건드리지 않는다.
    /// `*const Ast` 받음 — transform() cache hit 분기는 ast mutation 없음. 단, ast 필드는
    /// `*Ast` 라 내부적으로 `@constCast` (caller 가 mut 의도면 별도 borrow 함수 미래에).
    pub fn initBorrow(allocator: std.mem.Allocator, ast: *const Ast, options: TransformOptions) Error!Transformer {
        var opts = options;
        if (opts.experimental_decorators) opts.use_define_for_class_fields = false;
        return finishInit(allocator, @constCast(ast), opts, .borrowed);
    }

    const AstOwnership = enum { owned, borrowed };

    fn finishInit(
        allocator: std.mem.Allocator,
        ast_ptr: *Ast,
        opts: TransformOptions,
        ownership: AstOwnership,
    ) Error!Transformer {
        const parser_count: u32 = switch (ownership) {
            .owned => @intCast(ast_ptr.nodes.items.len),
            .borrowed => ast_ptr.transform_boundary orelse @intCast(ast_ptr.nodes.items.len),
        };
        var self: Transformer = .{
            .ast = ast_ptr,
            .parser_node_count = parser_count,
            .options = opts,
            .allocator = allocator,
            .scratch = .empty,
            .pending_nodes = .empty,
            .ast_ownership = ownership,
        };
        if (opts.unsupported.arrow) self.runtime_es5_compat = true;
        return self;
    }

    pub fn deinit(self: *Transformer) void {
        // borrow 모드는 외부 owner (보통 module.parse_arena) 가 ast 를 free.
        if (self.ast_ownership == .owned) {
            self.ast.deinit();
            self.allocator.destroy(self.ast);
        }
        self.deinitExceptAst();
    }

    /// AST를 제외한 모든 리소스를 해제한다.
    /// 테스트에서 AST를 별도로 관리할 때 사용. `.ast` 는 `*Ast` 이므로 호출자가
    /// `ast.deinit()` + `allocator.destroy(ast)` 둘 다 책임.
    pub fn deinitExceptAst(self: *Transformer) void {
        self.scratch.deinit(self.allocator);
        self.pending_nodes.deinit(self.allocator);
        self.symbol_ids.deinit(self.allocator);
        self.plugins.refresh.registrations.deinit(self.allocator);
        for (self.plugins.refresh.signatures.items) |s| self.allocator.free(s.signature);
        self.plugins.refresh.signatures.deinit(self.allocator);
        self.plugins.emotion.scope_stack.deinit(self.allocator);
        if (self.plugins.emotion.newline_offsets) |*list| list.deinit(self.allocator);
        self.plugins.styled_components.css_prop_pending_decls.deinit(self.allocator);
        // collision 발생 시 mangled name 은 heap-owned. owned flag 로 free 판정 (Zig 의
        // string-literal pooling 이 implementation-defined 이라 ptr 비교 fragile).
        const sc = &self.plugins.styled_components;
        if (sc.css_prop_inject_name_owned) self.allocator.free(sc.css_prop_inject_name);
        self.trailing_nodes.deinit(self.allocator);
        self.generator_label_stack.deinit(self.allocator);
        self.generator_temp_var_spans.deinit(self.allocator);
        self.tagged_template_fns.deinit(self.allocator);
        for (self.block_rename_stack.items) |entry| self.allocator.free(entry.new_name);
        self.block_rename_stack.deinit(self.allocator);
        self.scope_var_names.deinit(self.allocator);
        for (self.const_enums.items) |decl| {
            self.allocator.free(decl.name);
            for (decl.members) |m| {
                self.allocator.free(m.name);
                if (m.value == .string) self.allocator.free(m.value.string);
            }
            self.allocator.free(decl.members);
        }
        self.const_enums.deinit(self.allocator);
        {
            var it = self.regex_var_map.iterator();
            while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
            self.regex_var_map.deinit(self.allocator);
        }
    }

    /// semantic analyzer의 symbol_ids를 통합 배열로 복사한다.
    /// 파서 노드 영역(0..parser_node_count-1)에 symbol_id를 채운다.
    pub fn initSymbolIds(self: *Transformer, analyzer_symbol_ids: []const ?u32) Error!void {
        try self.symbol_ids.appendSlice(self.allocator, analyzer_symbol_ids);
    }

    // ================================================================
    // 공개 API
    // ================================================================

    /// 변환을 실행한다. 원본 AST의 마지막 노드(program)부터 시작.
    ///
    /// 반환값: 새 AST에서의 루트 NodeIndex.
    /// 변환된 AST는 self.ast에 저장된다.
    pub fn transform(self: *Transformer) Error!NodeIndex {
        var scope = @import("../profile.zig").begin(.transform);
        defer scope.end();

        // #1961: graph parse 단계의 pre-pass 가 이미 transform 한 ast 면 cached root 반환.
        // emitter 가 같은 ast 로 transformer 를 새로 만들 때 transform 을 다시 돌지 않도록.
        // caller 는 미리 transformer.runtime_helpers / .symbol_ids 를 module.transform_cache
        // 에서 hydrate 해 두어야 emit 시점에 동일한 결과 사용.
        if (self.ast.transformed_root) |cached| {
            return cached;
        }
        self.ast.assertInvariants();

        // worklet __pluginVersion 문자열 리터럴 span 사전 계산 (매 worklet당 할당 방지)
        if (self.options.worklet_plugin_version) |v| {
            const quoted = std.fmt.allocPrint(self.allocator, "\"{s}\"", .{v}) catch return Error.OutOfMemory;
            defer self.allocator.free(quoted);
            self.plugins.worklet.plugin_version_span = self.ast.addString(quoted) catch return Error.OutOfMemory;
        }

        // 파서의 마지막 노드가 루트 (program). parser_node_count - 1.
        const root_idx: NodeIndex = @enumFromInt(self.parser_node_count - 1);
        const saved_temp_counter = self.temp_var_counter;
        // worklet anonymous naming counter — Transformer 인스턴스 재사용 시 매 transform당 0부터 시작.
        self.plugins.worklet.anonymous_counter = 0;
        var root = try self.visitNode(root_idx);

        // Pass 2: ES2015 params lowering 일괄 적용
        if (self.options.unsupported.default_params) {
            try self.lowerAllFunctionParams();
        }

        // top-level 임시 변수 호이스팅: var _a, _b, ... 선언을 program 앞에 삽입
        if (self.temp_var_counter > saved_temp_counter and !root.isNone()) {
            root = try self.hoistTempVars(root, saved_temp_counter, self.ast.getNode(root_idx).span);
        }

        // ES2015 tagged template: _templateObject 캐싱 함수를 program 맨 앞에 호이스팅
        if (self.tagged_template_fns.items.len > 0 and !root.isNone()) {
            root = try self.prependStatementsToBody(root, self.tagged_template_fns.items);
        }

        // #1961: 사용된 runtime helper 별 named import statement 를 program 앞에 prepend.
        // graph parse 단계의 transformer pre-pass 가 set 하는 옵션으로만 활성 — emitter 의
        // in-place transformer 호출은 false 유지하여 helper specifier 가 출력에 새는 사고 방지.
        if (self.options.emit_runtime_helper_imports and !root.isNone()) {
            const helper_imports = @import("runtime_helper_imports.zig");
            const root_span = self.ast.getNode(root).span;
            var imports: std.ArrayList(NodeIndex) = .empty;
            defer imports.deinit(self.allocator);
            try helper_imports.appendHelperImports(self, self.runtime_helpers, root_span, &imports);
            if (imports.items.len > 0) {
                root = try self.prependStatementsToBody(root, imports.items);
            }
        }

        // React Fast Refresh: 컴포넌트 등록 코드를 프로그램 끝에 추가 ($RefreshReg$만, $RefreshSig$ 제거)
        if (self.options.react_refresh and self.plugins.refresh.registrations.items.len > 0) {
            root = try self.appendRefreshRegistrations(root);
        }

        self.ast.transformed_root = root;
        self.ast.assertInvariants();
        return root;
    }

    /// Pass 2: 모든 function-like 노드의 params를 일괄 lowering.
    /// Pass 1에서 생성된 모든 function_declaration, function_expression, function,
    /// method_definition 노드를 순회하며, default/rest/destructuring params가 있으면
    /// lowerParams를 적용하고 extra_data를 in-place 수정한다.
    fn lowerAllFunctionParams(self: *Transformer) Error!void {
        const node_count = self.ast.nodes.items.len;
        var i: usize = 0;
        while (i < node_count) : (i += 1) {
            const node = self.ast.nodes.items[i];
            switch (node.tag) {
                .function_declaration, .function_expression, .function, .method_definition => {
                    // extra layout: [name_or_key(0), params(1), body(2), ...]
                    const e = node.data.extra;
                    if (e + 2 >= self.ast.extra_data.items.len) continue;
                    const params_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
                    if (params_idx.isNone() or @intFromEnum(params_idx) >= self.ast.nodes.items.len) continue;
                    const params_node = self.ast.getNode(params_idx);
                    if (params_node.tag != .formal_parameters) continue;
                    const params_list = params_node.data.list;
                    if (params_list.len == 0) continue;
                    if (!es2015_params.ES2015Params(Transformer).hasDefaultOrRest(self, params_list)) continue;

                    var lr = try es2015_params.ES2015Params(Transformer).lowerParamsPass2(self, params_list, node.span);
                    defer lr.body_stmts.deinit(self.allocator);

                    // formal_parameters 노드를 새로 만들어 extras[e+1]에 연결.
                    // (여러 function 노드가 동일 params_idx를 공유할 수 있으므로 in-place mutation 금지:
                    //  prependToFunctionBody 등은 params_idx를 복사하여 새 function 노드를 만든다.)
                    const new_params_node = try self.ast.addFormalParameters(lr.new_params, params_node.span);
                    self.ast.extra_data.items[e + 1] = @intFromEnum(new_params_node);

                    if (lr.body_stmts.items.len > 0) {
                        const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
                        if (!body_idx.isNone()) {
                            const new_body = try self.prependStatementsToBody(body_idx, lr.body_stmts.items);
                            self.ast.extra_data.items[e + 2] = @intFromEnum(new_body);
                        }
                    }
                },
                else => {},
            }
        }
    }

    // ================================================================
    // 핵심 visitor — switch 기반 (D042)
    // ================================================================

    /// 노드 하나를 방문하여 새 AST에 복사/변환/스킵한다.
    ///
    /// 반환값:
    ///   - 변환된 노드의 새 인덱스
    ///   - .none이면 이 노드를 삭제(스킵)한다는 뜻
    /// 에러 타입. ArrayList의 append/ensureCapacity가 반환하는 에러.
    /// 재귀 함수에서 Zig가 에러 셋을 추론할 수 없으므로 명시적으로 선언.
    pub const Error = std.mem.Allocator.Error;

    pub fn visitNode(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        if (idx.isNone()) return .none;
        const new_idx = try self.visitNodeInner(idx);
        // symbol_id 전파: 원본 node_idx → 새 node_idx
        self.propagateSymbolId(idx, new_idx);
        return new_idx;
    }

    fn visitNodeInner(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        const node = self.ast.getNode(idx);

        // --------------------------------------------------------
        // 1단계: TS 타입 전용 노드는 통째로 삭제
        // --------------------------------------------------------
        if (self.options.strip_types and isTypeOnlyNode(node.tag)) {
            return .none;
        }

        // --------------------------------------------------------
        // 2단계: --drop 처리
        // --------------------------------------------------------
        if (self.options.drop_debugger and node.tag == .debugger_statement) {
            return .none;
        }
        if (self.options.drop_console and node.tag == .expression_statement) {
            if (self.isConsoleCall(node)) return .none;
        }
        if (self.options.drop_labels.len > 0 and node.tag == .labeled_statement) {
            const label_node = self.ast.getNode(node.data.binary.left);
            const label_name = self.ast.getText(label_node.span);
            for (self.options.drop_labels) |drop| {
                if (std.mem.eql(u8, label_name, drop)) return .none;
            }
        }

        // --------------------------------------------------------
        // 3단계: define 글로벌 치환
        // --------------------------------------------------------
        // worklet body 내부에서는 억제: UI 런타임은 bundler prelude의 polyfill 심볼을 모름.
        if (self.options.define.len > 0 and self.plugins.worklet.body_depth == 0) {
            if (self.tryDefineReplace(node)) |new_node| {
                return try new_node;
            }
        }

        // --------------------------------------------------------
        // 4단계: 태그별 분기 (switch 기반 visitor)
        // --------------------------------------------------------
        return switch (node.tag) {
            // === TS expressions: 타입 부분만 제거, 값 보존 ===
            .ts_as_expression,
            .ts_satisfies_expression,
            .ts_non_null_expression,
            .ts_type_assertion,
            .ts_instantiation_expression,
            .flow_as_expression,
            .flow_type_cast_expression,
            => self.visitTsExpression(idx),

            .flow_match_expression => self.visitFlowMatch(node),

            // Flow component with ref → function Name_withRef + const Name = React.forwardRef(...)
            .flow_component_wrapper => self.visitFlowComponentWrapper(node),

            // === 리스트 노드: 자식을 하나씩 방문하며 복사 ===
            .program => {
                // Plugin visitor 훅 선취권 (file-level worklet directive 등)
                if (try self.dispatchVisitor(.on_program, idx)) |replacement| return replacement;
                // ES2022 top-level await 다운레벨링: 미지원 타겟에서 async IIFE 로 wrap. (#1384)
                if (self.options.unsupported.top_level_await) {
                    if (try es2022_tla.lowerProgram(Transformer, self, node)) |wrapped| {
                        return wrapped;
                    }
                }
                const result = try self.visitListNode(idx);
                // styled-components cssProp transform 으로 추출된 module-level decl 들을
                // program body 끝에 hoist. trailing_nodes 가 nearest list (declarator list 등)
                // 에 들어가는 케이스 회피.
                const pending = &self.plugins.styled_components.css_prop_pending_decls;
                if (pending.items.len > 0) {
                    const result_node = self.ast.getNode(result);
                    const old_list = result_node.data.list;
                    const top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(top);
                    for (self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len]) |raw| {
                        try self.scratch.append(self.allocator, @as(NodeIndex, @enumFromInt(raw)));
                    }
                    for (pending.items) |decl_idx| {
                        try self.scratch.append(self.allocator, decl_idx);
                    }
                    const new_list = try self.ast.addNodeList(self.scratch.items[top..]);
                    pending.clearRetainingCapacity();
                    return self.ast.addNode(.{
                        .tag = .program,
                        .span = result_node.span,
                        .data = .{ .list = new_list },
                    });
                }
                return result;
            },
            .block_statement,
            .sequence_expression,
            .class_body,
            .formal_parameters,
            .function_body,
            => self.visitListNode(idx),

            // JSX — fragment는 .list, element/opening_element는 .extra
            .jsx_fragment => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXFragment(self, node);
                }
                return self.visitListNode(idx);
            },

            .template_literal => {
                if (self.options.unsupported.template_literal) {
                    return es2015_template.ES2015Template(Transformer).lowerTemplateLiteral(self, node);
                }
                // no-substitution template (data.none == 0)은 리프 노드 — visitListNode으로 처리하면
                // data.list = {start: X, len: 0}이 되어 codegen의 data.none == 0 체크가 깨짐
                if (node.data.none == 0) return self.copyNodeDirect(idx);
                return self.visitListNode(idx);
            },

            // array_expression: spread(ES2015) 다운레벨링
            .array_expression => {
                if (self.options.unsupported.spread) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadInArray(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadArray(self, node);
                    }
                }
                return self.visitListNode(idx);
            },

            // object_expression: spread(ES2018) / method shorthand / computed property(ES2015) 다운레벨링
            .object_expression => {
                // Plugin visitor 훅 — 기본 방문 전 선취권 (null 반환 시 default 진행)
                if (try self.dispatchVisitor(.on_object_expression, idx)) |replacement| return replacement;
                if (self.options.unsupported.object_spread) {
                    if (es2018.ES2018(Transformer).hasSpreadProperty(self, node)) {
                        return es2018.ES2018(Transformer).lowerObjectSpread(self, node);
                    }
                }
                // method shorthand → { key: function() {} } 를 먼저 처리.
                // function_expression 내부 async/generator lowering까지 visitNode 경로로 수행한 뒤,
                // computed key가 남아 있으면 아래 ES2015Computed가 후속 처리한다.
                if (self.options.unsupported.object_extensions) {
                    if (es2015_object_methods.ES2015ObjectMethods(Transformer).hasObjectMethod(self, node)) {
                        const lowered = try es2015_object_methods.ES2015ObjectMethods(Transformer).lowerObjectMethods(self, node);
                        const lowered_node = self.ast.getNode(lowered);
                        if (es2015_computed.ES2015Computed(Transformer).hasComputedProperty(self, lowered_node)) {
                            return es2015_computed.ES2015Computed(Transformer).lowerComputedProperties(self, lowered_node);
                        }
                        return lowered;
                    }
                }
                if (self.options.unsupported.object_extensions) {
                    if (es2015_computed.ES2015Computed(Transformer).hasComputedProperty(self, node)) {
                        return es2015_computed.ES2015Computed(Transformer).lowerComputedProperties(self, node);
                    }
                }
                return self.visitListNode(idx);
            },

            // JSX element/opening_element: .extra 형식 (tag, attrs, children)
            .jsx_element => {
                // `<ClassNames>{({css}) => ...}</ClassNames>` 진입 시 destructured `css`
                // 의 local 이름을 scope frame 에 push — render-prop 함수 안의
                // tagged_template_expression 이 visit 될 때 인식되도록.
                const pushed_emotion_scope = try emotion_mod.maybeEnterClassNamesScope(self, node);
                defer if (pushed_emotion_scope) emotion_mod.exitClassNamesScope(self);

                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXElement(self, node);
                }
                return self.visitJSXElement(node);
            },
            .jsx_opening_element => self.visitJSXOpeningElement(node),

            // === 단항 노드: 자식 1개 재귀 방문 ===
            .expression_statement => {
                // emotion `injectGlobal\`...\`;` 같은 expression-statement form 에 sourceMap
                // 적용. autoLabel 은 var 이름이 없어 미적용 — sourceMap 만 부여.
                if (self.options.emotion and self.options.emotion_source_map) {
                    const new_idx = try self.visitUnaryNode(idx);
                    return emotion_mod.maybeTransformExpressionStatement(self, new_idx);
                }
                return self.visitUnaryNode(idx);
            },
            .return_statement,
            .throw_statement,
            .spread_element,
            => self.visitUnaryNode(idx),
            .parenthesized_expression => {
                // (expr as T) → expr: TS expression이면 괄호 불필요
                const inner = node.data.unary.operand;
                if (!inner.isNone()) {
                    const inner_tag = self.ast.getNode(inner).tag;
                    if (inner_tag == .ts_as_expression or
                        inner_tag == .ts_satisfies_expression or
                        inner_tag == .ts_non_null_expression or
                        inner_tag == .ts_type_assertion or
                        inner_tag == .flow_as_expression or
                        inner_tag == .flow_type_cast_expression)
                    {
                        return self.visitNode(inner);
                    }
                }
                return self.visitUnaryNode(idx);
            },
            .await_expression => {
                if (self.options.unsupported.async_await) {
                    return es2017_mod.ES2017(Transformer).lowerAwaitExpression(self, node);
                }
                return self.visitUnaryNode(idx);
            },
            .yield_expression,
            .rest_element,
            .decorator,
            => self.visitUnaryNode(idx),
            // JSX
            .jsx_spread_attribute,
            .jsx_expression_container,
            => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXExpressionContainer(self, node);
                }
                return self.visitUnaryNode(idx);
            },
            .jsx_spread_child,
            .chain_expression,
            .computed_property_key,
            .break_statement,
            .continue_statement,
            .static_block,
            => self.visitUnaryNode(idx),

            // === 이항 노드: 자식 2개 재귀 방문 ===
            .binary_expression,
            .logical_expression,
            => {
                // ES 다운레벨링: ** → Math.pow (target < es2016)
                if (self.options.unsupported.exponentiation and node.tag == .binary_expression) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .star2) {
                        return es2016.ES2016(Transformer).lowerExponentiation(self, node);
                    }
                }
                // ES 다운레벨링: ?? → ternary
                if (self.options.unsupported.nullish_coalescing and node.tag == .logical_expression) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .question2) {
                        return es2020.ES2020(Transformer).lowerNullishCoalescing(self, node);
                    }
                }
                // ES2022 Ergonomic Brand Checks: #x in obj → _x.has(obj) 등
                // private mapping이 설정돼 있을 때만 변환 (class 다운레벨 경로가 활성화된 경우).
                if (node.tag == .binary_expression and
                    (self.current_private_fields.len > 0 or self.current_private_methods.len > 0))
                {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .kw_in) {
                        if (es2015_class.ES2015Class(Transformer).lowerPrivateIn(self, node)) |result| {
                            return result;
                        }
                    }
                }
                return self.visitBinaryNode(idx);
            },
            .assignment_expression => {
                // ES2015: super.x = v / super.x += v / super.x ||= v 는
                // Parent.prototype.x 직접 접근이 아니라 receiver(this)를 보존하는 get/set
                // 헬퍼로 먼저 lowering한다. 이후 generic logical/compound lowering으로 넘기면
                // helper call에 대입하는 잘못된 target이 생성된다.
                if (self.needsSuperLowering()) {
                    if (es2015_class.ES2015Class(Transformer).lowerSuperPropertyAssignment(self, node)) |result| {
                        return result;
                    }
                }
                // Private field 좌변은 모든 assignment 연산자(=, +=, ??=, ||=, &&= ...)를
                // lowerPrivateFieldSet 단일 경로에서 처리 — es2021/es2016 등은 좌변에
                // `(a = b)` 패턴을 만들어 get()/helper call에 대입하게 되므로 먼저 가로챈다.
                // (esbuild의 lowerAssign이나 SWC/Babel plugin 순서와 동일한 선점 패턴.)
                if (self.hasActivePrivateFieldLowering()) {
                    const left_idx = node.data.binary.left;
                    if (!left_idx.isNone()) {
                        const left_node = self.ast.getNode(left_idx);
                        if (left_node.tag == .private_field_expression) {
                            if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldSet(self, node)) |result| {
                                return result;
                            }
                        }
                    }
                }
                // ES 다운레벨링: **= → a = Math.pow(a, b) (es2016)
                if (self.options.unsupported.exponentiation) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .star2_eq) {
                        return es2016.ES2016(Transformer).lowerExponentiationAssignment(self, node);
                    }
                }
                // ES 다운레벨링: ??=, ||=, &&= (es2021)
                if (self.options.unsupported.logical_assignment) {
                    const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                    if (op == .question2_eq) {
                        return es2021.ES2021(Transformer).lowerNullishAssignment(self, node);
                    } else if (op == .pipe2_eq) {
                        return es2021.ES2021(Transformer).lowerLogicalAssignment(self, node, .pipe2);
                    } else if (op == .amp2_eq) {
                        return es2021.ES2021(Transformer).lowerLogicalAssignment(self, node, .amp2);
                    }
                }
                // ES2015: assignment destructuring → sequence expression.
                // destructuring 자체가 지원되더라도 target에 private field가 있으면 강제 lowering —
                // 일반 visit 경로가 `this.#x` 를 `_x.get(this)` 로 만들어 invalid assignment target이 됨 (#1485).
                {
                    const left_idx = node.data.binary.left;
                    if (!left_idx.isNone()) {
                        const left_node = self.ast.getNode(left_idx);
                        if (left_node.tag == .object_assignment_target or left_node.tag == .array_assignment_target) {
                            const has_private = self.current_private_fields.len > 0 and
                                es2015_class.ES2015Class(Transformer).destructuringTargetHasPrivateField(self, left_idx);
                            if (self.options.unsupported.destructuring or has_private) {
                                return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringAssignment(self, node);
                            }
                        }
                    }
                }
                // styled-components: `Component = styled.div\`...\`` 도 wrap 대상.
                // visitBinaryNode 결과의 right 가 styled tagged template 이면 LHS identifier
                // 이름을 displayName 으로 사용해 wrap. =, +=, ||= 등 모든 연산자에서 동작
                // (의미상 = 만 styled component 할당이지만 가드 추가 비용 vs 자연스러운 케이스
                // 커버 trade-off — 비-= 연산자 + tagged template 조합은 거의 없음).
                if (self.options.styled_components and self.plugins.styled_components.default_binding != null) {
                    const new_idx = try self.visitBinaryNode(idx);
                    return styled_components_mod.maybeWrapAssignment(self, new_idx);
                }
                return self.visitBinaryNode(idx);
            },
            .while_statement,
            .do_while_statement,
            .with_statement,
            // JSX
            .jsx_attribute,
            .jsx_namespaced_name,
            .jsx_member_expression,
            // ES2024: import(x, opts) — binary { left=arg, right=options }
            .import_expression,
            => self.visitBinaryNode(idx),

            // === member expression: extra = [object, property, flags] ===
            .static_member_expression => {
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.unsupported.optional_chaining) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super.method → Parent.prototype.method
                if (self.needsSuperLowering()) {
                    if (es2015_class.ES2015Class(Transformer).isSuperMember(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperMember(self, node);
                    }
                }
                return self.visitMemberExpression(node);
            },
            .private_field_expression => {
                // 순서 중요: `?.` 를 먼저 ternary 로 풀어야 한다. 아래의 lowerPrivateMethodGet /
                // lowerPrivateFieldGet 이 만든 `_x.get(this)` 호출이 `?.` short-circuit 안에 들어가면
                // base 가 null/undefined 일 때도 evaluate 되어 spec 위반이다.
                // class_private_field 가 lowering 대상이면 target 이 ES2020+ 라도 chain 자체를
                // 미리 풀어야 같은 회피가 가능 — `unsupported.optional_chaining` 만으로는 부족.
                if (self.options.unsupported.optional_chaining or self.hasActivePrivateFieldLowering()) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2022: this.#method → _method_fn.bind(this) (참조만, 호출 아닌 경우)
                if (self.current_private_methods.len > 0) {
                    if (es2022.ES2022(Transformer).lowerPrivateMethodGet(self, node)) |result| {
                        return result;
                    }
                }
                // ES2015/ES2022: this.#x → _x.get(this)
                if (self.hasActivePrivateFieldLowering()) {
                    if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldGet(self, node)) |result| {
                        return result;
                    }
                }
                return self.visitMemberExpression(node);
            },
            .computed_member_expression => {
                // ES 다운레벨링: ?. → ternary (target < es2020)
                if (self.options.unsupported.optional_chaining) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super["prop"] → Parent.prototype["prop"]
                if (self.needsSuperLowering()) {
                    if (es2015_class.ES2015Class(Transformer).isSuperComputedMember(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperComputedMember(self, node);
                    }
                }
                return self.visitMemberExpression(node);
            },

            // === unary/update expression: extra = [operand, operator_and_flags] ===
            .unary_expression,
            .update_expression,
            => self.visitUnaryExtra(node),

            // === 삼항 노드: 자식 3개 재귀 방문 ===
            .if_statement, .conditional_expression, .for_in_statement => {
                if (node.tag == .for_in_statement and self.current_private_fields.len > 0) {
                    if (try self.tryLowerForInOfPrivateTarget(node)) |result| return result;
                }
                if (self.options.unsupported.destructuring) {
                    // for (var [i,j,k] in obj) → for (var _ref in obj) { var i=_ref[0],...; body }
                    const left = node.data.ternary.a;
                    if (!left.isNone()) {
                        const left_node = self.ast.getNode(left);
                        if (left_node.tag == .variable_declaration and
                            es2015_destructuring.ES2015Destructuring(Transformer).hasDestructuring(self, left_node))
                        {
                            return es2015_destructuring.ES2015Destructuring(Transformer).lowerForInDestructuring(self, node);
                        }
                    }
                }
                return self.visitForInOfTernary(node);
            },
            .try_statement,
            => self.visitTernaryNode(node),
            .for_await_of_statement => {
                // for-await 키워드는 ES2018. ES2018 미만 타겟에서는 async function 자체를
                // 보존하더라도 for-await 구문만 __asyncValues + while 로 제거해야 한다.
                if (self.options.unsupported.needsForAwaitOfDownlevel()) {
                    return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOf(self, node);
                }
                return self.visitForInOfTernary(node);
            },
            .for_of_statement => {
                // private field target은 그대로 두면 `for (_x.get(this) of arr)` → invalid.
                // 임시 binding + body prefix assignment 패턴으로 변환 (#1491).
                if (self.current_private_fields.len > 0) {
                    if (try self.tryLowerForInOfPrivateTarget(node)) |result| return result;
                }
                if (self.options.unsupported.for_of) {
                    return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatement(self, node);
                }
                return self.visitForInOfTernary(node);
            },
            .labeled_statement => {
                // for-of/for-await-of를 block으로 lowering할 때, label이 block에 남으면
                // 바디의 `continue LABEL` 이 iteration statement를 못 찾는다.
                // label을 lowered inner while/for_statement에 직접 부여해 이를 회피.
                const child_idx = node.data.binary.right;
                if (!child_idx.isNone()) {
                    const child = self.ast.getNode(child_idx);
                    if (self.options.unsupported.needsForAwaitOfDownlevel() and child.tag == .for_await_of_statement) {
                        const new_label = try self.visitNode(node.data.binary.left);
                        return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOfLabeled(self, child, new_label);
                    }
                    if (self.options.unsupported.for_of and child.tag == .for_of_statement) {
                        const new_label = try self.visitNode(node.data.binary.left);
                        return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatementLabeled(self, child, new_label);
                    }
                }
                return self.visitBinaryNode(idx);
            },

            // === extra 기반 노드: 별도 처리 ===
            .variable_declaration => self.visitVariableDeclaration(node),
            .variable_declarator => self.visitVariableDeclarator(node),
            .function_declaration,
            .function_expression,
            => {
                const e = node.data.extra;
                const flags = self.readU32(e, ast_mod.FunctionExtra.flags);
                if (self.options.unsupported.async_await and (flags & ast_mod.FunctionFlags.is_async) != 0) {
                    // async generator (`async function*`) → __asyncGenerator wrapper. (#1911)
                    if ((flags & ast_mod.FunctionFlags.is_generator) != 0) {
                        return es2017_mod.ES2017(Transformer).lowerAsyncGeneratorToStateMachine(self, node);
                    }
                    // async + generator 둘 다 unsupported → 직접 state machine 생성
                    if (self.options.unsupported.generator) {
                        return es2017_mod.ES2017(Transformer).lowerAsyncToStateMachine(self, node);
                    }
                    return es2017_mod.ES2017(Transformer).lowerAsyncFunction(self, node);
                }
                if (self.options.unsupported.generator and (flags & ast_mod.FunctionFlags.is_generator) != 0) {
                    return es2015_generator.ES2015Generator(Transformer).lowerGeneratorFunction(self, node);
                }
                return self.visitFunction(node);
            },
            .function,
            => self.visitFunction(node),
            .arrow_function_expression => {
                if (self.options.unsupported.async_await) {
                    const extras = self.ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 < extras.len and (extras[e + 2] & ast_mod.ArrowFlags.is_async) != 0) {
                        // async + generator 둘 다 unsupported → 직접 state machine 생성
                        if (self.options.unsupported.generator) {
                            return es2017_mod.ES2017(Transformer).lowerAsyncArrowToStateMachine(self, node);
                        }
                        return es2017_mod.ES2017(Transformer).lowerAsyncArrow(self, node);
                    }
                }
                if (self.options.unsupported.arrow) {
                    return es2015_arrow.ES2015Arrow(Transformer).lowerArrowFunction(self, node);
                }
                return self.visitArrowFunction(node);
            },
            .class_declaration => {
                const replacement_idx = try self.dispatchVisitor(.on_class_declaration, idx);
                const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
                // Stage 3 decorator는 unsupported.class 분기보다 먼저 돌려야 한다 — 반대면 decorator가 silent drop.
                // 이름 있는 class_declaration은 Stage 3 내부에서 outer_var_decl을 pending_nodes로 hoist하고
                // `.none`을 반환하므로, export_named/default declaration이 이름을 감지해 `export { X };` 또는
                // `export default X;` 형태로 분리한다 (#1538). 익명/class_expression은 iife_call을 직접 반환해
                // 아래 visitNode 재방문이 arrow/let/static block을 ES5로 마저 다운레벨링한다.
                if (try self.tryTransformStage3(target_node)) |stage3_result| {
                    if (self.options.unsupported.class) return self.visitNode(stage3_result);
                    return stage3_result;
                }
                if (self.options.unsupported.class) {
                    return es2015_class.ES2015Class(Transformer).lowerClassDeclaration(self, target_node);
                }
                if (replacement_idx) |r| return r;
                return self.visitClass(node);
            },
            .class_expression => {
                const replacement_idx = try self.dispatchVisitor(.on_class_expression, idx);
                const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
                if (try self.tryTransformStage3(target_node)) |stage3_result| {
                    if (self.options.unsupported.class) return self.visitNode(stage3_result);
                    return stage3_result;
                }
                if (self.options.unsupported.class) {
                    return es2015_class.ES2015Class(Transformer).lowerClassExpression(self, target_node);
                }
                if (replacement_idx) |r| return r;
                return self.visitClass(node);
            },
            .for_statement => self.visitForStatement(node),
            .switch_statement => self.visitSwitchStatement(node),
            .switch_case => self.visitSwitchCase(node),
            .call_expression => {
                // ES2022: this.#method(args) → _method_fn.call(this, args)
                if (self.current_private_methods.len > 0) {
                    if (es2022.ES2022(Transformer).lowerPrivateMethodCall(self, node)) |result| {
                        return result;
                    }
                }
                // ES 다운레벨링: ?.() → ternary (target < es2020)
                if (self.options.unsupported.optional_chaining) {
                    if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                        return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                    }
                }
                // ES2015: super(args) → Parent.call(this, args)
                // ES2015: super.method(args) → Parent.prototype.method.call(this, args)
                if (self.needsSuperLowering()) {
                    if (es2015_class.ES2015Class(Transformer).isSuperCall(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperCall(self, node);
                    }
                    if (es2015_class.ES2015Class(Transformer).isSuperMethodCall(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperMethodCall(self, node);
                    }
                    if (es2015_class.ES2015Class(Transformer).isSuperComputedMethodCall(self, node)) {
                        return es2015_class.ES2015Class(Transformer).lowerSuperComputedMethodCall(self, node);
                    }
                }
                // Plugin visitor 훅 — web-check 치환 등
                if (try self.dispatchVisitor(.on_call_expression, idx)) |replacement| return replacement;
                // ES2015: spread in call → .apply()
                if (self.options.unsupported.spread) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadArg(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadCall(self, node);
                    }
                }
                return self.visitCallExpression(node);
            },
            .new_expression => {
                if (self.options.unsupported.spread) {
                    if (es2015_spread.ES2015Spread(Transformer).hasSpreadArg(self, node)) {
                        return es2015_spread.ES2015Spread(Transformer).lowerSpreadNew(self, node);
                    }
                }
                return self.visitNewExpression(node);
            },
            .tagged_template_expression => self.visitTaggedTemplate(node),
            .method_definition => self.visitMethodDefinition(node),
            .property_definition => self.visitPropertyDefinition(node),
            .object_property => self.visitObjectProperty(node),
            .formal_parameter => self.visitFormalParameter(node),
            .import_declaration => self.visitImportDeclaration(node),
            .export_named_declaration => self.visitExportNamedDeclaration(node),
            .export_default_declaration => self.visitExportDefaultDeclaration(node),
            .export_all_declaration => self.visitExportAllDeclaration(node),
            .catch_clause => {
                if (self.options.unsupported.optional_catch_binding) {
                    return es2019.ES2019(Transformer).lowerOptionalCatchBinding(self, node);
                }
                return self.visitBinaryNode(idx);
            },
            .binding_property,
            .assignment_pattern,
            => self.visitBinaryNode(idx),
            .accessor_property => self.visitAccessorProperty(node),

            // === 리프 노드: 그대로 복사 (자식 없음) ===
            // this_expression: static block 안에서 클래스 이름으로 치환 가능
            .this_expression => {
                // ES2022 static block 다운레벨링 중이고, 일반 함수 안이 아니면 치환
                if (self.static_block_class_name) |class_span| {
                    if (self.this_depth == 0) {
                        return self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = class_span,
                            .data = .{ .string_ref = class_span },
                        });
                    }
                }
                // ES2015 arrow this 캡처: arrow body 안의 this → _this
                if (self.options.unsupported.arrow and self.arrow_this_depth > 0) {
                    self.needs_this_var = true;
                    return es_helpers.makeIdentifierRef(self, "_this");
                }
                // ES2015 class super() 후 this → _this
                if (self.super_call_this_alias) {
                    const helper = try es_helpers.makeRuntimeHelperRef(self, "__assertThisInitialized");
                    const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
                    self.runtime_helpers.derived_constructor = true;
                    return es_helpers.makeCallExpr(self, helper, &.{this_ref}, node.span);
                }
                return self.copyNodeDirect(idx);
            },

            // meta_property: new.target / import.meta
            .meta_property => {
                // new.target (data.none == 1) 다운레벨링
                if (node.data.none == 1 and self.options.unsupported.new_target) {
                    return self.lowerNewTarget(node.span);
                }
                return self.copyNodeDirect(idx);
            },

            .boolean_literal,
            .null_literal,
            .numeric_literal,
            .bigint_literal,
            => self.copyNodeDirect(idx),
            .string_literal => blk: {
                if (!self.options.unsupported.unicode_brace_escape) break :blk self.copyNodeDirect(idx);
                const raw = self.ast.getText(node.span);
                // raw는 따옴표를 포함. content 만 변환 후 다시 조립.
                if (raw.len < 2) break :blk self.copyNodeDirect(idx);
                const quote = raw[0];
                if (quote != '"' and quote != '\'') break :blk self.copyNodeDirect(idx);
                const content = raw[1 .. raw.len - 1];
                const lowered = (try unicode_escape_lower.lowerContent(self.allocator, content)) orelse break :blk self.copyNodeDirect(idx);
                defer self.allocator.free(lowered);
                const new_raw = try std.fmt.allocPrint(self.allocator, "{c}{s}{c}", .{ quote, lowered, quote });
                defer self.allocator.free(new_raw);
                const new_span = try self.ast.addString(new_raw);
                break :blk try self.ast.addNode(.{
                    .tag = .string_literal,
                    .span = new_span,
                    .data = .{ .string_ref = new_span },
                });
            },
            .regexp_literal => blk: {
                const u = self.options.unsupported;
                if (!(u.regex_dotall or u.regex_named_groups or u.regex_sticky or u.unicode_brace_escape)) {
                    break :blk self.copyNodeDirect(idx);
                }
                const raw = self.ast.getText(node.span);
                const result = try regex_lower.lower(self.allocator, raw, .{ .unsupported = u });
                const new_text = result.text orelse break :blk self.copyNodeDirect(idx);
                defer self.allocator.free(new_text);
                const new_span = try self.ast.addString(new_text);
                break :blk try self.ast.addNode(.{
                    .tag = .regexp_literal,
                    .span = new_span,
                    .data = .{ .string_ref = new_span },
                });
            },
            .identifier_reference => {
                // ES2015 arrow arguments 캡처: arrow body 안의 arguments → _arguments
                if (self.options.unsupported.arrow and self.arrow_this_depth > 0) {
                    const text = self.ast.getText(node.data.string_ref);
                    if (std.mem.eql(u8, text, "arguments")) {
                        self.needs_arguments_var = true;
                        const args_span = try self.ast.addString("_arguments");
                        const new_idx = try self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = args_span,
                            .data = .{ .string_ref = args_span },
                        });
                        self.propagateSymbolId(idx, new_idx);
                        return new_idx;
                    }
                }
                if (try self.tryRenameIdentifierLike(idx, .identifier_reference)) |i| return i;
                return self.copyNodeDirect(idx);
            },
            .binding_identifier => {
                if (try self.tryRenameIdentifierLike(idx, .binding_identifier)) |i| return i;
                return self.copyNodeDirect(idx);
            },
            .assignment_target_identifier => {
                if (try self.tryRenameIdentifierLike(idx, .assignment_target_identifier)) |i| return i;
                return self.copyNodeDirect(idx);
            },
            .template_element => blk: {
                if (!self.options.unsupported.unicode_brace_escape) break :blk self.copyNodeDirect(idx);
                const raw = self.ast.getText(node.span);
                const lowered = (try unicode_escape_lower.lowerContent(self.allocator, raw)) orelse break :blk self.copyNodeDirect(idx);
                defer self.allocator.free(lowered);
                const new_span = try self.ast.addString(lowered);
                break :blk try self.ast.addNode(.{
                    .tag = .template_element,
                    .span = new_span,
                    .data = node.data,
                });
            },
            .private_identifier,
            .empty_statement,
            .debugger_statement,
            .directive,
            .hashbang,
            .super_expression,
            .elision,
            .jsx_empty_expression,
            .jsx_identifier,
            .jsx_closing_element,
            .jsx_opening_fragment,
            .jsx_closing_fragment,
            => self.copyNodeDirect(idx),

            // JSX leaf — jsx_text는 별도 처리 (jsx_transform 시 lowerJSXText)
            .jsx_text => {
                if (self.options.jsx_transform) {
                    return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXText(self, node);
                }
                return self.copyNodeDirect(idx);
            },

            // === import/export specifiers ===
            // #1791 Phase D: inline `type` modifier (SPEC_FLAG_TYPE_ONLY) 또는 named specifier 의
            // value-ref 0 (type 위치에서만 사용) 이면 elide. visitExtraList 가 `.none` 을
            // 필터링. default/namespace 는 JSX pragma 등 implicit value use 위험이 커
            // `shouldElideImportSpecifier` 에서 이미 false 를 반환하므로 elision 비활성.
            .import_specifier => blk: {
                if ((node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) break :blk NodeIndex.none;
                if (self.shouldElideImportSpecifier(idx, node)) break :blk NodeIndex.none;
                break :blk self.visitBinaryNode(idx);
            },
            .export_specifier => if ((node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) .none else self.visitBinaryNode(idx),
            // default/namespace specifier는 string_ref(span) 복사 — 자식 노드 없음
            .import_default_specifier,
            .import_namespace_specifier,
            .import_attribute,
            => self.copyNodeDirect(idx),

            // === Pattern 노드: 자식 재귀 방문 ===
            .array_pattern,
            .object_pattern,
            .array_assignment_target,
            .object_assignment_target,
            => self.visitListNode(idx),

            .binding_rest_element,
            .assignment_target_rest,
            => self.visitUnaryNode(idx),
            .assignment_target_with_default,
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            => self.visitBinaryNode(idx),
            // assignment_target_identifier: string_ref → 변환 불필요 (identifier와 동일)

            // === TS enum/namespace: 런타임 코드 생성 (codegen에서 IIFE 출력) ===
            .ts_enum_declaration => self.visitEnumDeclaration(node),
            .ts_enum_member => self.visitBinaryNode(idx),
            .ts_enum_body => self.visitListNode(idx),
            // === Flow enum (#2401): codegen 에서 Object.freeze({...}) 출력. members 의
            // init expression 만 visit 필요 (다른 변환 영향 없음).
            .flow_enum_declaration => self.visitFlowEnumDeclaration(node),
            .flow_enum_member => self.visitBinaryNode(idx),
            .ts_module_declaration => self.visitNamespaceDeclaration(node),
            .ts_module_block => self.visitListNode(idx),

            // import x = require('y') → const x = require('y')
            .ts_import_equals_declaration => self.visitImportEqualsDeclaration(node),

            // export = expr → module.exports = expr;
            .ts_export_assignment => self.visitExportAssignment(node),

            // === 나머지: invalid + TS 타입 전용 노드 ===
            // TS 타입 노드는 isTypeOnlyNode 검사(위)에서 이미 .none으로 반환됨.
            // 여기 도달하면 strip_types=false인 경우 → 그대로 복사.
            .invalid => .none,
            else => self.copyNodeDirect(idx),
        };
    }

    // ================================================================
    // 노드 복사 헬퍼
    // ================================================================

    /// 리프/불변 노드를 identity 로 반환한다 — 새 NodeIndex 를 할당하지 않음.
    /// 통합 AST 에서는 parser/transformer 가 같은 배열을 공유하므로 old_idx 그대로
    /// 유효하며, Symbol 의 NodeIndex 필드(`single_read_node` 등)가 stale 되지 않는다.
    /// 내용이 변하는 리프(unicode escape lowering 등)는 여전히 `self.ast.addNode`
    /// 로 새 노드를 만들어야 한다 — 이 함수는 "값 그대로 복제" 경로 전용.
    pub fn copyNodeDirect(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        _ = self;
        return idx;
    }

    /// ES2015 block scoping 격리: outer scope 와 충돌하는 inner `let`/`const` 가
    /// `block_rename_stack` 에 등록되어 있으면 `name$N` 으로 치환된 새 노드 반환.
    /// identifier_reference / binding_identifier / assignment_target_identifier 가 공유.
    /// 호출 후 새 노드의 symbol_id 를 반드시 전파 — 누락 시 linker rename 미적용으로
    /// 정의/사용 비대칭 (`acc = acc$1 + n` 같은 strict-mode ReferenceError) 발생.
    fn tryRenameIdentifierLike(
        self: *Transformer,
        idx: NodeIndex,
        comptime tag: Tag,
    ) Error!?NodeIndex {
        if (!self.options.unsupported.block_scoping) return null;
        if (self.block_rename_stack.items.len == 0) return null;
        const node = self.ast.getNode(idx);
        const text = self.ast.getText(node.data.string_ref);
        const new_name = self.lookupBlockRename(text) orelse return null;
        const new_span = try self.ast.addString(new_name);
        const new_idx = try self.ast.addNode(.{
            .tag = tag,
            .span = new_span,
            .data = .{ .string_ref = new_span },
        });
        self.propagateSymbolId(idx, new_idx);
        return new_idx;
    }

    /// 클래스 이름 노드에서 Span 추출. 익명 클래스(none)면 null 반환.
    /// ES2022 static block의 this → 클래스 이름 치환에 사용.
    pub fn getClassNameSpan(self: *Transformer, name_idx: NodeIndex) ?Span {
        if (name_idx.isNone()) return null;
        return self.ast.getNode(name_idx).data.string_ref;
    }

    /// symbol_ids를 target_idx까지 null로 확장.
    fn ensureSymbolIds(self: *Transformer, target_idx: usize) void {
        if (self.symbol_ids.items.len <= target_idx) {
            const needed = target_idx + 1 - self.symbol_ids.items.len;
            self.symbol_ids.appendNTimes(self.allocator, null, needed) catch return;
        }
    }

    /// 파서 노드 → 트랜스포머 노드로 symbol_id 전파.
    /// 통합 AST에서는 old_idx와 new_idx가 같은 배열의 인덱스.
    pub fn propagateSymbolId(self: *Transformer, old_idx: NodeIndex, new_idx: NodeIndex) void {
        if (self.symbol_ids.items.len == 0) return; // 전파 비활성
        if (new_idx.isNone()) return;

        const old_i = @intFromEnum(old_idx);
        const new_i = @intFromEnum(new_idx);

        self.ensureSymbolIds(new_i);

        if (old_i < self.symbol_ids.items.len) {
            // ts_as_expression 등 wrapper 노드가 내부 노드와 같은 new_idx를 반환하면
            // wrapper의 null symbol_id가 내부 노드의 유효한 symbol_id를 덮어쓸 수 있음.
            // 이미 유효한 symbol_id가 설정되어 있으면 null로 덮어쓰지 않음.
            if (self.symbol_ids.items[old_i] != null or self.symbol_ids.items[new_i] == null) {
                self.symbol_ids.items[new_i] = self.symbol_ids.items[old_i];
            }
        }
    }

    /// AST 내에서 노드 간 symbol_id 복사.
    /// 노드 복제 시 symbol_id가 누락되지 않도록 사용.
    pub fn copySymbolId(self: *Transformer, src_idx: NodeIndex, dst_idx: NodeIndex) void {
        if (self.symbol_ids.items.len == 0) return;
        if (src_idx.isNone() or dst_idx.isNone()) return;

        const src_i = @intFromEnum(src_idx);
        const dst_i = @intFromEnum(dst_idx);

        self.ensureSymbolIds(dst_i);

        if (src_i < self.symbol_ids.items.len) {
            if (self.symbol_ids.items[src_i]) |sid| {
                self.symbol_ids.items[dst_i] = sid;
            }
        }
    }

    /// span + old_idx로 identifier_reference 생성 + symbol_id 전파.
    /// ES5 class lowering, decorator 등에서 renamed 이름이 반영되도록 사용.
    pub fn makeIdentifierRefWithSymbol(self: *Transformer, name_span: Span, old_idx: NodeIndex) Error!NodeIndex {
        const ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
        self.propagateSymbolId(old_idx, ref);
        return ref;
    }

    /// JSX → `React.createElement` 변환처럼 transformer 가 *원본 AST 에 없는*
    /// 식별자 노드를 만들 때, 그 이름으로 root scope (module/global) 의 binding
    /// 을 lookup 하여 symbol_id 를 attach 한다 (#2196).
    ///
    /// 이렇게 해야 mangler/linker 가 원본 binding 의 rename 결과를 새 노드에도
    /// 그대로 반영. lookup 실패 시 (해당 이름의 root binding 없음) 그냥 패스 —
    /// 원본 그대로 emit 됨.
    ///
    /// **Limitation**: root scope (scope_id=0) 만 검색. 함수 안에서 declare 한
    /// `function f() { const React = ...; return <div/>; }` 같은 shadowed binding
    /// 은 미지원 — JSX runtime 식별자가 함수 스코프에 있으면 lookup 실패 후
    /// silent fallback 으로 원본 이름 그대로 emit. 외부에 동일 이름 root binding
    /// 이 있으면 mangle 불일치 발생 가능. 실세계 React 코드 패턴이 거의 항상
    /// module/global level 이라 의도된 trade-off.
    ///
    /// linear scan 이지만 호출 빈도 (factory head 식별자만) 가 낮아 비용 무시할
    /// 수준. 측정 후 필요하면 root scope sym map caching 으로 follow-up.
    pub fn attachRootScopeSymbolByName(self: *Transformer, node_idx: NodeIndex, name: []const u8) void {
        if (self.symbols.len == 0) return;
        if (self.symbol_ids.items.len == 0) return;
        if (node_idx.isNone()) return;

        for (self.symbols, 0..) |sym, i| {
            if (sym.scope_id.isNone()) continue;
            if (sym.scope_id.toIndex() != 0) continue;
            const sym_name = sym.nameText(self.ast.source);
            if (std.mem.eql(u8, sym_name, name)) {
                const ni = @intFromEnum(node_idx);
                self.ensureSymbolIds(ni);
                if (ni < self.symbol_ids.items.len) {
                    self.symbol_ids.items[ni] = @intCast(i);
                }
                return;
            }
        }
    }

    /// 단항 노드: operand를 재귀 방문 후 복사.
    fn visitUnaryNode(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        const node = self.ast.getNode(idx);
        const old_operand = node.data.unary.operand;
        const new_operand = try self.visitNode(old_operand);
        // 자식 unchanged → 부모도 identity. ast.addNode 호출 제거.
        if (new_operand == old_operand) return idx;
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
        });
    }

    /// 이항 노드: left, right를 재귀 방문 후 복사.
    fn visitBinaryNode(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        const node = self.ast.getNode(idx);
        const old_left = node.data.binary.left;
        const old_right = node.data.binary.right;
        const new_left = try self.visitNode(old_left);
        const new_right = try self.visitNode(old_right);
        if (new_left == old_left and new_right == old_right) return idx;
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .binary = .{
                .left = new_left,
                .right = new_right,
                .flags = node.data.binary.flags,
            } },
        });
    }

    // ES 다운레벨링 헬퍼 — es_helpers.zig로 위임 (Transformer 메서드 호환)
    fn makeTempVarSpan(self: *Transformer) Error!Span {
        return es_helpers.makeTempVarSpan(self);
    }
    fn isSimpleIdentifier(self: *Transformer, left_idx: NodeIndex) bool {
        return es_helpers.isSimpleIdentifier(self, left_idx);
    }

    // ES 다운레벨링 함수는 es2020.zig, es2021.zig, es_helpers.zig로 분리됨.

    /// unary/update expression: extra = [operand, operator_and_flags]
    fn visitUnaryExtra(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 1 >= self.ast.extra_data.items.len) return NodeIndex.none;

        const operand_idx = self.readNodeIdx(e, 0);
        const op_flags = self.readU32(e, 1);

        // private field update: this.#x++ → _x.set(this, _x.get(this) + 1)
        if (node.tag == .update_expression and (self.options.unsupported.class or self.options.unsupported.class_private_field)) {
            const operand = self.ast.getNode(operand_idx);
            if (self.needsSuperLowering()) {
                if (es2015_class.ES2015Class(Transformer).lowerSuperPropertyUpdate(self, operand, op_flags, node.span)) |result| {
                    return try result;
                }
            }
            if (operand.tag == .private_field_expression) {
                if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldUpdate(self, operand, op_flags, node.span)) |result| {
                    return try result;
                }
            }
        }

        // `delete obj?.a?.b` lowering: 일반 optional chain lowering 결과인
        // `delete (cond ? void 0 : _a.b)` 는 ConditionalExpression이라 Reference가 아니어서 실제 삭제 안 됨.
        // → `cond ? true : delete _a.b` 형태로 별도 lowering.
        if (node.tag == .unary_expression and self.options.unsupported.optional_chaining and
            (op_flags & 0xff) == @intFromEnum(token_mod.Kind.kw_delete))
        {
            const operand = self.ast.getNode(operand_idx);
            if (es2020.ES2020(Transformer).findOptionalChainBase(self, operand)) |base_idx| {
                return es2020.ES2020(Transformer).lowerOptionalChainCtx(self, operand, base_idx, .delete);
            }
        }

        const new_operand = try self.visitNode(operand_idx);
        const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_operand), op_flags });
        return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    pub const visitTaggedTemplate = tagged_template_mod.visitTaggedTemplate;

    /// member expression: extra = [object, property, flags]
    pub fn visitMemberExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;

        // const enum 인라인: `EnumName.Member` → literal
        if (try self.tryInlineConstEnumMember(node)) |inlined| return inlined;

        const left_idx = self.readNodeIdx(e, 0);
        const right_idx = self.readNodeIdx(e, 1);
        const flags = self.readU32(e, 2);
        const new_left = try self.visitNode(left_idx);
        // computed_member: right는 임의 expression. static_member/private_field: right는 식별자 리프.
        // visitNode가 리프를 copyNodeDirect로 처리하므로 동일하게 visitNode 호출.
        const new_right = try self.visitNode(right_idx);
        const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_left), @intFromEnum(new_right), flags });
        return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// 삼항 노드: a, b, c를 재귀 방문 후 복사.
    fn visitTernaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_a = try self.visitNode(node.data.ternary.a);
        const new_b = try self.visitNode(node.data.ternary.b);
        const new_c = try self.visitNode(node.data.ternary.c);
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
        });
    }

    /// for-in/for-of/for-await-of 헤더 전용 ternary visit.
    /// `a`(left) 방문 시 in_for_in_of_header 플래그를 켜서, block_scoping 다운레벨로
    /// let/const → var 변환 시 불필요한 `= void 0` init 주입을 막는다 (#1386).
    fn visitForInOfTernary(self: *Transformer, node: Node) Error!NodeIndex {
        if (self.options.unsupported.block_scoping) {
            const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
            var lexical_names = try BlockScoping.collectLexicalVarNames(self, node.data.ternary.a);
            defer lexical_names.deinit(self.allocator);

            if (lexical_names.items.len > 0) {
                const orig_body_idx = node.data.ternary.c;
                // 원본 AST 에서 capture 검사 — visitNode 가 closure 경계를 변환하기 전 시점.
                const has_capture = BlockScoping.hasCapturedClosure(self, orig_body_idx, lexical_names.items);
                // body 에 await 가 있으면 _loop 도 async 여야 (호출부도 await wrap).
                // for-await-of 자체는 enclosing async function 보장이지만 body 에 await
                // 가 없으면 sync _loop 으로 충분.
                const is_async = if (has_capture) BlockScoping.hasAwaitExpression(self, orig_body_idx) else false;

                var flow = BlockScoping.FlowResult{};
                defer flow.labels.deinit(self.allocator);
                if (has_capture) {
                    BlockScoping.analyzeControlFlow(self, orig_body_idx, &flow, 0, 0);
                }

                const saved = self.in_for_in_of_header;
                self.in_for_in_of_header = true;
                const new_a = try self.visitNode(node.data.ternary.a);
                self.in_for_in_of_header = saved;
                const new_b = try self.visitNode(node.data.ternary.b);
                const new_c = try self.visitNode(orig_body_idx);

                if (has_capture) {
                    const result = try BlockScoping.buildLoopClosureWithFlow(
                        self,
                        new_c,
                        lexical_names.items,
                        &flow,
                        null,
                        node.span,
                        is_async,
                    );
                    const loop_node = try self.ast.addNode(.{
                        .tag = node.tag,
                        .span = node.span,
                        .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = result.call_and_check } },
                    });
                    const stmts = try self.ast.addNodeList(&.{ result.loop_fn, loop_node });
                    return self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = node.span,
                        .data = .{ .list = stmts },
                    });
                }

                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
                });
            }
        }

        const saved = self.in_for_in_of_header;
        self.in_for_in_of_header = true;
        const new_a = try self.visitNode(node.data.ternary.a);
        self.in_for_in_of_header = saved;
        const new_b = try self.visitNode(node.data.ternary.b);
        const new_c = try self.visitNode(node.data.ternary.c);
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
        });
    }

    /// for-of/for-in의 left에 private_field 가 포함되면 임시 binding + body prefix
    /// assignment 로 재구성 (#1491). 그렇지 않으면 null.
    /// - `for (this.#x of arr) BODY` → `for (var _t of arr) { this.#x = _t; BODY }`
    /// - `for ({x: this.#x} of arr) BODY` → `for (var _t of arr) { ({x: this.#x} = _t); BODY }`
    /// body prefix의 assignment 는 이후 일반 assignment_expression lowering 경로를 거쳐
    /// __classPrivateFieldSet / destructuring helper 로 변환됨.
    fn tryLowerForInOfPrivateTarget(self: *Transformer, node: Node) Error!?NodeIndex {
        const left_idx = node.data.ternary.a;
        if (left_idx.isNone()) return null;
        const left_node = self.ast.getNode(left_idx);
        const has_private = switch (left_node.tag) {
            .private_field_expression => true,
            .object_assignment_target, .array_assignment_target => es2015_class.ES2015Class(Transformer).destructuringTargetHasPrivateField(self, left_idx),
            else => false,
        };
        if (!has_private) return null;

        const span = node.span;
        const temp_span = try es_helpers.makeTempVarSpan(self);
        // var _t;
        const binding = try es_helpers.makeBindingIdentifier(self, temp_span);
        const declarator = try es_helpers.makeDeclarator(self, binding, NodeIndex.none, span);
        const var_decl = try es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);

        // (LHS = _t) assignment_expression — 이후 방문 시 lowerPrivateFieldSet / destructuring 경로 거침.
        const tmp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
        const prefix_assign = try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = span,
            .data = .{ .binary = .{
                .left = left_idx,
                .right = tmp_ref,
                .flags = @intFromEnum(token_mod.Kind.eq),
            } },
        });
        const prefix_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = span,
            .data = .{ .unary = .{ .operand = prefix_assign, .flags = 0 } },
        });

        // 원본 body 의 자식을 prefix_stmt 와 묶어 block_statement 생성 (body 내부는 일반 visit).
        const body_idx = node.data.ternary.c;
        const new_body = try self.buildForBodyWithPrefix(body_idx, prefix_stmt, span);

        // for (var _t ... ) new_body 로 재조립한 뒤, 표준 visit로 하위 변환 적용.
        const rewritten = try self.ast.addNode(.{
            .tag = node.tag,
            .span = span,
            .data = .{ .ternary = .{ .a = var_decl, .b = node.data.ternary.b, .c = new_body } },
        });
        return try self.visitNode(rewritten);
    }

    /// for-loop body 앞에 prefix statement를 삽입해 새 block_statement 생성.
    /// body 가 이미 block_statement면 기존 자식 앞에 prefix를 끼우고, 아니면 [prefix, body] 두 개로 감쌈.
    fn buildForBodyWithPrefix(self: *Transformer, body_idx: NodeIndex, prefix_stmt: NodeIndex, span: Span) Error!NodeIndex {
        if (body_idx.isNone()) {
            const list = try self.ast.addNodeList(&.{prefix_stmt});
            return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = list } });
        }
        const body_node = self.ast.getNode(body_idx);
        if (body_node.tag != .block_statement) {
            const list = try self.ast.addNodeList(&.{ prefix_stmt, body_idx });
            return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = list } });
        }
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        try self.scratch.append(self.allocator, prefix_stmt);
        const start = body_node.data.list.start;
        const len = body_node.data.list.len;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const child_raw = self.ast.extra_data.items[start + i];
            try self.scratch.append(self.allocator, @enumFromInt(child_raw));
        }
        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = list } });
    }

    /// 리스트 노드: 각 자식을 방문, .none이 아닌 것만 새 리스트로 수집.
    fn visitListNode(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        const node = self.ast.getNode(idx);
        // ES2015 block scoping 격리: block_statement 진입 시 리네이밍 처리
        if (self.options.unsupported.block_scoping and node.tag == .block_statement) {
            return self.visitBlockWithScoping(node);
        }
        // program/function_body: 함수 스코프의 var 이름 수집
        if (self.options.unsupported.block_scoping and (node.tag == .program or node.tag == .function_body)) {
            self.collectTopLevelVarNames(node.data.list.start, node.data.list.len);
        }
        // ES2025: using/await using → try-finally 래핑
        if (self.options.unsupported.using) {
            const Using = es2025_using.ES2025Using(Transformer);
            if (Using.hasUsingDeclaration(self, node.data.list.start, node.data.list.len)) {
                const new_list = try Using.lowerUsingInStatements(self, node.data.list.start, node.data.list.len);
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .list = new_list },
                });
            }
        }
        const new_list = try self.visitExtraList(node.data.list);
        // visitExtraList 가 identity (원본 list 그대로) 반환 → 부모도 identity.
        if (new_list.start == node.data.list.start and new_list.len == node.data.list.len) {
            return idx;
        }
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .list = new_list },
        });
    }

    /// block_statement를 방문하면서 내부 let/const 리네이밍을 적용한다.
    fn visitBlockWithScoping(self: *Transformer, node: Node) Error!NodeIndex {
        const list_start = node.data.list.start;
        const list_len = node.data.list.len;

        const saved_scope_len = self.scope_var_names.items.len;
        const renames_added = try self.pushBlockRenames(list_start, list_len);
        const new_list = try self.visitExtraList(.{ .start = list_start, .len = list_len });

        // 블록 퇴장: rename 맵 + scope_var_names 모두 복원
        if (renames_added > 0) {
            self.block_rename_stack.shrinkRetainingCapacity(self.block_rename_stack.items.len - renames_added);
        }
        self.scope_var_names.shrinkRetainingCapacity(saved_scope_len);

        return self.ast.addNode(.{
            .tag = .block_statement,
            .span = node.span,
            .data = .{ .list = new_list },
        });
    }

    /// program/function_body의 top-level 선언에서 var/let/const 이름을 scope_var_names에 수집.
    fn collectTopLevelVarNames(self: *Transformer, list_start: u32, list_len: u32) void {
        var i: u32 = 0;
        while (i < list_len) : (i += 1) {
            const raw = self.ast.extra_data.items[list_start + i];
            const stmt = self.ast.getNode(@enumFromInt(raw));
            if (stmt.tag != .variable_declaration) continue;

            const ve = stmt.data.extra;
            const decl_start = self.readU32(ve, 1);
            const decl_len = self.readU32(ve, 2);

            var j: u32 = 0;
            while (j < decl_len) : (j += 1) {
                const decl_raw = self.ast.extra_data.items[decl_start + j];
                const decl = self.ast.getNode(@enumFromInt(decl_raw));
                if (decl.tag != .variable_declarator) continue;

                const name_idx = self.readNodeIdx(decl.data.extra, 0);
                if (name_idx.isNone()) continue;

                const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(self.allocator);
                BlockScoping.collectBindingNames(self, name_idx, &names) catch continue;

                for (names.items) |name| {
                    if (!self.isNameInScope(name)) {
                        self.scope_var_names.append(self.allocator, name) catch {};
                    }
                }
            }
        }
    }

    /// extra_data의 노드 리스트를 방문하여 새 AST에 복사.
    /// .none이 된 자식은 자동으로 제거된다.
    /// scratch 버퍼를 사용하며, 중첩 호출에 안전 (save/restore 패턴).
    ///
    /// pending_nodes 지원: 각 자식 방문 후 pending_nodes에 쌓인 노드를
    /// 해당 자식 앞에 삽입한다. 이를 통해 1→N 노드 확장이 가능하다.
    /// 예: enum 변환 시 visitNode가 IIFE를 반환하면서 `var Color;`을
    ///     pending_nodes에 push → 리스트에 `var Color;` + IIFE 순서로 삽입.
    /// 리스트의 각 자식을 방문해 새 NodeList 반환.
    /// 변경이 하나도 없으면 원본 `list` 를 그대로 반환한다 (identity) — extra_data
    /// 재할당을 피해 메모리 성장을 억제. caller 가 start/len 동일성으로 판별 가능.
    pub fn visitExtraList(self: *Transformer, list: NodeList) Error!NodeList {
        // 주의: extra_data.items 슬라이스를 캐시하면 안 됨.
        // visitNode 내부에서 ast.extra_data에 append하면 배열이 재할당되어
        // 캐시된 슬라이스가 dangling pointer가 될 수 있다.
        // 따라서 매 반복마다 start+i로 직접 인덱싱한다.

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // pending_nodes save/restore: 중첩 visitExtraList 호출에 안전.
        // 내부 리스트의 pending_nodes가 외부 리스트로 누출되지 않도록 한다.
        const pending_top = self.pending_nodes.items.len;
        defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

        // trailing_nodes save/restore: 중첩 visitExtraList 호출에 안전.
        const trailing_top = self.trailing_nodes.items.len;
        defer self.trailing_nodes.shrinkRetainingCapacity(trailing_top);

        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            // 매 반복마다 extra_data에서 직접 읽기 (재할당 안전)
            const raw_idx = self.ast.extra_data.items[list.start + i];
            const new_child = try self.visitNode(@enumFromInt(raw_idx));

            // pending_nodes 드레인: visitNode가 추가한 보류 노드를 먼저 삽입
            if (self.pending_nodes.items.len > pending_top) {
                try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                self.pending_nodes.shrinkRetainingCapacity(pending_top);
            }

            if (!new_child.isNone()) {
                try self.scratch.append(self.allocator, new_child);
            }

            // trailing_nodes 드레인: visitNode가 추가한 후행 노드를 자식 뒤에 삽입
            // (예: worklet 함수 뒤의 __workletHash/__closure/__initData 프로퍼티 할당)
            if (self.trailing_nodes.items.len > trailing_top) {
                try self.scratch.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
                self.trailing_nodes.shrinkRetainingCapacity(trailing_top);
            }
        }

        const scratch_slice = self.scratch.items[scratch_top..];
        // 변경 없음 감지: 자식 개수 동일 + 각 idx 가 원본과 같음 → 원본 list 그대로 반환.
        // 이 경우 extra_data 재할당이 없고 caller 도 부모 노드를 identity 로 전파 가능.
        if (scratch_slice.len == list.len) {
            var identical = true;
            for (scratch_slice, 0..) |new_idx, j| {
                if (@intFromEnum(new_idx) != self.ast.extra_data.items[list.start + j]) {
                    identical = false;
                    break;
                }
            }
            if (identical) return list;
        }
        return self.ast.addNodeList(scratch_slice);
    }

    // ================================================================
    // TS expression 변환 — 타입 부분 제거, 값만 보존
    // ================================================================

    /// TS expression (as/satisfies/!/type assertion/instantiation)에서
    /// 값 부분만 추출한다.
    ///
    /// 예: `x as number` → `x` (operand만 반환)
    /// 예: `x!` → `x` (non-null assertion 제거)
    /// 예: `<number>x` → `x` (type assertion 제거)
    /// Flow match expression → (function(_m){if(_m===P){B}else if...})(expr)
    fn visitFlowMatch(self: *Transformer, node: Node) Error!NodeIndex {
        const span = node.span;
        const e = node.data.extra;
        const discriminant_idx = self.readNodeIdx(e, 0);
        const arms_start = self.readU32(e, 1);
        const arms_len = self.readU32(e, 2);

        // arm 인덱스를 미리 로컬에 복사 (visitNode가 extra_data를 재할당할 수 있으므로)
        const arm_indices = try self.allocator.alloc(u32, arms_len);
        defer self.allocator.free(arm_indices);
        for (0..arms_len) |i| {
            arm_indices[i] = self.ast.extra_data.items[arms_start + i];
        }

        const new_discriminant = try self.visitNode(discriminant_idx);

        // 임시 변수 _m
        const match_var = try es_helpers.makeTempVarSpan(self);
        const match_param = try es_helpers.makeBindingIdentifier(self, match_var);
        var else_branch: NodeIndex = .none;

        var i: usize = arm_indices.len;
        while (i > 0) {
            i -= 1;
            const arm = self.ast.getNode(@enumFromInt(arm_indices[i]));
            const pattern = arm.data.binary.left;
            const body_idx = arm.data.binary.right;
            const new_body_raw = try self.visitNode(body_idx);
            // body를 { return body; } 또는 block 그대로 사용
            const body_node = self.ast.getNode(new_body_raw);
            const new_body = if (body_node.tag == .block_statement)
                new_body_raw
            else blk: {
                // expression → { return expr; }
                const return_stmt = try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = new_body_raw, .flags = 0 } },
                });
                const stmts = try self.ast.addNodeList(&.{return_stmt});
                break :blk try self.ast.addNode(.{
                    .tag = .block_statement,
                    .span = span,
                    .data = .{ .list = stmts },
                });
            };

            // wildcard `_` 감지
            const pat_node = self.ast.getNode(pattern);
            const is_wildcard = blk: {
                if (pat_node.tag == .identifier_reference) {
                    const text = self.ast.getText(pat_node.span);
                    break :blk std.mem.eql(u8, text, "_");
                }
                break :blk false;
            };

            if (is_wildcard) {
                else_branch = new_body;
            } else {
                const new_pattern = try self.visitNode(pattern);
                const match_ref = try es_helpers.makeTempVarRef(self, match_var, match_var);
                // _m === pattern
                const test_expr = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{
                        .left = match_ref,
                        .right = new_pattern,
                        .flags = @intFromEnum(token_mod.Kind.eq3),
                    } },
                });
                else_branch = try self.ast.addNode(.{
                    .tag = .if_statement,
                    .span = span,
                    .data = .{ .ternary = .{ .a = test_expr, .b = new_body, .c = else_branch } },
                });
            }
        }

        // function(_m) { if-chain }
        const body_list = if (!else_branch.isNone())
            try self.ast.addNodeList(&.{else_branch})
        else
            @import("../parser/ast.zig").NodeList{ .start = 0, .len = 0 };
        const fn_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = span,
            .data = .{ .list = body_list },
        });
        const fn_params_list = try self.ast.addNodeList(&.{match_param});
        const fn_params_node = try self.ast.addFormalParameters(fn_params_list, span);
        const fn_extra = try self.ast.addExtras(&.{
            @intFromEnum(NodeIndex.none), // name (anonymous)
            @intFromEnum(fn_params_node),
            @intFromEnum(fn_body),
            0, // flags
            @intFromEnum(NodeIndex.none), // return type
        });
        const fn_expr = try self.ast.addNode(.{
            .tag = .function_expression,
            .span = span,
            .data = .{ .extra = fn_extra },
        });

        // (function(_m){...})(discriminant)
        // function expression을 parenthesized로 감싸서 IIFE 형태로 만듦
        const paren_fn = try es_helpers.makeParenExpr(self, fn_expr, span);
        // call_expression extra: [callee, args_start, args_len, flags]
        const args_list = try self.ast.addNodeList(&.{new_discriminant});
        const call_extra = try self.ast.addExtras(&.{
            @intFromEnum(paren_fn),
            args_list.start,
            args_list.len,
            0, // flags
        });
        return self.ast.addNode(.{
            .tag = .call_expression,
            .span = span,
            .data = .{ .extra = call_extra },
        });
    }

    /// Flow component with ref → 2개 statement로 변환:
    ///   function Name_withRef({...props}, ref) { ... }    ← pending_nodes
    ///   const Name = React.forwardRef(Name_withRef);       ← 반환값
    ///
    /// extra = [name, params_start, params_len, body]
    /// Flow component with ref: 파서가 생성한 2개 statement를 방문.
    /// extra = [func_decl, const_decl]
    /// func_decl은 pending_nodes에, const_decl은 반환.
    fn visitFlowComponentWrapper(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const func_decl_idx = self.readNodeIdx(e, 0);
        const const_decl_idx = self.readNodeIdx(e, 1);

        // function Name_withRef 방문 (ES2015 lowering 등 적용)
        const new_func = try self.visitNode(func_decl_idx);
        try self.pending_nodes.append(self.allocator, new_func);

        // const Name = React.forwardRef(Name_withRef) 방문
        return self.visitNode(const_decl_idx);
    }

    fn visitTsExpression(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        const node = self.ast.getNode(idx);
        if (!self.options.strip_types) {
            return self.copyNodeDirect(idx);
        }
        const operand = node.data.unary.operand;
        // ts_type_assertion: <T>(expr) → expr (괄호 불필요)
        // angle-bracket 타입 어설션에서 operand가 parenthesized_expression이면
        // 괄호를 벗겨서 내부 expression만 반환한다.
        // 단, comma sequence는 괄호가 필요하므로 유지한다.
        if (node.tag == .ts_type_assertion and !operand.isNone()) {
            const op_node = self.ast.getNode(operand);
            if (op_node.tag == .parenthesized_expression and !op_node.data.unary.operand.isNone()) {
                const inner = self.ast.getNode(op_node.data.unary.operand);
                if (inner.tag != .sequence_expression) {
                    return self.visitNode(op_node.data.unary.operand);
                }
            }
        }
        // 모든 TS expression은 unary로, operand가 값 부분
        return self.visitNode(operand);
    }

    // ================================================================
    // Extra 기반 노드 변환
    // ================================================================

    // ================================================================
    // --drop 헬퍼
    // ================================================================

    /// expression_statement가 console.* 호출인지 판별.
    /// console.log(...), console.warn(...), console.error(...) 등.
    fn isConsoleCall(self: *const Transformer, node: Node) bool {
        // expression_statement → unary.operand가 call_expression이어야 함
        const expr_idx = node.data.unary.operand;
        if (expr_idx.isNone()) return false;
        const expr = self.ast.getNode(expr_idx);
        if (expr.tag != .call_expression) return false;

        // call_expression: extra = [callee, args_start, args_len, flags]
        const ce = expr.data.extra;
        if (ce >= self.ast.extra_data.items.len) return false;
        const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
        if (callee_idx.isNone()) return false;
        const callee = self.ast.getNode(callee_idx);

        // callee가 static_member_expression (console.log)이어야 함
        if (callee.tag != .static_member_expression) return false;

        // left가 identifier "console" — extra = [object, property, flags]
        const me = callee.data.extra;
        if (me >= self.ast.extra_data.items.len) return false;
        const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
        if (obj_idx.isNone()) return false;
        const obj = self.ast.getNode(obj_idx);
        if (obj.tag != .identifier_reference) return false;

        const obj_text = self.ast.getText(obj.data.string_ref);
        return std.mem.eql(u8, obj_text, "console");
    }

    // ================================================================
    // define 글로벌 치환
    // ================================================================

    /// 함수 body가 worklet이 될 예정이면 `plugins.worklet.body_depth`를 올린 상태로 body를 방문한다.
    /// 반환된 body 내부에서는 `--define` 치환이 억제되어 UI 런타임에서도 심볼이 안전하게 유지된다.
    pub fn visitBodyWorkletAware(self: *Transformer, body_idx: NodeIndex) Error!NodeIndex {
        const is_worklet = self.plugins.worklet.auto_next or
            worklet_mod.isWorkletDirectiveGeneric(self, body_idx, "worklet");
        if (is_worklet) self.plugins.worklet.body_depth += 1;
        defer if (is_worklet) {
            self.plugins.worklet.body_depth -= 1;
        };
        return self.visitNode(body_idx);
    }

    /// Fast Refresh 등록이 억제된 scope 안에서 node를 visit한다.
    /// IIFE 내부 factory처럼 최상위 바인딩이 아닌 함수 선언에 대해
    /// `_cN = <name>` 참조 시 ReferenceError를 유발하지 않도록 refresh 등록을 건너뛴다.
    /// 호출 scope 바깥의 suppress 상태는 save/restore된다.
    pub fn visitWithRefreshSuppressed(self: *Transformer, node_idx: NodeIndex) Error!NodeIndex {
        const saved = self.plugins.refresh.suppress_registration;
        self.plugins.refresh.suppress_registration = true;
        defer self.plugins.refresh.suppress_registration = saved;
        return self.visitNode(node_idx);
    }

    /// 노드가 define 치환 대상이면 새 string_literal 노드를 반환.
    /// 대상: identifier_reference / static_member_expression / chain_expression.
    ///
    /// 매칭 규칙(#1552):
    ///   - optional chaining(`?.`)이 포함된 식은 `.`로 정규화 후 매칭.
    ///     방어적 접근 패턴(`globalThis.process?.env?.NODE_ENV`)까지 커버.
    ///   - `globalThis.` / `window.` / `self.` 접두어는 번들 맥락에서 의미 없는
    ///     global root이므로 벗기고 define key와 비교.
    fn tryDefineReplace(self: *Transformer, node: Node) ?Error!NodeIndex {
        const raw_text = self.getNodeText(node) orelse return null;

        // parser는 `a?.b`를 chain_expression 없이 static_member_expression + optional
        // flag로 표현하므로, `?` 존재 여부로만 정규화 필요를 판별.
        var norm_buf: [DEFINE_KEY_NORM_BUF]u8 = undefined;
        const text = if (std.mem.indexOfScalar(u8, raw_text, '?') != null)
            normalizeOptionalChain(raw_text, &norm_buf) orelse return null
        else
            raw_text;

        for (self.options.define) |entry| {
            if (!matchDefineKey(text, entry.key)) continue;
            // intern map 이 같은 entry.value 의 두 번째 호출부터 hit → 캐시 효과 흡수.
            const value_span = self.ast.addString(entry.value) catch return Error.OutOfMemory;
            // 값이 따옴표로 시작하면 string_literal, 아니면 identifier_reference.
            // "production" → string_literal, false/true/숫자 → identifier_reference.
            const is_string = entry.value.len >= 2 and (entry.value[0] == '"' or entry.value[0] == '\'');
            return self.ast.addNode(.{
                .tag = if (is_string) .string_literal else .identifier_reference,
                .span = value_span,
                .data = .{ .string_ref = value_span },
            });
        }
        return null;
    }

    /// 노드의 소스 텍스트를 반환. define 치환 대상 노드만 지원.
    fn getNodeText(self: *const Transformer, node: Node) ?[]const u8 {
        return getDefineCandidateText(self.ast, node);
    }

    // ================================================================
    // TS / Flow enum 변환 — transformer/enum.zig로 위임
    // ================================================================
    const enum_mod = @import("transformer/enum.zig");
    pub const visitFlowEnumDeclaration = enum_mod.visitFlowEnumDeclaration;
    pub const visitEnumDeclaration = enum_mod.visitEnumDeclaration;
    pub const tryInlineConstEnumMember = enum_mod.tryInlineConstEnumMember;

    // ================================================================
    // TS namespace 변환
    // ================================================================

    /// ts_module_declaration: binary = { left=name, right=body_or_inner, flags }
    /// flags=1: ambient module declaration (`declare module "*.css" { ... }`) → strip.
    /// flags=0: 일반 namespace → 새 AST에 복사. codegen에서 IIFE로 출력.
    /// import x = require('y') → const x = require('y')
    /// import x = Namespace.Member → const x = Namespace.Member
    fn visitImportEqualsDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const name_idx = node.data.binary.left;
        const value_idx = node.data.binary.right;
        const new_name = try self.visitNode(name_idx);
        const new_value = try self.visitNode(value_idx);
        // variable_declarator: extra = [name, type_ann(none), init]
        const decl_extra = try self.ast.addExtras(&.{
            @intFromEnum(new_name),
            @intFromEnum(NodeIndex.none), // type_ann (stripped)
            @intFromEnum(new_value),
        });
        const declarator = try self.ast.addNode(.{
            .tag = .variable_declarator,
            .span = node.span,
            .data = .{ .extra = decl_extra },
        });
        const scratch_top = self.scratch.items.len;
        try self.scratch.append(self.allocator, declarator);
        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.scratch.shrinkRetainingCapacity(scratch_top);
        // variable_declaration: extra = [kind_flags, list.start, list.len]
        // kind = .const
        const var_extra = try self.ast.addExtras(&.{ @intFromEnum(VariableDeclarationKind.@"const"), list.start, list.len });
        return try self.ast.addNode(.{
            .tag = .variable_declaration,
            .span = node.span,
            .data = .{ .extra = var_extra },
        });
    }

    /// `export = expr;` → `module.exports = expr;` ExpressionStatement.
    /// ESM output context 에서는 런타임에서 `module is not defined` 으로 실패하지만
    /// (tsc TS1203 동등), rewrite 는 무조건 — #1961 의 helper-import 패턴과 동일하게
    /// 정책 (warn/strip/error) 은 호출자/codegen 이 결정.
    fn visitExportAssignment(self: *Transformer, node: Node) Error!NodeIndex {
        const new_expr = try self.visitNode(node.data.unary.operand);
        if (new_expr.isNone()) return .none;

        const module_id = try es_helpers.makeIdentifierRef(self, "module");
        const exports_id = try es_helpers.makeIdentifierRef(self, "exports");
        const member = try es_helpers.makeStaticMember(self, module_id, exports_id, node.span);
        return es_helpers.makeAssignStmt(self, member, new_expr, node.span, 0);
    }

    fn visitNamespaceDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        // declare module "*.css" { ... } 같은 ambient module은 런타임 코드 없음 → strip
        if (node.data.binary.flags == 1) return .none;
        const new_name = try self.visitNode(node.data.binary.left);
        const new_body = try self.visitNode(node.data.binary.right);
        // 타입만 있어 전부 스트리핑됐거나, 빈 블록인 namespace → strip
        if (new_body.isNone()) return .none;
        const body_node = self.ast.getNode(new_body);
        if ((body_node.tag == .block_statement or body_node.tag == .ts_module_block) and body_node.data.list.len == 0) {
            return .none;
        }
        return self.ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = node.span,
            .data = .{ .binary = .{ .left = new_name, .right = new_body, .flags = 0 } },
        });
    }

    // ================================================================
    // 헬퍼
    // ================================================================

    /// 노드의 symbol_id 조회 (없으면 null).
    pub fn getSymbolIdAt(self: *const Transformer, idx: NodeIndex) ?u32 {
        if (idx.isNone()) return null;
        const i = @intFromEnum(idx);
        if (i >= self.symbol_ids.items.len) return null;
        return self.symbol_ids.items[i];
    }

    /// extra 인덱스로 NodeIndex 읽기.
    pub fn readNodeIdx(self: *const Transformer, extra_start: u32, offset: u32) NodeIndex {
        return @enumFromInt(self.ast.extra_data.items[extra_start + offset]);
    }

    /// extra 인덱스로 u32 읽기.
    pub fn readU32(self: *const Transformer, extra_start: u32, offset: u32) u32 {
        return self.ast.extra_data.items[extra_start + offset];
    }

    /// 노드를 extra_data로 만들어 새 AST에 추가.
    pub fn addExtraNode(self: *Transformer, tag: Tag, span: Span, extras: []const u32) Error!NodeIndex {
        const new_extra = try self.ast.addExtras(extras);
        return self.ast.addNode(.{ .tag = tag, .span = span, .data = .{ .extra = new_extra } });
    }

    // ================================================================
    // JSX 노드 변환
    // ================================================================

    /// jsx_element: extra = [tag_name, attrs_start, attrs_len, children_start, children_len]
    /// 항상 5 fields. self-closing은 children_len=0.
    fn visitJSXElement(self: *Transformer, node: Node) Error!NodeIndex {
        // cssProp pre-processing — `<X css={...}>` 를 styled component 로 추출 (jsx_transform=false
        // 경로 — jsx 가 그대로 출력되는 케이스).
        const working_node = (try styled_components_mod.maybeExtractCssProp(self, node)) orelse node;
        const e = working_node.data.extra;
        const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
        const new_attrs = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        const children_len = self.readU32(e, 4);
        const new_children = if (children_len > 0)
            try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = children_len })
        else
            NodeList{ .start = 0, .len = 0 };
        return self.addExtraNode(.jsx_element, working_node.span, &.{
            @intFromEnum(new_tag),
            new_attrs.start,
            new_attrs.len,
            new_children.start,
            new_children.len,
        });
    }

    /// jsx_opening_element: extra = [tag_name, attrs_start, attrs_len]
    fn visitJSXOpeningElement(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitJSXExtraNode(.jsx_opening_element, node);
    }

    /// JSX extra 노드 공통: tag + attrs만 복사 (opening element 등)
    fn visitJSXExtraNode(self: *Transformer, tag: Tag, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
        const new_attrs = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        return self.addExtraNode(tag, node.span, &.{
            @intFromEnum(new_tag),
            new_attrs.start,
            new_attrs.len,
        });
    }

    // ================================================================
    // Extra 기반 노드 변환
    // ================================================================

    /// variable_declaration: extra_data = [kind_flags, list.start, list.len]
    /// binding이 destructuring pattern (object/array)인지 판별.
    inline fn isBindingPattern(self: *const Transformer, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        const tag = self.ast.getNode(idx).tag;
        return tag == .object_pattern or tag == .array_pattern;
    }

    fn visitVariableDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        // ES2015: destructuring pattern → 개별 declarator로 분해
        // ES2018: object rest (...rest) → __rest 호출 (target < es2018)
        if (self.options.unsupported.destructuring) {
            if (es2015_destructuring.ES2015Destructuring(Transformer).hasDestructuring(self, node)) {
                return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringDeclaration(self, node);
            }
        } else if (self.options.unsupported.object_spread) {
            if (es2015_destructuring.ES2015Destructuring(Transformer).hasObjectRest(self, node)) {
                return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringDeclaration(self, node);
            }
        }
        const e = node.data.extra;
        const orig_kind = self.ast.variableDeclarationKind(node);

        // `const re = /.../` 추적 — String.replace 의 named group 매핑 lookup 용 (#1473).
        // const 만 추적: let/var 는 재할당 가능해 추적 결과를 신뢰할 수 없음.
        if (self.options.unsupported.regex_named_groups and orig_kind == .@"const") {
            self.collectConstRegexDeclarators(self.readU32(e, 1), self.readU32(e, 2)) catch {};
        }
        const kind = if (self.options.unsupported.block_scoping)
            es2015_block_scoping.lowerKind(orig_kind)
        else
            orig_kind;

        // let/const → var 변환 시: 초기화 없는 declarator에 = void 0 추가.
        // let은 블록 스코프로 매 반복 새 바인딩이지만, var는 hoisted되어 이전 값 유지.
        // Metro(Babel)와 동일하게 명시적 undefined 초기화로 의미론 보존.
        //
        // 단, for-in/for-of/for-await-of 헤더의 left는 매 반복 루프가 바인딩에 쓰므로
        // `= void 0`이 불필요하고, 오히려 `for (var k = void 0 in obj)` 는 Annex B
        // legacy 구문(for-in 전용, 비-strict)이라 codegen이 `k = void 0;` 로 hoist해
        // 선언 전에 토해내 strict mode ReferenceError를 유발 (#1386).
        const needs_void_init = self.options.unsupported.block_scoping and
            orig_kind.isLexical() and
            !self.in_for_in_of_header;

        const list_start = self.readU32(e, 1);
        const list_len = self.readU32(e, 2);

        if (needs_void_init) {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var i_loop: u32 = 0;
            while (i_loop < list_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[list_start + i_loop];
                const decl = self.ast.getNode(@enumFromInt(raw_idx));
                if (decl.tag != .variable_declarator) {
                    const new_node = try self.visitNode(@enumFromInt(raw_idx));
                    if (!new_node.isNone()) try self.scratch.append(self.allocator, new_node);
                    continue;
                }
                const de = decl.data.extra;
                const name_idx = self.readNodeIdx(de, 0);
                const init_idx = self.readNodeIdx(de, 2);
                const new_name = try self.visitNode(name_idx);

                if (init_idx.isNone()) {
                    // let x; → var x = void 0;
                    // 단 destructuring pattern (`let {x}`, `let [x]`)은 init 추가 금지 —
                    // for-of/for-in의 left에서 매 반복 iter value를 받으며, `{x} = void 0` 같은
                    // statement는 block_statement로 잘못 파싱되어 syntax error (#1302).
                    const is_destructuring = isBindingPattern(self, new_name);
                    const none = @intFromEnum(NodeIndex.none);
                    const init_node: u32 = if (is_destructuring)
                        none
                    else
                        @intFromEnum(try es_helpers.makeVoidZero(self, node.span));
                    const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{ @intFromEnum(new_name), none, init_node });
                    try self.scratch.append(self.allocator, new_decl);
                } else {
                    const new_init = try self.visitNode(init_idx);
                    const none = @intFromEnum(NodeIndex.none);
                    const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{ @intFromEnum(new_name), none, @intFromEnum(new_init) });
                    try self.scratch.append(self.allocator, new_decl);
                }
            }

            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.addExtraNode(.variable_declaration, node.span, &.{ @intFromEnum(kind), new_list.start, new_list.len });
        }

        const new_list = try self.visitExtraList(.{ .start = list_start, .len = list_len });
        return self.addExtraNode(.variable_declaration, node.span, &.{ @intFromEnum(kind), new_list.start, new_list.len });
    }

    /// variable_declarator: extra_data = [name, type_ann, init]
    fn visitVariableDeclarator(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        var new_init = try self.visitNode(self.readNodeIdx(e, 2));
        // styled-components: tag 를 `.withConfig({displayName})` 로 wrap. fast-path 로 1) 옵션,
        // 2) binding 감지, 3) init.tag == tagged_template_expression 을 사전 거른 뒤에만
        // 본 helper 호출. var_name 은 block-scoping rename 후 안전하도록 new_name 에서 읽음.
        if (!new_name.isNone() and styled_components_mod.shouldAttemptWrap(self, new_init)) {
            const new_name_node = self.ast.getNode(new_name);
            if (new_name_node.tag == .binding_identifier or new_name_node.tag == .identifier_reference) {
                const var_name = self.ast.getText(new_name_node.data.string_ref);
                new_init = try styled_components_mod.wrapStyledTagInExpr(self, new_init, var_name);
            }
        }
        // emotion autoLabel: const X = css`...` → css`label:X;...`
        if (self.options.emotion and !new_name.isNone() and !new_init.isNone()) {
            const new_name_node = self.ast.getNode(new_name);
            if (new_name_node.tag == .binding_identifier or new_name_node.tag == .identifier_reference) {
                const var_name = self.ast.getText(new_name_node.data.string_ref);
                new_init = try emotion_mod.maybeTransformEmotionTemplate(self, new_init, var_name);
            }
        }
        // styled-components named helper minify: const X = css`...` / keyframes`...` 등.
        // helper 는 컴포넌트가 아니라 CSS 조각이라 displayName/componentId 는 안 붙임.
        if (self.options.styled_components and !new_init.isNone()) {
            new_init = try styled_components_mod.maybeMinifyHelperTemplate(self, new_init);
        }
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.variable_declarator, node.span, &.{ @intFromEnum(new_name), none, @intFromEnum(new_init) });
    }

    /// function/function_declaration/function_expression/arrow_function_expression
    /// extra_data = [name, params_start, params_len, body, flags, return_type]
    ///
    /// parameter property 변환:
    ///   constructor(public x: number) {} →
    ///   constructor(x) { this.x = x; }
    fn visitFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;

        // TS function overload signature: body가 없으면 제거
        // function foo(): void;  ← overload signature (body 없음)
        // function foo(x: number): void;  ← overload signature
        // function foo(x?: number) {}  ← 구현체 (body 있음)
        if (self.readNodeIdx(e, 2).isNone()) return NodeIndex.none;

        // 일반 함수는 자체 this 바인딩을 가지므로 depth 증가.
        // static block 안에서 function() { this.x } 의 this는 치환하면 안 됨.
        const in_static_block = self.static_block_class_name != null;
        if (in_static_block) self.this_depth += 1;
        defer if (in_static_block) {
            self.this_depth -= 1;
        };

        // ES2015 arrow this/arguments 캡처: 일반 함수는 자체 this/arguments 바인딩을 가짐.
        const saved_arrow_depth = self.arrow_this_depth;
        const saved_needs_this = self.needs_this_var;
        const saved_needs_args = self.needs_arguments_var;
        const saved_super_alias = self.super_call_this_alias;
        self.arrow_this_depth = 0;
        self.needs_this_var = false;
        self.needs_arguments_var = false;
        self.super_call_this_alias = false;

        // ES2015 block scoping: 함수는 새 var 스코프. save/restore.
        const saved_scope_len = self.scope_var_names.items.len;
        const saved_rename_len = self.block_rename_stack.items.len;
        defer {
            self.scope_var_names.shrinkRetainingCapacity(saved_scope_len);
            // 함수 내부에서 추가된 rename 해제
            for (self.block_rename_stack.items[saved_rename_len..]) |entry| self.allocator.free(entry.new_name);
            self.block_rename_stack.shrinkRetainingCapacity(saved_rename_len);
        }

        // ES2015 new.target: 일반 함수 → function_named 컨텍스트
        const saved_new_target_ctx = self.new_target_ctx;
        if (self.options.unsupported.new_target) {
            const name_idx = self.readNodeIdx(e, 0);
            if (!name_idx.isNone()) {
                self.new_target_ctx = .{ .function_named = self.ast.getNode(name_idx).span };
            } else {
                // 익명 함수: new.target → void 0 (이름 없으므로 instanceof 불가)
                self.new_target_ctx = .method;
            }
        }
        defer self.new_target_ctx = saved_new_target_ctx;

        // 임시 변수 카운터 저장 (함수 스코프 내 사용된 임시 변수 호이스팅용)
        const saved_temp_counter = self.temp_var_counter;

        const new_name = try self.visitNode(self.readNodeIdx(e, 0));

        // 파라미터 방문 + parameter property 수집
        const params_idx_old = self.readNodeIdx(e, 1);
        var params_span = node.span;
        var params_list_old = NodeList{ .start = 0, .len = 0 };
        if (!params_idx_old.isNone()) {
            const pnode = self.ast.getNode(params_idx_old);
            if (pnode.tag == .formal_parameters) {
                params_list_old = pnode.data.list;
                params_span = pnode.span;
            }
        }
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var pp = try self.visitParamsCollectProperties(params_list_old);
        defer pp.prop_names.deinit(self.allocator);

        // 바디 방문
        const old_body_idx = self.readNodeIdx(e, 2);
        var new_body = try self.visitBodyWorkletAware(old_body_idx);

        // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
        if (pp.prop_names.items.len > 0 and !new_body.isNone()) {
            new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names.items);
        }

        // ES2015 arrow this/arguments 캡처: 이 함수 안의 arrow가 this/arguments를 사용했으면
        // var _this = this; / var _arguments = arguments; 를 바디 앞에 삽입.
        if (self.options.unsupported.arrow and !new_body.isNone() and
            (self.needs_this_var or self.needs_arguments_var))
        {
            var capture_stmts: [2]NodeIndex = undefined;
            var capture_count: usize = 0;

            if (self.needs_this_var) {
                const this_init = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = node.span,
                    .data = .{ .none = 0 },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, node.span);
                capture_count += 1;
            }
            if (self.needs_arguments_var) {
                const args_span = try self.ast.addString("arguments");
                const args_init = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = args_span,
                    .data = .{ .string_ref = args_span },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_arguments", args_init, node.span);
                capture_count += 1;
            }

            new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
        }

        // 임시 변수 호이스팅: 이 함수 안에서 사용된 _a, _b, ... 선언을 body 앞에 삽입
        if (self.temp_var_counter > saved_temp_counter and !new_body.isNone()) {
            new_body = try self.hoistTempVars(new_body, saved_temp_counter, node.span);
        }
        // 함수 스코프 종료 — outer scope 의 hoistTempVars 가 같은 _a 를 다시 hoist 하지 않도록
        // 카운터 복원 (#1960). 다음 함수 / outer 에서 동일 이름을 안전하게 재사용 가능.
        self.temp_var_counter = saved_temp_counter;

        // arrow 캡처 상태 복원
        self.arrow_this_depth = saved_arrow_depth;
        self.needs_this_var = saved_needs_this;
        self.needs_arguments_var = saved_needs_args;
        self.super_call_this_alias = saved_super_alias;

        // $RefreshSig$ (hook signature) 스캔은 제거 — transform 후 stale AST 인덱스로 OOM 유발.
        // Metro도 직접 스캔하지 않고 Babel/SWC에 위임. $RefreshReg$만 유지.

        const none = @intFromEnum(NodeIndex.none);
        const new_params_node = try self.ast.addFormalParameters(pp.new_params, params_span);
        const result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_params_node),
            @intFromEnum(new_body), self.readU32(e, 3),
            none,
        });

        // Plugin dispatch: onFunction (AST 훅)
        const is_auto_worklet = self.plugins.worklet.auto_next;
        if (try self.dispatchFunctionPlugins(result, .{
            .node_idx = result,
            .node_tag = node.tag,
            .name = self.getFunctionName(self.ast.getNode(result)),
            .body_idx = new_body,
            .params = pp.new_params,
            .original_params = params_list_old,
            .original_body_idx = old_body_idx,
            .flags = self.readU32(e, 3),
            .source_path = self.options.jsx_filename,
            .is_auto_worklet = is_auto_worklet,
        })) |replacement| {
            return replacement;
        }

        // React Fast Refresh: PascalCase 함수 → 컴포넌트 등록
        try self.maybeRegisterRefreshComponent(result);

        return result;
    }

    /// 파라미터 목록을 방문하면서 parameter property (public x 등)를 감지.
    /// modifier를 제거하고 this.x = x 삽입용 이름을 수집한다.
    /// caller 는 반환된 result.prop_names 를 `deinit(self.allocator)` 해야 함.
    const ParamPropertyResult = struct {
        new_params: NodeList,
        prop_names: std.ArrayList(NodeIndex),
    };

    pub fn visitParamsCollectProperties(self: *Transformer, vp: NodeList) Error!ParamPropertyResult {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var result = ParamPropertyResult{
            .new_params = NodeList{ .start = 0, .len = 0 },
            .prop_names = .empty,
        };
        errdefer result.prop_names.deinit(self.allocator);

        // visitNode가 AST를 변형하므로 인덱스 루프 사용
        var i_loop: u32 = 0;
        while (i_loop < vp.len) : (i_loop += 1) {
            const raw_idx = self.ast.extra_data.items[vp.start + i_loop];
            const param_idx: NodeIndex = @enumFromInt(raw_idx);
            if (param_idx.isNone()) continue;
            const param_node = self.ast.getNode(param_idx);
            // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
            // flags != 0 → parameter property (public/private/protected/readonly/override)
            if (param_node.tag == .formal_parameter and self.ast.extra_data.items[param_node.data.extra + 3] != 0) {
                const inner = try self.visitNode(@enumFromInt(self.ast.extra_data.items[param_node.data.extra]));
                try self.scratch.append(self.allocator, inner);
                try result.prop_names.append(self.allocator, inner);
            } else {
                const new_param = try self.visitNode(@enumFromInt(raw_idx));
                if (!new_param.isNone()) {
                    try self.scratch.append(self.allocator, new_param);
                }
            }
        }

        result.new_params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return result;
    }

    /// `this.x = x;` 형태의 expression_statement 노드들을 만들어 반환한다.
    /// ES5 다운레벨링에서 derived class 는 super() 뒤에 _this 별칭으로 emit,
    /// base class 는 body 앞에 prepend — caller 가 결정한다.
    /// 결과 slice 는 transformer 의 NodeList 풀에 등록되므로 즉시 소비할 것.
    pub fn buildParameterPropertyStatements(self: *Transformer, prop_names: []const NodeIndex) Error!NodeList {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        for (prop_names) |name_idx| {
            const name_node = self.ast.getNode(name_idx);
            const this_node = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = name_node.span,
                .data = .{ .none = 0 },
            });
            const member_extra = try self.ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(name_idx), 0 });
            const member = try self.ast.addNode(.{
                .tag = .static_member_expression,
                .span = name_node.span,
                .data = .{ .extra = member_extra },
            });
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = name_node.span,
                .data = .{ .binary = .{ .left = member, .right = name_idx, .flags = 0 } },
            });
            const stmt = try self.ast.addNode(.{
                .tag = .expression_statement,
                .span = name_node.span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, stmt);
        }
        return try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    }

    /// derived class constructor 의 super() 직후에 this.x = x; 문들을 삽입한다.
    /// (kept-class 경로 — visitMethodDefinition. ES5 lowering 은 postProcessDerivedConstructorBody 사용).
    pub fn insertParameterPropertyAssignmentsAfterSuper(self: *Transformer, body_idx: NodeIndex, prop_names: []const NodeIndex) Error!NodeIndex {
        const pp_list = try self.buildParameterPropertyStatements(prop_names);
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        for (self.ast.extra_data.items[pp_list.start .. pp_list.start + pp_list.len]) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }
        return self.insertStatementsAfterSuper(body_idx, self.scratch.items[scratch_top..]);
    }

    /// block_statement 바디 앞에 this.x = x; 문들을 삽입한다 (base class ctor 용).
    /// derived class 는 super() 호출 이전에 박으면 super() 후 새 인스턴스에 손실되므로 사용 금지 —
    /// `buildParameterPropertyStatements` + `postProcessDerivedConstructorBody` 경로를 사용하라.
    pub fn insertParameterPropertyAssignments(self: *Transformer, body_idx: NodeIndex, prop_names: []const NodeIndex) Error!NodeIndex {
        const body = self.ast.getNode(body_idx);
        if (body.tag != .block_statement) return body_idx;

        const old_list = body.data.list;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const pp_list = try self.buildParameterPropertyStatements(prop_names);
        const pp_stmts = self.ast.extra_data.items[pp_list.start .. pp_list.start + pp_list.len];
        for (pp_stmts) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));

        const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
        for (old_stmts) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));

        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{
            .tag = .block_statement,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    /// block_statement / program / function_body 앞에 문들을 삽입한다.
    /// body의 첫 super() 호출 이후 위치에 stmts 삽입 — derived class constructor 전용 (#1495).
    /// super_call이 없으면 body 앞에 prepend (fallback). body가 block이 아니면 block으로 감싼 뒤 처리.
    pub fn insertStatementsAfterSuper(self: *Transformer, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
        const body = self.ast.getNode(body_idx);
        if (body.tag != .block_statement and body.tag != .function_body) {
            return self.prependStatementsToBody(body_idx, stmts);
        }
        const old_list = body.data.list;
        const old_stmts_start = old_list.start;
        const old_stmts_len = old_list.len;
        const old_stmts = self.ast.extra_data.items[old_stmts_start .. old_stmts_start + old_stmts_len];

        // super() 호출이 들어있는 expression_statement 찾기.
        var super_idx: ?u32 = null;
        for (old_stmts, 0..) |raw_idx, i| {
            const stmt = self.ast.getNode(@enumFromInt(raw_idx));
            if (stmt.tag != .expression_statement) continue;
            const operand = stmt.data.unary.operand;
            if (operand.isNone()) continue;
            const call = self.ast.getNode(operand);
            if (call.tag != .call_expression) continue;
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[call.data.extra]);
            const callee = self.ast.getNode(callee_idx);
            if (callee.tag == .super_expression) {
                super_idx = @intCast(i);
                break;
            }
        }

        if (super_idx == null) return self.prependStatementsToBody(body_idx, stmts);

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // [0..super_idx] + super() + stmts + [super_idx+1..]
        const cut: u32 = super_idx.? + 1;
        for (old_stmts[0..cut]) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        for (stmts) |stmt| try self.scratch.append(self.allocator, stmt);
        for (old_stmts[cut..]) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));

        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{
            .tag = body.tag,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    pub fn prependStatementsToBody(self: *Transformer, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
        const body = self.ast.getNode(body_idx);
        if (body.tag != .block_statement and body.tag != .program and body.tag != .function_body) {
            // 단일 문(non-block)이면 블록으로 감싸서 prepend
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            for (stmts) |stmt| {
                try self.scratch.append(self.allocator, stmt);
            }
            try self.scratch.append(self.allocator, body_idx);
            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = body.span,
                .data = .{ .list = new_list },
            });
        }

        const old_list = body.data.list;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (stmts) |stmt| {
            try self.scratch.append(self.allocator, stmt);
        }

        const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{
            .tag = body.tag,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    /// ES2015 new.target 변환.
    /// constructor: this.constructor
    /// method: void 0
    /// function_named(Fn): this instanceof Fn ? this.constructor : void 0
    fn lowerNewTarget(self: *Transformer, span: Span) Error!NodeIndex {
        return switch (self.new_target_ctx) {
            .constructor => es_helpers.makeThisDotConstructor(self, span),
            .method, .none => es_helpers.makeVoidZero(self, span),
            .function_named => |fn_span| {
                // (this instanceof Fn ? this.constructor : void 0)
                const this1 = try es_helpers.makeThisExpr(self, span);
                const fn_ref = try es_helpers.makeIdentifierRefFromSpan(self, fn_span);
                const instanceof = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{
                        .left = this1,
                        .right = fn_ref,
                        .flags = @intFromEnum(token_mod.Kind.kw_instanceof),
                    } },
                });

                const this_ctor = try es_helpers.makeThisDotConstructor(self, span);

                const void_zero = try es_helpers.makeVoidZero(self, span);

                // conditional → parenthesized (우선순위 보호)
                const cond = try self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = span,
                    .data = .{ .ternary = .{
                        .a = instanceof,
                        .b = this_ctor,
                        .c = void_zero,
                    } },
                });
                return self.ast.addNode(.{
                    .tag = .parenthesized_expression,
                    .span = span,
                    .data = .{ .unary = .{ .operand = cond, .flags = 0 } },
                });
            },
        };
    }

    /// block_rename_stack에서 이름 조회. 스택 뒤(가장 안쪽 블록)부터 검색.
    pub fn lookupBlockRename(self: *const Transformer, name: []const u8) ?[]const u8 {
        var i = self.block_rename_stack.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.block_rename_stack.items[i];
            if (std.mem.eql(u8, entry.old_name, name)) return entry.new_name;
        }
        return null;
    }

    /// 현재 함수 스코프의 var 이름 목록에 해당 이름이 있는지 확인.
    fn isNameInScope(self: *const Transformer, name: []const u8) bool {
        for (self.scope_var_names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// block_statement 진입 시: 내부 let/const 선언을 스캔하여 외부 스코프와
    /// 충돌하는 이름을 찾고 리네이밍 맵을 push한다.
    /// 반환값: push한 rename entry 수 (퇴장 시 pop할 양).
    fn pushBlockRenames(self: *Transformer, list_start: u32, list_len: u32) Error!u32 {
        var renames_added: u32 = 0;

        var i: u32 = 0;
        while (i < list_len) : (i += 1) {
            const raw = self.ast.extra_data.items[list_start + i];
            const stmt = self.ast.getNode(@enumFromInt(raw));
            if (stmt.tag != .variable_declaration) continue;

            const ve = stmt.data.extra;
            if (!self.ast.variableDeclarationKind(stmt).isLexical()) continue;

            const decl_start = self.readU32(ve, 1);
            const decl_len = self.readU32(ve, 2);

            var j: u32 = 0;
            while (j < decl_len) : (j += 1) {
                const decl_raw = self.ast.extra_data.items[decl_start + j];
                const decl = self.ast.getNode(@enumFromInt(decl_raw));
                if (decl.tag != .variable_declarator) continue;

                const name_idx = self.readNodeIdx(decl.data.extra, 0);
                if (name_idx.isNone()) continue;

                // binding pattern에서 모든 이름 수집 (destructuring 지원)
                const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(self.allocator);
                BlockScoping.collectBindingNames(self, name_idx, &names) catch continue;

                for (names.items) |name| {
                    if (self.isNameInScope(name)) {
                        self.block_rename_counter += 1;
                        const new_name = std.fmt.allocPrint(self.allocator, "{s}${d}", .{ name, self.block_rename_counter }) catch return Error.OutOfMemory;
                        self.block_rename_stack.append(self.allocator, .{ .old_name = name, .new_name = new_name }) catch return Error.OutOfMemory;
                        renames_added += 1;
                    } else {
                        self.scope_var_names.append(self.allocator, name) catch return Error.OutOfMemory;
                    }
                }
            }
        }

        return renames_added;
    }

    /// var <name> = <init_value>; 문 생성 (범용 헬퍼).
    /// prefix + 카운터로 고유 이름을 생성한다. (예: _loop, _loop2, _loop3, ...)
    /// 호출부에서 전용 카운터 포인터를 전달하여 다른 기능과 충돌 방지.
    pub fn buildUniqueName(self: *Transformer, prefix: []const u8, counter: *u32) Error![]const u8 {
        counter.* += 1;
        if (counter.* == 1) return prefix;
        return std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, counter.* }) catch return Error.OutOfMemory;
    }

    pub fn buildVarDecl(self: *Transformer, name: []const u8, init_value: NodeIndex, span: Span) Error!NodeIndex {
        const name_span = try self.ast.addString(name);
        const binding = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });

        const none = @intFromEnum(NodeIndex.none);
        const declarator = try self.addExtraNode(.variable_declarator, span, &.{
            @intFromEnum(binding), none, @intFromEnum(init_value),
        });

        const decl_list = try self.ast.addNodeList(&.{declarator});
        return self.addExtraNode(.variable_declaration, span, &.{
            @intFromEnum(VariableDeclarationKind.@"var"),
            decl_list.start,
            decl_list.len,
        });
    }

    /// 임시 변수 호이스팅: saved_counter..current counter 범위의 var _a, _b, ... 선언을 body 앞에 삽입.
    /// body 의 top-level var 선언에 이미 같은 이름이 있으면 skip — `lowerDestructuringDeclaration`
    /// 처럼 declaration 형태로 직접 emit 하는 패스가 있어 mergeAdjacentDecls 가 `var _a, _a = init, ...`
    /// 같은 어색한 출력을 만드는 회귀 방지 (#1960).
    pub fn hoistTempVars(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span) Error!NodeIndex {
        const count = self.temp_var_counter - saved_counter;
        if (count == 0) return body_idx;

        const body_node = self.ast.getNode(body_idx);
        const has_block = body_node.tag == .block_statement or
            body_node.tag == .program or
            body_node.tag == .function_body;

        // var _a, _b, ... (초기값 없이 선언만)
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var i: u32 = saved_counter;
        while (i < self.temp_var_counter) : (i += 1) {
            var buf: [16]u8 = undefined;
            const name = es_helpers.tempVarName(i, &buf);
            if (has_block and self.bodyHasTopLevelVarBinding(body_node, name)) continue;
            const name_span = try self.ast.addString(name);
            const binding = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = name_span,
                .data = .{ .string_ref = name_span },
            });
            const none = @intFromEnum(NodeIndex.none);
            const declarator = try self.addExtraNode(.variable_declarator, span, &.{
                @intFromEnum(binding), none, none,
            });
            try self.scratch.append(self.allocator, declarator);
        }

        if (self.scratch.items.len == scratch_top) return body_idx;

        const decl_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        const var_decl = try self.addExtraNode(.variable_declaration, span, &.{
            @intFromEnum(VariableDeclarationKind.@"var"),
            decl_list.start,
            decl_list.len,
        });

        return self.prependStatementsToBody(body_idx, &.{var_decl});
    }

    /// body (block_statement / program / function_body) 의 top-level var declaration 에서
    /// `name` 과 같은 binding identifier 가 있는지 검사. nested block 은 보지 않음 — var 는
    /// function-scoped 라 top-level 만 봐도 충분.
    fn bodyHasTopLevelVarBinding(self: *const Transformer, body: Node, name: []const u8) bool {
        const list = body.data.list;
        const stmts = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (stmts) |raw_idx| {
            const stmt = self.ast.getNode(@enumFromInt(raw_idx));
            if (stmt.tag != .variable_declaration) continue;
            const e = stmt.data.extra;
            if (e + 2 >= self.ast.extra_data.items.len) continue;
            const dl_start = self.ast.extra_data.items[e + 1];
            const dl_len = self.ast.extra_data.items[e + 2];
            var di: u32 = 0;
            while (di < dl_len) : (di += 1) {
                const draw_idx = self.ast.extra_data.items[dl_start + di];
                const decl = self.ast.getNode(@enumFromInt(draw_idx));
                if (decl.tag != .variable_declarator) continue;
                const binding_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decl.data.extra]);
                if (binding_idx.isNone()) continue;
                const binding = self.ast.getNode(binding_idx);
                if (binding.tag != .binding_identifier) continue;
                if (std.mem.eql(u8, self.ast.getText(binding.span), name)) return true;
            }
        }
        return false;
    }

    /// arrow_function_expression: extra = [params_list, body, flags]
    /// flags: 0x01 = async
    fn visitArrowFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;
        const params_idx = self.readNodeIdx(e, 0);
        const body_idx = self.readNodeIdx(e, 1);
        const flags = self.readU32(e, 2);
        const new_params = try self.visitNode(params_idx);
        const new_body = try self.visitBodyWorkletAware(body_idx);
        const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_params), @intFromEnum(new_body), flags });
        const result = try self.ast.addNode(.{ .tag = .arrow_function_expression, .span = node.span, .data = .{ .extra = new_extra } });

        // Plugin dispatch: auto-workletization 등 AST 플러그인 적용
        const is_auto_worklet = self.plugins.worklet.auto_next;
        if (is_auto_worklet or self.options.plugins.len > 0) {
            // parser가 arrow params를 항상 formal_parameters list로 정규화하므로 tag 체크 불필요.
            const orig_params_list: NodeList = blk: {
                if (params_idx.isNone()) break :blk .{ .start = 0, .len = 0 };
                const n = self.ast.getNode(params_idx);
                break :blk if (n.tag == .formal_parameters) n.data.list else .{ .start = 0, .len = 0 };
            };
            const new_params_list: NodeList = blk: {
                if (new_params.isNone()) break :blk .{ .start = 0, .len = 0 };
                const n = self.ast.getNode(new_params);
                break :blk if (n.tag == .formal_parameters) n.data.list else .{ .start = 0, .len = 0 };
            };

            if (try self.dispatchFunctionPlugins(result, .{
                .node_idx = result,
                .node_tag = .arrow_function_expression,
                .name = null,
                .body_idx = new_body,
                .params = new_params_list,
                .original_params = orig_params_list,
                .original_body_idx = body_idx,
                .flags = flags,
                .source_path = self.options.jsx_filename,
                .is_auto_worklet = is_auto_worklet,
            })) |replacement| {
                return replacement;
            }
        }

        return result;
    }

    // ================================================================
    // Class + Decorator — transformer/class_decorator.zig로 위임
    // ================================================================
    const class_deco = @import("transformer/class_decorator.zig");

    /// Stage 3 decorator lowering이 필요한 class면 실행해 결과 NodeIndex 반환, 아니면 null.
    /// `unsupported.class` 분기보다 먼저 호출해 ES5 target에서 decorator silent drop을 방지한다.
    fn tryTransformStage3(self: *Transformer, node: Node) Error!?NodeIndex {
        if (self.options.experimental_decorators) return null;
        const e = node.data.extra;
        const class_deco_len = self.readU32(e, ast_mod.ClassExtra.deco_len);
        const has_member_decos = self.hasAnyMemberDecorators(e);
        if (class_deco_len == 0 and !has_member_decos) return null;
        return try self.transformStage3Decorators(node);
    }

    pub const visitClass = class_deco.visitClass;
    pub const visitClassWithAssignSemantics = class_deco.visitClassWithAssignSemantics;
    pub const buildStaticFieldAssignment = class_deco.buildStaticFieldAssignment;
    pub const classifyClassMember = class_deco.classifyClassMember;
    pub const classifyPropertyDefinition = class_deco.classifyPropertyDefinition;
    pub const classifyMethodDefinition = class_deco.classifyMethodDefinition;
    pub const applyFieldAssignments = class_deco.applyFieldAssignments;
    pub const ClassMemberContext = class_deco.ClassMemberContext;
    pub const FieldAssignment = class_deco.FieldAssignment;
    pub const MemberDecoratorInfo = class_deco.MemberDecoratorInfo;
    pub const visitDecoratorExpression = class_deco.visitDecoratorExpression;
    pub const collectMemberDecorators = class_deco.collectMemberDecorators;
    pub const collectParamDecorators = class_deco.collectParamDecorators;
    pub const appendParamDecorators = class_deco.appendParamDecorators;
    pub const buildDecorateParamCall = class_deco.buildDecorateParamCall;
    pub const insertFieldAssignmentsIntoConstructor = class_deco.insertFieldAssignmentsIntoConstructor;
    pub const isSuperCallStatement = class_deco.isSuperCallStatement;
    pub const buildConstructorWithFieldAssignments = class_deco.buildConstructorWithFieldAssignments;
    pub const buildThisAssignment = class_deco.buildThisAssignment;
    pub const transformExperimentalDecorators = class_deco.transformExperimentalDecorators;
    pub const buildDecorateClassMemberCall = class_deco.buildDecorateClassMemberCall;
    pub const buildDecorateClassCall = class_deco.buildDecorateClassCall;
    pub const serializeTypeAnnotation = class_deco.serializeTypeAnnotation;
    pub const buildMetadataCall = class_deco.buildMetadataCall;
    pub const buildParamTypesArray = class_deco.buildParamTypesArray;
    pub const appendMemberMetadata = class_deco.appendMemberMetadata;
    pub const appendClassMetadata = class_deco.appendClassMetadata;
    // Stage 3 (TC39) decorator
    pub const hasAnyMemberDecorators = class_deco.hasAnyMemberDecorators;
    pub const transformStage3Decorators = class_deco.transformStage3Decorators;
    pub const memberKeyToStringLiteral = class_deco.memberKeyToStringLiteral;
    pub const collectStage3Decorators = class_deco.collectStage3Decorators;
    pub const buildEsDecorateCall = class_deco.buildEsDecorateCall;
    pub const buildClassEsDecorateCall = class_deco.buildClassEsDecorateCall;
    pub const buildContextObject = class_deco.buildContextObject;
    pub const buildMetadataDecl = class_deco.buildMetadataDecl;
    pub const buildClassReassign = class_deco.buildClassReassign;
    pub const buildRunInitializersCall = class_deco.buildRunInitializersCall;
    pub const buildRunInitializersCall2 = class_deco.buildRunInitializersCall2;
    pub const buildStage3LetDeclarations = class_deco.buildStage3LetDeclarations;
    pub const makeLet = class_deco.makeLet;
    pub const makeObjProp = class_deco.makeObjProp;
    pub const buildAccessObject = class_deco.buildAccessObject;
    pub const buildFieldInitNames = class_deco.buildFieldInitNames;
    pub const buildMetadataDefineProperty = class_deco.buildMetadataDefineProperty;
    pub const buildGetterMethod = class_deco.buildGetterMethod;
    pub const buildSetterMethod = class_deco.buildSetterMethod;
    pub const extractCleanVarName = class_deco.extractCleanVarName;
    pub const appendEsDecorateStmt = class_deco.appendEsDecorateStmt;
    pub const wrapInStringLiteral = class_deco.wrapInStringLiteral;
    pub const extractTypeFromSource = class_deco.extractTypeFromSource;

    fn visitForStatement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const init_idx = self.readNodeIdx(e, 0);

        // ES2015 block scoping: let/const 변수 캡처 감지
        if (self.options.unsupported.block_scoping) {
            const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
            var lexical_names = try BlockScoping.collectLexicalVarNames(self, init_idx);
            defer lexical_names.deinit(self.allocator);

            if (lexical_names.items.len > 0) {
                // 원본 body에서 캡처/제어흐름 분석 (new AST에서는 extra 레이아웃이 변경됨)
                const orig_body_idx = self.readNodeIdx(e, 3);
                const has_capture = BlockScoping.hasCapturedClosure(self, orig_body_idx, lexical_names.items);
                const is_async = if (has_capture) BlockScoping.hasAwaitExpression(self, orig_body_idx) else false;

                // 제어 흐름 분석도 원본에서 수행
                var flow = BlockScoping.FlowResult{};
                defer flow.labels.deinit(self.allocator);
                if (has_capture) {
                    BlockScoping.analyzeControlFlow(self, orig_body_idx, &flow, 0, 0);
                }

                const new_init = try self.visitNode(init_idx);
                const new_test = try self.visitNode(self.readNodeIdx(e, 1));
                const new_update = try self.visitNode(self.readNodeIdx(e, 2));
                const new_body = try self.visitNode(orig_body_idx);

                if (has_capture) {
                    const result = try BlockScoping.buildLoopClosureWithFlow(
                        self,
                        new_body,
                        lexical_names.items,
                        &flow,
                        null,
                        node.span,
                        is_async,
                    );

                    // var _loop = function(...) { ... };
                    // for (var i = 0; ...) { _loop(i); }
                    const for_node = try self.addExtraNode(.for_statement, node.span, &.{
                        @intFromEnum(new_init),   @intFromEnum(new_test),
                        @intFromEnum(new_update), @intFromEnum(result.call_and_check),
                    });

                    // 두 문을 블록으로 반환 (호이스팅 불필요 — for 문 바로 앞에 삽입)
                    const stmts = try self.ast.addNodeList(&.{ result.loop_fn, for_node });
                    return self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = node.span,
                        .data = .{ .list = stmts },
                    });
                }

                return self.addExtraNode(.for_statement, node.span, &.{
                    @intFromEnum(new_init), @intFromEnum(new_test), @intFromEnum(new_update), @intFromEnum(new_body),
                });
            }
        }

        const new_init = try self.visitNode(init_idx);
        const new_test = try self.visitNode(self.readNodeIdx(e, 1));
        const new_update = try self.visitNode(self.readNodeIdx(e, 2));
        const new_body = try self.visitNode(self.readNodeIdx(e, 3));
        return self.addExtraNode(.for_statement, node.span, &.{
            @intFromEnum(new_init), @intFromEnum(new_test), @intFromEnum(new_update), @intFromEnum(new_body),
        });
    }

    /// switch_statement: extra = [discriminant, cases.start, cases.len]
    fn visitSwitchStatement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_disc = try self.visitNode(self.readNodeIdx(e, 0));
        const new_cases = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        return self.addExtraNode(.switch_statement, node.span, &.{
            @intFromEnum(new_disc), new_cases.start, new_cases.len,
        });
    }

    /// switch_case: extra_data = [test, stmts_start, stmts_len]
    fn visitSwitchCase(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_test = try self.visitNode(self.readNodeIdx(e, 0));
        const new_stmts = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
        return self.addExtraNode(.switch_case, node.span, &.{ @intFromEnum(new_test), new_stmts.start, new_stmts.len });
    }

    /// call_expression: extra = [callee, args_start, args_len, flags]
    pub fn visitCallExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 3 >= self.ast.extra_data.items.len) return NodeIndex.none;
        const callee_idx = self.readNodeIdx(e, 0);
        const args_start = self.readU32(e, 1);
        const args_len = self.readU32(e, 2);
        const flags = self.readU32(e, 3);

        // String.{replace,replaceAll} 의 replacement string 안 `$<name>` → `$N` 변환.
        // regex_lower 가 named group 을 strip하면 인덱스 매핑이 깨져 replacement 가 매칭 실패하므로,
        // literal regex + literal string 조합에 한해 replacement 도 함께 변환한다.
        if (self.options.unsupported.regex_named_groups and args_len == 2) {
            if (try self.tryRewriteReplaceNamedRefs(callee_idx, args_start)) |rewritten_args| {
                const new_callee = try self.visitNode(callee_idx);
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_callee), rewritten_args.start, rewritten_args.len, flags,
                });
                return self.ast.addNode(.{
                    .tag = .call_expression,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }
        }

        const new_callee = try self.visitNode(callee_idx);

        // Auto-workletization: callee 이름이 플러그인 목록에 매칭되면
        // 해당 인자 위치의 function/arrow에 plugins.worklet.auto_next 플래그를 설정.
        const auto_callee = self.matchAutoWorkletCallee(callee_idx);
        const new_args = if (auto_callee != null)
            try self.visitCallArgsWithAutoWorklet(args_start, args_len, auto_callee.?)
        else
            try self.visitExtraList(.{ .start = args_start, .len = args_len });

        const new_extra = try self.ast.addExtras(&.{
            @intFromEnum(new_callee), new_args.start, new_args.len, flags,
        });
        return self.ast.addNode(.{
            .tag = .call_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    // ================================================================
    // Regex replacement 변환 — transformer/regex.zig로 위임
    // ================================================================
    const regex_mod = @import("transformer/regex.zig");
    pub const tryRewriteReplaceNamedRefs = regex_mod.tryRewriteReplaceNamedRefs;
    pub const collectConstRegexDeclarators = regex_mod.collectConstRegexDeclarators;

    /// new_expression: extra = [callee, args_start, args_len, flags]
    fn visitNewExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        if (e + 3 >= self.ast.extra_data.items.len) return NodeIndex.none;
        const callee_idx = self.readNodeIdx(e, 0);
        const args_start = self.readU32(e, 1);
        const args_len = self.readU32(e, 2);
        const flags = self.readU32(e, 3);
        const new_callee = try self.visitNode(callee_idx);
        const new_args = try self.visitExtraList(.{ .start = args_start, .len = args_len });
        const new_extra = try self.ast.addExtras(&.{
            @intFromEnum(new_callee), new_args.start, new_args.len, flags,
        });
        return self.ast.addNode(.{
            .tag = .new_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    // method_definition: extra = [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
    // constructor의 parameter property (public x: number) 변환도 처리.
    // abstract 메서드는 런타임에 존재하면 안 되므로 완전히 제거.
    pub fn visitMethodDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, ast_mod.MethodExtra.flags);
        // abstract 메서드는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & ast_mod.MethodFlags.is_abstract) != 0) return NodeIndex.none;
        // TS method overload signature: body가 없으면 제거
        if (self.readNodeIdx(e, 2).isNone()) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));

        // 파라미터 방문 — parameter property 감지
        const params_idx_old = self.readNodeIdx(e, 1);
        var params_span = node.span;
        var params_list_old = NodeList{ .start = 0, .len = 0 };
        if (!params_idx_old.isNone()) {
            const pnode = self.ast.getNode(params_idx_old);
            if (pnode.tag == .formal_parameters) {
                params_list_old = pnode.data.list;
                params_span = pnode.span;
            }
        }
        var pp = try self.visitParamsCollectProperties(params_list_old);
        defer pp.prop_names.deinit(self.allocator);

        // arrow this/arguments 캡처: method도 자체 this 바인딩을 가짐 (visitFunction과 동일)
        const saved_arrow_depth = self.arrow_this_depth;
        const saved_needs_this = self.needs_this_var;
        const saved_needs_args = self.needs_arguments_var;
        const saved_super_alias = self.super_call_this_alias;
        self.arrow_this_depth = 0;
        self.needs_this_var = false;
        self.needs_arguments_var = false;
        self.super_call_this_alias = false;

        const is_ctor = (flags & ast_mod.MethodFlags.is_static) == 0 and
            es_helpers.isConstructorKey(self, self.readNodeIdx(e, ast_mod.MethodExtra.key));

        // ES2015 new.target: method → constructor 또는 void 0
        const saved_new_target_ctx = self.new_target_ctx;
        if (self.options.unsupported.new_target) {
            self.new_target_ctx = if (is_ctor) .constructor else .method;
        }
        defer self.new_target_ctx = saved_new_target_ctx;

        var new_body = try self.visitBodyWorkletAware(self.readNodeIdx(e, 2));

        // parameter property: derived class constructor 는 super() 후에, 그 외에는 body 앞에 prepend.
        // 전자에서 prepend 하면 `this` 가 super() 전 접근되어 ReferenceError.
        if (pp.prop_names.items.len > 0 and !new_body.isNone()) {
            if (is_ctor and self.current_super_class != null) {
                new_body = try self.insertParameterPropertyAssignmentsAfterSuper(new_body, pp.prop_names.items);
            } else {
                new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names.items);
            }
        }

        // arrow가 this/arguments를 사용했으면 var _this = this; 등 삽입
        if (self.options.unsupported.arrow and !new_body.isNone() and
            (self.needs_this_var or self.needs_arguments_var))
        {
            var capture_stmts: [2]NodeIndex = undefined;
            var capture_count: usize = 0;

            if (self.needs_this_var) {
                const this_init = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = node.span,
                    .data = .{ .none = 0 },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, node.span);
                capture_count += 1;
            }
            if (self.needs_arguments_var) {
                const args_span = try self.ast.addString("arguments");
                const args_init = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = args_span,
                    .data = .{ .string_ref = args_span },
                });
                capture_stmts[capture_count] = try self.buildVarDecl("_arguments", args_init, node.span);
                capture_count += 1;
            }

            new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
        }

        self.arrow_this_depth = saved_arrow_depth;
        self.needs_this_var = saved_needs_this;
        self.needs_arguments_var = saved_needs_args;
        self.super_call_this_alias = saved_super_alias;

        // experimentalDecorators 모드에서는 decorator를 class 수준에서 처리하므로
        // method_definition에서는 제거한다.
        const new_decos = if (self.options.experimental_decorators)
            NodeList{ .start = 0, .len = 0 }
        else
            try self.visitExtraList(.{ .start = self.readU32(e, 4), .len = self.readU32(e, 5) });
        const old_body_idx = self.readNodeIdx(e, 2);
        const new_params_node = try self.ast.addFormalParameters(pp.new_params, params_span);
        const result = try self.addExtraNode(.method_definition, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_params_node), @intFromEnum(new_body),
            self.readU32(e, 3),    new_decos.start,               new_decos.len,
        });

        // Plugin dispatch: worklet 등 AST 플러그인 적용
        // method_definition은 object/class 내부에 있으므로 IIFE 교체는 불가.
        // 대신 워크릿 플러그인이 method body 기반으로 function_expression을 생성하여
        // object_property value로 교체할 수 있도록 정보를 전달한다.
        const is_auto_worklet = self.plugins.worklet.auto_next;
        // method 이름 추출 (key가 identifier인 경우)
        const method_name: ?[]const u8 = blk: {
            const key_idx = self.readNodeIdx(e, 0);
            if (key_idx.isNone()) break :blk null;
            const key_node = self.ast.getNode(key_idx);
            if (key_node.tag == .identifier_reference) {
                break :blk self.ast.getText(key_node.span);
            }
            break :blk null;
        };
        if (try self.dispatchFunctionPlugins(result, .{
            .node_idx = result,
            .node_tag = .method_definition,
            .name = method_name,
            .body_idx = new_body,
            .params = pp.new_params,
            .original_params = params_list_old,
            .original_body_idx = old_body_idx,
            .flags = flags,
            .source_path = self.options.jsx_filename,
            .is_auto_worklet = is_auto_worklet,
        })) |replacement| {
            return replacement;
        }

        return result;
    }

    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
    // abstract 프로퍼티 (flags bit5=0x20) 및 declare 필드 (flags bit6=0x40)는
    // 런타임에 존재하면 안 되므로 완전히 제거.
    // declare 필드가 남으면 undefined로 초기화되어 의미가 바뀜.
    pub fn visitPropertyDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 2);
        // abstract(0x20), declare(0x40), Flow variance(0x80)는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & 0xE0) != 0) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        var new_value = try self.visitNode(self.readNodeIdx(e, 1));
        // styled-components: `class { static Child = styled.div\`\` }` 의 value 가 styled
        // tagged template 이면 field key 를 displayName 으로 사용해 wrap. 인스턴스 필드도
        // 동일하게 처리 (드물지만 가능). objectProperty 패턴 재사용.
        if (!new_key.isNone() and styled_components_mod.shouldAttemptWrap(self, new_value)) {
            if (styled_components_mod.objectPropertyKeyName(self, new_key)) |key_name| {
                new_value = try styled_components_mod.wrapStyledTagInExpr(self, new_value, key_name);
            }
        }
        // experimentalDecorators 모드에서는 decorator를 class 수준에서 처리하므로
        // property_definition에서는 제거한다.
        const new_decos = if (self.options.experimental_decorators)
            NodeList{ .start = 0, .len = 0 }
        else
            try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = self.readU32(e, 4) });
        return self.addExtraNode(.property_definition, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            new_decos.start,       new_decos.len,
        });
    }

    // accessor_property: extra = [key, init_val, flags, deco_start, deco_len]
    pub fn visitAccessorProperty(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 2);
        // declare accessor는 타입 전용이므로 완전히 스트리핑
        if (self.options.strip_types and (flags & ast_mod.PropertyFlags.is_declare) != 0) return NodeIndex.none;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        var new_value = try self.visitNode(self.readNodeIdx(e, 1));
        // styled-components: property_definition 와 동일 — accessor 필드도 init 이 styled
        // tagged template 이면 wrap. 드물지만 symmetry.
        if (!new_key.isNone() and styled_components_mod.shouldAttemptWrap(self, new_value)) {
            if (styled_components_mod.objectPropertyKeyName(self, new_key)) |key_name| {
                new_value = try styled_components_mod.wrapStyledTagInExpr(self, new_value, key_name);
            }
        }
        const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = self.readU32(e, 4) });
        return self.addExtraNode(.accessor_property, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            new_decos.start,       new_decos.len,
        });
    }

    /// object_property: binary = { left=key, right=value, flags }
    fn visitObjectProperty(self: *Transformer, node: Node) Error!NodeIndex {
        // ES2015: shorthand property 확장 ({ x } → { x: x })
        if (self.options.unsupported.object_extensions and node.data.binary.right.isNone()) {
            return es2015_shorthand.ES2015Shorthand(Transformer).expandShorthand(self, node);
        }
        // non-computed key(identifier, string, numeric)는 property 이름이므로
        // block scoping rename 등 변수 치환을 적용하면 안 됨. copyNodeDirect 사용.
        // symbol_id는 항상 전파: shorthand({ x })에서 codegen이 rename을
        // 감지하여 { x: x$1 }로 확장하는 데 필요. non-shorthand/literal key는
        // codegen이 writeSpan으로 출력하므로 symbol_id가 있어도 무시됨.
        const key_idx = node.data.binary.left;
        const new_key = if (!key_idx.isNone() and self.ast.getNode(key_idx).tag != .computed_property_key)
            try self.copyNodeDirect(key_idx)
        else
            try self.visitNode(key_idx);
        self.propagateSymbolId(key_idx, new_key);
        var new_value = try self.visitNode(node.data.binary.right);
        // styled-components: { One: styled.div`...` } 의 value 가 styled tagged template 이면
        // property key 이름을 displayName 으로 사용해 wrap. variable_declarator 와 동일 패턴.
        if (!new_key.isNone() and styled_components_mod.shouldAttemptWrap(self, new_value)) {
            if (styled_components_mod.objectPropertyKeyName(self, new_key)) |prop_name| {
                new_value = try styled_components_mod.wrapStyledTagInExpr(self, new_value, prop_name);
            }
        }
        return self.ast.addNode(.{
            .tag = .object_property,
            .span = node.span,
            .data = .{ .binary = .{
                .left = new_key,
                .right = new_value,
                .flags = node.data.binary.flags,
            } },
        });
    }

    /// formal_parameter:
    ///   extra = [pattern, type_ann, default, flags, deco_start, deco_len]
    /// flags: parameter property modifier (public=0x01, private=0x02, protected=0x04, readonly=0x08, override=0x10)
    /// parameter property (flags!=0)는 visitFunction/visitMethodDefinition에서 직접 처리하지만,
    /// 다른 경로에서 도달할 수 있으므로 방어적으로 처리.
    fn visitFormalParameter(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 3);
        // parameter property: modifier 제거하고 내부 패턴만 반환
        if (flags != 0) {
            return self.visitNode(self.readNodeIdx(e, 0));
        }
        const new_pattern = try self.visitNode(self.readNodeIdx(e, 0));
        const new_default = try self.visitNode(self.readNodeIdx(e, 2));
        const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, 4), .len = self.readU32(e, 5) });
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.formal_parameter, node.span, &.{
            @intFromEnum(new_pattern), none,            @intFromEnum(new_default), // type_ann 제거
            0,                         new_decos.start, new_decos.len,
        });
    }

    // ================================================================
    // Import/export 변환 — transformer/import_export.zig로 위임
    // ================================================================
    const import_export_mod = @import("transformer/import_export.zig");
    pub const visitExportDefaultDeclaration = import_export_mod.visitExportDefaultDeclaration;
    pub const visitImportDeclaration = import_export_mod.visitImportDeclaration;
    pub const shouldElideImportSpecifier = import_export_mod.shouldElideImportSpecifier;
    pub const visitExportAllDeclaration = import_export_mod.visitExportAllDeclaration;
    pub const visitExportNamedDeclaration = import_export_mod.visitExportNamedDeclaration;

    // ================================================================
    // Comptime 헬퍼 — TS 타입 전용 노드 판별 (D042)
    // ================================================================

    /// TS 타입 전용 노드인지 판별한다 (comptime 평가).
    ///
    /// 이 함수는 컴파일 타임에 평가되므로 런타임 비용이 0이다.
    /// tag의 정수 값 범위로 판별하지 않고 명시적으로 나열한다.
    /// 이유: enum 값 순서가 바뀌어도 안전하게 동작하도록.
    pub fn isTypeOnlyNode(tag: Tag) bool {
        return switch (tag) {
            // TS 타입 키워드 (14개)
            .ts_any_keyword,
            .ts_string_keyword,
            .ts_boolean_keyword,
            .ts_number_keyword,
            .ts_never_keyword,
            .ts_unknown_keyword,
            .ts_null_keyword,
            .ts_undefined_keyword,
            .ts_void_keyword,
            .ts_symbol_keyword,
            .ts_object_keyword,
            .ts_bigint_keyword,
            .ts_this_type,
            .ts_intrinsic_keyword,
            // TS 타입 구문 (23개)
            .ts_type_reference,
            .ts_qualified_name,
            .ts_array_type,
            .ts_tuple_type,
            .ts_named_tuple_member,
            .ts_union_type,
            .ts_intersection_type,
            .ts_conditional_type,
            .ts_type_operator,
            .ts_optional_type,
            .ts_rest_type,
            .ts_indexed_access_type,
            .ts_type_literal,
            .ts_function_type,
            .ts_constructor_type,
            .ts_mapped_type,
            .ts_template_literal_type,
            .ts_infer_type,
            .ts_parenthesized_type,
            .ts_import_type,
            .ts_type_query,
            .ts_literal_type,
            .ts_type_predicate,
            // TS/Flow 선언 (통째로 삭제) — isTypeOnlyDeclaration() 대상 포함
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_interface_body,
            .ts_property_signature,
            .ts_method_signature,
            .ts_call_signature,
            .ts_construct_signature,
            .ts_index_signature,
            .ts_getter_signature,
            .ts_setter_signature,
            // TS 타입 파라미터/this/implements
            .ts_type_parameter,
            .ts_type_parameter_declaration,
            .ts_type_parameter_instantiation,
            .ts_this_parameter,
            .ts_class_implements,
            // namespace는 런타임 코드 생성 → visitNode에서 별도 처리
            // ts_namespace_export_declaration은 타입 전용 (export as namespace X)
            .ts_namespace_export_declaration,
            // TS import/export 특수 형태
            // ts_import_equals_declaration / ts_export_assignment 는 런타임 코드 생성
            // — visitNode 에서 별도 처리.
            .ts_external_module_reference,
            // enum은 타입 전용이 아님 — 런타임 코드 생성이 필요
            // visitNode의 switch에서 별도 처리
            // Flow 타입 (flow.zig에서 생성)
            .flow_any_keyword,
            .flow_string_keyword,
            .flow_boolean_keyword,
            .flow_number_keyword,
            .flow_never_keyword,
            .flow_null_keyword,
            .flow_void_keyword,
            .flow_symbol_keyword,
            .flow_bigint_keyword,
            .flow_this_type,
            .flow_mixed_keyword,
            .flow_empty_keyword,
            .flow_type_reference,
            .flow_qualified_name,
            .flow_array_type,
            .flow_tuple_type,
            .flow_union_type,
            .flow_intersection_type,
            .flow_function_type,
            .flow_parenthesized_type,
            .flow_literal_type,
            .flow_type_query,
            .flow_nullable_type,
            .flow_type_parameter,
            .flow_type_parameter_declaration,
            .flow_type_parameter_instantiation,
            .flow_this_parameter,
            .flow_type_alias_declaration,
            .flow_opaque_type,
            .flow_interface_declaration,
            .flow_object_type,
            .flow_exact_object_type,
            .flow_property_signature,
            .flow_object_spread_property,
            => true,
            else => false,
        };
    }

    // ================================================================
    // React Fast Refresh — transformer/refresh.zig로 위임
    // ================================================================
    const refresh = @import("transformer/refresh.zig");
    pub const isComponentName = refresh.isComponentName;
    pub const getFunctionName = refresh.getFunctionName;
    pub const maybeRegisterRefreshComponent = refresh.maybeRegisterRefreshComponent;
    pub const makeRefreshHandle = refresh.makeRefreshHandle;
    pub const appendRefreshRegistrations = refresh.appendRefreshRegistrations;
    pub const buildRefreshAssignment = refresh.buildRefreshAssignment;
    pub const buildRefreshVarDeclaration = refresh.buildRefreshVarDeclaration;
    pub const buildRefreshRegCall = refresh.buildRefreshRegCall;
    pub const buildRefreshSigDeclaration = refresh.buildRefreshSigDeclaration;
    pub const buildRefreshSigCall = refresh.buildRefreshSigCall;
    pub const isHookCall = refresh.isHookCall;
    pub const scanHookSignature = refresh.scanHookSignature;
    pub const findHookCallsInNode = refresh.findHookCallsInNode;
    pub const findHookCallsInNodeDepth = refresh.findHookCallsInNodeDepth;
    pub const makeSigHandle = refresh.makeSigHandle;
    pub const maybeRegisterRefreshSignature = refresh.maybeRegisterRefreshSignature;
    pub const insertSigCallAtBodyStart = refresh.insertSigCallAtBodyStart;

    // ================================================================
    // Auto-workletization helpers — transformer/auto_worklet.zig로 위임
    // ================================================================
    const auto_worklet = @import("transformer/auto_worklet.zig");
    pub const matchAutoWorkletCallee = auto_worklet.matchAutoWorkletCallee;
    pub const visitCallArgsWithAutoWorklet = auto_worklet.visitCallArgsWithAutoWorklet;

    // ================================================================
    // Plugin dispatch helper
    // ================================================================

    /// 함수-유사 노드의 body가 extra_data에서 차지하는 슬롯 오프셋.
    /// parser/ast.zig의 노드 extra 레이아웃 정의와 일치해야 한다.
    fn functionBodyOffset(tag: @import("../parser/ast.zig").Node.Tag) u32 {
        return switch (tag) {
            // arrow: [params(0), body(1), flags]
            .arrow_function_expression => 1,
            // function_declaration/expression/method_definition: [name/key(0), params(1), body(2), flags(3), ...]
            else => 2,
        };
    }

    /// Plugin visitor 훅 dispatch — 지정된 tag에 등록된 훅을 순회하며 first-wins로 호출.
    /// 모든 훅이 null 반환이면 null → caller가 default 방문 진행.
    pub const VisitorHookKind = enum { on_program, on_object_expression, on_call_expression, on_class_declaration, on_class_expression };
    pub fn dispatchVisitor(self: *Transformer, comptime kind: VisitorHookKind, node_idx: NodeIndex) Error!?NodeIndex {
        if (self.options.plugins.len == 0) return null;
        var api = AstTransformCtx{ .transformer = self };
        for (self.options.plugins) |p| {
            const v = p.visitor orelse continue;
            // enum → struct field: @tagName이 런타임 오버헤드 없이 comptime 매핑.
            // 새 훅 추가 시 enum + Visitor struct만 수정하면 됨 (switch 분기 불필요).
            const hook = @field(v, @tagName(kind)) orelse continue;
            const result = hook(p.context, &api, node_idx) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PluginFailed => continue,
            };
            if (result) |r| return r;
        }
        return null;
    }

    /// onFunction 플러그인 훅을 실행한다.
    /// 플러그인이 함수를 교체하면 새 NodeIndex를 반환, 아니면 null.
    /// body 수정 시 result 노드의 extra_data를 직접 패치한다.
    pub fn dispatchFunctionPlugins(self: *Transformer, result: NodeIndex, func_info: FunctionInfo) Error!?NodeIndex {
        if (self.options.plugins.len == 0) return null;
        var api = AstTransformCtx{ .transformer = self, .modified_body = null };
        defer api.deinitClosureCache();
        for (self.options.plugins) |p| {
            if (p.onFunction) |hook| {
                hook(p.context, &api, func_info) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.PluginFailed => {},
                };
            }
        }
        if (api.modified_body) |new_body_idx| {
            const result_extra = self.ast.getNode(result).data.extra;
            self.ast.extra_data.items[result_extra + functionBodyOffset(func_info.node_tag)] = @intFromEnum(new_body_idx);
        }
        return api.replaced_node;
    }
};
