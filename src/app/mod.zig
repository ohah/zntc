pub const env = @import("env.zig");
pub const build = @import("build.zig");

test {
    _ = env;
    _ = build;

    // test files
    _ = @import("env_test.zig");
    _ = @import("build_test.zig");
}
