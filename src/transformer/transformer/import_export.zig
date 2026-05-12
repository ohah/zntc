//! Import/export helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const module_parser = @import("../../parser/module.zig");
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const emotion_mod = @import("emotion.zig");
const styled_components_mod = @import("styled_components.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// export default class/function → ES5 lowering 시 operand가 .none이 되는 케이스 처리.
/// lowerClassDeclaration이 pending_nodes에 function 등을 넣고 .none을 반환하므로,
/// 클래스/함수 이름(또는 익명의 합성 이름 _Class)의 identifier reference를 operand로 사용.
pub fn visitExportDefaultDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    const operand_idx = node.data.unary.operand;
    const new_operand = try self.visitNode(operand_idx);

    if (new_operand.isNone()) {
        const operand_node = self.ast.getNode(operand_idx);
        if (operand_node.tag == .class_declaration or operand_node.tag == .function_declaration) {
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[operand_node.data.extra]);
            // named class/function → 원본 이름 사용
            // anonymous class → lowerClassDeclaration이 "_Class"로 합성 (addString)
            const name_span = if (!name_idx.isNone())
                self.ast.getNode(name_idx).data.string_ref
            else
                try self.ast.addString("_Class");
            const name_ref = try self.makeIdentifierRefWithSymbol(name_span, name_idx);
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .unary = .{ .operand = name_ref, .flags = node.data.unary.flags } },
            });
        }
    }

    return self.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
    });
}

pub fn visitImportDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    try styled_components_mod.detectStyledImport(self, node);
    try emotion_mod.detectEmotionImport(self, node);

    const x = module_parser.readImportDeclExtras(self.ast, node.data.extra);

    // Unused import 제거: 모든 specifier의 reference_count가 0이면 import 전체를 제거.
    // side-effect import는 specifier가 없으면 제거 불가.
    // verbatimModuleSyntax=true면 elision 생략 — 값 import는 그대로 보존.
    if (!self.options.verbatim_module_syntax and
        hasImportElisionFacts(self) and x.specs_len > 0)
    {
        if (areAllSpecifiersUnused(self, x.specs_start, x.specs_len)) return .none;
    }

    // module_specifier_map: cherry-pick 분해. 매핑 entry 와 source 일치 + 모든 specifier
    // 가 named/no-alias/value 면 한 import 를 default + path 형태 N개로 split.
    if (self.options.module_specifier_map.len > 0 and x.attrs_len == 0 and x.phase == .none) {
        if (findModuleMapTemplate(self, x.source)) |template| {
            if (try rewriteImportToPathSplits(self, node, x, template)) |rewritten| {
                return rewritten;
            }
        }
    }

    const new_specs = try self.visitExtraList(.{ .start = x.specs_start, .len = x.specs_len });
    const new_source = try self.visitNode(x.source);
    // phase / attributes는 metadata — transform 대상 아님, 그대로 통과.
    return self.addExtraNode(.import_declaration, node.span, &.{
        new_specs.start,       new_specs.len, @intFromEnum(new_source),
        @intFromEnum(x.phase), x.attrs_start, x.attrs_len,
    });
}

/// visit switch 용 wrapper — `verbatim_module_syntax` 와 symbol table 준비 여부를
/// 먼저 가드한 뒤 `isImportSpecifierUnused` 에 위임. #1791 Phase D 의 elision 조건을
/// default/named/namespace 세 switch arm 이 동일하게 적용하도록 모아둔다.
pub fn shouldElideImportSpecifier(self: *const Transformer, spec_idx: NodeIndex, spec_node: Node) bool {
    if (self.options.verbatim_module_syntax) return false;
    if (!hasImportElisionFacts(self)) return false;
    return isImportSpecifierUnused(self, spec_idx, spec_node);
}

/// export_all_declaration: `module_parser.ExportAllExtras` 참고.
/// attrs 는 string literal 쌍이라 visit 불필요 — 원본 리스트 그대로 전달.
pub fn visitExportAllDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    const x = module_parser.readExportAllExtras(self.ast, node.data.extra);
    const new_name = try self.visitNode(x.exported_name);
    const new_source = try self.visitNode(x.source);
    return self.addExtraNode(.export_all_declaration, node.span, &.{
        @intFromEnum(new_name),
        @intFromEnum(new_source),
        x.attrs_start,
        x.attrs_len,
    });
}

/// export_named_declaration: `module_parser.ExportNamedExtras` 참고.
/// attrs 는 string literal 쌍이라 visit 불필요 — 원본 리스트 그대로 전달.
pub fn visitExportNamedDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    const x = module_parser.readExportNamedExtras(self.ast, node.data.extra);
    const new_decl = try self.visitNode(x.decl);
    const new_specs = try self.visitExtraList(.{ .start = x.specs_start, .len = x.specs_len });
    const new_source = try self.visitNode(x.source);
    // export interface/type alias 등 타입 선언만 있으면 빈 export {} 제거
    // export { type Foo } from './a' 같은 re-export는 source가 있으므로 유지
    if (new_decl.isNone() and new_specs.len == 0 and new_source.isNone()) {
        // `@dec export class Named`: Stage 3 decorator pass가 outer_var_decl을
        // pending_nodes로 hoist하고 `.none`을 반환한 경우 — 원본 class 이름으로
        // `export { Named };` specifier를 합성해 export 키워드가 drop되지 않게 한다.
        const orig_decl_idx = x.decl;
        if (!orig_decl_idx.isNone()) {
            const orig_decl = self.ast.getNode(orig_decl_idx);
            if (orig_decl.tag == .class_declaration) {
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[orig_decl.data.extra]);
                if (!name_idx.isNone()) {
                    const name_span = self.ast.getNode(name_idx).data.string_ref;
                    const local_ref = try self.makeIdentifierRefWithSymbol(name_span, name_idx);
                    const exported_ref = try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = name_span,
                        .data = .{ .string_ref = name_span },
                    });
                    const specifier = try self.ast.addNode(.{
                        .tag = .export_specifier,
                        .span = node.span,
                        .data = .{ .binary = .{ .left = local_ref, .right = exported_ref, .flags = 0 } },
                    });
                    const specs = try self.ast.addNodeList(&.{specifier});
                    return self.addExtraNode(.export_named_declaration, node.span, &.{
                        @intFromEnum(NodeIndex.none), specs.start, specs.len, @intFromEnum(NodeIndex.none),
                        0, 0, // attrs empty
                    });
                }
            }
        }
        return NodeIndex.none;
    }
    return self.addExtraNode(.export_named_declaration, node.span, &.{
        @intFromEnum(new_decl), new_specs.start, new_specs.len, @intFromEnum(new_source),
        x.attrs_start,          x.attrs_len,
    });
}

/// import source string 이 module_specifier_map 의 entry 와 매칭되면 template 반환.
/// `'lodash'` 같은 구체 매칭만 — wildcard 미지원. unmatched 면 null.
fn findModuleMapTemplate(self: *Transformer, source_idx: NodeIndex) ?[]const u8 {
    const source_node = self.ast.getNode(source_idx);
    if (source_node.tag != .string_literal) return null;
    const raw = self.ast.getText(source_node.data.string_ref);
    const stripped = Ast.stripStringQuotes(raw);
    for (self.options.module_specifier_map) |entry| {
        if (std.mem.eql(u8, stripped, entry.module)) return entry.template;
    }
    return null;
}

/// 매핑 조건 충족 시 분해. 단일 named → 단일 default 노드 반환. 다중 → 첫 specifier 만
/// 반환하고 나머지는 trailing_nodes 로 같은 list 에 추가. 조건 미충족 (default/namespace/
/// alias/type-only) 이면 null 반환 — caller 가 unchanged path 진행.
fn rewriteImportToPathSplits(
    self: *Transformer,
    node: Node,
    x: module_parser.ImportDeclExtras,
    template: []const u8,
) Error!?NodeIndex {
    if (x.specs_len == 0) return null;

    // 모든 specifier 검증 — named, no alias, no type-only
    var i: u32 = 0;
    while (i < x.specs_len) : (i += 1) {
        const spec_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[x.specs_start + i]);
        const spec_node = self.ast.getNode(spec_idx);
        if (spec_node.tag != .import_specifier) return null;
        // type-only specifier — 분해 X (path 에 type 만 export 안 함)
        if ((spec_node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) return null;
        // alias 없는지: imported == local (NodeIndex 동일성)
        if (spec_node.data.binary.left != spec_node.data.binary.right) return null;
    }

    var first_result: ?NodeIndex = null;
    i = 0;
    while (i < x.specs_len) : (i += 1) {
        const spec_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[x.specs_start + i]);
        const spec_node = self.ast.getNode(spec_idx);
        const name_node = self.ast.getNode(spec_node.data.binary.left);
        const name_span = name_node.span;
        const name_text = self.ast.getText(name_span);

        const new_decl = try buildDefaultImportFromTemplate(
            self,
            name_span,
            name_text,
            template,
            node.span,
        );

        if (first_result == null) {
            first_result = new_decl;
        } else {
            try self.trailing_nodes.append(self.allocator, new_decl);
        }
    }
    return first_result;
}

/// `import <name> from '<template:name>'` 의 AST 노드 빌드.
fn buildDefaultImportFromTemplate(
    self: *Transformer,
    name_span: Span,
    name_text: []const u8,
    template: []const u8,
    decl_span: Span,
) Error!NodeIndex {
    // path string: template 의 `{name}` 을 name_text 로 치환 + quote
    const path_text = try renderTemplate(self, template, name_text);
    defer self.allocator.free(path_text);
    const quoted = try std.fmt.allocPrint(self.allocator, "'{s}'", .{path_text});
    defer self.allocator.free(quoted);
    const path_span = try self.ast.addString(quoted);

    const default_spec = try self.ast.addNode(.{
        .tag = .import_default_specifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
    const source_node = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = path_span,
        .data = .{ .string_ref = path_span },
    });

    const specs_start = try self.ast.addExtras(&.{@intFromEnum(default_spec)});
    return self.addExtraNode(.import_declaration, decl_span, &.{
        specs_start,               1,
        @intFromEnum(source_node), @intFromEnum(module_parser.ImportPhase.none),
        0,                         0,
    });
}

/// `'lodash/{name}'` 의 `{name}` placeholder 치환. 첫 occurrence 만 — 일반적 사용처.
/// placeholder 없는 template (e.g. `'lodash'`) 은 _malformed config_ — 모든 specifier
/// 가 동일 path 로 합쳐져 사실상 invalid. caller 책임으로 정상 매핑 제공 가정.
fn renderTemplate(self: *Transformer, template: []const u8, name: []const u8) Error![]u8 {
    const placeholder = "{name}";
    if (std.mem.indexOf(u8, template, placeholder)) |idx| {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}{s}{s}",
            .{ template[0..idx], name, template[idx + placeholder.len ..] },
        );
    }
    // placeholder 없으면 template 그대로 — 거의 의미 없는 매핑이지만 caller 책임.
    return self.allocator.dupe(u8, template);
}

/// import의 모든 specifier가 미사용인지 확인한다.
/// type-only specifier(이미 스트리핑됨)와 reference_count==0인 specifier만 있으면 true.
fn areAllSpecifiersUnused(self: *Transformer, specs_start: u32, specs_len: u32) bool {
    var i: u32 = 0;
    while (i < specs_len) : (i += 1) {
        const spec_idx_raw = self.ast.extra_data.items[specs_start + i];
        const spec_idx: NodeIndex = @enumFromInt(spec_idx_raw);
        if (spec_idx.isNone()) continue;
        const spec_node = self.ast.getNode(spec_idx);

        // type-only specifier → 이미 스트리핑됨, 무시
        if (spec_node.tag == .import_specifier and (spec_node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;
        if (spec_node.tag == .export_specifier) continue; // 방어적: export specifier는 여기 없지만

        if (!isImportSpecifierUnused(self, spec_idx, spec_node)) return false;
    }
    return true;
}

fn hasImportElisionFacts(self: *const Transformer) bool {
    return (self.symbols.len > 0 and self.symbol_ids.items.len > 0) or self.binding_lite != null;
}

/// 단일 import specifier 의 local binding 이 value 로 참조된 적이 있는지 조회.
/// #1791 Phase D 판정: symbol 의 Reference 들 중 **type_context / value_as_type 이
/// 모두 false 인 read** (= 순수 value 사용) 가 하나라도 있으면 false. 하나도 없으면
/// true (= elide 가능).
///
/// 기존 `reference_count` 기반 접근은 false positive — `export { X }` / JSX tag /
/// namespace member access 같은 경로가 analyzer 에서 카운트되지 않아 value-use 가
/// 있음에도 "미사용" 으로 오판했음 (PR #1793 revert 원인).
///
/// `self.references` 가 비어있으면 보수적으로 "사용 중" 간주. symbol_id 조회 실패도 동일.
fn isImportSpecifierUnused(self: *const Transformer, spec_idx: NodeIndex, spec_node: Node) bool {
    // #1791: Phase D 를 **named specifier 한정**. default/namespace 는 JSX pragma,
    // CSS-in-JS default export, namespace member access 같은 implicit value use 가
    // 많아 false positive 위험이 큼 (#1793 revert 원인). bungae 의 실제 crash 경로
    // (`import { HeaderBarButtonItem }`) 는 named 이므로 이 제한으로도 해결.
    if (spec_node.tag != .import_specifier) return false;
    const local_idx = spec_node.data.binary.right;
    const sym_node_idx: u32 = if (!local_idx.isNone()) @intFromEnum(local_idx) else @intFromEnum(spec_idx);
    const local_node = if (!local_idx.isNone()) self.ast.getNode(local_idx) else spec_node;
    const local_name = self.ast.getText(local_node.span);

    // classic JSX lowering 은 source 에 없던 factory/fragment identifier 참조를 만든다 —
    // elision 이 보는 reference / binding_lite 스캔에는 안 잡히므로, head identifier 가
    // 일치하면 value-use 로 간주해 keep. automatic 모드의 jsx-runtime import 는
    // transformer 가 직접 주입하므로 (user import 아님) 이 경로와 무관 (#3063).
    if (self.ast.has_jsx and self.options.shouldLowerJsx() and self.options.jsx_runtime == .classic) {
        if (std.mem.eql(u8, local_name, self.options.jsxClassicFactoryHead()) or
            std.mem.eql(u8, local_name, self.options.jsxClassicFragmentHead()))
            return false;
    }

    if (self.binding_lite) |binding_lite| {
        if (binding_lite.namedImportValueUse(local_name)) |used_as_value| return !used_as_value;
        return false;
    }

    if (sym_node_idx >= self.symbol_ids.items.len) return false;
    const sym_id = self.symbol_ids.items[sym_node_idx] orelse return false;
    if (sym_id >= self.symbols.len) return false;

    // Reference 들 중 value-use 하나라도 있으면 keep. 판정은 `Reference.isValueUse`
    // 가 공통으로 수행 — linker 의 `isImportBindingTypeOnly` 와 동일 기준.
    for (self.references) |r| {
        if (@intFromEnum(r.symbol_id) != sym_id) continue;
        if (r.isValueUse()) return false;
    }
    return true;
}
