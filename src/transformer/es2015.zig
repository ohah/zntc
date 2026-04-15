//! ES2015 (ES6) 다운레벨링
//!
//! --target < es2015 (즉 es5) 일 때 활성화.
//! 모든 ES2015 기능별 모듈의 엔트리포인트.
//!
//! 기능별 파일 구조:
//!   es2015_template.zig      — template literal → string concat
//!   es2015_shorthand.zig     — shorthand property → full property
//!   es2015_computed.zig      — computed property → bracket notation
//!   es2015_params.zig        — default/rest params → conditional/arguments
//!   es2015_spread.zig        — spread → apply/concat
//!   es2015_arrow.zig         — arrow function → function + this capture
//!   es2015_for_of.zig        — for-of → for loop / iterator protocol
//!   es2015_destructuring.zig — destructuring → temporary variables
//!   es2015_block_scoping.zig — let/const → var + TDZ emulation
//!   es2015_class.zig         — class → function + prototype
//!   es2015_generator.zig     — generator → state machine
//!
//! 스펙:
//! - https://tc39.es/ecma262/ (ES2015 / ES6)
//! - https://262.ecma-international.org/6.0/
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (~3000줄)
//! - oxc: crates/oxc_transformer/src/es2015/ (arrow만 부분 구현)
//! - SWC: crates/swc_ecma_compat_es2015/ (~11000줄)
//! - Babel: @babel/preset-env (ES2015 플러그인 ~20개)

pub const es2015_template = @import("es2015_template.zig");
pub const es2015_shorthand = @import("es2015_shorthand.zig");
pub const es2015_computed = @import("es2015_computed.zig");
pub const es2015_object_methods = @import("es2015_object_methods.zig");
pub const es2015_params = @import("es2015_params.zig");
pub const es2015_spread = @import("es2015_spread.zig");
pub const es2015_arrow = @import("es2015_arrow.zig");
pub const es2015_for_of = @import("es2015_for_of.zig");
pub const es2015_destructuring = @import("es2015_destructuring.zig");
pub const es2015_block_scoping = @import("es2015_block_scoping.zig");
pub const es2015_class = @import("es2015_class.zig");
pub const es2015_generator = @import("es2015_generator.zig");

test {
    _ = es2015_template;
    _ = es2015_shorthand;
    _ = es2015_computed;
    _ = es2015_object_methods;
    _ = es2015_params;
    _ = es2015_spread;
    _ = es2015_arrow;
    _ = es2015_for_of;
    _ = es2015_destructuring;
    _ = es2015_block_scoping;
    _ = es2015_class;
    _ = es2015_generator;
}
