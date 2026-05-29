const std = @import("std");

pub const DefineEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const LoadOptions = struct {
    mode: []const u8,
    env_dir: []const u8 = ".",
    prefixes: []const []const u8 = &.{ "VITE_", "ZNTC_" },
};

pub const EnvMap = std.StringHashMap([]const u8);

pub fn loadEnv(allocator: std.mem.Allocator, io: std.Io, opts: LoadOptions) !EnvMap {
    var merged = EnvMap.init(allocator);
    errdefer deinitMap(&merged, allocator);

    const mode_file = try std.fmt.allocPrint(allocator, ".env.{s}", .{opts.mode});
    defer allocator.free(mode_file);
    const mode_local_file = try std.fmt.allocPrint(allocator, ".env.{s}.local", .{opts.mode});
    defer allocator.free(mode_local_file);
    const files = [_][]const u8{ ".env", ".env.local", mode_file, mode_local_file };

    for (files) |name| {
        const path = try std.fs.path.join(allocator, &.{ opts.env_dir, name });
        defer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(content);
        try parseDotenvInto(allocator, content, &merged);
    }

    var filtered = EnvMap.init(allocator);
    errdefer deinitMap(&filtered, allocator);
    var it = merged.iterator();
    while (it.next()) |entry| {
        if (!hasAllowedPrefix(entry.key_ptr.*, opts.prefixes)) continue;
        try filtered.put(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*),
        );
    }
    deinitMap(&merged, allocator);
    return filtered;
}

pub fn deinitMap(map: *EnvMap, allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

pub fn envToDefine(
    allocator: std.mem.Allocator,
    env_map: *const EnvMap,
    mode: []const u8,
    base_url: []const u8,
) ![]DefineEntry {
    var list: std.ArrayList(DefineEntry) = .empty;
    errdefer {
        for (list.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        list.deinit(allocator);
    }

    try appendDefine(allocator, &list, "import.meta.env.MODE", mode, .string);
    try appendDefine(allocator, &list, "import.meta.env.PROD", if (std.mem.eql(u8, mode, "production")) "true" else "false", .literal);
    try appendDefine(allocator, &list, "import.meta.env.DEV", if (std.mem.eql(u8, mode, "production")) "false" else "true", .literal);
    try appendDefine(allocator, &list, "import.meta.env.SSR", "false", .literal);
    try appendDefine(allocator, &list, "import.meta.env.BASE_URL", base_url, .string);

    var object = std.ArrayList(u8).empty;
    defer object.deinit(allocator);
    try object.append(allocator, '{');
    try appendObjectField(allocator, &object, "MODE", mode, .string, false);
    try appendObjectField(allocator, &object, "PROD", if (std.mem.eql(u8, mode, "production")) "true" else "false", .literal, true);
    try appendObjectField(allocator, &object, "DEV", if (std.mem.eql(u8, mode, "production")) "false" else "true", .literal, true);
    try appendObjectField(allocator, &object, "SSR", "false", .literal, true);
    try appendObjectField(allocator, &object, "BASE_URL", base_url, .string, true);

    var it = env_map.iterator();
    while (it.next()) |entry| {
        const define_key = try std.fmt.allocPrint(allocator, "import.meta.env.{s}", .{entry.key_ptr.*});
        errdefer allocator.free(define_key);
        const define_val = try quoteJsonString(allocator, entry.value_ptr.*);
        errdefer allocator.free(define_val);
        try list.append(allocator, .{ .key = define_key, .value = define_val });
        try appendObjectField(allocator, &object, entry.key_ptr.*, entry.value_ptr.*, .string, true);
    }

    try object.append(allocator, '}');
    try list.append(allocator, .{
        .key = try allocator.dupe(u8, "import.meta.env"),
        .value = try object.toOwnedSlice(allocator),
    });
    return try list.toOwnedSlice(allocator);
}

pub fn freeDefines(allocator: std.mem.Allocator, defines: []DefineEntry) void {
    for (defines) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    allocator.free(defines);
}

const ValueKind = enum { string, literal };

fn appendDefine(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(DefineEntry),
    key: []const u8,
    value: []const u8,
    kind: ValueKind,
) !void {
    try list.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .value = if (kind == .string) try quoteJsonString(allocator, value) else try allocator.dupe(u8, value),
    });
}

fn appendObjectField(
    allocator: std.mem.Allocator,
    object: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    kind: ValueKind,
    comma: bool,
) !void {
    if (comma) try object.append(allocator, ',');
    const key_json = try quoteJsonString(allocator, key);
    defer allocator.free(key_json);
    try object.appendSlice(allocator, key_json);
    try object.append(allocator, ':');
    if (kind == .string) {
        const value_json = try quoteJsonString(allocator, value);
        defer allocator.free(value_json);
        try object.appendSlice(allocator, value_json);
    } else {
        try object.appendSlice(allocator, value);
    }
}

fn parseDotenvInto(allocator: std.mem.Allocator, content: []const u8, map: *EnvMap) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (eq == 0) continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!isValidKey(key)) continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (isQuoted(value)) {
            value = value[1 .. value.len - 1];
        } else if (std.mem.indexOf(u8, value, " #")) |comment| {
            value = std.mem.trimEnd(u8, value[0..comment], " \t");
        }

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        const gop = try map.getOrPut(owned_key);
        if (gop.found_existing) {
            allocator.free(owned_key);
            allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = owned_value;
        } else {
            gop.value_ptr.* = owned_value;
        }
    }
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn isQuoted(value: []const u8) bool {
    return value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\''));
}

fn hasAllowedPrefix(key: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, key, prefix)) return true;
    }
    return false;
}

fn quoteJsonString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}
