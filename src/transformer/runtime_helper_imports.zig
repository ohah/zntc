//! Runtime helper virtual module 의 named import statement 를 transformer finalize 단계에 emit (#1961).
//!
//! Transformer 가 visit 도중 set 한 `RuntimeHelpers` 비트맵을 보고, 각 비트가 가리키는
//! helper base 들을 묶어 `import { __generator } from "\x00zts:runtime/generator"`
//! 형태의 import_declaration 노드를 program body 앞에 추가한다. graph parse 단계가
//! 이 노드를 발견해 helper module 을 chunk 분배 대상으로 등록한다.
//!
//! ## 비트맵 → 모듈 매핑
//!
//! `bundler/runtime_helper_modules.zig::moduleShortFor` 가 helper base name → module
//! short name 매핑의 단일 소스. 이 모듈은 RuntimeHelpers 의 packed 비트가 어떤 base
//! 들을 import 해야 하는지만 정의 — 모듈 short name 자체는 lookup.
//!
//! 비트 하나가 여러 base 를 export 하는 모듈을 가리키는 경우 (decorator/es-decorator/
//! using/class-static-private-field) 한 import statement 에 named specifier 를 모두 묶는다.
//!
//! ## 활성화 조건
//!
//! `TransformOptions.emit_runtime_helper_imports = true` 일 때만 동작. graph parse
//! 단계의 transformer pre-pass 만 이 플래그를 set — emitter 의 in-place transformer
//! 호출은 false 유지 (그래프 통합 없이 helper specifier 만 출력에 들어가는 사고 방지).

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const ImportPhase = @import("../parser/module.zig").ImportPhase;
const helper_modules = @import("../bundler/runtime_helper_modules.zig");
const helper_names = @import("../runtime_helper_names.zig");
const RuntimeHelpers = @import("transformer.zig").RuntimeHelpers;

/// RuntimeHelpers 비트 ↔ helper base list 매핑.
/// 비트 하나 = helper module 하나. `bases` 의 첫 항목은 module short 결정용 lookup key
/// (같은 모듈 안의 helper 라 어느 것을 골라도 동일 short 반환). 나머지는 named export.
const BitDef = struct {
    field: []const u8,
    bases: []const []const u8,
};

const BIT_DEFS = [_]BitDef{
    .{ .field = "async_helper", .bases = &.{"__async"} },
    .{ .field = "extends", .bases = &.{"__extends"} },
    .{ .field = "spread_array", .bases = &.{"__toConsumableArray"} },
    .{ .field = "generator", .bases = &.{"__generator"} },
    .{ .field = "rest", .bases = &.{"__rest"} },
    .{ .field = "values", .bases = &.{"__values"} },
    .{ .field = "to_binary", .bases = &.{"__toBinary"} },
    .{ .field = "keep_names", .bases = &.{"__name"} },
    .{ .field = "class_private_method_init", .bases = &.{"__classPrivateMethodInit"} },
    .{ .field = "class_private_method_get", .bases = &.{"__classPrivateMethodGet"} },
    .{ .field = "class_call_check", .bases = &.{"__classCallCheck"} },
    .{ .field = "call_super", .bases = &.{"__callSuper"} },
    .{ .field = "tagged_template_literal", .bases = &.{"__taggedTemplateLiteral"} },
    .{ .field = "using_ctx", .bases = &.{ "__using", "__callDispose" } },
    .{ .field = "class_static_private_field", .bases = &.{
        "__classCheckPrivateStaticAccess",
        "__classCheckPrivateStaticFieldDescriptor",
        "__classStaticPrivateFieldSpecGet",
        "__classStaticPrivateFieldSpecSet",
    } },
    .{ .field = "es_decorator", .bases = &.{
        "__esDecorate",
        "__runInitializers",
        "__setFunctionName",
        "__propKey",
    } },
    .{ .field = "async_values", .bases = &.{"__asyncValues"} },
    .{ .field = "class_private_field_set", .bases = &.{"__classPrivateFieldSet"} },
    .{ .field = "async_generator", .bases = &.{"__asyncGenerator"} },
    .{ .field = "await_helper", .bases = &.{"__await"} },
};

comptime {
    // BIT_DEFS 의 field 이름이 RuntimeHelpers 의 실 필드와 매핑되는지 빌드 타임 검증.
    // 이름 typo 를 하면 즉시 컴파일 에러로 노출.
    for (BIT_DEFS) |def| {
        if (!@hasField(RuntimeHelpers, def.field)) {
            @compileError("BIT_DEFS field '" ++ def.field ++ "' not present on RuntimeHelpers");
        }
    }
}

/// 비트맵에 set 된 비트마다 import_declaration 노드 1개씩 생성하여 `out` 에 append.
/// `span` 은 새 노드의 위치 정보 (prepend 대상의 span 권장).
/// `self` 는 transformer (allocator/ast/scratch/options 가짐).
pub fn appendHelperImports(
    self: anytype,
    helpers: RuntimeHelpers,
    span: Span,
    out: *std.ArrayList(NodeIndex),
) !void {
    inline for (BIT_DEFS) |def| {
        if (@field(helpers, def.field)) {
            try emitOne(self, def.bases, span, out);
        }
    }
}

fn emitOne(
    self: anytype,
    bases: []const []const u8,
    span: Span,
    out: *std.ArrayList(NodeIndex),
) !void {
    // bases[0] 이 module 안의 한 helper. moduleShortFor 가 module short 를 반환.
    const id = (try helper_modules.idForBase(self.allocator, bases[0])) orelse return;
    defer self.allocator.free(id);

    // source string_literal: codegen 이 raw span text 를 그대로 출력하므로 quote 포함.
    const quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{id});
    defer self.allocator.free(quoted);
    const source_span = try self.ast.addString(quoted);
    const source_node = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = source_span,
        .data = .{ .string_ref = source_span },
    });

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    for (bases) |base| {
        const local = helper_names.helperName(base, self.options.minify_whitespace);

        const imported_span = try self.ast.addString(base);
        const imported_node = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = imported_span,
            .data = .{ .string_ref = imported_span },
        });

        // local == base 면 같은 노드 재사용 (parser 패턴 — module.zig:516).
        const local_node = if (std.mem.eql(u8, local, base)) imported_node else blk: {
            const local_span = try self.ast.addString(local);
            break :blk try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = local_span,
                .data = .{ .string_ref = local_span },
            });
        };

        const spec = try self.ast.addNode(.{
            .tag = .import_specifier,
            .span = span,
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
        .span = span,
        .data = .{ .extra = extra_start },
    });
    try out.append(self.allocator, decl);
}

// ============================================================
// 단위 테스트
// ============================================================

test "BIT_DEFS 의 모든 base 가 helper_modules 에 등록되어 있음" {
    // 빌드 타임 drift 가드: BIT_DEFS 추가 후 helper_modules.MODULES 매핑 누락이 즉시 노출.
    inline for (BIT_DEFS) |def| {
        for (def.bases) |base| {
            try std.testing.expect(helper_modules.moduleShortFor(base) != null);
        }
    }
}

test "BIT_DEFS 의 같은 비트 안 모든 base 가 동일 module short 로 매핑" {
    // 묶음 모듈 (decorator/es-decorator/using/class-static-private-field) 의 base 가
    // 같은 short 인지 검증. drift 시 한 비트가 두 모듈에 분산되어 import 출력 깨짐.
    inline for (BIT_DEFS) |def| {
        if (def.bases.len > 1) {
            const first_short = helper_modules.moduleShortFor(def.bases[0]).?;
            for (def.bases[1..]) |base| {
                const s = helper_modules.moduleShortFor(base).?;
                try std.testing.expectEqualStrings(first_short, s);
            }
        }
    }
}
