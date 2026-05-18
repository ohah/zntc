//! cli/options.zig 테스트 — mf 번들 DTO → MfBundleConfig 변환 검증.
//! options.zig 의 pub API 미의존 (lib.bundler.mf_options 직접 검증)이라 옆 파일 분리.

const std = @import("std");
const lib = @import("zntc_lib");
const mf_options = lib.bundler.mf_options;

test "#4-0 mfBundleFromDto: per-shared share_scope 명시 + 번들 상속 + free 대칭" {
    const a = std.testing.allocator;
    const P = struct {
        fn p(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(lib.transpile.MfConfigDto) {
            return std.json.parseFromSlice(lib.transpile.MfConfigDto, alloc, s, .{ .ignore_unknown_fields = true });
        }
        fn scopeOf(mfb: lib.bundler.MfBundleConfig, nm: []const u8) []const u8 {
            for (mfb.shared) |s| if (std.mem.eql(u8, s.name, nm)) return s.share_scope;
            return "<missing>";
        }
    };

    { // 번들 shareScope="host": react 는 명시 "ui", lodash 미지정 → "host" 상속
        const v = try P.p(a, "{\"shareScope\":\"host\",\"shared\":{\"react\":{\"shareScope\":\"ui\"},\"lodash\":{}}}");
        defer v.deinit();
        const mfb = try mf_options.fromDto(a, &v.value);
        defer mf_options.freeMfBundle(a, mfb); // testing.allocator = 누수 탐지(항상-owned free 대칭)
        try std.testing.expectEqualStrings("ui", P.scopeOf(mfb, "react"));
        try std.testing.expectEqualStrings("host", P.scopeOf(mfb, "lodash"));
    }
    { // 번들 shareScope 미지정 + per-shared 미지정 → "default"
        const v = try P.p(a, "{\"shared\":{\"react\":{}}}");
        defer v.deinit();
        const mfb = try mf_options.fromDto(a, &v.value);
        defer mf_options.freeMfBundle(a, mfb);
        try std.testing.expectEqualStrings("default", P.scopeOf(mfb, "react"));
    }
}
