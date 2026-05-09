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

    // .js/.jsx: package.json "type" 또는 Unambiguous 모드로 module/script 결정
    // .mjs/.mts/.ts/.tsx: 이미 확정 module, 변경 없음
    if (!parser.is_module) {
        parser.is_module = true;
        scanner.is_module = true;
        if (module.def_format == .unknown) {
            parser.is_unambiguous = true;
        }
    }
    // Inline scanning: 파서가 AST를 구축하면서 import/export 레코드를 동시 수집
    parser.enable_scan = true;
    // require.context 등 build-time 정적 평가용 define entries 전달 (#1579 Phase 2.6)
    parser.scan_defines = self.defines;
    return true;
}
