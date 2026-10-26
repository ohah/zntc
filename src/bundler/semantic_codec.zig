//! semantic 직렬화 codec — 디스크 캐시(#4438) PR2.
//!
//! `ModuleSemanticData` 의 **relocatable 부분만** 직렬화한다 (사용자 결정: 점진 PR).
//! - `scopes` / `symbol_ids` / `references`: 전부 인덱스·스칼라라 통째 memcpy.
//! - `symbols`(ArrayList): Symbol 도 대부분 인덱스/Span 이라 memcpy, 단 `synthetic_name`과
//!   `output_name_hint` (`[]const u8`)만 별도 — memcpy 후 빈 문자열로 리셋하고 직렬화 텍스트에서
//!   복원(arena dupe).
//! - HashMap 5개(scope_maps/exported_names/unresolved_references/numeric_const_texts/
//!   helper_scope_map)는 **PR3**에서 복원한다. 키 문자열은 source/string_table(parse_arena)
//!   슬라이스라 deserialize 가 주입 arena 에 dupe; 값은 심볼인덱스(usize→u32)/Span/void/텍스트.
//!
//! 소유권: `ModuleSemanticData` 는 deinit 이 없고 원본은 `parse_arena` 가 일괄 소유한다.
//! deserialize 본은 parse_arena 가 없으므로 **caller 가 arena 를 주입** — 모든 배열·문자열을
//! 그 arena 에 alloc 하고 `arena.deinit()` 가 일괄 해제(원본 모델과 동일).
//!
//! 안전: PR1 ast_codec 과 동일하게 `[MAGIC][VERSION][checksum]` 헤더 + 비배수/오버플로우
//! 검증 → 실패는 항상 error(fail-safe). host endian/정렬 native(로컬 캐시 전제).

const std = @import("std");
const module = @import("module.zig");
const ModuleSemanticData = module.ModuleSemanticData;
const symbol_mod = @import("../semantic/symbol.zig");
const Symbol = symbol_mod.Symbol;
const Reference = symbol_mod.Reference;
const scope_mod = @import("../semantic/scope.zig");
const Scope = scope_mod.Scope;
const Span = @import("../lexer/token.zig").Span;
const wyhash = @import("../util/wyhash.zig");
const codec_io = @import("../util/codec_io.zig");

pub const MAGIC: u32 = 0x5A53454D; // "ZSEM"
// v19: HMR runtime roles persist with their owning semantic graph.
// Initial ordinary-function arguments bindings are now exact source symbols.
// Older source graphs can resolve through the wrong enclosing binding.
// v24: nested TS enum outer bindings have lexical source identities.
// Reusing a v23 source graph can omit those bindings or restore var lifetimes.
// v25: class static blocks own distinct var environments and source IDs.
// v24 graphs hoisted these vars into unrelated enclosing activations.
pub const FORMAT_VERSION: u32 = 25;
const HEADER_LEN: usize = 16;

/// `?u32`(symbol_ids) 의 null 표식. 값은 symbols 배열 인덱스라 maxInt 에 도달하지 않으므로
/// 안전한 sentinel(SymbolId.none/ScopeId.none 과 동일 패턴).
const NULL_U32: u32 = std.math.maxInt(u32);
const CJS_RUNTIME_FIELDS = [_][]const u8{ "callback_parameter", "module_parameter", "catch_parameter", "require_function" };
const ESM_RUNTIME_FIELDS = [_][]const u8{ "factory_parameter", "result_parameter", "catch_parameter", "init_function", "factory_local" };

const INTEROP_HELPER_FIELDS = [_][]const u8{ "create", "get_proto_of", "def_prop", "get_own_prop_names", "get_own_prop_desc", "has_own", "copy_props", "to_esm", "export_helper", "to_common_js" };
const INTEROP_INTERNAL_FIELDS = [_][]const u8{ "copy_props_to", "copy_props_from", "copy_props_desc", "copy_props_keys", "copy_props_index", "copy_props_key", "copy_props_closure_key", "to_esm_module", "to_esm_node_mode", "to_esm_target", "export_target", "export_all", "export_name", "to_common_js_module" };

const HMR_RUNTIME_FIELDS = [_][]const u8{ "global", "modules", "hot_callbacks", "hot_data", "schedule", "reload", "resolve_refresh", "refresh_boundary", "refresh_timer", "enqueue_update", "make_hot", "original_commonjs", "original_esm", "apply_update" };

comptime {
    if (@typeInfo(module.RuntimeIdentitySnapshot).@"struct".field_names.len != 8 or
        @typeInfo(module.CjsRuntimeInternalSymbolIds).@"struct".field_names.len != CJS_RUNTIME_FIELDS.len or
        @typeInfo(module.EsmRuntimeInternalSymbolIds).@"struct".field_names.len != ESM_RUNTIME_FIELDS.len or
        @typeInfo(module.EsmInteropRuntimeHelperSymbolIds).@"struct".field_names.len != INTEROP_HELPER_FIELDS.len or
        @typeInfo(module.EsmInteropRuntimeInternalSymbolIds).@"struct".field_names.len != INTEROP_INTERNAL_FIELDS.len or
        @typeInfo(module.HmrRuntimeInternalSymbolIds).@"struct".field_names.len != HMR_RUNTIME_FIELDS.len)
        @compileError("Runtime identity snapshot changed; update the semantic codec layout and version.");
}

fn putRuntimeId(out: *std.ArrayList(u8), allocator: std.mem.Allocator, id: ?symbol_mod.SymbolId) !void {
    if (id) |value| if (@backingInt(value) == NULL_U32) return error.Truncated;
    try putU32(out, allocator, if (id) |value| @backingInt(value) else NULL_U32);
}

fn putRuntimeGroup(comptime fields: []const []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator, group: anytype) !void {
    try putU32(out, allocator, @intFromBool(group != null));
    if (group) |ids| inline for (fields) |field| {
        const id: symbol_mod.SymbolId = @field(ids, field);
        try putRuntimeId(out, allocator, id);
    };
}

fn readRuntimeId(r: *Reader, symbols_len: usize) Error!?symbol_mod.SymbolId {
    const raw = try r.u32v();
    if (raw == NULL_U32) return null;
    if (raw >= symbols_len) return error.Truncated;
    return @fromBackingInt(raw);
}

fn readRuntimeGroup(comptime T: type, comptime fields: []const []const u8, r: *Reader, symbols_len: usize) Error!?T {
    const present = try r.u32v();
    if (present == 0) return null;
    if (present != 1) return error.Truncated;
    var ids: T = undefined;
    inline for (fields) |field| @field(ids, field) = (try readRuntimeId(r, symbols_len)) orelse return error.Truncated;
    return ids;
}

fn validRuntimeIdentityLayout(snapshot: module.RuntimeIdentitySnapshot, symbols_len: usize) bool {
    if ((snapshot.cjs_factory == null) != (snapshot.cjs_internal == null) or
        (snapshot.esm_factory == null) != (snapshot.esm_internal == null)) return false;
    if (snapshot.interop_internal != null and snapshot.interop_helpers == null) return false;
    const ids = [_]?symbol_mod.SymbolId{
        snapshot.cjs_factory,
        if (snapshot.cjs_internal) |x| x.callback_parameter else null,
        if (snapshot.cjs_internal) |x| x.module_parameter else null,
        if (snapshot.cjs_internal) |x| x.catch_parameter else null,
        if (snapshot.cjs_internal) |x| x.require_function else null,
        snapshot.esm_factory,
        if (snapshot.esm_internal) |x| x.factory_parameter else null,
        if (snapshot.esm_internal) |x| x.result_parameter else null,
        if (snapshot.esm_internal) |x| x.catch_parameter else null,
        if (snapshot.esm_internal) |x| x.init_function else null,
        if (snapshot.esm_internal) |x| x.factory_local else null,
        snapshot.to_binary,
        if (snapshot.interop_helpers) |x| x.create else null,
        if (snapshot.interop_helpers) |x| x.get_proto_of else null,
        if (snapshot.interop_helpers) |x| x.def_prop else null,
        if (snapshot.interop_helpers) |x| x.get_own_prop_names else null,
        if (snapshot.interop_helpers) |x| x.get_own_prop_desc else null,
        if (snapshot.interop_helpers) |x| x.has_own else null,
        if (snapshot.interop_helpers) |x| x.copy_props else null,
        if (snapshot.interop_helpers) |x| x.to_esm else null,
        if (snapshot.interop_helpers) |x| x.export_helper else null,
        if (snapshot.interop_helpers) |x| x.to_common_js else null,
        if (snapshot.interop_internal) |x| x.copy_props_to else null,
        if (snapshot.interop_internal) |x| x.copy_props_from else null,
        if (snapshot.interop_internal) |x| x.copy_props_desc else null,
        if (snapshot.interop_internal) |x| x.copy_props_keys else null,
        if (snapshot.interop_internal) |x| x.copy_props_index else null,
        if (snapshot.interop_internal) |x| x.copy_props_key else null,
        if (snapshot.interop_internal) |x| x.copy_props_closure_key else null,
        if (snapshot.interop_internal) |x| x.to_esm_module else null,
        if (snapshot.interop_internal) |x| x.to_esm_node_mode else null,
        if (snapshot.interop_internal) |x| x.to_esm_target else null,
        if (snapshot.interop_internal) |x| x.export_target else null,
        if (snapshot.interop_internal) |x| x.export_all else null,
        if (snapshot.interop_internal) |x| x.export_name else null,
        if (snapshot.interop_internal) |x| x.to_common_js_module else null,
        if (snapshot.hmr_internal) |x| x.global else null,
        if (snapshot.hmr_internal) |x| x.modules else null,
        if (snapshot.hmr_internal) |x| x.hot_callbacks else null,
        if (snapshot.hmr_internal) |x| x.hot_data else null,
        if (snapshot.hmr_internal) |x| x.schedule else null,
        if (snapshot.hmr_internal) |x| x.reload else null,
        if (snapshot.hmr_internal) |x| x.resolve_refresh else null,
        if (snapshot.hmr_internal) |x| x.refresh_boundary else null,
        if (snapshot.hmr_internal) |x| x.refresh_timer else null,
        if (snapshot.hmr_internal) |x| x.enqueue_update else null,
        if (snapshot.hmr_internal) |x| x.make_hot else null,
        if (snapshot.hmr_internal) |x| x.original_commonjs else null,
        if (snapshot.hmr_internal) |x| x.original_esm else null,
        if (snapshot.hmr_internal) |x| x.apply_update else null,
    };
    for (ids, 0..) |id, i| {
        if (id == null) continue;
        if (@backingInt(id.?) >= symbols_len) return false;
        for (ids[0..i]) |previous| if (id == previous) return false;
    }
    return true;
}

comptime {
    // synthetic_kind 직렬화(putSymbol/readSymbol)가 0xFF 를 ?SyntheticKind 의 null sentinel 로
    // 쓴다. SyntheticKind(enum(u8))에 값 0xFF 변형이 생기면 null 로 오역(silent miscompile)되므로
    // 0xFF 가 유효 변형이 아님을 못박는다(여유 있는 sentinel — 미래 회귀 가드).
    if (std.enums.fromInt(symbol_mod.SyntheticKind, 0xFF) != null)
        @compileError("SyntheticKind 0xFF 변형이 semantic_codec 의 null sentinel 과 충돌 — sentinel 폭 확장 필요.");
}

/// struct 의 `"name:typename;name:typename;…"` 시그니처를 comptime 문자열로 만든다.
/// 필드 수뿐 아니라 **이름+타입+순서**까지 못박아 rename/retype/reorder(필드 수 불변 변경)도
/// 컴파일 에러로 잡는다 — 이 codec 은 필드별 명시 직렬화라 그런 변경이 silent 하면 cache-hit
/// drift(miscompile)가 된다.
fn fieldSig(comptime T: type) []const u8 {
    comptime {
        var sig: []const u8 = "";
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |name, field_type| {
            sig = sig ++ name ++ ":" ++ @typeName(field_type) ++ ";";
        }
        return sig;
    }
}

comptime {
    // Symbol/Scope/Reference 는 일반 struct 라 통째 memcpy 가 padding/미초기화 바이트를 직렬화
    // stream 에 섞어 비결정적이었다(#4438). 이제 `putSymbol`/`putScope`/`putReference` 가 필드별
    // 명시 직렬화한다. 필드를 추가/삭제/rename/retype/reorder 하면 직렬화가 silently 어긋나
    // cache-hit drift 이므로, **필드 시그니처(이름+타입+순서)**를 못박아 codec 갱신을 컴파일
    // 에러로 강제한다. 새 필드가 슬라이스/포인터면 side-table 복원(synthetic_name 패턴)이 추가 필요.
    // (필드 수만 핀하면 rename/retype/reorder 를 못 잡아 silent miscompile 위험 — 결함4.)
    const symbol_sig = "name:lexer.token.Span;scope_id:semantic.scope.ScopeId;origin_scope:semantic.scope.ScopeId;" ++
        "kind:semantic.symbol.SymbolKind;decl_flags:semantic.symbol.DeclFlags;declaration_span:lexer.token.Span;" ++
        "reference_count:u32;write_count:u32;const_kind:semantic.symbol.ConstValue.Kind;" ++
        "synthetic_kind:?semantic.symbol.SyntheticKind;synthetic_name:[]const u8;output_name_hint:[]const u8;" ++
        "requires_uppercase_first_char:bool;" ++
        "synthetic_owner_id:?semantic.symbol.SymbolId;annex_b_alias:semantic.symbol.AnnexBFunctionAlias;parameter_copy:semantic.symbol.ParameterBodyVarCopy;binding_instantiation:semantic.symbol.BindingInstantiation;";
    if (!std.mem.eql(u8, fieldSig(Symbol), symbol_sig))
        @compileError("Symbol 필드 시그니처가 바뀜 — putSymbol/readSymbol 의 명시 직렬화 갱신 후 이 시그니처를 갱신.\n실제: " ++ fieldSig(Symbol));
    const annex_alias_sig = "variable:semantic.symbol.SymbolId;state:semantic.symbol.AnnexBFunctionAlias.State;source_assignment_count:u32;";
    if (!std.mem.eql(u8, fieldSig(symbol_mod.AnnexBFunctionAlias), annex_alias_sig))
        @compileError("Annex B role changed; update the explicit semantic wire layout/version.");
    const parameter_copy_sig = "parameter_source:semantic.symbol.SymbolId;state:semantic.symbol.ParameterBodyVarCopy.State;";
    if (!std.mem.eql(u8, fieldSig(symbol_mod.ParameterBodyVarCopy), parameter_copy_sig))
        @compileError("Parameter/body-var role changed; update the explicit semantic wire layout/version.");
    if (@bitSizeOf(symbol_mod.BindingInstantiation) != 8 or !std.mem.eql(u8, fieldSig(symbol_mod.BindingInstantiation), "annex_b:bool;parameter_copy:bool;strict_output_function:bool;reserved:u5;"))
        @compileError("Binding instantiation presence bits changed; update the semantic wire layout/version.");
    const scope_sig = "parent:semantic.scope.ScopeId;kind:semantic.scope.ScopeKind;is_strict:bool;" ++
        "subtree_has_direct_eval:bool;subtree_has_with:bool;symbol_count:u16;";
    if (!std.mem.eql(u8, fieldSig(Scope), scope_sig))
        @compileError("Scope 필드 시그니처가 바뀜 — putScope/readScope 의 명시 직렬화 갱신 후 이 시그니처를 갱신.\n실제: " ++ fieldSig(Scope));
    const reference_sig = "node_index:parser.ast.NodeIndex;declaration_node_index:parser.ast.NodeIndex;scope_id:semantic.scope.ScopeId;symbol_id:semantic.symbol.SymbolId;" ++
        "stmt_idx:u32;scope_stmt_idx:u32;flags:semantic.symbol.ReferenceFlags;";
    if (!std.mem.eql(u8, fieldSig(Reference), reference_sig))
        @compileError("Reference 필드 시그니처가 바뀜 — putReference/readReference 의 명시 직렬화 갱신 후 이 시그니처를 갱신.\n실제: " ++ fieldSig(Reference));
    // owner_token is memory-only and deliberately omitted; decode defaults to unassigned.
    // serialize/deserialize 는 ModuleSemanticData 의 persisted 필드를 손으로 열거한다. 필드가 추가되면
    // 직렬화에서 silently 누락 → PR4 cache-hit 연결 시 그 필드만 default 로 stale miscompile.
    // 필드 수를 못박아 새 필드 추가를 컴파일 에러로 만들어 codec 갱신을 강제한다.
    if (@typeInfo(@import("../semantic/node_scope_provenance.zig").Entry).@"struct".field_names.len != 3) @compileError("expression provenance fields changed; update semantic codec");
    const StrictRole = @import("strict_function_context.zig").Role;
    const strict_names = [_][]const u8{ "kind", "body", "directive", "name_role", "declaration", "binding", "symbol", "returned_function", "factory", "factory_scope", "source_scope", "lexical_root" };
    const strict_fields = @typeInfo(StrictRole).@"struct".field_names;
    if (strict_fields.len != strict_names.len) @compileError("strict role wire fields changed; update codec/version");
    for (strict_names, strict_fields) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual) or @bitSizeOf(@FieldType(StrictRole, actual)) != 32)
            @compileError("strict role wire order/type changed; update codec/version");
    }
    const StrictKind = @import("strict_function_context.zig").RoleKind;
    const StrictName = @import("strict_function_context.zig").NameRole;
    if (@backingInt(StrictKind.factory) != 0 or @backingInt(StrictKind.body_directive) != 1 or
        @backingInt(StrictName.binding) != 0 or @backingInt(StrictName.anonymous_default) != 1)
        @compileError("strict role wire tags changed; update codec/version");
    if (@typeInfo(ModuleSemanticData).@"struct".field_names.len != 17) {
        @compileError("ModuleSemanticData 필드 수가 바뀜 — semantic_codec 의 serialize/deserialize 에 새 필드 직렬화 추가 후 이 가드를 갱신.");
    }
}

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    Truncated,
} || std.mem.Allocator.Error;

// ── serialize ───────────────────────────────────────────────────────────────

// IO 원시함수/Reader 는 공유 `util/codec_io.zig` 사용(ast_codec/module_codec 와 동일 1벌).
const putU32 = codec_io.putU32;
const putU64 = codec_io.putU64;
const putBytes = codec_io.putBytes;

// 작은 스칼라 — codec_io 엔 u32/u64 만 있으므로 여기서 직접 append.
fn putU16(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    try buf.appendSlice(alloc, std.mem.asBytes(&v));
}
fn putU8(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u8) !void {
    try buf.append(alloc, v);
}

// Symbol/Scope/Reference 필드별 직렬화(#4438). 일반 struct 의 padding/미초기화 꼬리를
// stream 에서 제외해 결정성을 보장한다. enum 은 `@intFromEnum`, packed struct 는 정수
// 표현으로 쓴다. synthetic_name(슬라이스)은 length-prefixed 텍스트로 인라인 직렬화 —
// 필드별 직렬화는 memcpy 가 아니므로 dangling 위험이 없고, deserialize 가 arena dupe 로 복원.
fn putSymbol(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: Symbol) !void {
    try putU32(buf, alloc, s.name.start);
    try putU32(buf, alloc, s.name.end);
    try putU32(buf, alloc, @backingInt(s.scope_id));
    try putU32(buf, alloc, @backingInt(s.origin_scope));
    try putU8(buf, alloc, @backingInt(s.kind));
    try putU16(buf, alloc, s.decl_flags.toInt());
    try putU32(buf, alloc, s.declaration_span.start);
    try putU32(buf, alloc, s.declaration_span.end);
    try putU32(buf, alloc, s.reference_count);
    try putU32(buf, alloc, s.write_count);
    try putU8(buf, alloc, @backingInt(s.const_kind));
    // ?SyntheticKind → 0xFF=null, 아니면 enum 값(0xFF sentinel과 충돌하지 않음).
    try putU8(buf, alloc, if (s.synthetic_kind) |k| @backingInt(k) else 0xFF);
    try putBytes(buf, alloc, s.synthetic_name);
    try putBytes(buf, alloc, s.output_name_hint);
    try putU8(buf, alloc, @intFromBool(s.requires_uppercase_first_char));
    try putU32(buf, alloc, if (s.synthetic_owner_id) |owner| @backingInt(owner) else NULL_U32);
    try putU32(buf, alloc, @backingInt(s.annex_b_alias.variable));
    try putU32(buf, alloc, @backingInt(s.annex_b_alias.state));
    try putU32(buf, alloc, s.annex_b_alias.source_assignment_count);
    try putU32(buf, alloc, @backingInt(s.parameter_copy.parameter_source));
    try putU32(buf, alloc, @backingInt(s.parameter_copy.state));
    try putU8(buf, alloc, @bitCast(s.binding_instantiation));
}
fn putScope(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: Scope) !void {
    try putU32(buf, alloc, @backingInt(s.parent));
    try putU8(buf, alloc, @backingInt(s.kind));
    try putU8(buf, alloc, @intFromBool(s.is_strict));
    try putU8(buf, alloc, @intFromBool(s.subtree_has_direct_eval));
    try putU8(buf, alloc, @intFromBool(s.subtree_has_with));
    try putU16(buf, alloc, s.symbol_count);
}
fn putReference(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, ref: Reference) !void {
    try putU32(buf, alloc, @backingInt(ref.node_index));
    try putU32(buf, alloc, @backingInt(ref.declaration_node_index));
    try putU32(buf, alloc, @backingInt(ref.scope_id));
    try putU32(buf, alloc, @backingInt(ref.symbol_id));
    try putU32(buf, alloc, ref.stmt_idx);
    try putU32(buf, alloc, ref.scope_stmt_idx);
    try putU8(buf, alloc, @as(u8, @bitCast(ref.flags)));
}

// HashMap 직렬화 (PR3). 모두 `[count][entry…]`. 키 문자열은 putBytes 로 그대로 (deserialize
// 가 arena dupe). 값 usize 는 심볼 인덱스(symbol_ids 와 동일하게 u32 범위)라 u32 로 고정 —
// disk 크기 절감 + host arch 무관.
//
// ⚠️ HashMap iteration 순서는 비결정적이라 정렬 없이 직렬화하면 같은 입력도 byte stream 이
// 달라진다(#4438). 모든 helper 가 키를 정렬(string=lexicographic, u32=오름차순)한 뒤 쓴다.
// 키는 module 내 유일(맵의 키)하므로 정렬이 안정적 total order 를 준다. deserialize 는 순서
// 무관(맵 재구성)이라 짝 변경 불필요.
fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// StringHashMap 의 키를 lexicographic 정렬해 반환(caller free). 빈 맵이면 빈 슬라이스.
/// 키는 맵 내 유일하므로 안정적 total order. 값 조회는 호출자가 `m.get(k)` 로.
fn sortedStrKeys(alloc: std.mem.Allocator, m: anytype) ![]const []const u8 {
    const keys = try alloc.alloc([]const u8, m.count());
    var it = m.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) keys[i] = k.*;
    std.mem.sortUnstable([]const u8, keys, {}, lessThanStr);
    return keys;
}

fn putStrMapUsize(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(usize)) !void {
    try putU32(buf, alloc, m.count());
    const keys = try sortedStrKeys(alloc, m);
    defer alloc.free(keys);
    for (keys) |k| {
        try putBytes(buf, alloc, k);
        try putU32(buf, alloc, @intCast(m.get(k).?));
    }
}
fn putStrMapSpan(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(Span)) !void {
    try putU32(buf, alloc, m.count());
    const keys = try sortedStrKeys(alloc, m);
    defer alloc.free(keys);
    for (keys) |k| {
        const v = m.get(k).?;
        try putBytes(buf, alloc, k);
        try putU32(buf, alloc, v.start);
        try putU32(buf, alloc, v.end);
    }
}
fn putStrSet(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(void)) !void {
    try putU32(buf, alloc, m.count());
    const keys = try sortedStrKeys(alloc, m);
    defer alloc.free(keys);
    for (keys) |k| try putBytes(buf, alloc, k);
}
fn putNumTexts(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.AutoHashMapUnmanaged(u32, []const u8)) !void {
    try putU32(buf, alloc, m.count());
    if (m.count() > 0) {
        const keys = try alloc.alloc(u32, m.count());
        defer alloc.free(keys);
        var it = m.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) keys[i] = k.*;
        std.mem.sortUnstable(u32, keys, {}, std.sort.asc(u32));
        for (keys) |k| {
            try putU32(buf, alloc, k);
            try putBytes(buf, alloc, m.get(k).?);
        }
    }
}

/// semantic 의 relocatable 부분을 `out` 에 직렬화 (append).
pub fn serialize(sem: *const ModuleSemanticData, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    if (!@import("../semantic/annex_b_function.zig").validate(sem.symbols.items)) return error.InvalidAnnexBRole;
    if (!@import("../semantic/parameter_body_var.zig").validate(sem.symbols.items)) return error.InvalidParameterBodyVarRole;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    // Symbol/Scope/Reference 는 일반(non-extern) struct 라 `sliceAsBytes` 통째 memcpy 는
    // struct 꼬리 padding 과 미초기화 바이트를 stream 에 섞어 같은 입력도 byte 가 달라진다
    // (#4438). 필드별로 명시 직렬화해 결정성을 코드 레벨로 보장한다. synthetic_name(슬라이스)은
    // Symbol 직렬화에 포함하지 않고 — memcpy 가 아니므로 dangling 위험 없음 — 텍스트를 직접 쓴다.
    try putU32(&payload, alloc, @intCast(sem.symbols.items.len));
    for (sem.symbols.items) |s| try putSymbol(&payload, alloc, s);

    try putU32(&payload, alloc, @intCast(sem.scopes.len));
    for (sem.scopes) |s| try putScope(&payload, alloc, s);

    try putU32(&payload, alloc, @intCast(sem.symbol_ids.len));
    for (sem.symbol_ids) |id| try putU32(&payload, alloc, if (id) |v| v else NULL_U32);

    try putU32(&payload, alloc, @intCast(sem.references.len));
    for (sem.references) |ref| try putReference(&payload, alloc, ref);

    // HashMap 5개 (PR3). scope_maps 는 scopes 와 동일 인덱스를 공유하는 맵 배열.
    try putU32(&payload, alloc, @intCast(sem.scope_maps.len));
    for (sem.scope_maps) |*m| try putStrMapUsize(&payload, alloc, m);
    try putStrMapSpan(&payload, alloc, &sem.exported_names);
    try putStrSet(&payload, alloc, &sem.unresolved_references);
    try putNumTexts(&payload, alloc, &sem.numeric_const_texts);
    try putStrMapUsize(&payload, alloc, &sem.helper_scope_map);
    try putU32(&payload, alloc, @intCast(sem.scope_owner_map.count()));
    const owner_keys = try alloc.alloc(u32, sem.scope_owner_map.count());
    defer alloc.free(owner_keys);
    var owner_it = sem.scope_owner_map.keyIterator();
    for (owner_keys) |*key| key.* = owner_it.next().?.*;
    std.mem.sortUnstable(u32, owner_keys, {}, std.sort.asc(u32));
    for (owner_keys) |key| {
        try putU32(&payload, alloc, key);
        try putU32(&payload, alloc, sem.scope_owner_map.get(key).?);
    }
    try putU32(&payload, alloc, @intCast(sem.node_scope_provenance.count()));
    const use_keys = try alloc.alloc(u32, sem.node_scope_provenance.count());
    defer alloc.free(use_keys);
    var use_it = sem.node_scope_provenance.keyIterator();
    for (use_keys) |*key| key.* = @backingInt(use_it.next().?.*);
    std.mem.sortUnstable(u32, use_keys, {}, std.sort.asc(u32));
    for (use_keys) |key| {
        const entry = sem.node_scope_provenance.get(@fromBackingInt(key)).?;
        const scope = entry.scope;
        if (entry.source_node.isNone() or @backingInt(entry.source_node) >= sem.symbol_ids.len or key >= sem.symbol_ids.len or scope.isNone() or scope.toIndex() >= sem.scopes.len) return error.Truncated;
        try putU32(&payload, alloc, key);
        try putU32(&payload, alloc, @backingInt(scope));
        try putU32(&payload, alloc, @backingInt(entry.source_node));
        try putU8(&payload, alloc, @intFromBool(entry.with_environment));
    }
    try putU32(&payload, alloc, @intCast(sem.class_self_symbol_map.count()));
    const class_keys = try alloc.alloc(u32, sem.class_self_symbol_map.count());
    defer alloc.free(class_keys);
    var class_it = sem.class_self_symbol_map.keyIterator();
    for (class_keys) |*key| key.* = class_it.next().?.*;
    std.mem.sortUnstable(u32, class_keys, {}, std.sort.asc(u32));
    for (class_keys) |key| {
        try putU32(&payload, alloc, key);
        try putU32(&payload, alloc, sem.class_self_symbol_map.get(key).?);
    }
    try putU32(&payload, alloc, @intCast(sem.namespace_member_owners.count()));
    const ns_keys = try alloc.alloc(u32, sem.namespace_member_owners.count());
    defer alloc.free(ns_keys);
    var ns_it = sem.namespace_member_owners.keyIterator();
    for (ns_keys) |*key| key.* = ns_it.next().?.*;
    std.mem.sortUnstable(u32, ns_keys, {}, std.sort.asc(u32));
    for (ns_keys) |key| {
        try putU32(&payload, alloc, key);
        try putU32(&payload, alloc, sem.namespace_member_owners.get(key).?);
    }
    try putU32(&payload, alloc, @intCast(sem.namespace_declaration_owners.count()));
    const ns_decl_keys = try alloc.alloc(u32, sem.namespace_declaration_owners.count());
    defer alloc.free(ns_decl_keys);
    var ns_decl_it = sem.namespace_declaration_owners.keyIterator();
    for (ns_decl_keys) |*key| key.* = ns_decl_it.next().?.*;
    std.mem.sortUnstable(u32, ns_decl_keys, {}, std.sort.asc(u32));
    for (ns_decl_keys) |key| {
        try putU32(&payload, alloc, key);
        try putU32(&payload, alloc, sem.namespace_declaration_owners.get(key).?);
    }
    try putU32(&payload, alloc, @intFromBool(sem.runtime_identities != null));
    if (sem.runtime_identities) |ids| {
        if (!validRuntimeIdentityLayout(ids.*, sem.symbols.items.len)) return error.Truncated;
        try putRuntimeId(&payload, alloc, ids.cjs_factory);
        try putRuntimeGroup(&CJS_RUNTIME_FIELDS, &payload, alloc, ids.cjs_internal);
        try putRuntimeId(&payload, alloc, ids.esm_factory);
        try putRuntimeGroup(&ESM_RUNTIME_FIELDS, &payload, alloc, ids.esm_internal);
        try putRuntimeId(&payload, alloc, ids.to_binary);
        try putRuntimeGroup(&INTEROP_HELPER_FIELDS, &payload, alloc, ids.interop_helpers);
        try putRuntimeGroup(&INTEROP_INTERNAL_FIELDS, &payload, alloc, ids.interop_internal);
        try putRuntimeGroup(&HMR_RUNTIME_FIELDS, &payload, alloc, ids.hmr_internal);
    }

    try putU32(&payload, alloc, @intCast(sem.strict_output_context.functions.len));
    for (sem.strict_output_context.functions) |role| {
        inline for (@typeInfo(@TypeOf(role)).@"struct".field_names) |name| try putU32(&payload, alloc, @backingInt(@field(role, name)));
    }

    try putU32(&payload, alloc, @backingInt(sem.strict_output_context.program));
    try putU32(&payload, alloc, @backingInt(sem.strict_output_context.directive));

    const checksum = wyhash.hashU64(payload.items);
    try putU32(out, alloc, MAGIC);
    try putU32(out, alloc, FORMAT_VERSION);
    try putU64(out, alloc, checksum);
    try out.appendSlice(alloc, payload.items);
}

// ── deserialize ──────────────────────────────────────────────────────────────

const Reader = codec_io.Reader;

// 각 맵 엔트리는 최소 4바이트(키 길이 prefix `[len:u32]` 또는 u32 키)를 소비한다. 따라서 정상
// 입력이면 `count ≤ remaining/4`. checksum 통과해도 손상 캐시가 거대 count(예: maxInt(u32))를 줄
// 수 있는데, 그대로 `ensureTotalCapacity(count)` 에 넘기면 Zig hash_map 의 capacityForSize 가
// `ceilPowerOfTwo(count) catch unreachable` 라 **OOM degrade 가 아니라 panic** 한다(배열 경로의
// arena.alloc 은 OOM 으로 안전 degrade — 비대칭). 미리 payload 길이로 count 를 상한해 panic 을
// error.Truncated(=miss, 재파싱 fail-safe)로 바꾼다.
const MIN_MAP_ENTRY_BYTES: usize = 4;
fn checkedMapCount(r: *const Reader, n: u32) Error!u32 {
    if (n > r.remaining() / MIN_MAP_ENTRY_BYTES) return error.Truncated;
    return n;
}

// HashMap 역직렬화 (PR3). checksum 통과 후라도 count 는 손상 가능 → `checkedMapCount` 로
// payload 길이 대비 sanity 검증 후 ensureTotalCapacity. 키는 payload 슬라이스를 arena 에 dupe.
fn readStrMapUsize(r: *Reader, arena: std.mem.Allocator) Error!std.StringHashMapUnmanaged(usize) {
    var m: std.StringHashMapUnmanaged(usize) = .empty;
    const n = try checkedMapCount(r, try r.u32v());
    try m.ensureTotalCapacity(arena, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try arena.dupe(u8, try r.bytes());
        m.putAssumeCapacity(key, @intCast(try r.u32v()));
    }
    return m;
}
fn readStrMapSpan(r: *Reader, arena: std.mem.Allocator) Error!std.StringHashMapUnmanaged(Span) {
    var m: std.StringHashMapUnmanaged(Span) = .empty;
    const n = try checkedMapCount(r, try r.u32v());
    try m.ensureTotalCapacity(arena, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try arena.dupe(u8, try r.bytes());
        const start = try r.u32v();
        const end = try r.u32v();
        m.putAssumeCapacity(key, .{ .start = start, .end = end });
    }
    return m;
}
fn readStrSet(r: *Reader, arena: std.mem.Allocator) Error!std.StringHashMapUnmanaged(void) {
    var m: std.StringHashMapUnmanaged(void) = .empty;
    const n = try checkedMapCount(r, try r.u32v());
    try m.ensureTotalCapacity(arena, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try arena.dupe(u8, try r.bytes());
        m.putAssumeCapacity(key, {});
    }
    return m;
}
fn readNumTexts(r: *Reader, arena: std.mem.Allocator) Error!std.AutoHashMapUnmanaged(u32, []const u8) {
    var m: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    const n = try checkedMapCount(r, try r.u32v());
    try m.ensureTotalCapacity(arena, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try r.u32v();
        const text = try arena.dupe(u8, try r.bytes());
        m.putAssumeCapacity(key, text);
    }
    return m;
}

// 작은 스칼라 read — codec_io.Reader 엔 u16/u8 helper 가 없어 take 로 직접.
fn readU16(r: *Reader) Error!u16 {
    return std.mem.bytesToValue(u16, (try r.take(2))[0..2]);
}

// Symbol/Scope/Reference 필드별 역직렬화(#4438 put* 의 짝). 0-init 후 의미 필드만 채운다 —
// padding 은 0 으로 남아 결정적. enum 은 `enums.fromInt`(손상 캐시의 잘못된 tag 도 fail-safe error).
fn readSymbol(r: *Reader, arena: std.mem.Allocator) Error!Symbol {
    var s = std.mem.zeroes(Symbol);
    s.name = .{ .start = try r.u32v(), .end = try r.u32v() };
    s.scope_id = @fromBackingInt(@intCast(try r.u32v()));
    s.origin_scope = @fromBackingInt(@intCast(try r.u32v()));
    s.kind = std.enums.fromInt(symbol_mod.SymbolKind, try r.byte()) orelse return error.Truncated;
    s.decl_flags = symbol_mod.DeclFlags.fromInt(try readU16(r));
    s.declaration_span = .{ .start = try r.u32v(), .end = try r.u32v() };
    s.reference_count = try r.u32v();
    s.write_count = try r.u32v();
    s.const_kind = std.enums.fromInt(symbol_mod.ConstValue.Kind, try r.byte()) orelse return error.Truncated;
    const syn = try r.byte();
    s.synthetic_kind = if (syn == 0xFF) null else (std.enums.fromInt(symbol_mod.SyntheticKind, syn) orelse return error.Truncated);
    const name_text = try r.bytes();
    s.synthetic_name = if (name_text.len == 0) "" else try arena.dupe(u8, name_text);
    const output_name_hint = try r.bytes();
    s.output_name_hint = if (output_name_hint.len == 0) "" else try arena.dupe(u8, output_name_hint);
    s.requires_uppercase_first_char = (try r.byte()) != 0;
    const owner_id = try r.u32v();
    s.synthetic_owner_id = if (owner_id == NULL_U32) null else @fromBackingInt(@intCast(owner_id));
    s.annex_b_alias = .{
        .variable = @fromBackingInt(try r.u32v()),
        .state = std.enums.fromInt(symbol_mod.AnnexBFunctionAlias.State, try r.u32v()) orelse return error.Truncated,
        .source_assignment_count = try r.u32v(),
    };
    s.parameter_copy = .{
        .parameter_source = @fromBackingInt(try r.u32v()),
        .state = std.enums.fromInt(symbol_mod.ParameterBodyVarCopy.State, try r.u32v()) orelse return error.Truncated,
    };
    s.binding_instantiation = @bitCast(try r.byte());
    return s;
}
fn readScope(r: *Reader) Error!Scope {
    var s = std.mem.zeroes(Scope);
    s.parent = @fromBackingInt(@intCast(try r.u32v()));
    s.kind = std.enums.fromInt(scope_mod.ScopeKind, try r.byte()) orelse return error.Truncated;
    s.is_strict = (try r.byte()) != 0;
    s.subtree_has_direct_eval = (try r.byte()) != 0;
    s.subtree_has_with = (try r.byte()) != 0;
    s.symbol_count = try readU16(r);
    return s;
}
fn readReference(r: *Reader) Error!Reference {
    var ref = std.mem.zeroes(Reference);
    ref.node_index = @fromBackingInt(@intCast(try r.u32v()));
    ref.declaration_node_index = @fromBackingInt(@intCast(try r.u32v()));
    ref.scope_id = @fromBackingInt(@intCast(try r.u32v()));
    ref.symbol_id = @fromBackingInt(@intCast(try r.u32v()));
    ref.stmt_idx = try r.u32v();
    ref.scope_stmt_idx = try r.u32v();
    ref.flags = @bitCast(try r.byte());
    return ref;
}

/// `arena` 에 모든 배열·문자열·HashMap 을 alloc 하여 ModuleSemanticData 전체를 복원(PR3 로
/// HashMap 5개 포함). caller 가 `arena.deinit()` 로 일괄 해제(원본 parse_arena 모델과 동일).
/// 검증 실패는 항상 error(fail-safe 재파싱).
///
/// ⚠️ codec 자체는 완전하나 graph 통합(buildIncremental 의 디스크 cache-hit 분기)은 **PR4**
/// 에서 한다 — 무효화 키(버전·옵션·tsconfig·.env) 정합성이 PR5 전까지 미비하므로 그 전에
/// 파이프라인에 연결하면 stale 캐시로 잘못된 결과가 나온다. 현재는 codec 단위 테스트 전용.
pub fn deserialize(data: []const u8, arena: std.mem.Allocator) Error!ModuleSemanticData {
    if (data.len < HEADER_LEN) return error.Truncated;
    if (std.mem.bytesToValue(u32, data[0..4]) != MAGIC) return error.BadMagic;
    if (std.mem.bytesToValue(u32, data[4..8]) != FORMAT_VERSION) return error.UnsupportedVersion;
    const checksum = std.mem.bytesToValue(u64, data[8..16]);
    const payload = data[HEADER_LEN..];
    if (wyhash.hashU64(payload) != checksum) return error.ChecksumMismatch;

    var r = Reader{ .buf = payload };

    // 필드별 역직렬화(#4438 put* 의 짝). 각 배열은 `[count]` 후 레코드별 명시 read.
    // 손상 캐시가 거대 count 를 줘도: (1) **배열**(arena.alloc) 경로는 OutOfMemory 로 안전
    // degrade 하고 read 도중 take 의 경계검사가 Truncated 를 낸다(OOB read 불가). (2) **HashMap**
    // 경로는 `ensureTotalCapacity(count)` 가 capacityForSize 의 `ceilPowerOfTwo catch unreachable`
    // 로 panic 할 수 있어 비대칭이므로, readStr*/readNumTexts 가 `checkedMapCount` 로 payload 길이
    // 대비 count 를 먼저 상한(엔트리당 ≥4B)해 panic 을 Truncated(=miss, 재파싱)로 바꾼다 → 둘 다 fail-safe.
    const symbols_len = try r.u32v();
    const symbols_slice = try arena.alloc(Symbol, symbols_len);
    for (symbols_slice) |*s| s.* = try readSymbol(&r, arena);
    if (!@import("../semantic/annex_b_function.zig").validate(symbols_slice)) return error.Truncated;
    if (!@import("../semantic/parameter_body_var.zig").validate(symbols_slice)) return error.Truncated;

    const scopes_len = try r.u32v();
    const scopes = try arena.alloc(Scope, scopes_len);
    for (scopes) |*s| s.* = try readScope(&r);

    const symbol_ids_len = try r.u32v();
    const symbol_ids = try arena.alloc(?u32, symbol_ids_len);
    for (symbol_ids) |*id| {
        const v = try r.u32v();
        id.* = if (v == NULL_U32) null else v;
    }

    const references_len = try r.u32v();
    const references = try arena.alloc(Reference, references_len);
    for (references) |*ref| ref.* = try readReference(&r);

    // HashMap 5개 (PR3). scope_maps 는 맵 배열 — 길이만큼 alloc 후 각 맵 복원.
    const scope_maps_len = try r.u32v();
    const scope_maps = try arena.alloc(std.StringHashMapUnmanaged(usize), scope_maps_len);
    for (scope_maps) |*m| m.* = try readStrMapUsize(&r, arena);
    const exported_names = try readStrMapSpan(&r, arena);
    const unresolved_references = try readStrSet(&r, arena);
    const numeric_const_texts = try readNumTexts(&r, arena);
    const helper_scope_map = try readStrMapUsize(&r, arena);
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const owner_count = try checkedMapCount(&r, try r.u32v());
    try scope_owner_map.ensureTotalCapacity(arena, owner_count);
    for (0..owner_count) |_| {
        const key = try r.u32v();
        const value = try r.u32v();
        if (key >= symbol_ids_len or value >= scopes_len or scope_owner_map.contains(key)) return error.Truncated;
        scope_owner_map.putAssumeCapacity(key, value);
    }
    var node_scope_provenance: @import("../semantic/node_scope_provenance.zig").Map = .empty;
    const use_count = try checkedMapCount(&r, try r.u32v());
    try node_scope_provenance.ensureTotalCapacity(arena, use_count);
    for (0..use_count) |_| {
        const key = try r.u32v();
        const scope = try r.u32v();
        const node: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(key);
        if (key >= symbol_ids_len or scope >= scopes_len or node_scope_provenance.contains(node)) return error.Truncated;
        const source_node = try r.u32v();
        if (source_node >= symbol_ids_len) return error.Truncated;
        const with_environment = (try r.take(1))[0];
        if (with_environment > 1) return error.Truncated;
        node_scope_provenance.putAssumeCapacity(node, .{ .scope = @fromBackingInt(scope), .source_node = @fromBackingInt(source_node), .with_environment = with_environment != 0 });
    }
    var class_self_symbol_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const class_count = try checkedMapCount(&r, try r.u32v());
    try class_self_symbol_map.ensureTotalCapacity(arena, class_count);
    for (0..class_count) |_| {
        const key = try r.u32v();
        const value = try r.u32v();
        if (key >= symbol_ids_len or value >= symbols_len or class_self_symbol_map.contains(key)) return error.Truncated;
        class_self_symbol_map.putAssumeCapacity(key, value);
    }
    var namespace_member_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const ns_count = try checkedMapCount(&r, try r.u32v());
    try namespace_member_owners.ensureTotalCapacity(arena, ns_count);
    for (0..ns_count) |_| {
        const key = try r.u32v();
        const value = try r.u32v();
        if (key >= symbols_len or value >= symbols_len or namespace_member_owners.contains(key)) return error.Truncated;
        namespace_member_owners.putAssumeCapacity(key, value);
    }
    var namespace_declaration_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const ns_decl_count = try checkedMapCount(&r, try r.u32v());
    try namespace_declaration_owners.ensureTotalCapacity(arena, ns_decl_count);
    for (0..ns_decl_count) |_| {
        const key = try r.u32v();
        const value = try r.u32v();
        if (key >= symbols_len or value >= symbols_len or namespace_declaration_owners.contains(key)) return error.Truncated;
        namespace_declaration_owners.putAssumeCapacity(key, value);
    }

    var runtime_identities: ?*module.RuntimeIdentitySnapshot = null;
    const has_runtime_ids = try r.u32v();
    if (has_runtime_ids > 1) return error.Truncated;
    if (has_runtime_ids == 1) {
        const snapshot: module.RuntimeIdentitySnapshot = .{
            .cjs_factory = try readRuntimeId(&r, symbols_len),
            .cjs_internal = try readRuntimeGroup(module.CjsRuntimeInternalSymbolIds, &CJS_RUNTIME_FIELDS, &r, symbols_len),
            .esm_factory = try readRuntimeId(&r, symbols_len),
            .esm_internal = try readRuntimeGroup(module.EsmRuntimeInternalSymbolIds, &ESM_RUNTIME_FIELDS, &r, symbols_len),
            .to_binary = try readRuntimeId(&r, symbols_len),
            .interop_helpers = try readRuntimeGroup(module.EsmInteropRuntimeHelperSymbolIds, &INTEROP_HELPER_FIELDS, &r, symbols_len),
            .interop_internal = try readRuntimeGroup(module.EsmInteropRuntimeInternalSymbolIds, &INTEROP_INTERNAL_FIELDS, &r, symbols_len),
            .hmr_internal = try readRuntimeGroup(module.HmrRuntimeInternalSymbolIds, &HMR_RUNTIME_FIELDS, &r, symbols_len),
        };
        if (!validRuntimeIdentityLayout(snapshot, symbols_len)) return error.Truncated;
        runtime_identities = try arena.create(module.RuntimeIdentitySnapshot);
        runtime_identities.?.* = snapshot;
    }
    const strict_count = try r.u32v();
    if (strict_count > r.remaining() / (@typeInfo(@import("strict_function_context.zig").Role).@"struct".field_names.len * 4)) return error.Truncated;
    const strict_roles = try arena.alloc(@import("strict_function_context.zig").Role, strict_count);
    for (strict_roles) |*role| {
        inline for (@typeInfo(@TypeOf(role.*)).@"struct".field_names) |name| @field(role, name) = @fromBackingInt(try r.u32v());
        if ((role.kind != .factory and role.kind != .body_directive) or
            (role.name_role != .binding and role.name_role != .anonymous_default) or
            role.symbol.isNone() or @backingInt(role.symbol) >= symbols_len or
            role.source_scope.isNone() or role.source_scope.toIndex() >= scopes.len or role.lexical_root.isNone() or role.lexical_root.toIndex() >= scopes.len) return error.Truncated;
        if (role.kind == .factory and (role.factory_scope.isNone() or role.factory_scope.toIndex() >= scopes.len)) return error.Truncated;
        if (role.kind == .body_directive and !role.factory_scope.isNone()) return error.Truncated;
    }
    const strict_program: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    const strict_directive: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    if (strict_program.isNone() != strict_directive.isNone() or (strict_program.isNone() and strict_roles.len != 0)) return error.Truncated;
    if (r.remaining() != 0) return error.Truncated;

    return .{
        .owner_token = .unassigned, // Memory ownership cannot survive decode.
        .symbols = .{ .items = symbols_slice, .capacity = symbols_slice.len, .pointer_stability = .{} },
        .scopes = scopes,
        .scope_maps = scope_maps,
        .exported_names = exported_names,
        .symbol_ids = symbol_ids,
        .unresolved_references = unresolved_references,
        .references = references,
        .numeric_const_texts = numeric_const_texts,
        .helper_scope_map = helper_scope_map,
        .scope_owner_map = scope_owner_map,
        .node_scope_provenance = node_scope_provenance,
        .class_self_symbol_map = class_self_symbol_map,
        .namespace_member_owners = namespace_member_owners,
        .namespace_declaration_owners = namespace_declaration_owners,
        .runtime_identities = runtime_identities,
        .strict_output_context = .{ .program = strict_program, .directive = strict_directive, .functions = strict_roles },
    };
}
