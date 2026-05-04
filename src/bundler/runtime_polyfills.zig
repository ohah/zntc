//! Runtime core-js polyfill usage collector.
//!
//! JS computes target-compatible core-js module candidates. The native graph
//! decides which usage-mode candidates are actually needed after parse,
//! plugin transforms, and semantic binding resolution.

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const ast_walk = @import("../parser/ast_walk.zig");
const Module = @import("module.zig").Module;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const ModuleType = @import("types.zig").ModuleType;

pub const Mode = enum {
    usage,
    entry,

    pub fn fromString(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "usage")) return .usage;
        if (std.mem.eql(u8, value, "entry")) return .entry;
        return null;
    }
};

pub const Feature = []const u8;

pub const FeatureSet = struct {
    const max_features = 512;

    items: [max_features]Feature = undefined,
    len: usize = 0,

    pub fn deinit(self: *FeatureSet, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn insert(self: *FeatureSet, allocator: std.mem.Allocator, feature: Feature) !void {
        _ = allocator;
        if (self.has(feature)) return;
        if (self.len >= max_features) return error.OutOfMemory;
        self.items[self.len] = feature;
        self.len += 1;
    }

    pub fn has(self: FeatureSet, feature: Feature) bool {
        for (self.items[0..self.len]) |existing| {
            if (std.mem.eql(u8, existing, feature)) return true;
        }
        return false;
    }

    pub fn merge(self: *FeatureSet, allocator: std.mem.Allocator, other: FeatureSet) !void {
        for (other.items[0..other.len]) |feature| {
            try self.insert(allocator, feature);
        }
    }

    pub fn isEmpty(self: FeatureSet) bool {
        return self.len == 0;
    }
};

pub const ResolvedModule = struct {
    module: []const u8,
    path: []const u8,
};

pub const Candidate = struct {
    feature: Feature,
    module: []const u8,
    path: []const u8,
};

pub const Plan = struct {
    mode: Mode,
    candidates: []const Candidate = &.{},
    entry_modules: []const ResolvedModule = &.{},
    include: []const ResolvedModule = &.{},
    exclude: []const []const u8 = &.{},
};

const NameFeature = struct {
    name: []const u8,
    feature: []const u8,
};

const global_features = [_]NameFeature{
    .{ .name = "AggregateError", .feature = "aggregate_error" },
    .{ .name = "ArrayBuffer", .feature = "array_buffer" },
    .{ .name = "AsyncDisposableStack", .feature = "async_disposable_stack" },
    .{ .name = "DataView", .feature = "data_view" },
    .{ .name = "DisposableStack", .feature = "disposable_stack" },
    .{ .name = "DOMException", .feature = "web_dom_exception" },
    .{ .name = "Float32Array", .feature = "typed_array_float32" },
    .{ .name = "Float64Array", .feature = "typed_array_float64" },
    .{ .name = "Int8Array", .feature = "typed_array_int8" },
    .{ .name = "Int16Array", .feature = "typed_array_int16" },
    .{ .name = "Int32Array", .feature = "typed_array_int32" },
    .{ .name = "Iterator", .feature = "iterator" },
    .{ .name = "Map", .feature = "map" },
    .{ .name = "Promise", .feature = "promise" },
    .{ .name = "Set", .feature = "set" },
    .{ .name = "SuppressedError", .feature = "suppressed_error" },
    .{ .name = "Symbol", .feature = "symbol" },
    .{ .name = "URL", .feature = "web_url" },
    .{ .name = "URLSearchParams", .feature = "web_url_search_params" },
    .{ .name = "Uint8Array", .feature = "typed_array_uint8" },
    .{ .name = "Uint8ClampedArray", .feature = "typed_array_uint8_clamped" },
    .{ .name = "Uint16Array", .feature = "typed_array_uint16" },
    .{ .name = "Uint32Array", .feature = "typed_array_uint32" },
    .{ .name = "WeakMap", .feature = "weak_map" },
    .{ .name = "WeakSet", .feature = "weak_set" },
    .{ .name = "atob", .feature = "web_atob" },
    .{ .name = "btoa", .feature = "web_btoa" },
    .{ .name = "clearImmediate", .feature = "web_immediate" },
    .{ .name = "escape", .feature = "escape" },
    .{ .name = "globalThis", .feature = "global_this" },
    .{ .name = "parseFloat", .feature = "parse_float" },
    .{ .name = "parseInt", .feature = "parse_int" },
    .{ .name = "queueMicrotask", .feature = "web_queue_microtask" },
    .{ .name = "self", .feature = "web_self" },
    .{ .name = "setImmediate", .feature = "web_immediate" },
    .{ .name = "setInterval", .feature = "web_timers" },
    .{ .name = "setTimeout", .feature = "web_timers" },
    .{ .name = "structuredClone", .feature = "structured_clone" },
    .{ .name = "unescape", .feature = "unescape" },
};

const prototype_member_features = [_]NameFeature{
    .{ .name = "anchor", .feature = "string_anchor" },
    .{ .name = "at", .feature = "array_at" },
    .{ .name = "at", .feature = "typed_array_at" },
    .{ .name = "big", .feature = "string_big" },
    .{ .name = "bind", .feature = "function_bind" },
    .{ .name = "blink", .feature = "string_blink" },
    .{ .name = "bold", .feature = "string_bold" },
    .{ .name = "codePointAt", .feature = "string_code_point_at" },
    .{ .name = "concat", .feature = "array_concat" },
    .{ .name = "copyWithin", .feature = "array_copy_within" },
    .{ .name = "copyWithin", .feature = "typed_array_copy_within" },
    .{ .name = "delete", .feature = "web_url_search_params_delete" },
    .{ .name = "difference", .feature = "set_difference" },
    .{ .name = "dotAll", .feature = "regexp_dot_all" },
    .{ .name = "drop", .feature = "iterator_drop" },
    .{ .name = "endsWith", .feature = "string_ends_with" },
    .{ .name = "every", .feature = "array_every" },
    .{ .name = "every", .feature = "typed_array_every" },
    .{ .name = "every", .feature = "iterator_every" },
    .{ .name = "fill", .feature = "array_fill" },
    .{ .name = "fill", .feature = "typed_array_fill" },
    .{ .name = "filter", .feature = "array_filter" },
    .{ .name = "filter", .feature = "typed_array_filter" },
    .{ .name = "filter", .feature = "iterator_filter" },
    .{ .name = "find", .feature = "array_find" },
    .{ .name = "find", .feature = "typed_array_find" },
    .{ .name = "find", .feature = "iterator_find" },
    .{ .name = "findIndex", .feature = "array_find_index" },
    .{ .name = "findIndex", .feature = "typed_array_find_index" },
    .{ .name = "findLast", .feature = "array_find_last" },
    .{ .name = "findLast", .feature = "typed_array_find_last" },
    .{ .name = "findLastIndex", .feature = "array_find_last_index" },
    .{ .name = "findLastIndex", .feature = "typed_array_find_last_index" },
    .{ .name = "fixed", .feature = "string_fixed" },
    .{ .name = "flags", .feature = "regexp_flags" },
    .{ .name = "flat", .feature = "array_flat" },
    .{ .name = "flatMap", .feature = "array_flat_map" },
    .{ .name = "flatMap", .feature = "iterator_flat_map" },
    .{ .name = "fontcolor", .feature = "string_fontcolor" },
    .{ .name = "fontsize", .feature = "string_fontsize" },
    .{ .name = "forEach", .feature = "array_for_each" },
    .{ .name = "forEach", .feature = "typed_array_for_each" },
    .{ .name = "forEach", .feature = "iterator_for_each" },
    .{ .name = "forEach", .feature = "web_dom_collections_for_each" },
    .{ .name = "getFloat16", .feature = "data_view_get_float16" },
    .{ .name = "getOrInsert", .feature = "map_get_or_insert" },
    .{ .name = "getOrInsert", .feature = "weak_map_get_or_insert" },
    .{ .name = "getOrInsertComputed", .feature = "map_get_or_insert_computed" },
    .{ .name = "getOrInsertComputed", .feature = "weak_map_get_or_insert_computed" },
    .{ .name = "has", .feature = "web_url_search_params_has" },
    .{ .name = "includes", .feature = "array_includes" },
    .{ .name = "includes", .feature = "string_includes" },
    .{ .name = "includes", .feature = "typed_array_includes" },
    .{ .name = "indexOf", .feature = "array_index_of" },
    .{ .name = "indexOf", .feature = "typed_array_index_of" },
    .{ .name = "intersection", .feature = "set_intersection" },
    .{ .name = "isDisjointFrom", .feature = "set_is_disjoint_from" },
    .{ .name = "isSubsetOf", .feature = "set_is_subset_of" },
    .{ .name = "isSupersetOf", .feature = "set_is_superset_of" },
    .{ .name = "isWellFormed", .feature = "string_is_well_formed" },
    .{ .name = "italics", .feature = "string_italics" },
    .{ .name = "join", .feature = "array_join" },
    .{ .name = "join", .feature = "typed_array_join" },
    .{ .name = "lastIndexOf", .feature = "array_last_index_of" },
    .{ .name = "lastIndexOf", .feature = "typed_array_last_index_of" },
    .{ .name = "link", .feature = "string_link" },
    .{ .name = "map", .feature = "array_map" },
    .{ .name = "map", .feature = "typed_array_map" },
    .{ .name = "map", .feature = "iterator_map" },
    .{ .name = "matchAll", .feature = "string_match_all" },
    .{ .name = "padEnd", .feature = "string_pad_end" },
    .{ .name = "padStart", .feature = "string_pad_start" },
    .{ .name = "push", .feature = "array_push" },
    .{ .name = "reduce", .feature = "array_reduce" },
    .{ .name = "reduce", .feature = "typed_array_reduce" },
    .{ .name = "reduce", .feature = "iterator_reduce" },
    .{ .name = "reduceRight", .feature = "array_reduce_right" },
    .{ .name = "reduceRight", .feature = "typed_array_reduce_right" },
    .{ .name = "repeat", .feature = "string_repeat" },
    .{ .name = "replaceAll", .feature = "string_replace_all" },
    .{ .name = "reverse", .feature = "array_reverse" },
    .{ .name = "reverse", .feature = "typed_array_reverse" },
    .{ .name = "set", .feature = "typed_array_set" },
    .{ .name = "setFloat16", .feature = "data_view_set_float16" },
    .{ .name = "setFromBase64", .feature = "uint8_array_set_from_base64" },
    .{ .name = "setFromHex", .feature = "uint8_array_set_from_hex" },
    .{ .name = "size", .feature = "web_url_search_params_size" },
    .{ .name = "slice", .feature = "array_slice" },
    .{ .name = "slice", .feature = "typed_array_slice" },
    .{ .name = "slice", .feature = "array_buffer_slice" },
    .{ .name = "small", .feature = "string_small" },
    .{ .name = "some", .feature = "array_some" },
    .{ .name = "some", .feature = "typed_array_some" },
    .{ .name = "some", .feature = "iterator_some" },
    .{ .name = "sort", .feature = "array_sort" },
    .{ .name = "sort", .feature = "typed_array_sort" },
    .{ .name = "splice", .feature = "array_splice" },
    .{ .name = "startsWith", .feature = "string_starts_with" },
    .{ .name = "sticky", .feature = "regexp_sticky" },
    .{ .name = "strike", .feature = "string_strike" },
    .{ .name = "sub", .feature = "string_sub" },
    .{ .name = "subarray", .feature = "typed_array_subarray" },
    .{ .name = "substr", .feature = "string_substr" },
    .{ .name = "sup", .feature = "string_sup" },
    .{ .name = "symmetricDifference", .feature = "set_symmetric_difference" },
    .{ .name = "take", .feature = "iterator_take" },
    .{ .name = "toArray", .feature = "iterator_to_array" },
    .{ .name = "toBase64", .feature = "uint8_array_to_base64" },
    .{ .name = "toFixed", .feature = "number_to_fixed" },
    .{ .name = "toExponential", .feature = "number_to_exponential" },
    .{ .name = "toHex", .feature = "uint8_array_to_hex" },
    .{ .name = "toISOString", .feature = "date_to_iso_string" },
    .{ .name = "toJSON", .feature = "web_url_to_json" },
    .{ .name = "toPrecision", .feature = "number_to_precision" },
    .{ .name = "toReversed", .feature = "array_to_reversed" },
    .{ .name = "toReversed", .feature = "typed_array_to_reversed" },
    .{ .name = "toSorted", .feature = "array_to_sorted" },
    .{ .name = "toSorted", .feature = "typed_array_to_sorted" },
    .{ .name = "toSpliced", .feature = "array_to_spliced" },
    .{ .name = "toWellFormed", .feature = "string_to_well_formed" },
    .{ .name = "transfer", .feature = "array_buffer_transfer" },
    .{ .name = "transferToFixedLength", .feature = "array_buffer_transfer_to_fixed_length" },
    .{ .name = "trim", .feature = "string_trim" },
    .{ .name = "trimEnd", .feature = "string_trim_end" },
    .{ .name = "trimLeft", .feature = "string_trim_start" },
    .{ .name = "trimRight", .feature = "string_trim_end" },
    .{ .name = "trimStart", .feature = "string_trim_start" },
    .{ .name = "union", .feature = "set_union" },
    .{ .name = "unshift", .feature = "array_unshift" },
    .{ .name = "with", .feature = "array_with" },
    .{ .name = "with", .feature = "typed_array_with" },
    .{ .name = "__defineGetter__", .feature = "object_define_getter" },
    .{ .name = "__defineSetter__", .feature = "object_define_setter" },
    .{ .name = "__lookupGetter__", .feature = "object_lookup_getter" },
    .{ .name = "__lookupSetter__", .feature = "object_lookup_setter" },
    .{ .name = "__proto__", .feature = "object_proto" },
};

const static_member_features = [_]NameFeature{
    .{ .name = "Array.from", .feature = "array_from" },
    .{ .name = "Array.fromAsync", .feature = "array_from_async" },
    .{ .name = "Array.isArray", .feature = "array_is_array" },
    .{ .name = "Array.of", .feature = "array_of" },
    .{ .name = "ArrayBuffer.isView", .feature = "array_buffer_is_view" },
    .{ .name = "Date.now", .feature = "date_now" },
    .{ .name = "Error.isError", .feature = "error_is_error" },
    .{ .name = "Iterator.from", .feature = "iterator_from" },
    .{ .name = "JSON.isRawJSON", .feature = "json_is_raw_json" },
    .{ .name = "JSON.parse", .feature = "json_parse" },
    .{ .name = "JSON.rawJSON", .feature = "json_raw_json" },
    .{ .name = "JSON.stringify", .feature = "json_stringify" },
    .{ .name = "Map.groupBy", .feature = "map_group_by" },
    .{ .name = "Math.acosh", .feature = "math_acosh" },
    .{ .name = "Math.asinh", .feature = "math_asinh" },
    .{ .name = "Math.atanh", .feature = "math_atanh" },
    .{ .name = "Math.cbrt", .feature = "math_cbrt" },
    .{ .name = "Math.clz32", .feature = "math_clz32" },
    .{ .name = "Math.cosh", .feature = "math_cosh" },
    .{ .name = "Math.expm1", .feature = "math_expm1" },
    .{ .name = "Math.f16round", .feature = "math_f16round" },
    .{ .name = "Math.fround", .feature = "math_fround" },
    .{ .name = "Math.hypot", .feature = "math_hypot" },
    .{ .name = "Math.imul", .feature = "math_imul" },
    .{ .name = "Math.log10", .feature = "math_log10" },
    .{ .name = "Math.log1p", .feature = "math_log1p" },
    .{ .name = "Math.log2", .feature = "math_log2" },
    .{ .name = "Math.sign", .feature = "math_sign" },
    .{ .name = "Math.sinh", .feature = "math_sinh" },
    .{ .name = "Math.sumPrecise", .feature = "math_sum_precise" },
    .{ .name = "Math.tanh", .feature = "math_tanh" },
    .{ .name = "Math.trunc", .feature = "math_trunc" },
    .{ .name = "Number.EPSILON", .feature = "number_epsilon" },
    .{ .name = "Number.MAX_SAFE_INTEGER", .feature = "number_max_safe_integer" },
    .{ .name = "Number.MIN_SAFE_INTEGER", .feature = "number_min_safe_integer" },
    .{ .name = "Number.isFinite", .feature = "number_is_finite" },
    .{ .name = "Number.isInteger", .feature = "number_is_integer" },
    .{ .name = "Number.isNaN", .feature = "number_is_nan" },
    .{ .name = "Number.isSafeInteger", .feature = "number_is_safe_integer" },
    .{ .name = "Number.parseFloat", .feature = "number_parse_float" },
    .{ .name = "Number.parseInt", .feature = "number_parse_int" },
    .{ .name = "Object.assign", .feature = "object_assign" },
    .{ .name = "Object.create", .feature = "object_create" },
    .{ .name = "Object.defineProperties", .feature = "object_define_properties" },
    .{ .name = "Object.defineProperty", .feature = "object_define_property" },
    .{ .name = "Object.entries", .feature = "object_entries" },
    .{ .name = "Object.freeze", .feature = "object_freeze" },
    .{ .name = "Object.fromEntries", .feature = "object_from_entries" },
    .{ .name = "Object.getOwnPropertyDescriptor", .feature = "object_get_own_property_descriptor" },
    .{ .name = "Object.getOwnPropertyDescriptors", .feature = "object_get_own_property_descriptors" },
    .{ .name = "Object.getOwnPropertyNames", .feature = "object_get_own_property_names" },
    .{ .name = "Object.getPrototypeOf", .feature = "object_get_prototype_of" },
    .{ .name = "Object.groupBy", .feature = "object_group_by" },
    .{ .name = "Object.hasOwn", .feature = "object_has_own" },
    .{ .name = "Object.is", .feature = "object_is" },
    .{ .name = "Object.isExtensible", .feature = "object_is_extensible" },
    .{ .name = "Object.isFrozen", .feature = "object_is_frozen" },
    .{ .name = "Object.isSealed", .feature = "object_is_sealed" },
    .{ .name = "Object.keys", .feature = "object_keys" },
    .{ .name = "Object.preventExtensions", .feature = "object_prevent_extensions" },
    .{ .name = "Object.seal", .feature = "object_seal" },
    .{ .name = "Object.setPrototypeOf", .feature = "object_set_prototype_of" },
    .{ .name = "Object.values", .feature = "object_values" },
    .{ .name = "Promise.allSettled", .feature = "promise_all_settled" },
    .{ .name = "Promise.any", .feature = "promise_any" },
    .{ .name = "Promise.try", .feature = "promise_try" },
    .{ .name = "Promise.withResolvers", .feature = "promise_with_resolvers" },
    .{ .name = "Reflect.apply", .feature = "reflect_apply" },
    .{ .name = "Reflect.construct", .feature = "reflect_construct" },
    .{ .name = "Reflect.defineProperty", .feature = "reflect_define_property" },
    .{ .name = "Reflect.deleteProperty", .feature = "reflect_delete_property" },
    .{ .name = "Reflect.get", .feature = "reflect_get" },
    .{ .name = "Reflect.getOwnPropertyDescriptor", .feature = "reflect_get_own_property_descriptor" },
    .{ .name = "Reflect.getPrototypeOf", .feature = "reflect_get_prototype_of" },
    .{ .name = "Reflect.has", .feature = "reflect_has" },
    .{ .name = "Reflect.isExtensible", .feature = "reflect_is_extensible" },
    .{ .name = "Reflect.ownKeys", .feature = "reflect_own_keys" },
    .{ .name = "Reflect.preventExtensions", .feature = "reflect_prevent_extensions" },
    .{ .name = "Reflect.set", .feature = "reflect_set" },
    .{ .name = "Reflect.setPrototypeOf", .feature = "reflect_set_prototype_of" },
    .{ .name = "RegExp.escape", .feature = "regexp_escape" },
    .{ .name = "String.fromCodePoint", .feature = "string_from_code_point" },
    .{ .name = "String.raw", .feature = "string_raw" },
    .{ .name = "Symbol.asyncDispose", .feature = "symbol_async_dispose" },
    .{ .name = "Symbol.asyncIterator", .feature = "symbol_async_iterator" },
    .{ .name = "Symbol.dispose", .feature = "symbol_dispose" },
    .{ .name = "Symbol.hasInstance", .feature = "symbol_has_instance" },
    .{ .name = "Symbol.isConcatSpreadable", .feature = "symbol_is_concat_spreadable" },
    .{ .name = "Symbol.iterator", .feature = "symbol_iterator" },
    .{ .name = "Symbol.iterator", .feature = "web_dom_collections_iterator" },
    .{ .name = "Symbol.match", .feature = "symbol_match" },
    .{ .name = "Symbol.matchAll", .feature = "symbol_match_all" },
    .{ .name = "Symbol.replace", .feature = "symbol_replace" },
    .{ .name = "Symbol.search", .feature = "symbol_search" },
    .{ .name = "Symbol.species", .feature = "symbol_species" },
    .{ .name = "Symbol.split", .feature = "symbol_split" },
    .{ .name = "Symbol.toPrimitive", .feature = "symbol_to_primitive" },
    .{ .name = "Symbol.toStringTag", .feature = "symbol_to_string_tag" },
    .{ .name = "Symbol.unscopables", .feature = "symbol_unscopables" },
    .{ .name = "URL.canParse", .feature = "web_url_can_parse" },
    .{ .name = "URL.parse", .feature = "web_url_parse" },
    .{ .name = "Uint8Array.fromBase64", .feature = "uint8_array_from_base64" },
    .{ .name = "Uint8Array.fromHex", .feature = "uint8_array_from_hex" },
};

pub fn collectModuleUsage(allocator: std.mem.Allocator, module: *const Module) !FeatureSet {
    if (!module.module_type.isJavaScriptLike()) return .{};
    const ast = &(module.ast orelse return .{});
    const semantic = &(module.semantic orelse return .{});
    return collectAstUsage(allocator, ast, semantic);
}

fn collectAstUsage(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    semantic: *const ModuleSemanticData,
) !FeatureSet {
    if (ast.nodes.items.len == 0) return .{};

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, ast);
    defer allocator.free(reachable);

    var skip_identifiers = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);
    defer skip_identifiers.deinit();
    markSkippedIdentifiers(ast, reachable, &skip_identifiers);

    var out: FeatureSet = .{};
    for (reachable) |ni| {
        const node = ast.nodes.items[ni];
        switch (node.tag) {
            .static_member_expression => try recordStaticMemberUsage(allocator, ast, semantic, @enumFromInt(ni), node, &out),
            .identifier_reference => {
                if (!skip_identifiers.isSet(ni)) try recordIdentifierUsage(allocator, ast, semantic, @enumFromInt(ni), &out);
            },
            else => {},
        }
    }
    return out;
}

fn markSkippedIdentifiers(ast: *const Ast, reachable: []const u32, skip: *std.DynamicBitSet) void {
    for (reachable) |ni| {
        const node = ast.nodes.items[ni];
        switch (node.tag) {
            .static_member_expression => {
                const prop = ast.readExtraNode(node.data.extra, 1);
                setSkip(skip, prop);
            },
            .computed_member_expression => {
                const obj = ast.readExtraNode(node.data.extra, 0);
                const prop = ast.readExtraNode(node.data.extra, 1);
                setSkip(skip, obj);
                setSkip(skip, prop);
            },
            .object_property => {
                if (!node.data.binary.right.isNone()) setSkip(skip, node.data.binary.left);
            },
            .method_definition, .property_definition, .accessor_property => {
                const key = ast.readExtraNode(node.data.extra, 0);
                setSkip(skip, key);
            },
            .import_specifier, .import_default_specifier, .import_namespace_specifier, .export_specifier => {
                var it = ast_walk.children(ast, node);
                while (it.next()) |child| setSkip(skip, child);
            },
            else => {},
        }
    }
}

fn setSkip(skip: *std.DynamicBitSet, idx: NodeIndex) void {
    if (idx.isNone()) return;
    const raw = @intFromEnum(idx);
    if (raw < skip.capacity()) skip.set(raw);
}

fn recordStaticMemberUsage(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    semantic: *const ModuleSemanticData,
    idx: NodeIndex,
    node: Node,
    out: *FeatureSet,
) !void {
    const obj_idx = ast.readExtraNode(node.data.extra, 0);
    const prop_idx = ast.readExtraNode(node.data.extra, 1);
    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return;

    const prop_node = ast.getNode(prop_idx);
    if (prop_node.tag != .identifier_reference) return;
    const prop_name = ast.getText(prop_node.data.string_ref);

    try insertFeaturesForName(allocator, out, prop_name, &prototype_member_features);
    if (globalReferenceName(ast, semantic, obj_idx)) |global_name| {
        try insertStaticMemberFeatures(allocator, out, global_name, prop_name);
    }

    try recordGlobalReferenceUsage(allocator, ast, semantic, idx, out);
    try recordGlobalReferenceUsage(allocator, ast, semantic, obj_idx, out);
}

fn recordIdentifierUsage(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    semantic: *const ModuleSemanticData,
    idx: NodeIndex,
    out: *FeatureSet,
) !void {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return;
    const node = ast.getNode(idx);
    if (node.tag != .identifier_reference) return;
    const name = ast.getText(node.data.string_ref);
    if (!isGlobalIdentifierNamed(ast, semantic, idx, name)) return;

    try insertFeatureForGlobalName(allocator, name, out);
}

fn recordGlobalReferenceUsage(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    semantic: *const ModuleSemanticData,
    idx: NodeIndex,
    out: *FeatureSet,
) !void {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return;
    const node = ast.getNode(idx);
    if (node.tag == .identifier_reference) {
        try recordIdentifierUsage(allocator, ast, semantic, idx, out);
        return;
    }
    if (node.tag != .static_member_expression) return;

    const obj_idx = ast.readExtraNode(node.data.extra, 0);
    const prop_idx = ast.readExtraNode(node.data.extra, 1);
    if (!isGlobalIdentifierNamed(ast, semantic, obj_idx, "globalThis")) return;
    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return;

    const prop_node = ast.getNode(prop_idx);
    if (prop_node.tag != .identifier_reference) return;
    const name = ast.getText(prop_node.data.string_ref);
    try insertFeatureForGlobalName(allocator, name, out);
}

fn insertFeatureForGlobalName(allocator: std.mem.Allocator, name: []const u8, out: *FeatureSet) !void {
    try insertFeaturesForName(allocator, out, name, &global_features);
}

fn insertFeaturesForName(
    allocator: std.mem.Allocator,
    out: *FeatureSet,
    name: []const u8,
    mappings: []const NameFeature,
) !void {
    for (mappings) |mapping| {
        if (std.mem.eql(u8, name, mapping.name)) {
            try out.insert(allocator, mapping.feature);
        }
    }
}

fn insertStaticMemberFeatures(
    allocator: std.mem.Allocator,
    out: *FeatureSet,
    object_name: []const u8,
    property_name: []const u8,
) !void {
    var buf: [96]u8 = undefined;
    if (object_name.len + property_name.len + 1 > buf.len) return;
    @memcpy(buf[0..object_name.len], object_name);
    buf[object_name.len] = '.';
    @memcpy(buf[object_name.len + 1 .. object_name.len + 1 + property_name.len], property_name);
    const key = buf[0 .. object_name.len + 1 + property_name.len];
    try insertFeaturesForName(allocator, out, key, &static_member_features);

    if (std.mem.eql(u8, object_name, "Promise")) {
        if (std.mem.eql(u8, property_name, "all") or
            std.mem.eql(u8, property_name, "race") or
            std.mem.eql(u8, property_name, "reject") or
            std.mem.eql(u8, property_name, "resolve"))
        {
            try out.insert(allocator, "promise");
        }
    } else if (isTypedArrayGlobalName(object_name)) {
        if (std.mem.eql(u8, property_name, "from")) {
            try out.insert(allocator, "typed_array_from");
        } else if (std.mem.eql(u8, property_name, "of")) {
            try out.insert(allocator, "typed_array_of");
        }
    }
}

fn isGlobalReferenceNamed(
    ast: *const Ast,
    semantic: *const ModuleSemanticData,
    idx: NodeIndex,
    expected: []const u8,
) bool {
    if (isGlobalIdentifierNamed(ast, semantic, idx, expected)) return true;
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return false;
    const node = ast.getNode(idx);
    if (node.tag != .static_member_expression) return false;

    const obj_idx = ast.readExtraNode(node.data.extra, 0);
    const prop_idx = ast.readExtraNode(node.data.extra, 1);
    if (!isGlobalIdentifierNamed(ast, semantic, obj_idx, "globalThis")) return false;
    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return false;

    const prop_node = ast.getNode(prop_idx);
    if (prop_node.tag != .identifier_reference) return false;
    return std.mem.eql(u8, ast.getText(prop_node.data.string_ref), expected);
}

fn globalReferenceName(
    ast: *const Ast,
    semantic: *const ModuleSemanticData,
    idx: NodeIndex,
) ?[]const u8 {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return null;
    const node = ast.getNode(idx);
    if (node.tag == .identifier_reference) {
        const name = ast.getText(node.data.string_ref);
        return if (isGlobalIdentifierNamed(ast, semantic, idx, name)) name else null;
    }
    if (node.tag != .static_member_expression) return null;

    const obj_idx = ast.readExtraNode(node.data.extra, 0);
    const prop_idx = ast.readExtraNode(node.data.extra, 1);
    if (!isGlobalIdentifierNamed(ast, semantic, obj_idx, "globalThis")) return null;
    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return null;

    const prop_node = ast.getNode(prop_idx);
    if (prop_node.tag != .identifier_reference) return null;
    return ast.getText(prop_node.data.string_ref);
}

fn isTypedArrayGlobalName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Int8Array") or
        std.mem.eql(u8, name, "Int16Array") or
        std.mem.eql(u8, name, "Int32Array") or
        std.mem.eql(u8, name, "Uint8Array") or
        std.mem.eql(u8, name, "Uint8ClampedArray") or
        std.mem.eql(u8, name, "Uint16Array") or
        std.mem.eql(u8, name, "Uint32Array") or
        std.mem.eql(u8, name, "Float32Array") or
        std.mem.eql(u8, name, "Float64Array");
}

fn isGlobalIdentifierNamed(
    ast: *const Ast,
    semantic: *const ModuleSemanticData,
    idx: NodeIndex,
    expected: []const u8,
) bool {
    if (idx.isNone()) return false;
    const raw = @intFromEnum(idx);
    if (raw >= ast.nodes.items.len or raw >= semantic.symbol_ids.len) return false;
    const node = ast.nodes.items[raw];
    if (node.tag != .identifier_reference) return false;
    const name = ast.getText(node.data.string_ref);
    return std.mem.eql(u8, name, expected) and
        semantic.symbol_ids[raw] == null and
        semantic.unresolved_references.contains(expected);
}

test "runtime polyfill collector detects v1 global and member usage" {
    const usage = try testCollect(
        \\const a = "a".replaceAll("a", "b");
        \\const b = values.at(0);
        \\const c = Object.hasOwn({ a: 1 }, "a");
        \\const d = structuredClone(c);
        \\const e = new Map();
        \\const f = new Set();
        \\const g = Promise.resolve(d);
        \\void [a, b, c, d, e, f, g];
    );
    try std.testing.expect(usage.has("string_replace_all"));
    try std.testing.expect(usage.has("array_at"));
    try std.testing.expect(usage.has("object_has_own"));
    try std.testing.expect(usage.has("structured_clone"));
    try std.testing.expect(usage.has("map"));
    try std.testing.expect(usage.has("set"));
    try std.testing.expect(usage.has("promise"));
}

test "runtime polyfill collector detects explicit globalThis references" {
    const usage = try testCollect(
        \\const a = new globalThis.Map();
        \\const b = new globalThis.Set();
        \\const c = globalThis.Promise.resolve(a);
        \\const d = globalThis.structuredClone(b);
        \\const e = globalThis.Object.hasOwn({ a: 1 }, "a");
        \\void [a, b, c, d, e];
    );
    try std.testing.expect(usage.has("map"));
    try std.testing.expect(usage.has("set"));
    try std.testing.expect(usage.has("promise"));
    try std.testing.expect(usage.has("structured_clone"));
    try std.testing.expect(usage.has("object_has_own"));
}

test "runtime polyfill collector detects expanded core-js built-ins" {
    const usage = try testCollect(
        \\const a = Object.values({ a: 1 });
        \\const b = [1, 2, 3].findLast((value) => value < 3);
        \\const c = "7".padStart(2, "0");
        \\const d = Math.trunc(1.8);
        \\const e = Reflect.ownKeys({ x: 1 });
        \\const f = Promise.any([Promise.resolve(1)]);
        \\const g = Symbol.iterator;
        \\const h = new WeakMap();
        \\const i = URL.canParse("https://example.com");
        \\const j = new Uint8Array(4).toReversed();
        \\const k = Iterator.from([1, 2]).take(1).toArray();
        \\const l = ArrayBuffer.isView(j);
        \\const m = queueMicrotask(() => {});
        \\void [a, b, c, d, e, f, g, h, i, k, l, m];
    );
    try std.testing.expect(usage.has("object_values"));
    try std.testing.expect(usage.has("array_find_last"));
    try std.testing.expect(usage.has("string_pad_start"));
    try std.testing.expect(usage.has("math_trunc"));
    try std.testing.expect(usage.has("reflect_own_keys"));
    try std.testing.expect(usage.has("promise_any"));
    try std.testing.expect(usage.has("symbol_iterator"));
    try std.testing.expect(usage.has("weak_map"));
    try std.testing.expect(usage.has("web_url_can_parse"));
    try std.testing.expect(usage.has("typed_array_uint8"));
    try std.testing.expect(usage.has("typed_array_to_reversed"));
    try std.testing.expect(usage.has("iterator_from"));
    try std.testing.expect(usage.has("iterator_take"));
    try std.testing.expect(usage.has("iterator_to_array"));
    try std.testing.expect(usage.has("array_buffer_is_view"));
    try std.testing.expect(usage.has("web_queue_microtask"));
}

test "runtime polyfill collector ignores shadowed and imported globals" {
    const usage = try testCollect(
        \\import { Map, Object as ImportedObject } from "pkg";
        \\const Promise = { resolve() {} };
        \\function run(structuredClone) {
        \\  const Set = class {};
        \\  new Map();
        \\  new Set();
        \\  Promise.resolve();
        \\  ImportedObject.hasOwn({}, "x");
        \\  structuredClone({});
        \\}
        \\run();
    );
    try std.testing.expect(!usage.has("map"));
    try std.testing.expect(!usage.has("set"));
    try std.testing.expect(!usage.has("promise"));
    try std.testing.expect(!usage.has("object_has_own"));
    try std.testing.expect(!usage.has("structured_clone"));
}

test "runtime polyfill collector ignores type-only references and shadowed globalThis" {
    const usage = try testCollectTyped(
        \\type Cache = Map<string, Set<number>>;
        \\interface Work {
        \\  done: Promise<void>;
        \\}
        \\const globalThis = {
        \\  Map: class {},
        \\  Promise: { resolve() {} },
        \\  Object: { hasOwn() { return true; } },
        \\};
        \\new globalThis.Map();
        \\globalThis.Promise.resolve();
        \\globalThis.Object.hasOwn({}, "x");
    );
    try std.testing.expect(!usage.has("map"));
    try std.testing.expect(!usage.has("set"));
    try std.testing.expect(!usage.has("promise"));
    try std.testing.expect(!usage.has("object_has_own"));
}

test "runtime polyfill collector ignores dynamic computed member access" {
    const usage = try testCollect(
        \\const method = "resolve";
        \\Promise[method]();
        \\value[method]("x");
        \\globalThis["Map"];
        \\globalThis.Object["hasOwn"]({}, "x");
    );
    try std.testing.expect(!usage.has("promise"));
    try std.testing.expect(!usage.has("map"));
    try std.testing.expect(!usage.has("object_has_own"));
    try std.testing.expect(!usage.has("string_replace_all"));
    try std.testing.expect(!usage.has("array_at"));
}

fn testCollect(source: []const u8) !FeatureSet {
    return testCollectWithModuleType(source, .js);
}

fn testCollectTyped(source: []const u8) !FeatureSet {
    return testCollectWithModuleType(source, .ts);
}

fn testCollectWithModuleType(source: []const u8, module_type: ModuleType) !FeatureSet {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    const parser_flags = module_type.toParserFlags();
    parser.configureForBundlerKind(parser_flags.is_ts, parser_flags.is_jsx);
    parser.enable_scan = true;
    _ = try parser.parse();

    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();

    var module = Module.init(.none, "input.js");
    module.source = source;
    module.module_type = module_type;
    module.ast = parser.ast;
    module.semantic = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .exported_names = analyzer.exported_names,
        .symbol_ids = analyzer.symbol_ids.items,
        .unresolved_references = analyzer.unresolved_references,
        .references = analyzer.references.items,
        .numeric_const_texts = analyzer.numeric_const_texts,
    };
    return collectModuleUsage(allocator, &module);
}
