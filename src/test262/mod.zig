//! ZTS Test262 Runner
//!
//! TC39 Test262 테스트 스위트를 실행하여 ECMAScript 스펙 준수를 검증한다.

pub const runner = @import("runner.zig");

test {
    _ = runner;

    // test files
    _ = @import("runner_test.zig");
}
