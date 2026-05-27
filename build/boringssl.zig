// BoringSSL static-lib build (epic #2538 4-1 PR-2).
//
// vendor/boringssl/gen/sources.json 의 `bcm` + `crypto` + `ssl` 의 srcs 만 골라
// libboringssl 정적 라이브러리로 컴파일한다. asm 은 전부 제외 (`OPENSSL_NO_ASM=1`)
// — arch 분기/NASM 의존성 회피. asm 활성화는 별도 작업 (#3788).
//
// 호출자 (build.zig) 는 `link(b, exe, target, optimize)` 로 lib 을 빌드 + exe 에
// linkLibrary + include path 추가. BoringSSL 자체는 system C/C++ stdlib (libc/libc++)
// 에 의존하므로 exe 가 linkLibC / linkLibCpp 도 이미 호출돼 있어야 한다.

const std = @import("std");

const SrcsList = struct { srcs: []const []const u8 };
const SourcesJson = struct {
    bcm: SrcsList,
    crypto: SrcsList,
    ssl: SrcsList,
};

/// BoringSSL 정적 lib 을 1회 컴파일해 반환. `attach()` 로 caller (exe / test) 에
/// linkLibrary + include path 를 부착하는 두 단계 분리 — exe / lib_unit_tests /
/// exe_unit_tests 가 같은 .a 를 공유 (중복 컴파일 회피).
pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "boringssl",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // **`pic = true`** — NAPI binary (`zig-out/lib/zntc.node`) 는 shared library
            // 라 link 되는 모든 코드가 PIC 여야 한다. non-PIC archive 를 dynamic library
            // 에 link 하면 `R_AARCH64_ADR_PREL_PG_HI21 cannot be used against symbol
            // 'malloc'; recompile with -fPIC` (ARM64) / `R_X86_64_PC32 ... (X86_64)`
            // relocation 에러 발생. exe binary 도 PIC 코드 OK (현대 Linux 의 PIE default
            // 와 일치) — overhead 무시 수준.
            .pic = true,
            // **`sanitize_c = .off`** — Zig 의 default sanitize_c (Debug 빌드 시 on)
            // 는 `__ubsan_handle_*` symbol 들을 호출하는 코드를 emit. 그런데 Linux 의
            // libubsan 은 Zig 가 자동 link 안 해서 NAPI binary dlopen 시
            // `undefined symbol: __ubsan_handle_type_mismatch_v1` 발생 (관찰 환경:
            // CI ubuntu-latest, packages/core 의 build:js:cjs step 에서 require).
            // vendored BoringSSL 은 외부 코드라 자체 sanitize 무의미 — off 가 정합.
            .sanitize_c = .off,
        }),
    });
    lib.linkLibC();
    lib.linkLibCpp();

    const sources_text = @embedFile("../vendor/boringssl/gen/sources.json");
    // Leaky variant — b.allocator 가 build graph lifetime arena 라 별도 ArenaAllocator
    // 가 필요 없음. std.json doc 의 ArenaAllocator caller 권장 패턴.
    const parsed = try std.json.parseFromSliceLeaky(
        SourcesJson,
        b.allocator,
        sources_text,
        .{ .ignore_unknown_fields = true },
    );

    const cflags_common = [_][]const u8{
        "-DOPENSSL_NO_ASM=1",
        "-DOPENSSL_SMALL", // dev server scope — table 작게
        "-fno-strict-aliasing",
        "-Wno-unused-parameter",
        "-Wno-unused-function",
        "-Wno-missing-field-initializers",
    };

    const cxxflags = cflags_common ++ [_][]const u8{
        "-std=c++17",
        "-fno-exceptions",
        "-fno-rtti",
    };

    const cflags = cflags_common ++ [_][]const u8{
        "-std=c11",
    };

    const linux_extra = [_][]const u8{"-D_XOPEN_SOURCE=700"};
    const win_extra = [_][]const u8{
        "-D_HAS_EXCEPTIONS=0",
        "-DWIN32_LEAN_AND_MEAN",
        "-DNOMINMAX",
        "-D_CRT_SECURE_NO_WARNINGS",
    };

    const cxx_linux = cxxflags ++ linux_extra;
    const cxx_win = cxxflags ++ win_extra;
    const c_linux = cflags ++ linux_extra;
    const c_win = cflags ++ win_extra;
    const cxx_full: []const []const u8 = switch (target.result.os.tag) {
        .linux => &cxx_linux,
        .windows => &cxx_win,
        else => &cxxflags,
    };
    const c_full: []const []const u8 = switch (target.result.os.tag) {
        .linux => &c_linux,
        .windows => &c_win,
        else => &cflags,
    };

    inline for (.{ "bcm", "crypto", "ssl" }) |group| {
        const srcs = @field(parsed, group).srcs;
        for (srcs) |rel| {
            const full = try std.fs.path.join(b.allocator, &.{ "vendor/boringssl", rel });
            const is_cpp = std.mem.endsWith(u8, rel, ".cc") or std.mem.endsWith(u8, rel, ".cpp");
            lib.addCSourceFile(.{
                .file = b.path(full),
                .flags = if (is_cpp) cxx_full else c_full,
            });
        }
    }

    // angle-bracket `<openssl/...>` 가 BoringSSL 의 public header 를 resolve.
    lib.addIncludePath(b.path("vendor/boringssl/include"));

    // Windows target — crypto/bio/socket.cc / connect.cc 가 `<winsock2.h>` 무조건
    // include 하고 Win32 socket API (socket/recv/WSAGetLastError) 호출. 시스템
    // ws2_32 link 가 없으면 cross-Windows build 가 undefined symbol.
    if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary("ws2_32");
    }

    return lib;
}

/// `build()` 가 만든 lib 을 caller (exe / test step) 에 부착. linkLibrary +
/// BoringSSL header 의 include path. include path 는 pure-Zig caller (extern fn
/// declaration 만) 에는 dead 지만, 추후 caller 가 `addCSourceFile` 로 inline C
/// bridge 를 추가하거나 `@cImport` 를 쓰면 필요해진다. 또 lib 의 linkLibCpp 가
/// transitive 로 caller 의 is_linking_libcpp 를 true 로 만든다 (Zig 0.15.2
/// std.Build.Step.Compile L1147-1152).
pub fn attach(
    target_step: *std.Build.Step.Compile,
    lib: *std.Build.Step.Compile,
    b: *std.Build,
) void {
    target_step.linkLibrary(lib);
    target_step.addIncludePath(b.path("vendor/boringssl/include"));
}
