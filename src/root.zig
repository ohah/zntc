//! ZTS — Zig TypeScript Transpiler
//!
//! 라이브러리 엔트리포인트. 모든 공개 모듈을 여기서 re-export한다.

const std = @import("std");

pub const diagnostic = @import("diagnostic.zig");
pub const lexer = @import("lexer/mod.zig");
pub const parser = @import("parser/mod.zig");
pub const semantic = @import("semantic/mod.zig");
pub const transformer = @import("transformer/mod.zig");
pub const codegen = @import("codegen/mod.zig");
pub const config = @import("config.zig");
pub const regexp = @import("regexp/mod.zig");
pub const test262 = @import("test262/mod.zig");
pub const bundler = @import("bundler/mod.zig");
pub const server = @import("server/mod.zig");

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

    // test files
    _ = @import("config_test.zig");
}
