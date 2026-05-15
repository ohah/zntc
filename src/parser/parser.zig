//! ZNTC Parser
//!
//! 토큰 스트림을 AST로 변환하는 재귀 하강(recursive descent) 파서.
//! 2패스 설계: parse → visit (D040).
//! 에러 복구: 다중 에러 수집 (D039).
//!
//! 참고:
//! - references/bun/src/js_parser.zig
//! - references/oxc/crates/oxc_parser/src/

const std = @import("std");
const profile = @import("../profile.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Token = token_mod.Token;
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const jsx = @import("jsx.zig");
const ts = @import("ts.zig");
const flow = @import("flow.zig");
const diagnostic = @import("../diagnostic.zig");
pub const Diagnostic = diagnostic.Diagnostic;
const scan_results_mod = @import("scan_results.zig");
const import_scanner = @import("../bundler/import_scanner.zig");
pub const scan_results = scan_results_mod;

/// 재귀 함수용 명시적 에러 타입.
/// Zig는 재귀 함수에서 `!T` (inferred error set)를 사용할 수 없다.
/// 파서의 모든 에러는 메모리 할당 실패뿐이므로 Allocator.Error로 충분하다.
pub const ParseError2 = std.mem.Allocator.Error;

/// 괄호 매칭 정보. 여는 괄호를 만나면 push, 닫는 괄호를 만나면 pop.
/// 닫는 괄호 에러 시 "opened here" 위치를 보여주기 위해 사용.
const BracketInfo = struct {
    kind: Kind,
    span: Span,
};

/// 파서 입력의 source-type 3-state. "TS 문법을 거부하지 않으면서도 TS 가 아닌" js_lenient 와
/// "명시 JS 라서 TS 문법을 거부하는" js_strict 가 별개 상태라 두 boolean 으로는 (true,true)
/// 같은 불가능 조합이 표현 가능했고, 이를 enum 으로 차단한다.
pub const SourceMode = enum {
    /// JS 입력이지만 source-type signal 이 없는 legacy 모드 (standalone transpile + unknown
    /// extension 등). TS 문법은 silent 통과. 새 입력 경로에는 사용하지 말 것.
    js_lenient,
    /// .js/.jsx/.mjs/.cjs 또는 loader=js/jsx 로 source-type 이 명시된 JS. TS 문법 거부.
    js_strict,
    /// .ts/.tsx/.mts/.cts 또는 loader=ts/tsx 로 source-type 이 명시된 TS.
    ts,
};

/// 재귀 하강 파서.
/// Scanner에서 토큰을 하나씩 읽어 AST를 구축한다.
pub const Parser = struct {
    /// 렉서 (토큰 공급)
    scanner: *Scanner,

    /// AST 저장소
    ast: Ast,

    /// 수집된 에러 목록 (D039: 다중 에러)
    errors: std.ArrayList(Diagnostic),

    /// Unambiguous 모드에서 모듈 전용 에러를 지연 수집하는 버퍼.
    /// 파싱 완료 후 모듈로 확정되면 errors에 병합, 스크립트면 폐기.
    /// oxc의 deferred_module_errors와 동일한 역할.
    deferred_module_errors: std.ArrayList(Diagnostic),

    /// 재사용 가능한 임시 버퍼 (리스트 수집용). 매 사용 시 clearRetainingCapacity.
    scratch: std.ArrayList(NodeIndex),

    /// Inline import/export scanning (bundler mode). Populated when enable_scan=true.
    /// 파서가 AST를 구축하면서 동시에 import/export 레코드와 바인딩을 수집한다.
    /// .empty (allocator 미지정) 상태이므로 append 시 반드시 self.allocator를 전달해야 한다.
    scan_import_records: std.ArrayListUnmanaged(scan_results_mod.ScanImportRecord) = .empty,
    scan_import_bindings: std.ArrayListUnmanaged(scan_results_mod.ScanImportBinding) = .empty,
    scan_export_bindings: std.ArrayListUnmanaged(scan_results_mod.ScanExportBinding) = .empty,
    /// checkBarrelReExport용 O(1) 조회 맵: local_name → scan_import_bindings 인덱스.
    /// 첫 조회 시 lazy 구축.
    scan_import_binding_map: std.StringHashMapUnmanaged(u32) = .{},
    scan_result: scan_results_mod.ScanResult = .{},
    /// Enable inline scanning. Set to true by bundler before parsing.
    enable_scan: bool = false,

    /// Define entries — `process.env.X` 같은 member access 를 string literal 로 평가.
    /// require.context 인자 평가 (Phase 2.6) 와 미래 build-time 정적 평가에 활용.
    /// bundler 가 parse 전 설정. 비어있으면 evaluator 가 define lookup 안 함. (#1579)
    scan_defines: []const scan_results_mod.DefineEntry = &.{},
    /// define으로 죽은 분기를 파싱 중일 때 inline require 스캔을 막는 깊이.
    scan_dead_depth: u32 = 0,

    /// arrow 파라미터 중복 검사용 임시 이름 수집 버퍼.
    param_name_spans: std.ArrayList(Span),

    /// 괄호 매칭 스택 — 여는 괄호의 위치를 추적하여 닫힘 에러 시 "opened here" 표시.
    bracket_stack: std.ArrayList(BracketInfo),

    /// 메모리 할당자
    allocator: std.mem.Allocator,

    // ================================================================
    // 컨텍스트 플래그 (D051: 파서에서 구문 컨텍스트 추적)
    // ================================================================
    //
    // Context(u8)는 ECMAScript 문법 파라미터([+In], [+Yield] 등)만 포함한다.
    // 나머지 파서 상태는 개별 bool 필드로 관리한다.
    //
    // is_module은 파싱 시작 시 한 번 결정되고 변하지 않는 불변 설정이므로
    // Context에 포함하지 않고 별도 필드로 관리한다 (oxc/Babel/Hermes 방식).

    /// 파싱 컨텍스트 bitflags — ECMAScript 문법 파라미터만 포함.
    ctx: Context = Context.default,

    /// module 모드인지 (import/export 허용, 항상 strict).
    /// 파싱 시작 시 한 번 결정되는 불변 설정이므로 Context에 포함하지 않음.
    /// Unambiguous 모드에서는 낙관적으로 true로 시작하고, 파싱 후 확정.
    is_module: bool = false,

    /// Unambiguous 모드인지 (.ts/.tsx — 내용 기반 모듈 판별, oxc 방식).
    /// true이면 is_module=true로 낙관적 파싱하되, 모듈 전용 에러를 지연 수집.
    /// 파싱 완료 후 import/export 유무로 확정: 없으면 is_module=false + 에러 폐기.
    is_unambiguous: bool = false,

    /// import/export/import.meta가 발견되었는지. Unambiguous 모드에서 모듈 확정 기준.
    has_module_syntax: bool = false,

    /// namespace body 안인지. export/import를 허용하되 await를 키워드로 취급하지 않음.
    /// is_module과 분리: namespace는 export/import를 허용하지만 module code가 아님.
    in_namespace: bool = false,

    /// JSX 모드 (TSX). true이면 <는 JSX 엘리먼트 시작으로 우선 해석.
    /// false이면 <T>()=>{}가 제네릭 arrow로 해석.
    is_jsx: bool = false,

    /// 파서가 보는 source-type. 변형별 의미는 SourceMode 정의 참고.
    source_mode: SourceMode = .js_lenient,

    /// Flow 모드 (.js/.jsx + @flow pragma, .js.flow, 또는 --flow CLI).
    /// Flow 타입 어노테이션 파싱 및 스트리핑을 활성화한다.
    is_flow: bool = false,

    // ================================================================
    // 개별 파서 상태 플래그
    // ================================================================

    /// TS 타입 어노테이션 안인지 (렉서 동작 변경: `<`/`>`를 타입 구분자로)
    in_type: bool = false,
    /// 함수 파라미터 안인지
    in_parameters: bool = false,
    /// new.target 허용 여부
    allow_new_target: bool = false,
    /// constructor 안인지
    is_constructor: bool = false,
    /// await using 파싱 중인지 (parseAwaitUsingDeclaration → parseVariableDeclaration에서 kind=.await_using으로 설정)
    is_await_using: bool = false,
    /// strict mode 여부 (D054: "use strict" directive 또는 module mode)
    is_strict_mode: bool = false,
    /// strict mode 가 영구적인지 — unambiguous 해소 결과에 좌우되지 않음.
    /// `true` 인 경우:
    ///   1) `"use strict"` directive (script/module 둘 다 유효)
    ///   2) TS spec 의 implicit strict (`.ts/.tsx/.cts` — D16.1, import/export 유무
    ///      와 무관하게 strict 유지)
    /// `addStrictModuleErrorCode` 가 unambiguous 모드에서 지연할지 즉시 발화할지 판단,
    /// 그리고 `resolveModuleKind` 가 script fallback 시 strict 를 해제할지 결정한다.
    strict_persistent: bool = false,
    /// 루프 안에 있는지 (continue 유효성 검증용)
    in_loop: bool = false,
    /// switch 안에 있는지 (break 유효성 검증용 — break는 loop OR switch에서 허용)
    in_switch: bool = false,
    /// 현재 파싱 중인 함수의 파라미터가 simple인지 (non-simple이면 "use strict" 금지)
    has_simple_params: bool = true,
    /// for 초기화절 안인지 (for-in/for-of 구분)
    for_loop_init: bool = false,
    /// class 본문 안인지
    in_class: bool = false,
    /// class field 초기값 안인지
    in_class_field: bool = false,
    /// extends 있는 class인지 (super() 허용 판단)
    has_super_class: bool = false,
    /// class가 위치한 외부 스코프의 async 컨텍스트.
    /// 파라미터 데코레이터는 메서드가 아닌 클래스의 외부 스코프에서 평가되므로,
    /// @dec(await x)에서 await이 유효한지 판단할 때 이 값을 사용한다.
    class_scope_async: bool = false,
    /// super() 호출 허용 여부 (constructor + extends)
    allow_super_call: bool = false,
    /// super.x / super[x] 허용 여부
    allow_super_property: bool = false,
    /// static initializer (static { }) 안인지 — arguments 사용 금지
    in_static_initializer: bool = false,
    /// object literal에서 CoverInitializedName (shorthand with default: { x = 1 }) 가 있었는지.
    /// cover grammar 변환(destructuring)에서 소비되지 않으면 에러.
    has_cover_init_name: bool = false,
    /// formal parameter 파싱 중인지 (yield/await expression 금지).
    in_formal_parameters: bool = false,
    /// Flow 반환 타입 파싱 중 — shorthand 함수 타입 `Type => Type` 금지.
    /// (): any => {} 에서 any 뒤 =>가 arrow body인지 shorthand인지 구분.
    flow_in_return_type: bool = false,
    /// Flow conditional type 의 check/extends 타입 파싱 중인지. true 면 outer
    /// `?` 가 conditional 의 일부이므로, `infer A extends B ?` 같은 모호한
    /// sequence 에서 `extends B` 를 infer 가 흡수하지 않고 outer 로 양보.
    /// Hermes 의 `allowConditionalType_` 와 동등. 기본 true.
    flow_allow_conditional_type: bool = true,
    /// enum 멤버 초기값 파싱 중인지.
    /// true이면 await/yield를 키워드가 아닌 식별자로 취급한다.
    /// (enum 내에서 다른 멤버를 참조: `enum X { await = 1, y = await }`)
    in_enum_initializer: bool = false,
    /// if/with/labeled body에서 labelled function statement 금지 체크 중인지.
    /// IsLabelledFunction(Statement) is true → SyntaxError
    in_labelled_fn_check: bool = false,
    /// ternary의 consequent 파싱 중인지.
    /// true이면 `(identifier) :` 패턴을 typed arrow로 해석하지 않는다 — `:` 가
    /// ternary separator일 수 있기 때문. `(identifier: Type)` 등 확실한 패턴은 여전히 허용.
    in_ternary_consequent: bool = false,
    /// `trySkipTypeArgsSpeculative` 안에서 type-args 를 speculative 파싱 중인지.
    /// inner `parseType` → `<T>(x = expr) => R` 같은 generic function type 의
    /// parameter default 가 expression-mode 로 재진입하면, 그 안의 `<<` 가 또
    /// generic-call speculation 을 발화해 O(2^N) nest 폭주 (TSC conformance
    /// `parserRealSource2.ts`). speculation 안에서는 callable 후보를 더 따질
    /// 필요가 없으므로 (외부 speculation 의 성공/실패만 남기면 됨) 이 플래그가
    /// true 일 때 expression 의 generic-call speculation 진입을 차단한다.
    in_type_args_speculation: bool = false,

    // ================================================================
    // Context packed struct 정의
    // ================================================================

    /// ECMAScript 문법 파라미터를 추적하는 bitflags.
    ///
    /// packed struct(u8)에는 문법 파라미터(allow_in, in_generator 등)만 포함한다.
    /// 나머지 파서 상태(is_strict_mode, in_loop 등)는 Parser의 개별 필드로 관리.
    ///
    /// 기본값 주의: allow_in, is_top_level은 기본값이 true.
    pub const Context = packed struct(u8) {
        /// `in` 연산자 허용 여부 (for-in/for-of 초기화절에서는 false로 설정하여
        /// `in`을 관계 연산자가 아닌 for-in 키워드로 파싱)
        allow_in: bool = true,
        /// generator 함수 안에 있는지 (yield 키워드 유효성 검증용)
        in_generator: bool = false,
        /// async 함수 안에 있는지 (await 키워드 유효성 검증용)
        in_async: bool = false,
        /// 함수 본문 안에 있는지 (return 유효성 검증용)
        in_function: bool = false,
        /// 최상위 레벨인지 (top-level await 감지용)
        is_top_level: bool = true,
        /// decorator 파싱 중인지
        in_decorator: bool = false,
        /// TS declare 블록 또는 .d.ts 파일 안인지
        in_ambient: bool = false,
        /// TS 조건부 타입 금지 (infer 절에서 extends를 제약으로 파싱)
        disallow_conditional_types: bool = false,

        /// 기본값: allow_in=true, is_top_level=true, 나머지 false.
        pub const default: Context = .{};

        /// 함수 진입 시 Context(문법 파라미터)를 설정한다.
        /// in_function=true, is_top_level=false, async/generator는 인자로 설정.
        pub fn enterFunction(self: Context, is_async: bool, is_generator: bool) Context {
            var new = self;
            new.in_function = true;
            new.in_async = is_async;
            new.in_generator = is_generator;
            new.is_top_level = false;
            return new;
        }
    };

    /// 함수/메서드 진입 시 저장되는 상태.
    /// enterFunctionContext()로 저장, restoreFunctionContext()로 복원.
    const SavedState = struct {
        ctx: Context,
        is_strict_mode: bool,
        in_loop: bool,
        in_switch: bool,
        has_simple_params: bool,
        for_loop_init: bool,
        in_class_field: bool,
        in_static_initializer: bool,
        allow_new_target: bool,
        allow_super_call: bool,
        allow_super_property: bool,
        in_formal_parameters: bool,
        in_ternary_consequent: bool,
    };

    pub fn init(allocator: std.mem.Allocator, scanner: *Scanner) Parser {
        return .{
            .scanner = scanner,
            .ast = Ast.init(allocator, scanner.source),
            .errors = .empty,
            .deferred_module_errors = .empty,
            .scratch = .empty,
            .param_name_spans = .empty,
            .bracket_stack = blk: {
                var stack: std.ArrayList(BracketInfo) = .empty;
                stack.ensureTotalCapacity(allocator, 8) catch {}; // pre-alloc 실패해도 동작에 지장 없음
                break :blk stack;
            },
            .allocator = allocator,
        };
    }

    /// 파일 확장자에 따라 is_module, is_jsx를 설정한다.
    /// main.zig와 bundler graph.zig에서 중복 없이 사용.
    ///
    /// oxc 방식 Unambiguous 모드:
    /// - .mts/.mjs → 확정적 Module (is_module=true)
    /// - .ts/.tsx/.cts → Unambiguous (is_module=true 낙관적 파싱 + 에러 지연).
    ///                    .cts 는 TS CommonJS 인데 tsc 정책상 ESM 구문 허용 → module.exports 로 transpile.
    /// - .js/.jsx → Unambiguous (is_module=true 낙관적 파싱 — esbuild/swc/rollup 와
    ///                            동일하게 ESM 코드도 받음. 순수 script 코드도 호환)
    /// - .cjs → Script (is_module=false, Node CommonJS — `import`/`export`/top-level-await 거부)
    /// CLI용: .ts/.tsx는 Unambiguous 모드 (import/export 유무로 module/script 파싱 후 확정)
    pub fn configureFromExtension(self: *Parser, ext: []const u8) void {
        self.applyExtension(ext, true);
    }

    /// 번들러용: .ts/.tsx를 확정 module로 파싱 (await 키워드, strict mode 항상 적용)
    pub fn configureForBundler(self: *Parser, ext: []const u8) void {
        self.applyExtension(ext, false);
    }

    /// 번들러용: 확장자 매칭을 거치지 않고 TS/JSX 플래그를 직접 덮어쓴다.
    /// 확장자 기반 module/script 판정은 configureForBundler()가 맡고, 이 함수는 source type만
    /// 갱신한다. `--loader:.foo=tsx` 또는 `--loader:.ts=js`처럼 확장자와 parser 의미가
    /// 어긋날 때 사용. parser는 standalone 모듈이라 bundler의 ModuleType 을 직접 참조하지
    /// 않고 호출자가 (is_ts, is_jsx) 로 변환해서 넘긴다.
    pub fn configureForBundlerKind(self: *Parser, is_ts: bool, is_jsx: bool) void {
        self.source_mode = if (is_ts) .ts else .js_strict;
        self.is_jsx = is_jsx;
        if (is_ts) {
            self.is_module = true;
            self.scanner.is_module = true;
            self.is_unambiguous = false;
        }
    }

    fn applyExtension(self: *Parser, ext: []const u8, ts_unambiguous: bool) void {
        if (std.mem.eql(u8, ext, ".mts") or std.mem.eql(u8, ext, ".mjs")) {
            self.is_module = true;
            self.scanner.is_module = true;
        } else if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".cts"))
        {
            // .cts 는 Node 입장에선 CJS 지만 tsc 가 ESM 구문을 받아 module.exports 로
            // transpile. parser 레벨에선 module 로 파싱.
            //
            // D16: TypeScript spec — 모든 TS 파일은 implicit strict (tsc TS1212/TS1100).
            // strict 는 `strict_persistent=true` 로 영구화 → `let/yield/private/static`
            // 등 strict reserved 식별자가 즉시 거부된다 (회귀 가드 D16).
            //
            // D16.1: `await` 는 strict 와 무관한 module-only reserved word (ECMAScript
            // 12.1.1). import/export 가 없는 TS 파일은 TS auto module detection 기준
            // script 라 await 를 식별자로 허용해야 함 (TSC asyncFunctionDeclaration2/4/11,
            // asyncArrowFunction4/5 conformance). 따라서 module 판정은 `is_unambiguous`
            // 로 유지하여 module-only 에러는 import/export 유무에 따라 해소한다.
            self.is_module = true;
            self.scanner.is_module = true;
            self.is_unambiguous = true;
            self.is_strict_mode = true;
            self.strict_persistent = true;
        } else if (ts_unambiguous and
            (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx")))
        {
            // CLI/transpile 모드 전용. 번들러 (ts_unambiguous=false) 는 `graph.zig`
            // 의 `def_format` 분류 (package.json#type 인식 포함) 로 module/script
            // 를 결정 — 거기서 unambiguous 도 같이 set 한다. 여기서 비-bundler
            // 경로만 esbuild/swc/rollup 와 동일하게 `.js` 를 낙관적 module 로 받음.
            self.is_module = true;
            self.scanner.is_module = true;
            self.is_unambiguous = true;
        }
        if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".mts") or std.mem.eql(u8, ext, ".cts"))
        {
            self.source_mode = .ts;
        } else if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or
            std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs"))
        {
            self.source_mode = .js_strict;
        }
        if (std.mem.eql(u8, ext, ".tsx") or std.mem.eql(u8, ext, ".jsx")) {
            self.is_jsx = true;
        }
    }

    /// 파일 경로에서 `.d.ts` / `.d.mts` / `.d.cts` 이중 확장자를 감지하여 ambient
    /// context 를 설정한다. `.d.ts` 의 모든 declaration 은 implicit `declare` — const
    /// initializer / function body / class field initializer 강제가 적용되지 않는다.
    /// `std.fs.path.extension()` 은 `.ts` 만 반환하므로 전체 경로 검사 필요.
    pub fn configureAmbientFromPath(self: *Parser, file_path: []const u8) void {
        if (std.mem.endsWith(u8, file_path, ".d.ts") or
            std.mem.endsWith(u8, file_path, ".d.mts") or
            std.mem.endsWith(u8, file_path, ".d.cts"))
        {
            self.ctx.in_ambient = true;
        }
    }

    /// 파일 경로에서 .js.flow / .jsx.flow 이중 확장자를 감지하여 Flow 모드를 설정한다.
    /// std.fs.path.extension()은 마지막 확장자(.flow)만 반환하므로
    /// 전체 경로를 확인해야 한다.
    /// TS 와 Flow 는 상호 배타적이므로, TS 파일에서는 설정하지 않는다.
    pub fn configureFlowFromPath(self: *Parser, file_path: []const u8) void {
        if (self.source_mode == .ts) return; // TS와 Flow는 상호 배타
        if (std.mem.endsWith(u8, file_path, ".js.flow")) {
            self.is_flow = true;
            self.scanner.has_flow_pragma = true; // flow comment 활성화
        } else if (std.mem.endsWith(u8, file_path, ".jsx.flow")) {
            self.is_flow = true;
            self.is_jsx = true;
            self.scanner.has_flow_pragma = true;
        }
    }

    /// 스캐너가 @flow pragma를 감지했으면 is_flow를 활성화한다.
    /// 내부 전용 — statement.parse()의 advance() 직후에서만 호출.
    /// advance()가 첫 주석을 스캔하므로 이 시점에서 has_flow_pragma가 설정되어 있다.
    /// TS 와 Flow 는 상호 배타적이므로, TS 모드에서는 무시한다.
    pub fn applyFlowPragma(self: *Parser) void {
        if (self.source_mode == .ts) return; // TS와 Flow는 상호 배타
        if (self.scanner.has_flow_pragma) {
            self.is_flow = true;
        }
    }

    /// inline scan 중 cond expression 을 build-time 평가. enable_scan + scan_defines
    /// 가드를 한 곳에 묶어 parseIfStatement / parseConditionalExpression 가 공유.
    /// `__DEV__ ? require : require` 같은 dead branch 의 inline require 등록 차단에 사용.
    pub inline fn evalScanCondition(self: *Parser, expr: NodeIndex) ?bool {
        if (!self.enable_scan or self.scan_defines.len == 0) return null;
        return import_scanner.evalToBoolean(&self.ast, expr, self.scan_defines);
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit();
        for (self.errors.items) |err| if (err.labels.len > 0) self.allocator.free(err.labels);
        self.errors.deinit(self.allocator);
        for (self.deferred_module_errors.items) |err| if (err.labels.len > 0) self.allocator.free(err.labels);
        self.deferred_module_errors.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.scan_import_records.deinit(self.allocator);
        self.scan_import_bindings.deinit(self.allocator);
        self.scan_export_bindings.deinit(self.allocator);
        self.scan_import_binding_map.deinit(self.allocator);
        self.param_name_spans.deinit(self.allocator);
        self.bracket_stack.deinit(self.allocator);
    }

    /// Speculative 파싱 실패 시 errors를 mark까지 롤백한다. 제거되는 에러가
    /// 소유한 labels 배열도 함께 free — `errors.shrinkRetainingCapacity` 대신 사용.
    pub fn rollbackErrors(self: *Parser, mark: usize) void {
        if (mark >= self.errors.items.len) return;
        for (self.errors.items[mark..]) |err| {
            if (err.labels.len > 0) self.allocator.free(err.labels);
        }
        self.errors.shrinkRetainingCapacity(mark);
    }

    // ================================================================
    // 토큰 접근 헬퍼
    // ================================================================

    /// 현재 토큰의 Kind.
    pub fn current(self: *const Parser) Kind {
        return self.scanner.token.kind;
    }

    /// 현재 토큰의 Span.
    pub fn currentSpan(self: *const Parser) Span {
        return self.scanner.token.span;
    }

    /// 다음 토큰으로 전진. 여는/닫는 괄호를 자동 추적한다.
    pub fn advance(self: *Parser) !void {
        const kind = self.current();
        // 여는 괄호면 스택에 push
        if (kind == .l_paren or kind == .l_bracket or kind == .l_curly) {
            try self.bracket_stack.append(self.allocator, .{
                .kind = kind,
                .span = self.currentSpan(),
            });
        } else if (kind == .r_paren or kind == .r_bracket or kind == .r_curly) {
            // 닫는 괄호면 스택에서 매칭되는 여는 괄호만 pop.
            // 매칭 안 되면 pop하지 않는다 — 에러 복구 시 스택 오염 방지.
            const expected_open: Kind = switch (kind) {
                .r_paren => .l_paren,
                .r_bracket => .l_bracket,
                .r_curly => .l_curly,
                else => unreachable,
            };
            if (self.bracket_stack.items.len > 0 and
                self.bracket_stack.items[self.bracket_stack.items.len - 1].kind == expected_open)
            {
                _ = self.bracket_stack.pop();
            }
        }
        try self.scanner.next();
    }

    /// 현재 토큰이 expected이면 소비하고 true, 아니면 false.
    pub fn eat(self: *Parser, expected: Kind) !bool {
        if (self.current() == expected) {
            try self.advance();
            return true;
        }
        return false;
    }

    /// 현재 토큰이 expected이면 소비, 아니면 "Expected X but found Y" 에러 추가.
    /// 닫는 괄호를 기대하는 경우, 매칭되는 여는 괄호 위치도 표시한다.
    /// 에러 시 토큰을 advance하지 않음 — 각 루프의 progress guard가 무한 루프를 방지.
    pub fn expect(self: *Parser, expected: Kind) !void {
        if (!try self.eat(expected)) {
            const opening = self.findMatchingOpenBracket(expected);
            const labels: []const diagnostic.Label = if (opening) |o| blk: {
                const label_msg: ?[]const u8 = switch (o.kind) {
                    .l_paren => "opening '(' is here",
                    .l_bracket => "opening '[' is here",
                    .l_curly => "opening '{' is here",
                    else => null,
                };
                if (label_msg == null) break :blk &.{};
                const buf = try self.allocator.alloc(diagnostic.Label, 1);
                buf[0] = .{ .span = o.span, .message = label_msg };
                break :blk buf;
            } else &.{};
            try self.errors.append(self.allocator, .{
                .span = self.currentSpan(),
                .message = expected.symbol(),
                .found = self.current().symbol(),
                .labels = labels,
            });
        }
    }

    /// 제네릭 여는 꺾쇠 `<` 를 소비한다. (oxc re_lex_ts_l_angle 대응)
    /// `<<`, `<=`, `<<=` 를 `<` + 나머지로 분할한다.
    /// 예: `Array<<T>() => T>` 에서 `<<` → `<` + `<`
    pub fn expectOpeningAngleBracket(self: *Parser) !void {
        switch (self.current()) {
            .l_angle => try self.advance(),
            .shift_left, // <<
            .lt_eq, // <=
            .shift_left_eq, // <<=
            => {
                self.scanner.prev_token_kind = .l_angle;
                self.scanner.current = self.scanner.token.span.start + 1;
                try self.advance();
            },
            else => try self.expect(.l_angle),
        }
    }

    /// 제네릭 닫는 꺾쇠 `>` 를 기대한다. (oxc re_lex_ts_r_angle 대응)
    /// `>>`, `>>>`, `>=`, `>>=`, `>>>=` 를 `>` + 나머지로 분할한다.
    /// 예: `Array<Map<K,V>>` 에서 `>>` → `>` + `>`
    /// 예: `(): A<T>=> 0` 에서 `>=` → `>` + `=`
    pub fn expectClosingAngleBracket(self: *Parser) !void {
        if (self.current() == .r_angle) {
            try self.advance();
        } else if (self.isAtClosingAngleBracket()) {
            // 토큰의 첫 바이트(>)만 소비하고 나머지는 다음 렉싱에서 처리
            self.scanner.prev_token_kind = .r_angle;
            self.scanner.current = self.scanner.token.span.start + 1;
            try self.advance();
        } else {
            try self.expect(.r_angle);
        }
    }

    /// 현재 토큰이 `<` 또는 `<`로 시작하는 복합 토큰인지 확인한다.
    pub fn isAtOpeningAngleBracket(self: *const Parser) bool {
        return switch (self.current()) {
            .l_angle, .shift_left, .lt_eq, .shift_left_eq => true,
            else => false,
        };
    }

    /// 현재 토큰이 `>` 또는 `>`로 시작하는 복합 토큰인지 확인한다.
    pub fn isAtClosingAngleBracket(self: *const Parser) bool {
        return switch (self.current()) {
            .r_angle, .shift_right, .shift_right3, .gt_eq, .shift_right_eq, .shift_right3_eq => true,
            else => false,
        };
    }

    /// ASI (Automatic Semicolon Insertion) 규칙으로 세미콜론을 처리한다.
    /// - 세미콜론이 있으면 소비
    /// - 현재 토큰 앞에 개행이 있으면 OK (ASI)
    /// - 현재 토큰이 } 또는 EOF이면 OK (ASI)
    /// - 그 외: "Expected ';' but found X" + 힌트
    pub fn expectSemicolon(self: *Parser) !void {
        if (try self.eat(.semicolon)) return;
        if (self.scanner.token.has_newline_before) return;
        if (self.current() == .r_curly or self.current() == .eof) return;
        try self.errors.append(self.allocator, .{
            .span = self.currentSpan(),
            .message = ";",
            .found = self.current().symbol(),
            .hint = "Try inserting a semicolon here",
        });
    }

    /// 루프 progress guard: 토큰이 진행되지 않았으면 강제 advance.
    /// EOF에 도달하여 루프를 탈출해야 하면 true 반환.
    /// 사용법: `if (try self.ensureLoopProgress(saved_pos)) break;`
    pub fn ensureLoopProgress(self: *Parser, saved_pos: u32) !bool {
        if (self.scanner.token.span.start == saved_pos) {
            if (self.current() == .eof) return true;
            try self.advance();
        }
        return false;
    }

    /// 에러를 추가한다. 기존 호출부 하위 호환 — found/hint 등은 null.
    const ErrorCode = @import("../error_codes.zig").Code;

    pub fn addError(self: *Parser, span: Span, expected: []const u8) !void {
        try self.addErrorCode(span, expected, null);
    }

    /// 에러 코드를 지정하여 에러를 추가한다.
    pub fn addErrorCode(self: *Parser, span: Span, expected: []const u8, code: ?ErrorCode) !void {
        try self.errors.append(self.allocator, .{
            .span = span,
            .message = expected,
            .code = code,
        });
    }

    /// 재선언 계열 에러 + "previously declared here" secondary label.
    pub fn addErrorCodeWithPrevious(self: *Parser, span: Span, message: []const u8, code: ErrorCode, previous_span: Span) !void {
        const buf = try self.allocator.alloc(diagnostic.Label, 1);
        buf[0] = .{ .span = previous_span, .message = diagnostic.PREVIOUSLY_DECLARED_HERE };
        try self.errors.append(self.allocator, .{
            .span = span,
            .message = message,
            .code = code,
            .labels = buf,
        });
    }

    /// Unambiguous 모드에서 모듈 전용 에러를 지연 수집한다.
    /// module에서만 에러인 항목 (top-level return, await in module 등)에 사용.
    /// 파싱 후 resolveModuleKind()에서 모듈 확정 시 병합, 스크립트 확정 시 폐기.
    pub fn addModuleError(self: *Parser, span: Span, message: []const u8) !void {
        try self.addModuleErrorCode(span, message, null);
    }

    pub fn addModuleErrorCode(self: *Parser, span: Span, message: []const u8, code: ?ErrorCode) !void {
        if (self.is_unambiguous) {
            try self.deferred_module_errors.append(self.allocator, .{
                .span = span,
                .message = message,
                .code = code,
            });
        } else {
            try self.addErrorCode(span, message, code);
        }
    }

    /// Unambiguous 모드에서 module-자동-strict에 의한 에러를 지연 수집한다.
    /// "use strict" directive에 의한 strict이면 즉시 에러 (script에서도 유효하므로).
    /// module 자동 strict이면 지연 (script 확정 시 폐기).
    /// with문, yield/reserved word as identifier 등 strict-mode 에러에 사용.
    pub fn addStrictModuleError(self: *Parser, span: Span, message: []const u8) !void {
        try self.addStrictModuleErrorCode(span, message, null);
    }

    pub fn addStrictModuleErrorCode(self: *Parser, span: Span, message: []const u8, code: ?ErrorCode) !void {
        if (self.is_unambiguous and !self.strict_persistent) {
            try self.deferred_module_errors.append(self.allocator, .{
                .span = span,
                .message = message,
                .code = code,
            });
        } else {
            try self.addErrorCode(span, message, code);
        }
    }

    /// Unambiguous 모드 해결: 파싱 완료 후 import/export 유무로 module/script 확정.
    /// module syntax가 있으면 → Module (지연 에러 병합)
    /// module syntax가 없으면 → Script (지연 에러 폐기, is_module=false)
    pub fn resolveModuleKind(self: *Parser) !void {
        if (!self.is_unambiguous) return;

        if (self.has_module_syntax) {
            try self.errors.appendSlice(self.allocator, self.deferred_module_errors.items);
        } else {
            self.is_module = false;
            self.scanner.is_module = false;
            // module 자동 strict 해제 (directive / TS spec strict 는 유지)
            if (!self.strict_persistent) {
                self.is_strict_mode = false;
            }
        }

        self.is_unambiguous = false;
    }

    /// 닫는 괄호에 매칭되는 여는 괄호를 bracket_stack에서 찾는다.
    /// expect()에서 닫는 괄호 에러 시 "opened here" 표시용.
    pub fn findMatchingOpenBracket(self: *const Parser, closing: Kind) ?BracketInfo {
        const expected_open: Kind = switch (closing) {
            .r_paren => .l_paren,
            .r_bracket => .l_bracket,
            .r_curly => .l_curly,
            else => return null,
        };
        // 스택 맨 위부터 역순 탐색
        var i: usize = self.bracket_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bracket_stack.items[i].kind == expected_open) {
                return self.bracket_stack.items[i];
            }
        }
        return null;
    }

    /// scratch 버퍼의 현재 위치를 저장한다. 중첩 사용 시 save/restore 패턴.
    /// 사용법:
    ///   const top = self.saveScratch();
    ///   // ... scratch에 append ...
    ///   const items = self.scratch.items[top..];
    ///   // ... items 사용 후 ...
    ///   self.restoreScratch(top);
    pub fn saveScratch(self: *const Parser) usize {
        return self.scratch.items.len;
    }

    pub fn restoreScratch(self: *Parser, top: usize) void {
        self.scratch.shrinkRetainingCapacity(top);
    }

    /// speculative parse 의 5 가지 state (scanner / errors / scratch / ast.nodes /
    /// ast.extra_data) 를 한 번에 캡처해 실패 시 rollback. 이전엔 호출 사이트
    /// 마다 5 lines 의 boilerplate 가 중복돼 있었음 (3 곳: trySkipTypeArgs,
    /// tryReinterpretAsTypedArrow, parseDecorator type-args).
    pub const SpeculationCheckpoint = struct {
        scanner: ScannerState,
        errors_len: usize,
        scratch_top: usize,
        nodes_len: usize,
        extra_len: usize,

        pub fn save(p: *const Parser) SpeculationCheckpoint {
            return .{
                .scanner = p.saveState(),
                .errors_len = p.errors.items.len,
                .scratch_top = p.saveScratch(),
                .nodes_len = p.ast.nodes.items.len,
                .extra_len = p.ast.extra_data.items.len,
            };
        }

        /// 전체 복원 — scanner 위치까지 되돌린다.
        pub fn rollback(self: SpeculationCheckpoint, p: *Parser) void {
            self.rollbackKeepScanner(p);
            p.restoreState(self.scanner);
        }

        /// AST / scratch / errors 만 복원, scanner 는 현재 위치 유지.
        /// type-args speculation 이 성공하지만 노드는 strip 하고 scanner 만
        /// 전진된 상태로 두는 케이스 (예: `parseDecorator` 의 `<T>` 인자
        /// 스트리핑) 에서 사용.
        pub fn rollbackKeepScanner(self: SpeculationCheckpoint, p: *Parser) void {
            p.rollbackErrors(self.errors_len);
            p.ast.nodes.items.len = self.nodes_len;
            p.ast.extra_data.items.len = self.extra_len;
            p.restoreScratch(self.scratch_top);
        }

        pub fn errorAdded(self: SpeculationCheckpoint, p: *const Parser) bool {
            return p.errors.items.len > self.errors_len;
        }
    };

    /// rest parameter가 마지막이 아니면 에러. binding.zig 파싱 경로에서 호출되며
    /// 항상 rest_element 태그를 본다 (cover grammar 경로는 정규화 후 별도 검증).
    /// 단, ambient context (declare)에서 trailing comma (,...) → ) 는 허용.
    pub fn checkRestParameterLast(self: *Parser, param: NodeIndex) ParseError2!void {
        if (param.isNone() or self.current() != .comma) return;
        if (self.ast.getNode(param).tag != .rest_element) return;
        // ambient context에서 trailing comma (rest 뒤 comma + r_paren)는 허용
        if (self.ctx.in_ambient) {
            const next = try self.peekNextKind();
            if (next == .r_paren) return;
        }
        try self.addErrorCode(self.currentSpan(), "Rest parameter must be last formal parameter", .rest_must_be_last);
    }

    /// 현재 토큰의 소스 텍스트.
    pub fn tokenText(self: *const Parser) []const u8 {
        return self.scanner.tokenText();
    }

    /// 현재 토큰이 identifier이고 텍스트가 name과 일치하면 true.
    /// TS contextual keyword 판별에 사용 (kw_number 등이 identifier로 토큰화된 후).
    pub fn isContextual(self: *const Parser, name: []const u8) bool {
        return self.current() == .identifier and
            std.mem.eql(u8, self.tokenText(), name);
    }

    /// 현재 토큰이 identifier이고 텍스트가 name과 일치하면 소비하고 true.
    pub fn eatContextual(self: *Parser, name: []const u8) !bool {
        if (self.isContextual(name)) {
            try self.advance();
            return true;
        }
        return false;
    }

    /// isContextual과 동일하지만 여러 이름을 한번에 체크.
    pub fn isContextualAny(self: *const Parser, names: []const []const u8) bool {
        if (self.current() != .identifier) return false;
        const text = self.tokenText();
        for (names) |name| {
            if (std.mem.eql(u8, text, name)) return true;
        }
        return false;
    }

    /// 현재 토큰이 identifier이고 텍스트가 name과 일치하면 소비, 아니면 에러.
    pub fn expectContextual(self: *Parser, name: []const u8) !void {
        if (!try self.eatContextual(name)) {
            try self.addError(self.currentSpan(), name);
        }
    }

    /// strict mode에서 eval/arguments를 바인딩 이름으로 사용하면 에러.
    /// escaped 형태 (\u0065val → "eval")도 검증한다.
    pub fn checkStrictBinding(self: *Parser, span: Span) ParseError2!void {
        if (!self.is_strict_mode) return;
        const text = self.resolveIdentifierText(span);
        if (std.mem.eql(u8, text, "eval") or std.mem.eql(u8, text, "arguments")) {
            try self.addErrorCode(span, "Assignment to 'eval' or 'arguments' is not allowed in strict mode", .assignment_eval_arguments_strict);
        }
    }

    pub const rest_init_error = "rest element may not have a default initializer";
    /// object_property의 binary.flags에 설정하여 shorthand-with-default를 표시.
    /// parseObjectProperty에서 마킹, coverObjectExpressionToTarget에서 검증.
    pub const shorthand_with_default: u16 = 0x01;
    /// spread_element의 unary.flags에 설정하여 trailing comma를 표시.
    /// parseArrayExpression에서 마킹, coverArrayExpressionToTarget에서 검증.
    pub const spread_trailing_comma: u16 = 0x01;

    /// binding pattern에서 rest element가 assignment_pattern(= initializer)이면 에러.
    /// parseArrayPattern, parseObjectPattern, parseBindingPattern의 rest 처리에서 공통 사용.
    pub fn checkBindingRestInit(self: *Parser, rest_arg: NodeIndex) ParseError2!void {
        if (rest_arg.isNone()) return;
        const rest_node = self.ast.getNode(rest_arg);
        // binding 위치에서는 assignment_pattern, cover grammar에서는 assignment_expression
        if (rest_node.tag == .assignment_pattern or rest_node.tag == .assignment_expression) {
            try self.addError(rest_node.span, rest_init_error);
        }
    }

    /// identifier의 소스 텍스트가 escaped reserved keyword인지 확인.
    /// 소스에 `\`가 있고, 디코딩하면 reserved keyword이면 에러.
    /// strict mode에서는 escaped strict mode reserved도 에러.
    /// cover grammar 함수 내부 + parseObjectProperty에서 사용.
    pub fn checkIdentifierEscapedKeyword(self: *Parser, span: Span) ParseError2!void {
        // escape가 없으면 검사 불필요
        const raw = self.ast.source[span.start..span.end];
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return;

        const text = self.scanner.decodeIdentifierEscapes(raw) orelse return;
        if (token_mod.keywords.get(text)) |kw| {
            // yield/await는 context-dependent keywords — checkYieldAwaitUse에서 별도 검증.
            if (kw == .kw_yield or kw == .kw_await) return;
            if (kw.isReservedKeyword() or kw.isLiteralKeyword() or
                (self.is_strict_mode and kw.isStrictModeReserved()))
            {
                try self.addErrorCode(span, "Keywords cannot contain escape characters", .keywords_escape);
            }
        }
    }

    /// identifier span의 소스 텍스트를 반환. escape가 있으면 디코딩한 결과를 반환.
    /// 키워드 매칭에 사용 — escape 유무와 관계없이 동일한 resolved text 반환.
    pub fn resolveIdentifierText(self: *Parser, span: Span) []const u8 {
        const text = self.ast.source[span.start..span.end];
        if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
        return self.scanner.decodeIdentifierEscapes(text) orelse text;
    }

    // ================================================================
    // Cover Grammar — cover.zig로 위임
    // ================================================================

    const cover = @import("cover.zig");

    pub const coverExpressionToAssignmentTarget = cover.coverExpressionToAssignmentTarget;
    pub const coverSpreadElementToTarget = cover.coverSpreadElementToTarget;
    pub const coverArrayExpressionToTarget = cover.coverArrayExpressionToTarget;
    pub const coverObjectExpressionToTarget = cover.coverObjectExpressionToTarget;
    pub const collectCoverParamNames = cover.collectCoverParamNames;
    pub const isValidArrowParamForm = cover.isValidArrowParamForm;
    pub const checkAsyncArrowParamsForAwait = cover.checkAsyncArrowParamsForAwait;
    pub const checkCoverParamDefaultForYieldAwait = cover.checkCoverParamDefaultForYieldAwait;
    pub const wrapAsFormalParameters = cover.wrapAsFormalParameters;
    pub const wrapAsFormalParametersFromList = cover.wrapAsFormalParametersFromList;
    pub const coverExpressionToArrowParams = cover.coverExpressionToArrowParams;

    /// 키워드를 바인딩 위치에서 사용할 때의 검증.
    /// ECMAScript 12.1.1: reserved keyword, strict mode reserved, contextual keywords.
    /// escaped 형태 (\u0061wait 등)도 동일하게 검증한다.
    pub fn checkKeywordBinding(self: *Parser) ParseError2!void {
        // await는 조건부 예약어 — async/module에서만 금지, script에서는 식별자로 사용 가능
        // yield도 조건부 — generator/strict에서만 금지
        // 둘 다 checkYieldAwaitUse에서 처리
        if (self.current() == .kw_await or self.current() == .kw_yield) {
            _ = try self.checkYieldAwaitUse(self.currentSpan(), "identifier");
        } else if (self.current().isReservedKeyword() or self.current().isLiteralKeyword()) {
            try self.addErrorCode(self.currentSpan(), "Reserved word cannot be used as identifier", .reserved_word_identifier);
        } else if (self.is_strict_mode and self.current().isStrictModeReserved()) {
            try self.addStrictModuleErrorCode(self.currentSpan(), "Reserved word in strict mode cannot be used as identifier", .reserved_word_identifier_strict);
        } else if (self.current() == .escaped_keyword) {
            // escaped reserved keyword는 식별자로 사용 불가 (예: \u0061wait in script)
            // 단, escaped await는 script mode의 non-async에서는 허용
            const is_escaped_await = self.isEscapedKeyword("await");
            if (is_escaped_await) {
                if (self.ctx.in_async) {
                    try self.addErrorCode(self.currentSpan(), "'await' cannot be used as identifier in this context", .await_identifier);
                } else if (self.is_module and !self.in_namespace) {
                    try self.addModuleErrorCode(self.currentSpan(), "'await' cannot be used as identifier in this context", .await_identifier);
                }
            } else {
                try self.addErrorCode(self.currentSpan(), "Keywords cannot contain escape characters", .keywords_escape);
            }
        } else if (self.current() == .escaped_strict_reserved) {
            // escaped strict reserved는 strict mode에서 금지
            // yield/await 컨텍스트 에러가 우선
            const had_error = try self.checkYieldAwaitUse(self.currentSpan(), "identifier");
            if (!had_error and self.is_strict_mode) {
                try self.addErrorCode(self.currentSpan(), "Keywords cannot contain escape characters", .keywords_escape);
            }
        }
    }

    /// yield/await를 식별자/레이블/바인딩으로 사용할 때의 검증.
    /// ECMAScript 13.1.1: yield는 [Yield] 또는 strict mode에서, await는 [Await] 또는 module에서 금지.
    /// context_noun: "identifier", "label" 등 — 에러 메시지에 사용 (comptime 문자열 연결).
    /// 에러를 추가했으면 true, 아니면 false를 반환한다.
    /// yield/await + strict mode 예약어를 식별자 위치에서 검증한다.
    /// ECMAScript 12.1.1: yield/await는 컨텍스트에 따라 식별자 사용 금지,
    /// strict mode에서는 implements/interface/let/package 등도 금지.
    pub fn checkIdentifierKeywordUse(self: *Parser, span: Span) ParseError2!void {
        if (self.current() == .kw_yield or self.current() == .kw_await) {
            _ = try self.checkYieldAwaitUse(span, "identifier");
        } else if (self.is_strict_mode and self.current().isStrictModeReserved()) {
            try self.addStrictModuleErrorCode(span, "Reserved word in strict mode cannot be used as identifier", .reserved_word_identifier_strict);
        }
    }

    pub fn checkYieldAwaitUse(self: *Parser, span: Span, comptime context_noun: []const u8) ParseError2!bool {
        // enum 초기값에서 await/yield는 다른 멤버를 참조하는 식별자로 허용한다.
        if (self.in_enum_initializer) return false;

        // yield/await는 escaped 형태(yi\u0065ld)도 동일 규칙 적용 (ECMAScript 12.1.1)
        // await는 reserved keyword이므로 escaped_keyword로 분류됨 → 여기서는 yield만 처리
        const is_yield = self.current() == .kw_yield or
            (self.current() == .escaped_strict_reserved and self.isEscapedKeyword("yield"));
        const is_await = self.current() == .kw_await;

        if (is_yield) {
            if (self.ctx.in_generator) {
                try self.addError(span, "'yield' cannot be used as " ++ context_noun ++ " in generator");
                return true;
            } else if (self.is_strict_mode) {
                try self.addStrictModuleError(span, "'yield' cannot be used as " ++ context_noun ++ " in strict mode");
                return true;
            }
        } else if (is_await) {
            if (self.ctx.in_async) {
                try self.addError(span, "'await' cannot be used as " ++ context_noun ++ " in async function");
                return true;
            } else if (self.is_module and !self.in_namespace) {
                try self.addModuleError(span, "'await' cannot be used as " ++ context_noun ++ " in module code");
                return true;
            }
        }
        return false;
    }

    /// escaped_strict_reserved 토큰이 특정 키워드인지 확인한다.
    /// Scanner.decodeIdentifierEscapes로 디코딩 후 비교.
    pub fn isEscapedKeyword(self: *Parser, comptime expected: []const u8) bool {
        const decoded = self.scanner.decodeIdentifierEscapes(self.tokenText()) orelse return false;
        return std.mem.eql(u8, decoded, expected);
    }

    // ================================================================
    // 컨텍스트 저장/복원 (D051: 함수 경계에서 컨텍스트 리셋)
    // ================================================================
    //
    // 함수 진입 시 SavedState로 ctx(u8) + 관련 Parser 필드를 저장/복원한다.
    // allow_in 등 Context만 변경하는 경우는 ctx를 직접 save/restore한다.

    /// 함수 컨텍스트를 설정한다.
    /// 현재 ctx와 관련 Parser 필드를 SavedState에 저장하고, 함수 진입 상태로 변경한다.
    /// 함수/메서드/arrow 진입 시 호출하고, 본문 파싱 후 restoreFunctionContext()로 복원.
    pub fn enterFunctionContext(self: *Parser, is_async: bool, is_generator: bool) SavedState {
        const saved = SavedState{
            .ctx = self.ctx,
            .is_strict_mode = self.is_strict_mode,
            .in_loop = self.in_loop,
            .in_switch = self.in_switch,
            .has_simple_params = self.has_simple_params,
            .for_loop_init = self.for_loop_init,
            .in_class_field = self.in_class_field,
            .in_static_initializer = self.in_static_initializer,
            .allow_new_target = self.allow_new_target,
            .allow_super_call = self.allow_super_call,
            .allow_super_property = self.allow_super_property,
            .in_formal_parameters = self.in_formal_parameters,
            .in_ternary_consequent = self.in_ternary_consequent,
        };
        self.ctx = self.ctx.enterFunction(is_async, is_generator);
        // Parser 필드 리셋 — 함수 경계에서 초기 상태로
        self.in_loop = false;
        self.in_switch = false;
        self.has_simple_params = true; // 기본값은 true (checkSimpleParams에서 갱신)
        self.for_loop_init = false;
        self.allow_super_call = false;
        self.allow_super_property = false;
        self.in_class_field = false;
        self.in_static_initializer = false;
        self.allow_new_target = true; // 일반 함수에서는 new.target 허용
        self.in_formal_parameters = false;
        self.in_ternary_consequent = false; // 함수 본문은 새로운 expression 컨텍스트
        return saved;
    }

    /// 함수 컨텍스트를 복원한다 (enterFunctionContext와 쌍).
    pub fn restoreFunctionContext(self: *Parser, saved: SavedState) void {
        self.ctx = saved.ctx;
        self.is_strict_mode = saved.is_strict_mode;
        self.in_loop = saved.in_loop;
        self.in_switch = saved.in_switch;
        self.has_simple_params = saved.has_simple_params;
        self.for_loop_init = saved.for_loop_init;
        self.in_class_field = saved.in_class_field;
        self.in_static_initializer = saved.in_static_initializer;
        self.allow_new_target = saved.allow_new_target;
        self.allow_super_call = saved.allow_super_call;
        self.allow_super_property = saved.allow_super_property;
        self.in_formal_parameters = saved.in_formal_parameters;
        self.in_ternary_consequent = saved.in_ternary_consequent;
    }

    /// Context(u8)를 복원한다 (enterAllowInContext 등과 쌍).
    pub fn restoreContext(self: *Parser, saved: Context) void {
        self.ctx = saved;
    }

    /// `in` 연산자 허용/금지 컨텍스트에 진입한다.
    /// ECMAScript 문법의 [+In]/[~In] 파라미터 전환에 사용.
    /// 반환값을 restoreContext()에 전달하여 복원.
    pub fn enterAllowInContext(self: *Parser, allow: bool) Context {
        const saved = self.ctx;
        self.ctx.allow_in = allow;
        return saved;
    }

    /// 현재 토큰이 "use strict" directive인지 확인한다.
    /// directive prologue에서 호출 — tokenText()는 따옴표를 포함하므로 내부를 비교.
    pub fn isUseStrictDirective(self: *const Parser) bool {
        if (self.current() != .string_literal) return false;
        const text = self.tokenText();
        // "use strict" 또는 'use strict' — 따옴표 포함 길이 = "use strict".len + 2 = 12
        if (text.len < "\"use strict\"".len) return false;
        const inner = text[1 .. text.len - 1];
        return std.mem.eql(u8, inner, "use strict");
    }

    /// 파싱된 statement 가 bare `StringLiteral ;` 형태이면 `.directive` 노드로 재해석.
    /// oxc 의 post-parse 판정 방식 (crates/oxc_parser/src/js/statement.rs, `parse_directives_and_statements`):
    /// ASI/peek 예측 없이 실제 파스 결과를 검사하므로 정확하다.
    ///
    /// 괄호 방어: `("use strict");` 은 directive 아님. 현재 파서는 괄호를
    /// `.parenthesized_expression` 로 보존하므로 operand tag 검사만으로 걸러지지만,
    /// span.start 비교도 함께 둬 paren unwrapping 이 생길 경우에도 견딘다.
    ///
    /// 효율: 새 노드를 할당하지 않고 기존 slot 의 tag/data 를 in-place 로 덮어쓴다
    /// (minify.zig 의 empty_statement 치환과 동일한 관행). 반환값은 directive 면
    /// 동일한 stmt_idx, 아니면 `.none`.
    pub fn tryConvertToDirective(self: *Parser, stmt_idx: NodeIndex) NodeIndex {
        if (stmt_idx.isNone()) return NodeIndex.none;
        const stmt = self.ast.getNode(stmt_idx);
        if (stmt.tag != .expression_statement) return NodeIndex.none;
        const operand = stmt.data.unary.operand;
        if (operand.isNone()) return NodeIndex.none;
        const expr = self.ast.getNode(operand);
        if (expr.tag != .string_literal) return NodeIndex.none;
        if (stmt.span.start != expr.span.start) return NodeIndex.none;
        // span 은 문자열 리터럴 범위 (따옴표 포함). worklet 의 getText(span)[1..len-1]
        // 슬라이싱과 호환. codegen 은 `.directive` 출력 시 span + `;` 를 쓴다.
        self.ast.nodes.items[@intFromEnum(stmt_idx)] = .{
            .tag = .directive,
            .span = expr.span,
            .data = .{ .none = 0 },
        };
        return stmt_idx;
    }

    /// parseStatement 결과를 stmts 에 추가하면서 directive prologue 상태를 갱신한다.
    /// prologue 중이고 stmt 이 bare string 이면 `.directive` 로 in-place 전환, 아니면
    /// prologue 종료. program 파서와 function body 파서에서 공유.
    pub fn appendStatementTrackingPrologue(
        self: *Parser,
        stmts: *std.ArrayList(NodeIndex),
        stmt: NodeIndex,
        in_prologue: *bool,
    ) !void {
        if (stmt.isNone()) return;
        if (in_prologue.* and self.tryConvertToDirective(stmt).isNone()) {
            in_prologue.* = false;
        }
        try stmts.append(self.allocator, stmt);
    }

    /// 루프 본문을 파싱한다. in_loop를 save/restore.
    pub fn parseLoopBody(self: *Parser) ParseError2!NodeIndex {
        const saved_in_loop = self.in_loop;
        self.in_loop = true;
        const body = try self.parseStatementChecked(true);
        self.in_loop = saved_in_loop;

        // ECMAScript 14.7.5: It is a Syntax Error if IsLabelledFunction(Statement) is true.
        // 반복문의 body가 labelled function이면 에러 (중첩 label도 재귀 검사).
        // Annex B의 labelled function 예외는 반복문 body에서 적용되지 않는다.
        try self.checkLabelledFunction(body);

        return body;
    }

    /// IsLabelledFunction 검사: labeled statement을 재귀적으로 따라가서
    /// 최종 body가 function declaration이면 에러를 발생시킨다.
    pub fn checkLabelledFunction(self: *Parser, idx: NodeIndex) ParseError2!void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .labeled_statement) {
            // labeled_statement의 body는 binary.right에 저장됨
            const inner = node.data.binary.right;
            const inner_node = self.ast.getNode(inner);
            if (inner_node.tag == .function_declaration) {
                try self.addErrorCode(inner_node.span, "Labelled function declaration is not allowed in loop body", .labelled_function_in_loop);
            } else if (inner_node.tag == .labeled_statement) {
                // 중첩 label: label1: label2: function f() {}
                try self.checkLabelledFunction(inner);
            }
        }
    }

    /// 파라미터 리스트가 simple인지 검사한다.
    /// simple = 모든 파라미터가 binding_identifier (destructuring, default, rest 없음)
    /// arrow function의 cover grammar 파라미터가 simple인지 확인한다.
    /// simple = 모든 파라미터가 plain identifier (destructuring, default, rest 없음).
    /// "use strict" + non-simple params → SyntaxError (ECMAScript 14.2.1).
    pub fn isSimpleArrowParams(self: *const Parser, param_idx: NodeIndex) bool {
        if (param_idx.isNone()) return true; // () → simple
        const node = self.ast.getNode(param_idx);
        return switch (node.tag) {
            // 단일 식별자: x => ... → simple
            .binding_identifier, .identifier_reference, .assignment_target_identifier => true,
            // 괄호 표현식: (x) → 내부 확인
            .parenthesized_expression => {
                if (node.data.unary.operand.isNone()) return true; // () → simple
                return self.isSimpleArrowParams(node.data.unary.operand);
            },
            // 콤마 리스트: (a, b, c) → 각 요소 확인
            .sequence_expression, .formal_parameters => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    if (!self.isSimpleArrowParams(elem_idx)) return false;
                }
                return true;
            },
            // destructuring, default, rest, spread → non-simple
            else => false,
        };
    }

    pub fn checkSimpleParams(self: *const Parser, scratch_top: usize) bool {
        const params = self.scratch.items[scratch_top..];
        for (params) |param_idx| {
            if (param_idx.isNone()) continue;
            const node = self.ast.getNode(param_idx);
            switch (node.tag) {
                .binding_identifier => {}, // simple
                else => return false, // destructuring, default, rest, formal_parameter 등
            }
        }
        return true;
    }

    /// arrow function은 항상 UniqueFormalParameters — 조건 없이 검사.
    pub fn checkDuplicateArrowFormalParams(self: *Parser, scratch_top: usize) ParseError2!void {
        try self.checkDuplicateParamsCore(scratch_top);
    }

    /// 일반 함수 중복 파라미터 검사.
    /// sloppy mode + simple params인 일반 function만 허용, 나머지는 에러.
    pub fn checkDuplicateParams(self: *Parser, scratch_top: usize) ParseError2!void {
        const must_check = self.is_strict_mode or !self.has_simple_params or
            self.ctx.in_generator or self.ctx.in_async;
        if (!must_check) return;
        try self.checkDuplicateParamsCore(scratch_top);
    }

    /// 파라미터 목록에서 중복 바인딩 이름을 찾아 에러를 추가한다.
    fn checkDuplicateParamsCore(self: *Parser, scratch_top: usize) ParseError2!void {
        const params = self.scratch.items[scratch_top..];
        self.param_name_spans.clearRetainingCapacity();
        for (params) |param_idx| {
            const names_before = self.param_name_spans.items.len;
            try self.collectBoundNames(param_idx);
            const names_after = self.param_name_spans.items.len;
            var j: usize = names_before;
            while (j < names_after) : (j += 1) {
                const name_span = self.param_name_spans.items[j];
                const name = self.ast.source[name_span.start..name_span.end];
                for (self.param_name_spans.items[0..j]) |prev_span| {
                    const prev_name = self.ast.source[prev_span.start..prev_span.end];
                    if (std.mem.eql(u8, name, prev_name)) {
                        try self.addErrorCodeWithPrevious(name_span, "Duplicate parameter name", .duplicate_parameter, prev_span);
                        break;
                    }
                }
            }
        }
        self.param_name_spans.clearRetainingCapacity();
    }

    /// 바인딩 패턴 노드에서 모든 바인딩 이름의 Span을 재귀적으로 수집한다.
    /// ECMAScript 8.6.3 BoundNames 알고리즘에 해당.
    ///
    /// 지원하는 패턴:
    ///   - binding_identifier (a)              → Span 1개 추가
    ///   - assignment_pattern (a = 1)           → left 재귀
    ///   - formal_parameter (TS: public a)      → operand 재귀
    ///   - spread_element / rest_element (...a) → operand 재귀
    ///   - array_pattern ([a, b, [c]])           → 각 element 재귀
    ///   - object_pattern ({a, b: c})            → 각 property 재귀
    ///   - binding_property ({key: value})       → right(value) 재귀
    ///   - elision / invalid                    → 무시
    pub fn collectBoundNames(self: *Parser, idx: NodeIndex) ParseError2!void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            // 단말 노드: 이름 1개 추가
            .binding_identifier => {
                try self.param_name_spans.append(self.allocator, node.span);
            },
            // x = default → 왼쪽이 실제 바인딩
            .assignment_pattern => {
                try self.collectBoundNames(node.data.binary.left);
            },
            // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
            .formal_parameter => {
                try self.collectBoundNames(@enumFromInt(self.ast.extra_data.items[node.data.extra]));
            },
            // ...rest → operand가 실제 바인딩 (배열/객체 패턴 포함)
            .spread_element, .rest_element, .binding_rest_element => {
                try self.collectBoundNames(node.data.unary.operand);
            },
            // [a, b, [c, d]] → 각 element를 재귀적으로 처리
            .array_pattern => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    try self.collectBoundNames(elem_idx);
                }
            },
            // {a, b: c, ...rest} → 각 property를 재귀적으로 처리
            .object_pattern => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    try self.collectBoundNames(prop_idx);
                }
            },
            // {key: value} → right(value)가 실제 바인딩 패턴
            // shorthand {a} 도 binding_property: left=key(binding_identifier), right=value(binding_identifier)
            .binding_property => {
                try self.collectBoundNames(node.data.binary.right);
            },
            // elision, invalid 등 — 바인딩 없음, 무시
            else => {},
        }
    }

    /// 파라미터 노드에서 단일 바인딩 이름의 Span을 추출한다.
    /// binding_identifier, assignment_pattern(= default), formal_parameter(TS modifier),
    /// spread_element(...rest) 등 단일 이름을 반환하는 형태만 처리.
    /// destructuring([a,b], {a,b})처럼 이름이 여럿인 경우는 null 반환.
    /// 중복 파라미터 검사에는 collectBoundNames를 사용할 것.
    pub fn extractParamName(self: *const Parser, idx: NodeIndex) ?Span {
        if (idx.isNone()) return null;
        const node = self.ast.getNode(idx);
        return switch (node.tag) {
            .binding_identifier => node.span,
            // x = default → left가 binding name
            .assignment_pattern => self.extractParamName(node.data.binary.left),
            // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
            .formal_parameter => self.extractParamName(@enumFromInt(self.ast.extra_data.items[node.data.extra])),
            // rest parameter (...x) → operand가 binding
            .spread_element => self.extractParamName(node.data.unary.operand),
            // destructuring([a,b], {a,b})은 이름이 여럿 — collectBoundNames 사용
            else => null,
        };
    }

    /// "use strict" directive가 발견된 후 함수 이름이 eval/arguments인지 소급 검증.
    /// ECMAScript 14.1.2: strict mode에서 eval/arguments를 바인딩 이름으로 사용 금지.
    pub fn checkStrictFunctionName(self: *Parser, name_idx: NodeIndex) ParseError2!void {
        if (name_idx.isNone()) return;
        const node = self.ast.getNode(name_idx);
        if (node.tag != .binding_identifier) return;
        try self.checkStrictBinding(node.span);
    }

    /// "use strict" directive가 발견된 후 파라미터 이름을 소급 검증.
    /// ECMAScript 14.1.2: strict mode에서 eval/arguments + 중복 파라미터 금지.
    /// destructuring 패턴 안의 이름도 재귀적으로 검사한다.
    pub fn checkStrictParamNames(self: *Parser, scratch_top: usize) ParseError2!void {
        const params = self.scratch.items[scratch_top..];
        for (params) |param_idx| {
            // collectBoundNames로 destructuring 안의 이름도 포함하여 모두 검사
            self.param_name_spans.clearRetainingCapacity();
            try self.collectBoundNames(param_idx);
            for (self.param_name_spans.items) |name_span| {
                try self.checkStrictBinding(name_span);
            }
        }
        self.param_name_spans.clearRetainingCapacity();
        // 중복 파라미터도 소급 검사 (simple params + sloppy에서는 허용이지만 strict에서는 금지)
        try self.checkDuplicateParams(scratch_top);
    }

    /// 함수 선언의 본문을 파싱한다 (닫는 `}` 뒤의 `/`는 regexp로 토큰화).
    pub fn parseFunctionBody(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionBodyInner(false);
    }

    /// 표현식 컨텍스트에서 함수 본문을 파싱한다.
    /// 닫는 `}` 뒤의 `/`가 division으로 올바르게 토큰화된다.
    pub fn parseFunctionBodyExpr(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionBodyInner(true);
    }

    pub fn parseFunctionBodyInner(self: *Parser, in_expression: bool) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        try self.expect(.l_curly);

        var stmts: std.ArrayList(NodeIndex) = .empty;
        defer stmts.deinit(self.allocator);

        // directive prologue: 본문 시작의 문자열 리터럴 expression statement 중 "use strict" 감지
        var in_directive_prologue = true;
        // directive prologue에서 "use strict" 이전의 문자열에 legacy octal이 있으면
        // retroactive하게 에러 보고 (ECMAScript 12.8.4.1)
        var has_prologue_octal = false;
        var prologue_octal_span: Span = Span.EMPTY;

        while (self.current() != .r_curly and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;

            // Pre-parse: "use strict" 및 octal escape 감지는 파싱 결과에 영향을 주므로
            // parseStatement 호출 전에 수행. directive 노드로의 변환은 post-parse.
            if (in_directive_prologue) {
                if (self.isUseStrictDirective()) {
                    // non-simple parameters + "use strict" → 에러
                    // ECMAScript 14.1.2: function with non-simple parameter list
                    // shall not contain a Use Strict Directive
                    if (!self.has_simple_params) {
                        try self.addErrorCode(self.currentSpan(), "\"use strict\" not allowed in function with non-simple parameters", .use_strict_non_simple);
                    }
                    self.is_strict_mode = true;
                    // `strict_persistent` 는 일부러 설정하지 않음 — 함수 스코프 strict
                    // 는 enterFunctionContext 의 save/restore 가 함수 종료 시 해제하므로
                    // module/script 결정에 영향을 줄 수 없다. (프로그램 레벨 prologue 의
                    // strict 는 statement.zig 에서 `strict_persistent=true` 로 처리.)
                    if (has_prologue_octal) {
                        try self.addErrorCode(prologue_octal_span, "Octal escape sequences are not allowed in strict mode", .octal_escape_strict);
                    }
                } else if (self.current() == .string_literal) {
                    // directive prologue의 문자열 — octal escape 추적
                    if (self.scanner.token.has_legacy_octal and !has_prologue_octal) {
                        has_prologue_octal = true;
                        prologue_octal_span = self.currentSpan();
                    }
                }
            }

            const stmt = try self.parseStatement();
            try self.appendStatementTrackingPrologue(&stmts, stmt, &in_directive_prologue);

            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }

        const end = self.currentSpan().end;

        // 표현식 컨텍스트(함수 표현식, 클래스 메서드 등)에서는 닫는 `}` 뒤의 `/`가
        // division이어야 한다. scanner.prev_token_kind를 `.r_paren`으로 설정하면
        // scanSlash()가 slashIsRegex()=false로 판단하여 division으로 토큰화한다.
        // 이 설정은 expect 내부의 advance() → scanner.next()에서 사용된다.
        if (in_expression) {
            self.scanner.prev_token_kind = .r_paren;
        }
        try self.expect(.r_curly);

        const list = try self.ast.addNodeList(stmts.items);
        return try self.ast.addNode(.{
            .tag = .block_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    // ================================================================
    // 프로그램 + Statement 파싱 — statement.zig로 위임
    // ================================================================

    const statement = @import("statement.zig");

    pub fn parse(self: *Parser) !NodeIndex {
        var scope = profile.begin(.parse);
        defer scope.end();
        return statement.parse(self);
    }

    /// 파싱 누적 diagnostic 이 하나라도 있는지. 문법 위반 source 가 codegen 에 silent 통과
    /// 하는 회귀를 잡을 때 유용 (#1906 — `e2eFull` test helper).
    pub fn hasErrors(self: *const Parser) bool {
        return self.errors.items.len > 0;
    }

    pub fn parseStatementChecked(self: *Parser, comptime is_loop_body: bool) ParseError2!NodeIndex {
        return statement.parseStatementChecked(self, is_loop_body);
    }

    pub fn parseStatement(self: *Parser) ParseError2!NodeIndex {
        return statement.parseStatement(self);
    }

    pub fn parseBlockStatement(self: *Parser) ParseError2!NodeIndex {
        return statement.parseBlockStatement(self);
    }

    pub fn parseExpressionStatement(self: *Parser) ParseError2!NodeIndex {
        return statement.parseExpressionStatement(self);
    }

    // ================================================================
    // Function/Class Declaration — declaration.zig로 위임
    // ================================================================

    const declaration = @import("declaration.zig");

    pub fn parseFunctionDeclaration(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseFunctionDeclaration(self);
    }

    pub fn parseAsyncStatement(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseAsyncStatement(self);
    }

    pub fn parseFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseFunctionDeclarationDefaultExport(self);
    }

    pub fn parseAsyncFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseAsyncFunctionDeclarationDefaultExport(self);
    }

    pub fn parseFunctionExpression(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseFunctionExpression(self);
    }

    pub fn parseFunctionExpressionWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
        return declaration.parseFunctionExpressionWithFlags(self, extra_flags);
    }

    pub fn parseClassDeclaration(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseClassDeclaration(self);
    }

    pub fn parseClassExpression(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseClassExpression(self);
    }

    pub fn parseClassWithDecorators(self: *Parser, tag: Tag, decorators: NodeList) ParseError2!NodeIndex {
        return declaration.parseClassWithDecorators(self, tag, decorators);
    }

    const PeekResult = struct { kind: Kind, has_newline_before: bool };

    /// 스캐너 상태를 저장한다. lookahead 후 restoreState로 되돌릴 때 사용.
    pub const ScannerState = struct {
        current: u32,
        start: u32,
        token: Token,
        line: u32,
        line_start: u32,
        brace_depth: u32,
        prev_token_kind: Kind,
        template_depth_len: usize,
        line_offsets_len: usize,
        /// speculative parse 시 스캔된 comment 가 codegen 으로 leak 되지 않도록
        /// 복원 — 누락 시 같은 comment 가 speculation 횟수만큼 중복 emit.
        comments_len: usize,
    };

    pub fn saveState(self: *const Parser) ScannerState {
        return .{
            .current = self.scanner.current,
            .start = self.scanner.start,
            .token = self.scanner.token,
            .line = self.scanner.line,
            .line_start = self.scanner.line_start,
            .brace_depth = self.scanner.brace_depth,
            .prev_token_kind = self.scanner.prev_token_kind,
            .template_depth_len = self.scanner.template_depth_stack.items.len,
            .line_offsets_len = self.scanner.line_offsets.items.len,
            .comments_len = self.scanner.comments.items.len,
        };
    }

    pub fn restoreState(self: *Parser, s: ScannerState) void {
        self.scanner.current = s.current;
        self.scanner.start = s.start;
        self.scanner.token = s.token;
        self.scanner.line = s.line;
        self.scanner.line_start = s.line_start;
        self.scanner.brace_depth = s.brace_depth;
        self.scanner.prev_token_kind = s.prev_token_kind;
        self.scanner.line_offsets.shrinkRetainingCapacity(s.line_offsets_len);
        self.scanner.comments.shrinkRetainingCapacity(s.comments_len);
        // template_depth_stack은 lookahead 중 push(grow) 또는 pop(shrink) 가능.
        // pop으로 줄어든 경우 saved 길이가 현재보다 크지만, capacity 내이므로
        // items.len 직접 설정으로 안전하게 복구할 수 있다.
        if (s.template_depth_len <= self.scanner.template_depth_stack.items.len) {
            self.scanner.template_depth_stack.shrinkRetainingCapacity(s.template_depth_len);
        } else {
            self.scanner.template_depth_stack.items.len = s.template_depth_len;
        }
    }

    /// 다음 토큰의 Kind와 줄바꿈 여부를 미리 본다 (현재 토큰을 소비하지 않음).
    pub fn peekNext(self: *Parser) !PeekResult {
        const saved = self.saveState();

        try self.scanner.next();
        const result = PeekResult{
            .kind = self.scanner.token.kind,
            .has_newline_before = self.scanner.token.has_newline_before,
        };

        self.restoreState(saved);
        return result;
    }

    /// peekNext의 Kind만 반환하는 편의 함수.
    pub fn peekNextKind(self: *Parser) !Kind {
        return (try self.peekNext()).kind;
    }

    /// JSX element 모드에서 다음 토큰의 Kind를 미리 본다 (현재 토큰을 소비하지 않음).
    /// JSX children 파싱 중 '<' 다음이 '/'인지 판별할 때 사용.
    /// normal 모드에서는 '/'가 regex로 해석될 수 있으므로 JSX 전용 peek이 필요하다.
    pub fn peekNextKindJSX(self: *Parser) !Kind {
        const saved = self.saveState();
        try self.scanner.nextInsideJSXElement();
        const peek_kind = self.scanner.token.kind;
        self.restoreState(saved);
        return peek_kind;
    }

    // ================================================================
    // Import/Export — module.zig로 위임
    // ================================================================

    const module_parser = @import("module.zig");

    pub fn parseImportCallArgs(self: *Parser, start: u32) ParseError2!NodeIndex {
        return module_parser.parseImportCallArgs(self, start);
    }

    pub fn parseImportDeclaration(self: *Parser) ParseError2!NodeIndex {
        return module_parser.parseImportDeclaration(self);
    }

    pub fn parseExportDeclaration(self: *Parser) ParseError2!NodeIndex {
        return module_parser.parseExportDeclaration(self);
    }

    // ================================================================
    // Expression 파싱 — expression.zig로 위임
    // ================================================================

    const expression = @import("expression.zig");

    pub fn parseExpression(self: *Parser) ParseError2!NodeIndex {
        return expression.parseExpression(self);
    }

    pub fn parseArrowBody(self: *Parser, is_async: bool, param_idx: NodeIndex) ParseError2!NodeIndex {
        return expression.parseArrowBody(self, is_async, param_idx);
    }

    pub fn parseAssignmentExpression(self: *Parser) ParseError2!NodeIndex {
        return expression.parseAssignmentExpression(self);
    }

    pub fn parseCallExpression(self: *Parser) ParseError2!NodeIndex {
        return expression.parseCallExpression(self);
    }

    pub fn parseIdentifierName(self: *Parser) ParseError2!NodeIndex {
        return expression.parseIdentifierName(self);
    }

    pub fn parseModuleExportName(self: *Parser) ParseError2!NodeIndex {
        return expression.parseModuleExportName(self);
    }

    pub fn parsePropertyKey(self: *Parser) ParseError2!NodeIndex {
        return expression.parsePropertyKey(self);
    }

    // ================================================================
    // Binding Pattern — binding.zig로 직접 위임
    // ================================================================

    const binding_parser = @import("binding.zig");

    pub fn parseBindingIdentifier(self: *Parser) ParseError2!NodeIndex {
        return binding_parser.parseBindingIdentifier(self);
    }

    pub fn parseBindingName(self: *Parser) ParseError2!NodeIndex {
        return binding_parser.parseBindingName(self);
    }

    pub fn parseSimpleIdentifier(self: *Parser) ParseError2!NodeIndex {
        return binding_parser.parseSimpleIdentifier(self);
    }

    // ================================================================
    // JSX 파싱 — jsx.zig로 위임
    // ================================================================

    pub fn parseJSXElement(self: *Parser) ParseError2!NodeIndex {
        return jsx.parseJSXElement(self);
    }

    // ================================================================
    // TypeScript 파싱 — ts.zig로 위임
    // ================================================================

    pub fn parseTsTypeAliasDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsTypeAliasDeclaration(self);
    }

    pub fn parseTsInterfaceDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsInterfaceDeclaration(self);
    }

    pub fn parseConstEnum(self: *Parser) ParseError2!NodeIndex {
        return ts.parseConstEnum(self);
    }

    pub fn parseTsEnumDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsEnumDeclaration(self);
    }

    pub fn parseFlowEnumDeclaration(self: *Parser) ParseError2!NodeIndex {
        return flow.parseFlowEnumDeclaration(self);
    }

    pub fn parseTsModuleDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsModuleDeclaration(self);
    }

    pub fn parseTsDeclareStatement(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsDeclareStatement(self);
    }

    pub fn parseTsAbstractClass(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsAbstractClass(self);
    }

    pub fn parseTsNamespaceBlock(self: *Parser) ParseError2!NodeIndex {
        return ts.parseNamespaceBlock(self);
    }

    pub fn parseDecoratedStatement(self: *Parser) ParseError2!NodeIndex {
        return ts.parseDecoratedStatement(self);
    }

    pub fn parseDecorator(self: *Parser) ParseError2!NodeIndex {
        return ts.parseDecorator(self);
    }

    pub fn parseTsTypeParameterDeclaration(self: *Parser) ParseError2!NodeIndex {
        if (self.is_flow) return flow.parseTypeParameterDeclaration(self);
        try self.rejectTypeScriptSyntaxInJavaScript("TypeScript type parameters are not allowed when parsing as JavaScript");
        return ts.parseTsTypeParameterDeclaration(self);
    }

    pub fn parseFlowTypeAliasDeclaration(self: *Parser) ParseError2!NodeIndex {
        return flow.parseFlowTypeAliasDeclaration(self);
    }

    pub fn parseFlowOpaqueType(self: *Parser) ParseError2!NodeIndex {
        return flow.parseFlowOpaqueType(self);
    }

    pub fn parseFlowDeclareStatement(self: *Parser) ParseError2!NodeIndex {
        return flow.parseFlowDeclareStatement(self);
    }

    pub fn parseFlowInterfaceDeclaration(self: *Parser) ParseError2!NodeIndex {
        return flow.parseFlowInterfaceDeclaration(self);
    }

    pub fn parseFlowComponentDeclaration(self: *Parser) ParseError2!NodeIndex {
        return flow.parseFlowComponentDeclaration(self);
    }

    pub fn tryParseTypeAnnotation(self: *Parser) ParseError2!NodeIndex {
        if (self.is_flow) return flow.tryParseTypeAnnotation(self);
        if (self.current() == .colon) {
            try self.rejectTypeScriptSyntaxInJavaScript("TypeScript type annotations are not allowed when parsing as JavaScript");
        }
        return ts.tryParseTypeAnnotation(self);
    }

    /// TS `this` 파라미터 스킵. 함수의 첫 번째 파라미터가 `this` 면
    /// `this` (+ 선택적 `: Type`) + 선택적 `,` 를 소비하고 파라미터 리스트에
    /// 추가하지 않는다 — 런타임에 불필요.
    /// 다음 토큰이 `:` (`this: Type`), `,` (`this, next`), `)` (`this)` 단독 마지막
    /// 파라미터) 중 하나면 TS this parameter 로 인식. 그 외 (예: `this.x`,
    /// `this = ...`) 는 일반 expression context 라 fall-through.
    /// esbuild/oxc 와 일치 — bare `this` (no type annotation) 도 valid TS.
    pub fn trySkipThisParameter(self: *Parser) ParseError2!void {
        if (self.current() != .kw_this) return;
        const next = try self.peekNextKind();
        switch (next) {
            .colon, .comma, .r_paren => {},
            else => return,
        }
        try self.rejectTypeScriptSyntaxInJavaScript("TypeScript this parameters are not allowed when parsing as JavaScript");
        try self.advance(); // skip 'this'
        _ = try self.tryParseTypeAnnotation(); // skip ': Type' 있으면
        _ = try self.eat(.comma);
    }

    pub fn tryParseReturnType(self: *Parser) ParseError2!NodeIndex {
        if (self.is_flow) return flow.tryParseReturnType(self);
        if (self.current() == .colon) {
            try self.rejectTypeScriptSyntaxInJavaScript("TypeScript return type annotations are not allowed when parsing as JavaScript");
        }
        return ts.tryParseReturnType(self);
    }

    fn rejectTypeScriptSyntaxInJavaScript(self: *Parser, message: []const u8) ParseError2!void {
        if (self.source_mode != .js_strict or self.is_flow) return;
        try self.addErrorCode(self.currentSpan(), message, .ts_syntax_in_js);
    }

    pub fn parseType(self: *Parser) ParseError2!NodeIndex {
        if (self.is_flow) return flow.parseType(self);
        return ts.parseType(self);
    }

    pub fn parseIndexSignature(self: *Parser, start: u32, is_readonly: bool) ParseError2!NodeIndex {
        return ts.parseIndexSignature(self, start, is_readonly);
    }

    pub fn parseTypeArguments(self: *Parser) ParseError2!NodeIndex {
        if (self.is_flow) return flow.parseTypeArguments(self);
        return ts.parseTypeArguments(self);
    }

    /// 식 컨텍스트에서의 타입 인자 파싱 (speculative).
    /// 최외곽 닫는 `>`가 정확히 `.r_angle`일 때만 성공한다.
    pub fn parseTypeArgumentsInExpression(self: *Parser) ParseError2!NodeIndex {
        if (self.is_flow) return flow.parseTypeArgumentsInExpression(self);
        return ts.parseTypeArgumentsInExpression(self);
    }

    // ================================================================
    // TS Arrow Function Detection
    // ================================================================

    /// `(x = default, y: T) =>` 같은 typed arrow detection 중 default value
    /// expression 을 통과해 다음 param 의 `:` / `?` 까지 진행한다. paren/bracket/brace
    /// balanced skip 으로 nested call/object/array literal 도 안전하게 통과. 종료 시
    /// current 토큰은 `,` 또는 `)` (eof 직전 종료).
    fn skipDefaultValueToCommaOrRParen(self: *Parser) !void {
        var depth: u32 = 0;
        while (self.current() != .eof) {
            switch (self.current()) {
                .l_paren, .l_bracket, .l_curly => depth += 1,
                .r_paren, .r_bracket, .r_curly => {
                    if (depth == 0) return;
                    depth -= 1;
                },
                .comma => if (depth == 0) return,
                else => {},
            }
            try self.advance();
        }
    }

    /// TS 모드에서 `(identifier:` 또는 `(identifier?` 패턴으로 typed arrow function 감지.
    /// 현재 토큰이 `(` 일 때 호출. 2-token lookahead로 판단.
    pub fn isTypedArrowFunction(self: *Parser) !bool {
        if (self.current() != .l_paren) return false;
        const saved = self.saveState();
        defer self.restoreState(saved);

        try self.advance(); // skip (

        // (): Type => ... — 빈 파라미터 + 리턴 타입
        if (self.current() == .r_paren) {
            try self.advance();
            if (self.current() != .colon) return false;
            // ternary consequent 안에서는 `:` 가 ternary separator일 수 있다.
            if (!self.in_ternary_consequent) return true;
            // Flow: `:` 뒤에 type keyword가 오면 return type annotation 확정.
            // void, number 등은 expression start로 사용되지 않으므로 ternary `:` 와 구분 가능.
            if (self.is_flow) {
                const after = try self.peekNextKind();
                if (after == .kw_void or after == .kw_typeof) return true;
            }
            return false;
        }

        // (...rest: Type) => ... — rest parameter with type
        if (self.current() == .dot3) return true;

        // (identifier: 패턴 — contextual keyword(get/set/number 등)도 식별자
        // ?는 ternary와 모호하므로 : 만 감지
        if (self.current() == .identifier or self.current().isKeyword() or self.current() == .escaped_keyword) {
            try self.advance(); // skip identifier
            if (self.current() == .colon) return true;
            // (a): Type => ... — 단일 파라미터 + 리턴 타입
            // ternary consequent 안에서는 `:` 가 ternary separator일 수 있으므로 여기서 판단하지 않는다.
            if (self.current() == .r_paren) {
                try self.advance();
                return self.current() == .colon and !self.in_ternary_consequent;
            }
            // (a?: Type) — optional parameter
            if (self.current() == .question) return true;
            // (a = default, ...) — 첫 번째 파라미터에 default value 가 있는 경우.
            // default expression 을 통과한 뒤 typed arrow 후보 검사를 이어간다.
            if (self.current() == .eq) {
                try self.advance(); // skip =
                try self.skipDefaultValueToCommaOrRParen();
                if (self.current() == .r_paren) {
                    try self.advance();
                    return self.current() == .colon and !self.in_ternary_consequent;
                }
                // comma → 아래 typed-param 검사 loop 로 fall-through
            }

            // (a, b: Type) => ... — 첫 번째 파라미터에 타입이 없고 뒤에 타입이 있는 경우.
            // `,` 뒤의 파라미터에서 `identifier :` 패턴을 찾으면 typed arrow로 판별.
            // 예: (background, useForeground: boolean) => {}
            //     (acc, edge: Edge) => {}
            if (self.current() == .comma) {
                while (self.current() == .comma) {
                    try self.advance(); // skip ,
                    // trailing comma 케이스: `(a, b, c,): T => ...` — 마지막 `,` 다음 곧장
                    // `)`. 모든 파라미터에 type annotation 이 없어도 return type 으로 typed
                    // arrow 판별 가능. @reduxjs/toolkit listenerMiddleware.test-d.ts.
                    if (self.current() == .r_paren) {
                        try self.advance();
                        return self.current() == .colon and !self.in_ternary_consequent;
                    }
                    // rest parameter with type
                    if (self.current() == .dot3) return true;
                    // destructuring with type
                    if (self.current() == .l_curly or self.current() == .l_bracket) return true;
                    if (self.current() == .identifier or self.current().isKeyword() or self.current() == .escaped_keyword) {
                        try self.advance(); // skip identifier
                        if (self.current() == .colon or self.current() == .question) return true;
                        if (self.current() == .r_paren) {
                            try self.advance();
                            return self.current() == .colon and !self.in_ternary_consequent;
                        }
                        // default value 가 있는 다음 param — expression 통과 후 계속.
                        if (self.current() == .eq) {
                            try self.advance(); // skip =
                            try self.skipDefaultValueToCommaOrRParen();
                            if (self.current() == .comma) continue;
                            if (self.current() == .r_paren) {
                                try self.advance();
                                return self.current() == .colon and !self.in_ternary_consequent;
                            }
                        }
                        // 이 파라미터에도 타입이 없으면 다음 파라미터 확인
                    } else {
                        break;
                    }
                }
            }
            return false;
        }

        // ({}: Type) 또는 ([]: Type) — destructuring with type
        if (self.current() == .l_curly or self.current() == .l_bracket) return true;

        return false;
    }

    /// TS typed arrow function을 직접 파싱: `(a: Type, b?: Type): ReturnType => body`
    /// save/restore로 실패 시 원래 위치로 복원할 수 있도록 호출부에서 관리.
    /// TS typed arrow function 파싱 시도. 성공하면 arrow 노드, 실패하면 null (호출부가 폴백).
    pub fn parseTypedArrowParams(self: *Parser, start: u32, is_async: bool) ParseError2!?NodeIndex {
        const saved = self.saveState();
        const errors_before = self.errors.items.len;

        try self.advance(); // skip (
        self.in_formal_parameters = true;
        try self.trySkipThisParameter();
        const scratch_top = self.saveScratch();

        while (self.current() != .r_paren and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(self.allocator, param);
            // rest parameter 뒤에 comma가 오면 에러: (...a,) => {}
            try self.checkRestParameterLast(param);
            if (!try self.eat(.comma)) break;
            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }

        self.in_formal_parameters = false;
        if (self.current() != .r_paren) {
            self.restoreScratch(scratch_top);
            self.rollbackErrors(errors_before);
            self.restoreState(saved);
            return null;
        }
        try self.advance(); // skip )

        // return type annotation: ): Type =>
        // Flow: shorthand 함수 타입 금지 — (): any => {} 에서 =>는 arrow body
        {
            const saved_flow_flag = self.flow_in_return_type;
            self.flow_in_return_type = true;
            defer self.flow_in_return_type = saved_flow_flag;
            _ = try self.tryParseReturnType();
        }

        // => 확인
        if (self.current() != .arrow or self.scanner.token.has_newline_before) {
            self.restoreScratch(scratch_top);
            self.rollbackErrors(errors_before);
            self.restoreState(saved);
            return null;
        }

        // arrow function은 항상 UniqueFormalParameters — 중복 파라미터 이름 금지.
        try self.checkDuplicateArrowFormalParams(scratch_top);

        // 파라미터 노드 리스트 생성
        const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const params_node = try self.ast.addNode(.{
            .tag = .formal_parameters,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = params },
        });

        try self.advance(); // skip =>
        const body = try expression.parseArrowBody(self, is_async, params_node);
        const flags: u32 = if (is_async) 0x01 else 0;
        const ae = try self.ast.addExtras(&.{ @intFromEnum(params_node), @intFromEnum(body), flags });
        return try self.ast.addNode(.{
            .tag = .arrow_function_expression,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = ae },
        });
    }
};
