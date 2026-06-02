//! ZNTC AST Constant Folding & Dead Branch Elimination
//!
//! transformer 완료 후 ast를 in-place 수정. bundler/emitter가 항상 호출(#1552).
//! `--define`으로 주입된 상수 비교/리터럴 분기 정리가 `--minify` 없이도 동작해야
//! rolldown/esbuild와 같은 DCE 효과가 난다.
//!
//! 하는 일:
//!   - 이항/단항 상수 폴딩: 1+2→3, "a"+"b"→"ab", !true→false, typeof "x"→"string"
//!   - 엄격 비교: 1===1→true, "a"==="b"→false
//!   - 논리 단락: true && x → x, false || x → x, null ?? x → x
//!   - if / while / ?: dead branch 제거
//!   - sequence/comma 정리
//!
//! 하지 않는 것: 식별자 mangling, 주석 제거 (별도 --minify / codegen peephole 영역).
//!
//! 참고:
//!   - oxc peephole/fold_constants.rs
//!   - esbuild js_ast_helpers.go (ShouldFoldBinaryOperatorWhenMinifying)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const Span = @import("../lexer/token.zig").Span;
const Kind = @import("../lexer/token.zig").Kind;
const symbol_mod = @import("../semantic/symbol.zig");
const scope_mod = @import("../semantic/scope.zig");
const purity = @import("../bundler/purity.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const numeric = @import("minify/numeric.zig");
const unused_expr = @import("minify/unused_expr.zig");
const string_escape = @import("../string_escape.zig");
const debug_log = @import("../debug_log.zig");
const module_parser = @import("../parser/module.zig");

// RFC #3411 PR-1: bundle-context `export const X=...` 는 codegen 이 bare
// `const X=...` 로 출력하나 AST tag 는 `.export_named_declaration` 으로 남아
// 기존 decl-coalescing(tryMergeWithPrev, `.variable_declaration` 만)에서
// 원천 제외된다 (effect 841 미병합). 이제 export-wrapper 도 병합 후보로
// 인식 — `export const a=1,b=2;` 는 ESM 어디서나 valid 하고 export↔
// non-export 혼합 가드(resolveMergeableVarDecl.is_export 동치)가 intrinsic
// 이라 build-mode 무관 안전. 측정: effect −2.0%, 전수 144-lib 회귀 0,
// 27 lib 개선. `ZNTC_NO_DECL_COALESCE` 는 kill-switch (회귀 시 강제 비활성
// → pre-PR byte-identical). force-ON 미제공 (footgun 회피).
const decl_coalesce_disabled = @import("../env_flag.zig").Once("ZNTC_NO_DECL_COALESCE");

/// statement 노드를 "병합 가능한 내부 variable_declaration + export 여부" 로
/// 해석. plain `.variable_declaration` → {ni, is_export=false}. flag on 시
/// `.export_named_declaration` 중 *specifier/source/attrs 없는 local
/// `export const/let/var X=...`* → {inner_decl_ni, is_export=true}.
/// 그 외 (export {a} from / export * / export default / specifier-only) →
/// null (비대상 — 안전 우선).
const MergeableDecl = struct { vardecl_ni: u32, is_export: bool };

fn resolveMergeableVarDecl(ast: *const Ast, ni: u32) ?MergeableDecl {
    if (ni >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[ni];
    if (node.tag == .variable_declaration) return .{ .vardecl_ni = ni, .is_export = false };
    if (decl_coalesce_disabled.enabled()) return null;
    if (node.tag != .export_named_declaration) return null;
    // 방어: 파서 불변상 export_named_declaration 은 항상 6슬롯이나, 코드베이스
    // 관례(metadata.zig/binding_scanner.zig 의 `e+N >= len` 가드)와 일치시켜
    // extras read 전 바운드 확인 (transformer 가 이 tag 를 생성하진 않음).
    if (@as(usize, node.data.extra) + 6 > ast.extra_data.items.len) return null;
    const x = module_parser.readExportNamedExtras(ast, node.data.extra);
    if (x.decl.isNone() or x.specs_len != 0 or !x.source.isNone() or x.attrs_len != 0) return null;
    const decl_ni: u32 = @intFromEnum(x.decl);
    if (decl_ni >= ast.nodes.items.len) return null;
    if (ast.nodes.items[decl_ni].tag != .variable_declaration) return null;
    return .{ .vardecl_ni = decl_ni, .is_export = true };
}

/// Minify pass 컨텍스트. semantic 정보가 있을 때만 dead store 제거가 동작한다.
/// `symbols` 는 read-only 로 사용한다 — 과거엔 `reference_count` 를 직접 감산했지만,
/// `module.semantic` 이 `PersistentModuleStore` 에 캐시되어 rebuild 간 재사용되므로
/// 영구 뮤테이션은 누적 감산 → live 선언 오제거로 이어진다. emit 당 임시 delta
/// 는 `minify` 내부 scratch 배열에 기록하고, check/rewrite 는 그 조합으로 판정한다.
/// `scopes` 는 eval / with 포함 여부 조회용 (dynamic lookup 보호).
pub const MinifyCtx = struct {
    symbols: []const symbol_mod.Symbol,
    symbol_ids: []const ?u32,
    /// `symbol_ids` 의 mutable view (동일 backing). single-use **identifier-alias** inline
    /// 이 read 위치 노드의 symbol_id 를 init 식별자(`S`)의 것으로 갱신하는 데 필요 —
    /// codegen/mangler 의 rename 조회가 symbol_id 기준이라(둘 다 `transformer.symbol_ids` 를
    /// 읽음 = 단일 진실의 원천). null 이면 alias inline 자체를 skip (constant inline 무관).
    symbol_ids_mut: ?[]?u32 = null,
    scopes: []const scope_mod.Scope,
    unresolved_globals: ?*const purity.GlobalRefSet,
    /// per-reference 배열. #1666 single-use inline 이 declaration ↔ read adjacency
    /// 를 판단하는 데 사용 (`scope_stmt_idx`). 비어있으면 inline pass 는 skip.
    references: []const symbol_mod.Reference = &.{},
    /// symbol 별 누적 감산량 (이번 emit 한정). length == symbols.len 또는 0.
    /// 비어있으면 `symbols[*].reference_count` 를 그대로 사용 (최초 호출 경로).
    /// `minify()` 진입부에서 scratch 로 할당 → `decrementRefsInExpr` 가 증가.
    ref_deltas: []u32 = &.{},
    /// Top-level constant inline is a size optimization that can make debug/non-minified
    /// output less readable. Keep it behind minify_syntax.
    allow_top_level_inline: bool = false,
    /// Module-level dead store removal.
    ///
    /// 기본은 false — transpile 단독 경로에선 entry top-level 선언이 사라지면
    /// 외부 host 의 `import {x} from "./mod"` 가 깨진다. bundle 경로에선 tree-shaker
    /// 가 cross-module ref 보존을 이미 보장하고, 진짜 dead 인 module-level binding
    /// (sym.isExported()==false + intra-module ref==0 + pure init) 은 안전하게
    /// elide 가능. caller (emitter) 가 `shaker != null` 일 때만 true 세팅.
    allow_top_level_dead: bool = false,

    /// semantic 없이 호출할 때 사용. dead store pass 는 skip 된다.
    pub const empty: MinifyCtx = .{
        .symbols = &.{},
        .symbol_ids = &.{},
        .scopes = &.{},
        .unresolved_globals = null,
    };

    /// `module.semantic` + 호출 사이트의 `symbol_ids` 로 ctx 를 생성. transformer 진행 중에는
    /// transformer.symbol_ids 를, 정착된 분석 산출물을 다룰 때는 sem.symbol_ids 를 넘긴다.
    pub fn fromSemantic(
        sem: anytype,
        symbol_ids: []const ?u32,
        allow_top_level_inline: bool,
    ) MinifyCtx {
        return .{
            .symbols = sem.symbols.items,
            .symbol_ids = symbol_ids,
            .scopes = sem.scopes,
            .unresolved_globals = &sem.unresolved_references,
            .references = sem.references,
            .allow_top_level_inline = allow_top_level_inline,
        };
    }

    /// semantic 정보 3축 (symbols / symbol_ids / scopes) 이 모두 채워졌는지 확인.
    /// scopes 누락 시 eval / with 가드가 silent 통과되어 직접 eval 스코프 안의 변수가
    /// 잘못 제거될 수 있으므로, 세 필드 모두 요구하는 all-or-nothing 계약.
    pub inline fn hasSemantic(self: MinifyCtx) bool {
        return self.symbols.len > 0 and self.symbol_ids.len > 0 and self.scopes.len > 0;
    }

    /// 심볼 id 의 effective reference_count (ref_deltas 적용).
    inline fn effectiveRefCount(self: MinifyCtx, sid: u32) u32 {
        const base = self.symbols[sid].reference_count;
        if (sid >= self.ref_deltas.len) return base;
        const delta = self.ref_deltas[sid];
        return if (delta >= base) 0 else base - delta;
    }
};

/// 따옴표를 포함한 문자열 리터럴을 string_table에 추가한다.
fn makeQuotedString(ast: *Ast, text: []const u8) ?Span {
    var buf: [256]u8 = undefined;
    if (text.len + 2 > buf.len) return null;
    buf[0] = '"';
    @memcpy(buf[1 .. 1 + text.len], text);
    buf[1 + text.len] = '"';
    return ast.addString(buf[0 .. text.len + 2]) catch null;
}

/// `(expr)` 래핑을 재귀적으로 벗겨 실제 노드를 반환.
/// parenthesized_expression는 semantic상 투명이므로 타입 판별/치환 전에 unwrap.
fn unwrapParens(ast: *const Ast, node: Node) Node {
    var cur = node;
    while (cur.tag == .parenthesized_expression) {
        const inner_ni: u32 = @intFromEnum(cur.data.unary.operand);
        if (inner_ni >= ast.nodes.items.len) break;
        cur = ast.nodes.items[inner_ni];
    }
    return cur;
}

/// 노드가 boolean primitive를 반환함이 정적으로 보장되는지 판별.
/// `!!x → x` / `x === true → x` 류 축약에서 operand 타입 가드로 사용한다.
/// 증명 못 하면 false — 축약을 거부해 semantic 보존 (#1577).
///
/// 참고:
///   - oxc: peephole/minimize_not_expression.rs — `value_type().is_boolean()`
///   - esbuild: js_ast_helpers.go — `KnownPrimitiveType() == PrimitiveBoolean`
///   - swc: compress/optimize/ops.rs — `get_type() == Known(Type::Bool)`
fn isGuaranteedBoolean(ast: *const Ast, node: Node) bool {
    const inner = unwrapParens(ast, node);
    return switch (inner.tag) {
        .boolean_literal => true,
        .unary_expression => blk: {
            const e = inner.data.extra;
            if (e + 1 >= ast.extra_data.items.len) break :blk false;
            const op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[e + 1])));
            break :blk switch (op) {
                .bang, .kw_delete => true,
                else => false,
            };
        },
        .binary_expression => blk: {
            const op: Kind = @enumFromInt(inner.data.binary.flags);
            break :blk switch (op) {
                .eq3, .neq2, .eq2, .neq, .l_angle, .r_angle, .lt_eq, .gt_eq, .kw_in, .kw_instanceof => true,
                else => false,
            };
        },
        else => false,
    };
}

/// fixed-point loop 반복 상한. oxc `PeepholeOptimizations::run_in_loop` 와 동일 값.
/// pathological AST 에서 무한 교환 (e.g. A↔B) 을 방지.
const max_fixpoint_iterations: u32 = 5;

/// 전체 노드 치환 + fixed-point 신호. fold / simplify 사이트가 반복적으로 쓰는 패턴.
inline fn replaceNode(ast: *Ast, idx: u32, new_node: Node, changed: *bool) void {
    ast.nodes.items[idx] = new_node;
    changed.* = true;
}

inline fn sourceSpanStart(node: Node) u32 {
    return node.span.start & ~ast_mod.Ast.STRING_TABLE_BIT;
}

/// AST minify 패스를 실행한다. ast를 in-place 수정.
/// `ctx` 에 semantic 정보가 있으면 dead store (unused declaration) 제거도 함께 수행.
///
/// **Fixed-point loop** (#1650): constant fold → simplify → dead store 가 서로의 제거
/// 기회를 만들기 때문에 (`let y = 1 + 2; let x = y;` → 1 iter: fold + x dead, y.ref 감산
/// → 2 iter: y dead), `runOnce` 를 변경 없을 때까지 반복한다.
///
/// `root` 가 .none 이 아니면 root 에서 도달 가능한 노드만 dead-store 제거 대상으로 삼는다.
/// transformer 가 `visitNode` 에서 매번 새 노드를 만들어 원본을 `ast.nodes` 에 orphan 으로
/// 남기는데, orphan 의 init 을 제거하면서 `decrementRefsInExpr` 가 살아있는 심볼의
/// `reference_count` 를 중복 감산해 live 선언까지 잘못 제거되는 문제를 막는다 (#번개 실측).
///
/// `scratch` 는 skip/live bitset 과 BFS 큐 전용 임시 allocator. 호출 종료 시 해제되는
/// ephemeral arena 를 권장한다 (예: bundler 의 emit_arena). `ast.allocator` (parse_arena)
/// 를 넘기면 watch 모드 rebuild 마다 버퍼가 모듈 수명 동안 누적되므로 피할 것.
pub fn minify(ast: *Ast, ctx_in: MinifyCtx, scratch: std.mem.Allocator, root: NodeIndex) void {
    var ctx = ctx_in;
    // per-emit ref delta 배열: dead-store 가 `symbols.reference_count` 를 직접
    // 감산하던 경로를 대체. semantic 이 `PersistentModuleStore` 에 캐시되어 rebuild
    // 마다 누적 감산되던 live 선언 오제거 (#번개 실측: react-devtools-core 의
    // `operatorResMap` 이 2회차 rebuild 에서 사라짐) 를 방지한다. 호출자가
    // 이미 ref_deltas 를 제공하면 재사용.
    var owned_deltas: ?[]u32 = null;
    defer if (owned_deltas) |d| scratch.free(d);
    if (ctx.hasSemantic() and ctx.ref_deltas.len == 0) {
        if (scratch.alloc(u32, ctx.symbols.len)) |buf| {
            @memset(buf, 0);
            owned_deltas = buf;
            ctx.ref_deltas = buf;
        } else |_| {
            // OOM — ref_deltas 없이 진행 (기존 동작: ctx.symbols 바로 읽음).
            // symbols 는 const slice 이므로 여기서 쓸 수 없어 decrement 는 noop 된다.
        }
    }

    // for-loop binding 은 fold passes 가 새로 만들지 않아 iter-invariant — 미리 1회만 수집.
    var skip_for_binding: ?std.DynamicBitSet = null;
    defer if (skip_for_binding) |*b| b.deinit();
    if (ctx.hasSemantic()) {
        skip_for_binding = std.DynamicBitSet.initEmpty(scratch, ast.nodes.items.len) catch null;
        if (skip_for_binding) |*b| markForLoopBindings(ast, b);
    }

    // call-callee 자리에 있는 sequence 는 fold pass 들이 새로 만들지 않으므로 미리 1회만 수집.
    // 새로 append 된 노드는 capacity 밖이라 isSet 호출 시 false 처리되어 안전하다.
    var protected_sequences: ?std.DynamicBitSet = std.DynamicBitSet.initEmpty(scratch, ast.nodes.items.len) catch null;
    defer if (protected_sequences) |*b| b.deinit();
    if (protected_sequences) |*b| markCallCalleeSequences(ast, b);

    // live reachable set + BFS 큐: iter 간 재사용하여 watch 모드 누적 할당 회피.
    // fold pass 들이 var_declaration 을 새로 만들지 않고 paren/empty_statement 만 추가하므로
    // dead-store 탐지 대상은 기존 노드 인덱스로 충분하지만, ast.nodes.items.len 이 커지면
    // 리사이즈가 필요하므로 매 iter 재확인한다.
    var live_nodes: ?std.DynamicBitSet = null;
    defer if (live_nodes) |*b| b.deinit();
    var bfs_queue: std.ArrayList(NodeIndex) = .empty;
    defer bfs_queue.deinit(scratch);
    if (ctx.hasSemantic() and !root.isNone()) {
        live_nodes = std.DynamicBitSet.initEmpty(scratch, ast.nodes.items.len) catch null;
    }

    var i: u32 = 0;
    while (i < max_fixpoint_iterations) : (i += 1) {
        const skip_ptr: ?*const std.DynamicBitSet = if (skip_for_binding) |*b| b else null;
        const protected_ptr: ?*const std.DynamicBitSet = if (protected_sequences) |*b| b else null;
        const live_ptr: ?*const std.DynamicBitSet = if (live_nodes) |*b| blk: {
            // 매 iter live set 을 재계산 — fold pass 가 노드 tag 를 바꾸면 도달 가능성이 변한다.
            // capacity 가 부족하면 resize. DynamicBitSet.resize 가 존재해 재할당 없이 확장 가능.
            if (b.capacity() < ast.nodes.items.len) {
                b.resize(ast.nodes.items.len, false) catch break :blk null;
            } else {
                clearBitSet(b);
            }
            markReachableNodes(ast, root, b, &bfs_queue, scratch);
            break :blk b;
        } else null;
        if (!runOnce(ast, ctx, skip_ptr, live_ptr, protected_ptr, scratch)) break;
    }
}

fn clearBitSet(b: *std.DynamicBitSet) void {
    const len = b.capacity();
    if (len > 0) b.setRangeValue(.{ .start = 0, .end = len }, false);
}

/// minify 1 iteration. 변경이 있었으면 true 반환 (fixed-point 종료 판정용).
/// `changed` 는 보수적 true 허용 — 실제 mutation 없이 true 설정해도 최악 1 iter 더 돌고 끝.
///
/// **Index-based loop**: rewrite 중 `ast.nodes.append` (e.g. paren 노드 생성) 로
/// items slice 가 재할당되어도 안전 — 매 iter `ast.nodes.items[i]` 재슬라이스.
/// 새로 append 된 노드는 `items.len` 증가로 자동 순회됨.
fn runOnce(
    ast: *Ast,
    ctx: MinifyCtx,
    skip_for_binding: ?*const std.DynamicBitSet,
    live_nodes: ?*const std.DynamicBitSet,
    protected_sequences: ?*const std.DynamicBitSet,
    scratch: std.mem.Allocator,
) bool {
    var changed = false;
    var i: u32 = 0;
    while (i < ast.nodes.items.len) : (i += 1) {
        if (!isLiveMinifyNode(live_nodes, i)) continue;
        const node = ast.nodes.items[i];
        switch (node.tag) {
            .binary_expression => foldBinary(ast, scratch, i, node, &changed),
            .logical_expression => {
                if (!foldNullishCheck(ast, ctx, i, node, &changed))
                    foldLogical(ast, ctx, i, node, &changed);
            },
            .unary_expression => foldUnary(ast, i, node, &changed),
            .call_expression => foldCall(ast, i, node, &changed),
            .conditional_expression => foldConditional(ast, ctx, i, node, &changed),
            .if_statement => foldIf(ast, ctx, i, node, &changed),
            .while_statement => foldWhile(ast, ctx, i, node, &changed),
            .sequence_expression => {
                // bitset alloc 실패 시 보수적으로 모든 sequence 를 protected 로 — `(0,eval)()` 같은
                // callee 자리 sequence 를 잘못 unwrap 해서 indirect→direct eval 로 의미 바꾸느니
                // simplification 을 통째로 건너뛴다.
                const is_protected = if (protected_sequences) |set| i < set.capacity() and set.isSet(i) else true;
                if (!is_protected) unused_expr.simplifySequence(ast, ctx, i, node, &changed);
            },
            // PR1.5 (a): unused expression statement 축약 — semantic 정보 있을 때만
            // (symbol_ids 가 없으면 identifier local binding 판정 불가)
            .expression_statement => if (ctx.hasSemantic()) unused_expr.simplifyUnusedExprStmt(ast, ctx, i, node, &changed),
            // function expression 의 name 이 self-reference 안 쓰면 elide. function expression
            // 의 name binding 은 *그 함수 body 안에서만* visible (spec) — reference_count == 0
            // 이면 name 안전하게 anonymous. mobx 같은 ES5 class transpile 패턴 큰 영향.
            // debug/stack-trace 식별성을 깨므로 minify_syntax 일 때만 적용 (line 596/753 패턴).
            .function_expression => {
                if (ctx.hasSemantic() and ctx.allow_top_level_inline) elideUnusedFnExprName(ast, ctx, node, &changed);
                if (ctx.allow_top_level_inline) elideTrailingEmptyReturn(ast, node, &changed);
            },
            // 함수 body 마지막 `return;` (no operand) → empty_statement. implicit return undefined
            // 와 동등. minify_whitespace 가 empty 자동 elide. arrow body 도 block 일 때만 적용
            // (concise body 는 expression — functionBodyBlock 가 block 만 반환해 자동 skip).
            .function_declaration, .function, .arrow_function_expression, .method_definition => if (ctx.allow_top_level_inline) elideTrailingEmptyReturn(ast, node, &changed),
            else => {},
        }
    }
    if (ctx.hasSemantic()) {
        // 순서 고정 (#1631): inlineSingleUse → inlineTopLevelPrimitiveConstants.
        // 뒤집으면 multi-use inline 이 ref_count 를 0 으로 떨궈 single-use declaration 이
        // 잔존 (e.g. `const kn="["; const out=\`<!--${kn}-->\`;` → `const e="["` 잔존).
        inlineSingleUse(ast, ctx, skip_for_binding, live_nodes, &changed, scratch);
        inlineTopLevelPrimitiveConstants(ast, ctx, live_nodes, &changed, scratch);
        removeDeadStores(ast, ctx, skip_for_binding, live_nodes, &changed, scratch);
    }
    return changed;
}

fn isLiveMinifyNode(live_nodes: ?*const std.DynamicBitSet, node_idx: u32) bool {
    const lives = live_nodes orelse return true;
    return node_idx < lives.capacity() and lives.isSet(node_idx);
}

fn markCallCalleeSequences(ast: *const Ast, protected_sequences: *std.DynamicBitSet) void {
    for (ast.nodes.items) |node| {
        if (node.tag != .call_expression and node.tag != .new_expression) continue;
        markSequenceInCallee(ast, @enumFromInt(ast.readExtra(node.data.extra, 0)), protected_sequences);
    }
}

fn markSequenceInCallee(ast: *const Ast, idx: NodeIndex, protected_sequences: *std.DynamicBitSet) void {
    if (idx.isNone()) return;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len or ni >= protected_sequences.capacity()) return;
    const node = ast.nodes.items[ni];
    switch (node.tag) {
        .sequence_expression => protected_sequences.set(ni),
        .parenthesized_expression => markSequenceInCallee(ast, node.data.unary.operand, protected_sequences),
        else => {},
    }
}

/// root 에서 BFS 로 도달 가능한 노드 인덱스를 `live` 에 표시. `queue` 는 호출자가 재사용.
/// transformer 가 orphan 으로 남긴 노드는 `live` 밖이라 dead-store 제거 대상에서 제외된다.
fn markReachableNodes(ast: *const Ast, root: NodeIndex, live: *std.DynamicBitSet, queue: *std.ArrayList(NodeIndex), scratch: std.mem.Allocator) void {
    if (root.isNone()) return;
    queue.clearRetainingCapacity();
    queue.append(scratch, root) catch return;

    while (queue.items.len > 0) {
        const current = queue.pop() orelse break;
        const ni = @intFromEnum(current);
        if (ni >= live.capacity()) continue;
        if (live.isSet(ni)) continue;
        live.set(ni);

        if (ni >= ast.nodes.items.len) continue;
        const node = ast.nodes.items[ni];
        var it = ast_walk.children(ast, node);
        while (it.next()) |child| {
            if (child.isNone()) continue;
            queue.append(scratch, child) catch break;
        }
    }
}

// ================================================================
// Dead Store Elimination — Unused Declaration (#1644 PR1)
// ================================================================
//
// 제거 조건 (모두 만족):
//   - `var` / `let` / `const` 의 **단일** `binding_identifier` declarator
//   - symbol 의 `scope_id != 0` (함수/블록 local 만) — top-level 은 tree-shaker 영역
//   - `reference_count == 0` and `write_count == 0`
//   - `is_exported` / `is_default_export` 둘 다 false
//   - source-authored init 이 없거나 `purity.isExprPure` 가 true
//
// 제외:
//   - top-level (module scope) 선언     — tree-shaker 가 커버, 중복 제거는 fixture 회귀
//   - `using` / `await using`           — `[Symbol.dispose]` 호출이 side-effect
//   - destructuring / non-identifier    — pattern 은 간접 getter 호출 가능
//   - declarator 2개 이상               — 부분 제거는 PR 범위 밖 (복잡도)
//   - synthetic no-init temp 선언       — transformer 가 나중에 만든 assignment ref 는
//                                        원본 semantic refcount 와 어긋날 수 있음
//   - init 이 불순                      — "강등" (→ expression_statement) 은 PR1.5
//
// 제거 시 init expression 내 모든 identifier_reference 의 `reference_count` 를
// 감산해 semantic scalar 와의 정합성을 유지한다 — fixed-point loop 의 다음 iter 가
// 연쇄 dead 탐지를 위해 정확한 ref_count 를 필요로 한다.

/// `skip_for_binding` 은 `minify` 가 1회 수집해 모든 iter 에 공유 — fold passes 가
/// for-loop 을 새로 만들지 않아 재계산 불필요. null 이면 (OOM) 보수적으로 전부 skip.
///
/// `live_nodes` 가 주어지면 root 에서 도달 가능한 var_declaration 만 처리한다.
/// orphan (transformer 가 visit 중 복제하고 root 에서 연결 안 한 원본) 을 건드리면
/// `decrementRefsInExpr` 가 공유 symbol table 의 refcount 를 중복 감산해 live 선언이
/// 잘못 dead 판정된다.
fn removeDeadStores(ast: *Ast, ctx: MinifyCtx, skip_for_binding: ?*const std.DynamicBitSet, live_nodes: ?*const std.DynamicBitSet, changed: *bool, scratch: std.mem.Allocator) void {
    const skip = skip_for_binding orelse return;

    // inline 패스가 rewrite 하지 않는 shorthand object property key(=value) 위치에
    // 라이브 ref 를 가진 symbol 집합 (#3559). 이 symbol 들은 effectiveRefCount 가 0 으로
    // 보여도 — ref_deltas 누적과 base count 불일치로 — 실제로는 emit 되는 ref 가 살아
    // 있으므로 dead 제거에서 보호한다. 패스당 1회 O(n) 선계산 (per-decl O(n²) 회피).
    var shorthand_ref_syms = std.DynamicBitSet.initEmpty(scratch, ctx.symbols.len) catch {
        // OOM: 보수적으로 dead-store pass 자체를 skip (잘못된 제거보다 안전).
        return;
    };
    defer shorthand_ref_syms.deinit();
    for (ast.nodes.items) |node| {
        if (node.tag != .object_property) continue;
        if (!node.data.binary.right.isNone()) continue; // shorthand 만
        const key_ni = @intFromEnum(node.data.binary.left);
        if (key_ni >= ast.nodes.items.len) continue;
        if (ast.nodes.items[key_ni].tag != .identifier_reference) continue;
        if (!isLiveMinifyNode(live_nodes, @intCast(key_ni))) continue;
        if (key_ni >= ctx.symbol_ids.len) continue;
        const sid = ctx.symbol_ids[key_ni] orelse continue;
        if (sid < shorthand_ref_syms.capacity()) shorthand_ref_syms.set(sid);
    }

    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .variable_declaration) continue;
        if (skip.isSet(i)) continue;
        if (!isLiveMinifyNode(live_nodes, @intCast(i))) continue;
        tryRemoveDeadDecl(ast, ctx, @intCast(i), node, changed, &shorthand_ref_syms);
    }
}

/// for-loop (for / for-in / for-of / for-await-of) 의 init/left 자리에 있는
/// variable_declaration 노드 인덱스를 bitset 에 set. 해당 binding 은 body 에서
/// 사용되지 않더라도 구문상 필수이므로 dead store 제거 대상이 아니다.
fn markForLoopBindings(ast: *const Ast, skip: *std.DynamicBitSet) void {
    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .for_statement => {
                // extra = [init, test, update, body] — init 이 자식 0
                const ei = node.data.extra;
                if (ei >= ast.extra_data.items.len) continue;
                const raw = ast.extra_data.items[ei];
                if (raw < ast.nodes.items.len and
                    ast.nodes.items[raw].tag == .variable_declaration)
                {
                    skip.set(raw);
                }
            },
            .for_in_statement, .for_of_statement, .for_await_of_statement => {
                // ternary: a = LHS (variable_declaration 또는 assignment target)
                const raw = @intFromEnum(node.data.ternary.a);
                if (raw < ast.nodes.items.len and
                    ast.nodes.items[raw].tag == .variable_declaration)
                {
                    skip.set(raw);
                }
            },
            else => {},
        }
    }
}

fn tryRemoveDeadDecl(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool, shorthand_ref_syms: *const std.DynamicBitSet) void {
    const kind = ast.variableDeclarationKind(node);
    // `using` / `await using`: Symbol.dispose 호출 side-effect → 보존
    if (kind.isUsing()) return;

    const extra = node.data.extra;
    if (extra + 2 >= ast.extra_data.items.len) return;
    const list_start = ast.extra_data.items[extra + 1];
    const list_len = ast.extra_data.items[extra + 2];
    // 단일 declarator 만 처리 (부분 제거는 PR 범위 밖)
    if (list_len != 1) return;
    if (list_start >= ast.extra_data.items.len) return;

    const decl_raw = ast.extra_data.items[list_start];
    if (decl_raw >= ast.nodes.items.len) return;
    const decl = ast.nodes.items[decl_raw];
    if (decl.tag != .variable_declarator) return;

    // variable_declarator: extra = [name, type_ann, init]
    const de = decl.data.extra;
    if (de + 2 >= ast.extra_data.items.len) return;
    const name_raw = ast.extra_data.items[de];
    const init_raw = ast.extra_data.items[de + 2];

    if (name_raw >= ast.nodes.items.len) return;
    const name_node = ast.nodes.items[name_raw];
    // 단일 binding_identifier 만 — destructuring/array/object pattern 제외
    if (name_node.tag != .binding_identifier) return;

    const init_idx: NodeIndex = @enumFromInt(init_raw);
    // Transformer-generated temp declarations (`var _a;`) use interned string-table
    // spans and are paired with assignment reads that may be introduced after the
    // original semantic pass. Dropping the declaration can turn valid downlevel
    // output into `_a = ...` ReferenceError in strict-mode wrappers.
    if (init_idx.isNone() and (name_node.data.string_ref.start & Ast.STRING_TABLE_BIT) != 0) return;

    // symbol_ids[name_node_idx] → symbol index
    if (name_raw >= ctx.symbol_ids.len) return;
    const sym_id = ctx.symbol_ids[name_raw] orelse return;
    if (sym_id >= ctx.symbols.len) return;
    const sym = ctx.symbols[sym_id];

    // top-level (module scope=0) 의 dead store 는 기본 보수 보호.
    // - transpile 단독 경로: cross-module ref 정보가 없어 외부 host 의 `import {x} from
    //   "./mod"` 가 깨질 수 있다 → 그대로 보존.
    // - bundle 경로 (`ctx.allow_top_level_dead == true`, emitter 가 tree-shaker active 일
    //   때 세팅): tree-shaker 가 cross-module ref 보존을 이미 보장한다. 같은 binding 이
    //   외부에서 쓰이면 `is_exported=true` 가드로 보호되고, 아니면 진짜 dead → elide 안전.
    //   N RFC (#3267) 의 mobx 4KB cascade-dead 회수 경로.
    const scope_idx = @intFromEnum(sym.scope_id);
    if (scope_idx == 0 and !ctx.allow_top_level_dead) {
        // audit: 다른 가드 (eval/with/exported/ref/purity) 통과한 candidate 의 size 추적.
        // bundle 모드 (allow_top_level_dead) 에선 진짜 elide 로 가니 여기 안 옴.
        if (debug_log.enabled(.dead_toplevel_audit)) {
            tryAuditDeadToplevel(ast, ctx, sym_id, sym, node, init_idx);
        }
        return;
    }

    // eval / with 스코프 안의 선언은 동적 lookup 대상이 될 수 있다. mangler 와 동일 보호
    // (Scope.blocksMangling — subtree_has_direct_eval / subtree_has_with).
    if (scope_idx < ctx.scopes.len and ctx.scopes[scope_idx].blocksMangling()) return;

    // exported binding 보호 — transpile 단독 경로는 tree-shaker 가 없어 직접 지키는 외엔 없다
    if (sym.isExported()) return;

    // reference 가 있거나 다른 곳에서 쓰이면 dead 아님.
    // ref_deltas 가 이번 emit 에서 감산된 양을 반영.
    if (ctx.effectiveRefCount(sym_id) != 0 or sym.write_count != 0) return;

    // shorthand object property `{ x }` 의 key(=value) 위치 identifier_reference 는
    // inline 패스가 의도적으로 rewrite 하지 않는다 (markForbiddenInlineSites — replace
    // 하면 `{[1,2,3]}` 같은 잘못된 구문). 그 ref 는 emit 에 그대로 살아남는데,
    // effectiveRefCount 는 base reference_count − ref_deltas 누적이라
    // inlineTopLevelPrimitiveConstants 가 다른(비-forbidden) ref 를 인라인하며 delta 를
    // 올리면 base 와 어긋나 0 으로 포화될 수 있다 (#3559). 그 상태로 선언을 제거하면
    // 살아있는 shorthand-key ref 가 dangling → `ReferenceError`.
    //
    // effectiveRefCount==0 은 어디까지나 휴리스틱이고, "실제로 살아있는 ref 가 있는가"
    // 가 권위 기준이다. inline 이 손대지 않는 forbidden(shorthand-key) ref 가 라이브로
    // 남아있으면 — count 가 0 으로 보여도 — 선언을 보존한다. 이 가드는 반드시
    // decrementRefsInExpr 앞에 둔다 — 뒤에서 bail 하면 보존된 init 의 ref 가 이미
    // 감산돼 동일 drift 를 한 단계 아래에서 재생산한다 (다른 보호 return 과 동일 위치).
    if (sym_id < shorthand_ref_syms.capacity() and shorthand_ref_syms.isSet(sym_id)) return;

    // init 이 있으면 purity 검사 — 불순하면 RHS 보존을 위해 (아직) 제거 불가
    if (!init_idx.isNone()) {
        if (!purity.isExprPure(ast, init_idx, ctx.unresolved_globals)) return;
        // init 내부의 pure identifier_reference 들의 reference_count 를 감산
        decrementRefsInExpr(ast, ctx, init_idx);
    }

    // variable_declaration 전체를 empty_statement 로 교체
    replaceNode(ast, node_idx, .{
        .tag = .empty_statement,
        .span = node.span,
        .data = .{ .none = 0 },
    }, changed);
}

/// N RFC (#3267) audit 누적기 — `dead_toplevel_audit` 활성 시 minify pass 동안
/// module-level dead candidate (다른 가드 통과 후 scope_idx==0 으로만 차단된 binding)
/// 의 개수 + span size 누적. 호출자가 빌드 종료 시 직접 dump 또는 외부 grep.
///
/// emit_arena 는 chunk 단위 thread pool 로 병렬 호출되므로 audit 카운터는 atomic.
/// `.monotonic` 으로 충분 — counter 의 정확한 합만 필요하고 다른 메모리 ordering 보장
/// 의존 없음. 비활성 시엔 increment 자체 호출 안 됨 (caller debug_log.enabled 가드).
var dead_toplevel_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var dead_toplevel_size: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

pub fn resetDeadToplevelAudit() void {
    dead_toplevel_count.store(0, .monotonic);
    dead_toplevel_size.store(0, .monotonic);
}

pub fn dumpDeadToplevelAudit() void {
    if (!debug_log.enabled(.dead_toplevel_audit)) return;
    debug_log.print(.dead_toplevel_audit, "module-level dead candidates: count={d} size={d}\n", .{
        dead_toplevel_count.load(.monotonic),
        dead_toplevel_size.load(.monotonic),
    });
}

fn tryAuditDeadToplevel(ast: *Ast, ctx: MinifyCtx, sym_id: u32, sym: symbol_mod.Symbol, node: Node, init_idx: NodeIndex) void {
    if (sym.isExported()) return;
    if (ctx.effectiveRefCount(sym_id) != 0 or sym.write_count != 0) return;
    if (!init_idx.isNone() and !purity.isExprPure(ast, init_idx, ctx.unresolved_globals)) return;
    const size = @as(usize, node.span.end) -| @as(usize, node.span.start);
    _ = dead_toplevel_count.fetchAdd(1, .monotonic);
    _ = dead_toplevel_size.fetchAdd(size, .monotonic);
    // per-binding dump — count+size 만으로는 어떤 declaration 인지 식별 불가.
    // root cause 분석 (mobx error message dict 류 / runtime helper 잔여 / TS-emit
    // temp 등 분류) 에 필요. `sym.nameText(ast.source)` 는 binding identifier span 을
    // 원본 source 에서 가져오므로 transform 후에도 정확. synthetic 심볼은 합성 이름 반환.
    const name = sym.nameText(ast.source);
    debug_log.print(.dead_toplevel_audit, "  - {s}  size={d}  span={d}..{d}\n", .{
        name,
        size,
        node.span.start,
        node.span.end,
    });
}

/// expression 안의 모든 `identifier_reference` 노드를 찾아, symbol_ids 로 symbol 을
/// 역매핑해 `reference_count` 를 1 감산한다. init expression 은 RHS 이므로
/// assignment_target_identifier 는 등장하지 않아 read 경로만 처리.
pub fn decrementRefsInExpr(ast: *const Ast, ctx: MinifyCtx, idx: NodeIndex) void {
    decrementRefsImpl(ast, ctx, idx, false);
}

/// `decrementRefsInExpr` 의 cascade 안전 variant — function/class declaration/expression
/// 의 body 는 walk 하지 않는다. `if (false) f();` 같은 dead branch 안 statement 의 ref 를
/// 감산해 cascade dead 를 발견할 때 쓰인다. branch 안에 `function foo() { return bar; }` 가
/// 있어도 그 함수가 *다른 곳* 에서 호출 가능하므로 body 안 `bar` 의 ref 는 보존해야 한다
/// — full walk 시 over-decrement → bar 가 사실은 살아있는데 dead 마크되어 회귀
/// (RN codegen snapshot 24 fail 확인 후 도입).
pub fn decrementRefsShallow(ast: *const Ast, ctx: MinifyCtx, idx: NodeIndex) void {
    decrementRefsImpl(ast, ctx, idx, true);
}

const DecrementRefsCtx = struct { mc: MinifyCtx, skip_fn_body: bool };

fn decrementRefsVisit(ctx: *DecrementRefsCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    if (node.tag == .identifier_reference) {
        const ni = @intFromEnum(idx);
        if (ni < ctx.mc.symbol_ids.len) {
            if (ctx.mc.symbol_ids[ni]) |sid| {
                if (sid < ctx.mc.ref_deltas.len and ctx.mc.effectiveRefCount(sid) > 0) {
                    ctx.mc.ref_deltas[sid] += 1;
                }
            }
        }
        return .skip_children; // identifier_reference 는 자식 없음
    }
    if (ctx.skip_fn_body) switch (node.tag) {
        // 함수/클래스 body 는 호출/인스턴스화 시점에 평가. dead branch 안에 함수
        // declaration 이 있어도 그 함수가 외부 ref 면 body 안 read 는 살아 있음.
        .function_declaration,
        .function_expression,
        .arrow_function_expression,
        .class_declaration,
        .class_expression,
        => return .skip_children,
        else => {},
    };
    return .descend;
}

fn decrementRefsImpl(ast: *const Ast, ctx: MinifyCtx, idx: NodeIndex, comptime skip_fn_body: bool) void {
    // 반복 순회(#4123): 깊은 좌결합 체인(`if(false) a+b+c+…`)의 dead branch 를 감산할 때
    // 재귀면 스택 오버플로우. OOM 시 일부 감산 누락 → 해당 심볼이 보수적으로 live 유지 → 출력 정상.
    var c = DecrementRefsCtx{ .mc = ctx, .skip_fn_body = skip_fn_body };
    ast_walk.walkPreorderIterative(ast.allocator, ast, idx, &c, decrementRefsVisit) catch {};
}

// ================================================================
// Single-use Identifier Inline (#1666 Phase 2+3)
// ================================================================
//
// 제거 조건 (모두 만족):
//   - `const` / `let` 선언, 단일 `binding_identifier` declarator (using/var 제외)
//   - `scope_id != 0` — top-level 은 tree-shaker 영역
//   - `reference_count == 1` and `write_count == 0`
//   - init 이 `isConstantExpr` — literal 또는 literal 만 담은 array/object (식별자
//     의존성 없음). mutable state 와 무관해 선언→read 사이 개입 write 가 결과를
//     바꿀 수 없으므로 adjacency 검사 불필요.
//   - init 이 purity.isExprPure (이중 안전망 — constant expr 은 자동 pure).
//   - `is_exported` / `is_default_export` 아님
//   - eval / with 스코프 아님
//
// 동작: 유일한 read 위치의 identifier_reference 노드를 init 노드의 내용으로 in-place
// 덮어쓴다 (같은 NodeIndex 유지, tag/span/data 교체 — init 의 자식은 extra_data 를
// 공유하므로 별도 복제 불필요). 선언 statement 는 empty_statement 로 교체.
//
// **Traversal-based** (esbuild `substituteSingleUseSymbolInExpr`, oxc
// `peephole/inline.rs` 방식). `ctx.references` 의 `node_index` 는 parser 시점
// 캡처라 transformer 의 copyNodeDirect 이후 orphan 이 되므로 **사용하지 않고**,
// live AST 를 직접 walk 해서 symbol_ids 로 read 위치를 찾는다.
//
// 일반 expression inline (식별자 포함 init) 은 이 PR 범위 밖 — 개입 write 의
// evaluate-order 안전성을 별도로 증명해야 함 (esbuild 의 sequence-rewrite).

pub fn markForbiddenInlineSites(ast: *const Ast, forbidden: *std.DynamicBitSet) void {
    for (ast.nodes.items) |node| {
        if (node.tag != .object_property) continue;
        if (!node.data.binary.right.isNone()) continue;
        const key_ni = @intFromEnum(node.data.binary.left);
        if (key_ni < forbidden.capacity()) forbidden.set(key_ni);
    }
}

/// 각 statement 의 root expression NodeIndex 를 set — `return X;` /
/// `X;` (expression_statement) / `var x = X;` (variable_declarator init).
/// pure compound inline 시 이 위치엔 paren wrap 불필요 — caller context 가
/// statement 라 precedence 무관.
pub fn markStatementRootExpressions(ast: *const Ast, roots: *std.DynamicBitSet) void {
    const cap = roots.capacity();
    for (ast.nodes.items) |node| switch (node.tag) {
        .return_statement, .expression_statement => {
            const operand_ni = @intFromEnum(node.data.unary.operand);
            if (operand_ni < cap) roots.set(operand_ni);
        },
        .variable_declarator => {
            const e = node.data.extra;
            if (e + 2 >= ast.extra_data.items.len) continue;
            const init_ni = ast.extra_data.items[e + 2];
            if (init_ni < cap) roots.set(init_ni);
        },
        else => {},
    };
}

fn isPrimitiveConstantExpr(ast: *const Ast, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return false;
    return switch (ast.nodes.items[ni].tag) {
        .numeric_literal, .string_literal, .boolean_literal, .null_literal => true,
        else => false,
    };
}

fn inlineTopLevelPrimitiveConstants(ast: *Ast, ctx: MinifyCtx, live_nodes: ?*const std.DynamicBitSet, changed: *bool, scratch: std.mem.Allocator) void {
    if (!ctx.allow_top_level_inline) return;
    if (!ctx.hasSemantic()) return;

    var forbidden = std.DynamicBitSet.initEmpty(scratch, ast.nodes.items.len) catch return;
    defer forbidden.deinit();
    markForbiddenInlineSites(ast, &forbidden);

    for (ast.nodes.items) |node| {
        if (node.tag != .variable_declaration) continue;
        const kind = ast.variableDeclarationKind(node);
        if (kind == .@"var" or kind.isUsing()) continue;

        const extra = node.data.extra;
        if (extra + 2 >= ast.extra_data.items.len) continue;
        const list_start = ast.extra_data.items[extra + 1];
        const list_len = ast.extra_data.items[extra + 2];
        if (list_start + list_len > ast.extra_data.items.len) continue;

        for (ast.extra_data.items[list_start .. list_start + list_len]) |decl_raw| {
            if (decl_raw >= ast.nodes.items.len) continue;
            const decl = ast.nodes.items[decl_raw];
            if (decl.tag != .variable_declarator) continue;
            const de = decl.data.extra;
            if (de + 2 >= ast.extra_data.items.len) continue;
            const name_raw = ast.extra_data.items[de];
            const init_raw = ast.extra_data.items[de + 2];
            if (name_raw >= ast.nodes.items.len) continue;
            if (ast.nodes.items[name_raw].tag != .binding_identifier) continue;
            if (name_raw >= ctx.symbol_ids.len) continue;
            const sym_id = ctx.symbol_ids[name_raw] orelse continue;
            if (sym_id >= ctx.symbols.len) continue;
            const sym = ctx.symbols[sym_id];
            if (@intFromEnum(sym.scope_id) != 0) continue;
            if (ctx.scopes.len > 0 and ctx.scopes[0].blocksMangling()) continue;
            if (sym.isExported()) continue;
            if (sym.write_count != 0) continue;

            const init_idx: NodeIndex = @enumFromInt(init_raw);
            if (!isPrimitiveConstantExpr(ast, init_idx)) continue;
            const init_ni = @intFromEnum(init_idx);
            if (init_ni >= ast.nodes.items.len) continue;
            const init_node = ast.nodes.items[init_ni];
            const decl_start = sourceSpanStart(node);

            for (ast.nodes.items, 0..) |read_node, read_i| {
                if (read_node.tag != .identifier_reference) continue;
                if (read_i >= ctx.symbol_ids.len) continue;
                if ((ctx.symbol_ids[read_i] orelse continue) != sym_id) continue;
                if (forbidden.isSet(read_i)) continue;
                if (!isLiveMinifyNode(live_nodes, @intCast(read_i))) continue;
                if (sourceSpanStart(read_node) <= decl_start) continue;
                ast.nodes.items[read_i] = .{
                    .tag = init_node.tag,
                    .span = init_node.span,
                    .data = init_node.data,
                };
                if (sym_id < ctx.ref_deltas.len and ctx.effectiveRefCount(sym_id) > 0) {
                    ctx.ref_deltas[sym_id] += 1;
                }
                changed.* = true;
            }
        }
    }
}

/// Phase 2+3 inline: constant-expr init 을 유일 read 에 inline.
fn inlineSingleUse(ast: *Ast, ctx: MinifyCtx, skip_for_binding: ?*const std.DynamicBitSet, live_nodes: ?*const std.DynamicBitSet, changed: *bool, scratch: std.mem.Allocator) void {
    if (!ctx.hasSemantic()) return;
    const skip = skip_for_binding orelse return;

    // Pre-pass: replace 시 구문 깨지는 NodeIndex 를 forbidden 으로 마킹.
    // 대표 케이스: shorthand object property `{ x }` — key(=value) 위치의
    // identifier_reference 를 다른 tag 로 덮어쓰면 codegen 이 `{[1,2,3]}` 같은
    // 잘못된 문법을 낸다. object_property 에서 right(value) 가 .none 인 경우
    // left(key) NodeIndex 를 금지 목록에 추가.
    var forbidden = std.DynamicBitSet.initEmpty(scratch, ast.nodes.items.len) catch return;
    defer forbidden.deinit();
    markForbiddenInlineSites(ast, &forbidden);

    // statement-root expression 위치 마킹 — `return X;` / `X;` (expression_statement)
    // / `var x = X;` (variable_declarator init) 의 root X. pure compound inline 시
    // 이 위치에 read 가 있으면 caller context 가 statement 라 precedence 무관
    // → paren wrap 불필요 (`return ((x+1)*2)-3` → `return (x+1)*2-3`).
    var stmt_roots = std.DynamicBitSet.initEmpty(scratch, ast.nodes.items.len) catch return;
    defer stmt_roots.deinit();
    markStatementRootExpressions(ast, &stmt_roots);

    // symbol 별 identifier_reference 등장 횟수 + 첫 등장 NodeIndex 를 스캔.
    // 오직 live 영역의 identifier_reference 만 집계한다 — transformer 가 남긴 orphan
    // 을 세면 ref_count 미스매치로 inline 이 어긋난다.
    const counts = scratch.alloc(u32, ctx.symbols.len) catch return;
    defer scratch.free(counts);
    const first_loc = scratch.alloc(u32, ctx.symbols.len) catch return;
    defer scratch.free(first_loc);
    @memset(counts, 0);
    @memset(first_loc, std.math.maxInt(u32));

    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .identifier_reference) continue;
        if (!isLiveMinifyNode(live_nodes, @intCast(i))) continue;
        if (i >= ctx.symbol_ids.len) continue;
        const sid = ctx.symbol_ids[i] orelse continue;
        if (sid >= counts.len) continue;
        // shorthand key 위치의 identifier_reference 는 "read" 로 세되 inline 대상
        // 으로는 쓰지 않는다 — replace 하면 syntax 깨짐. counts 는 증가시키고 (read 수
        // 일치 보장), first_loc 는 non-forbidden 위치만 기록.
        counts[sid] += 1;
        if (first_loc[sid] == std.math.maxInt(u32) and !forbidden.isSet(i)) first_loc[sid] = @intCast(i);
    }

    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .variable_declaration) continue;
        if (skip.isSet(i)) continue;
        if (!isLiveMinifyNode(live_nodes, @intCast(i))) continue;
        tryInlineDecl(ast, ctx, counts, first_loc, &stmt_roots, @intCast(i), node, changed);
    }
}

fn tryInlineDecl(ast: *Ast, ctx: MinifyCtx, counts: []const u32, first_loc: []const u32, stmt_roots: *const std.DynamicBitSet, decl_stmt_idx: u32, node: Node, changed: *bool) void {
    const kind = ast.variableDeclarationKind(node);
    if (kind.isUsing()) return;
    if (kind == .@"var") return;

    const extra = node.data.extra;
    if (extra + 2 >= ast.extra_data.items.len) return;
    const list_len = ast.extra_data.items[extra + 2];
    if (list_len != 1) return;
    const list_start = ast.extra_data.items[extra + 1];
    if (list_start >= ast.extra_data.items.len) return;

    const decl_raw = ast.extra_data.items[list_start];
    if (decl_raw >= ast.nodes.items.len) return;
    const decl = ast.nodes.items[decl_raw];
    if (decl.tag != .variable_declarator) return;

    const de = decl.data.extra;
    if (de + 2 >= ast.extra_data.items.len) return;
    const name_raw = ast.extra_data.items[de];
    const init_raw = ast.extra_data.items[de + 2];

    if (name_raw >= ast.nodes.items.len) return;
    const name_node = ast.nodes.items[name_raw];
    if (name_node.tag != .binding_identifier) return;

    if (name_raw >= ctx.symbol_ids.len) return;
    const sym_id = ctx.symbol_ids[name_raw] orelse return;
    if (sym_id >= ctx.symbols.len) return;
    const sym = ctx.symbols[sym_id];

    const scope_idx = @intFromEnum(sym.scope_id);
    if (scope_idx < ctx.scopes.len and ctx.scopes[scope_idx].blocksMangling()) return;
    if (scope_idx == 0 and !ctx.allow_top_level_inline) return;
    if (sym.isExported()) return;

    if (ctx.effectiveRefCount(sym_id) != 1 or sym.write_count != 0) return;

    const init_idx: NodeIndex = @enumFromInt(init_raw);
    if (init_idx.isNone()) return;
    const init_ni = @intFromEnum(init_idx);
    if (init_ni >= ast.nodes.items.len) return;
    const init_node = ast.nodes.items[init_ni];

    // inline 대상 세 종류:
    //   ① constant expr (mutable state 무관 → 위치 자유)
    //   ② **immutable binding alias** — `const x = foo;` 에서 `foo` 가 write_count==0
    //   ③ **pure compound expr** — `const x = a+1;` 처럼 binary/unary/conditional/
    //      member access 등. 안 의 모든 reference 가 immutable 이어야 ordering 안전.
    // ②/③ 는 read 가 declaration 과 **같은 scope** 일 때만 (아래 scope 검사) —
    // 다른 scope 로 ref 를 옮기면 mangle/shadow collision 위험.
    var alias_sym: ?u32 = null;
    var needs_scope_check = false;
    if (!isConstantExpr(ast, init_idx)) {
        if (ctx.symbol_ids_mut == null) return; // symbol_ids mutation 필요한 케이스
        if (init_node.tag == .identifier_reference) {
            if (init_ni >= ctx.symbol_ids.len) return;
            const s = ctx.symbol_ids[init_ni] orelse return;
            if (s == sym_id) return; // self-ref(`const x = x;`) 방어
            if (!isImmutableSymbol(ctx, s)) return;
            alias_sym = s;
        } else {
            // pure compound expression — 모든 내부 reference 의 referenced symbol 이
            // immutable(write_count==0) 이어야 inline 후 ordering 보존.
            if (!allInnerReferencesImmutable(ast, ctx, init_idx, sym_id)) return;
        }
        needs_scope_check = true;
    }
    if (!purity.isExprPure(ast, init_idx, ctx.unresolved_globals)) return;

    // 실측 identifier_reference 수 확인 — ref_deltas 를 감안한 ref_count 와 정확히 1 일치.
    if (sym_id >= counts.len) return;
    if (counts[sym_id] != 1) return;
    const read_ni = first_loc[sym_id];
    if (read_ni == std.math.maxInt(u32) or read_ni >= ast.nodes.items.len) return;

    // alias / pure compound inline: read 위치가 `x` 선언과 같은 scope 여야 안전 (위
    // 주석). read 의 scope 는 pre-minify `references` 에서 `node_index == read_ni` 인
    // 항목으로 조회 — transformer 가 노드를 copy 했으면 매칭 실패(orphan) → 안전
    // 보수적 skip.
    if (needs_scope_check) {
        var read_scope_ok = false;
        for (ctx.references) |r| {
            if (@intFromEnum(r.node_index) != read_ni) continue;
            if (@intFromEnum(r.symbol_id) != sym_id) continue;
            read_scope_ok = @intFromEnum(r.scope_id) == @intFromEnum(sym.scope_id);
            break;
        }
        if (!read_scope_ok) return;
    }
    // Forward-reference 검증 (#2195). read 가 declaration 이전이면 TDZ throw 대상이라
    // inline 금지 — `let x = 1; console.log(x)` 와 `console.log(x); let x = 1;` 의 의미가
    // 다름 (전자는 1, 후자는 ReferenceError). 이전엔 top-level 만 검증해 block-scoped
    // TDZ (try/if/{} 안 let) 의 semantic 이 깨졌었음.
    //
    // closure 안의 read 는 textually 이전이라도 *실행 시점* 이 declaration 이후라 TDZ
    // 위반 아님인데, 그래도 sourceSpan 비교만으로 conservative 하게 inline 거부 →
    // 안전 우선 (semantic-preserving).
    if (sourceSpanStart(ast.nodes.items[read_ni]) <= sourceSpanStart(node)) return;

    // in-place swap: read 위치의 identifier_reference 를 init 의 tag/data 로 덮어쓴다.
    // init 의 자식은 extra_data 공유 → codegen 은 read_ni 에서 init 전체를 출력.
    // span 은 init 의 것을 사용 (source map 에서 inlined 값의 위치 유지).
    //
    // pure compound expression 은 parenthesized_expression 으로 wrap — codegen 이
    // precedence-based paren 을 자동 추가하지 않으므로 `const a=x+1; b=a*2;` 가
    // `b=x+1*2` (잘못, `1*2` 먼저) 가 되는 회귀 방지. constant / alias 분기는 단일
    // 토큰이라 paren 불필요.
    const pure_compound = alias_sym == null and needs_scope_check;
    // statement-root 위치 (return/expression_statement/variable_declarator init) 면
    // caller context 가 statement 라 precedence 무관 → paren skip.
    const at_stmt_root = read_ni < stmt_roots.capacity() and stmt_roots.isSet(read_ni);
    if (pure_compound and !at_stmt_root) {
        ast.nodes.items[read_ni] = .{
            .tag = .parenthesized_expression,
            .span = init_node.span,
            .data = .{ .unary = .{ .operand = init_idx, .flags = 0 } },
        };
    } else {
        ast.nodes.items[read_ni] = .{
            .tag = init_node.tag,
            .span = init_node.span,
            .data = init_node.data,
        };
    }
    // alias inline: codegen/mangler 의 rename 조회가 symbol_id 기준이므로 read 위치의
    // symbol_id 를 `S` 로 갱신. ref count 는 불변 — init 의 `S`-ref 가 read 위치로 "이동"
    // 하고, decl 제거로 orphan 되는 init 노드가 `reference_count(S)` 를 balance.
    if (alias_sym) |s| {
        if (ctx.symbol_ids_mut) |sids| {
            if (read_ni < sids.len) sids[read_ni] = s;
        }
    }

    replaceNode(ast, decl_stmt_idx, .{
        .tag = .empty_statement,
        .span = node.span,
        .data = .{ .none = 0 },
    }, changed);
    if (sym_id < ctx.ref_deltas.len) ctx.ref_deltas[sym_id] += 1;
    changed.* = true;
}

/// 심볼이 어디서도 재할당되지 않는지 (`write_count == 0`). out-of-bounds
/// 보수적 false. alias inline / pure compound inline 양쪽에서 공유.
inline fn isImmutableSymbol(ctx: MinifyCtx, sid: u32) bool {
    return sid < ctx.symbols.len and ctx.symbols[sid].write_count == 0;
}

/// `idx` 안의 모든 identifier_reference 의 referenced symbol 이 immutable 인지
/// 재귀 판정. self-reference 도 거부 (decl_sym_id 와 같은 symbol → `const x = x;`
/// 같은 self-cycle 방어). unresolved global 또는 symbol_ids 미매핑이면 보수적
/// false.
///
/// pure compound expression inline 안전성 — `const a = x+1; b = a*2;` 에서
/// `x` 가 mutable 이면 inline 후 `b = (x+1)*2;` 의 `x` 평가 시점이 declaration
/// 위치에서 read 위치로 옮겨가 ordering 의미 변경 위험.
const ImmutableRefsCtx = struct { mc: MinifyCtx, decl_sym_id: u32, all_immutable: bool };

fn immutableRefsVisit(ctx: *ImmutableRefsCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    if (node.tag == .identifier_reference) {
        const ni = @intFromEnum(idx);
        // 원본과 동일: ni 범위 밖 / symbol_id 없음 / decl 자기참조 / mutable 심볼 → 즉시 false.
        const immutable = ni < ctx.mc.symbol_ids.len and blk: {
            const sid = ctx.mc.symbol_ids[ni] orelse break :blk false;
            if (sid == ctx.decl_sym_id) break :blk false;
            break :blk isImmutableSymbol(ctx.mc, sid);
        };
        if (!immutable) {
            ctx.all_immutable = false;
            return .stop;
        }
        return .skip_children; // identifier_reference 는 자식 없음
    }
    return .descend;
}

fn allInnerReferencesImmutable(
    ast: *const Ast,
    ctx: MinifyCtx,
    idx: NodeIndex,
    decl_sym_id: u32,
) bool {
    // 반복 순회(#4123): 단일-use inline 대상 init(`const x = a+b+c+…`)이 깊은 체인이면
    // 재귀 시 스택 오버플로우. OOM 시 보수적으로 false(=inline 안 함) 반환 → 출력 정상.
    var c = ImmutableRefsCtx{ .mc = ctx, .decl_sym_id = decl_sym_id, .all_immutable = true };
    ast_walk.walkPreorderIterative(ast.allocator, ast, idx, &c, immutableRefsVisit) catch return false;
    return c.all_immutable;
}

/// init 이 식별자 의존성 없는 constant expression 인지 판정.
/// - numeric / string / bigint / boolean / null / regexp literal
/// - template_literal (정적 — expression 슬롯 없음)
/// - array_expression / object_expression: 모든 원소/값이 재귀적으로 constant
///   (object_property 의 key 는 identifier/string/numeric/bigint 만 허용, computed/
///   shorthand 제외)
///
/// identifier_reference, this_expression, call_expression, binary/unary 등은 전부 false
/// 반환. 식별자 의존성이 있으면 "개입 write" 의 evaluate-order 안전성을 증명해야 하는데,
/// 그건 esbuild 의 substituteSingleUseSymbolInExpr sequence-rewrite 수준이라 본 PR
/// 범위 밖. 이 pass 는 mutable state 의존이 전혀 없는 constant-only subset 에 한정.
fn isConstantExpr(ast: *const Ast, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[ni];
    return switch (node.tag) {
        .numeric_literal,
        .string_literal,
        .bigint_literal,
        .boolean_literal,
        .null_literal,
        .regexp_literal,
        => true,
        // template_literal: no-substitution (`.{ .none = 0 }`) vs interpolated (`.list`)
        // 을 extern union 에서 런타임 구분할 안전한 수단이 없어 (data.list.len 읽으면
        // `.none` 에서 padding 읽기) 보수적으로 전부 skip. 실사용 impact 은 미미.
        .template_literal => false,
        .array_expression => blk: {
            const list = node.data.list;
            var j: u32 = 0;
            while (j < list.len) : (j += 1) {
                if (list.start + j >= ast.extra_data.items.len) break :blk false;
                const child_raw = ast.extra_data.items[list.start + j];
                const child_idx: NodeIndex = @enumFromInt(child_raw);
                if (child_idx.isNone()) continue; // elision NodeIndex.none
                const child_ni = @intFromEnum(child_idx);
                if (child_ni < ast.nodes.items.len and ast.nodes.items[child_ni].tag == .elision) continue;
                if (!isConstantExpr(ast, child_idx)) break :blk false;
            }
            break :blk true;
        },
        .object_expression => blk: {
            const list = node.data.list;
            var j: u32 = 0;
            while (j < list.len) : (j += 1) {
                if (list.start + j >= ast.extra_data.items.len) break :blk false;
                const prop_raw = ast.extra_data.items[list.start + j];
                if (prop_raw >= ast.nodes.items.len) break :blk false;
                const prop = ast.nodes.items[prop_raw];
                if (prop.tag != .object_property) break :blk false;
                // object_property: binary = { left: key, right: value }.
                const key_idx = prop.data.binary.left;
                const value_idx = prop.data.binary.right;
                const key_ni = @intFromEnum(key_idx);
                if (key_ni >= ast.nodes.items.len) break :blk false;
                const key_tag = ast.nodes.items[key_ni].tag;
                // 정적 key 만: identifier_reference (속성명 자체), string/numeric literal.
                // computed_property_key 는 expression 이 들어갈 수 있어 제외. 쇼트핸드 `{a}` 는
                // value 도 identifier_reference 라 value 검사에서 자연히 false.
                switch (key_tag) {
                    .identifier_reference, .string_literal, .numeric_literal, .bigint_literal => {},
                    else => break :blk false,
                }
                if (!isConstantExpr(ast, value_idx)) break :blk false;
            }
            break :blk true;
        },
        // 그 외 (identifier_reference, member_expression, call_expression, new_expression,
        // arrow_function_expression, function_expression, unary, binary, ...) 는 보수적
        // 으로 false. unary (!1) / binary (1+2) 등 constant fold 대상은 다른 pass 가
        // 이미 리터럴로 접었을 것.
        else => false,
    };
}

/// Top-level `const` / `let` 선언을 `var` 로 다운그레이드 (#1630).
///
/// **호출자 계약**: `scope_hoist = true` 일 때만 호출 — module top-level 이 IIFE / CJS wrap
/// 으로 function scope 에 통합되어 block-scope 의미가 function-scope 와 동일해진다.
/// 그 외엔 TDZ / block-scope hoisting 의미 변경 위험.
///
/// 범위: `program` 노드의 직속 statement 중 `variable_declaration` 의 kind 만 수정.
/// 함수/블록 내부는 건드리지 않음 (block scope 내 let/const 를 var 로 바꾸면 function scope
/// 로 hoist 되어 semantic 변경). for-loop init/left binding 은 각 iter 새 바인딩 특성을
/// 유지해야 하므로 `markForLoopBindings` 로 제외.
///
/// **merge 와 조합**: `mergeDecls` 직전에 호출하면 같은 kind(`.var`) 끼리 연쇄 merge —
/// svelte-mount-min 에서 `const 168개 → var` 전환 후 단일 `var a=1,b=2,...` 로 압축.
pub fn downgradeToVar(ast: *Ast) void {
    // program 노드 찾기 (codegen 이 쓰는 최종 program)
    var prog_idx: ?u32 = null;
    for (ast.nodes.items, 0..) |n, i| {
        if (n.tag == .program) prog_idx = @intCast(i);
    }
    const prog_ni = prog_idx orelse return;
    const prog = ast.nodes.items[prog_ni];
    const list = prog.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;

    // for-loop binding 은 각 iter 새 바인딩 의미 → downgrade 금지.
    var skip_for_binding = std.DynamicBitSet.initEmpty(ast.allocator, ast.nodes.items.len) catch return;
    defer skip_for_binding.deinit();
    markForLoopBindings(ast, &skip_for_binding);

    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
        if (raw >= ast.nodes.items.len) continue;
        if (skip_for_binding.isSet(raw)) continue;
        const stmt = ast.nodes.items[raw];
        if (stmt.tag != .variable_declaration) continue;

        const kind = ast.variableDeclarationKind(stmt);
        // var / using / await_using 은 유지 — using 은 dispose semantic, var 는 이미 target.
        if (kind != .let and kind != .@"const") continue;

        const e = stmt.data.extra;
        if (e >= ast.extra_data.items.len) continue;
        ast.setVariableDeclarationKind(stmt, .@"var");
    }
}

/// `const` → `let` 으로 변환 (전체 AST 순회).
///
/// **호출자 계약**: minify_syntax 모드에서만 호출 + `mergeDecls` 직전. *재할당 의미 변경*
/// (TypeError → silent) 을 허용하므로 minify-only 파이프라인 외에선 호출 금지.
/// for-loop init / for-of/for-in left binding 의 const 도 let 으로 변환해 동일 (각 iter
/// 새 binding 의미 유지). esbuild/rolldown/rspack/terser 동일.
///
/// **목적**: `mergeDecls` 가 *동일 kind* 만 merge — `const a=1; let b=2; const c=3;` 같은
/// *섞인 시퀀스* 는 *3 declaration* 으로 남는다. const → let 통일 후 `let a=1,b=2,c=3;`
/// 로 합쳐져 *2 declaration + 2 byte* 절감.
pub fn convertConstToLet(ast: *Ast) void {
    for (ast.nodes.items) |stmt| {
        if (stmt.tag != .variable_declaration) continue;
        const e = stmt.data.extra;
        if (e >= ast.extra_data.items.len) continue;
        if (ast.extra_data.items[e] == @intFromEnum(VariableDeclarationKind.@"const")) {
            ast.setVariableDeclarationKind(stmt, .let);
        }
    }
}

/// 인접한 같은-kind `var`/`let`/`const` 선언을 단일 선언으로 병합한다 (#1588).
///
/// 반드시 tree-shaking **이후**에 호출해야 한다. 번들러는 `var A=1; var B=2;`에서
/// `B`만 tree-shake로 skip_nodes에 마킹하는데, merge가 이를 무시하면 B가 A와 합쳐져
/// tree-shaker가 단일 statement를 제거하지 못해 미사용 declarator가 최종 출력에 남는다.
/// `skip_nodes`가 주어지면 마킹된 statement는 merge 대상에서 제외해 tree-shaker 효과를 보존한다.
pub fn mergeDecls(ast: *Ast, skip_nodes: ?*const std.DynamicBitSet) void {
    for (ast.nodes.items, 0..) |node, i| {
        switch (node.tag) {
            .program, .block_statement, .function_body => mergeAdjacentDecls(ast, @intCast(i), node, skip_nodes),
            else => {},
        }
    }
}

// ================================================================
// Constant Folding — Binary Expression
// ================================================================

/// 함수 body 마지막 `return;` (operand 없음) 을 `empty_statement` 로 변환.
/// implicit `return undefined` 와 의미 동등 — 함수 끝 자연 도달 시 undefined 반환.
/// emit 시 minify_whitespace 가 empty_statement 자동 elide → ~7 byte 절감.
/// arrow function 의 concise body (expression) 는 functionBodyBlock 가 block 만 반환해 자동 skip.
fn elideTrailingEmptyReturn(ast: *Ast, node: Node, changed: *bool) void {
    const body_idx = ast.functionBodyBlock(node) orelse return;
    const body_ni = @intFromEnum(body_idx);
    if (body_ni >= ast.nodes.items.len) return;
    const body = ast.nodes.items[body_ni];
    if (body.tag != .block_statement) return;
    const list = body.data.list;
    if (list.len == 0) return;
    if (list.start + list.len > ast.extra_data.items.len) return;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    var last_raw: u32 = 0;
    var found = false;
    var k: usize = indices.len;
    while (k > 0) {
        k -= 1;
        const raw = indices[k];
        if (raw >= ast.nodes.items.len) continue;
        if (ast.nodes.items[raw].tag == .empty_statement) continue;
        last_raw = raw;
        found = true;
        break;
    }
    if (!found) return;
    const last_node = ast.nodes.items[last_raw];
    if (last_node.tag != .return_statement) return;
    if (!last_node.data.unary.operand.isNone()) return;
    ast.nodes.items[last_raw] = .{
        .tag = .empty_statement,
        .span = last_node.span,
        .data = .{ .none = 0 },
    };
    changed.* = true;
}

/// function expression 의 name 이 self-reference 안 쓰이면 elide (anonymous 화).
/// `function Name() {...}` (expression context, e.g. `prototype.method = function Name() {}`)
/// 의 Name 은 spec 상 *그 함수 body 안에서만* visible — reference_count == 0 이면
/// 외부에서 안 보이고 self-ref 도 없음. AST mutate (extra[0] → NodeIndex.none).
/// mobx 같은 ES5 transpile class 패턴 큰 영향 (모든 prototype method 의 name elide).
fn elideUnusedFnExprName(ast: *Ast, ctx: MinifyCtx, node: Node, changed: *bool) void {
    const e = node.data.extra;
    if (e + 4 > ast.extra_data.items.len) return;
    const name_raw = ast.extra_data.items[e];
    const name_idx: NodeIndex = @enumFromInt(name_raw);
    if (name_idx.isNone()) return;
    const name_ni = @intFromEnum(name_idx);
    if (name_ni >= ctx.symbol_ids.len) return;
    const sym_id = ctx.symbol_ids[name_ni] orelse return;
    if (sym_id >= ctx.symbols.len) return;
    if (ctx.symbols[sym_id].reference_count != 0) return;
    ast.extra_data.items[e] = @intFromEnum(NodeIndex.none);
    changed.* = true;
}

fn foldBinary(ast: *Ast, allocator: std.mem.Allocator, node_idx: u32, node: Node, changed: *bool) void {
    const left_ni = @intFromEnum(node.data.binary.left);
    const right_ni = @intFromEnum(node.data.binary.right);
    if (left_ni >= ast.nodes.items.len or right_ni >= ast.nodes.items.len) return;

    const left = ast.nodes.items[left_ni];
    const right = ast.nodes.items[right_ni];
    const op: Kind = @enumFromInt(node.data.binary.flags);

    // 비교 연산 (산술보다 먼저 — 숫자 === 숫자도 여기서 처리)
    if (op == .eq3 or op == .neq2) {
        // typeof X === "undefined" → typeof X > "u", typeof X !== "undefined" → typeof X < "u".
        // esbuild/rolldown 표준 minify trick. transformer 의 clone 패턴 (binary deep clone, leaf
        // string_literal share) 때문에 같은 right_ni 를 갖는 binary 가 여러 개 (orphan + clone)
        // 존재 — `foldTypeofUndefinedComparison` 내부에서 *원본* 과 *이미 short 된 상태* 둘 다
        // 매치해 모든 share binary 의 flags 가 일관되게 갱신된다.
        if (foldTypeofUndefinedComparison(ast, node_idx, left, right, right_ni, op)) {
            changed.* = true;
            return;
        }
        // typeof X === "string-literal" → `==`, `!==` → `!=` (per-occurrence 1B 절감).
        // typeof 결과는 항상 string 이므로 양쪽 type 보장 → `==` 의 type coercion 안전.
        if (foldTypeofStringComparison(ast, node_idx, left, right, op)) {
            changed.* = true;
            return;
        }
        // x === true → x, x === false → !x (한쪽만 boolean이면 축약)
        if (simplifyBooleanComparison(ast, node_idx, left, right, left_ni, right_ni, op)) {
            changed.* = true;
            return;
        }

        if (foldStrictEquality(ast, allocator, left, right)) |result| {
            const value = if (op == .neq2) !result else result;
            const text = if (value) "true" else "false";
            if (ast.addString(text)) |span| {
                replaceNode(ast, node_idx, .{
                    .tag = .boolean_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                }, changed);
            } else |_| {}
        }
        return;
    }

    // 숫자 산술
    if (left.tag == .numeric_literal and right.tag == .numeric_literal) {
        if (numeric.foldBinary(ast, left, right, op)) |result| {
            if (numeric.formatNumber(ast, result)) |new_span| {
                const orig_len = (node.span.end & ~ast_mod.Ast.STRING_TABLE_BIT) -| (node.span.start & ~ast_mod.Ast.STRING_TABLE_BIT);
                const new_len = (new_span.end & ~ast_mod.Ast.STRING_TABLE_BIT) -| (new_span.start & ~ast_mod.Ast.STRING_TABLE_BIT);
                if (new_len <= orig_len) {
                    replaceNode(ast, node_idx, .{
                        .tag = .numeric_literal,
                        .span = new_span,
                        .data = .{ .none = 0 },
                    }, changed);
                }
            }
        }
        return;
    }

    // 문자열 연결 (+ 연산자만)
    if (left.tag == .string_literal and right.tag == .string_literal and op == .plus) {
        foldStringConcat(ast, node_idx, left, right, changed);
        return;
    }
}

pub fn foldNumericLiteralExpression(ast: *Ast, root: NodeIndex) ?Span {
    return numeric.foldLiteralExpression(ast, root);
}

/// `typeof X === "undefined"` → `typeof X > "u"`, `typeof X !== "undefined"` → `typeof X < "u"`.
/// `typeof` 결과 8 종 중 `"undefined"` 만 lexicographically `> "u"` 이고 나머지
/// (bigint/boolean/function/number/object/string/symbol) 모두 `< "u"`. 의미 동등 +
/// per-occurrence 8 byte 절감.
///
/// transformer 가 binary 를 deep clone 하지만 leaf string_literal 은 share — 같은 right_ni 를
/// 갖는 binary 가 여러 개 (orphan + clone) 존재. 첫 fold 가 string 을 `"u"` 로 변경하면 후속
/// binary fold 시 right_text 가 이미 short. 따라서 *원본 ("undefined", len 11)* 과 *이미
/// short 된 상태 ("u", len 3)* 두 형태 모두 매치해 flags 만 갱신 (string 은 첫 fold 시만 변경).
/// 이게 없으면 emit 가 사용하는 clone binary 의 flags 가 안 바뀌어 operator 변경이 보이지 않음.
fn foldTypeofUndefinedComparison(
    ast: *Ast,
    node_idx: u32,
    left: Node,
    right: Node,
    right_ni: u32,
    op: Kind,
) bool {
    if (left.tag != .unary_expression) return false;
    const left_e = left.data.extra;
    if (left_e + 1 >= ast.extra_data.items.len) return false;
    const left_op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[left_e + 1])));
    if (left_op != .kw_typeof) return false;

    if (right.tag != .string_literal) return false;
    const rt = ast.getText(right.span);
    const is_undef = rt.len == 11 and (rt[0] == '"' or rt[0] == '\'') and std.mem.eql(u8, rt[1..10], "undefined");
    const is_short = rt.len == 3 and (rt[0] == '"' or rt[0] == '\'') and rt[1] == 'u' and rt[2] == rt[0];
    if (!is_undef and !is_short) return false;

    const new_op: Kind = if (op == .neq2) .l_angle else .r_angle;
    ast.nodes.items[node_idx].data.binary.flags = @intFromEnum(new_op);
    if (is_undef) {
        const new_text: []const u8 = if (rt[0] == '"') "\"u\"" else "'u'";
        const new_span = ast.addString(new_text) catch return true;
        ast.nodes.items[right_ni].span = new_span;
    }
    return true;
}

/// `typeof X === "literal"` → `typeof X == "literal"`, `typeof X !== "literal"` → `typeof X != "literal"`.
/// `typeof` 결과는 항상 string 이므로 right 가 string literal 이면 양쪽 type 보장 — `===`/`!==`
/// 의 strict 검사가 `==`/`!=` 의 abstract 검사와 동일 결과 (type coercion 안 일어남).
/// per-occurrence 1 byte 절감. operator 만 변경 — leaf node 무관, share binary 모두 자연 갱신.
fn foldTypeofStringComparison(
    ast: *Ast,
    node_idx: u32,
    left: Node,
    right: Node,
    op: Kind,
) bool {
    if (left.tag != .unary_expression) return false;
    const left_e = left.data.extra;
    if (left_e + 1 >= ast.extra_data.items.len) return false;
    const left_op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[left_e + 1])));
    if (left_op != .kw_typeof) return false;
    if (right.tag != .string_literal) return false;
    const new_op: Kind = if (op == .neq2) .neq else .eq2;
    ast.nodes.items[node_idx].data.binary.flags = @intFromEnum(new_op);
    return true;
}

fn foldStringConcat(ast: *Ast, node_idx: u32, left: Node, right: Node, changed: *bool) void {
    const left_text = ast.getText(left.span);
    const right_text = ast.getText(right.span);

    // escape 규칙이 동일한 경우만 concat — 양쪽 모두 같은 quote char(`"` / `'` / backtick)여야.
    // 다른 quote를 합치면 내부 escape 변환 필요(예: `'..."x"...'`를 double quote로 재포장하면
    // `"`를 `\"`로 바꿔야 hermesc 같은 엄격 파서 통과). 재escape 비용 대신 fold 포기가 안전.
    // 같은 quote끼리는 내부 텍스트가 이미 해당 quote에 대해 escape 되어 있어 그대로 합쳐도 OK.
    const lq = detectQuote(left_text) orelse return;
    const rq = detectQuote(right_text) orelse return;
    if (lq != rq) return;

    const a = left_text[1 .. left_text.len - 1];
    const b = right_text[1 .. right_text.len - 1];

    var buf: [4096]u8 = undefined;
    if (a.len + b.len + 2 > buf.len) return;
    buf[0] = lq;
    @memcpy(buf[1 .. 1 + a.len], a);
    @memcpy(buf[1 + a.len .. 1 + a.len + b.len], b);
    buf[1 + a.len + b.len] = lq;
    const total = 2 + a.len + b.len;

    const span = ast.addString(buf[0..total]) catch return;
    replaceNode(ast, node_idx, .{
        .tag = .string_literal,
        .span = span,
        .data = .{ .none = 0 },
    }, changed);
}

/// 문자열 리터럴의 quote char — `"` / `'` / backtick. 리터럴 형식이 아니면 null.
fn detectQuote(text: []const u8) ?u8 {
    if (text.len < 2) return null;
    const q = text[0];
    if (q != '"' and q != '\'' and q != '`') return null;
    if (text[text.len - 1] != q) return null;
    return q;
}

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2) {
        if ((text[0] == '"' or text[0] == '\'' or text[0] == '`') and text[text.len - 1] == text[0]) {
            return text[1 .. text.len - 1];
        }
    }
    return text;
}

fn simpleStringLiteralValue(ast: *const Ast, node: Node) ?[]const u8 {
    if (node.tag != .string_literal) return null;
    const value = stripQuotes(ast.getText(node.span));
    for (value) |c| {
        // Avoid changing semantics for escape sequences or unicode case mapping.
        if (c == '\\' or c >= 0x80) return null;
    }
    return value;
}

fn staticMemberName(ast: *const Ast, node: Node) ?[]const u8 {
    if (node.tag != .static_member_expression) return null;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 2)) return null;
    const flags = ast.readExtra(e, 2);
    if ((flags & ast_mod.MemberFlags.optional_chain) != 0) return null;
    const prop_idx: NodeIndex = @enumFromInt(ast.readExtra(e, 1));
    const prop_ni = @intFromEnum(prop_idx);
    if (prop_ni >= ast.nodes.items.len) return null;
    const prop = ast.nodes.items[prop_ni];
    return switch (prop.tag) {
        .identifier_reference, .binding_identifier => ast.getText(prop.data.string_ref),
        else => null,
    };
}

fn staticMemberObject(ast: *const Ast, node: Node) ?Node {
    if (node.tag != .static_member_expression) return null;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 2)) return null;
    const obj_idx: NodeIndex = @enumFromInt(ast.readExtra(e, 0));
    const obj_ni = @intFromEnum(obj_idx);
    if (obj_ni >= ast.nodes.items.len) return null;
    return ast.nodes.items[obj_ni];
}

fn callHasNoArgs(ast: *const Ast, node: Node) bool {
    const e = node.data.extra;
    if (!ast.hasExtra(e, 3)) return false;
    return ast.readExtra(e, 2) == 0;
}

fn singleStringArg(ast: *const Ast, node: Node) ?[]const u8 {
    const e = node.data.extra;
    if (!ast.hasExtra(e, 3)) return null;
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1 or args_start >= ast.extra_data.items.len) return null;
    const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    const arg_ni = @intFromEnum(arg_idx);
    if (arg_ni >= ast.nodes.items.len) return null;
    return simpleStringLiteralValue(ast, ast.nodes.items[arg_ni]);
}

fn makeBoolNode(ast: *Ast, value: bool) ?Node {
    const text = if (value) "true" else "false";
    const span = ast.addString(text) catch return null;
    return .{
        .tag = .boolean_literal,
        .span = span,
        .data = .{ .none = 0 },
    };
}

fn foldCall(ast: *Ast, node_idx: u32, node: Node, changed: *bool) void {
    const e = node.data.extra;
    if (!ast.hasExtra(e, 3)) return;
    const flags = ast.readExtra(e, 3);
    if ((flags & ast_mod.CallFlags.optional_chain) != 0) return;

    // IIFE collapse 시도 — `(()=>X)()` / `(()=>{return X})()` → X.
    // oxc `substitute_iife_call` (substitute_alternate_syntax.rs) 의 최소 스펙.
    if (tryFoldIife(ast, node_idx, e, changed)) return;

    const callee_idx: NodeIndex = @enumFromInt(ast.readExtra(e, 0));
    const callee_ni = @intFromEnum(callee_idx);
    if (callee_ni >= ast.nodes.items.len) return;
    const callee = ast.nodes.items[callee_ni];
    const method = staticMemberName(ast, callee) orelse return;
    const object = staticMemberObject(ast, callee) orelse return;

    if (std.mem.eql(u8, method, "toLowerCase") and callHasNoArgs(ast, node)) {
        const value = simpleStringLiteralValue(ast, object) orelse return;
        var buf: [4096]u8 = undefined;
        if (value.len > buf.len) return;
        for (value, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        if (makeQuotedString(ast, buf[0..value.len])) |span| {
            replaceNode(ast, node_idx, .{
                .tag = .string_literal,
                .span = span,
                .data = .{ .none = 0 },
            }, changed);
        }
        return;
    }

    if (std.mem.eql(u8, method, "startsWith")) {
        const value = simpleStringLiteralValue(ast, object) orelse return;
        const prefix = singleStringArg(ast, node) orelse return;
        if (makeBoolNode(ast, std.mem.startsWith(u8, value, prefix))) |bool_node| {
            replaceNode(ast, node_idx, bool_node, changed);
        }
    }
}

/// IIFE collapse — arrow function 만, args/params 0, async 아님, body 가
/// expression(concise) 또는 single-return statement block 인 케이스. callee 의
/// return expression 으로 call_expression 노드를 in-place 대체. function expression
/// 은 `this`/`arguments` 의미가 다르고 hoisted name 도 있어 제외.
///
/// 보수 가드: returned expression 이 object/function/class literal 이면 abandon
/// — codegen 이 statement-context paren wrap 보장 안 함 ('{a:1};' 가 block 으로
/// 파싱되는 statement-level IIFE 회피). expression context (var initializer 등)
/// 가 99%지만 statement 단독 IIFE side-effect 패턴도 존재.
fn tryFoldIife(ast: *Ast, node_idx: u32, e: u32, changed: *bool) bool {
    const args_len = ast.readExtra(e, 2);
    if (args_len != 0) return false;

    const callee_raw = ast.readExtra(e, 0);
    if (callee_raw >= ast.nodes.items.len) return false;
    const callee = unwrapParens(ast, ast.nodes.items[callee_raw]);
    if (callee.tag != .arrow_function_expression) return false;

    const arrow_e = callee.data.extra;
    if (!ast.hasExtra(arrow_e, ast_mod.ArrowExtra.flags)) return false;
    const arrow_flags = ast.readExtra(arrow_e, ast_mod.ArrowExtra.flags);
    if ((arrow_flags & ast_mod.ArrowFlags.is_async) != 0) return false;

    if (ast.functionParams(callee).len != 0) return false;

    const body_idx = ast.functionBodyBlock(callee) orelse return false;
    const body_ni = @intFromEnum(body_idx);
    if (body_ni >= ast.nodes.items.len) return false;
    const body = ast.nodes.items[body_ni];

    var return_ni: u32 = undefined;
    if (body.tag == .block_statement) {
        const list = body.data.list;
        if (list.len != 1) return false;
        if (list.start >= ast.extra_data.items.len) return false;
        const stmt_raw = ast.extra_data.items[list.start];
        if (stmt_raw >= ast.nodes.items.len) return false;
        const stmt = ast.nodes.items[stmt_raw];
        if (stmt.tag != .return_statement) return false;
        const arg = stmt.data.unary.operand;
        if (arg.isNone()) return false;
        return_ni = @intFromEnum(arg);
    } else {
        return_ni = body_ni;
    }

    if (return_ni >= ast.nodes.items.len) return false;
    const return_node = ast.nodes.items[return_ni];

    // statement-context 위험한 leading-token 형태 (object/function/class)는
    // parenthesized_expression 으로 감싸 emit 안전성 확보 — `{a:1};` 가 block 으로
    // 파싱되는 ASI hazard 회피.
    //
    // **span 은 inner 그대로 유지** — string_literal/template_literal 등은 span 이
    // 곧 source text 위치라 call expression span (`(()=>"hi")()` 전체) 으로 덮으면
    // emit 시 wrong text 가 출력된다. esbuild/oxc 도 inner span 사용.
    const needs_paren = switch (return_node.tag) {
        .object_expression, .function_expression, .class_expression => true,
        else => false,
    };
    if (needs_paren) {
        const wrapped = ast.addNode(.{
            .tag = .parenthesized_expression,
            .span = return_node.span,
            .data = .{ .unary = .{ .operand = @enumFromInt(return_ni), .flags = 0 } },
        }) catch return false;
        ast.nodes.items[node_idx] = ast.nodes.items[@intFromEnum(wrapped)];
    } else {
        ast.nodes.items[node_idx] = return_node;
    }
    changed.* = true;
    return true;
}

/// x === true → x, x === false → !x, x !== true → !x, x !== false → x
/// 한쪽이 boolean 리터럴이고 다른 쪽이 non-literal이면 축약.
fn simplifyBooleanComparison(
    ast: *Ast,
    node_idx: u32,
    left: Node,
    right: Node,
    left_ni: u32,
    right_ni: u32,
    op: Kind,
) bool {
    // 어느 쪽이 boolean 리터럴인지 판별
    const bool_val: ?bool = if (left.tag == .boolean_literal)
        getBoolValue(ast, left)
    else if (right.tag == .boolean_literal)
        getBoolValue(ast, right)
    else
        null;
    const bv = bool_val orelse return false;

    // 양쪽 다 리터럴이면 foldStrictEquality에서 처리 (여기서는 축약하지 않음)
    const other_ni = if (left.tag == .boolean_literal) right_ni else left_ni;
    const other_raw = ast.nodes.items[other_ni];
    if (other_raw.tag == .boolean_literal or other_raw.tag == .numeric_literal or
        other_raw.tag == .string_literal or other_raw.tag == .null_literal) return false;

    // other가 boolean임이 보장되지 않으면 축약 거부 — `y === true` 와 `y`는 다르다
    // (y=1일 때 y===true는 false, y는 1). `!!x`와 같은 이유로 #1577에서 가드.
    const other = unwrapParens(ast, other_raw);
    if (!isGuaranteedBoolean(ast, other)) return false;

    // x === true → x, x === false → !x
    // x !== true → !x, x !== false → x
    const need_negate = (op == .eq3 and !bv) or (op == .neq2 and bv);

    if (need_negate) {
        // !x — unary_expression을 새로 만들어야 하는데, in-place 수정으로는
        // extra_data에 추가가 필요. addExtra가 실패할 수 있으므로 try 없이 catch 처리.
        const operand_extra = ast.addExtra(other_ni) catch return false;
        _ = ast.addExtra(@intFromEnum(Kind.bang)) catch return false;
        ast.nodes.items[node_idx] = .{
            .tag = .unary_expression,
            .span = ast.nodes.items[node_idx].span,
            .data = .{ .extra = operand_extra },
        };
    } else {
        // x 그대로
        ast.nodes.items[node_idx] = other;
    }
    return true;
}

fn foldStrictEquality(ast: *const Ast, allocator: std.mem.Allocator, left: Node, right: Node) ?bool {
    // 숫자 === 숫자
    if (left.tag == .numeric_literal and right.tag == .numeric_literal) {
        const a = numeric.parseLiteral(ast, left) orelse return null;
        const b = numeric.parseLiteral(ast, right) orelse return null;
        if (std.math.isNan(a) or std.math.isNan(b)) return false;
        return a == b;
    }
    // boolean === boolean
    if (left.tag == .boolean_literal and right.tag == .boolean_literal) {
        const a = getBoolValue(ast, left);
        const b = getBoolValue(ast, right);
        if (a != null and b != null) return a.? == b.?;
    }
    // null === null
    if (left.tag == .null_literal and right.tag == .null_literal) return true;
    // string === string
    if (left.tag == .string_literal and right.tag == .string_literal) {
        return stringLiteralValuesEqual(allocator, ast.getText(left.span), ast.getText(right.span));
    }
    return null;
}

/// JS string literal equality must compare decoded string values, not raw literal
/// bodies. For example `"Ā"` and `"\u0100"` are the same runtime string.
fn stringLiteralValuesEqual(allocator: std.mem.Allocator, left_raw: []const u8, right_raw: []const u8) ?bool {
    const left = string_escape.decodeJsStringLiteral(allocator, left_raw) catch return null;
    defer allocator.free(left);
    const right = string_escape.decodeJsStringLiteral(allocator, right_raw) catch return null;
    defer allocator.free(right);
    return std.mem.eql(u8, left, right);
}

// ================================================================
// Constant Folding — Unary Expression
// ================================================================

fn foldUnary(ast: *Ast, node_idx: u32, node: Node, changed: *bool) void {
    const e = node.data.extra;
    if (e + 1 >= ast.extra_data.items.len) return;
    const operand_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
    const op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[e + 1])));
    const operand_ni = @intFromEnum(operand_idx);
    if (operand_ni >= ast.nodes.items.len) return;
    const operand = ast.nodes.items[operand_ni];

    switch (op) {
        .bang => {
            // !!x → x — inner operand가 이미 boolean일 때만 안전 (#1577).
            // 예: !!(a === b) → a === b. 그러나 !!variable은 ToBoolean 강제변환이
            // 사라지므로 유지해야 함 (undefined/null/0 → false 보존).
            if (operand.tag == .unary_expression) {
                const inner_e = operand.data.extra;
                if (inner_e + 1 < ast.extra_data.items.len) {
                    const inner_op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[inner_e + 1])));
                    if (inner_op == .bang) {
                        const inner_operand_ni = ast.extra_data.items[inner_e];
                        if (inner_operand_ni < ast.nodes.items.len) {
                            const unwrapped = unwrapParens(ast, ast.nodes.items[inner_operand_ni]);
                            if (isGuaranteedBoolean(ast, unwrapped)) {
                                replaceNode(ast, node_idx, unwrapped, changed);
                                return;
                            }
                        }
                    }
                }
            }
            // !true → false, !false → true, !0 → true, !1 → false
            if (evalTruthiness(ast, operand)) |truthy| {
                const text = if (!truthy) "true" else "false";
                if (ast.addString(text)) |span| {
                    replaceNode(ast, node_idx, .{
                        .tag = .boolean_literal,
                        .span = span,
                        .data = .{ .none = 0 },
                    }, changed);
                } else |_| {}
            }
        },
        .kw_typeof => {
            // typeof "str" → "string", typeof 42 → "number", typeof true → "boolean"
            // typeof null → "object", typeof undefined → "undefined"
            if (foldTypeof(ast, operand)) |type_str| {
                if (makeQuotedString(ast, type_str)) |span| {
                    replaceNode(ast, node_idx, .{
                        .tag = .string_literal,
                        .span = span,
                        .data = .{ .none = 0 },
                    }, changed);
                }
            }
        },
        .minus => {
            // -리터럴 → 음수 리터럴 (-1 → numeric_literal(-1))
            if (operand.tag == .numeric_literal) {
                if (numeric.parseLiteral(ast, operand)) |val| {
                    if (numeric.formatNumber(ast, -val)) |span| {
                        replaceNode(ast, node_idx, .{
                            .tag = .numeric_literal,
                            .span = span,
                            .data = .{ .none = 0 },
                        }, changed);
                    }
                }
            }
        },
        .plus => {
            // +리터럴 → 그대로 (불필요한 단항 + 제거)
            if (operand.tag == .numeric_literal) {
                replaceNode(ast, node_idx, operand, changed);
            }
        },
        .kw_void => {
            // void 0 → undefined는 minify에서 하지 않음 (codegen에서 처리)
        },
        else => {},
    }
}

// ================================================================
// Helpers
// ================================================================

/// 노드의 truthiness를 정적으로 평가한다. 결정 불가능하면 null.
fn evalTruthiness(ast: *const Ast, node: Node) ?bool {
    return switch (node.tag) {
        .boolean_literal => getBoolValue(ast, node),
        .numeric_literal => blk: {
            const val = numeric.parseLiteral(ast, node) orelse break :blk null;
            if (std.math.isNan(val)) break :blk false;
            break :blk val != 0;
        },
        .null_literal => false,
        .string_literal => blk: {
            const text = stripQuotes(ast.getText(node.span));
            break :blk text.len > 0;
        },
        .identifier_reference => blk: {
            const text = ast.getText(node.span);
            if (std.mem.eql(u8, text, "true")) break :blk true;
            if (std.mem.eql(u8, text, "false")) break :blk false;
            if (std.mem.eql(u8, text, "undefined")) break :blk false;
            if (std.mem.eql(u8, text, "NaN")) break :blk false;
            break :blk null;
        },
        .parenthesized_expression => blk: {
            const inner_ni = @intFromEnum(node.data.unary.operand);
            if (inner_ni >= ast.nodes.items.len) break :blk null;
            break :blk evalTruthiness(ast, ast.nodes.items[inner_ni]);
        },
        else => null,
    };
}

fn getBoolValue(ast: *const Ast, node: Node) ?bool {
    if (node.tag != .boolean_literal) return null;
    const text = ast.getText(node.span);
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

fn foldTypeof(ast: *const Ast, operand: Node) ?[]const u8 {
    return switch (operand.tag) {
        .string_literal => "string",
        .numeric_literal => "number",
        .boolean_literal => "boolean",
        .null_literal => "object",
        .identifier_reference => blk: {
            const text = ast.getText(operand.span);
            if (std.mem.eql(u8, text, "undefined")) break :blk "undefined";
            break :blk null;
        },
        .function_expression, .arrow_function_expression => "function",
        else => null,
    };
}

// ================================================================
// Phase 2: Dead Code Elimination
// ================================================================

/// conditional_expression: false ? a : b → b, true ? a : b → a.
///
/// dead 분기 안 ref 는 `decrementRefsShallow` 로 감산 — function/class body 는 호출 시점
/// 평가라 skip (over-decrement 회피, #3267 N-step4).
fn foldConditional(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
    const cond_ni = @intFromEnum(node.data.ternary.a);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    const kept = if (truthy) node.data.ternary.b else node.data.ternary.c;
    const dropped = if (truthy) node.data.ternary.c else node.data.ternary.b;
    const kept_ni = @intFromEnum(kept);
    if (kept_ni >= ast.nodes.items.len) return;
    if (ctx.hasSemantic() and !dropped.isNone()) decrementRefsShallow(ast, ctx, dropped);
    replaceNode(ast, node_idx, ast.nodes.items[kept_ni], changed);
}

/// if_statement: if (false) { A } else { B } → B, if (true) { A } → A.
/// dead 분기의 cascade decrement (#3267 N-step4).
fn foldIf(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
    const cond_ni = @intFromEnum(node.data.ternary.a);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    const semantic = ctx.hasSemantic();
    if (truthy) {
        // if (true) { A } else { B } → A. else (B) 분기 cascade.
        const then_ni = @intFromEnum(node.data.ternary.b);
        if (then_ni >= ast.nodes.items.len) return;
        if (ast.nodes.items[then_ni].tag == .function_declaration) return;
        if (semantic and !node.data.ternary.c.isNone()) decrementRefsShallow(ast, ctx, node.data.ternary.c);
        replaceNode(ast, node_idx, ast.nodes.items[then_ni], changed);
    } else {
        if (!node.data.ternary.c.isNone()) {
            // if (false) { A } else { B } → B. then (A) 분기 cascade.
            const else_ni = @intFromEnum(node.data.ternary.c);
            if (else_ni >= ast.nodes.items.len) return;
            if (ast.nodes.items[else_ni].tag == .function_declaration) return;
            if (semantic) decrementRefsShallow(ast, ctx, node.data.ternary.b);
            replaceNode(ast, node_idx, ast.nodes.items[else_ni], changed);
        } else {
            // if (false) { A } → empty_statement. then (A) 분기 cascade.
            if (semantic) decrementRefsShallow(ast, ctx, node.data.ternary.b);
            replaceNode(ast, node_idx, .{
                .tag = .empty_statement,
                .span = node.span,
                .data = .{ .none = 0 },
            }, changed);
        }
    }
}

/// while (false) { ... } → empty_statement. body cascade (#3267 N-step4).
fn foldWhile(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
    const cond_ni = @intFromEnum(node.data.binary.left);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    if (!truthy) {
        if (ctx.hasSemantic()) decrementRefsShallow(ast, ctx, node.data.binary.right);
        replaceNode(ast, node_idx, .{
            .tag = .empty_statement,
            .span = node.span,
            .data = .{ .none = 0 },
        }, changed);
    }
}

/// `X` 가 side-effect-free identifier 이고 `undefined`(예약어 식별자)가 아니면 텍스트.
/// member (`a.b`) 는 의도적으로 제외 — getter side-effect 시 2회→1회 평가가
/// observable behavior 변경 (folding 으로 getter 호출 횟수 감소). identifier 만 안전.
fn simpleIdentText(ast: *const Ast, idx: ast_mod.NodeIndex) ?[]const u8 {
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return null;
    const n = ast.nodes.items[ni];
    if (n.tag != .identifier_reference) return null;
    const t = ast.getText(n.span);
    if (std.mem.eql(u8, t, "undefined")) return null;
    return t;
}

/// `null` literal 또는 `undefined`(식별자)/`void <expr>` 인지.
fn isNullOrUndefinedLit(ast: *const Ast, idx: ast_mod.NodeIndex) enum { null_lit, undef, no } {
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return .no;
    const n = ast.nodes.items[ni];
    switch (n.tag) {
        .null_literal => return .null_lit,
        .identifier_reference => {
            if (std.mem.eql(u8, ast.getText(n.span), "undefined")) return .undef;
            return .no;
        },
        .unary_expression => {
            // `void <expr>` 는 operand 무관하게 항상 undefined — `void g()` 도 .undef.
            // (dropped 시 decrementRefsShallow 가 operand subtree ref 정확 처리.)
            const e = n.data.extra;
            if (e + 1 >= ast.extra_data.items.len) return .no;
            const op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[e + 1])));
            return if (op == .kw_void) .undef else .no;
        },
        else => return .no,
    }
}

/// `X===null||X===void 0` → `X==null`, `X!==null&&X!==void 0` → `X!=null`
/// (terser/esbuild 표준). X 는 side-effect-free identifier (1회 평가 — 2회→1회
/// 안전). ECMAScript: `X==null` ⟺ X is null 또는 undefined. 매칭 시 true 반환
/// (이 경우 foldLogical skip), 아니면 false.
fn foldNullishCheck(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) bool {
    const op: Kind = @enumFromInt(node.data.binary.flags);
    // || → 양쪽 `===`, 결과 `==` / && → 양쪽 `!==`, 결과 `!=`
    const want_cmp: Kind = switch (op) {
        .pipe2 => .eq3,
        .amp2 => .neq2,
        else => return false,
    };
    const result_op: Kind = if (op == .pipe2) .eq2 else .neq;

    const lni = @intFromEnum(node.data.binary.left);
    const rni = @intFromEnum(node.data.binary.right);
    if (lni >= ast.nodes.items.len or rni >= ast.nodes.items.len) return false;
    const L = ast.nodes.items[lni];
    const R = ast.nodes.items[rni];
    if (L.tag != .binary_expression or R.tag != .binary_expression) return false;
    if (@as(Kind, @enumFromInt(L.data.binary.flags)) != want_cmp) return false;
    if (@as(Kind, @enumFromInt(R.data.binary.flags)) != want_cmp) return false;

    const lx = simpleIdentText(ast, L.data.binary.left) orelse return false;
    const rx = simpleIdentText(ast, R.data.binary.left) orelse return false;
    if (!std.mem.eql(u8, lx, rx)) return false;

    const lkind = isNullOrUndefinedLit(ast, L.data.binary.right);
    const rkind = isNullOrUndefinedLit(ast, R.data.binary.right);
    // {null, undefined} 한 쌍이어야 — (null,null)/(undef,undef) 등은 다른 의미.
    if (!((lkind == .null_lit and rkind == .undef) or (lkind == .undef and rkind == .null_lit)))
        return false;

    // 최종: binary(result_op, X=L.left, null_node). null literal 노드 재사용.
    const keep_null: ast_mod.NodeIndex = if (lkind == .null_lit) L.data.binary.right else R.data.binary.right;
    const keep_x = L.data.binary.left;

    // dropped (semantic 시 cascade): X 중복 ref(R.left) + undefined-side 노드.
    if (ctx.hasSemantic()) {
        decrementRefsShallow(ast, ctx, R.data.binary.left);
        const undef_side = if (lkind == .undef) L.data.binary.right else R.data.binary.right;
        decrementRefsShallow(ast, ctx, undef_side);
    }

    ast.nodes.items[node_idx] = .{
        .tag = .binary_expression,
        .span = node.span,
        .data = .{ .binary = .{
            .left = keep_x,
            .right = keep_null,
            .flags = @intFromEnum(result_op),
        } },
    };
    changed.* = true;
    return true;
}

/// logical_expression: true && x → x, false && x → false, true || x → true, false || x → x.
/// dropped side 의 cascade decrement (#3267 N-step4).
fn foldLogical(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
    const left_ni = @intFromEnum(node.data.binary.left);
    if (left_ni >= ast.nodes.items.len) return;
    const left = ast.nodes.items[left_ni];
    const op: Kind = @enumFromInt(node.data.binary.flags);

    const truthy = evalTruthiness(ast, left) orelse return;
    const semantic = ctx.hasSemantic();

    switch (op) {
        .amp2 => { // &&
            if (truthy) {
                // true && x → x (left literal — 영향 0)
                const right_ni = @intFromEnum(node.data.binary.right);
                if (right_ni >= ast.nodes.items.len) return;
                replaceNode(ast, node_idx, ast.nodes.items[right_ni], changed);
            } else {
                // false && x → false. right (x) drop → cascade.
                if (semantic) decrementRefsShallow(ast, ctx, node.data.binary.right);
                replaceNode(ast, node_idx, left, changed);
            }
        },
        .pipe2 => { // ||
            if (truthy) {
                // true || x → true. right (x) drop → cascade.
                if (semantic) decrementRefsShallow(ast, ctx, node.data.binary.right);
                replaceNode(ast, node_idx, left, changed);
            } else {
                // false || x → x (left literal — 영향 0)
                const right_ni = @intFromEnum(node.data.binary.right);
                if (right_ni >= ast.nodes.items.len) return;
                replaceNode(ast, node_idx, ast.nodes.items[right_ni], changed);
            }
        },
        .question2 => { // ??
            // null ?? x → x, undefined ?? x → x
            if (left.tag == .null_literal) {
                const right_ni = @intFromEnum(node.data.binary.right);
                if (right_ni >= ast.nodes.items.len) return;
                replaceNode(ast, node_idx, ast.nodes.items[right_ni], changed);
            } else if (left.tag == .identifier_reference) {
                const text = ast.getText(left.span);
                if (std.mem.eql(u8, text, "undefined")) {
                    const right_ni = @intFromEnum(node.data.binary.right);
                    if (right_ni >= ast.nodes.items.len) return;
                    replaceNode(ast, node_idx, ast.nodes.items[right_ni], changed);
                }
            }
        },
        else => {},
    }
}

// ================================================================
// Phase 5: Adjacent Same-Kind Declaration Merge (#1588)
// ================================================================
//
// `var a=1; var b=2;` → `var a=1,b=2;` — 선언당 4-6 바이트 절감.
// 참고: esbuild `mangleStmts`, rolldown `mergeable_declarations.rs`.

// `ast.allocator`는 parse_arena라 `free`가 no-op — watch 재빌드 시 캐시된 모듈의
// arena에 임시 할당이 누적되므로 스택 버퍼만 사용. 상한 초과 블록은 merge 스킵.
const MAX_STMTS_PER_BLOCK: usize = 4096;
const MAX_DECLS_PER_MERGE: usize = 1024;

/// Program/BlockStatement/FunctionBody 내 연속된 같은-kind 선언을 병합한다.
///
/// `skip_nodes`가 주어지면 tree-shake로 마킹된 statement는 accumulator에 넣지 않아
/// merge 대상에서도 제외된다 (statement 자체는 새 리스트에 그대로 남음 — codegen이
/// skip_nodes를 보고 출력을 생략).
fn mergeAdjacentDecls(ast: *Ast, node_idx: u32, node: Node, skip_nodes: ?*const std.DynamicBitSet) void {
    const list = node.data.list;
    if (list.len < 2) return;
    if (list.len > MAX_STMTS_PER_BLOCK) return;
    if (@as(usize, list.start) + list.len > ast.extra_data.items.len) return;

    // 원본 리스트 복사 — 이후 extra_data append가 슬라이스를 무효화할 수 있음.
    var stmts_buf: [MAX_STMTS_PER_BLOCK]u32 = undefined;
    const stmts = stmts_buf[0..list.len];
    @memcpy(stmts, ast.extra_data.items[list.start .. list.start + list.len]);

    var out_buf: [MAX_STMTS_PER_BLOCK]u32 = undefined;
    var out_len: usize = 0;
    var changed = false;

    for (stmts) |stmt_ni| {
        // skip_nodes 마킹된 statement는 merge 후보에서 제외. prev로도, cur로도 취급 안 함.
        // 대신 원본 순서대로 out_buf에 포함 — codegen이 skip_nodes 보고 출력 생략.
        const is_skipped = if (skip_nodes) |s| (stmt_ni < s.capacity() and s.isSet(stmt_ni)) else false;

        if (!is_skipped and tryMergeWithPrev(ast, stmt_ni, out_buf[0..out_len], skip_nodes)) {
            changed = true;
            continue;
        }
        out_buf[out_len] = stmt_ni;
        out_len += 1;
    }

    if (!changed) return;

    // 새 리스트를 extra_data 끝에 append — 원본 슬롯은 garbage로 남는다.
    // 두 번째 호출 시엔 이미 merge 완료 상태라 `changed=false`로 조기 반환 → idempotent.
    const new_start = ast.addExtras(out_buf[0..out_len]) catch return;
    ast.nodes.items[node_idx].data = .{
        .list = .{ .start = new_start, .len = @intCast(out_len) },
    };
}

/// `cur_ni`가 `accumulated`의 마지막 non-skipped 선언과 병합 가능하면 병합하고 true 반환.
/// 병합 시: prev의 declarator list를 `[prev_decls ++ cur_decls]`로 확장.
fn tryMergeWithPrev(ast: *Ast, cur_ni: u32, accumulated: []const u32, skip_nodes: ?*const std.DynamicBitSet) bool {
    if (accumulated.len == 0) return false;
    if (cur_ni >= ast.nodes.items.len) return false;
    const cur_info = resolveMergeableVarDecl(ast, cur_ni) orelse return false;

    // prev 탐색 시 skip_nodes 마킹된 항목은 건너뜀 — 이들은 codegen에서도 출력 안 되므로
    // 인접성 기준으로 삼으면 tree-shake 결과와 어긋날 수 있다.
    var prev_ni: u32 = 0;
    var found_prev = false;
    var idx: usize = accumulated.len;
    while (idx > 0) {
        idx -= 1;
        const candidate = accumulated[idx];
        const is_skipped = if (skip_nodes) |s| (candidate < s.capacity() and s.isSet(candidate)) else false;
        if (is_skipped) continue;
        prev_ni = candidate;
        found_prev = true;
        break;
    }
    if (!found_prev) return false;

    if (prev_ni >= ast.nodes.items.len) return false;
    const prev_info = resolveMergeableVarDecl(ast, prev_ni) orelse return false;

    // correctness 핵심: export↔non-export 혼합 금지. `export const a=1; const b=2;`
    // 를 한 선언으로 합치면 b 가 잘못 export 되거나 a 가 un-export 됨. 둘 다
    // plain 이거나 둘 다 export-wrapper 일 때만 병합 (단일파일·번들 양쪽 안전).
    if (prev_info.is_export != cur_info.is_export) return false;

    const prev_vd = ast.nodes.items[prev_info.vardecl_ni];
    const cur_vd = ast.nodes.items[cur_info.vardecl_ni];
    const kind_prev = ast.variableDeclarationKind(prev_vd);
    const kind_cur = ast.variableDeclarationKind(cur_vd);
    if (kind_prev != kind_cur) return false;
    // `using`/`await using`: declarator 좌→우로 dispose 스택에 push되고 block 끝에서
    // LIFO로 pop되므로, 개별 선언과 merged 선언의 dispose 순서가 동일 → 안전하게 merge.

    // 병합은 *내부* variable_declaration 의 declarator list 에 수행. export-wrapper
    // 의 경우 prev 의 inner vardecl 에 cur 의 inner declarator 를 이어붙이고 prev
    // wrapper 는 그대로 두면 emit 시 `export const a=1,b=2;` (또는 번들 ctx 에선
    // `const a=1,b=2;`) 로 정상. cur (외곽 노드) 은 아래에서 empty_statement 치환.
    const pe = prev_vd.data.extra;
    const ce = cur_vd.data.extra;
    if (pe + 2 >= ast.extra_data.items.len) return false;
    if (ce + 2 >= ast.extra_data.items.len) return false;

    const p_start = ast.extra_data.items[pe + 1];
    const p_len = ast.extra_data.items[pe + 2];
    const c_start = ast.extra_data.items[ce + 1];
    const c_len = ast.extra_data.items[ce + 2];

    if (@as(usize, p_start) + p_len > ast.extra_data.items.len) return false;
    if (@as(usize, c_start) + c_len > ast.extra_data.items.len) return false;

    const total_len: usize = @as(usize, p_len) + c_len;
    if (total_len > MAX_DECLS_PER_MERGE) return false;

    var buf: [MAX_DECLS_PER_MERGE]u32 = undefined;
    @memcpy(buf[0..p_len], ast.extra_data.items[p_start .. p_start + p_len]);
    @memcpy(buf[p_len..total_len], ast.extra_data.items[c_start .. c_start + c_len]);

    const new_start = ast.addExtras(buf[0..total_len]) catch return false;
    // pe+1/pe+2는 고정 인덱스이므로 addExtras 후에도 직접 쓰기 가능.
    ast.extra_data.items[pe + 1] = new_start;
    ast.extra_data.items[pe + 2] = @intCast(total_len);
    // `cur` 노드를 empty_statement로 교체한다. 이유:
    // 1) idempotency: 같은 AST가 여러 container에 걸쳐 있을 때(module-program /
    //    wrapper-program) 두 번째 container가 동일 pair를 재병합하면 prev에 cur의
    //    declarator가 중복(a,b,b)으로 붙는다.
    // 2) shared-node 안전성: 클래스 lowering처럼 pass1이 중간 function_declaration을
    //    남기고 pass2(`lowerAllFunctionParams`)가 dead/live 양쪽 body를 모두 수정하면,
    //    dead block은 `[var_gestures, var_this]`가 인접해 merge되지만 live block은
    //    `[var_gestures, __classCallCheck, var_this]`로 비인접이다. cur의 list_len만 0으로
    //    비우면(기존 구현) live block의 var_this가 `var ;`로 깨진다. 노드 자체를
    //    empty_statement로 바꾸면 live block은 `;`를 emit하여 구문상 무해하다.
    ast.nodes.items[cur_ni] = .{
        .tag = .empty_statement,
        .span = ast.nodes.items[cur_ni].span,
        .data = .{ .none = 0 },
    };
    return true;
}
