import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';

export type RuntimePolyfillMode = 'auto' | 'usage' | 'entry';
export type RuntimePolyfillProvider = 'core-js';

export interface RuntimePolyfillOptions {
  /**
   * Runtime polyfill injection strategy.
   *
   * `auto` and `usage` select from graph-detected API usage, while `entry`
   * injects all target-required core-js ES/Web modules.
   */
  mode?: RuntimePolyfillMode;
  /** Polyfill provider. Only `core-js` is currently supported. */
  provider?: RuntimePolyfillProvider;
  /**
   * Browserslist targets for core-js-compat, matching Rspack/SWC `env.targets`.
   *
   * Examples: `["chrome >= 87", "edge >= 88", "firefox >= 78", "safari >= 14"]`.
   * Physical device names such as `"iPhone 8"` and compact shorthands such as
   * `"ios12"` are rejected.
   */
  targets?: string | string[];
  /** core-js version used for compatibility calculation, matching Rspack/SWC `env.coreJs`. */
  coreJs?: string;
  /** Additional core-js modules to force into the runtime prelude. */
  include?: string[];
  /** core-js modules to remove after target and usage calculation. */
  exclude?: string[];
  /** Include proposal polyfills when querying core-js-compat. */
  proposals?: boolean;
}

export type RuntimePolyfillsOption = 'off' | RuntimePolyfillMode | RuntimePolyfillOptions;

export interface RuntimePolyfillBuildOptions {
  entryPoints: string[];
  platform?: string;
  target?: string;
  browserslist?: string | string[];
  runtimePolyfills?: RuntimePolyfillsOption;
  coreJs?: string;
  runBeforeMain?: string[];
  resolveExtensions?: string[];
}

interface NormalizedRuntimePolyfills {
  mode: RuntimePolyfillMode;
  provider: RuntimePolyfillProvider;
  targets: CoreJsTargets;
  include: string[];
  exclude: string[];
  proposals: boolean;
  coreJsVersion?: string;
}

type CoreJsTargetObject = Record<string, string | number>;
type CoreJsTargets = string | string[] | CoreJsTargetObject;

type RuntimeRequire = ReturnType<typeof createRequire>;

type CoreJsCompat = (options: {
  targets: CoreJsTargets;
  version?: string;
  modules?: string[] | RegExp;
  proposals?: boolean;
}) => { list: string[] };

type RuntimePolyfillFeature = string;

export interface ResolvedRuntimeModule {
  module: string;
  path: string;
}

export interface ResolvedRuntimeCandidate extends ResolvedRuntimeModule {
  feature: RuntimePolyfillFeature;
}

/** NAPI 로 전달되는 단일 plan 객체. usage 모드는 candidates, entry 모드는 entry 를 채운다. */
export interface RuntimePolyfillNativePlan {
  mode: 'usage' | 'entry';
  candidates?: readonly ResolvedRuntimeCandidate[];
  entry?: readonly ResolvedRuntimeModule[];
  include?: readonly ResolvedRuntimeModule[];
  exclude?: readonly string[];
}

let runtimeRequireOverride: RuntimeRequire | null = null;

function getRuntimeRequire(): RuntimeRequire {
  return runtimeRequireOverride ?? createRequire(import.meta.url);
}

/** @internal */
export const __runtimePolyfillTestHooks = {
  reset() {
    coreJsCompatCache = undefined;
    coreJsVersionCache = undefined;
    runtimeRequireOverride = null;
  },
  setRuntimeRequire(runtimeRequire: RuntimeRequire | null) {
    coreJsCompatCache = undefined;
    coreJsVersionCache = undefined;
    runtimeRequireOverride = runtimeRequire;
  },
};

/** @internal — Zig 매핑 테이블과의 sync 검증용. 외부 사용자는 사용 금지. */
export const __runtimePolyfillTestInternals = {
  get featureModules() {
    return RUNTIME_POLYFILL_FEATURE_MODULES;
  },
};

const ES_TARGETS = new Set([
  'es5',
  'es2015',
  'es2016',
  'es2017',
  'es2018',
  'es2019',
  'es2020',
  'es2021',
  'es2022',
  'es2023',
  'es2024',
  'es2025',
  'esnext',
]);

const DEVICE_TARGET_RE =
  /\b(?:iphone|ipad|ipod|galaxy|pixel|nexus|oneplus|xiaomi|redmi|huawei|motorola|moto)\b/i;

const RUNTIME_POLYFILL_FEATURE_MODULES: readonly {
  feature: RuntimePolyfillFeature;
  module: string;
}[] = [
  { feature: 'aggregate_error', module: 'es.aggregate-error' },
  { feature: 'aggregate_error', module: 'es.aggregate-error.cause' },
  { feature: 'array_buffer', module: 'es.array-buffer.constructor' },
  { feature: 'array_buffer_detached', module: 'es.array-buffer.detached' },
  { feature: 'array_buffer_is_view', module: 'es.array-buffer.is-view' },
  { feature: 'array_buffer_slice', module: 'es.array-buffer.slice' },
  { feature: 'array_buffer_transfer', module: 'es.array-buffer.transfer' },
  {
    feature: 'array_buffer_transfer_to_fixed_length',
    module: 'es.array-buffer.transfer-to-fixed-length',
  },
  { feature: 'array_at', module: 'es.array.at' },
  { feature: 'array_concat', module: 'es.array.concat' },
  { feature: 'array_copy_within', module: 'es.array.copy-within' },
  { feature: 'array_every', module: 'es.array.every' },
  { feature: 'array_fill', module: 'es.array.fill' },
  { feature: 'array_filter', module: 'es.array.filter' },
  { feature: 'array_find', module: 'es.array.find' },
  { feature: 'array_find_index', module: 'es.array.find-index' },
  { feature: 'array_find_last', module: 'es.array.find-last' },
  { feature: 'array_find_last_index', module: 'es.array.find-last-index' },
  { feature: 'array_flat', module: 'es.array.flat' },
  { feature: 'array_flat_map', module: 'es.array.flat-map' },
  { feature: 'array_for_each', module: 'es.array.for-each' },
  { feature: 'array_from', module: 'es.array.from' },
  { feature: 'array_from_async', module: 'es.array.from-async' },
  { feature: 'array_includes', module: 'es.array.includes' },
  { feature: 'array_index_of', module: 'es.array.index-of' },
  { feature: 'array_is_array', module: 'es.array.is-array' },
  { feature: 'array_join', module: 'es.array.join' },
  { feature: 'array_last_index_of', module: 'es.array.last-index-of' },
  { feature: 'array_map', module: 'es.array.map' },
  { feature: 'array_of', module: 'es.array.of' },
  { feature: 'array_push', module: 'es.array.push' },
  { feature: 'array_reduce', module: 'es.array.reduce' },
  { feature: 'array_reduce_right', module: 'es.array.reduce-right' },
  { feature: 'array_reverse', module: 'es.array.reverse' },
  { feature: 'array_slice', module: 'es.array.slice' },
  { feature: 'array_some', module: 'es.array.some' },
  { feature: 'array_sort', module: 'es.array.sort' },
  { feature: 'array_splice', module: 'es.array.splice' },
  { feature: 'array_to_reversed', module: 'es.array.to-reversed' },
  { feature: 'array_to_sorted', module: 'es.array.to-sorted' },
  { feature: 'array_to_spliced', module: 'es.array.to-spliced' },
  { feature: 'array_unshift', module: 'es.array.unshift' },
  { feature: 'array_with', module: 'es.array.with' },
  { feature: 'async_disposable_stack', module: 'es.async-disposable-stack.constructor' },
  { feature: 'data_view', module: 'es.data-view' },
  { feature: 'data_view_get_float16', module: 'es.data-view.get-float16' },
  { feature: 'data_view_set_float16', module: 'es.data-view.set-float16' },
  { feature: 'date_now', module: 'es.date.now' },
  { feature: 'date_to_iso_string', module: 'es.date.to-iso-string' },
  { feature: 'disposable_stack', module: 'es.disposable-stack.constructor' },
  { feature: 'error_is_error', module: 'es.error.is-error' },
  { feature: 'escape', module: 'es.escape' },
  { feature: 'function_bind', module: 'es.function.bind' },
  { feature: 'global_this', module: 'es.global-this' },
  { feature: 'iterator', module: 'es.iterator.constructor' },
  { feature: 'iterator_drop', module: 'es.iterator.drop' },
  { feature: 'iterator_every', module: 'es.iterator.every' },
  { feature: 'iterator_filter', module: 'es.iterator.filter' },
  { feature: 'iterator_find', module: 'es.iterator.find' },
  { feature: 'iterator_flat_map', module: 'es.iterator.flat-map' },
  { feature: 'iterator_for_each', module: 'es.iterator.for-each' },
  { feature: 'iterator_from', module: 'es.iterator.from' },
  { feature: 'iterator_map', module: 'es.iterator.map' },
  { feature: 'iterator_reduce', module: 'es.iterator.reduce' },
  { feature: 'iterator_some', module: 'es.iterator.some' },
  { feature: 'iterator_take', module: 'es.iterator.take' },
  { feature: 'iterator_to_array', module: 'es.iterator.to-array' },
  { feature: 'json_is_raw_json', module: 'es.json.is-raw-json' },
  { feature: 'json_parse', module: 'es.json.parse' },
  { feature: 'json_raw_json', module: 'es.json.raw-json' },
  { feature: 'json_stringify', module: 'es.json.stringify' },
  { feature: 'map', module: 'es.map' },
  { feature: 'map_get_or_insert', module: 'es.map.get-or-insert' },
  { feature: 'map_get_or_insert_computed', module: 'es.map.get-or-insert-computed' },
  { feature: 'map_group_by', module: 'es.map.group-by' },
  { feature: 'math_acosh', module: 'es.math.acosh' },
  { feature: 'math_asinh', module: 'es.math.asinh' },
  { feature: 'math_atanh', module: 'es.math.atanh' },
  { feature: 'math_cbrt', module: 'es.math.cbrt' },
  { feature: 'math_clz32', module: 'es.math.clz32' },
  { feature: 'math_cosh', module: 'es.math.cosh' },
  { feature: 'math_expm1', module: 'es.math.expm1' },
  { feature: 'math_f16round', module: 'es.math.f16round' },
  { feature: 'math_fround', module: 'es.math.fround' },
  { feature: 'math_hypot', module: 'es.math.hypot' },
  { feature: 'math_imul', module: 'es.math.imul' },
  { feature: 'math_log10', module: 'es.math.log10' },
  { feature: 'math_log1p', module: 'es.math.log1p' },
  { feature: 'math_log2', module: 'es.math.log2' },
  { feature: 'math_sign', module: 'es.math.sign' },
  { feature: 'math_sinh', module: 'es.math.sinh' },
  { feature: 'math_sum_precise', module: 'es.math.sum-precise' },
  { feature: 'math_tanh', module: 'es.math.tanh' },
  { feature: 'math_trunc', module: 'es.math.trunc' },
  { feature: 'number_constructor', module: 'es.number.constructor' },
  { feature: 'number_epsilon', module: 'es.number.epsilon' },
  { feature: 'number_is_finite', module: 'es.number.is-finite' },
  { feature: 'number_is_integer', module: 'es.number.is-integer' },
  { feature: 'number_is_nan', module: 'es.number.is-nan' },
  { feature: 'number_is_safe_integer', module: 'es.number.is-safe-integer' },
  { feature: 'number_max_safe_integer', module: 'es.number.max-safe-integer' },
  { feature: 'number_min_safe_integer', module: 'es.number.min-safe-integer' },
  { feature: 'number_parse_float', module: 'es.number.parse-float' },
  { feature: 'number_parse_int', module: 'es.number.parse-int' },
  { feature: 'number_to_exponential', module: 'es.number.to-exponential' },
  { feature: 'number_to_fixed', module: 'es.number.to-fixed' },
  { feature: 'number_to_precision', module: 'es.number.to-precision' },
  { feature: 'object_assign', module: 'es.object.assign' },
  { feature: 'object_create', module: 'es.object.create' },
  { feature: 'object_define_getter', module: 'es.object.define-getter' },
  { feature: 'object_define_properties', module: 'es.object.define-properties' },
  { feature: 'object_define_property', module: 'es.object.define-property' },
  { feature: 'object_define_setter', module: 'es.object.define-setter' },
  { feature: 'object_entries', module: 'es.object.entries' },
  { feature: 'object_freeze', module: 'es.object.freeze' },
  { feature: 'object_from_entries', module: 'es.object.from-entries' },
  {
    feature: 'object_get_own_property_descriptor',
    module: 'es.object.get-own-property-descriptor',
  },
  {
    feature: 'object_get_own_property_descriptors',
    module: 'es.object.get-own-property-descriptors',
  },
  { feature: 'object_get_own_property_names', module: 'es.object.get-own-property-names' },
  { feature: 'object_get_prototype_of', module: 'es.object.get-prototype-of' },
  { feature: 'object_group_by', module: 'es.object.group-by' },
  { feature: 'object_has_own', module: 'es.object.has-own' },
  { feature: 'object_is', module: 'es.object.is' },
  { feature: 'object_is_extensible', module: 'es.object.is-extensible' },
  { feature: 'object_is_frozen', module: 'es.object.is-frozen' },
  { feature: 'object_is_sealed', module: 'es.object.is-sealed' },
  { feature: 'object_keys', module: 'es.object.keys' },
  { feature: 'object_lookup_getter', module: 'es.object.lookup-getter' },
  { feature: 'object_lookup_setter', module: 'es.object.lookup-setter' },
  { feature: 'object_prevent_extensions', module: 'es.object.prevent-extensions' },
  { feature: 'object_proto', module: 'es.object.proto' },
  { feature: 'object_seal', module: 'es.object.seal' },
  { feature: 'object_set_prototype_of', module: 'es.object.set-prototype-of' },
  { feature: 'object_values', module: 'es.object.values' },
  { feature: 'parse_float', module: 'es.parse-float' },
  { feature: 'parse_int', module: 'es.parse-int' },
  { feature: 'set', module: 'es.set' },
  { feature: 'set_difference', module: 'es.set.difference.v2' },
  { feature: 'set_intersection', module: 'es.set.intersection.v2' },
  { feature: 'set_is_disjoint_from', module: 'es.set.is-disjoint-from.v2' },
  { feature: 'set_is_subset_of', module: 'es.set.is-subset-of.v2' },
  { feature: 'set_is_superset_of', module: 'es.set.is-superset-of.v2' },
  { feature: 'set_symmetric_difference', module: 'es.set.symmetric-difference.v2' },
  { feature: 'set_union', module: 'es.set.union.v2' },
  { feature: 'promise', module: 'es.promise' },
  { feature: 'promise_all_settled', module: 'es.promise.all-settled' },
  { feature: 'promise_any', module: 'es.promise.any' },
  { feature: 'promise_finally', module: 'es.promise.finally' },
  { feature: 'promise_try', module: 'es.promise.try' },
  { feature: 'promise_with_resolvers', module: 'es.promise.with-resolvers' },
  { feature: 'reflect_apply', module: 'es.reflect.apply' },
  { feature: 'reflect_construct', module: 'es.reflect.construct' },
  { feature: 'reflect_define_property', module: 'es.reflect.define-property' },
  { feature: 'reflect_delete_property', module: 'es.reflect.delete-property' },
  { feature: 'reflect_get', module: 'es.reflect.get' },
  {
    feature: 'reflect_get_own_property_descriptor',
    module: 'es.reflect.get-own-property-descriptor',
  },
  { feature: 'reflect_get_prototype_of', module: 'es.reflect.get-prototype-of' },
  { feature: 'reflect_has', module: 'es.reflect.has' },
  { feature: 'reflect_is_extensible', module: 'es.reflect.is-extensible' },
  { feature: 'reflect_own_keys', module: 'es.reflect.own-keys' },
  { feature: 'reflect_prevent_extensions', module: 'es.reflect.prevent-extensions' },
  { feature: 'reflect_set', module: 'es.reflect.set' },
  { feature: 'reflect_set_prototype_of', module: 'es.reflect.set-prototype-of' },
  { feature: 'regexp_escape', module: 'es.regexp.escape' },
  { feature: 'regexp_flags', module: 'es.regexp.flags' },
  { feature: 'regexp_sticky', module: 'es.regexp.sticky' },
  { feature: 'regexp_dot_all', module: 'es.regexp.dot-all' },
  { feature: 'structured_clone', module: 'web.structured-clone' },
  { feature: 'string_anchor', module: 'es.string.anchor' },
  { feature: 'string_big', module: 'es.string.big' },
  { feature: 'string_blink', module: 'es.string.blink' },
  { feature: 'string_bold', module: 'es.string.bold' },
  { feature: 'string_code_point_at', module: 'es.string.code-point-at' },
  { feature: 'string_ends_with', module: 'es.string.ends-with' },
  { feature: 'string_fixed', module: 'es.string.fixed' },
  { feature: 'string_fontcolor', module: 'es.string.fontcolor' },
  { feature: 'string_fontsize', module: 'es.string.fontsize' },
  { feature: 'string_from_code_point', module: 'es.string.from-code-point' },
  { feature: 'string_includes', module: 'es.string.includes' },
  { feature: 'string_is_well_formed', module: 'es.string.is-well-formed' },
  { feature: 'string_italics', module: 'es.string.italics' },
  { feature: 'string_link', module: 'es.string.link' },
  { feature: 'string_match_all', module: 'es.string.match-all' },
  { feature: 'string_pad_end', module: 'es.string.pad-end' },
  { feature: 'string_pad_start', module: 'es.string.pad-start' },
  { feature: 'string_raw', module: 'es.string.raw' },
  { feature: 'string_repeat', module: 'es.string.repeat' },
  { feature: 'string_replace_all', module: 'es.string.replace-all' },
  { feature: 'string_small', module: 'es.string.small' },
  { feature: 'string_starts_with', module: 'es.string.starts-with' },
  { feature: 'string_strike', module: 'es.string.strike' },
  { feature: 'string_sub', module: 'es.string.sub' },
  { feature: 'string_substr', module: 'es.string.substr' },
  { feature: 'string_sup', module: 'es.string.sup' },
  { feature: 'string_to_well_formed', module: 'es.string.to-well-formed' },
  { feature: 'string_trim', module: 'es.string.trim' },
  { feature: 'string_trim_end', module: 'es.string.trim-end' },
  { feature: 'string_trim_start', module: 'es.string.trim-start' },
  { feature: 'suppressed_error', module: 'es.suppressed-error.constructor' },
  { feature: 'symbol', module: 'es.symbol' },
  { feature: 'symbol_async_dispose', module: 'es.symbol.async-dispose' },
  { feature: 'symbol_async_iterator', module: 'es.symbol.async-iterator' },
  { feature: 'symbol_description', module: 'es.symbol.description' },
  { feature: 'symbol_dispose', module: 'es.symbol.dispose' },
  { feature: 'symbol_has_instance', module: 'es.symbol.has-instance' },
  { feature: 'symbol_is_concat_spreadable', module: 'es.symbol.is-concat-spreadable' },
  { feature: 'symbol_iterator', module: 'es.symbol.iterator' },
  { feature: 'symbol_match', module: 'es.symbol.match' },
  { feature: 'symbol_match_all', module: 'es.symbol.match-all' },
  { feature: 'symbol_replace', module: 'es.symbol.replace' },
  { feature: 'symbol_search', module: 'es.symbol.search' },
  { feature: 'symbol_species', module: 'es.symbol.species' },
  { feature: 'symbol_split', module: 'es.symbol.split' },
  { feature: 'symbol_to_primitive', module: 'es.symbol.to-primitive' },
  { feature: 'symbol_to_string_tag', module: 'es.symbol.to-string-tag' },
  { feature: 'symbol_unscopables', module: 'es.symbol.unscopables' },
  { feature: 'typed_array_float32', module: 'es.typed-array.float32-array' },
  { feature: 'typed_array_float64', module: 'es.typed-array.float64-array' },
  { feature: 'typed_array_int8', module: 'es.typed-array.int8-array' },
  { feature: 'typed_array_int16', module: 'es.typed-array.int16-array' },
  { feature: 'typed_array_int32', module: 'es.typed-array.int32-array' },
  { feature: 'typed_array_uint8', module: 'es.typed-array.uint8-array' },
  { feature: 'typed_array_uint8_clamped', module: 'es.typed-array.uint8-clamped-array' },
  { feature: 'typed_array_uint16', module: 'es.typed-array.uint16-array' },
  { feature: 'typed_array_uint32', module: 'es.typed-array.uint32-array' },
  { feature: 'typed_array_at', module: 'es.typed-array.at' },
  { feature: 'typed_array_copy_within', module: 'es.typed-array.copy-within' },
  { feature: 'typed_array_every', module: 'es.typed-array.every' },
  { feature: 'typed_array_fill', module: 'es.typed-array.fill' },
  { feature: 'typed_array_filter', module: 'es.typed-array.filter' },
  { feature: 'typed_array_find', module: 'es.typed-array.find' },
  { feature: 'typed_array_find_index', module: 'es.typed-array.find-index' },
  { feature: 'typed_array_find_last', module: 'es.typed-array.find-last' },
  { feature: 'typed_array_find_last_index', module: 'es.typed-array.find-last-index' },
  { feature: 'typed_array_for_each', module: 'es.typed-array.for-each' },
  { feature: 'typed_array_from', module: 'es.typed-array.from' },
  { feature: 'typed_array_includes', module: 'es.typed-array.includes' },
  { feature: 'typed_array_index_of', module: 'es.typed-array.index-of' },
  { feature: 'typed_array_join', module: 'es.typed-array.join' },
  { feature: 'typed_array_last_index_of', module: 'es.typed-array.last-index-of' },
  { feature: 'typed_array_map', module: 'es.typed-array.map' },
  { feature: 'typed_array_of', module: 'es.typed-array.of' },
  { feature: 'typed_array_reduce', module: 'es.typed-array.reduce' },
  { feature: 'typed_array_reduce_right', module: 'es.typed-array.reduce-right' },
  { feature: 'typed_array_reverse', module: 'es.typed-array.reverse' },
  { feature: 'typed_array_set', module: 'es.typed-array.set' },
  { feature: 'typed_array_slice', module: 'es.typed-array.slice' },
  { feature: 'typed_array_some', module: 'es.typed-array.some' },
  { feature: 'typed_array_sort', module: 'es.typed-array.sort' },
  { feature: 'typed_array_subarray', module: 'es.typed-array.subarray' },
  { feature: 'typed_array_to_reversed', module: 'es.typed-array.to-reversed' },
  { feature: 'typed_array_to_sorted', module: 'es.typed-array.to-sorted' },
  { feature: 'typed_array_with', module: 'es.typed-array.with' },
  { feature: 'uint8_array_from_base64', module: 'es.uint8-array.from-base64' },
  { feature: 'uint8_array_from_hex', module: 'es.uint8-array.from-hex' },
  { feature: 'uint8_array_set_from_base64', module: 'es.uint8-array.set-from-base64' },
  { feature: 'uint8_array_set_from_hex', module: 'es.uint8-array.set-from-hex' },
  { feature: 'uint8_array_to_base64', module: 'es.uint8-array.to-base64' },
  { feature: 'uint8_array_to_hex', module: 'es.uint8-array.to-hex' },
  { feature: 'unescape', module: 'es.unescape' },
  { feature: 'weak_map', module: 'es.weak-map' },
  { feature: 'weak_map_get_or_insert', module: 'es.weak-map.get-or-insert' },
  { feature: 'weak_map_get_or_insert_computed', module: 'es.weak-map.get-or-insert-computed' },
  { feature: 'weak_set', module: 'es.weak-set' },
  { feature: 'web_atob', module: 'web.atob' },
  { feature: 'web_btoa', module: 'web.btoa' },
  { feature: 'web_dom_collections_for_each', module: 'web.dom-collections.for-each' },
  { feature: 'web_dom_collections_iterator', module: 'web.dom-collections.iterator' },
  { feature: 'web_dom_exception', module: 'web.dom-exception.constructor' },
  { feature: 'web_immediate', module: 'web.immediate' },
  { feature: 'web_queue_microtask', module: 'web.queue-microtask' },
  { feature: 'web_self', module: 'web.self' },
  { feature: 'web_timers', module: 'web.timers' },
  { feature: 'web_url', module: 'web.url' },
  { feature: 'web_url_can_parse', module: 'web.url.can-parse' },
  { feature: 'web_url_parse', module: 'web.url.parse' },
  { feature: 'web_url_to_json', module: 'web.url.to-json' },
  { feature: 'web_url_search_params', module: 'web.url-search-params' },
  { feature: 'web_url_search_params_delete', module: 'web.url-search-params.delete' },
  { feature: 'web_url_search_params_has', module: 'web.url-search-params.has' },
  { feature: 'web_url_search_params_size', module: 'web.url-search-params.size' },
];

const RUNTIME_POLYFILL_CANDIDATE_MODULES = RUNTIME_POLYFILL_FEATURE_MODULES.map(
  (item) => item.module,
);

let coreJsCompatCache: CoreJsCompat | null | undefined;
let coreJsVersionCache: string | null | undefined;

export function isEsTarget(target: string | undefined): boolean {
  return target !== undefined && ES_TARGETS.has(target);
}

function loadCoreJsCompat(): CoreJsCompat {
  if (coreJsCompatCache !== undefined) {
    if (coreJsCompatCache) return coreJsCompatCache;
    throwCoreJsCompatMissing();
  }
  try {
    const req = getRuntimeRequire();
    coreJsCompatCache = req('core-js-compat') as CoreJsCompat;
    return coreJsCompatCache;
  } catch {
    coreJsCompatCache = null;
    throwCoreJsCompatMissing();
  }
}

function throwCoreJsCompatMissing(): never {
  throw new Error(
    "@zntc/core: runtimePolyfills requires the optional 'core-js-compat' package. Install it with `bun add core-js core-js-compat`.",
  );
}

function readInstalledCoreJsVersion(): string | undefined {
  if (coreJsVersionCache !== undefined) return coreJsVersionCache ?? undefined;
  try {
    const req = getRuntimeRequire();
    const pkgPath = req.resolve('core-js/package.json');
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8')) as { version?: string };
    coreJsVersionCache = pkg.version ?? null;
  } catch {
    coreJsVersionCache = null;
  }
  return coreJsVersionCache ?? undefined;
}

function assertNotPhysicalDeviceTarget(raw: string): void {
  if (!DEVICE_TARGET_RE.test(raw)) return;
  throw new Error(
    `@zntc/core: unsupported runtime target '${raw}'. Physical device names are not supported; use Browserslist targets such as 'ios_saf 12', 'chrome >= 85', or 'node 18'.`,
  );
}

function assertNotCompactRuntimeTarget(raw: string): void {
  const compact = raw.match(
    /^(ios_saf|ios|safari|chrome|android|samsung|hermes|node)v?\d+(?:\.\d+)*$/i,
  );
  if (!compact) return;
  throw new Error(
    `@zntc/core: unsupported runtime target '${raw}'. Compact runtime target shorthands are not supported; use Browserslist targets such as 'ios_saf 12', 'chrome >= 85', or 'node 18'.`,
  );
}

function assertBrowserslistRuntimeTarget(raw: string): void {
  if (!/^(?:hermes|react-native|reactnative)\b/i.test(raw)) return;
  throw new Error(
    `@zntc/core: unsupported runtime target '${raw}'. runtimePolyfills.targets follows Rspack/SWC env.targets and accepts Browserslist queries; use platform: 'react-native' for the default Hermes runtime target.`,
  );
}

function normalizeRuntimeTargetString(raw: string): string {
  const value = raw.trim();
  assertNotPhysicalDeviceTarget(value);
  assertNotCompactRuntimeTarget(value);
  assertBrowserslistRuntimeTarget(value);
  return value;
}

export function normalizeRuntimeTargets(targets: string | string[]): string | string[] {
  if (Array.isArray(targets)) return targets.map(normalizeRuntimeTargetString);
  return normalizeRuntimeTargetString(targets);
}

function normalizeBuildTargetForRuntime(target: string | undefined): CoreJsTargets | undefined {
  if (!target || isEsTarget(target)) return undefined;
  const nodeTarget = target.match(/^node(\d+(?:\.\d+)*)$/i);
  if (nodeTarget) return { node: nodeTarget[1] };
  const hermesTarget = target.match(/^hermes(\d+(?:\.\d+)*)$/i);
  if (hermesTarget) return { hermes: hermesTarget[1] };
  return normalizeRuntimeTargets(target);
}

function defaultRuntimeTargets(options: RuntimePolyfillBuildOptions): CoreJsTargets {
  if (options.platform === 'node') {
    const [major, minor = '0'] = process.versions.node.split('.');
    return { node: `${major}.${minor}` };
  }
  if (options.platform === 'react-native') return { hermes: '0.7' };
  return 'defaults';
}

function chooseRuntimeTargets(
  options: RuntimePolyfillBuildOptions,
  runtime: RuntimePolyfillOptions,
): CoreJsTargets {
  const raw = runtime.targets ?? (options.browserslist ? options.browserslist : undefined);
  if (raw !== undefined) return normalizeRuntimeTargets(raw);
  const target = normalizeBuildTargetForRuntime(options.target);
  if (target !== undefined) return target;
  return defaultRuntimeTargets(options);
}

function normalizeCoreJsModuleName(raw: string): string {
  let value = raw.trim();
  if (value.startsWith('core-js/modules/')) value = value.slice('core-js/modules/'.length);
  if (value.endsWith('.js')) value = value.slice(0, -3);
  if (!/^(?:es|web)\.[a-z0-9.-]+$/i.test(value)) {
    throw new Error(
      `@zntc/core: invalid core-js module '${raw}'. Expected e.g. 'es.string.replace-all'.`,
    );
  }
  return value;
}

export function normalizeRuntimePolyfillOptions(
  options: RuntimePolyfillBuildOptions,
): NormalizedRuntimePolyfills | null {
  const raw = options.runtimePolyfills;
  if (raw === undefined || raw === 'off') return null;

  const runtime: RuntimePolyfillOptions = typeof raw === 'string' ? { mode: raw } : { ...raw };
  const mode = runtime.mode ?? 'auto';
  if (mode !== 'auto' && mode !== 'usage' && mode !== 'entry') {
    throw new Error("@zntc/core: runtimePolyfills.mode must be 'auto', 'usage', or 'entry'.");
  }
  const provider = runtime.provider ?? 'core-js';
  if (provider !== 'core-js') {
    throw new Error("@zntc/core: runtimePolyfills.provider currently supports only 'core-js'.");
  }

  return {
    mode,
    provider,
    targets: chooseRuntimeTargets(options, runtime),
    include: (runtime.include ?? []).map(normalizeCoreJsModuleName),
    exclude: (runtime.exclude ?? []).map(normalizeCoreJsModuleName),
    proposals: runtime.proposals === true,
    coreJsVersion: runtime.coreJs ?? options.coreJs ?? readInstalledCoreJsVersion(),
  };
}

export function computeCoreJsCompatModules(
  targets: CoreJsTargets,
  modules: string[] | RegExp,
  options: { version?: string; proposals?: boolean } = {},
): string[] {
  const compat = loadCoreJsCompat();
  const result = compat({
    targets,
    modules,
    version: options.version,
    proposals: options.proposals,
  });
  return result.list.map(normalizeCoreJsModuleName).sort();
}

function buildCoreJsResolver(entryPoints: readonly string[]): (moduleName: string) => string {
  const override = runtimeRequireOverride;
  const requires: RuntimeRequire[] = [];
  if (override) {
    requires.push(override);
  } else {
    const entry = entryPoints[0];
    if (entry) requires.push(createRequire(resolve(dirname(resolve(entry)), 'package.json')));
    requires.push(createRequire(import.meta.url));
  }
  return (moduleName: string) => {
    const specifier = `core-js/modules/${moduleName}.js`;
    let firstError: string | undefined;
    for (const req of requires) {
      try {
        return req.resolve(specifier);
      } catch (err) {
        firstError ??= err instanceof Error ? err.message : String(err);
      }
    }
    throw new Error(
      `@zntc/core: runtimePolyfills could not resolve '${specifier}'. Install core-js with \`bun add core-js\`.\n${firstError ?? ''}`,
    );
  };
}

function uniqueSorted(values: Iterable<string>): string[] {
  return [...new Set(values)].sort();
}

function resolveRuntimeModules(
  modules: Iterable<string>,
  resolveCoreJs: (moduleName: string) => string,
): ResolvedRuntimeModule[] {
  return uniqueSorted(modules).map((moduleName) => ({
    module: moduleName,
    path: resolveCoreJs(moduleName),
  }));
}

export function applyRuntimePolyfillsToNapiOptions(
  napiOptions: Record<string, unknown>,
  options: RuntimePolyfillBuildOptions,
): { cleanup: () => void; modules: string[] } {
  delete napiOptions.runtimePolyfills;
  delete napiOptions.coreJs;

  if (options.target && !isEsTarget(options.target)) delete napiOptions.target;

  const runtime = normalizeRuntimePolyfillOptions(options);
  if (!runtime) return { cleanup: () => {}, modules: [] };

  const exclude = new Set(runtime.exclude);
  const includeModules = runtime.include.filter((moduleName) => !exclude.has(moduleName));
  const resolveCoreJs = buildCoreJsResolver(options.entryPoints);
  const includeResolved = resolveRuntimeModules(includeModules, resolveCoreJs);

  if (runtime.mode === 'entry') {
    const entryModules = computeCoreJsCompatModules(runtime.targets, /^(?:es|web)\./, {
      version: runtime.coreJsVersion,
      proposals: runtime.proposals,
    }).filter((moduleName) => !exclude.has(moduleName));
    const entryResolved = resolveRuntimeModules(entryModules, resolveCoreJs);
    if (entryResolved.length === 0 && includeResolved.length === 0) {
      return { cleanup: () => {}, modules: [] };
    }
    napiOptions.runtimePolyfillPlan = {
      mode: 'entry',
      entry: entryResolved,
      include: includeResolved,
      exclude: runtime.exclude,
    };
    return {
      cleanup: () => {},
      modules: uniqueSorted([...entryResolved, ...includeResolved].map((item) => item.module)),
    };
  }

  const targetCandidateSet = new Set(
    computeCoreJsCompatModules(runtime.targets, RUNTIME_POLYFILL_CANDIDATE_MODULES, {
      version: runtime.coreJsVersion,
      proposals: runtime.proposals,
    }).filter((moduleName) => !exclude.has(moduleName)),
  );
  const candidates: ResolvedRuntimeCandidate[] = [];
  for (const item of RUNTIME_POLYFILL_FEATURE_MODULES) {
    if (!targetCandidateSet.has(item.module)) continue;
    candidates.push({
      feature: item.feature,
      module: item.module,
      path: resolveCoreJs(item.module),
    });
  }

  if (candidates.length === 0 && includeResolved.length === 0) {
    return { cleanup: () => {}, modules: [] };
  }

  napiOptions.runtimePolyfillPlan = {
    mode: 'usage',
    candidates,
    include: includeResolved,
    exclude: runtime.exclude,
  };

  return {
    cleanup: () => {},
    modules: uniqueSorted([...candidates, ...includeResolved].map((item) => item.module)),
  };
}
