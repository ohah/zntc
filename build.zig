const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("zts_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zts",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "zts",
        .root_module = exe_mod,
    });
    exe.linkLibC();

    // mimalloc: 고성능 메모리 할당자 (vendor/mimalloc, static.c 단일 컴파일)
    exe.addCSourceFile(.{
        .file = b.path("vendor/mimalloc/src/static.c"),
        .flags = &.{
            "-DMI_SKIP_COLLECT_ON_EXIT=1",
            "-DMI_OVERRIDE=0",
            "-DNDEBUG",
            "-Wno-date-time", // __DATE__/__TIME__ 경고 억제
        },
    });
    exe.addIncludePath(b.path("vendor/mimalloc/include"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // 테스트 필터: `zig build test -Dtest-filter="Arena"` 처럼 특정 테스트만 실행 가능
    const test_filter_opt = b.option([]const u8, "test-filter", "Filter tests by name substring");
    const test_filters: []const []const u8 = if (test_filter_opt) |f| &.{f} else &.{};

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
        .filters = test_filters,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
        .filters = test_filters,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    // ─── WASM 빌드 ───
    // `zig build wasm` — wasm32-wasi 타겟으로 트랜스파일 전용 WASM 모듈을 빌드한다.
    // packages/wasm/src/wasm_entry.zig가 진입점이며, transpile 함수만 export한다.
    {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        });

        const wasm_lib_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });

        const wasm_mod = b.createModule(.{
            .root_source_file = b.path("packages/wasm/src/wasm_entry.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        wasm_mod.addImport("zts_lib", wasm_lib_mod);

        const wasm_exe = b.addExecutable(.{
            .name = "zts",
            .root_module = wasm_mod,
        });
        // export fn 심볼을 동적 심볼 테이블에 노출
        wasm_exe.rdynamic = true;
        // 라이브러리 모드: 엔트리포인트 없이 export 함수만 노출
        wasm_exe.entry = .disabled;

        const wasm_install = b.addInstallArtifact(wasm_exe, .{});
        const wasm_step = b.step("wasm", "Build WASM module (wasm32-wasi)");
        wasm_step.dependOn(&wasm_install.step);
    }

    // Test262 러너 테스트 (유닛 테스트)
    // lib_mod에 이미 test262가 포함되어 있으므로 같은 모듈로 테스트.
    const test262_step = b.step("test262", "Run Test262 runner unit tests");
    test262_step.dependOn(&run_lib_unit_tests.step);

    // Test262 실제 실행 (파서 통과율 측정)
    // `zig build test262-run` — 전체 카테고리
    // `zig build test262-run -- expressions` — 특정 카테고리만
    const test262_run_mod = b.createModule(.{
        .root_source_file = b.path("src/test262/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // runner.zig가 lexer/parser를 상대 경로로 import하므로 lib_mod를 추가
    test262_run_mod.addImport("zts_lib", lib_mod);
    const test262_exe = b.addExecutable(.{
        .name = "test262-runner",
        .root_module = test262_run_mod,
    });
    const test262_run_cmd = b.addRunArtifact(test262_exe);
    if (b.args) |args| {
        test262_run_cmd.addArgs(args);
    }
    const test262_run_step = b.step("test262-run", "Run Test262 parser tests (pass rate)");
    test262_run_step.dependOn(&test262_run_cmd.step);
}
