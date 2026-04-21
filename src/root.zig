//! ZTS — Zig TypeScript Transpiler
//!
//! 라이브러리 엔트리포인트. 모든 공개 모듈을 여기서 re-export한다.

const std = @import("std");

pub const diagnostic = @import("diagnostic.zig");
pub const ansi_mod = @import("ansi.zig");
pub const rich_diagnostic = @import("rich_diagnostic.zig");
pub const diagnostic_renderer = @import("diagnostic_renderer.zig");
pub const levenshtein = @import("levenshtein.zig");
pub const error_codes = @import("error_codes.zig");
pub const lexer = @import("lexer/mod.zig");
pub const parser = @import("parser/mod.zig");
pub const semantic = @import("semantic/mod.zig");
pub const transformer = @import("transformer/mod.zig");
pub const codegen = @import("codegen/mod.zig");
pub const config = @import("config.zig");
pub const tsconfig_merge = @import("tsconfig_merge.zig");
pub const regexp = @import("regexp/mod.zig");
pub const test262 = @import("test262/mod.zig");
pub const bundler = @import("bundler/mod.zig");
pub const server = @import("server/mod.zig");
pub const transpile = @import("transpile.zig");
pub const string_escape = @import("string_escape.zig");
pub const util = @import("util/mod.zig");
pub const crash_handler = @import("crash_handler.zig");
pub const debug_log = @import("debug_log.zig");
pub const profile = @import("profile.zig");
pub const bench = @import("bench.zig");

test {
    _ = lexer;
    _ = regexp;
    _ = semantic;
    _ = transformer;
    _ = codegen;
    _ = config;
    _ = test262;
    _ = bundler;
    _ = server;
    _ = @import("test_arena.zig");
    _ = util.wyhash;

    // diagnostic system
    _ = ansi_mod;
    _ = rich_diagnostic;
    _ = diagnostic_renderer;
    _ = levenshtein;
    _ = error_codes;

    _ = crash_handler;

    _ = tsconfig_merge;

    // test files
    _ = @import("config_test.zig");
    _ = @import("transpile_options_dto_test.zig");
}
