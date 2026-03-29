//! ZTS Semantic Analyzer
//!
//! AST를 순회하면서 스코프 트리를 구축하고 심볼(변수/함수/클래스 선언)을 수집한다.
//! 수집된 정보로 재선언 에러 등을 검증한다.
//!
//! 설계 (D038, D051):
//!   - 파서와 분리된 별도 패스 (oxc 방식)
//!   - Switch 기반 visitor (D042)
//!   - 파서가 이미 처리한 것: strict mode, break/continue/return 검증
//!   - 이 모듈이 처리하는 것: 스코프/심볼 수집, 재선언 검증

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;
const scope_mod = @import("scope.zig");
const ScopeId = scope_mod.ScopeId;
const ScopeKind = scope_mod.ScopeKind;
const Scope = scope_mod.Scope;
const symbol_mod = @import("symbol.zig");
const SymbolId = symbol_mod.SymbolId;
const SymbolKind = symbol_mod.SymbolKind;
const Symbol = symbol_mod.Symbol;
const checker = @import("checker.zig");
pub const Diagnostic = @import("../diagnostic.zig").Diagnostic;

const AllocError = std.mem.Allocator.Error;

/// Semantic Analyzer.
///
/// 사용법:
/// ```zig
/// var analyzer = SemanticAnalyzer.init(allocator, &ast);
/// defer analyzer.deinit();
/// analyzer.analyze();
/// // analyzer.errors에 에러가 있으면 출력
/// ```
pub const SemanticAnalyzer = struct {
    /// 분석 대상 AST. @__NO_SIDE_EFFECTS__ 자동 전파에서 CallFlags 수정이 필요하므로 mutable.
    ast: *Ast,

    /// 스코프 배열 (플랫, D052)
    scopes: std.ArrayList(Scope),

    /// 심볼 배열 (플랫, D053)
    symbols: std.ArrayList(Symbol),

    /// 수집된 에러 목록
    errors: std.ArrayList(Diagnostic),

    /// 현재 스코프 (스코프 스택 대신 인덱스 하나로 추적)
    current_scope: ScopeId = .none,

    /// strict mode 여부 (파서에서 전달받음, 스코프 진입 시 전파)
    is_strict_mode: bool = false,

    /// module 모드 여부 (파서에서 전달받음)
    is_module: bool = false,

    /// TypeScript 모드 여부 (.ts/.tsx/.mts 파일)
    /// TS에서는 function overload, duplicate export 등이 합법
    is_ts: bool = false,

    /// Top-Level Await 감지 결과. 모듈의 top-level에서 await가 사용되면 true.
    /// 함수/arrow 내부의 await는 포함하지 않음.
    has_top_level_await: bool = false,

    /// 메모리 할당자
    allocator: std.mem.Allocator,

    /// module의 exported name 추적 (중복 export 검사).
    /// key: 내보낸 이름 (default 포함), value: 첫 선언의 span.
    exported_names: std.StringHashMap(Span),

    /// class private name 스택 (중첩 class 지원, oxc 방식).
    /// 각 항목은 해당 class body에서 선언된 private name 집합.
    class_private_declared: std.ArrayList(std.StringHashMap(PrivateNameInfo)),

    /// class private name 참조 스택.
    /// 각 항목은 해당 class body에서 참조된 private name 목록 (검증 대기).
    class_private_refs: std.ArrayList(std.ArrayList(PrivateRef)),

    /// label 스택. labeled statement 진입 시 push, 퇴장 시 pop.
    /// 함수 경계에서 saved_label_len으로 저장/복원 (label은 함수를 넘지 못함).
    labels: std.ArrayList(LabelEntry) = undefined,
    /// label fence: 함수 경계에서 외부 label을 숨기기 위한 인덱스.
    /// findLabel은 fence 이후의 label만 검색한다.
    label_fence: usize = 0,
    /// resolvePrivateName에서 할당된 문자열 (deinit에서 해제)
    resolved_names: std.ArrayList([]const u8) = undefined,

    /// per-scope 심볼 검색용 HashMap 배열 (O(1) 조회).
    /// scopes 배열과 같은 인덱스를 공유: scope_maps.items[scope_id] = 해당 스코프의 이름→심볼인덱스 맵.
    /// key는 소스 코드 슬라이스 (zero-copy), value는 symbols 배열의 인덱스.
    scope_maps: std.ArrayList(std.StringHashMap(usize)),

    /// 미해결 참조 (unresolved references). resolveIdentifier에서 스코프 체인을 다 올라가도
    /// 선언을 찾지 못한 이름. 번들러 linker가 scope hoisting 시 이 이름들을 예약하여
    /// 모듈 top-level 변수가 글로벌을 shadowing하지 않도록 한다 (Rolldown 방식).
    /// key는 소스 코드 슬라이스 (zero-copy).
    unresolved_references: std.StringHashMap(void),

    /// Forward reference 지원을 위한 pre-declaration 스코프.
    /// visitProgram에서 첫 번째 패스로 top-level 바인딩 이름을 미리 등록한 후,
    /// 두 번째 패스(본 순회)에서 이 스코프의 variable_declaration은 registerBinding을 건너뛴다.
    /// (이미 등록된 이름을 다시 등록하면 재선언 에러가 발생하므로)
    predeclared_scope: ScopeId = .none,

    /// 노드 인덱스 → 심볼 인덱스 매핑. 번들러 linker가 codegen에서 식별자 리네임에 사용.
    /// 식별자 참조/선언 노드만 유효한 값을 가지고, 나머지는 null.
    /// resolveIdentifier/declareSymbol에서 채워진다.
    symbol_ids: std.ArrayList(?u32),

    /// mangler용 참조 scope 페어. resolveIdentifier에서 심볼을 찾을 때마다 기록.
    /// (symbol_index, reference_scope_id) — liveness BitSet 계산에 사용.
    ref_scope_pairs: std.ArrayList(symbol_mod.RefScopePair),

    /// Annex B: if/else/labeled body에서 function declaration을 만나면
    /// var hoisting conflict check를 건너뛴다.
    /// sloppy mode에서 `if (true) function f() {}` 같은 구문이 let/const와 충돌하지 않도록 한다.
    /// ECMAScript B.3.2/B.3.3: "If replacing the FunctionDeclaration with a VariableStatement
    /// would produce an Early Error, the extension is not applied."
    in_annex_b_context: bool = false,

    // ================================================================
    // Part 시스템 (Phase 7-1): 번들러 StmtInfo를 파싱 중 구축
    // ================================================================

    /// 현재 방문 중인 top-level statement 인덱스. null이면 top-level이 아님.
    /// visitProgram의 2nd pass에서 각 statement 방문 전 설정.
    current_top_stmt: ?u32 = null,

    /// per-top-level-statement declared 심볼 인덱스 수집 버퍼.
    /// stmt_declared.items[i] = i번째 top-level statement가 선언하는 심볼들.
    stmt_declared: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,

    /// per-top-level-statement referenced 심볼 인덱스 수집 버퍼.
    /// stmt_referenced.items[i] = i번째 top-level statement가 참조하는 심볼들 (declared에 없는 것만).
    stmt_referenced: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,

    /// top-level statement의 AST 노드 인덱스 배열.
    top_stmt_node_indices: std.ArrayListUnmanaged(u32) = .empty,

    const PrivateRef = struct {
        name: []const u8,
        span: Span,
    };

    /// private name의 종류 (중복 검사에서 getter+setter 쌍을 허용하기 위해 구분).
    const PrivateNameKind = enum {
        field,
        method,
        getter,
        setter,
    };

    /// private name 선언 정보 (span + kind).
    const PrivateNameInfo = struct {
        span: Span,
        kind: PrivateNameKind,
    };

    const LabelEntry = struct {
        name: []const u8,
        span: Span,
        is_loop: bool,
    };

    pub fn init(allocator: std.mem.Allocator, ast: *Ast) SemanticAnalyzer {
        return .{
            .ast = ast,
            .scopes = .empty,
            .symbols = .empty,
            .exported_names = std.StringHashMap(Span).init(allocator),
            .class_private_declared = .empty,
            .class_private_refs = .empty,
            .labels = .empty,
            .resolved_names = .empty,
            .scope_maps = .empty,
            .unresolved_references = std.StringHashMap(void).init(allocator),
            .symbol_ids = .empty,
            .ref_scope_pairs = .empty,
            .errors = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SemanticAnalyzer) void {
        // allocPrint으로 할당된 에러 메시지 해제
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.scopes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        for (self.scope_maps.items) |*m| m.deinit();
        self.scope_maps.deinit(self.allocator);
        self.exported_names.deinit();
        self.unresolved_references.deinit();
        self.labels.deinit(self.allocator);
        // resolvePrivateName에서 할당된 문자열 해제
        for (self.resolved_names.items) |name| {
            self.allocator.free(name);
        }
        self.resolved_names.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.symbol_ids.deinit(self.allocator);
        self.ref_scope_pairs.deinit(self.allocator);
        for (self.class_private_declared.items) |*map| map.deinit();
        self.class_private_declared.deinit(self.allocator);
        for (self.class_private_refs.items) |*list| list.deinit(self.allocator);
        self.class_private_refs.deinit(self.allocator);
        // Part 시스템 필드 해제
        for (self.stmt_declared.items) |*b| b.deinit(self.allocator);
        self.stmt_declared.deinit(self.allocator);
        for (self.stmt_referenced.items) |*b| b.deinit(self.allocator);
        self.stmt_referenced.deinit(self.allocator);
        self.top_stmt_node_indices.deinit(self.allocator);
    }

    // ================================================================
    // 공개 API
    // ================================================================

    /// 분석을 실행한다. AST의 루트(마지막 노드 = program)부터 시작.
    pub fn analyze(self: *SemanticAnalyzer) AllocError!void {
        if (self.ast.nodes.items.len == 0) return;

        // symbol_ids 배열 초기화: 노드 수만큼 null로 채움
        try self.symbol_ids.ensureTotalCapacity(self.allocator, self.ast.nodes.items.len);
        self.symbol_ids.items.len = self.ast.nodes.items.len;
        @memset(self.symbol_ids.items, null);

        const root_idx: NodeIndex = @enumFromInt(@as(u32, @intCast(self.ast.nodes.items.len - 1)));
        try self.visitNode(root_idx);
    }

    // ================================================================
    // 스코프 관리
    // ================================================================

    /// 새 스코프를 생성하고 진입한다. 반환값: 이전 스코프 ID (나갈 때 복원용).
    fn enterScope(self: *SemanticAnalyzer, kind: ScopeKind, is_strict: bool) AllocError!ScopeId {
        const parent = self.current_scope;
        const new_id: ScopeId = @enumFromInt(@as(u32, @intCast(self.scopes.items.len)));
        try self.scopes.append(self.allocator, .{
            .parent = parent,
            .kind = kind,
            .is_strict = is_strict,
        });
        // scope_maps는 scopes와 동일 인덱스를 공유 — 빈 HashMap 추가
        try self.scope_maps.append(self.allocator, std.StringHashMap(usize).init(self.allocator));
        self.current_scope = new_id;
        return parent;
    }

    // ================================================================
    // Label 관리
    // ================================================================

    /// label 스택의 현재 길이를 저장한다. 함수 경계에서 복원용.
    fn saveLabelLen(self: *SemanticAnalyzer) usize {
        const saved = self.label_fence;
        // 함수 경계에서 label fence를 현재 위치로 설정.
        // findLabel은 fence 이후의 label만 검색한다.
        self.label_fence = self.labels.items.len;
        return saved;
    }

    /// label fence를 복원하고, 함수 내부에서 추가된 label을 제거한다.
    fn restoreLabelLen(self: *SemanticAnalyzer, saved: usize) void {
        self.labels.shrinkRetainingCapacity(self.label_fence);
        self.label_fence = saved;
    }

    /// label 이름으로 검색한다. 없으면 null.
    fn findLabel(self: *const SemanticAnalyzer, name: []const u8) ?LabelEntry {
        var i = self.labels.items.len;
        // label_fence 이후의 label만 검색 (함수 경계 외부 label 숨김)
        while (i > self.label_fence) {
            i -= 1;
            if (std.mem.eql(u8, self.labels.items[i].name, name)) {
                return self.labels.items[i];
            }
        }
        return null;
    }

    /// 현재 스코프 체인에 function 스코프가 있는지 확인한다.
    /// TLA 감지에 사용: function 안이면 await는 TLA가 아님.
    fn isInsideFunctionScope(self: *const SemanticAnalyzer) bool {
        var scope_id = self.current_scope;
        while (!scope_id.isNone()) {
            const scope = self.scopes.items[scope_id.toIndex()];
            if (scope.kind == .function) return true;
            scope_id = scope.parent;
        }
        return false;
    }

    /// 현재 스코프가 strict mode인지 확인한다.
    fn isCurrentStrict(self: *const SemanticAnalyzer) bool {
        if (self.is_strict_mode or self.is_module) return true;
        if (!self.current_scope.isNone()) {
            return self.scopes.items[self.current_scope.toIndex()].is_strict;
        }
        return false;
    }

    /// 스코프에서 나간다. enterScope의 반환값을 전달.
    fn exitScope(self: *SemanticAnalyzer, saved_scope: ScopeId) void {
        self.current_scope = saved_scope;
    }

    // ================================================================
    // Class Private Name 추적 (oxc 방식)
    // ================================================================

    /// class body 진입 시 private name 스코프를 push한다.
    fn pushClassScope(self: *SemanticAnalyzer) AllocError!void {
        try self.class_private_declared.append(self.allocator, std.StringHashMap(PrivateNameInfo).init(self.allocator));
        try self.class_private_refs.append(self.allocator, .empty);
    }

    /// class body 퇴장 시 private name 참조를 검증하고 pop한다.
    fn popClassScope(self: *SemanticAnalyzer) AllocError!void {
        if (self.class_private_declared.items.len == 0) return;

        var declared = self.class_private_declared.pop() orelse return;
        defer declared.deinit();
        var refs = self.class_private_refs.pop() orelse return;
        defer refs.deinit(self.allocator);

        // 참조된 private name이 선언되었는지 확인
        for (refs.items) |ref| {
            if (!declared.contains(ref.name)) {
                // 외부 class에 선언되어 있는지 확인 (중첩 class)
                var found = false;
                for (self.class_private_declared.items) |outer| {
                    if (outer.contains(ref.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try self.addPrivateNameError(ref.span, ref.name);
                }
            }
        }
    }

    /// private name을 현재 class scope에 선언 등록한다.
    fn declarePrivateName(self: *SemanticAnalyzer, name: []const u8, span: Span, kind: PrivateNameKind) AllocError!void {
        if (self.class_private_declared.items.len == 0) return;
        var current = &self.class_private_declared.items[self.class_private_declared.items.len - 1];

        if (current.get(name)) |existing| {
            // getter+setter 쌍은 허용 (순서 무관)
            const is_accessor_pair = (existing.kind == .getter and kind == .setter) or
                (existing.kind == .setter and kind == .getter);
            if (!is_accessor_pair) {
                try self.addErrorMsg(span, try std.fmt.allocPrint(
                    self.allocator,
                    "Private field '{s}' has already been declared",
                    .{name},
                ));
                return;
            }
        }
        try current.put(name, .{ .span = span, .kind = kind });
    }

    /// identifier 텍스트에서 unicode escape sequence를 해석하여 StringValue를 반환한다.
    /// ECMAScript 사양에 따르면 private name 비교는 StringValue 기준이므로
    /// `#\u{6F}`와 `#o`는 같은 이름이다.
    /// escape가 없으면 원본 슬라이스를 그대로 반환 (할당 없음).
    /// escape가 있으면 allocator로 새 문자열을 할당하여 반환한다.
    fn resolvePrivateName(self: *SemanticAnalyzer, raw: []const u8) AllocError![]const u8 {
        // escape가 없으면 그대로 반환
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;

        // escape가 포함된 경우: 디코딩하여 새 문자열 생성
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var i: usize = 0;

        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == 'u') {
                i += 2; // skip \u
                var codepoint: u32 = 0;
                if (i < raw.len and raw[i] == '{') {
                    // \u{XXXX} 형식 (가변 길이)
                    i += 1; // skip {
                    while (i < raw.len and raw[i] != '}') {
                        const digit = std.fmt.charToDigit(raw[i], 16) catch return raw;
                        codepoint = codepoint * 16 + digit;
                        i += 1;
                    }
                    if (i < raw.len) i += 1; // skip }
                } else {
                    // \uXXXX 형식 (4자리 고정)
                    var j: usize = 0;
                    while (j < 4 and i < raw.len) : (j += 1) {
                        const digit = std.fmt.charToDigit(raw[i], 16) catch return raw;
                        codepoint = codepoint * 16 + digit;
                        i += 1;
                    }
                }
                // 유효 범위 검증 후 UTF-8로 인코딩
                if (codepoint > 0x10FFFF) return raw;
                var encode_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(codepoint), &encode_buf) catch return raw;
                try buf.appendSlice(self.allocator, encode_buf[0..len]);
            } else {
                try buf.append(self.allocator, raw[i]);
                i += 1;
            }
        }

        const result = try self.allocator.dupe(u8, buf.items);
        // 할당된 문자열을 추적하여 deinit에서 해제
        try self.resolved_names.append(self.allocator, result);
        return result;
    }

    /// private name 참조를 기록한다 (class body 퇴장 시 검증).
    fn usePrivateName(self: *SemanticAnalyzer, name: []const u8, span: Span) AllocError!void {
        if (self.class_private_refs.items.len == 0) {
            // class 밖에서 private name 참조 → 즉시 에러
            try self.addPrivateNameError(span, name);
            return;
        }
        var current = &self.class_private_refs.items[self.class_private_refs.items.len - 1];
        try current.append(self.allocator, .{ .name = name, .span = span });
    }

    /// 현재 class scope 안에 있는지 (private name 참조 가능 여부).
    fn inClassScope(self: *const SemanticAnalyzer) bool {
        return self.class_private_declared.items.len > 0;
    }

    // ================================================================
    // 심볼 등록 + 재선언 검증
    // ================================================================

    /// 심볼을 현재 스코프에 등록한다.
    /// var는 가장 가까운 var scope(function/global/module)에 등록.
    /// let/const/class는 현재 블록 스코프에 등록.
    /// 중복 선언이면 에러를 추가한다.
    fn declareSymbol(self: *SemanticAnalyzer, name_span: Span, kind: SymbolKind, decl_span: Span) AllocError!void {
        return self.declareSymbolWithNode(name_span, kind, decl_span, null);
    }

    fn declareSymbolWithNode(self: *SemanticAnalyzer, name_span: Span, kind: SymbolKind, decl_span: Span, node_idx: ?u32) AllocError!void {
        const name_text = self.ast.source[name_span.start..name_span.end];

        // function-like 선언의 스코핑 규칙:
        // - var scope(global/function/module) 안에서 직접 선언: var scope에 등록 (호이스팅)
        // - 블록 스코프 안에서 선언: 블록 스코프에 등록 (ECMAScript B.3.2, 13.2.14)
        //   블록 안의 function/generator/async function은 LexicallyDeclaredNames에 포함
        const target_scope = if (kind == .variable_var)
            self.findVarScope()
        else if (kind.isFunctionLike()) blk: {
            // 현재 스코프가 var scope이면 그대로, 아니면 현재 블록 스코프에 등록
            if (!self.current_scope.isNone()) {
                const current = self.scopes.items[self.current_scope.toIndex()];
                if (!current.kind.isVarScope()) {
                    break :blk self.current_scope;
                }
            }
            break :blk self.findVarScope();
        } else self.current_scope;

        // Annex B 예외: if/else body의 function declaration은 sloppy mode에서
        // 모든 재선언/호이스팅 충돌 검사를 건너뛴다.
        // ECMAScript B.3.2/B.3.3: "If replacing the FunctionDeclaration with a VariableStatement
        // would produce an Early Error, the extension is not applied" — 에러가 아니라 무시.
        const is_annex_b_fn = self.in_annex_b_context and kind.isFunctionLike();

        // 재선언 검증: 같은 스코프에서 같은 이름의 심볼이 있는지 확인
        if (!is_annex_b_fn) {
            if (self.findSymbolInScope(target_scope, name_text)) |existing| {
                if (!self.canRedeclare(existing.kind, kind, target_scope)) {
                    try self.addError(decl_span, name_text);
                    return;
                }
            }
        }

        // var/function-like의 경우 블록 스코프 체인에서도 충돌 체크
        // let x; { var x; } → 에러 (var가 호이스팅되어 let과 같은 스코프에 도달)
        if (!is_annex_b_fn and (kind == .variable_var or kind.isFunctionLike())) {
            if (try self.checkVarHoistingConflict(target_scope, name_text, decl_span)) return;
        }

        // 역방향: let/const/class/function-like 선언 시,
        // 같은 block 경로에서 선언된 var가 있으면 충돌 (LexicallyDeclaredNames ∩ VarDeclaredNames)
        // { var f; let f; } → 에러, but { let f; } 밖의 var f → 충돌 아님
        if (!is_annex_b_fn and (kind.isBlockScoped() or (kind.isFunctionLike() and !target_scope.isNone() and
            !self.scopes.items[target_scope.toIndex()].kind.isVarScope())))
        {
            if (try self.checkLexicalVarConflict(target_scope, name_text, decl_span)) return;
        }

        const sym_index = self.symbols.items.len;
        var decl_flags = kind.declFlags();
        if (is_annex_b_fn) decl_flags.is_annex_b_function = true;
        try self.symbols.append(self.allocator, .{
            .name = name_span,
            .scope_id = target_scope,
            .kind = kind,
            .decl_flags = decl_flags,
            .declaration_span = decl_span,
            .origin_scope = self.current_scope,
        });

        // symbol_ids에 선언 노드 기록
        if (node_idx) |ni| {
            if (ni < self.symbol_ids.items.len) {
                self.symbol_ids.items[ni] = @intCast(sym_index);
            }
        }

        // per-scope HashMap에도 등록 (O(1) 검색용)
        if (!target_scope.isNone()) {
            self.scopes.items[target_scope.toIndex()].symbol_count += 1;
            try self.scope_maps.items[target_scope.toIndex()].put(name_text, sym_index);
        }

        // Part 시스템: top-level scope 심볼이면 stmt_declared에 수집
        if (self.current_top_stmt) |si| {
            if (@intFromEnum(target_scope) == 0 and si < self.stmt_declared.items.len) {
                const sym_u32: u32 = @intCast(sym_index);
                self.stmt_declared.items[si].append(self.allocator, sym_u32) catch {};
            }
        }
    }

    /// 가장 가까운 var scope(function/global/module)를 찾는다.
    fn findVarScope(self: *const SemanticAnalyzer) ScopeId {
        var scope_id = self.current_scope;
        while (!scope_id.isNone()) {
            const scope = self.scopes.items[scope_id.toIndex()];
            if (scope.kind.isVarScope()) return scope_id;
            scope_id = scope.parent;
        }
        return self.current_scope; // fallback (shouldn't happen)
    }

    /// 특정 스코프에서 이름으로 심볼을 찾는다.
    /// per-scope HashMap으로 O(1) 조회 (이전: O(N) 선형 스캔).
    fn findSymbolInScope(self: *const SemanticAnalyzer, scope_id: ScopeId, name: []const u8) ?Symbol {
        if (scope_id.isNone()) return null;
        const idx = scope_id.toIndex();
        if (idx >= self.scope_maps.items.len) return null;
        const sym_idx = self.scope_maps.items[idx].get(name) orelse return null;
        return self.symbols.items[sym_idx];
    }

    /// var 호이스팅이 블록 스코프의 let/const와 충돌하는지 체크.
    /// 예: let x = 1; { var x = 2; } → 에러 (var x가 함수 스코프로 호이스팅되면서 let x와 충돌)
    fn checkVarHoistingConflict(self: *SemanticAnalyzer, var_scope: ScopeId, name: []const u8, decl_span: Span) AllocError!bool {
        // current_scope부터 var_scope까지의 중간 블록 스코프에서 let/const 선언을 찾는다
        var scope_id = self.current_scope;
        while (!scope_id.isNone() and @intFromEnum(scope_id) != @intFromEnum(var_scope)) {
            if (self.findSymbolInScope(scope_id, name)) |existing| {
                // block scope의 let/const/class와 충돌하거나,
                // block scope의 function-like 선언과도 충돌
                if (existing.kind.isBlockScoped() or existing.kind.isFunctionLike()) {
                    try self.addError(decl_span, name);
                    return true;
                }
            }
            scope_id = self.scopes.items[scope_id.toIndex()].parent;
        }
        return false;
    }

    /// 두 심볼 종류의 재선언 가능 여부를 판단한다.
    /// target_scope: 심볼이 등록되는 대상 스코프 (block/var scope 구분에 필요)
    /// let/const/class/function-like 선언 시, 같은 block 경로에서 선언된 var가 있으면 충돌.
    /// origin_scope를 사용하여 var가 실제로 현재 scope 경로에서 선언되었는지 확인.
    /// ECMAScript: "LexicallyDeclaredNames ∩ VarDeclaredNames of StatementList"
    fn checkLexicalVarConflict(self: *SemanticAnalyzer, lexical_scope: ScopeId, name: []const u8, decl_span: Span) AllocError!bool {
        const var_scope = self.findVarScope();
        // scope_maps O(1) 조회로 var scope에서 같은 이름의 심볼을 찾는다
        const sym = self.findSymbolInScope(var_scope, name) orelse return false;
        if (sym.kind != .variable_var) return false;

        // var의 origin_scope가 현재 lexical_scope의 ancestor 경로에 있는지 확인
        // { var f; let f; } → var의 origin=block, let의 scope=block → 같으므로 충돌
        // { { var f; } let f; } → var의 origin=inner, let의 scope=outer → inner는 outer의 자식이므로 충돌
        // { let f; } 밖의 var f → var의 origin=global, let의 scope=block → 충돌 아님
        if (self.isScopeDescendantOf(sym.origin_scope, lexical_scope)) {
            try self.addError(decl_span, name);
            return true;
        }
        return false;
    }

    /// child_scope가 parent_scope와 같거나 그 자손인지 확인한다.
    /// child가 parent와 같거나 그 자손인지 확인한다 (scope chain 순회).
    fn isScopeDescendantOf(self: *const SemanticAnalyzer, child: ScopeId, parent: ScopeId) bool {
        var scope_id = child;
        while (!scope_id.isNone()) {
            if (@intFromEnum(scope_id) == @intFromEnum(parent)) return true;
            scope_id = self.scopes.items[scope_id.toIndex()].parent;
        }
        return false;
    }

    /// 두 심볼 종류의 재선언 가능 여부를 판단한다.
    /// DeclFlags.excludes() 비트마스크를 사용하여 O(1) 판단 후, 특수 규칙만 추가 체크.
    fn canRedeclare(self: *const SemanticAnalyzer, existing: SymbolKind, new: SymbolKind, target_scope: ScopeId) bool {
        const existing_flags = existing.declFlags();
        const new_flags = new.declFlags();

        // TS function overload: module scope에서 function + function 허용 (TS 전용)
        // JS에서는 module scope function이 lexical이므로 재선언 불가 (ECMAScript 스펙)
        // excludes 체크보다 먼저 해야 block_scoped generator/async가 걸리지 않음
        if (self.is_ts and self.is_module and existing.isFunctionLike() and new.isFunctionLike() and !target_scope.isNone()) {
            const scope = self.scopes.items[target_scope.toIndex()];
            if (scope.kind == .module) return true;
        }

        // 기본 규칙: 비트플래그 excludes로 충돌 판단
        // existing의 flags가 new의 excludes와 겹치면 재선언 불가
        if (existing_flags.intersects(new_flags.excludes())) {
            // 특수 케이스: parameter + parameter → non-strict에서 허용 (function f(a, a) {})
            if (existing == .parameter and new == .parameter and !self.is_strict_mode) {
                return true;
            }
            // sloppy mode var scope에서 function/var 재선언 허용 (ECMAScript B.3.2-B.3.5):
            // function + function, var + function, function + var 조합
            if (!self.is_strict_mode) {
                const is_fn_fn = existing.isFunctionLike() and new.isFunctionLike();
                const is_var_fn = (existing == .variable_var and new.isFunctionLike()) or
                    (existing.isFunctionLike() and new == .variable_var);
                if (is_fn_fn or is_var_fn) {
                    const in_var_scope = if (!target_scope.isNone())
                        self.scopes.items[target_scope.toIndex()].kind.isVarScope()
                    else
                        false;
                    if (in_var_scope) return true;
                }
            }
            return false;
        }

        // module scope에서의 특별 규칙:
        // ECMAScript: "At the top level of a Module, function declarations are treated
        // like lexical declarations rather than like var declarations."
        // → function + function 재선언 불가
        // → var + function, function + var 충돌
        if (self.is_module and !target_scope.isNone()) {
            const scope = self.scopes.items[target_scope.toIndex()];
            if (scope.kind == .module) {
                // function + function은 위에서 이미 허용 (TS overload)
                if (existing.isFunctionLike() and new == .variable_var) return false;
                if (existing == .variable_var and new.isFunctionLike()) return false;
            }
        }

        // block scope에서의 특별 규칙:
        // function + function → sloppy mode block에서만 허용 (ECMAScript B.3.2)
        // strict mode block에서는 duplicate lexical → 에러
        const in_block_scope = if (!target_scope.isNone()) blk: {
            break :blk !self.scopes.items[target_scope.toIndex()].kind.isVarScope();
        } else false;

        if (in_block_scope and existing.isFunctionLike() and new.isFunctionLike()) {
            // 양쪽 다 plain function이고 sloppy mode일 때만 허용
            if (existing == .function_decl and new == .function_decl and !self.isCurrentStrict()) {
                return true;
            }
            return false;
        }

        return true;
    }

    // ================================================================
    // 참조 추적 (Reference Tracking)
    // ================================================================

    /// 식별자 참조를 해결한다.
    /// 현재 스코프부터 부모 체인을 따라 올라가며 scope_maps로 O(1) 조회.
    /// 심볼을 찾으면 reference_count를 증가시킨다.
    ///
    /// tree-shaking에서 reference_count == 0인 심볼은 미사용으로 판단할 수 있다.
    /// 글로벌 스코프까지 올라가도 못 찾으면 외부 참조(미선언 변수)로 무시한다.
    ///
    /// Note: 번들러(Phase 6)에서는 Reference 배열도 기록하여 read/write/read_write
    /// 종류와 정확한 위치를 추적할 예정 (dead store 분석 등).
    fn resolveIdentifier(self: *SemanticAnalyzer, name: []const u8, node_idx: ?u32) void {
        var scope_id = self.current_scope;

        // 스코프 체인을 따라 올라가며 심볼 검색
        while (!scope_id.isNone()) {
            const idx = scope_id.toIndex();
            if (idx >= self.scope_maps.items.len) break;

            if (self.scope_maps.items[idx].get(name)) |sym_idx| {
                // 심볼을 찾음 — reference_count 증가
                self.symbols.items[sym_idx].reference_count += 1;
                // mangler용 참조 scope 기록 (liveness 계산에 사용)
                self.ref_scope_pairs.append(self.allocator, .{
                    .symbol_idx = @intCast(sym_idx),
                    .scope_id = self.current_scope,
                }) catch {};
                // symbol_ids에 기록: 이 노드가 어떤 심볼을 참조하는지
                if (node_idx) |ni| {
                    if (ni < self.symbol_ids.items.len) {
                        self.symbol_ids.items[ni] = @intCast(sym_idx);
                    }
                }
                // Part 시스템: top-level statement의 referenced 심볼 수집
                if (self.current_top_stmt) |si| {
                    if (si < self.stmt_referenced.items.len) {
                        const sym_u32: u32 = @intCast(sym_idx);
                        if (std.mem.indexOfScalar(u32, self.stmt_referenced.items[si].items, sym_u32) == null) {
                            self.stmt_referenced.items[si].append(self.allocator, sym_u32) catch {};
                        }
                    }
                }
                return;
            }

            // 부모 스코프로 이동
            scope_id = self.scopes.items[idx].parent;
        }

        // 스코프 체인을 전부 올라갔는데 선언을 찾지 못함 → 미해결 참조 (글로벌).
        // 번들러 linker가 이 이름들을 예약하여 scope hoisting 시 shadowing을 방지.
        self.unresolved_references.put(name, {}) catch {};
    }

    /// 노드가 식별자 참조이면 resolveIdentifier를 호출하고 true를 반환한다.
    /// assignment_expression, update_expression 등에서 공통 사용.
    /// 식별자가 아니면 false를 반환하여 호출자가 일반 순회를 수행하도록 한다.
    /// 현재 스코프에서 이름으로 symbol을 찾아 no_side_effects 플래그를 설정.
    /// 현재 스코프에서 이름으로 심볼 인덱스를 찾는다.
    fn findSymbolInCurrentScope(self: *const SemanticAnalyzer, name_span: Span) ?usize {
        const name = self.ast.source[name_span.start..name_span.end];
        const scope_idx = self.current_scope.toIndex();
        if (scope_idx >= self.scope_maps.items.len) return null;
        const sym_idx = self.scope_maps.items[scope_idx].get(name) orelse return null;
        if (sym_idx >= self.symbols.items.len) return null;
        return sym_idx;
    }

    fn markSymbolNoSideEffects(self: *SemanticAnalyzer, name_span: Span) void {
        const sym_idx = self.findSymbolInCurrentScope(name_span) orelse return;
        self.symbols.items[sym_idx].decl_flags.no_side_effects = true;
    }

    /// predeclared 심볼에 대해 symbol_ids[node_idx]를 설정한다.
    /// predeclare 1st pass에서 declareSymbol(node_idx=null)로 등록된 심볼은
    /// symbol_ids에 매핑이 없으므로, 2nd pass에서 skip 시 여기서 보충한다.
    fn setSymbolIdForPredeclared(self: *SemanticAnalyzer, name_span: Span, node_idx: u32) void {
        const sym_idx = self.findSymbolInCurrentScope(name_span) orelse return;
        if (node_idx < self.symbol_ids.items.len) {
            self.symbol_ids.items[node_idx] = @intCast(sym_idx);
        }
        // Part 시스템: top-level scope 심볼이면 stmt_declared에 수집
        if (self.current_top_stmt) |si| {
            if (si < self.stmt_declared.items.len) {
                const sym_u32: u32 = @intCast(sym_idx);
                if (std.mem.indexOfScalar(u32, self.stmt_declared.items[si].items, sym_u32) == null) {
                    self.stmt_declared.items[si].append(self.allocator, sym_u32) catch {};
                }
            }
        }
    }

    /// variable_declaration의 predeclared 바인딩에 대해 symbol_ids를 설정한다.
    /// 단순 식별자와 destructuring 패턴을 재귀 처리.
    fn setSymbolIdForPredeclaredBinding(self: *SemanticAnalyzer, idx: NodeIndex) void {
        if (idx.isNone()) return;
        const ni = @intFromEnum(idx);
        if (ni >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .binding_identifier, .assignment_target_identifier => {
                self.setSymbolIdForPredeclared(node.span, ni);
            },
            .array_pattern, .array_assignment_target, .object_pattern, .object_assignment_target => {
                const list = node.data.list;
                if (list.len == 0) return;
                if (list.start + list.len > self.ast.extra_data.items.len) return;
                const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
                for (indices) |raw| {
                    self.setSymbolIdForPredeclaredBinding(@enumFromInt(raw));
                }
            },
            .binding_property, .assignment_target_property_identifier, .assignment_target_property_property => {
                self.setSymbolIdForPredeclaredBinding(node.data.binary.right);
            },
            .assignment_pattern, .assignment_target_with_default => {
                self.setSymbolIdForPredeclaredBinding(node.data.binary.left);
            },
            .binding_rest_element, .rest_element, .assignment_target_rest => {
                self.setSymbolIdForPredeclaredBinding(node.data.unary.operand);
            },
            else => {},
        }
    }

    const ConstValue = @import("symbol.zig").ConstValue;

    fn extractConstValue(self: *const SemanticAnalyzer, node: Node) ConstValue {
        return switch (node.tag) {
            .boolean_literal => blk: {
                const text = self.ast.source[node.span.start..node.span.end];
                break :blk .{ .kind = if (std.mem.eql(u8, text, "true")) .true_ else .false_ };
            },
            .null_literal => .{ .kind = .null_ },
            .identifier_reference => blk: {
                const text = self.ast.source[node.span.start..node.span.end];
                if (std.mem.eql(u8, text, "undefined")) break :blk ConstValue{ .kind = .undefined_ };
                break :blk ConstValue{};
            },
            .unary_expression => blk: {
                const text = self.ast.source[node.span.start..node.span.end];
                if (std.mem.eql(u8, text, "void 0")) break :blk ConstValue{ .kind = .undefined_ };
                break :blk ConstValue{};
            },
            else => .{},
        };
    }

    fn setSymbolConstValue(self: *SemanticAnalyzer, name_span: Span, cv: ConstValue) void {
        const sym_idx = self.findSymbolInCurrentScope(name_span) orelse return;
        self.symbols.items[sym_idx].const_value = cv;
    }

    /// 노드가 @__NO_SIDE_EFFECTS__ 함수/arrow인지 확인.
    fn isFunctionWithNoSideEffects(self: *const SemanticAnalyzer, node: Node) bool {
        const e = node.data.extra;
        return switch (node.tag) {
            .function_expression, .function_declaration => self.ast.hasExtra(e, 4) and (self.ast.readExtra(e, 4) & ast_mod.FunctionFlags.no_side_effects) != 0,
            .arrow_function_expression => self.ast.hasExtra(e, 2) and (self.ast.readExtra(e, 2) & ast_mod.ArrowFlags.no_side_effects) != 0,
            else => false,
        };
    }

    fn tryResolveNodeAsRef(self: *SemanticAnalyzer, node_idx: NodeIndex) bool {
        if (node_idx.isNone() or @intFromEnum(node_idx) >= self.ast.nodes.items.len) return false;
        const node = self.ast.getNode(node_idx);
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
            const name = self.ast.getSourceText(node.span);
            self.resolveIdentifier(name, @intFromEnum(node_idx));
            return true;
        }
        return false;
    }

    // ================================================================
    // 에러 추가
    // ================================================================

    fn addError(self: *SemanticAnalyzer, span: Span, name: []const u8) AllocError!void {
        try self.addErrorMsg(span, try std.fmt.allocPrint(self.allocator, "Identifier '{s}' has already been declared", .{name}));
    }

    fn addPrivateNameError(self: *SemanticAnalyzer, span: Span, name: []const u8) AllocError!void {
        try self.addErrorMsg(span, try std.fmt.allocPrint(self.allocator, "Private field '{s}' must be declared in an enclosing class", .{name}));
    }

    fn addErrorMsg(self: *SemanticAnalyzer, span: Span, msg: []const u8) AllocError!void {
        try self.errors.append(self.allocator, .{
            .span = span,
            .message = msg,
            .kind = .semantic,
        });
    }

    // ================================================================
    // AST Visitor — switch 기반 (D042)
    // ================================================================

    fn visitNode(self: *SemanticAnalyzer, idx: NodeIndex) AllocError!void {
        if (idx.isNone()) return;
        // 바운드 체크: 잘못된 인덱스 방어
        if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;

        const node = self.ast.getNode(idx);
        switch (node.tag) {
            // ---- 스코프 생성 노드 ----
            .program => try self.visitProgram(node),
            .block_statement => try self.visitBlockStatement(node),
            .function_declaration => try self.visitFunctionDeclaration(node),
            .function_expression => try self.visitFunctionExpression(node),
            .arrow_function_expression => try self.visitArrowFunction(node),
            .class_declaration => try self.visitClassDeclaration(node),
            .class_expression => try self.visitClassExpression(node),
            .for_statement => try self.visitForStatement(node),
            .for_in_statement => try self.visitForInOf(node),
            .for_of_statement => try self.visitForInOf(node),
            .for_await_of_statement => {
                // for await (... of ...) — top-level이면 TLA
                if (self.is_module and !self.has_top_level_await and !self.isInsideFunctionScope()) {
                    self.has_top_level_await = true;
                }
                try self.visitForInOf(node);
            },
            .switch_statement => try self.visitSwitchStatement(node),
            .catch_clause => try self.visitCatchClause(node),

            // ---- 선언 노드 ----
            .variable_declaration => try self.visitVariableDeclaration(node),
            .import_declaration => try self.visitImportDeclaration(node),

            // ---- 자식 순회만 필요한 노드 ----
            .expression_statement => try self.visitNode(node.data.unary.operand),
            .return_statement => try self.visitNode(node.data.unary.operand),
            .throw_statement => try self.visitNode(node.data.unary.operand),
            .if_statement => {
                try self.visitNode(node.data.ternary.a);
                // Annex B: if/else body에서 function declaration은 sloppy mode에서
                // var hoisting conflict check를 건너뛴다.
                const saved_annex_b = self.in_annex_b_context;
                if (!self.is_strict_mode) self.in_annex_b_context = true;
                try self.visitNode(node.data.ternary.b);
                try self.visitNode(node.data.ternary.c);
                self.in_annex_b_context = saved_annex_b;
            },
            .while_statement, .do_while_statement => {
                try self.visitNode(node.data.binary.left);
                try self.visitNode(node.data.binary.right);
            },
            .labeled_statement => try self.visitLabeledStatement(node),
            .break_statement, .continue_statement => try self.visitBreakContinue(node),
            .with_statement => {
                try self.visitNode(node.data.binary.left);
                try self.visitNode(node.data.binary.right);
            },
            .switch_case => try self.visitSwitchCase(node),
            .try_statement => try self.visitTryStatement(node),
            .export_named_declaration => try self.visitExportNamedDeclaration(node),
            .export_default_declaration => try self.visitExportDefaultDeclaration(node, idx),
            .export_all_declaration => try self.visitExportAllDeclaration(node),

            // ---- private name 참조 ----
            .private_field_expression, .static_member_expression => {
                // extra: [object, property, flags]
                const e = node.data.extra;
                if (self.ast.hasExtra(e, 1)) {
                    const prop_idx = self.ast.readExtraNode(e, 1);
                    if (!prop_idx.isNone() and @intFromEnum(prop_idx) < self.ast.nodes.items.len) {
                        const prop_node = self.ast.getNode(prop_idx);
                        if (prop_node.tag == .private_identifier) {
                            const raw = self.ast.source[prop_node.span.start..prop_node.span.end];
                            const name = try self.resolvePrivateName(raw);
                            try self.usePrivateName(name, prop_node.span);
                        }
                    }
                }
                try self.visitNode(self.ast.readExtraNode(e, 0));
            },
            .computed_member_expression => {
                // extra: [object, property, flags]
                const e = node.data.extra;
                try self.visitNode(self.ast.readExtraNode(e, 0));
                try self.visitNode(self.ast.readExtraNode(e, 1));
            },

            // ---- method_definition/property_definition 내부 순회 ----
            .method_definition => {
                // extra: [key, params.start, params.len, body, flags]
                const extra_start = node.data.extra;
                const extras = self.ast.extra_data.items;
                if (extra_start + 3 < extras.len) {
                    // key 순회 — computed property ([expr])와 private name (#name) 검출에 필요.
                    // non-computed key는 단순한 이름이므로 순회하지 않는다.
                    // 순회하면 identifier_reference로 방문되어 namespace import 이름이
                    // 잘못 resolve되는 버그가 발생한다 (예: fiberRefs 메서드 이름이
                    // `import * as fiberRefs`의 namespace 객체로 치환됨).
                    const key_idx: NodeIndex = @enumFromInt(extras[extra_start]);
                    const key_node = self.ast.getNode(key_idx);
                    if (key_node.tag == .computed_property_key or key_node.tag == .private_identifier) {
                        try self.visitNode(key_idx);
                    }

                    // getter/setter 파라미터 개수 검증
                    try checker.checkGetterSetterParams(self.ast, node, &self.errors, self.allocator);

                    const body_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);
                    // 함수 본문을 function scope로 감싸서 순회
                    const scope_saved = try self.enterScope(.function, self.is_strict_mode);
                    const params_start = extras[extra_start + 1];
                    const params_len = extras[extra_start + 2];
                    try self.registerParams(params_start, params_len);
                    // 메서드는 항상 UniqueFormalParameters — 중복 금지
                    try checker.checkDuplicateParams(self.ast, params_start, params_len, &self.errors, self.allocator);
                    try self.visitFunctionBodyInner(body_idx);
                    self.exitScope(scope_saved);
                }
            },
            .property_definition, .accessor_property => {
                // extra: [key, init_val, flags, deco_start, deco_len]
                // key는 computed property([expr])나 private name(#name)일 때만 순회.
                // non-computed key는 단순 이름이므로 순회하면 namespace import가
                // 잘못 resolve되는 버그가 발생한다.
                const e = node.data.extra;
                if (e + 1 < self.ast.extra_data.items.len) {
                    const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                    const key_node = self.ast.getNode(key_idx);
                    if (key_node.tag == .computed_property_key or key_node.tag == .private_identifier) {
                        try self.visitNode(key_idx);
                    }
                    try self.visitNode(@enumFromInt(self.ast.extra_data.items[e + 1]));
                }
            },
            .static_block => {
                // static block은 함수와 같은 경계 — label은 넘지 못함
                const saved_labels = self.saveLabelLen();
                try self.visitNode(node.data.unary.operand);
                self.restoreLabelLen(saved_labels);
            },

            // ---- 식별자 참조 추적 ----
            .identifier_reference => {
                const name = self.ast.getSourceText(node.span);
                self.resolveIdentifier(name, @intFromEnum(idx));
            },

            // JSX tag name이 대문자로 시작하면 컴포넌트 참조 (e.g. <Header />)
            .jsx_identifier => {
                const name = self.ast.getSourceText(node.span);
                if (name.len > 0 and std.ascii.isUpper(name[0])) {
                    self.resolveIdentifier(name, @intFromEnum(idx));
                }
            },

            // ---- 일반 표현식 순회 (private name 참조 등을 위해) ----
            .assignment_expression => {
                // LHS가 식별자이면 reference count 증가
                const lhs_idx = node.data.binary.left;
                if (!self.tryResolveNodeAsRef(lhs_idx)) {
                    // LHS가 멤버 표현식 등 — 일반 순회
                    try self.visitNode(lhs_idx);
                }
                // RHS는 항상 순회 (내부에 식별자 참조 등이 있을 수 있음)
                try self.visitNode(node.data.binary.right);
            },
            .binary_expression,
            .logical_expression,
            => {
                try self.visitNode(node.data.binary.left);
                try self.visitNode(node.data.binary.right);
            },
            .conditional_expression => {
                // ternary: { a = condition, b = consequent, c = alternate }
                try self.visitNode(node.data.ternary.a);
                try self.visitNode(node.data.ternary.b);
                try self.visitNode(node.data.ternary.c);
            },
            .update_expression => {
                // ++x, x++ — extra: [operand, operator_and_flags]
                const e = node.data.extra;
                const extras = self.ast.extra_data.items;
                if (e < extras.len) {
                    const operand_idx: NodeIndex = @enumFromInt(extras[e]);
                    if (!self.tryResolveNodeAsRef(operand_idx)) {
                        try self.visitNode(operand_idx);
                    }
                }
            },
            .unary_expression => {
                // extra: [operand, operator_and_flags]
                const e = node.data.extra;
                if (e < self.ast.extra_data.items.len) {
                    try self.visitNode(@enumFromInt(self.ast.extra_data.items[e]));
                }
            },
            .yield_expression,
            .parenthesized_expression,
            .spread_element,
            => {
                try self.visitNode(node.data.unary.operand);
            },
            .await_expression => {
                // TLA 감지: module top-level에서 await가 사용되면 플래그 세팅.
                // 현재 스코프 체인에 function 스코프가 없으면 top-level.
                if (self.is_module and !self.has_top_level_await and !self.isInsideFunctionScope()) {
                    self.has_top_level_await = true;
                }
                try self.visitNode(node.data.unary.operand);
            },
            .call_expression,
            .new_expression,
            => {
                // extra: [callee, args_start, args_len, flags]
                const e = node.data.extra;
                if (self.ast.hasExtra(e, 2)) {
                    const callee_idx = self.ast.readExtraNode(e, 0);
                    try self.visitNode(callee_idx);
                    try self.visitNodeList(.{
                        .start = self.ast.readExtra(e, 1),
                        .len = self.ast.readExtra(e, 2),
                    });

                    // @__NO_SIDE_EFFECTS__ 자동 전파: callee symbol이 no_side_effects이면
                    // CallFlags.is_pure 자동 설정 (O(1) — resolveIdentifier가 설정한 symbol_ids 활용)
                    if (self.ast.hasExtra(e, 3) and !callee_idx.isNone()) {
                        const callee_ni = @intFromEnum(callee_idx);
                        if (callee_ni < self.symbol_ids.items.len) {
                            if (self.symbol_ids.items[callee_ni]) |sym_idx| {
                                if (sym_idx < self.symbols.items.len and
                                    self.symbols.items[sym_idx].decl_flags.no_side_effects)
                                {
                                    self.ast.extra_data.items[e + 3] |= ast_mod.CallFlags.is_pure;
                                }
                            }
                        }
                    }
                }
            },
            .tagged_template_expression => {
                // extra: [tag, template, flags]
                const e = node.data.extra;
                try self.visitNode(self.ast.readExtraNode(e, 0));
                try self.visitNode(self.ast.readExtraNode(e, 1));
            },
            .sequence_expression => {
                try self.visitNodeList(node.data.list);
            },
            .array_expression => {
                try self.visitNodeList(node.data.list);
            },
            .object_expression => {
                // __proto__ 중복 검사 (ECMAScript 12.2.6.1)
                try checker.checkObjectDuplicateProto(self.ast, node.data.list, &self.errors, self.allocator);
                try self.visitNodeList(node.data.list);
            },
            .object_property => {
                // binary: { left = key, right = value, flags }
                const key_idx = node.data.binary.left;
                const val_idx = node.data.binary.right;
                if (!key_idx.isNone()) {
                    const key_node = self.ast.getNode(key_idx);
                    if (val_idx.isNone()) {
                        // shorthand `{x}` — key가 변수 참조이므로 resolve 필요
                        try self.visitNode(key_idx);
                    } else if (key_node.tag == .computed_property_key) {
                        // computed `{[expr]: value}` — expr 내부 순회
                        try self.visitNode(key_idx);
                    }
                    // non-shorthand `{key: value}` — key는 property name이므로 순회하지 않음.
                    // identifier_reference 태그여도 심볼 참조가 아닌 이름일 뿐.
                }
                try self.visitNode(val_idx);
            },
            .template_literal => {
                // list: [template_element, expression, template_element, ...]
                // 표현식 내부에 private name 참조 등이 있을 수 있으므로 순회
                try self.visitNodeList(node.data.list);
            },

            // ---- private_identifier 단독 노드 ----
            // method_definition/property_definition의 key로 직접 방문될 수 있음
            // class body 안이면 collectPrivateNames가 선언을 등록했으므로 usePrivateName 통과,
            // class 밖이면 에러 보고
            .private_identifier => {
                const raw = self.ast.source[node.span.start..node.span.end];
                const name = try self.resolvePrivateName(raw);
                try self.usePrivateName(name, node.span);
            },

            // ---- computed property key ----
            // [expr] 형태의 프로퍼티 키 — 내부 expression을 순회하여 private name 참조 검출
            .computed_property_key => {
                try self.visitNode(node.data.unary.operand);
            },

            // ---- JSX 순회 (tag name + attributes + children에서 식별자 참조 추적) ----
            .jsx_element => {
                // extra: [tag_name, attrs_start, attrs_len, children_start, children_len]
                const e = node.data.extra;
                if (self.ast.hasExtra(e, 4)) {
                    try self.visitNode(self.ast.readExtraNode(e, 0));
                    try self.visitNodeList(.{ .start = self.ast.readExtra(e, 1), .len = self.ast.readExtra(e, 2) }); // attrs
                    try self.visitNodeList(.{ .start = self.ast.readExtra(e, 3), .len = self.ast.readExtra(e, 4) }); // children
                }
            },
            .jsx_fragment => {
                // extra: [children_start, children_len] or list
                try self.visitNodeList(node.data.list);
            },
            .jsx_expression_container => {
                try self.visitNode(node.data.unary.operand);
            },
            .jsx_attribute => {
                // binary: { left=name, right=value }
                try self.visitNode(node.data.binary.right);
            },
            .jsx_spread_attribute => {
                try self.visitNode(node.data.unary.operand);
            },

            // ---- TS expression: 값 부분만 순회, 타입 부분은 스킵 ----
            // ts_as_expression, ts_satisfies_expression은 binary(left=expr, right=type)이지만
            // extern union이므로 unary.operand == binary.left — 값(expr) 부분만 방문한다.
            // ts_non_null_expression은 unary(operand=expr).
            // ts_type_assertion, ts_instantiation_expression은 현재 파서가 생성하지 않지만 안전을 위해 포함.
            .ts_as_expression,
            .ts_satisfies_expression,
            .ts_non_null_expression,
            .ts_type_assertion,
            .ts_instantiation_expression,
            => {
                try self.visitNode(node.data.unary.operand);
            },

            // ---- 스킵 (TS 타입 노드, 리터럴, 식별자 등) ----
            else => {},
        }
    }

    fn visitNodeList(self: *SemanticAnalyzer, list: NodeList) AllocError!void {
        if (list.len == 0) return;
        if (list.start + list.len > self.ast.extra_data.items.len) return; // 바운드 방어
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            const idx: NodeIndex = @enumFromInt(raw_idx);
            try self.visitNode(idx);
        }
    }

    // ================================================================
    // Visitor 구현 — 스코프 생성 노드
    // ================================================================

    fn visitProgram(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // module이면 module 스코프 (항상 strict), 아니면 global 스코프
        const scope_kind: ScopeKind = if (self.is_module) .module else .global;
        const saved = try self.enterScope(scope_kind, self.is_strict_mode);

        // Forward reference 지원: 2-pass 접근.
        // 1st pass — top-level 바인딩 이름만 스코프에 등록 (initializer는 순회하지 않음).
        //   예: const foo = () => bar();  // bar가 아직 스코프에 없어도
        //       const bar = () => "hello"; // 여기서 선언된 bar를 1st pass에서 미리 등록
        // 2nd pass — statement별 루프로 current_top_stmt 추적 (Part 시스템).
        try self.predeclareTopLevelBindings(node.data.list);
        self.predeclared_scope = self.current_scope;

        // Part 시스템: top-level statement별로 declared/referenced 심볼 수집.
        // visitNodeList 대신 직접 루프를 돌면서 current_top_stmt를 설정한다.
        const list = node.data.list;
        if (list.len > 0 and list.start + list.len <= self.ast.extra_data.items.len) {
            const indices = self.ast.extra_data.items[list.start .. list.start + list.len];

            try self.stmt_declared.ensureTotalCapacity(self.allocator, @intCast(indices.len));
            try self.stmt_referenced.ensureTotalCapacity(self.allocator, @intCast(indices.len));
            try self.top_stmt_node_indices.ensureTotalCapacity(self.allocator, @intCast(indices.len));

            for (indices, 0..) |raw_idx, stmt_i| {
                const idx: NodeIndex = @enumFromInt(raw_idx);

                // Part 메타데이터 기록
                self.top_stmt_node_indices.appendAssumeCapacity(raw_idx);
                self.stmt_declared.appendAssumeCapacity(.empty);
                self.stmt_referenced.appendAssumeCapacity(.empty);
                // side_effects는 buildFromSemantic에서 purity 모듈로 판정 (순환 의존 방지)

                // current_top_stmt 설정 후 방문
                self.current_top_stmt = @intCast(stmt_i);
                try self.visitNode(idx);
            }
            self.current_top_stmt = null;
        }

        self.predeclared_scope = .none;

        self.exitScope(saved);
    }

    /// Forward reference를 위한 1st pass: top-level 문(statement)에서 바인딩 이름만 추출하여
    /// 현재 스코프에 등록한다. initializer 표현식은 순회하지 않는다.
    ///
    /// 처리하는 선언:
    ///   - variable_declaration (const/let/var)
    ///   - function_declaration (이미 호이스팅되지만, 일관성을 위해)
    ///   - class_declaration
    ///   - export_named_declaration 내부의 위 선언들
    ///   - export_default_declaration 내부의 위 선언들
    /// 현재 스코프가 1st pass에서 바인딩이 미리 등록된 스코프인지 판별.
    fn isInPredeclaredScope(self: *const SemanticAnalyzer) bool {
        return self.predeclared_scope == self.current_scope;
    }

    fn predeclareTopLevelBindings(self: *SemanticAnalyzer, list: NodeList) AllocError!void {
        if (list.len == 0) return;
        if (list.start + list.len > self.ast.extra_data.items.len) return;

        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            const idx: NodeIndex = @enumFromInt(raw_idx);
            if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;

            const node = self.ast.getNode(idx);
            switch (node.tag) {
                .variable_declaration => try self.predeclareVarDecl(node),
                .function_declaration => try self.predeclareFuncDecl(node),
                .class_declaration => try self.predeclareClassDecl(node),
                .export_named_declaration => {
                    // export const x = ..., export function f() {}, export class C {}
                    const extra_start = node.data.extra;
                    const extras = self.ast.extra_data.items;
                    if (extra_start + 3 >= extras.len) continue;
                    const decl_idx: NodeIndex = @enumFromInt(extras[extra_start]);
                    if (decl_idx.isNone() or @intFromEnum(decl_idx) >= self.ast.nodes.items.len) continue;
                    const decl_node = self.ast.getNode(decl_idx);
                    switch (decl_node.tag) {
                        .variable_declaration => try self.predeclareVarDecl(decl_node),
                        .function_declaration => try self.predeclareFuncDecl(decl_node),
                        .class_declaration => try self.predeclareClassDecl(decl_node),
                        else => {},
                    }
                },
                .export_default_declaration => {
                    // export default function f() {}, export default class C {}
                    const inner_idx = node.data.unary.operand;
                    if (inner_idx.isNone() or @intFromEnum(inner_idx) >= self.ast.nodes.items.len) continue;
                    const inner_node = self.ast.getNode(inner_idx);
                    switch (inner_node.tag) {
                        .function_declaration => try self.predeclareFuncDecl(inner_node),
                        .class_declaration => try self.predeclareClassDecl(inner_node),
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    /// variable_declaration에서 바인딩 이름만 추출하여 등록 (initializer 무시).
    fn predeclareVarDecl(self: *SemanticAnalyzer, node: Node) AllocError!void {
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        const kind_flags = extras[extra_start];
        const decl_start = extras[extra_start + 1];
        const decl_len = extras[extra_start + 2];

        const sym_kind: SymbolKind = switch (kind_flags) {
            0 => .variable_var,
            1 => .variable_let,
            2 => .variable_const,
            else => .variable_var,
        };

        if (decl_start + decl_len > extras.len) return;
        const decl_indices = extras[decl_start .. decl_start + decl_len];
        for (decl_indices) |raw_idx| {
            const decl_idx: NodeIndex = @enumFromInt(raw_idx);
            if (decl_idx.isNone() or @intFromEnum(decl_idx) >= self.ast.nodes.items.len) continue;
            const decl_node = self.ast.getNode(decl_idx);
            if (decl_node.tag == .variable_declarator) {
                const binding_idx: NodeIndex = @enumFromInt(extras[decl_node.data.extra]);
                // 이름만 등록 — registerBinding 대신 predeclareBindingNames를 사용하여
                // default value 표현식을 순회하지 않는다.
                try self.predeclareBindingNames(binding_idx, sym_kind);
            }
        }
    }

    /// 바인딩 패턴에서 이름만 추출하여 심볼로 등록한다 (표현식은 순회하지 않음).
    /// registerBinding과 동일한 구조이지만, assignment_pattern의 default value 등
    /// 표현식 노드를 visitNode하지 않는다. forward reference pre-declaration 전용.
    fn predeclareBindingNames(self: *SemanticAnalyzer, idx: NodeIndex, kind: SymbolKind) AllocError!void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .binding_identifier, .assignment_target_identifier => {
                try self.declareSymbolWithNode(node.span, kind, node.span, @intFromEnum(idx));
            },
            .array_pattern, .array_assignment_target, .object_pattern, .object_assignment_target => {
                const list = node.data.list;
                if (list.len == 0) return;
                if (list.start + list.len > self.ast.extra_data.items.len) return;
                const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
                for (indices) |raw_idx| {
                    try self.predeclareBindingNames(@enumFromInt(raw_idx), kind);
                }
            },
            .binding_property, .assignment_target_property_identifier, .assignment_target_property_property => {
                try self.predeclareBindingNames(node.data.binary.right, kind);
            },
            .assignment_pattern, .assignment_target_with_default => {
                // default value(right)는 순회하지 않고, 바인딩 이름(left)만 추출
                try self.predeclareBindingNames(node.data.binary.left, kind);
            },
            .binding_rest_element, .rest_element, .assignment_target_rest => {
                try self.predeclareBindingNames(node.data.unary.operand, kind);
            },
            else => {},
        }
    }

    /// predeclared 스코프에서 registerBinding을 건너뛸 때, destructuring 패턴 내부의
    /// default value 표현식을 순회한다. 이름 등록은 하지 않음 (이미 pre-declared).
    /// 예: const { x = someExpr } = obj; 에서 someExpr를 visitNode한다.
    fn visitBindingPatternExpressions(self: *SemanticAnalyzer, idx: NodeIndex) AllocError!void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .binding_identifier, .assignment_target_identifier => {
                // 단순 식별자 — 표현식 없음
            },
            .array_pattern, .array_assignment_target, .object_pattern, .object_assignment_target => {
                const list = node.data.list;
                if (list.len == 0) return;
                if (list.start + list.len > self.ast.extra_data.items.len) return;
                const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
                for (indices) |raw_idx| {
                    try self.visitBindingPatternExpressions(@enumFromInt(raw_idx));
                }
            },
            .binding_property, .assignment_target_property_identifier, .assignment_target_property_property => {
                try self.visitBindingPatternExpressions(node.data.binary.right);
            },
            .assignment_pattern, .assignment_target_with_default => {
                // default value(right)를 순회
                try self.visitBindingPatternExpressions(node.data.binary.left);
                try self.visitNode(node.data.binary.right);
            },
            .binding_rest_element, .rest_element, .assignment_target_rest => {
                try self.visitBindingPatternExpressions(node.data.unary.operand);
            },
            else => {},
        }
    }

    /// function flags → SymbolKind 변환.
    fn functionSymbolKind(flags: u32) SymbolKind {
        const FnFlags = ast_mod.FunctionFlags;
        const is_async = (flags & FnFlags.is_async) != 0;
        const is_generator = (flags & FnFlags.is_generator) != 0;
        return if (is_async and is_generator)
            .async_generator_decl
        else if (is_async)
            .async_function_decl
        else if (is_generator)
            .generator_decl
        else
            .function_decl;
    }

    /// function_declaration의 이름만 등록.
    fn predeclareFuncDecl(self: *SemanticAnalyzer, node: Node) AllocError!void {
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 5 >= extras.len) return;
        const name_idx: NodeIndex = @enumFromInt(extras[extra_start]);

        if (!name_idx.isNone()) {
            const name_node = self.ast.getNode(name_idx);
            try self.declareSymbolWithNode(name_node.span, functionSymbolKind(extras[extra_start + 4]), node.span, @intFromEnum(name_idx));
        }
    }

    /// class_declaration의 이름만 등록.
    fn predeclareClassDecl(self: *SemanticAnalyzer, node: Node) AllocError!void {
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        const name_idx: NodeIndex = @enumFromInt(extras[extra_start]);

        if (!name_idx.isNone()) {
            const name_node = self.ast.getNode(name_idx);
            try self.declareSymbolWithNode(name_node.span, .class_decl, node.span, @intFromEnum(name_idx));
        }
    }

    fn visitBlockStatement(self: *SemanticAnalyzer, node: Node) AllocError!void {
        const saved = try self.enterScope(.block, self.is_strict_mode);
        try self.visitNodeList(node.data.list);
        self.exitScope(saved);
    }

    fn visitFunctionDeclaration(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [name, params.start, params.len, body, flags, return_type]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 5 >= extras.len) return;
        const name_idx: NodeIndex = @enumFromInt(extras[extra_start]);
        const body_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);
        const flags = extras[extra_start + 4];

        const symbol_kind = functionSymbolKind(flags);
        const has_no_side_effects = (flags & ast_mod.FunctionFlags.no_side_effects) != 0;

        // 함수 이름을 현재 스코프(외부)에 등록
        // predeclared_scope에서는 이미 1st pass에서 등록했으므로 건너뛴다.
        if (!name_idx.isNone()) {
            if (!self.isInPredeclaredScope()) {
                const name_node = self.ast.getNode(name_idx);
                try self.declareSymbolWithNode(name_node.span, symbol_kind, node.span, @intFromEnum(name_idx));
            } else {
                // predeclared: symbol_ids에 선언 노드→심볼 매핑 설정.
                // declareSymbolWithNode를 skip하지만 symbol_ids는 설정해야
                // buildFromSemantic/build에서 declared 매칭이 정확하다.
                const name_node = self.ast.getNode(name_idx);
                self.setSymbolIdForPredeclared(name_node.span, @intFromEnum(name_idx));
            }

            // @__NO_SIDE_EFFECTS__ → symbol에 전파 (predeclared 여부와 무관하게 항상 수행)
            if (has_no_side_effects) {
                const name_node = self.ast.getNode(name_idx);
                self.markSymbolNoSideEffects(name_node.span);
            }
        }

        // 함수 본문 — 새 function 스코프 (부모의 strict mode 상속)
        const saved = try self.enterScope(.function, self.is_strict_mode);
        const saved_labels = self.saveLabelLen(); // label은 함수 경계를 넘지 못함

        // 파라미터를 function 스코프에 등록
        const params_start = extras[extra_start + 1];
        const params_len = extras[extra_start + 2];
        try self.registerParams(params_start, params_len);

        // 중복 파라미터 검증: generator/async는 항상 UniqueFormalParameters,
        // 일반 함수는 strict mode에서만 (non-strict sloppy mode는 중복 허용)
        const FnFlags = ast_mod.FunctionFlags;
        if ((flags & FnFlags.is_async) != 0 or (flags & FnFlags.is_generator) != 0 or self.isCurrentStrict()) {
            try checker.checkDuplicateParams(self.ast, params_start, params_len, &self.errors, self.allocator);
        }

        // 본문 순회
        try self.visitFunctionBodyInner(body_idx);
        self.restoreLabelLen(saved_labels);
        self.exitScope(saved);
    }

    fn visitFunctionExpression(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [name, params.start, params.len, body, flags]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 4 >= extras.len) return;
        const body_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);

        const saved = try self.enterScope(.function, self.is_strict_mode);
        const saved_labels = self.saveLabelLen();

        // 함수 표현식의 이름은 자체 스코프에만 등록 (외부에서 접근 불가).
        // ECMAScript: 함수 표현식 이름은 implicit binding으로, body의 let/const/var로 섀도잉 가능.
        // 재선언 충돌을 일으키지 않도록 symbol 등록을 생략한다.
        // (이름의 read-only 접근은 런타임에서 처리)
        _ = @as(NodeIndex, @enumFromInt(extras[extra_start])); // name_idx (사용하지 않음)

        const params_start = extras[extra_start + 1];
        const params_len = extras[extra_start + 2];
        try self.registerParams(params_start, params_len);

        // 중복 파라미터 검증: flags에서 async/generator 판별
        const fn_flags = extras[extra_start + 4];
        const FnFlags = ast_mod.FunctionFlags;
        const fn_is_async = (fn_flags & FnFlags.is_async) != 0;
        const fn_is_generator = (fn_flags & FnFlags.is_generator) != 0;
        if (fn_is_async or fn_is_generator or self.isCurrentStrict()) {
            try checker.checkDuplicateParams(self.ast, params_start, params_len, &self.errors, self.allocator);
        }

        try self.visitFunctionBodyInner(body_idx);
        self.restoreLabelLen(saved_labels);
        self.exitScope(saved);
    }

    fn visitArrowFunction(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [params, body, flags]
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 2 >= extras.len) return;
        const saved = try self.enterScope(.function, self.is_strict_mode);
        const saved_labels = self.saveLabelLen();
        const body_idx: NodeIndex = @enumFromInt(extras[e + 1]);

        // left가 단일 파라미터(binding_identifier) 또는 파라미터 리스트일 수 있음
        const param_idx: NodeIndex = @enumFromInt(extras[e]);
        if (!param_idx.isNone()) {
            try self.declareArrowParams(param_idx);

            // arrow function은 항상 UniqueFormalParameters — 중복 금지
            try checker.checkDuplicateArrowParams(self.ast, param_idx, &self.errors, self.allocator);
        }

        if (!body_idx.isNone()) {
            const body_node = self.ast.getNode(body_idx);
            if (body_node.tag == .block_statement) {
                // block body — 내부를 직접 순회 (block_statement가 스코프를 또 만들지 않도록)
                try self.visitNodeList(body_node.data.list);
            } else {
                // expression body
                try self.visitNode(body_idx);
            }
        }

        self.restoreLabelLen(saved_labels);
        self.exitScope(saved);
    }

    /// arrow function의 파라미터를 재귀적으로 추출하여 심볼로 등록한다.
    /// cover grammar 변환 후 파라미터는 다양한 형태:
    /// - binding_identifier: 단일 파라미터 (x => ...)
    /// - parenthesized_expression: 괄호 형태 ((x, y) => ...)
    /// - sequence_expression: 괄호 내 여러 파라미터
    /// - assignment_pattern: 기본값 (x = 1)
    /// - identifier_reference: cover grammar에서 변환된 식별자
    /// - assignment_target_identifier: cover grammar 변환된 식별자
    fn declareArrowParams(self: *SemanticAnalyzer, idx: NodeIndex) AllocError!void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .binding_identifier, .identifier_reference, .assignment_target_identifier => {
                try self.declareSymbolWithNode(node.span, .parameter, node.span, @intFromEnum(idx));
            },
            .parenthesized_expression => {
                try self.declareArrowParams(node.data.unary.operand);
            },
            .sequence_expression => {
                // 여러 파라미터: (a, b, c)
                const list = node.data.list;
                if (list.len == 0) return;
                if (list.start + list.len > self.ast.extra_data.items.len) return;
                const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
                for (indices) |raw_idx| {
                    try self.declareArrowParams(@enumFromInt(raw_idx));
                }
            },
            .assignment_pattern, .assignment_expression => {
                // 기본값: x = 1 → left는 파라미터, right는 기본값 표현식
                try self.declareArrowParams(node.data.binary.left);
                try self.visitNode(node.data.binary.right);
            },
            .spread_element, .rest_element, .assignment_target_rest => {
                // ...rest
                try self.declareArrowParams(node.data.unary.operand);
            },
            .object_pattern, .array_pattern => {
                // destructuring 패턴 — 내부의 binding_identifier를 재귀적으로 추출
                try self.declareBindingPattern(idx);
            },
            .object_assignment_target, .array_assignment_target => {
                // cover grammar 변환된 destructuring
                try self.declareBindingPattern(idx);
            },
            else => {},
        }
    }

    /// destructuring 패턴에서 binding identifier를 재귀적으로 추출하여 parameter로 등록한다.
    fn declareBindingPattern(self: *SemanticAnalyzer, idx: NodeIndex) AllocError!void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .binding_identifier, .identifier_reference, .assignment_target_identifier => {
                try self.declareSymbolWithNode(node.span, .parameter, node.span, @intFromEnum(idx));
            },
            .object_pattern, .object_assignment_target => {
                const list = node.data.list;
                if (list.len == 0) return;
                if (list.start + list.len > self.ast.extra_data.items.len) return;
                const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
                for (indices) |raw_idx| {
                    try self.declareBindingPattern(@enumFromInt(raw_idx));
                }
            },
            .array_pattern, .array_assignment_target => {
                const list = node.data.list;
                if (list.len == 0) return;
                if (list.start + list.len > self.ast.extra_data.items.len) return;
                const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
                for (indices) |raw_idx| {
                    try self.declareBindingPattern(@enumFromInt(raw_idx));
                }
            },
            .binding_property => {
                // binary: { left = key, right = value }
                try self.declareBindingPattern(node.data.binary.right);
            },
            .assignment_target_property_identifier => {
                // shorthand property: { x } 또는 { x = default }
                // left = key(바인딩), right = default value 또는 none
                // 항상 left(key)에서 바인딩을 추출한다. right는 default value.
                try self.declareBindingPattern(node.data.binary.left);
            },
            .assignment_target_property_property => {
                // long-form property: { key: value }
                // right(value)에서 바인딩을 추출한다.
                try self.declareBindingPattern(node.data.binary.right);
            },
            .assignment_pattern, .assignment_expression, .assignment_target_with_default => {
                // 기본값: left가 바인딩
                try self.declareBindingPattern(node.data.binary.left);
            },
            .spread_element, .rest_element, .assignment_target_rest => {
                try self.declareBindingPattern(node.data.unary.operand);
            },
            else => {},
        }
    }

    fn visitClassDeclaration(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [name, super_class, body, ...]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        const name_idx: NodeIndex = @enumFromInt(extras[extra_start]);

        // 클래스 이름을 현재 스코프(외부)에 등록
        // predeclared_scope에서는 이미 1st pass에서 등록했으므로 건너뛴다.
        if (!name_idx.isNone()) {
            if (!self.isInPredeclaredScope()) {
                const name_node = self.ast.getNode(name_idx);
                try self.declareSymbolWithNode(name_node.span, .class_decl, node.span, @intFromEnum(name_idx));
            } else {
                const name_node = self.ast.getNode(name_idx);
                self.setSymbolIdForPredeclared(name_node.span, @intFromEnum(name_idx));
            }
        }

        const heritage_idx: NodeIndex = @enumFromInt(extras[extra_start + 1]);
        try self.visitClassWithHeritage(heritage_idx, @enumFromInt(extras[extra_start + 2]));
    }

    fn visitClassExpression(self: *SemanticAnalyzer, node: Node) AllocError!void {
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;

        const heritage_idx: NodeIndex = @enumFromInt(extras[extra_start + 1]);
        try self.visitClassWithHeritage(heritage_idx, @enumFromInt(extras[extra_start + 2]));
    }

    /// class를 순회한다. heritage expression과 body를 올바른 private name 환경에서 처리.
    ///
    /// ECMAScript ClassDefinitionEvaluation (15.7.14):
    ///   5. outerPrivateEnvironment = 현재 PrivateEnvironment
    ///   6-8. classPrivateEnvironment에 ClassBody의 private name 등록
    ///   10b. NOTE: ClassHeritage 평가 시 PrivateEnvironment는 outerPrivateEnvironment
    ///
    /// 즉, heritage expression에서는 이 클래스의 private name에 접근할 수 없고,
    /// 오직 외부(부모) 클래스의 private name만 보인다.
    fn visitClassWithHeritage(self: *SemanticAnalyzer, heritage_idx: NodeIndex, body_idx: NodeIndex) AllocError!void {
        // Step 1: heritage expression 순회 — 이 클래스의 class scope PUSH 전에!
        // heritage는 outerPrivateEnvironment에서 평가되므로 이 클래스의 #name에 접근 불가.
        // class scope를 push하기 전에 heritage를 순회하면, heritage에서의 #name 참조가
        // 외부 class scope에 기록되어 외부 선언만 확인된다.
        if (!heritage_idx.isNone()) {
            try self.visitNode(heritage_idx);
        }

        // Step 2: class body의 private name 수집 + early error 검증 + 순회
        // class body는 항상 strict mode (ECMAScript 10.2.1)
        const saved = try self.enterScope(.class_body, true);
        try self.pushClassScope();

        if (!body_idx.isNone() and @intFromEnum(body_idx) < self.ast.nodes.items.len) {
            const body_node = self.ast.getNode(body_idx);
            if (body_node.tag == .class_body) {
                // 1차: private name 선언 수집 (멤버 순회)
                try self.collectPrivateNames(body_node.data.list);
                // early error 검증: 중복 생성자, static/instance private name 충돌
                try checker.checkDuplicateConstructors(self.ast, body_node.data.list, &self.errors, self.allocator);
                try checker.checkPrivateNameStaticConflict(self.ast, body_node.data.list, &self.errors, self.allocator);
                // 2차: 전체 순회 (참조 검증 포함)
                try self.visitNodeList(body_node.data.list);
            }
        }

        try self.popClassScope();
        self.exitScope(saved);
    }

    /// class body 멤버에서 private name 선언을 수집한다 (1차 패스).
    fn collectPrivateNames(self: *SemanticAnalyzer, list: NodeList) AllocError!void {
        if (list.len == 0) return;
        if (list.start + list.len > self.ast.extra_data.items.len) return;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            const idx: NodeIndex = @enumFromInt(raw_idx);
            if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;
            const node = self.ast.getNode(idx);
            switch (node.tag) {
                .method_definition => {
                    // extra: [key, params.start, params.len, body, flags]
                    const extra_start = node.data.extra;
                    if (extra_start >= self.ast.extra_data.items.len) continue;
                    const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_start]);
                    // flags는 extra_start + 4: 0x02=getter, 0x04=setter
                    const kind: PrivateNameKind = blk: {
                        if (extra_start + 4 < self.ast.extra_data.items.len) {
                            const flags = self.ast.extra_data.items[extra_start + 4];
                            if (flags & 0x02 != 0) break :blk .getter;
                            if (flags & 0x04 != 0) break :blk .setter;
                        }
                        break :blk .method;
                    };
                    try self.tryRegisterPrivateKey(key_idx, kind);
                },
                .property_definition, .accessor_property => {
                    // extra: [key, init_val, flags, deco_start, deco_len]
                    const e = node.data.extra;
                    if (e < self.ast.extra_data.items.len) {
                        try self.tryRegisterPrivateKey(@enumFromInt(self.ast.extra_data.items[e]), .field);
                    }
                },
                else => {},
            }
        }
    }

    /// key가 private_identifier이면 선언 등록한다.
    fn tryRegisterPrivateKey(self: *SemanticAnalyzer, key_idx: NodeIndex, kind: PrivateNameKind) AllocError!void {
        if (key_idx.isNone() or @intFromEnum(key_idx) >= self.ast.nodes.items.len) return;
        const key_node = self.ast.getNode(key_idx);
        if (key_node.tag == .private_identifier) {
            const raw = self.ast.source[key_node.span.start..key_node.span.end];
            const name = try self.resolvePrivateName(raw);
            try self.declarePrivateName(name, key_node.span, kind);
        }
    }

    fn visitForStatement(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [init, test, update, body]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 3 >= extras.len) return;

        // for문은 블록 스코프를 생성 (for(let i=0; ...) 의 i가 블록 스코프)
        const saved = try self.enterScope(.block, self.is_strict_mode);
        try self.visitNode(@enumFromInt(extras[extra_start])); // init
        try self.visitNode(@enumFromInt(extras[extra_start + 1])); // test
        try self.visitNode(@enumFromInt(extras[extra_start + 2])); // update
        try self.visitNode(@enumFromInt(extras[extra_start + 3])); // body
        self.exitScope(saved);
    }

    fn visitForInOf(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // ternary: { a = left, b = right, c = body }
        const saved = try self.enterScope(.block, self.is_strict_mode);
        try self.visitNode(node.data.ternary.a);
        try self.visitNode(node.data.ternary.b);
        try self.visitNode(node.data.ternary.c);
        self.exitScope(saved);
    }

    /// labeled statement: label 등록 → body 순회 → label 해제.
    fn visitLabeledStatement(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // binary: { left = label identifier, right = body }
        const label_idx = node.data.binary.left;
        const body_idx = node.data.binary.right;

        if (!label_idx.isNone()) {
            const label_node = self.ast.getNode(label_idx);
            const name = self.ast.source[label_node.span.start..label_node.span.end];

            // 중복 label 체크 (같은 label 이름이 현재 스택에 있으면 에러)
            if (self.findLabel(name) != null) {
                try self.addErrorMsg(label_node.span, try std.fmt.allocPrint(self.allocator, "Label '{s}' has already been declared", .{name}));
            }

            // body가 loop인지 판별 (continue label에 필요)
            const is_loop = if (!body_idx.isNone()) blk: {
                const body_tag = self.ast.getNode(body_idx).tag;
                break :blk body_tag == .for_statement or body_tag == .for_in_statement or
                    body_tag == .for_of_statement or body_tag == .for_await_of_statement or body_tag == .while_statement or
                    body_tag == .do_while_statement;
            } else false;

            try self.labels.append(self.allocator, .{ .name = name, .span = label_node.span, .is_loop = is_loop });
            try self.visitNode(body_idx);
            _ = self.labels.pop();
        } else {
            try self.visitNode(body_idx);
        }
    }

    /// break/continue with label: label 존재 여부 + continue는 loop label만 가능.
    fn visitBreakContinue(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // unary: { operand = label identifier or none }
        const label_idx = node.data.unary.operand;
        if (label_idx.isNone()) return; // label 없는 break/continue는 파서에서 이미 검증

        const label_node = self.ast.getNode(label_idx);
        const name = self.ast.source[label_node.span.start..label_node.span.end];

        if (self.findLabel(name)) |entry| {
            // continue는 loop label만 가능
            if (node.tag == .continue_statement and !entry.is_loop) {
                try self.addErrorMsg(label_node.span, try std.fmt.allocPrint(self.allocator, "Cannot continue to non-loop label '{s}'", .{name}));
            }
        } else {
            // label이 존재하지 않음
            try self.addErrorMsg(label_node.span, try std.fmt.allocPrint(self.allocator, "Undefined label '{s}'", .{name}));
        }
    }

    fn visitSwitchStatement(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [discriminant, cases.start, cases.len]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        try self.visitNode(@enumFromInt(extras[extra_start])); // discriminant

        // switch body는 하나의 블록 스코프 (모든 case가 같은 스코프)
        const saved = try self.enterScope(.switch_block, self.is_strict_mode);
        const cases_start = extras[extra_start + 1];
        const cases_len = extras[extra_start + 2];
        const case_list = NodeList{ .start = cases_start, .len = cases_len };
        try self.visitNodeList(case_list);
        self.exitScope(saved);
    }

    fn visitCatchClause(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // binary: { left = param, right = body, flags }
        const saved = try self.enterScope(.catch_clause, self.is_strict_mode);
        const param_idx = node.data.binary.left;

        // catch param 이름 수집 (중복 바인딩 검사 + block body 충돌 검사용)
        var catch_names: [16]Span = undefined;
        var catch_name_count: usize = 0;

        if (!param_idx.isNone()) {
            const param_node = self.ast.getNode(param_idx);
            if (param_node.tag == .binding_identifier) {
                try self.declareSymbolWithNode(param_node.span, .catch_binding, param_node.span, @intFromEnum(param_idx));
                if (catch_name_count < 16) {
                    catch_names[catch_name_count] = param_node.span;
                    catch_name_count += 1;
                }
            } else {
                // Destructuring pattern — collect all binding names and check duplicates
                try self.collectAndCheckCatchBindings(param_idx, &catch_names, &catch_name_count);
            }
        }

        // Visit body (block statement) with catch param conflict checking
        const body_idx = node.data.binary.right;
        if (!body_idx.isNone()) {
            const body_node = self.ast.getNode(body_idx);
            if (body_node.tag == .block_statement and catch_name_count > 0) {
                // Enter block scope for the body
                const block_saved = try self.enterScope(.block, self.is_strict_mode);
                // Visit block body statements
                try self.visitNodeList(body_node.data.list);
                // Check for catch param conflicts with lexically-declared names in the block
                try self.checkCatchBodyConflicts(catch_names[0..catch_name_count]);
                self.exitScope(block_saved);
            } else {
                try self.visitNode(body_idx);
            }
        }
        self.exitScope(saved);
    }

    /// Collect binding names from destructuring pattern and check for duplicate catch bindings.
    fn collectAndCheckCatchBindings(self: *SemanticAnalyzer, idx: NodeIndex, names: *[16]Span, count: *usize) AllocError!void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .binding_identifier => {
                // Check for duplicate
                const name_text = self.ast.source[node.span.start..node.span.end];
                for (names.*[0..count.*]) |existing_span| {
                    const existing_text = self.ast.source[existing_span.start..existing_span.end];
                    if (std.mem.eql(u8, name_text, existing_text)) {
                        try self.addError(node.span, name_text);
                        return;
                    }
                }
                try self.declareSymbolWithNode(node.span, .catch_binding, node.span, @intFromEnum(idx));
                if (count.* < 16) {
                    names.*[count.*] = node.span;
                    count.* += 1;
                }
            },
            .array_pattern, .array_expression => {
                // list: binding elements
                if (node.data.list.len == 0) return;
                if (node.data.list.start + node.data.list.len > self.ast.extra_data.items.len) return;
                const indices = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                for (indices) |raw_idx| {
                    try self.collectAndCheckCatchBindings(@enumFromInt(raw_idx), names, count);
                }
            },
            .object_pattern, .object_expression => {
                if (node.data.list.len == 0) return;
                if (node.data.list.start + node.data.list.len > self.ast.extra_data.items.len) return;
                const indices = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                for (indices) |raw_idx| {
                    const prop_idx: NodeIndex = @enumFromInt(raw_idx);
                    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) continue;
                    const prop = self.ast.getNode(prop_idx);
                    if (prop.tag == .object_property or
                        prop.tag == .assignment_target_property_identifier)
                    {
                        try self.collectAndCheckCatchBindings(prop.data.binary.right, names, count);
                    } else {
                        try self.collectAndCheckCatchBindings(prop_idx, names, count);
                    }
                }
            },
            .assignment_pattern, .assignment_target_with_default => {
                // binary: { left = pattern, right = default }
                try self.collectAndCheckCatchBindings(node.data.binary.left, names, count);
            },
            .rest_element => {
                try self.collectAndCheckCatchBindings(node.data.unary.operand, names, count);
            },
            else => {},
        }
    }

    /// Check if any lexically-declared name in the catch body block conflicts with catch parameter names.
    fn checkCatchBodyConflicts(self: *SemanticAnalyzer, catch_names: []const Span) AllocError!void {
        // Check symbols declared in current scope against catch parameter names
        for (self.symbols.items) |sym| {
            if (@intFromEnum(sym.scope_id) != @intFromEnum(self.current_scope)) continue;
            // Only block-scoped (let/const/class) and function-like declarations conflict
            if (!sym.kind.isBlockScoped() and !sym.kind.isFunctionLike()) continue;
            // Annex B: if/else body의 function declaration은 catch parameter와 충돌하지 않는다.
            // ECMAScript B.3.5: var-like hoisting이 적용되는 함수는 catch parameter를 shadow 가능.
            if (sym.decl_flags.is_annex_b_function) continue;
            const sym_name = self.ast.source[sym.name.start..sym.name.end];
            for (catch_names) |catch_span| {
                const catch_name = self.ast.source[catch_span.start..catch_span.end];
                if (std.mem.eql(u8, sym_name, catch_name)) {
                    try self.addError(sym.declaration_span, sym_name);
                    return;
                }
            }
        }
    }

    fn visitSwitchCase(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [test_expr, body.start, body.len]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        // test_expr 순회 — 식별자 참조를 포함할 수 있음 (e.g. case VAL:)
        try self.visitNode(@enumFromInt(extras[extra_start]));
        const body_start = extras[extra_start + 1];
        const body_len = extras[extra_start + 2];
        try self.visitNodeList(.{ .start = body_start, .len = body_len });
    }

    fn visitTryStatement(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // ternary: { a = try_block, b = catch_clause, c = finally_block }
        try self.visitNode(node.data.ternary.a);
        try self.visitNode(node.data.ternary.b);
        try self.visitNode(node.data.ternary.c);
    }

    // ================================================================
    // Visitor 구현 — 선언 노드
    // ================================================================

    fn visitVariableDeclaration(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [kind_flags, declarators.start, declarators.len]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return; // 바운드 방어
        const kind_flags = extras[extra_start];
        const decl_start = extras[extra_start + 1];
        const decl_len = extras[extra_start + 2];

        const sym_kind: SymbolKind = switch (kind_flags) {
            0 => .variable_var,
            1 => .variable_let,
            2 => .variable_const,
            else => .variable_var,
        };

        // 각 declarator에서 바인딩 이름 추출
        // variable_declarator의 data는 extra: [name, type_ann, init_expr]
        const decl_indices = self.ast.extra_data.items[decl_start .. decl_start + decl_len];
        for (decl_indices) |raw_idx| {
            const decl_idx: NodeIndex = @enumFromInt(raw_idx);
            if (decl_idx.isNone()) continue;
            const decl_node = self.ast.getNode(decl_idx);
            if (decl_node.tag == .variable_declarator) {
                // extra: [name, type_ann, init_expr]
                const decl_extra = decl_node.data.extra;
                const decl_extras = self.ast.extra_data.items;
                const binding_idx: NodeIndex = @enumFromInt(decl_extras[decl_extra]);
                const init_idx: NodeIndex = @enumFromInt(decl_extras[decl_extra + 2]);

                // predeclared_scope에서는 이미 1st pass에서 바인딩이 등록되었으므로 건너뛴다.
                // 다시 registerBinding을 호출하면 let/const 재선언 에러가 발생한다.
                if (!self.isInPredeclaredScope()) {
                    try self.registerBinding(binding_idx, sym_kind);
                } else {
                    // predeclared: symbol_ids에 선언 노드→심볼 매핑 설정
                    self.setSymbolIdForPredeclaredBinding(binding_idx);
                    // predeclared인 경우에도, destructuring 패턴 내부의 default value
                    // 표현식은 순회해야 한다 (registerBinding이 수행하던 visitNode 호출 대체).
                    try self.visitBindingPatternExpressions(binding_idx);
                }
                // init 표현식도 순회 (내부에 함수 표현식 등이 있을 수 있음)
                try self.visitNode(init_idx);

                if (!init_idx.isNone() and @intFromEnum(init_idx) < self.ast.nodes.items.len) {
                    const init_node = self.ast.getNode(init_idx);
                    // @__NO_SIDE_EFFECTS__ 전파
                    if (self.isFunctionWithNoSideEffects(init_node)) {
                        if (!binding_idx.isNone() and @intFromEnum(binding_idx) < self.ast.nodes.items.len) {
                            const binding_node = self.ast.getNode(binding_idx);
                            self.markSymbolNoSideEffects(binding_node.span);
                        }
                    }
                    // const/let 리터럴 → const_value 설정 (번들러 상수 인라인용)
                    if (sym_kind == .variable_const or sym_kind == .variable_let) {
                        const cv = self.extractConstValue(init_node);
                        if (cv.kind != .none) {
                            if (!binding_idx.isNone() and @intFromEnum(binding_idx) < self.ast.nodes.items.len) {
                                const binding_node = self.ast.getNode(binding_idx);
                                self.setSymbolConstValue(binding_node.span, cv);
                            }
                        }
                    }
                }
            }
        }
    }

    fn visitImportDeclaration(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra_data에서 specifiers 리스트 추출
        // side-effect import는 specs_len=0이므로 아래에서 early return.
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;

        const specs_start = extras[extra_start];
        const specs_len = extras[extra_start + 1];
        if (specs_len == 0) return;
        if (specs_start + specs_len > extras.len) return;

        const spec_indices = extras[specs_start .. specs_start + specs_len];
        for (spec_indices) |raw_idx| {
            const spec_idx: NodeIndex = @enumFromInt(raw_idx);
            if (spec_idx.isNone()) continue;
            if (@intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;

            const spec_node = self.ast.getNode(spec_idx);
            switch (spec_node.tag) {
                .import_default_specifier => {
                    try self.checkStrictBindingName(spec_node.span);
                    try self.declareSymbolWithNode(spec_node.span, .import_binding, spec_node.span, @intFromEnum(spec_idx));
                },
                .import_namespace_specifier => {
                    try self.checkStrictBindingName(spec_node.span);
                    try self.declareSymbolWithNode(spec_node.span, .import_binding, spec_node.span, @intFromEnum(spec_idx));
                },
                .import_specifier => {
                    const local_idx = spec_node.data.binary.right;
                    if (!local_idx.isNone() and @intFromEnum(local_idx) < self.ast.nodes.items.len) {
                        const local_node = self.ast.getNode(local_idx);
                        try self.checkStrictBindingName(local_node.span);
                        try self.declareSymbolWithNode(local_node.span, .import_binding, spec_node.span, @intFromEnum(local_idx));
                    }
                },
                else => {},
            }
        }
    }

    /// strict mode에서 eval/arguments를 바인딩 이름으로 사용할 수 없다.
    /// module code는 항상 strict mode.
    fn checkStrictBindingName(self: *SemanticAnalyzer, span: Span) AllocError!void {
        if (!self.isCurrentStrict()) return;
        const name = self.ast.source[span.start..span.end];
        if (std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments")) {
            try self.addErrorMsg(span, try std.fmt.allocPrint(
                self.allocator,
                "'{s}' cannot be used as a binding identifier in strict mode",
                .{name},
            ));
        }
    }

    fn visitExportNamedDeclaration(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // extra: [declaration, specifiers_start, specifiers_len, source]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 3 >= extras.len) return;
        const decl_idx: NodeIndex = @enumFromInt(extras[extra_start]);
        const specs_start = extras[extra_start + 1];
        const specs_len = extras[extra_start + 2];
        const source_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);

        // export { a, b as c } — specifier로 내보낸 이름 추적
        if (specs_len > 0 and specs_start + specs_len <= extras.len) {
            const spec_indices = extras[specs_start .. specs_start + specs_len];
            for (spec_indices) |raw_idx| {
                const spec_idx: NodeIndex = @enumFromInt(raw_idx);
                if (spec_idx.isNone() or @intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;
                const spec_node = self.ast.getNode(spec_idx);
                if (spec_node.tag == .export_specifier) {
                    // exported name = right (the "as" name, or same as local if no "as")
                    const exported_idx = spec_node.data.binary.right;
                    if (!exported_idx.isNone() and @intFromEnum(exported_idx) < self.ast.nodes.items.len) {
                        const exported_node = self.ast.getNode(exported_idx);
                        const name = self.ast.source[exported_node.span.start..exported_node.span.end];
                        // string literal은 따옴표 제거
                        const effective_name = if (name.len >= 2 and (name[0] == '\'' or name[0] == '"'))
                            name[1 .. name.len - 1]
                        else
                            name;
                        try self.registerExportedName(effective_name, exported_node.span);
                    }

                    // source 없는 export { x } — local 바인딩이 존재하는지 검증 필요
                    if (source_idx.isNone() and self.is_module) {
                        const local_idx = spec_node.data.binary.left;
                        if (!local_idx.isNone() and @intFromEnum(local_idx) < self.ast.nodes.items.len) {
                            const local_node = self.ast.getNode(local_idx);
                            if (local_node.tag != .string_literal) {
                                const local_name = self.ast.source[local_node.span.start..local_node.span.end];
                                try self.checkExportBinding(local_name, local_node.span);
                            }
                        }
                    }
                }
            }
        }

        // export declaration (export var/let/const/function/class)
        if (!decl_idx.isNone() and @intFromEnum(decl_idx) < self.ast.nodes.items.len) {
            const decl_node = self.ast.getNode(decl_idx);
            // 선언에서 내보내는 이름 추적
            try self.collectExportedDeclNames(decl_node);
        }

        try self.visitNode(decl_idx);
    }

    /// export default 시 "default" 이름을 등록한다.
    /// inner가 named function/class/identifier가 아니면 `_default` facade 심볼을 생성하여
    /// scope_maps[0]에 등록 — StmtInfo가 심볼 기반으로 도달성을 추적할 수 있게 한다.
    fn visitExportDefaultDeclaration(self: *SemanticAnalyzer, node: Node, node_idx: NodeIndex) AllocError!void {
        try self.registerExportedName("default", node.span);

        // inner 노드 확인: named function/class/identifier이면 이미 심볼이 존재
        const inner_idx = node.data.unary.operand;
        var needs_facade = true;
        if (!inner_idx.isNone() and @intFromEnum(inner_idx) < self.ast.nodes.items.len) {
            const inner = self.ast.getNode(inner_idx);
            if (inner.tag == .function_declaration or inner.tag == .class_declaration) {
                // named function/class인지 확인 (이름이 있으면 predeclare에서 이미 심볼 생성됨)
                const e = inner.data.extra;
                if (e < self.ast.extra_data.items.len) {
                    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                    if (!name_idx.isNone()) needs_facade = false;
                }
            } else if (inner.tag == .identifier_reference) {
                // export default someVar → 기존 심볼 참조, facade 불필요
                needs_facade = false;
            }
        }

        if (needs_facade) {
            // _default facade 심볼 생성 — declareSymbolWithNode 우회 (재선언 검증 불필요)
            const module_scope = self.findVarScope();
            if (!module_scope.isNone()) {
                const sym_index = self.symbols.items.len;
                try self.symbols.append(self.allocator, .{
                    .name = node.span, // export default 문 전체 span
                    .scope_id = module_scope,
                    .kind = .variable_const,
                    .decl_flags = .{ .block_scoped = true, .is_const = true },
                    .declaration_span = node.span,
                    .origin_scope = module_scope,
                });
                // symbol_ids에 export_default_declaration 노드 자체를 기록
                const ni = @intFromEnum(node_idx);
                if (ni < self.symbol_ids.items.len) {
                    self.symbol_ids.items[ni] = @intCast(sym_index);
                }
                // scope_maps[0]에 "_default" 등록 — emitter/StmtInfo가 찾을 수 있도록
                try self.scope_maps.items[module_scope.toIndex()].put("_default", sym_index);
                // Part 시스템: facade 심볼도 stmt_declared에 수집
                if (self.current_top_stmt) |si| {
                    if (@intFromEnum(module_scope) == 0 and si < self.stmt_declared.items.len) {
                        self.stmt_declared.items[si].append(self.allocator, @intCast(sym_index)) catch {};
                    }
                }
                // export default <literal> → facade 심볼에 const_value 설정
                if (!inner_idx.isNone() and @intFromEnum(inner_idx) < self.ast.nodes.items.len) {
                    const cv = self.extractConstValue(self.ast.getNode(inner_idx));
                    if (cv.kind != .none) {
                        self.symbols.items[sym_index].const_value = cv;
                    }
                }
            }
        }

        // 내부 선언 순회
        try self.visitNode(inner_idx);
    }

    /// export * as name — name을 등록한다.
    fn visitExportAllDeclaration(self: *SemanticAnalyzer, node: Node) AllocError!void {
        // binary: { left = exported_name, right = source }
        const name_idx = node.data.binary.left;
        if (!name_idx.isNone() and @intFromEnum(name_idx) < self.ast.nodes.items.len) {
            const name_node = self.ast.getNode(name_idx);
            const name = self.ast.source[name_node.span.start..name_node.span.end];
            const effective_name = if (name.len >= 2 and (name[0] == '\'' or name[0] == '"'))
                name[1 .. name.len - 1]
            else
                name;
            try self.registerExportedName(effective_name, name_node.span);
        }
    }

    /// 선언에서 내보내는 이름을 추적한다 (export var x, export function f, etc.)
    fn collectExportedDeclNames(self: *SemanticAnalyzer, node: Node) AllocError!void {
        switch (node.tag) {
            .variable_declaration => {
                // variable_declaration → declarator → binding name
                const extra_start = node.data.extra;
                const extras = self.ast.extra_data.items;
                if (extra_start + 2 >= extras.len) return;
                const decl_start = extras[extra_start + 1];
                const decl_len = extras[extra_start + 2];
                if (decl_start + decl_len > extras.len) return;
                for (extras[decl_start .. decl_start + decl_len]) |raw_idx| {
                    const decl_idx: NodeIndex = @enumFromInt(raw_idx);
                    if (decl_idx.isNone() or @intFromEnum(decl_idx) >= self.ast.nodes.items.len) continue;
                    const decl_node = self.ast.getNode(decl_idx);
                    if (decl_node.tag == .variable_declarator) {
                        const binding_idx: NodeIndex = @enumFromInt(extras[decl_node.data.extra]);
                        try self.collectBindingExportNames(binding_idx);
                    }
                }
            },
            .function_declaration => {
                const extras = self.ast.extra_data.items;
                if (node.data.extra >= extras.len) return;
                const name_idx: NodeIndex = @enumFromInt(extras[node.data.extra]);
                if (!name_idx.isNone() and @intFromEnum(name_idx) < self.ast.nodes.items.len) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.source[name_node.span.start..name_node.span.end];
                    try self.registerExportedName(name, name_node.span);
                }
            },
            .class_declaration => {
                const extras = self.ast.extra_data.items;
                if (node.data.extra >= extras.len) return;
                const name_idx: NodeIndex = @enumFromInt(extras[node.data.extra]);
                if (!name_idx.isNone() and @intFromEnum(name_idx) < self.ast.nodes.items.len) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.source[name_node.span.start..name_node.span.end];
                    try self.registerExportedName(name, name_node.span);
                }
            },
            else => {},
        }
    }

    /// 바인딩 패턴에서 내보내는 이름을 수집한다.
    fn collectBindingExportNames(self: *SemanticAnalyzer, idx: NodeIndex) AllocError!void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .binding_identifier) {
            const name = self.ast.source[node.span.start..node.span.end];
            try self.registerExportedName(name, node.span);
        }
    }

    /// 내보낸 이름을 등록한다. JS에서 중복이면 에러, TS에서는 허용 (oxc 동일).
    /// TS에서는 function overload, namespace merge 등으로 같은 이름의 export가 합법.
    fn registerExportedName(self: *SemanticAnalyzer, name: []const u8, span: Span) AllocError!void {
        if (!self.is_module) return;
        if (self.exported_names.get(name)) |_| {
            // TS 모드: duplicate export 체크 스킵 (oxc: !is_typescript() 조건)
            // JS 모드에서만 에러
            if (!self.is_ts) {
                try self.addErrorMsg(span, try std.fmt.allocPrint(
                    self.allocator,
                    "Duplicate export name '{s}'",
                    .{name},
                ));
            }
        } else {
            try self.exported_names.put(name, span);
        }
    }

    /// export { x } (without from) — x가 선언된 바인딩인지 검증한다.
    /// module scope에서 VarDeclaredNames + LexicallyDeclaredNames에 없으면 에러.
    fn checkExportBinding(self: *SemanticAnalyzer, name: []const u8, span: Span) AllocError!void {
        // 현재 module scope에서 해당 이름의 심볼을 찾는다
        for (self.symbols.items) |sym| {
            const sym_name = self.ast.source[sym.name.start..sym.name.end];
            if (std.mem.eql(u8, sym_name, name)) return; // 존재
        }
        // 찾지 못함 → 에러
        try self.addErrorMsg(span, try std.fmt.allocPrint(
            self.allocator,
            "Export '{s}' is not defined",
            .{name},
        ));
    }

    // ================================================================
    // 헬퍼
    // ================================================================

    /// 바인딩 패턴에서 이름을 추출하여 심볼로 등록한다.
    /// 단순 식별자, 배열 패턴, 객체 패턴을 재귀적으로 처리.
    fn registerBinding(self: *SemanticAnalyzer, idx: NodeIndex, kind: SymbolKind) AllocError!void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .binding_identifier, .assignment_target_identifier => {
                try self.declareSymbolWithNode(node.span, kind, node.span, @intFromEnum(idx));
            },
            .array_pattern, .array_assignment_target => {
                // list of elements
                try self.registerBindingList(node.data.list, kind);
            },
            .object_pattern, .object_assignment_target => {
                // list of binding_property
                try self.registerBindingList(node.data.list, kind);
            },
            .binding_property,
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            => {
                // binary: { left = key, right = value }
                try self.registerBinding(node.data.binary.right, kind);
            },
            .assignment_pattern, .assignment_target_with_default => {
                // binary: { left = binding, right = default_value }
                try self.registerBinding(node.data.binary.left, kind);
                // 기본값 순회 — 식별자 참조를 포함할 수 있음 (e.g. function f(a = imported))
                try self.visitNode(node.data.binary.right);
            },
            .binding_rest_element, .rest_element, .assignment_target_rest => {
                // unary: { operand = binding }
                try self.registerBinding(node.data.unary.operand, kind);
            },
            else => {},
        }
    }

    fn registerBindingList(self: *SemanticAnalyzer, list: NodeList, kind: SymbolKind) AllocError!void {
        if (list.len == 0) return;
        if (list.start + list.len > self.ast.extra_data.items.len) return;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            try self.registerBinding(@enumFromInt(raw_idx), kind);
        }
    }

    /// 함수 파라미터를 현재 스코프에 등록한다.
    fn registerParams(self: *SemanticAnalyzer, params_start: u32, params_len: u32) AllocError!void {
        if (params_len == 0) return;
        if (params_start + params_len > self.ast.extra_data.items.len) return;
        const param_indices = self.ast.extra_data.items[params_start .. params_start + params_len];
        for (param_indices) |raw_idx| {
            try self.registerBinding(@enumFromInt(raw_idx), .parameter);
        }
    }

    /// 함수 본문 내부를 순회한다 (block_statement의 스코프 중복 생성 방지).
    fn visitFunctionBodyInner(self: *SemanticAnalyzer, body_idx: NodeIndex) AllocError!void {
        if (body_idx.isNone()) return;
        const body_node = self.ast.getNode(body_idx);
        if (body_node.tag == .block_statement) {
            // function 스코프가 이미 생성되었으므로 block_statement의 내용만 순회
            try self.visitNodeList(body_node.data.list);
        } else {
            try self.visitNode(body_idx);
        }
    }
};
