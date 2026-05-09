//! Scanner/Parser setup helper for ModuleGraph.

const std = @import("std");
const Module = @import("../module.zig").Module;
const Scanner = @import("../../lexer/scanner.zig").Scanner;
const Parser = @import("../../parser/parser.zig").Parser;
const Span = @import("../../lexer/token.zig").Span;
const profile = @import("../../profile.zig");
const graph_parse_helpers = @import("parse_helpers.zig");
const graph_package_info = @import("package_info.zig");
const configureParserForModule = graph_parse_helpers.configureParserForModule;
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;

pub fn init(
    self: *ModuleGraph,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    scanner: *Scanner,
    parser: *Parser,
) bool {
    var parser_setup_scope = profile.begin(.graph_discover_pm_setup_parser);
    defer parser_setup_scope.end();

    scanner.* = Scanner.init(arena_alloc, module.source) catch {
        self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Scanner initialization failed", null);
        module.state = .ready;
        return false;
    };

    parser.* = Parser.init(arena_alloc, scanner);
    const ext = std.fs.path.extension(module.path);
    configureParserForModule(parser, module, ext);

    // Flow 모드: --flow CLI 또는 .js.flow/.jsx.flow 확장자 (pragma는 parse() 내부에서 감지)
    // TS 와 Flow 는 상호 배타 — TS 파일에서는 Flow 무시
    if (parser.source_mode != .ts) {
        if (self.flow) {
            parser.is_flow = true;
            scanner.has_flow_pragma = true; // flow comment 활성화
        } else {
            parser.configureFlowFromPath(module.path);
        }
    }

    // .js 파일에서 JSX 파싱 활성화 (--platform=react-native 프리셋)
    // .ts 파일은 이미 configureForBundler에서 JSX 설정됨 (.tsx만 true)
    // .ts에 강제 jsx=true하면 <T> 제네릭이 JSX로 오파싱됨
    if (self.jsx_in_js and parser.source_mode != .ts) {
        parser.is_jsx = true;
    }

    // 모듈 정의 형식 결정 (Rolldown ModuleDefFormat)
    module.def_format = if (std.mem.eql(u8, ext, ".mjs"))
        .esm_mjs
    else if (std.mem.eql(u8, ext, ".mts"))
        .esm_mts
    else if (std.mem.eql(u8, ext, ".cjs"))
        .cjs
    else if (std.mem.eql(u8, ext, ".cts"))
        .cts
    else if (module.is_module_field or graph_package_info.isPackageTypeModule(self, module.path))
        .esm_package_json
    else
        .unknown;

    // def_format 기반 module/script 결정:
    //   .esm_mjs / .esm_mts / .esm_package_json → 확정 module
    //   .cjs → script (Node CommonJS — `import`/`export` 거부, top-level await 거부).
    //   .cts → module 유지 (TypeScript CJS — ESM 구문을 TS 가 module.exports 로 transpile.
    //          tsc 와 동일한 정책. configureForBundlerKind 가 이미 is_module=true 로 set).
    //   .unknown → Unambiguous (낙관적 module + 에러 지연 → 파싱 후 resolveModuleKind 가 확정)
    // .mjs/.mts/.ts/.tsx 는 configureForBundler 단계에서 이미 is_module=true.
    switch (module.def_format) {
        .cjs => {
            parser.is_module = false;
            scanner.is_module = false;
        },
        .unknown => if (!parser.is_module) {
            parser.is_module = true;
            scanner.is_module = true;
            parser.is_unambiguous = true;
        },
        else => if (!parser.is_module) {
            parser.is_module = true;
            scanner.is_module = true;
        },
    }
    // Inline scanning: 파서가 AST를 구축하면서 import/export 레코드를 동시 수집
    parser.enable_scan = true;
    // require.context 등 build-time 정적 평가용 define entries 전달 (#1579 Phase 2.6)
    parser.scan_defines = self.defines;
    return true;
}
