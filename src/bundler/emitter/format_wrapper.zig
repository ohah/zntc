//! Output format prologue/epilogue writers.

const std = @import("std");
const types = @import("../types.zig");

/// 포맷별 prologue를 output에 추가한다.
pub fn emitFormatPrologue(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    format: types.Format,
    global_name: ?[]const u8,
    factory_fn: []const u8,
    external_specifiers: []const []const u8,
    ext_param_names: []const []const u8,
) !void {
    switch (format) {
        .iife => {
            if (global_name) |gn| {
                if (std.mem.indexOfScalar(u8, gn, '.') != null) {
                    try output.appendSlice(allocator, "/* [ZNTC WARNING] Dotted globalName (\"");
                    try output.appendSlice(allocator, gn);
                    try output.appendSlice(allocator, "\") is not yet supported. Use a simple name. */\n");
                    try output.appendSlice(allocator, factory_fn);
                } else {
                    try output.appendSlice(allocator, "var ");
                    try output.appendSlice(allocator, gn);
                    try output.appendSlice(allocator, " = ");
                    try output.appendSlice(allocator, factory_fn);
                }
            } else {
                try output.appendSlice(allocator, factory_fn);
            }
        },
        .umd => {
            try output.appendSlice(allocator, "(function(root, factory) {\n");
            try output.appendSlice(allocator, "  if (typeof define === \"function\" && define.amd) define([");
            try writeDepArray(output, allocator, external_specifiers);
            try output.appendSlice(allocator, "], factory);\n");
            try output.appendSlice(allocator, "  else if (typeof module === \"object\" && module.exports) module.exports = factory(");
            try writeCjsRequireList(output, allocator, external_specifiers);
            try output.appendSlice(allocator, ");\n");
            if (global_name) |gn| {
                try output.appendSlice(allocator, "  else root.");
                try output.appendSlice(allocator, gn);
                try output.appendSlice(allocator, " = factory(");
            } else {
                try output.appendSlice(allocator, "  else factory(");
            }
            try writeGlobalsList(output, allocator, ext_param_names);
            try output.appendSlice(allocator, ");\n");
            try output.appendSlice(allocator, "})(typeof self !== \"undefined\" ? self : this, function(");
            try writeParamList(output, allocator, ext_param_names);
            try output.appendSlice(allocator, ") {\n");
        },
        .amd => {
            try output.appendSlice(allocator, "define([");
            try writeDepArray(output, allocator, external_specifiers);
            try output.appendSlice(allocator, "], function(");
            try writeParamList(output, allocator, ext_param_names);
            try output.appendSlice(allocator, ") {\n");
        },
        .cjs => try output.appendSlice(allocator, "\"use strict\";\n"),
        .esm => {},
    }
}

// UMD/AMD prologue 헬퍼: 반복되는 리스트 출력을 공유.

fn writeDepArray(output: *std.ArrayList(u8), allocator: std.mem.Allocator, specifiers: []const []const u8) !void {
    for (specifiers, 0..) |spec, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.append(allocator, '"');
        try output.appendSlice(allocator, spec);
        try output.append(allocator, '"');
    }
}

fn writeCjsRequireList(output: *std.ArrayList(u8), allocator: std.mem.Allocator, specifiers: []const []const u8) !void {
    for (specifiers, 0..) |spec, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, "require(\"");
        try output.appendSlice(allocator, spec);
        try output.appendSlice(allocator, "\")");
    }
}

fn writeGlobalsList(output: *std.ArrayList(u8), allocator: std.mem.Allocator, names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, "root.");
        try output.appendSlice(allocator, name);
    }
}

fn writeParamList(output: *std.ArrayList(u8), allocator: std.mem.Allocator, names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, name);
    }
}

/// 포맷별 epilogue를 output에 추가한다.
/// `iife_globals_args` 는 IIFE + external globals 매핑이 있을 때만 non-empty —
/// `})(React, ReactDom);` 형태로 factory 호출 인자를 부착한다 (#1824).
pub fn emitFormatEpilogue(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    format: types.Format,
    iife_globals_args: []const []const u8,
) !void {
    switch (format) {
        .iife => {
            if (iife_globals_args.len > 0) {
                try output.appendSlice(allocator, "})(");
                for (iife_globals_args, 0..) |arg, i| {
                    if (i > 0) try output.appendSlice(allocator, ", ");
                    try output.appendSlice(allocator, arg);
                }
                try output.appendSlice(allocator, ");\n");
            } else {
                try output.appendSlice(allocator, "})();\n");
            }
        },
        .umd, .amd => try output.appendSlice(allocator, "});\n"),
        .cjs, .esm => {},
    }
}
