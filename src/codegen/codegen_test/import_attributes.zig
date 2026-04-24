//! ES2024 import attributes round-trip 테스트.
//!
//! Static `import ... with { type: "json" }` 은 이미 동작 (파싱 + AST + codegen).
//! 본 파일은 현재 정보가 소실되는 두 경로의 라운드트립을 검증한다:
//!   - dynamic `import("x", { with: {...} })` — 두 번째 인자
//!   - `export ... from "x" with {...}` — re-export attributes
//!
//! `assert` (구버전) 는 파서가 `with` 로 자동 마이그레이션 — 같은 출력을 기대.

const std = @import("std");
const helpers = @import("helpers.zig");
const e2e = helpers.e2e;

// ============================================================
// Static import attributes (이미 동작 — 회귀 가드)
// ============================================================

test "import attributes: static with clause round-trip" {
    var r = try e2e(std.testing.allocator,
        \\import data from "./data.json" with { type: "json" };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "with") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"json\"") != null);
}

test "import attributes: static assert → with migration" {
    // 파서는 assert 를 with 로 자동 변환 (ES2024 표준 호환)
    var r = try e2e(std.testing.allocator,
        \\import data from "./data.json" assert { type: "json" };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "with") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "assert") == null);
}

test "import attributes: static multi-key preserved" {
    var r = try e2e(std.testing.allocator,
        \\import x from "./y" with { type: "css", foo: "bar" };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"bar\"") != null);
}

// ============================================================
// Dynamic import attributes (현재 소실 → 보존해야 함)
// ============================================================

test "import attributes: dynamic import 2nd arg preserved" {
    var r = try e2e(std.testing.allocator,
        \\const mod = import("./data.json", { with: { type: "json" } });
    );
    defer r.deinit();
    // 현재는 import("./data.json") 으로만 출력. 두 번째 인자를 보존해야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "with") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"json\"") != null);
}

test "import attributes: dynamic import assert 2nd arg preserved" {
    // 레거시 assert 구문도 두 번째 인자로 소비된 뒤 보존되어야 한다.
    // (정적 import 와 달리 동적 import 두 번째 인자는 일반 object expression 이므로
    //  assert/with 키 자체를 AST 가 그대로 보존해야 한다.)
    var r = try e2e(std.testing.allocator,
        \\const mod = import("./data.json", { assert: { type: "json" } });
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"json\"") != null);
}

test "import attributes: dynamic import without 2nd arg stays unary" {
    var r = try e2e(std.testing.allocator,
        \\const mod = import("./data.json");
    );
    defer r.deinit();
    // 두 번째 인자가 없으면 그대로.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "./data.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "with") == null);
}

// ============================================================
// Export re-export attributes (현재 소실 → 보존해야 함)
// ============================================================

test "import attributes: export named re-export with clause preserved" {
    var r = try e2e(std.testing.allocator,
        \\export { default as data } from "./data.json" with { type: "json" };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "with") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"json\"") != null);
}

// TODO(export-all-attrs): `export * from "x" with {...}` / `export * as ns from "x" with {...}`
// export_all_declaration 은 현재 .binary 레이아웃이라 attrs 를 담으려면 .extra 로 전환 필요.
// 사용처(linker/bundler/semantic) 다수라 별도 PR 에서 처리. 본 PR 은 export_named 만.

test "import attributes: export * from without clause stays intact (export-all baseline)" {
    var r = try e2e(std.testing.allocator,
        \\export * from "./other.json";
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "./other.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "with") == null);
}

test "import attributes: export * as ns from without clause stays intact (export-all baseline)" {
    var r = try e2e(std.testing.allocator,
        \\export * as ns from "./other.json";
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "./other.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "with") == null);
}

test "import attributes: export without source ignores attributes syntax" {
    // export { x }; — source 없으므로 with 구문 자체 불허. 보통 출력.
    var r = try e2e(std.testing.allocator,
        \\const x = 1;
        \\export { x };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "with") == null);
}
