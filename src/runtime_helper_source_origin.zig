//! A constructor witness is meaningful only together with the actual winning
//! load hook/context. It never authorizes a provider by path or source spelling.
pub const SourceOptions = struct {
    minify: bool = false,
    es5: bool = false,
    configurable_exports: bool = false,
};
pub const Catalog = enum { public_field, to_property_key, keep_names, super_get, super_set, wrap_regex, readiness_all, suspension_invoke, native_async_module, tdz, pm_default, pm_module, generator };
pub const Variant = enum { plain, min, es5, es5_min, configurable, configurable_min };
pub const Origin = struct {
    catalog: Catalog,
    catalog_descriptor: *const anyopaque,
    body_hash: u64,
    variant: Variant,
    requested: SourceOptions,
    contents: []const u8,
    contents_hash: u64,
};

pub fn matchesContents(origin: Origin, contents: []const u8) bool {
    return origin.contents.ptr == contents.ptr and origin.contents.len == contents.len and
        @import("util/wyhash.zig").hashU64(contents) == origin.contents_hash;
}

/// A winning builtin load witness for any helper module, independent of a
/// specialized callable catalog role. It grants only internal module policy.
pub const ModuleConstructor = struct {
    descriptor: *const anyopaque,
    requested: SourceOptions,
    contents: []const u8,
    contents_hash: u64,
};
