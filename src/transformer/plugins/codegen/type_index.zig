//! Type alias / interface 인덱싱 — 같은 파일 내 top-level 선언 이름 → NodeIndex 맵
//!
//! `program` 노드의 직계 자식만 순회하면서 type-only declaration 태그를 이름 →
//! NodeIndex 로 인덱싱한다. 재귀 안 함 (top-level only).
//!
//! 대상 태그는 `Tag.isTypeOnlyDeclaration()` (`ast.zig:390`) 이 true 인 5 종:
//!   - `ts_type_alias_declaration`
//!   - `ts_interface_declaration`
//!   - `flow_type_alias_declaration`
//!   - `flow_interface_declaration`
//!   - `flow_opaque_type`
//!
//! 이 5 종 모두 `data.extra` 의 첫 슬롯에 binding_identifier NodeIndex 를 두는
//! 컨벤션. 새 태그가 추가되면 같은 컨벤션을 따르는지 확인 필요 (현재 파서 코드
//! 검증 결과 5 종 모두 일관).
//!
//! 사용 시점: codegen plugin 의 첫 패스. 두 번째 패스에서 NativeProps 같은 type
//! reference 만났을 때 이 인덱스로 정의 노드를 찾는다.
//!
//! 알려진 한계:
//!
//!   - **`export type Foo = ...` 는 인덱싱 안 됨.** ZTS 파서 (`module.zig:885`) 가
//!     type-only declaration 의 export wrapper 를 parse 시점에 program 에서
//!     제거하기 때문. 해당 type alias 노드 자체는 `ast.nodes` 에 orphan 으로
//!     남지만 program 에서 도달 불가. NativeComponent spec 파일에서 NativeProps
//!     를 export 하는 패턴은 일반적이지 않으므로 (보통 unhindered `type
//!     NativeProps = ...`) 실용적 영향 없음. 영향 받는 spec 은 schema_builder
//!     (PR #3) 가 fail-fast 하고 Bungae 는 JS fallback 으로 처리.
//!   - Cross-file 미지원 (#2348 § 5): import 한 type reference 도 동일 fallback.
//!
//! 메모리: 호출자가 alloc 제공. arena 권장 — `arena.deinit()` 으로 일괄 해제,
//! `TypeIndex.deinit` 호출 불필요. 일반 allocator 쓰면 명시적으로 deinit.

const std = @import("std");
const ast_mod = @import("../../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;

/// 같은 파일 내 type alias / interface 선언의 이름 → NodeIndex 맵.
///
/// 반환된 NodeIndex 는 항상 type-only declaration 태그 중 하나를 가리킨다.
/// `export <decl>` 같은 wrapper 노드는 ZTS 파서가 parse 시점에 program 에서
/// 제거하므로 (`module.zig:885`) 이 인덱스에 들어오지 않는다.
///
/// **Lifetime 주의**: 키 (이름) 는 `Ast.string_table` 또는 source buffer 의
/// 슬라이스 — 별도 dupe 안 함. 호출자는 이 인덱스를 사용하는 동안 ast (및
/// 그 backing source buffer) 가 유효해야 한다. arena 기반에서 ast 와 함께
/// schema_builder 가 끝나면 일괄 해제되는 패턴 권장.
pub const TypeIndex = struct {
    /// 키 (이름) 는 `Ast.string_table` 또는 source buffer 가 소유 — 별도 dupe 안 함.
    /// 값은 declaration NodeIndex.
    map: std.StringHashMapUnmanaged(NodeIndex) = .empty,

    /// 일반 allocator 사용 시 명시 해제. arena 사용 시 호출 불필요.
    pub fn deinit(self: *TypeIndex, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    /// 이름 lookup — 못 찾으면 null.
    pub fn get(self: *const TypeIndex, name: []const u8) ?NodeIndex {
        return self.map.get(name);
    }

    /// 인덱싱된 선언 수.
    pub fn count(self: *const TypeIndex) usize {
        return self.map.count();
    }
};

/// `program` 노드의 직계 자식을 훑어 type alias / interface 를 인덱싱.
///
/// 중복 이름이면 마지막 정의가 이김 — codegen 은 단일 정의 가정 (파일 내 같은
/// 이름 두 번 선언은 사실상 사용자 버그).
///
/// 에러: OOM 만 전파. `program_idx` 가 program 이 아니거나 손상된 AST 노드는
/// silent skip — 빈 인덱스로 반환 (호출자는 `count() == 0` 으로 감지 가능).
pub fn build(
    ast: *const Ast,
    program_idx: NodeIndex,
    alloc: std.mem.Allocator,
) !TypeIndex {
    var index: TypeIndex = .{};

    const program = ast.getNode(program_idx);
    if (program.tag != .program) return index;

    const list = program.data.list;
    const items = ast.extra_data.items[list.start .. list.start + list.len];
    for (items) |raw| {
        const stmt_idx: NodeIndex = @enumFromInt(raw);
        if (stmt_idx == .none) continue;

        const decl = ast.getNode(stmt_idx);
        const name = nameOfDecl(ast, decl) orelse continue;
        try index.map.put(alloc, name, stmt_idx);
    }
    return index;
}

/// type-only declaration 의 첫 extra 슬롯에서 binding_identifier 를 읽어 텍스트 반환.
/// type-only 가 아닌 태그면 null. 5 종 layout 모두 `extra[0] = name` 컨벤션:
///
///   - `ts_type_alias_declaration`:    extra = [name, type_params, ty]
///   - `ts_interface_declaration`:     extra = [name, type_params, extends_start, extends_len, body]
///   - `flow_type_alias_declaration`:  extra = [name, type_params, value]
///   - `flow_interface_declaration`:   extra = [name, type_params, extends_start, extends_len]
///   - `flow_opaque_type`:             extra = [name, type_params, supertype, value]
///
/// `Tag.isTypeOnlyDeclaration()` (`ast.zig:390`) 을 가드로 사용 — ast.zig 에 새
/// type-only declaration 이 추가되면 자동으로 포함된다 (drift-proof). 단,
/// 새 태그가 위 컨벤션을 따라야 한다.
fn nameOfDecl(ast: *const Ast, node: Node) ?[]const u8 {
    if (!node.tag.isTypeOnlyDeclaration()) return null;

    const extra_start = node.data.extra;
    if (extra_start >= ast.extra_data.items.len) return null;
    const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extra_start]);
    if (name_idx == .none) return null;

    const name_node = ast.getNode(name_idx);
    if (name_node.tag != .binding_identifier) return null;
    return ast.getText(name_node.data.string_ref);
}
