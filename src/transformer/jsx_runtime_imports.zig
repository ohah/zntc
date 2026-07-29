//! JSX automatic runtime import 를 transformer finalize 단계에 정식 AST 노드로 추가 (#3062).
//!
//! 기존 `JsxImportInfo.buildImportString` 은 string 으로 import 를 만들어
//! `transpile.zig::prependImportLine` 으로 output 에 합쳐버리는 single-file 경로 전용이었다.
//! bundle 흐름은 이 string 을 사용 못 해서, parser_metadata 가 `synthetic ImportRecord +
//! ImportBinding` 을 별도 inject 하는 우회 경로를 만들었다. 우회 경로는 linker / mangler /
//! emitter 곳곳에 `isSynthetic` 분기를 남겼다.
//!
//! 본 모듈은 transformer 안에서 JSX runtime import 를 정식 import_declaration 노드로 만들어
//! program body 에 prepend 한다. 이후 graph resync 단계의 import_scanner / binding_scanner 가
//! 일반 import 처럼 detect → 다운스트림에 synthetic 분기 없이 처리된다.
//! `runtime_helper_imports.zig` 가 사용하는 패턴과 의도적으로 동일 구조.
//!
//! `#2869` helper marker (helper_scope_map 격리) 도 함께 적용 (#3068). 사용자가
//! `const _jsx = ...` 같이 같은 이름을 선언했을 때 resync 의 binding_scanner 가
//! user scope 와 helper scope 를 분리 → JSX call 이 사용자 binding 을 잘못 가리키는
//! 충돌을 회피. `jsx_lowering` 의 ref 생성도 같은 marker 를 거친다.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const ImportPhase = @import("../parser/module.zig").ImportPhase;
const JsxImportInfo = @import("jsx_lowering.zig").JsxImportInfo;

const Pair = struct { imported: []const u8, local: []const u8 };

/// JSX runtime import statement (들) 를 만들어 `out` 에 append.
/// `info` 가 어떤 helper 가 사용됐는지 추적. `import_source` 는 옵션의 jsx-import-source
/// (예: "react", "preact"). `is_dev` 가 true 면 `/jsx-dev-runtime` 사용.
///
/// 호출 위치: `transformer/transformer/driver.zig::transform` 의 finalize 단계 — runtime
/// helper import 와 같은 분기 (`emit_runtime_helper_imports`) 안에서.
pub fn appendJsxRuntimeImports(
    self: anytype,
    info: JsxImportInfo,
    import_source: []const u8,
    is_dev: bool,
    span: Span,
    out: *std.ArrayList(NodeIndex),
) !void {
    if (!info.hasImports()) return;

    // jsx-runtime (또는 jsx-dev-runtime) — jsx / jsxs / jsxDEV / Fragment
    if (info.used_jsx or info.used_jsxs or info.used_jsxDEV or info.used_fragment) {
        const subpath = if (is_dev) "/jsx-dev-runtime" else "/jsx-runtime";
        const specifier = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ import_source, subpath });
        defer self.allocator.free(specifier);

        var pairs_buf: [3]Pair = undefined;
        var pairs_len: usize = 0;
        if (is_dev) {
            if (info.used_jsxDEV) {
                pairs_buf[pairs_len] = .{ .imported = "jsxDEV", .local = "_jsxDEV" };
                pairs_len += 1;
            }
        } else {
            if (info.used_jsx) {
                pairs_buf[pairs_len] = .{ .imported = "jsx", .local = "_jsx" };
                pairs_len += 1;
            }
            if (info.used_jsxs) {
                pairs_buf[pairs_len] = .{ .imported = "jsxs", .local = "_jsxs" };
                pairs_len += 1;
            }
        }
        if (info.used_fragment) {
            pairs_buf[pairs_len] = .{ .imported = "Fragment", .local = "_Fragment" };
            pairs_len += 1;
        }
        if (pairs_len > 0) {
            try emitImportDeclaration(self, specifier, pairs_buf[0..pairs_len], span, out);
        }
    }

    // key-after-spread 폴백: `<source>` 에서 `createElement` 만 import.
    if (info.used_createElement) {
        const pair = [_]Pair{.{ .imported = "createElement", .local = "_createElement" }};
        try emitImportDeclaration(self, import_source, &pair, span, out);
    }
}

fn emitImportDeclaration(
    self: anytype,
    source_specifier: []const u8,
    pairs: []const Pair,
    span: Span,
    out: *std.ArrayList(NodeIndex),
) !void {
    // (#4596) 합성 노드 span 은 *위치 anchor* 로만 쓰고 길이 0 으로 접는다.
    // 호출자(`driver.zig`)는 prepend 대상인 program root 의 span 을 넘긴다 = 파일 전체 범위.
    // 그걸 그대로 노드 span 으로 쓰면, span 포함 관계로 "이 참조가 선언 안에 있나" 를 판정하는
    // 소비자에게 이 import_declaration 이 *파일 전체를 덮는 선언 범위* 로 보인다
    // (`NamespaceAccessIndex.decl_ranges` → `isInDecl`). 그러면 그 모듈의 모든 namespace
    // 참조가 "import 선언 내부라 참조 아님" 으로 skip 돼 멤버 사용이 0건으로 집계되고,
    // tree-shaker 가 실제로 살아있는 export 를 제거한다 → 출력엔 `_jsx(Root)` 참조만 남고
    // 선언이 없는 dangling ReferenceError (#4596: `import * as NS` + `<NS.Root>`).
    // 합성 import 는 대응하는 원본 소스 텍스트가 없으므로 zero-length 가 정확한 표현이다.
    const anchor: Span = .{ .start = span.start, .end = span.start };

    // source string_literal — codegen 이 raw span text 그대로 출력하므로 quote 포함 저장.
    const quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{source_specifier});
    defer self.allocator.free(quoted);
    const source_text = try self.ast.addString(quoted);
    const source_node = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = source_text,
        .data = .{ .string_ref = source_text },
    });

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    for (pairs) |p| {
        const imported_text = try self.ast.addString(p.imported);
        const imported_node = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = imported_text,
            .data = .{ .string_ref = imported_text },
        });

        const local_text = try self.ast.addString(p.local);
        const local_node = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = local_text,
            .data = .{ .string_ref = local_text },
        });
        try self.markRuntimeHelperRef(local_node);

        const spec = try self.ast.addNode(.{
            .tag = .import_specifier,
            .span = anchor,
            .data = .{ .binary = .{ .left = imported_node, .right = local_node, .flags = 0 } },
        });
        try self.scratch.append(self.allocator, spec);
    }

    const specs = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const extra_start = try self.ast.addExtras(&.{
        specs.start,
        specs.len,
        @intFromEnum(source_node),
        @intFromEnum(ImportPhase.none),
        0, // attrs.start
        0, // attrs.len
    });
    const decl = try self.ast.addNode(.{
        .tag = .import_declaration,
        .span = anchor,
        .data = .{ .extra = extra_start },
    });
    try out.append(self.allocator, decl);
}
