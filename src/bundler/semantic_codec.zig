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
// v26: lowered Annex B catch carriers preserve their exact lexical binding.
// v27: source-owned typed retirement graph state survives cache round trips.
// v39: exact producer-owned static capture aliases retain their retirement proof.
// v43: extracted await-loop source witnesses and function-name environment retirements.
// v49: class-key, Worklet, enum-member and explicit-drop proofs share one wire layout.
pub const FORMAT_VERSION: u32 = 51;
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
    @setEvalBranchQuota(3000);
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
    if (@typeInfo(@import("../semantic/node_scope_provenance.zig").Entry).@"struct".field_names.len != 5) @compileError("expression provenance fields changed; update semantic codec");
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
    const Retirement = @import("../semantic/source_owned_retirement.zig").Witness;
    const retirement_fields = [_][]const u8{ "symbol_id", "before", "declaration", "declaration_node", "source_owner", "source_owner_node", "source_scope", "source_parent", "source_name", "source_name_symbol", "closure_scope", "closure_parent", "reason", "erased_import", "static_capture_alias", "function_name_elision", "enum_environment", "dropped_statement", "inlined_binding" };
    if (@typeInfo(Retirement).@"struct".field_names.len != retirement_fields.len) @compileError("source retirement wire fields changed; update codec/version");
    for (retirement_fields, @typeInfo(Retirement).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("source retirement wire order changed; update codec/version");
    const InlineBinding = @import("../semantic/inlined_binding_retirement.zig").Witness;
    const inline_fields = [_][]const u8{ "declarator", "declarator_node", "initializer", "read", "read_node", "read_reference", "statement_kind", "source_epoch", "source_frame", "read_frame" };
    if (@typeInfo(InlineBinding).@"struct".field_names.len != inline_fields.len) @compileError("inline binding wire fields changed; update codec/version");
    for (inline_fields, @typeInfo(InlineBinding).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("inline binding wire order changed; update codec/version");
    const StaticAlias = @import("../semantic/static_capture_retirement.zig").Witness;
    const static_alias_fields = [_][]const u8{ "statement", "statement_node", "declarator", "declarator_node", "initializer", "initializer_node", "read", "read_node", "class_binding_node", "class_before", "class_scope", "replacement" };
    if (@typeInfo(StaticAlias).@"struct".field_names.len != static_alias_fields.len) @compileError("static capture wire fields changed; update codec/version");
    for (static_alias_fields, @typeInfo(StaticAlias).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("static capture wire order changed; update codec/version");
    if (std.enums.values(@FieldType(Retirement, "reason")).len != 8) @compileError("source retirement reason tags changed; update codec/version");
    const NameElision = @import("../semantic/function_name_retirement.zig");
    const name_witness_fields = [_][]const u8{ "event", "name_scope", "parameter_scope", "retire_parameters", "body_scope", "outer_scope", "name_frame", "parameter_frame", "body_frame", "formals", "engine", "owners" };
    if (@typeInfo(NameElision.Witness).@"struct".field_names.len != name_witness_fields.len) @compileError("name retirement wire fields changed; update codec/version");
    for (name_witness_fields, @typeInfo(NameElision.Witness).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("name retirement wire order changed; update codec/version");
    const name_event_fields = [_][]const u8{ "owner", "owner_node", "name", "name_node", "symbol_id", "parameters", "body" };
    if (@typeInfo(NameElision.Elision).@"struct".field_names.len != name_event_fields.len) @compileError("name event wire fields changed; update codec/version");
    for (name_event_fields, @typeInfo(NameElision.Elision).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("name event wire order changed; update codec/version");
    const formal_fields = [_][]const u8{ "binding", "node", "symbol_id", "before", "declaration" };
    if (@typeInfo(NameElision.Formal).@"struct".field_names.len != formal_fields.len) @compileError("formal wire fields changed; update codec/version");
    for (formal_fields, @typeInfo(NameElision.Formal).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("formal wire order changed; update codec/version");
    const engine_fields = [_][]const u8{ "symbol_id", "before", "declaration" };
    if (@typeInfo(NameElision.Engine).@"struct".field_names.len != engine_fields.len) @compileError("engine wire fields changed; update codec/version");
    for (engine_fields, @typeInfo(NameElision.Engine).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("engine wire order changed; update codec/version");
    const alias_fields = [_][]const u8{ "scope", "owner" };
    if (@typeInfo(NameElision.OwnerAlias).@"struct".field_names.len != alias_fields.len) @compileError("name owner alias wire fields changed; update codec/version");
    for (alias_fields, @typeInfo(NameElision.OwnerAlias).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("name owner alias wire order changed; update codec/version");
    const SourceExternal = @import("../semantic/source_external_origin.zig").Origin;
    const source_external_fields = [_][]const u8{ "tag", "name", "span", "flags", "source_scope", "source_frame", "execution_scope", "execution_frame", "scope_moves", "jsx_reference" };
    if (@typeInfo(SourceExternal).@"struct".field_names.len != source_external_fields.len) @compileError("source external fields changed; update codec/version");
    for (source_external_fields, @typeInfo(SourceExternal).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("source external wire order changed; update codec/version");
    const ScopeMove = @import("../semantic/source_external_origin.zig").ScopeMove;
    const FrameHistory = @import("../semantic/scope_frame_history.zig");
    const LoweredWorklet = @import("../semantic/lowered_worklet_class.zig");
    const history_types = .{ FrameHistory.History, FrameHistory.Event, FrameHistory.Owner, FrameHistory.OwnerBinding, FrameHistory.Actor, FrameHistory.ClassKeySource, @import("../semantic/class_key_evaluation.zig").Transfer, LoweredWorklet.Class, LoweredWorklet.Function, LoweredWorklet.Creator, LoweredWorklet.Witness };
    const history_fields = .{
        &.{ "source_scopes", "source_owners", "source_initializers", "source_computed_awaits", "source_class_keys", "worklet_class_creators", "lowered_worklet_classes", "source_dropped_statements", "source_drop_edges", "events" },
        &.{ "kind", "scope", "before", "after", "owner_before", "owner_after", "owner_edges", "trigger_scope", "trigger_parent", "parent_owner", "actor" },
        &.{ "node", "tag", "span", "words" },
        &.{ "scope", "owner", "edges" },
        &.{ "role", "module_index" },
        &.{ "scope", "class_owner", "body", "member", "member_slot", "key", "leaf" },
        &.{ "source_index", "evaluation_scope", "capture_epoch" },
        &.{ "node", "body", "name", "scope", "self" },
        &.{ "node", "name", "params", "body", "scope", "parent", "declaration", "symbol" },
        &.{ "source", "target", "factory", "factory_binding", "factory_symbol", "factory_scope", "wrapper_scope", "epoch" },
        &.{ "creator_index", "source", "target", "factory", "wrapper_scope", "constructor", "iife", "creator_epoch", "lowered_epoch" },
    };
    for (history_types, history_fields) |T, expected_fields| {
        const actual_fields = @typeInfo(T).@"struct".field_names;
        if (actual_fields.len != expected_fields.len) @compileError("scope history wire fields changed; update codec/version");
        for (actual_fields, expected_fields) |actual, expected| if (!std.mem.eql(u8, actual, expected)) @compileError("scope history wire order changed; update codec/version");
    }
    const edge_fields = [_][]const u8{ "parameters", "body", "heritage" };
    for (@typeInfo(FrameHistory.SourceEdges).@"struct".field_names, edge_fields) |actual, expected| if (!std.mem.eql(u8, actual, expected)) @compileError("source edges wire fields changed");
    const scope_move_fields = [_][]const u8{ "node", "source_node", "from", "to", "from_frame", "to_frame", "reason", "elision", "static_block", "generator", "class_heritage", "class_initializer", "class_key", "frame_epoch" };
    if (@typeInfo(ScopeMove).@"struct".field_names.len != scope_move_fields.len) @compileError("source scope move fields changed; update codec/version");
    for (scope_move_fields, @typeInfo(ScopeMove).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("source scope move wire order changed; update codec/version");
    if (std.enums.values(@FieldType(ScopeMove, "reason")).len != 7) @compileError("source scope move reason changed; update codec/version");
    const GeneratorTransfer = @import("../semantic/generator_environment_transfer.zig");
    const generator_fields = [_][]const u8{ "source", "callback", "callback_scope", "parameters", "body", "state_parameter", "birth_epoch", "heritage", "computed_await_source" };
    for (@typeInfo(GeneratorTransfer.Transfer).@"struct".field_names, generator_fields) |actual, expected| if (!std.mem.eql(u8, actual, expected)) @compileError("generator transfer wire fields changed");
    const generator_heritage_fields = [_][]const u8{ "owner", "scope", "heritage", "await_node", "read" };
    for (@typeInfo(GeneratorTransfer.HeritageRead).@"struct".field_names, generator_heritage_fields) |actual, expected| if (!std.mem.eql(u8, actual, expected)) @compileError("generator heritage read wire fields changed");
    const generator_source_fields = [_][]const u8{ "owner", "scope", "parameters", "body", "extracted_loop" };
    for (@typeInfo(GeneratorTransfer.Source).@"struct".field_names, generator_source_fields) |actual, expected| if (!std.mem.eql(u8, actual, expected)) @compileError("generator source wire fields changed");
    const ClassHeritage = @import("../semantic/source_external_origin.zig").ClassHeritageTransfer;
    const heritage_fields = [_][]const u8{ "owner", "class_scope", "heritage", "evaluation_scope", "capture_epoch" };
    for (@typeInfo(ClassHeritage).@"struct".field_names, heritage_fields) |actual, expected| if (!std.mem.eql(u8, actual, expected)) @compileError("class heritage wire fields changed");
    const StaticTransfer = @import("../semantic/source_external_origin.zig").StaticBlockTransfer;
    const static_fields = [_][]const u8{ "source_owner", "target_owner", "source_body", "parameters", "output_body", "birth_epoch" };
    if (@typeInfo(StaticTransfer).@"struct".field_names.len != static_fields.len) @compileError("static block handoff fields changed; update codec/version");
    for (static_fields, @typeInfo(StaticTransfer).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("static block handoff wire order changed; update codec/version");
    const Erasure = @import("../semantic/import_erasure.zig");
    const import_fields = [_][]const u8{ "declaration", "declaration_node", "specifier", "specifier_node", "local", "local_node", "declaration_type_only", "specifier_type_only", "policy" };
    if (@typeInfo(Erasure.Binding).@"struct".field_names.len != import_fields.len) @compileError("import erasure fields changed; update codec/version");
    for (import_fields, @typeInfo(Erasure.Binding).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("import erasure wire order changed; update codec/version");
    const external_fields = [_][]const u8{ "binding_symbol", "before", "before_tag", "before_name", "before_span" };
    if (@typeInfo(Erasure.ExternalOrigin).@"struct".field_names.len != external_fields.len) @compileError("import external origin fields changed; update codec/version");
    for (external_fields, @typeInfo(Erasure.ExternalOrigin).@"struct".field_names) |expected, actual| if (!std.mem.eql(u8, expected, actual)) @compileError("import origin wire order changed; update codec/version");
    if (@backingInt(@FieldType(Retirement, "reason").source_function_closure) != 0 or @backingInt(@FieldType(Retirement, "reason").erased_import_binding) != 1 or @backingInt(@FieldType(Retirement, "reason").erased_const_enum_binding) != 2 or @backingInt(@FieldType(Retirement, "reason").static_class_capture_alias) != 3 or std.enums.values(@FieldType(Erasure.Binding, "policy")).len != 3) @compileError("import erasure wire tags changed; update codec/version");
    if (@typeInfo(ModuleSemanticData).@"struct".field_names.len != 19) {
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

fn putRetirementNode(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, node: @import("../parser/ast.zig").Node) !void {
    switch (node.tag) {
        .binding_identifier, .identifier_reference, .import_default_specifier, .import_namespace_specifier, .function_declaration, .function_expression, .arrow_function_expression, .ts_enum_declaration, .import_declaration, .import_specifier, .class_declaration, .class_expression, .variable_declaration, .variable_declarator, .labeled_statement, .expression_statement, .debugger_statement => {},
        else => return error.InvalidSourceOwnedRetirement,
    }
    try putU32(buf, alloc, @backingInt(node.tag));
    try putU32(buf, alloc, node.span.start);
    try putU32(buf, alloc, node.span.end);
    switch (node.tag) {
        .binding_identifier, .identifier_reference, .import_default_specifier, .import_namespace_specifier => {
            try putU32(buf, alloc, node.data.string_ref.start);
            try putU32(buf, alloc, node.data.string_ref.end);
        },
        .import_specifier, .labeled_statement => {
            try putU32(buf, alloc, @backingInt(node.data.binary.left));
            try putU32(buf, alloc, @backingInt(node.data.binary.right));
            try putU32(buf, alloc, node.data.binary.flags);
        },
        .expression_statement => {
            try putU32(buf, alloc, @backingInt(node.data.unary.operand));
            try putU32(buf, alloc, node.data.unary.flags);
        },
        .debugger_statement => try putU32(buf, alloc, node.data.none),
        else => try putU32(buf, alloc, node.data.extra),
    }
}

fn readRetirementNode(r: *Reader, declaration: bool) Error!@import("../parser/ast.zig").Node {
    const Node = @import("../parser/ast.zig").Node;
    const tag = std.enums.fromInt(Node.Tag, try r.u32v()) orelse return error.Truncated;
    if (declaration) switch (tag) {
        .binding_identifier, .identifier_reference, .import_default_specifier, .import_namespace_specifier => {},
        else => return error.Truncated,
    } else switch (tag) {
        .function_declaration, .function_expression, .arrow_function_expression, .ts_enum_declaration, .import_declaration, .import_specifier, .import_default_specifier, .import_namespace_specifier, .class_declaration, .class_expression, .variable_declaration, .variable_declarator, .labeled_statement, .expression_statement, .debugger_statement => {},
        else => return error.Truncated,
    }
    var node: Node = .{ .tag = tag, .span = .{ .start = try r.u32v(), .end = try r.u32v() }, .data = std.mem.zeroes(Node.Data) };
    switch (tag) {
        .binding_identifier, .identifier_reference, .import_default_specifier, .import_namespace_specifier => node.data.string_ref = .{ .start = try r.u32v(), .end = try r.u32v() },
        .import_specifier, .labeled_statement => {
            const left = try r.u32v();
            const right = try r.u32v();
            const flags = std.math.cast(u16, try r.u32v()) orelse return error.Truncated;
            node.data.binary = .{ .left = @fromBackingInt(left), .right = @fromBackingInt(right), .flags = flags };
        },
        .expression_statement => {
            const operand = try r.u32v();
            const flags = std.math.cast(u16, try r.u32v()) orelse return error.Truncated;
            node.data.unary = .{ .operand = @fromBackingInt(operand), .flags = flags };
        },
        .debugger_statement => node.data.none = try r.u32v(),
        else => node.data.extra = try r.u32v(),
    }
    return node;
}

fn putInlineNode(buf: *std.ArrayList(u8), a: std.mem.Allocator, node: @import("../parser/ast.zig").Node) !void {
    try putU32(buf, a, @backingInt(node.tag));
    try putU32(buf, a, node.span.start);
    try putU32(buf, a, node.span.end);
    switch (@import("../parser/ast.zig").Node.Tag.dataKind(node.tag)) {
        .extra => try putU32(buf, a, node.data.extra),
        .list => {
            try putU32(buf, a, node.data.list.start);
            try putU32(buf, a, node.data.list.len);
        },
        .unary => {
            try putU32(buf, a, @backingInt(node.data.unary.operand));
            try putU32(buf, a, node.data.unary.flags);
        },
        .binary => {
            try putU32(buf, a, @backingInt(node.data.binary.left));
            try putU32(buf, a, @backingInt(node.data.binary.right));
            try putU32(buf, a, node.data.binary.flags);
        },
        .ternary => {
            try putU32(buf, a, @backingInt(node.data.ternary.a));
            try putU32(buf, a, @backingInt(node.data.ternary.b));
            try putU32(buf, a, @backingInt(node.data.ternary.c));
        },
        .leaf => {
            try putU32(buf, a, node.data.none);
            if (@import("../parser/ast.zig").Node.Tag.dataWidth(node.tag) == 8) try putU32(buf, a, node.data.string_ref.end);
        },
    }
}
fn readInlineNode(r: *Reader) Error!@import("../parser/ast.zig").Node {
    const Node = @import("../parser/ast.zig").Node;
    const tag = std.enums.fromInt(Node.Tag, try r.u32v()) orelse return error.Truncated;
    var node: Node = .{ .tag = tag, .span = .{ .start = try r.u32v(), .end = try r.u32v() }, .data = std.mem.zeroes(Node.Data) };
    if (node.span.start > node.span.end) return error.Truncated;
    switch (Node.Tag.dataKind(tag)) {
        .extra => node.data.extra = try r.u32v(),
        .list => node.data.list = .{ .start = try r.u32v(), .len = try r.u32v() },
        .unary => node.data.unary = .{ .operand = @fromBackingInt(try r.u32v()), .flags = std.math.cast(u16, try r.u32v()) orelse return error.Truncated },
        .binary => node.data.binary = .{ .left = @fromBackingInt(try r.u32v()), .right = @fromBackingInt(try r.u32v()), .flags = std.math.cast(u16, try r.u32v()) orelse return error.Truncated },
        .ternary => node.data.ternary = .{ .a = @fromBackingInt(try r.u32v()), .b = @fromBackingInt(try r.u32v()), .c = @fromBackingInt(try r.u32v()) },
        .leaf => {
            node.data.none = try r.u32v();
            if (Node.Tag.dataWidth(tag) == 8) node.data.string_ref.end = try r.u32v();
        },
    }
    return node;
}
fn putInlinedBinding(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: @import("../semantic/inlined_binding_retirement.zig").Witness) !void {
    try putU32(buf, a, @backingInt(value.declarator));
    try putInlineNode(buf, a, value.declarator_node);
    try putU32(buf, a, @backingInt(value.initializer));
    try putU32(buf, a, @backingInt(value.read));
    try putInlineNode(buf, a, value.read_node);
    try putReference(buf, a, value.read_reference);
    try putU32(buf, a, value.statement_kind);
    try putU32(buf, a, value.source_epoch);
    try putScope(buf, a, value.source_frame);
    try putScope(buf, a, value.read_frame);
}
fn readInlinedBinding(r: *Reader, node_count: usize, scope_count: usize, symbol_count: usize, epoch: usize) Error!@import("../semantic/inlined_binding_retirement.zig").Witness {
    const value: @import("../semantic/inlined_binding_retirement.zig").Witness = .{
        .declarator = @fromBackingInt(try r.u32v()),
        .declarator_node = try readInlineNode(r),
        .initializer = @fromBackingInt(try r.u32v()),
        .read = @fromBackingInt(try r.u32v()),
        .read_node = try readInlineNode(r),
        .read_reference = try readReference(r),
        .statement_kind = try r.u32v(),
        .source_epoch = try r.u32v(),
        .source_frame = try readScope(r),
        .read_frame = try readScope(r),
    };
    inline for (.{ value.declarator, value.initializer, value.read }) |node| if (node.isNone() or @backingInt(node) >= node_count) return error.Truncated;
    if (value.declarator_node.tag != .variable_declarator or value.read_node.tag != .identifier_reference or
        value.source_epoch > epoch or value.read_reference.scope_id.isNone() or value.read_reference.scope_id.toIndex() >= scope_count or
        value.read_reference.symbol_id.isNone() or @backingInt(value.read_reference.symbol_id) >= symbol_count) return error.Truncated;
    inline for (.{ value.source_frame, value.read_frame }) |frame| if (!frame.parent.isNone() and frame.parent.toIndex() >= scope_count) return error.Truncated;
    return value;
}

fn putStaticCaptureAlias(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: @import("../semantic/static_capture_retirement.zig").Witness) !void {
    try putU32(buf, a, @backingInt(value.statement));
    try putRetirementNode(buf, a, value.statement_node);
    try putU32(buf, a, @backingInt(value.declarator));
    try putRetirementNode(buf, a, value.declarator_node);
    try putReference(buf, a, value.initializer);
    try putRetirementNode(buf, a, value.initializer_node);
    try putReference(buf, a, value.read);
    try putRetirementNode(buf, a, value.read_node);
    try putRetirementNode(buf, a, value.class_binding_node);
    try putSymbol(buf, a, value.class_before);
    try putU32(buf, a, @backingInt(value.class_scope));
    try putReference(buf, a, value.replacement);
}

fn readStaticCaptureAlias(r: *Reader, a: std.mem.Allocator) Error!@import("../semantic/static_capture_retirement.zig").Witness {
    return .{
        .statement = @fromBackingInt(try r.u32v()),
        .statement_node = try readRetirementNode(r, false),
        .declarator = @fromBackingInt(try r.u32v()),
        .declarator_node = try readRetirementNode(r, false),
        .initializer = try readReference(r),
        .initializer_node = try readRetirementNode(r, true),
        .read = try readReference(r),
        .read_node = try readRetirementNode(r, true),
        .class_binding_node = try readRetirementNode(r, true),
        .class_before = try readSymbol(r, a),
        .class_scope = @fromBackingInt(try r.u32v()),
        .replacement = try readReference(r),
    };
}

fn putFunctionNameElision(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: @import("../semantic/function_name_retirement.zig").Witness) !void {
    const e = value.event;
    try putU32(buf, a, @backingInt(e.owner));
    try putRetirementNode(buf, a, e.owner_node);
    try putU32(buf, a, @backingInt(e.name));
    try putRetirementNode(buf, a, e.name_node);
    try putU32(buf, a, @backingInt(e.symbol_id));
    try putU32(buf, a, @backingInt(e.parameters));
    try putU32(buf, a, @backingInt(e.body));
    inline for (.{ value.name_scope, value.parameter_scope, value.body_scope, value.outer_scope }) |scope| try putU32(buf, a, @backingInt(scope));
    try putU32(buf, a, @intFromBool(value.retire_parameters));
    inline for (.{ value.name_frame, value.parameter_frame, value.body_frame }) |frame| try putScope(buf, a, frame);
    try putU32(buf, a, @intCast(value.formals.len));
    for (value.formals) |formal| {
        try putU32(buf, a, @backingInt(formal.binding));
        try putRetirementNode(buf, a, formal.node);
        try putU32(buf, a, @backingInt(formal.symbol_id));
        try putSymbol(buf, a, formal.before);
        try putReference(buf, a, formal.declaration);
    }
    try putU32(buf, a, @intFromBool(value.engine != null));
    if (value.engine) |engine| {
        try putU32(buf, a, @backingInt(engine.symbol_id));
        try putSymbol(buf, a, engine.before);
        try putReference(buf, a, engine.declaration);
    }
    try putU32(buf, a, @intCast(value.owners.len));
    for (value.owners) |alias| {
        try putU32(buf, a, @backingInt(alias.scope));
        try putFrameOwner(buf, a, alias.owner);
    }
}

fn readFunctionNameElision(r: *Reader, a: std.mem.Allocator) Error!@import("../semantic/function_name_retirement.zig").Witness {
    const Names = @import("../semantic/function_name_retirement.zig");
    var result: Names.Witness = .{ .event = .{ .owner = @fromBackingInt(try r.u32v()), .owner_node = try readRetirementNode(r, false), .name = @fromBackingInt(try r.u32v()), .name_node = try readRetirementNode(r, true), .symbol_id = @fromBackingInt(try r.u32v()), .parameters = @fromBackingInt(try r.u32v()), .body = @fromBackingInt(try r.u32v()) }, .name_scope = @fromBackingInt(try r.u32v()), .parameter_scope = @fromBackingInt(try r.u32v()), .body_scope = @fromBackingInt(try r.u32v()), .outer_scope = @fromBackingInt(try r.u32v()), .retire_parameters = blk: {
        const flag = try r.u32v();
        if (flag > 1) return error.Truncated;
        break :blk flag == 1;
    }, .name_frame = try readScope(r), .parameter_frame = try readScope(r), .body_frame = try readScope(r), .formals = &.{}, .engine = null, .owners = &.{} };
    const count = try r.u32v();
    if (count > r.remaining() / 4) return error.Truncated;
    const formals = try a.alloc(Names.Formal, count);
    for (formals) |*formal| formal.* = .{ .binding = @fromBackingInt(try r.u32v()), .node = try readRetirementNode(r, true), .symbol_id = @fromBackingInt(try r.u32v()), .before = try readSymbol(r, a), .declaration = try readReference(r) };
    result.formals = formals;
    const has_engine = try r.u32v();
    if (has_engine > 1) return error.Truncated;
    if (has_engine == 1) result.engine = .{ .symbol_id = @fromBackingInt(try r.u32v()), .before = try readSymbol(r, a), .declaration = try readReference(r) };
    const owner_count = try r.u32v();
    if (owner_count > r.remaining() / 4) return error.Truncated;
    const aliases = try a.alloc(Names.OwnerAlias, owner_count);
    for (aliases) |*alias| alias.* = .{ .scope = @fromBackingInt(try r.u32v()), .owner = try readFrameOwner(r) };
    result.owners = aliases;
    return result;
}

fn putImportErasure(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, binding: @import("../semantic/import_erasure.zig").Binding) !void {
    try putU32(buf, alloc, @backingInt(binding.declaration));
    try putRetirementNode(buf, alloc, binding.declaration_node);
    try putU32(buf, alloc, @backingInt(binding.specifier));
    try putRetirementNode(buf, alloc, binding.specifier_node);
    try putU32(buf, alloc, @backingInt(binding.local));
    try putRetirementNode(buf, alloc, binding.local_node);
    try putU32(buf, alloc, @intFromBool(binding.declaration_type_only));
    try putU32(buf, alloc, @intFromBool(binding.specifier_type_only));
    try putU32(buf, alloc, @backingInt(binding.policy));
}

fn readImportErasure(r: *Reader) Error!@import("../semantic/import_erasure.zig").Binding {
    const Binding = @import("../semantic/import_erasure.zig").Binding;
    const declaration: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    const declaration_node = try readRetirementNode(r, false);
    const specifier: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    const specifier_node = try readRetirementNode(r, false);
    const local: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    const local_node = try readRetirementNode(r, true);
    const type_only = try r.u32v();
    const inline_type = try r.u32v();
    const policy = std.enums.fromInt(@FieldType(Binding, "policy"), try r.u32v()) orelse return error.Truncated;
    if (type_only > 1 or inline_type > 1 or declaration_node.tag != .import_declaration) return error.Truncated;
    return .{ .declaration = declaration, .declaration_node = declaration_node, .specifier = specifier, .specifier_node = specifier_node, .local = local, .local_node = local_node, .declaration_type_only = type_only != 0, .specifier_type_only = inline_type != 0, .policy = policy };
}

fn putFrameOwner(buf: *std.ArrayList(u8), a: std.mem.Allocator, owner: @import("../semantic/scope_frame_history.zig").Owner) !void {
    try putU32(buf, a, @backingInt(owner.node));
    try putU32(buf, a, @backingInt(owner.tag));
    try putU32(buf, a, owner.span.start);
    try putU32(buf, a, owner.span.end);
    for (owner.words) |word| try putU32(buf, a, word);
}
fn readFrameOwner(r: *Reader) Error!@import("../semantic/scope_frame_history.zig").Owner {
    const node: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    const tag = std.enums.fromInt(@import("../parser/ast.zig").Node.Tag, try r.u32v()) orelse return error.Truncated;
    const span = Span{ .start = try r.u32v(), .end = try r.u32v() };
    var words: [3]u32 = undefined;
    for (&words) |*word| word.* = try r.u32v();
    if (node.isNone() or span.start > span.end) return error.Truncated;
    return .{ .node = node, .tag = tag, .span = span, .words = words };
}
fn putOptionalFrameOwner(buf: *std.ArrayList(u8), a: std.mem.Allocator, owner: ?@import("../semantic/scope_frame_history.zig").Owner) !void {
    try putU8(buf, a, @intFromBool(owner != null));
    if (owner) |value| try putFrameOwner(buf, a, value);
}
fn readOptionalFrameOwner(r: *Reader) Error!?@import("../semantic/scope_frame_history.zig").Owner {
    const has = try r.byte();
    if (has > 1) return error.Truncated;
    return if (has == 1) try readFrameOwner(r) else null;
}
fn putLoweredClassPart(buf: *std.ArrayList(u8), a: std.mem.Allocator, part: anytype) !void {
    inline for (@typeInfo(@TypeOf(part)).@"struct".field_names) |name| try putU32(buf, a, @backingInt(@field(part, name)));
}
fn readLoweredClassPart(comptime T: type, r: *Reader) Error!T {
    var part: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |name| @field(part, name) = @fromBackingInt(try r.u32v());
    return part;
}
fn putWorkletClassCreator(buf: *std.ArrayList(u8), a: std.mem.Allocator, creator: @import("../semantic/lowered_worklet_class.zig").Creator) !void {
    try putLoweredClassPart(buf, a, creator.source);
    try putLoweredClassPart(buf, a, creator.target);
    inline for (.{ "factory", "factory_binding", "factory_symbol", "factory_scope", "wrapper_scope" }) |name| try putU32(buf, a, @backingInt(@field(creator, name)));
    try putU32(buf, a, creator.epoch);
}
fn readWorkletClassCreator(r: *Reader, scope_count: usize, node_count: usize) Error!@import("../semantic/lowered_worklet_class.zig").Creator {
    const W = @import("../semantic/lowered_worklet_class.zig");
    const creator: W.Creator = .{
        .source = try readLoweredClassPart(W.Class, r),
        .target = try readLoweredClassPart(W.Class, r),
        .factory = @fromBackingInt(try r.u32v()),
        .factory_binding = @fromBackingInt(try r.u32v()),
        .factory_symbol = @fromBackingInt(try r.u32v()),
        .factory_scope = @fromBackingInt(try r.u32v()),
        .wrapper_scope = @fromBackingInt(try r.u32v()),
        .epoch = try r.u32v(),
    };
    inline for (.{ creator.source, creator.target }) |class| {
        if (class.scope.isNone() or class.scope.toIndex() >= scope_count or class.self.isNone()) return error.Truncated;
        inline for (.{ class.node, class.name, class.body }) |node| if (node.isNone() or @backingInt(node) >= node_count) return error.Truncated;
    }
    inline for (.{ creator.factory, creator.factory_binding }) |node| if (node.isNone() or @backingInt(node) >= node_count) return error.Truncated;
    inline for (.{ creator.factory_scope, creator.wrapper_scope }) |scope| if (scope.isNone() or scope.toIndex() >= scope_count) return error.Truncated;
    if (creator.factory_symbol.isNone()) return error.Truncated;
    return creator;
}

fn putLoweredWorkletClass(buf: *std.ArrayList(u8), a: std.mem.Allocator, witness: @import("../semantic/lowered_worklet_class.zig").Witness) !void {
    try putU32(buf, a, witness.creator_index);
    try putLoweredClassPart(buf, a, witness.source);
    try putLoweredClassPart(buf, a, witness.target);
    try putLoweredClassPart(buf, a, witness.factory);
    try putU32(buf, a, @backingInt(witness.wrapper_scope));
    try putLoweredClassPart(buf, a, witness.constructor);
    try putLoweredClassPart(buf, a, witness.iife);
    try putU32(buf, a, witness.creator_epoch);
    try putU32(buf, a, witness.lowered_epoch);
}
fn readLoweredWorkletClass(r: *Reader, scope_count: usize, node_count: usize) Error!@import("../semantic/lowered_worklet_class.zig").Witness {
    const W = @import("../semantic/lowered_worklet_class.zig");
    const witness: W.Witness = .{
        .creator_index = try r.u32v(),
        .source = try readLoweredClassPart(W.Class, r),
        .target = try readLoweredClassPart(W.Class, r),
        .factory = try readLoweredClassPart(W.Function, r),
        .wrapper_scope = @fromBackingInt(try r.u32v()),
        .constructor = try readLoweredClassPart(W.Function, r),
        .iife = try readLoweredClassPart(W.Function, r),
        .creator_epoch = try r.u32v(),
        .lowered_epoch = try r.u32v(),
    };
    inline for (.{ witness.source, witness.target }) |class| {
        if (class.scope.isNone() or class.scope.toIndex() >= scope_count or class.self.isNone()) return error.Truncated;
        inline for (.{ class.node, class.name, class.body }) |node| if (node.isNone() or @backingInt(node) >= node_count) return error.Truncated;
    }
    inline for (.{ witness.factory, witness.constructor, witness.iife }) |function| {
        if (function.scope.isNone() or function.scope.toIndex() >= scope_count or function.parent.isNone() or function.parent.toIndex() >= scope_count) return error.Truncated;
        inline for (.{ function.node, function.name, function.params, function.body, function.declaration }) |node| if (!node.isNone() and @backingInt(node) >= node_count) return error.Truncated;
        if (function.node.isNone() or function.params.isNone() or function.body.isNone()) return error.Truncated;
    }
    if (witness.wrapper_scope.isNone() or witness.wrapper_scope.toIndex() >= scope_count) return error.Truncated;
    return witness;
}

fn putEnumMemberLeaf(buf: *std.ArrayList(u8), a: std.mem.Allocator, node: @import("../parser/ast.zig").Node) !void {
    switch (node.tag) {
        .binding_identifier, .identifier_reference, .assignment_target_identifier, .string_literal => {},
        else => return error.InvalidSourceOwnedRetirement,
    }
    try putU32(buf, a, @backingInt(node.tag));
    try putU32(buf, a, node.span.start);
    try putU32(buf, a, node.span.end);
    try putU32(buf, a, node.data.string_ref.start);
    try putU32(buf, a, node.data.string_ref.end);
}

fn readEnumMemberLeaf(r: *Reader) Error!@import("../parser/ast.zig").Node {
    const N = @import("../parser/ast.zig").Node;
    const tag = std.enums.fromInt(N.Tag, try r.u32v()) orelse return error.Truncated;
    switch (tag) {
        .binding_identifier, .identifier_reference, .assignment_target_identifier, .string_literal => {},
        else => return error.Truncated,
    }
    return .{ .tag = tag, .span = .{ .start = try r.u32v(), .end = try r.u32v() }, .data = .{ .string_ref = .{ .start = try r.u32v(), .end = try r.u32v() } } };
}

fn putEnumMember(buf: *std.ArrayList(u8), a: std.mem.Allocator, member: @import("../semantic/enum_environment_retirement.zig").Member) !void {
    if (member.declaration_node.tag != .ts_enum_member) return error.InvalidSourceOwnedRetirement;
    try putU32(buf, a, @backingInt(member.declaration));
    try putU32(buf, a, member.declaration_node.span.start);
    try putU32(buf, a, member.declaration_node.span.end);
    try putU32(buf, a, @backingInt(member.declaration_node.data.binary.left));
    try putU32(buf, a, @backingInt(member.declaration_node.data.binary.right));
    try putU32(buf, a, member.declaration_node.data.binary.flags);
    try putU32(buf, a, @backingInt(member.key));
    try putEnumMemberLeaf(buf, a, member.key_node);
    try putEnumMemberLeaf(buf, a, member.read_node);
}

fn readEnumMember(r: *Reader) Error!@import("../semantic/enum_environment_retirement.zig").Member {
    const declaration: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    const span: @import("../lexer/token.zig").Span = .{ .start = try r.u32v(), .end = try r.u32v() };
    const left: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    const right: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
    const flags = try r.u32v();
    if (flags > std.math.maxInt(u16)) return error.Truncated;
    const node: @import("../parser/ast.zig").Node = .{ .tag = .ts_enum_member, .span = span, .data = .{ .binary = .{ .left = left, .right = right, .flags = @intCast(flags) } } };
    return .{ .declaration = declaration, .declaration_node = node, .key = @fromBackingInt(try r.u32v()), .key_node = try readEnumMemberLeaf(r), .read_node = try readEnumMemberLeaf(r) };
}

fn putDropNode(buf: *std.ArrayList(u8), a: std.mem.Allocator, node: @import("../semantic/source_drop_registry.zig").Node) !void {
    try putU32(buf, a, @backingInt(node.index));
    try putU32(buf, a, @backingInt(node.tag));
    try putU32(buf, a, node.span.start);
    try putU32(buf, a, node.span.end);
    try putU32(buf, a, node.source_symbol orelse std.math.maxInt(u32));
    for (node.data) |byte| try putU8(buf, a, byte);
    try putU32(buf, a, node.extra_len);
    for (node.extra[0..node.extra_len]) |word| try putU32(buf, a, word);
}

fn readDropNode(r: *Reader, node_count: usize, symbol_count: usize) Error!@import("../semantic/source_drop_registry.zig").Node {
    const Drop = @import("../semantic/source_drop_registry.zig");
    const raw = try r.u32v();
    const tag = std.enums.fromInt(@import("../parser/ast.zig").Node.Tag, try r.u32v()) orelse return error.Truncated;
    var result: Drop.Node = .{ .index = @fromBackingInt(raw), .tag = tag, .span = .{ .start = try r.u32v(), .end = try r.u32v() } };
    if (raw >= node_count or result.span.start > result.span.end) return error.Truncated;
    const source_symbol = try r.u32v();
    if (source_symbol != std.math.maxInt(u32)) {
        if (source_symbol >= symbol_count) return error.Truncated;
        result.source_symbol = source_symbol;
    }
    for (&result.data) |*byte| byte.* = try r.byte();
    const count = try r.u32v();
    if (count != (tag.runtimeExtraWords() orelse 0) or count > result.extra.len) return error.Truncated;
    result.extra_len = @intCast(count);
    for (result.extra[0..count]) |*word| word.* = try r.u32v();
    return result;
}

fn putFrameHistory(buf: *std.ArrayList(u8), a: std.mem.Allocator, history: @import("../semantic/scope_frame_history.zig").History) !void {
    try putU32(buf, a, @intCast(history.source_scopes.len));
    for (history.source_scopes) |scope| try putScope(buf, a, scope);
    try putU32(buf, a, @intCast(history.source_owners.len));
    for (history.source_owners) |binding| {
        try putU32(buf, a, @backingInt(binding.scope));
        try putFrameOwner(buf, a, binding.owner);
        try putU32(buf, a, @backingInt(binding.edges.parameters));
        try putU32(buf, a, @backingInt(binding.edges.body));
        try putU32(buf, a, @backingInt(binding.edges.heritage));
    }
    try putU32(buf, a, @intCast(history.source_initializers.len));
    for (history.source_initializers) |entry| {
        try putU32(buf, a, @backingInt(entry.scope));
        try putFrameOwner(buf, a, entry.class_owner);
        try putFrameOwner(buf, a, entry.field);
        try putFrameOwner(buf, a, entry.initializer);
        try putFrameOwner(buf, a, entry.leaf);
    }
    try putU32(buf, a, @intCast(history.source_computed_awaits.len));
    for (history.source_computed_awaits) |entry| {
        try putU32(buf, a, @backingInt(entry.scope));
        inline for (.{ entry.class_owner, entry.declaration, entry.key, entry.await_node, entry.leaf }) |owner| try putFrameOwner(buf, a, owner);
    }
    try putU32(buf, a, @intCast(history.source_class_keys.len));
    for (history.source_class_keys) |entry| {
        try putU32(buf, a, @backingInt(entry.scope));
        inline for (.{ entry.class_owner, entry.body, entry.member, entry.key, entry.leaf }) |owner| try putFrameOwner(buf, a, owner);
        try putU32(buf, a, entry.member_slot);
    }
    try putU32(buf, a, @intCast(history.worklet_class_creators.len));
    for (history.worklet_class_creators) |creator| try putWorkletClassCreator(buf, a, creator);
    try putU32(buf, a, @intCast(history.lowered_worklet_classes.len));
    for (history.lowered_worklet_classes) |witness| try putLoweredWorkletClass(buf, a, witness);
    try putU32(buf, a, @intCast(history.source_dropped_statements.len));
    for (history.source_dropped_statements) |entry| {
        try putU32(buf, a, @backingInt(entry.action));
        try putDropNode(buf, a, entry.source);
        try putDropNode(buf, a, entry.selected);
        try putU32(buf, a, entry.entry_epoch);
        try putU32(buf, a, entry.selection_epoch);
        try putU32(buf, a, @backingInt(entry.execution_scope));
        try putScope(buf, a, entry.execution_frame);
        try putU32(buf, a, entry.edge_start);
        try putU32(buf, a, entry.edge_len);
    }
    try putU32(buf, a, @intCast(history.source_drop_edges.len));
    for (history.source_drop_edges) |entry| {
        try putDropNode(buf, a, entry.parent);
        try putU8(buf, a, @intFromBool(entry.child != null));
        if (entry.child) |child| try putDropNode(buf, a, child);
        try putU32(buf, a, entry.ordinal);
        try putU32(buf, a, entry.child_count);
    }
    try putU32(buf, a, @intCast(history.events.len));
    for (history.events) |event| {
        try putU32(buf, a, @backingInt(event.kind));
        try putU32(buf, a, @backingInt(event.scope));
        try putU8(buf, a, @intFromBool(event.before != null));
        if (event.before) |scope| try putScope(buf, a, scope);
        try putScope(buf, a, event.after);
        try putOptionalFrameOwner(buf, a, event.owner_before);
        try putOptionalFrameOwner(buf, a, event.owner_after);
        inline for (.{ event.owner_edges.parameters, event.owner_edges.body, event.owner_edges.heritage }) |node| try putU32(buf, a, @backingInt(node));
        try putU32(buf, a, @backingInt(event.trigger_scope));
        try putU32(buf, a, @backingInt(event.trigger_parent));
        try putOptionalFrameOwner(buf, a, event.parent_owner);
        try putU32(buf, a, @backingInt(event.actor.role));
        try putU8(buf, a, @intFromBool(event.actor.module_index != null));
        if (event.actor.module_index) |module_index| try putU32(buf, a, module_index);
    }
}
fn readFrameHistory(r: *Reader, a: std.mem.Allocator, scope_count: usize, node_count: usize, symbol_count: usize) Error!@import("../semantic/scope_frame_history.zig").History {
    const H = @import("../semantic/scope_frame_history.zig");
    const count = try r.u32v();
    if (count > scope_count or count > r.remaining() / 4) return error.Truncated;
    const scopes = try a.alloc(Scope, count);
    for (scopes) |*scope| scope.* = try readScope(r);
    const owner_count = try checkedMapCount(r, try r.u32v());
    const owners = try a.alloc(H.OwnerBinding, owner_count);
    for (owners) |*owner| {
        const sid = try r.u32v();
        if (sid >= count) return error.Truncated;
        owner.* = .{ .scope = @fromBackingInt(sid), .owner = try readFrameOwner(r), .edges = .{
            .parameters = @fromBackingInt(try r.u32v()),
            .body = @fromBackingInt(try r.u32v()),
            .heritage = @fromBackingInt(try r.u32v()),
        } };
        inline for (.{ owner.edges.parameters, owner.edges.body, owner.edges.heritage }) |node| if (!node.isNone() and @backingInt(node) >= node_count) return error.Truncated;
        if (@backingInt(owner.owner.node) >= node_count) return error.Truncated;
    }
    const initializer_count = try checkedMapCount(r, try r.u32v());
    const initializers = try a.alloc(H.InitializerSource, initializer_count);
    for (initializers) |*entry| {
        const sid = try r.u32v();
        if (sid >= count) return error.Truncated;
        entry.* = .{ .scope = @fromBackingInt(sid), .class_owner = try readFrameOwner(r), .field = try readFrameOwner(r), .initializer = try readFrameOwner(r), .leaf = try readFrameOwner(r) };
        inline for (.{ entry.class_owner.node, entry.field.node, entry.initializer.node, entry.leaf.node }) |node| if (node.isNone() or @backingInt(node) >= node_count) return error.Truncated;
    }
    const computed_count = try checkedMapCount(r, try r.u32v());
    const computed = try a.alloc(H.ComputedAwaitSource, computed_count);
    for (computed) |*entry| {
        const sid = try r.u32v();
        if (sid >= count) return error.Truncated;
        entry.* = .{ .scope = @fromBackingInt(sid), .class_owner = try readFrameOwner(r), .declaration = try readFrameOwner(r), .key = try readFrameOwner(r), .await_node = try readFrameOwner(r), .leaf = try readFrameOwner(r) };
        inline for (.{ entry.class_owner, entry.declaration, entry.key, entry.await_node, entry.leaf }) |owner| if (@backingInt(owner.node) >= node_count) return error.Truncated;
    }
    const class_key_count = try checkedMapCount(r, try r.u32v());
    const class_keys = try a.alloc(H.ClassKeySource, class_key_count);
    for (class_keys) |*entry| {
        const sid = try r.u32v();
        if (sid >= count) return error.Truncated;
        entry.* = .{ .scope = @fromBackingInt(sid), .class_owner = try readFrameOwner(r), .body = try readFrameOwner(r), .member = try readFrameOwner(r), .key = try readFrameOwner(r), .leaf = try readFrameOwner(r), .member_slot = try r.u32v() };
        inline for (.{ entry.class_owner, entry.body, entry.member, entry.key, entry.leaf }) |owner| if (owner.node.isNone() or @backingInt(owner.node) >= node_count) return error.Truncated;
    }
    const creator_count = try checkedMapCount(r, try r.u32v());
    const creators = try a.alloc(@import("../semantic/lowered_worklet_class.zig").Creator, creator_count);
    for (creators) |*creator| creator.* = try readWorkletClassCreator(r, scope_count, node_count);
    const lowered_count = try checkedMapCount(r, try r.u32v());
    const lowered = try a.alloc(@import("../semantic/lowered_worklet_class.zig").Witness, lowered_count);
    for (lowered) |*witness| witness.* = try readLoweredWorkletClass(r, scope_count, node_count);
    const Drop = @import("../semantic/source_drop_registry.zig");
    const dropped_count = try checkedMapCount(r, try r.u32v());
    const dropped = try a.alloc(Drop.Statement, dropped_count);
    for (dropped) |*entry| {
        entry.* = .{
            .action = std.enums.fromInt(Drop.Action, try r.u32v()) orelse return error.Truncated,
            .source = try readDropNode(r, node_count, symbol_count),
            .selected = try readDropNode(r, node_count, symbol_count),
            .entry_epoch = try r.u32v(),
            .selection_epoch = try r.u32v(),
            .execution_scope = @fromBackingInt(try r.u32v()),
            .execution_frame = try readScope(r),
            .edge_start = try r.u32v(),
            .edge_len = try r.u32v(),
        };
        if (entry.execution_scope.isNone() or entry.execution_scope.toIndex() >= scope_count or entry.entry_epoch > entry.selection_epoch) return error.Truncated;
    }
    const drop_edge_count = try checkedMapCount(r, try r.u32v());
    const drop_edges = try a.alloc(Drop.Edge, drop_edge_count);
    for (drop_edges) |*entry| {
        const parent = try readDropNode(r, node_count, symbol_count);
        const has_child = try r.byte();
        if (has_child > 1) return error.Truncated;
        entry.* = .{ .parent = parent, .child = if (has_child == 1) try readDropNode(r, node_count, symbol_count) else null, .ordinal = try r.u32v(), .child_count = try r.u32v() };
        if (entry.ordinal >= entry.child_count) return error.Truncated;
    }
    for (dropped) |entry| if (entry.edge_start > drop_edges.len or entry.edge_len > drop_edges.len - entry.edge_start) return error.Truncated;
    const event_count = try checkedMapCount(r, try r.u32v());
    const events = try a.alloc(H.Event, event_count);
    for (events) |*event| {
        const kind = std.enums.fromInt(@FieldType(H.Event, "kind"), try r.u32v()) orelse return error.Truncated;
        const scope: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
        const has_before = try r.byte();
        if (has_before > 1 or scope.isNone() or scope.toIndex() >= scope_count) return error.Truncated;
        const before = if (has_before == 1) try readScope(r) else null;
        const after = try readScope(r);
        const old_owner = try readOptionalFrameOwner(r);
        const new_owner = try readOptionalFrameOwner(r);
        const owner_edges: H.SourceEdges = .{ .parameters = @fromBackingInt(try r.u32v()), .body = @fromBackingInt(try r.u32v()), .heritage = @fromBackingInt(try r.u32v()) };
        inline for (.{ owner_edges.parameters, owner_edges.body, owner_edges.heritage }) |node| if (!node.isNone() and @backingInt(node) >= node_count) return error.Truncated;
        const trigger_scope: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
        const trigger_parent: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
        const parent = try readOptionalFrameOwner(r);
        const role = std.enums.fromInt(@FieldType(H.Actor, "role"), try r.u32v()) orelse return error.Truncated;
        const has_module = try r.byte();
        if (has_module > 1) return error.Truncated;
        const module_index = if (has_module == 1) try r.u32v() else null;
        inline for (.{ old_owner, new_owner, parent }) |owner| if (owner) |value| if (@backingInt(value.node) >= node_count) return error.Truncated;
        event.* = .{ .kind = kind, .scope = scope, .before = before, .after = after, .owner_before = old_owner, .owner_after = new_owner, .owner_edges = owner_edges, .trigger_scope = trigger_scope, .trigger_parent = trigger_parent, .parent_owner = parent, .actor = .{ .role = role, .module_index = module_index } };
    }
    if (count == 0 and (owner_count != 0 or initializer_count != 0 or computed_count != 0 or creator_count != 0 or lowered_count != 0 or class_key_count != 0 or dropped_count != 0 or drop_edge_count != 0 or event_count != 0)) return error.Truncated;
    return .{ .source_scopes = scopes, .source_owners = owners, .source_initializers = initializers, .source_computed_awaits = computed, .worklet_class_creators = creators, .lowered_worklet_classes = lowered, .source_class_keys = class_keys, .source_dropped_statements = dropped, .source_drop_edges = drop_edges, .events = events };
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
    try putFrameHistory(&payload, alloc, sem.scope_history);
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
        try putU8(&payload, alloc, @intFromBool(entry.external_import != null));
        if (entry.external_import) |origin| {
            try putU32(&payload, alloc, @backingInt(origin.binding_symbol));
            try putReference(&payload, alloc, origin.before);
            try putU32(&payload, alloc, @backingInt(origin.before_tag));
            try putU32(&payload, alloc, origin.before_name.start);
            try putU32(&payload, alloc, origin.before_name.end);
            try putU32(&payload, alloc, origin.before_span.start);
            try putU32(&payload, alloc, origin.before_span.end);
        }
        try putU8(&payload, alloc, @intFromBool(entry.source_external != null));
        if (entry.source_external) |origin| {
            try putU32(&payload, alloc, @backingInt(origin.tag));
            try putU32(&payload, alloc, origin.name.start);
            try putU32(&payload, alloc, origin.name.end);
            try putU32(&payload, alloc, origin.span.start);
            try putU32(&payload, alloc, origin.span.end);
            try putU8(&payload, alloc, @bitCast(origin.flags));
            try putU32(&payload, alloc, @backingInt(origin.source_scope));
            try putScope(&payload, alloc, origin.source_frame);
            try putU32(&payload, alloc, @backingInt(origin.execution_scope));
            try putScope(&payload, alloc, origin.execution_frame);
            try putOptionalFrameOwner(&payload, alloc, origin.jsx_reference);
            try putU32(&payload, alloc, @intCast(origin.scope_moves.len));
            for (origin.scope_moves) |move| {
                try putU32(&payload, alloc, @backingInt(move.node));
                try putU32(&payload, alloc, @backingInt(move.source_node));
                try putU32(&payload, alloc, @backingInt(move.from));
                try putU32(&payload, alloc, @backingInt(move.to));
                try putScope(&payload, alloc, move.from_frame);
                try putScope(&payload, alloc, move.to_frame);
                try putU32(&payload, alloc, move.frame_epoch);
                try putU32(&payload, alloc, @backingInt(move.reason));
                try putU8(&payload, alloc, @intFromBool(move.elision != null));
                if (move.elision) |elision| {
                    try putU32(&payload, alloc, @backingInt(elision.owner));
                    try putRetirementNode(&payload, alloc, elision.source);
                }
                try putU8(&payload, alloc, @intFromBool(move.static_block != null));
                if (move.static_block) |transfer| {
                    try putFrameOwner(&payload, alloc, transfer.source_owner);
                    try putFrameOwner(&payload, alloc, transfer.target_owner);
                    try putU32(&payload, alloc, @backingInt(transfer.source_body));
                    try putU32(&payload, alloc, @backingInt(transfer.parameters));
                    try putU32(&payload, alloc, @backingInt(transfer.output_body));
                    try putU32(&payload, alloc, transfer.birth_epoch);
                }
                try putU8(&payload, alloc, @intFromBool(move.generator != null));
                if (move.generator) |transfer| {
                    try putFrameOwner(&payload, alloc, transfer.source.owner);
                    try putU32(&payload, alloc, @backingInt(transfer.source.scope));
                    try putU32(&payload, alloc, @backingInt(transfer.source.parameters));
                    try putU32(&payload, alloc, @backingInt(transfer.source.body));
                    try putU8(&payload, alloc, @intFromBool(transfer.source.extracted_loop != null));
                    if (transfer.source.extracted_loop) |loop| {
                        try putFrameOwner(&payload, alloc, loop.loop_owner);
                        try putU32(&payload, alloc, @backingInt(loop.loop_scope));
                        try putU32(&payload, alloc, @backingInt(loop.loop_body));
                        try putOptionalFrameOwner(&payload, alloc, loop.loop_body_owner);
                        try putFrameOwner(&payload, alloc, loop.function_owner);
                        try putU32(&payload, alloc, @backingInt(loop.function_scope));
                        try putU32(&payload, alloc, @backingInt(loop.parameters));
                        try putU32(&payload, alloc, @backingInt(loop.body));
                        try putU32(&payload, alloc, loop.birth_epoch);
                    }
                    try putFrameOwner(&payload, alloc, transfer.callback);
                    try putU32(&payload, alloc, @backingInt(transfer.callback_scope));
                    try putU32(&payload, alloc, @backingInt(transfer.parameters));
                    try putU32(&payload, alloc, @backingInt(transfer.body));
                    try putU32(&payload, alloc, @backingInt(transfer.state_parameter));
                    try putU32(&payload, alloc, transfer.birth_epoch);
                    try putU8(&payload, alloc, @intFromBool(transfer.heritage != null));
                    if (transfer.heritage) |heritage| {
                        try putFrameOwner(&payload, alloc, heritage.owner);
                        try putU32(&payload, alloc, @backingInt(heritage.scope));
                        try putU32(&payload, alloc, @backingInt(heritage.heritage));
                        try putU32(&payload, alloc, @backingInt(heritage.await_node));
                        try putU32(&payload, alloc, @backingInt(heritage.read));
                    }
                    try putU8(&payload, alloc, @intFromBool(transfer.computed_await_source != null));
                    if (transfer.computed_await_source) |computed_source| try putU32(&payload, alloc, computed_source);
                }
                try putU8(&payload, alloc, @intFromBool(move.class_heritage != null));
                if (move.class_heritage) |transfer| {
                    try putFrameOwner(&payload, alloc, transfer.owner);
                    try putU32(&payload, alloc, @backingInt(transfer.class_scope));
                    try putU32(&payload, alloc, @backingInt(transfer.heritage));
                    try putU32(&payload, alloc, @backingInt(transfer.evaluation_scope));
                    try putU32(&payload, alloc, transfer.capture_epoch);
                }
                try putU8(&payload, alloc, @intFromBool(move.class_initializer != null));
                if (move.class_initializer) |transfer| {
                    try putU32(&payload, alloc, transfer.source_index);
                    try putFrameOwner(&payload, alloc, transfer.target_owner);
                    try putU32(&payload, alloc, @backingInt(transfer.parameters));
                    try putU32(&payload, alloc, @backingInt(transfer.body));
                    try putU32(&payload, alloc, transfer.owner_epoch);
                }
                try putU8(&payload, alloc, @intFromBool(move.class_key != null));
                if (move.class_key) |transfer| {
                    try putU32(&payload, alloc, transfer.source_index);
                    try putU32(&payload, alloc, @backingInt(transfer.evaluation_scope));
                    try putU32(&payload, alloc, transfer.capture_epoch);
                }
            }
        }
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

    try putU32(&payload, alloc, @intCast(sem.source_owned_retirements.count()));
    const retirement_keys = try alloc.alloc(u32, sem.source_owned_retirements.count());
    defer alloc.free(retirement_keys);
    var retirement_it = sem.source_owned_retirements.keyIterator();
    for (retirement_keys) |*key| key.* = retirement_it.next().?.*;
    std.mem.sortUnstable(u32, retirement_keys, {}, std.sort.asc(u32));
    for (retirement_keys) |sid| {
        const witness = sem.source_owned_retirements.get(sid).?;
        if (sid >= sem.symbols.items.len or @backingInt(witness.symbol_id) != sid) return error.InvalidSourceOwnedRetirement;
        try putU32(&payload, alloc, sid);
        try putSymbol(&payload, alloc, witness.before);
        try putReference(&payload, alloc, witness.declaration);
        try putU32(&payload, alloc, @intFromBool(witness.declaration_node != null));
        if (witness.declaration_node) |node| try putRetirementNode(&payload, alloc, node);
        try putU32(&payload, alloc, @backingInt(witness.source_owner));
        try putRetirementNode(&payload, alloc, witness.source_owner_node);
        try putU32(&payload, alloc, @backingInt(witness.source_scope));
        try putU32(&payload, alloc, @backingInt(witness.source_parent));
        try putU32(&payload, alloc, @backingInt(witness.source_name));
        try putU32(&payload, alloc, @backingInt(witness.source_name_symbol));
        try putU32(&payload, alloc, @backingInt(witness.closure_scope));
        try putU32(&payload, alloc, @backingInt(witness.closure_parent));
        try putU32(&payload, alloc, @backingInt(witness.reason));
        try putU32(&payload, alloc, @intFromBool(witness.erased_import != null));
        if (witness.erased_import) |binding| try putImportErasure(&payload, alloc, binding);
        try putU32(&payload, alloc, @intFromBool(witness.static_capture_alias != null));
        if (witness.static_capture_alias) |alias| try putStaticCaptureAlias(&payload, alloc, alias);
        try putU32(&payload, alloc, @intFromBool(witness.function_name_elision != null));
        if (witness.function_name_elision) |name| try putFunctionNameElision(&payload, alloc, name);
        try putU32(&payload, alloc, @intFromBool(witness.enum_environment != null));
        if (witness.enum_environment) |environment| {
            try putFrameOwner(&payload, alloc, environment.owner);
            try putU32(&payload, alloc, @backingInt(environment.parameter_symbol));
            try putReference(&payload, alloc, environment.binding_declaration);
            try putRetirementNode(&payload, alloc, environment.binding_node);
            try putU32(&payload, alloc, @intFromBool(environment.member != null));
            if (environment.member) |member| try putEnumMember(&payload, alloc, member);
        }
        try putU32(&payload, alloc, @intFromBool(witness.dropped_statement != null));
        if (witness.dropped_statement) |drop| {
            try putU32(&payload, alloc, drop.statement);
            try putU32(&payload, alloc, drop.scope_owner orelse std.math.maxInt(u32));
        }
        try putU32(&payload, alloc, @intFromBool(witness.inlined_binding != null));
        if (witness.inlined_binding) |inlined| try putInlinedBinding(&payload, alloc, inlined);
    }

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
    const scope_history = try readFrameHistory(&r, arena, scopes_len, symbol_ids_len, symbols_len);
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
        const has_external = (try r.take(1))[0];
        if (has_external > 1) return error.Truncated;
        const external_import: ?@import("../semantic/import_erasure.zig").ExternalOrigin = if (has_external == 1) external: {
            const sid = try r.u32v();
            const before = try readReference(&r);
            const tag = std.enums.fromInt(@import("../parser/ast.zig").Node.Tag, try r.u32v()) orelse return error.Truncated;
            const name = @import("../parser/ast.zig").StringRef{ .start = try r.u32v(), .end = try r.u32v() };
            const span = Span{ .start = try r.u32v(), .end = try r.u32v() };
            if (sid >= symbols_len or @backingInt(before.symbol_id) != sid) return error.Truncated;
            break :external .{ .binding_symbol = @fromBackingInt(sid), .before = before, .before_tag = tag, .before_name = name, .before_span = span };
        } else null;
        const has_source_external = (try r.take(1))[0];
        if (has_source_external > 1 or (has_source_external == 1 and external_import != null)) return error.Truncated;
        const source_external: ?@import("../semantic/source_external_origin.zig").Origin = if (has_source_external == 1) external: {
            const tag = std.enums.fromInt(@import("../parser/ast.zig").Node.Tag, try r.u32v()) orelse return error.Truncated;
            const name = @import("../parser/ast.zig").StringRef{ .start = try r.u32v(), .end = try r.u32v() };
            const span = Span{ .start = try r.u32v(), .end = try r.u32v() };
            const flags: symbol_mod.ReferenceFlags = @bitCast((try r.take(1))[0]);
            const source_scope: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
            const source_frame = try readScope(&r);
            const execution_scope: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
            const execution_frame = try readScope(&r);
            const jsx_reference = try readOptionalFrameOwner(&r);
            if (jsx_reference) |jsx| if (jsx.tag != .jsx_identifier or @backingInt(jsx.node) >= symbol_ids_len) return error.Truncated;
            const move_count = try r.u32v();
            if (move_count > scopes_len or move_count > r.remaining() / 20) return error.Truncated;
            const ScopeMove = @import("../semantic/source_external_origin.zig").ScopeMove;
            const moves = try arena.alloc(ScopeMove, move_count);
            for (moves) |*move| {
                const moved_node = try r.u32v();
                const moved_source = try r.u32v();
                const from = try r.u32v();
                const to = try r.u32v();
                const from_frame = try readScope(&r);
                const to_frame = try readScope(&r);
                const frame_epoch = try r.u32v();
                if (frame_epoch > scope_history.events.len) return error.Truncated;
                const reason = std.enums.fromInt(@FieldType(ScopeMove, "reason"), try r.u32v()) orelse return error.Truncated;
                const has_elision = (try r.take(1))[0];
                if (has_elision > 1 or (has_elision == 1) != (reason == .empty_arrow_scope_elision)) return error.Truncated;
                const elision: ?@import("../semantic/source_external_origin.zig").EmptyArrowElision = if (has_elision == 1) .{ .owner = @fromBackingInt(try r.u32v()), .source = try readRetirementNode(&r, false) } else null;
                const has_static_block = (try r.take(1))[0];
                if (has_static_block > 1 or (has_static_block == 1) != (reason == .static_block_environment_transfer)) return error.Truncated;
                const static_block: ?@import("../semantic/source_external_origin.zig").StaticBlockTransfer = if (has_static_block == 1) .{
                    .source_owner = try readFrameOwner(&r),
                    .target_owner = try readFrameOwner(&r),
                    .source_body = @fromBackingInt(try r.u32v()),
                    .parameters = @fromBackingInt(try r.u32v()),
                    .output_body = @fromBackingInt(try r.u32v()),
                    .birth_epoch = try r.u32v(),
                } else null;
                const has_generator = (try r.take(1))[0];
                if (has_generator > 1 or (has_generator == 1) != (reason == .generator_environment_transfer)) return error.Truncated;
                const generator: ?@import("../semantic/generator_environment_transfer.zig").Transfer = if (has_generator == 1) .{
                    .source = .{ .owner = try readFrameOwner(&r), .scope = @fromBackingInt(try r.u32v()), .parameters = @fromBackingInt(try r.u32v()), .body = @fromBackingInt(try r.u32v()), .extracted_loop = loop: {
                        const present = try r.byte();
                        if (present > 1) return error.Truncated;
                        break :loop if (present == 1) @as(@import("../semantic/generator_environment_transfer.zig").ExtractedLoop, .{ .loop_owner = try readFrameOwner(&r), .loop_scope = @fromBackingInt(try r.u32v()), .loop_body = @fromBackingInt(try r.u32v()), .loop_body_owner = try readOptionalFrameOwner(&r), .function_owner = try readFrameOwner(&r), .function_scope = @fromBackingInt(try r.u32v()), .parameters = @fromBackingInt(try r.u32v()), .body = @fromBackingInt(try r.u32v()), .birth_epoch = try r.u32v() }) else null;
                    } },
                    .callback = try readFrameOwner(&r),
                    .callback_scope = @fromBackingInt(try r.u32v()),
                    .parameters = @fromBackingInt(try r.u32v()),
                    .body = @fromBackingInt(try r.u32v()),
                    .state_parameter = @fromBackingInt(try r.u32v()),
                    .birth_epoch = try r.u32v(),
                    .heritage = heritage: {
                        const present = (try r.take(1))[0];
                        if (present > 1) return error.Truncated;
                        break :heritage if (present == 1) @as(@import("../semantic/generator_environment_transfer.zig").HeritageRead, .{ .owner = try readFrameOwner(&r), .scope = @fromBackingInt(try r.u32v()), .heritage = @fromBackingInt(try r.u32v()), .await_node = @fromBackingInt(try r.u32v()), .read = @fromBackingInt(try r.u32v()) }) else null;
                    },
                    .computed_await_source = key: {
                        const present = try r.byte();
                        if (present > 1) return error.Truncated;
                        break :key if (present == 1) try r.u32v() else null;
                    },
                } else null;
                const has_heritage = (try r.take(1))[0];
                if (has_heritage > 1 or (has_heritage == 1) != (reason == .class_heritage_evaluation)) return error.Truncated;
                const class_heritage: ?@import("../semantic/source_external_origin.zig").ClassHeritageTransfer = if (has_heritage == 1) .{
                    .owner = try readFrameOwner(&r),
                    .class_scope = @fromBackingInt(try r.u32v()),
                    .heritage = @fromBackingInt(try r.u32v()),
                    .evaluation_scope = @fromBackingInt(try r.u32v()),
                    .capture_epoch = try r.u32v(),
                } else null;
                const has_initializer = try r.byte();
                if (has_initializer > 1 or (has_initializer == 1) != (reason == .class_initializer_environment_transfer)) return error.Truncated;
                const class_initializer: ?@import("../semantic/source_external_origin.zig").ClassInitializerTransfer = if (has_initializer == 1) .{
                    .source_index = try r.u32v(),
                    .target_owner = try readFrameOwner(&r),
                    .parameters = @fromBackingInt(try r.u32v()),
                    .body = @fromBackingInt(try r.u32v()),
                    .owner_epoch = try r.u32v(),
                } else null;
                const has_class_key = try r.byte();
                if (has_class_key > 1 or (has_class_key == 1) != (reason == .class_key_evaluation)) return error.Truncated;
                const class_key: ?@import("../semantic/class_key_evaluation.zig").Transfer = if (has_class_key == 1) .{ .source_index = try r.u32v(), .evaluation_scope = @fromBackingInt(try r.u32v()), .capture_epoch = try r.u32v() } else null;
                if (class_key) |transfer| if (transfer.evaluation_scope.isNone() or transfer.evaluation_scope.toIndex() >= scopes_len) return error.Truncated;
                if (moved_node >= symbol_ids_len or moved_source >= symbol_ids_len or from >= scopes_len or to >= scopes_len) return error.Truncated;
                move.* = .{ .node = @fromBackingInt(moved_node), .source_node = @fromBackingInt(moved_source), .from = @fromBackingInt(from), .to = @fromBackingInt(to), .from_frame = from_frame, .to_frame = to_frame, .reason = reason, .elision = elision, .static_block = static_block, .generator = generator, .class_heritage = class_heritage, .class_initializer = class_initializer, .class_key = class_key, .frame_epoch = frame_epoch };
            }
            if (source_scope.isNone() or source_scope.toIndex() >= scopes_len or execution_scope.isNone() or execution_scope.toIndex() >= scopes_len) return error.Truncated;
            break :external .{ .tag = tag, .name = name, .span = span, .flags = flags, .source_scope = source_scope, .source_frame = source_frame, .execution_scope = execution_scope, .execution_frame = execution_frame, .scope_moves = moves, .jsx_reference = jsx_reference };
        } else null;
        node_scope_provenance.putAssumeCapacity(node, .{ .scope = @fromBackingInt(scope), .source_node = @fromBackingInt(source_node), .with_environment = with_environment != 0, .external_import = external_import, .source_external = source_external });
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
    var source_owned_retirements: @import("../semantic/source_owned_retirement.zig").Map = .empty;
    const retirement_count = try r.u32v();
    if (retirement_count > symbols_len or retirement_count > r.remaining() / 4) return error.Truncated;
    try source_owned_retirements.ensureTotalCapacity(arena, retirement_count);
    for (0..retirement_count) |_| {
        const sid = try r.u32v();
        if (sid >= symbols_len or source_owned_retirements.contains(sid)) return error.Truncated;
        const before = try readSymbol(&r, arena);
        const declaration = try readReference(&r);
        const has_declaration = try r.u32v();
        if (has_declaration > 1) return error.Truncated;
        const declaration_node = if (has_declaration == 1) try readRetirementNode(&r, true) else null;
        const owner: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
        const owner_node = try readRetirementNode(&r, false);
        const source_scope: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
        const source_parent: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
        const source_name: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(try r.u32v());
        const source_name_symbol: symbol_mod.SymbolId = @fromBackingInt(try r.u32v());
        const closure_scope: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
        const closure_parent: scope_mod.ScopeId = @fromBackingInt(try r.u32v());
        const reason = std.enums.fromInt(@FieldType(@import("../semantic/source_owned_retirement.zig").Witness, "reason"), try r.u32v()) orelse return error.Truncated;
        const has_import = try r.u32v();
        if (has_import > 1) return error.Truncated;
        const erased_import = if (has_import == 1) try readImportErasure(&r) else null;
        const has_static_alias = try r.u32v();
        if (has_static_alias > 1) return error.Truncated;
        const static_alias = if (has_static_alias == 1) try readStaticCaptureAlias(&r, arena) else null;
        if ((reason == .static_class_capture_alias) != (static_alias != null)) return error.Truncated;
        const has_name_elision = try r.u32v();
        if (has_name_elision > 1) return error.Truncated;
        const name_elision = if (has_name_elision == 1) try readFunctionNameElision(&r, arena) else null;
        if ((reason == .elided_function_name) != (name_elision != null)) return error.Truncated;
        const has_enum_environment = try r.u32v();
        if (has_enum_environment > 1) return error.Truncated;
        const enum_environment: ?@import("../semantic/enum_environment_retirement.zig").Witness = if (has_enum_environment == 1) environment: {
            const owner_entry = try readFrameOwner(&r);
            const parameter: symbol_mod.SymbolId = @fromBackingInt(try r.u32v());
            const binding_declaration = try readReference(&r);
            const binding_node = try readRetirementNode(&r, true);
            const has_member = try r.u32v();
            if (has_member > 1) return error.Truncated;
            const member = if (has_member == 1) try readEnumMember(&r) else null;
            break :environment .{ .owner = owner_entry, .parameter_symbol = parameter, .binding_declaration = binding_declaration, .binding_node = binding_node, .member = member };
        } else null;
        const has_drop = try r.u32v();
        if (has_drop > 1) return error.Truncated;
        const dropped_statement: ?@import("../semantic/drop_statement_retirement.zig").Witness = if (has_drop == 1) drop: {
            const statement = try r.u32v();
            const owner_index = try r.u32v();
            if (statement >= scope_history.source_dropped_statements.len or
                (owner_index != std.math.maxInt(u32) and owner_index >= scope_history.source_owners.len)) return error.Truncated;
            break :drop .{ .statement = statement, .scope_owner = if (owner_index == std.math.maxInt(u32)) null else owner_index };
        } else null;
        const has_inlined = try r.u32v();
        if (has_inlined > 1) return error.Truncated;
        const inlined_binding = if (has_inlined == 1) try readInlinedBinding(&r, symbol_ids.len, scopes.len, symbols_len, scope_history.events.len) else null;
        if ((reason == .inlined_local_binding) != (inlined_binding != null)) return error.Truncated;
        if ((reason == .dropped_statement) != (dropped_statement != null)) return error.Truncated;
        if ((reason == .erased_const_enum_environment) != (enum_environment != null)) return error.Truncated;
        if (enum_environment) |environment| if (@backingInt(environment.parameter_symbol) >= symbols_len) return error.Truncated;
        if ((reason == .erased_import_binding) != (erased_import != null) or owner.isNone() or @backingInt(owner) >= symbol_ids.len or source_scope.isNone() or source_scope.toIndex() >= scopes.len or
            (if (reason == .source_function_closure or reason == .elided_function_name or reason == .erased_const_enum_environment or (reason == .dropped_statement and dropped_statement.?.scope_owner != null)) closure_scope.isNone() or closure_scope.toIndex() >= scopes.len else !closure_scope.isNone() or !closure_parent.isNone()) or
            (!source_name.isNone() and @backingInt(source_name) >= symbol_ids.len) or (!source_name_symbol.isNone() and @backingInt(source_name_symbol) >= symbols_len) or
            source_name.isNone() != source_name_symbol.isNone() or @backingInt(declaration.symbol_id) != sid) return error.Truncated;
        var expected = before;
        expected.reference_count = 0;
        expected.write_count = 0;
        if (!@import("../semantic/source_owned_retirement.zig").equalSymbol(expected, symbols_slice[sid])) return error.Truncated;
        source_owned_retirements.putAssumeCapacity(sid, .{
            .symbol_id = @fromBackingInt(sid),
            .before = before,
            .declaration = declaration,
            .declaration_node = declaration_node,
            .source_owner = owner,
            .source_owner_node = owner_node,
            .source_scope = source_scope,
            .source_parent = source_parent,
            .source_name = source_name,
            .source_name_symbol = source_name_symbol,
            .closure_scope = closure_scope,
            .closure_parent = closure_parent,
            .reason = reason,
            .erased_import = erased_import,
            .static_capture_alias = static_alias,
            .function_name_elision = name_elision,
            .enum_environment = enum_environment,
            .dropped_statement = dropped_statement,
            .inlined_binding = inlined_binding,
        });
    }
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
        .scope_history = scope_history,
        .class_self_symbol_map = class_self_symbol_map,
        .namespace_member_owners = namespace_member_owners,
        .source_owned_retirements = source_owned_retirements,
        .namespace_declaration_owners = namespace_declaration_owners,
        .runtime_identities = runtime_identities,
        .strict_output_context = .{ .program = strict_program, .directive = strict_directive, .functions = strict_roles },
    };
}
