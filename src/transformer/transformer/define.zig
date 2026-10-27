//! Define replacement helpers for Transformer.

const std = @import("std");
const es_helpers = @import("../es_helpers.zig");
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Scanner = @import("../../lexer/scanner.zig").Scanner;
const Kind = @import("../../lexer/token.zig").Kind;
const type_args = @import("../../parser/expression/type_args.zig");
const ReferenceFlags = @import("../../semantic/symbol.zig").ReferenceFlags;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// define 치환 엔트리. key=식별자 텍스트, value=치환 문자열.
/// `parser.scan_results.DefineEntry` 와 동일 정의 — parser 의 inline scan 도 같은 entries 사용.
pub const DefineEntry = @import("../../parser/scan_results.zig").DefineEntry;

/// 정규화 버퍼 크기. `process.env.NODE_ENV`류 식별자 체인은 훨씬 짧지만 여유.
/// 초과 시 normalizeOptionalChain은 null을 반환해 치환을 스킵한다.
const DEFINE_KEY_NORM_BUF: usize = 256;

/// 번들 맥락에서 의미 없는 global root 접두어.
/// `globalThis.X`, `window.X`, `self.X` → X로 간주해 define 키와 매칭.
const GLOBAL_ROOT_PREFIXES = [_][]const u8{ "globalThis.", "window.", "self." };

/// optional chaining 토큰 `?.`를 `.`로 치환한 정규화 문자열을 buf에 쓴다.
/// 정규화된 길이가 buf 용량을 초과하면 null (극히 드문 경로 — 치환 포기).
fn normalizeOptionalChain(text: []const u8, buf: []u8) ?[]const u8 {
    const needed = std.mem.replacementSize(u8, text, "?.", ".");
    if (needed > buf.len) return null;
    _ = std.mem.replace(u8, text, "?.", ".", buf);
    return buf[0..needed];
}

/// define 키 매칭 — 엄격 일치 또는 GLOBAL_ROOT_PREFIXES 제거 후 일치.
/// 예: `globalThis.process.env.NODE_ENV`를 키 `process.env.NODE_ENV`로 매치.
fn matchDefineKey(text: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, text, key)) return true;
    for (GLOBAL_ROOT_PREFIXES) |pfx| {
        if (std.mem.startsWith(u8, text, pfx) and std.mem.eql(u8, text[pfx.len..], key)) return true;
    }
    return false;
}

fn getDefineCandidateText(ast: *const Ast, node: Node) ?[]const u8 {
    return switch (node.tag) {
        .identifier_reference,
        .static_member_expression,
        .chain_expression,
        => ast.getText(node.span),
        else => null,
    };
}

/// Return the first define value that matches a candidate node. Keep this in
/// one place so retained-graph preflight and transformation use identical
/// normalization and first-match behavior.
pub fn matchedDefineValue(ast: *const Ast, node: Node, defines: []const DefineEntry) ?[]const u8 {
    const raw_text = getDefineCandidateText(ast, node) orelse return null;

    var norm_buf: [DEFINE_KEY_NORM_BUF]u8 = undefined;
    const text = if (std.mem.indexOfScalar(u8, raw_text, '?') != null)
        normalizeOptionalChain(raw_text, &norm_buf) orelse return null
    else
        raw_text;

    for (defines) |entry| {
        if (matchDefineKey(text, entry.key)) return entry.value;
    }
    return null;
}

pub fn isStringLiteralDefineValue(value: []const u8) bool {
    return value.len >= 2 and (value[0] == '"' or value[0] == '\'');
}

/// These exact primitive spellings are emitted as literals (or `void 0`), so
/// their replacements carry no source SymbolId reference edge.
pub fn isGraphSafePrimitiveDefineValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "null") or
        std.mem.eql(u8, value, "undefined");
}

pub fn astUsesDefine(ast: *const Ast, defines: []const DefineEntry) bool {
    if (defines.len == 0) return false;
    var scratch_arena = std.heap.ArenaAllocator.init(ast.allocator);
    defer scratch_arena.deinit();
    var module_specifier_names = std.DynamicBitSet.initEmpty(scratch_arena.allocator(), ast.nodes.items.len) catch return true;
    for (ast.nodes.items) |node| {
        if (node.tag != .import_specifier and node.tag != .export_specifier) continue;
        const children = [_]NodeIndex{ node.data.binary.left, node.data.binary.right };
        for (children) |child| {
            if (child.isNone()) continue;
            const raw = @backingInt(child);
            if (@as(usize, raw) >= ast.nodes.items.len) return true;
            module_specifier_names.set(raw);
        }
    }
    for (ast.nodes.items, 0..) |node, raw| {
        if (module_specifier_names.isSet(raw)) continue;
        if (matchedDefineValue(ast, node, defines) != null) return true;
    }
    return false;
}

/// Build the identifier/member/call subset of a define value as real AST
/// nodes. The root identifier must resolve in the use site's lexical scope;
/// treating the whole value (for example `globalThis.readFlag()`) as one
/// explicit global identifier loses that SymbolId and lets mangling rename a
/// local root that the emitted expression still reads.
fn buildLexicalDefinePath(
    self: *Transformer,
    value: []const u8,
    replacement_span: @import("../../lexer/token.zig").Span,
) ?Error!NodeIndex {
    // Validate the entire supported grammar before creating AST nodes or graph
    // references. Unsupported expressions must not leave orphan SymbolId edges.
    var validation_scanner = Scanner.init(self.allocator, value) catch return Error.OutOfMemory;
    defer validation_scanner.deinit();
    validation_scanner.next() catch return Error.OutOfMemory;
    const validated = parseLexicalDefineExpression(
        self,
        &validation_scanner,
        value,
        replacement_span,
        0,
        0,
        false,
    ) orelse return null;
    _ = validated catch |err| return err;
    if (validation_scanner.token.kind != .eof) return null;

    var scanner = Scanner.init(self.allocator, value) catch return Error.OutOfMemory;
    defer scanner.deinit();
    scanner.next() catch return Error.OutOfMemory;
    const parsed = parseLexicalDefineExpression(self, &scanner, value, replacement_span, 0, 0, true) orelse return null;
    const output = parsed catch |err| return err;
    if (scanner.token.kind != .eof) return null;
    return output;
}

fn makeDefineLexicalRef(self: *Transformer, name: []const u8) Error!NodeIndex {
    if (std.mem.eql(u8, name, "arguments")) {
        if (self.define_native_arguments_owner) |owner| {
            const span = try self.ast.addString(name);
            return self.makeNativeArgumentsRef(owner, self.current_scope, span);
        }
    }
    return self.makeLexicalScopeRefAtScope(name, self.current_scope);
}

/// Parse a conservative define-expression subset. Every identifier reference
/// is resolved in the define use site's lexical scope. Calls accept nested
/// path expressions, primitive literal arguments, and binary expressions.
/// Other grammar falls back to the existing opaque-expression path.
fn parseLexicalDefineExpression(
    self: *Transformer,
    scanner: *Scanner,
    value: []const u8,
    replacement_span: @import("../../lexer/token.zig").Span,
    min_precedence: u8,
    depth: usize,
    build_nodes: bool,
) ?Error!NodeIndex {
    const AssignmentTarget = enum { none, identifier, member };
    if (depth >= 64) return null;
    const root_token = scanner.token;
    if (root_token.span.start >= root_token.span.end or root_token.span.end > value.len) return null;
    const raw_name = value[root_token.span.start..root_token.span.end];
    var output: NodeIndex = .none;
    var consumed_initial = false;
    var assignment_target: AssignmentTarget = .none;

    if (root_token.kind == .l_bracket) {
        const parsed_array = parseLexicalDefineArray(
            self,
            scanner,
            value,
            replacement_span,
            depth + 1,
            build_nodes,
        ) orelse return null;
        output = parsed_array catch |err| return err;
        consumed_initial = true;
    } else if (root_token.kind == .l_curly) {
        const parsed_object = parseLexicalDefineObject(
            self,
            scanner,
            value,
            replacement_span,
            depth + 1,
            build_nodes,
        ) orelse return null;
        output = parsed_object catch |err| return err;
        consumed_initial = true;
    } else if (root_token.kind == .kw_function) {
        // A small, explicit function-expression subset is enough to preserve
        // lexical capture for common define callbacks. Keep unsupported
        // parameters/statements on the opaque path rather than guessing.
        scanner.next() catch return Error.OutOfMemory;
        if (scanner.token.kind != .l_paren) return null;
        scanner.next() catch return Error.OutOfMemory;
        if (scanner.token.kind != .r_paren) return null;
        scanner.next() catch return Error.OutOfMemory;
        if (scanner.token.kind != .l_curly) return null;
        scanner.next() catch return Error.OutOfMemory;
        if (scanner.token.kind != .kw_return) return null;
        scanner.next() catch return Error.OutOfMemory;
        const callback_scope: ScopeId = if (build_nodes and self.semantic_edit_enabled)
            self.reserveGeneratedFunctionScope(self.current_scope) catch return Error.OutOfMemory
        else
            .none;
        const saved_scope = self.current_scope;
        const saved_arguments_owner = self.define_native_arguments_owner;
        if (!callback_scope.isNone()) {
            self.current_scope = callback_scope;
            self.define_native_arguments_owner = callback_scope;
        }
        defer self.current_scope = saved_scope;
        defer self.define_native_arguments_owner = saved_arguments_owner;
        const parsed_return = parseLexicalDefineExpression(
            self,
            scanner,
            value,
            replacement_span,
            0,
            depth + 1,
            build_nodes,
        ) orelse return null;
        const return_value = parsed_return catch |err| return err;
        if (scanner.token.kind == .semicolon) scanner.next() catch return Error.OutOfMemory;
        if (scanner.token.kind != .r_curly) return null;
        scanner.next() catch return Error.OutOfMemory;
        if (build_nodes) {
            const params_list = self.ast.addNodeList(&.{}) catch return Error.OutOfMemory;
            const params = self.ast.addFormalParameters(params_list, replacement_span) catch return Error.OutOfMemory;
            const return_statement = self.ast.addUnaryNode(
                .return_statement,
                replacement_span,
                return_value,
                0,
            ) catch return Error.OutOfMemory;
            const body_list = self.ast.addNodeList(&.{return_statement}) catch return Error.OutOfMemory;
            const body = self.ast.addListNode(.block_statement, replacement_span, body_list) catch
                return Error.OutOfMemory;
            const extra = self.ast.addExtras(&.{
                @backingInt(NodeIndex.none),
                @backingInt(params),
                @backingInt(body),
                0,
                @backingInt(NodeIndex.none),
            }) catch return Error.OutOfMemory;
            output = self.ast.addExtraNode(.function_expression, replacement_span, extra) catch
                return Error.OutOfMemory;
            if (!callback_scope.isNone()) self.bindReservedFunctionOwner(callback_scope, output) catch return Error.OutOfMemory;
        }
        consumed_initial = true;
    } else if (root_token.kind == .no_substitution_template or root_token.kind == .template_head) {
        const parsed_template = parseLexicalDefineTemplate(
            self,
            scanner,
            value,
            replacement_span,
            depth + 1,
            build_nodes,
        ) orelse return null;
        output = parsed_template catch |err| return err;
        consumed_initial = true;
    } else if (root_token.kind == .l_paren) {
        scanner.next() catch return Error.OutOfMemory;
        if (scanner.token.kind == .r_paren) {
            scanner.next() catch return Error.OutOfMemory;
            if (scanner.token.kind != .arrow) return null;
            scanner.next() catch return Error.OutOfMemory;
            const callback_scope: ScopeId = if (build_nodes and self.semantic_edit_enabled)
                self.reserveGeneratedFunctionScope(self.current_scope) catch return Error.OutOfMemory
            else
                .none;
            const saved_scope = self.current_scope;
            if (!callback_scope.isNone()) self.current_scope = callback_scope;
            defer self.current_scope = saved_scope;
            const parsed_body = parseLexicalDefineExpression(
                self,
                scanner,
                value,
                replacement_span,
                0,
                depth + 1,
                build_nodes,
            ) orelse return null;
            const body = parsed_body catch |err| return err;
            if (build_nodes) {
                const params_list = self.ast.addNodeList(&.{}) catch return Error.OutOfMemory;
                const params = self.ast.addFormalParameters(params_list, replacement_span) catch return Error.OutOfMemory;
                const extra = self.ast.addExtras(&.{ @backingInt(params), @backingInt(body), 0 }) catch
                    return Error.OutOfMemory;
                output = self.ast.addExtraNode(.arrow_function_expression, replacement_span, extra) catch
                    return Error.OutOfMemory;
                if (!callback_scope.isNone()) self.bindReservedFunctionOwner(callback_scope, output) catch return Error.OutOfMemory;
            }
            assignment_target = .none;
        } else {
            const parsed_inner = parseLexicalDefineExpression(
                self,
                scanner,
                value,
                replacement_span,
                0,
                depth + 1,
                build_nodes,
            ) orelse return null;
            const inner = parsed_inner catch |err| return err;
            if (scanner.token.kind != .r_paren) return null;
            scanner.next() catch return Error.OutOfMemory;
            if (build_nodes) {
                output = self.ast.addUnaryNode(.parenthesized_expression, replacement_span, inner, 0) catch
                    return Error.OutOfMemory;
            }
            assignment_target = .none;
        }
        consumed_initial = true;
    } else if (isDefineUnaryOperator(root_token.kind)) {
        scanner.next() catch return Error.OutOfMemory;
        const parsed_operand = parseLexicalDefineExpression(
            self,
            scanner,
            value,
            replacement_span,
            std.math.maxInt(u8),
            depth + 1,
            build_nodes,
        ) orelse return null;
        const operand = parsed_operand catch |err| return err;
        if (build_nodes) {
            const extra = self.ast.addExtras(&.{ @backingInt(operand), @as(u32, @backingInt(root_token.kind)) }) catch
                return Error.OutOfMemory;
            output = self.ast.addNode(.{
                .tag = .unary_expression,
                .span = replacement_span,
                .data = .{ .extra = extra },
            }) catch return Error.OutOfMemory;
        }
        consumed_initial = true;
    } else if (root_token.kind == .kw_this) {
        if (build_nodes) {
            const span = self.ast.addString(raw_name) catch return Error.OutOfMemory;
            output = self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .none = 0 } }) catch
                return Error.OutOfMemory;
        }
    } else if (root_token.kind == .kw_true or root_token.kind == .kw_false or root_token.kind == .kw_null or
        root_token.kind.isNumericLiteral() or root_token.kind == .string_literal)
    {
        if (build_nodes) {
            const span = self.ast.addString(raw_name) catch return Error.OutOfMemory;
            const tag: Node.Tag = if (root_token.kind.isNumericLiteral())
                (if (root_token.kind.isBigIntLiteral()) .bigint_literal else .numeric_literal)
            else if (root_token.kind == .string_literal)
                .string_literal
            else if (root_token.kind == .kw_null)
                .null_literal
            else
                .boolean_literal;
            output = self.ast.addNode(.{
                .tag = tag,
                .span = span,
                .data = if (tag == .string_literal) .{ .string_ref = span } else .{ .none = 0 },
            }) catch return Error.OutOfMemory;
        }
    } else if (root_token.kind.canBeBindingName() and !root_token.kind.isLiteralKeyword()) {
        assignment_target = .identifier;
        if (build_nodes) {
            const root_name = Scanner.decodeIdentifierEscapesAlloc(self.allocator, raw_name) catch
                return Error.OutOfMemory;
            defer if (root_name.ptr != raw_name.ptr) self.allocator.free(root_name);
            output = makeDefineLexicalRef(self, root_name) catch |err| return err;
        }
    } else return null;

    if (!consumed_initial) scanner.next() catch return Error.OutOfMemory;
    while (true) {
        if (scanner.token.kind == .dot) {
            scanner.next() catch return Error.OutOfMemory;
            const property_token = scanner.token;
            if (!isDefinePropertyName(property_token.kind) or property_token.span.start >= property_token.span.end or
                property_token.span.end > value.len) return null;
            if (build_nodes) {
                const property_span = self.ast.addString(value[property_token.span.start..property_token.span.end]) catch
                    return Error.OutOfMemory;
                const property = es_helpers.makePropertyNameFromSpan(self, property_span) catch return Error.OutOfMemory;
                output = es_helpers.makeStaticMember(self, output, property, replacement_span) catch return Error.OutOfMemory;
            }
            scanner.next() catch return Error.OutOfMemory;
            assignment_target = .member;
            continue;
        }

        if (scanner.token.kind == .l_bracket) {
            scanner.next() catch return Error.OutOfMemory;
            const parsed_property = parseLexicalDefineExpression(
                self,
                scanner,
                value,
                replacement_span,
                0,
                depth + 1,
                build_nodes,
            ) orelse return null;
            const property = parsed_property catch |err| return err;
            if (scanner.token.kind != .r_bracket) return null;
            scanner.next() catch return Error.OutOfMemory;
            if (build_nodes) {
                output = es_helpers.makeComputedMember(self, output, property, replacement_span) catch return Error.OutOfMemory;
            }
            assignment_target = .member;
            continue;
        }

        if (scanner.token.kind == .question_dot) {
            scanner.next() catch return Error.OutOfMemory;
            if (scanner.token.kind == .l_bracket) {
                scanner.next() catch return Error.OutOfMemory;
                const parsed_property = parseLexicalDefineExpression(
                    self,
                    scanner,
                    value,
                    replacement_span,
                    0,
                    depth + 1,
                    build_nodes,
                ) orelse return null;
                const property = parsed_property catch |err| return err;
                if (scanner.token.kind != .r_bracket) return null;
                scanner.next() catch return Error.OutOfMemory;
                if (build_nodes) {
                    output = makeDefineMemberWithFlags(
                        self,
                        .computed_member_expression,
                        output,
                        property,
                        replacement_span,
                        @import("../../parser/ast.zig").MemberFlags.optional_chain,
                    ) catch
                        return Error.OutOfMemory;
                }
                assignment_target = .none;
                continue;
            }
            if (scanner.token.kind == .l_paren) {
                const parsed_call = parseLexicalDefineCall(
                    self,
                    scanner,
                    value,
                    output,
                    replacement_span,
                    depth + 1,
                    build_nodes,
                    true,
                ) orelse return null;
                output = parsed_call catch |err| return err;
                assignment_target = .none;
                continue;
            }
            const property_token = scanner.token;
            if (!isDefinePropertyName(property_token.kind) or property_token.span.start >= property_token.span.end or
                property_token.span.end > value.len) return null;
            if (build_nodes) {
                const property_span = self.ast.addString(value[property_token.span.start..property_token.span.end]) catch
                    return Error.OutOfMemory;
                const property = es_helpers.makePropertyNameFromSpan(self, property_span) catch return Error.OutOfMemory;
                output = makeDefineMemberWithFlags(
                    self,
                    .static_member_expression,
                    output,
                    property,
                    replacement_span,
                    @import("../../parser/ast.zig").MemberFlags.optional_chain,
                ) catch
                    return Error.OutOfMemory;
            }
            assignment_target = .none;
            scanner.next() catch return Error.OutOfMemory;
            continue;
        }

        if (scanner.token.kind == .l_paren) {
            const parsed_call = parseLexicalDefineCall(
                self,
                scanner,
                value,
                output,
                replacement_span,
                depth + 1,
                build_nodes,
                false,
            ) orelse return null;
            output = parsed_call catch |err| return err;
            assignment_target = .none;
            continue;
        }
        break;
    }

    while (true) {
        const op = scanner.token.kind;
        const precedence = type_args.getBinaryPrecedence(op);
        if (precedence == 0 or precedence <= min_precedence) break;

        scanner.next() catch return Error.OutOfMemory;
        const next_precedence = if (op == .star2) precedence - 1 else precedence;
        const parsed_right = parseLexicalDefineExpression(
            self,
            scanner,
            value,
            replacement_span,
            next_precedence,
            depth + 1,
            build_nodes,
        ) orelse return null;
        const right = parsed_right catch |err| return err;
        if (build_nodes) {
            const is_logical = op == .amp2 or op == .pipe2 or op == .question2;
            output = self.ast.addNode(.{
                .tag = if (is_logical) .logical_expression else .binary_expression,
                .span = replacement_span,
                .data = .{ .binary = .{
                    .left = output,
                    .right = right,
                    .flags = @backingInt(op),
                } },
            }) catch return Error.OutOfMemory;
        }
        assignment_target = .none;
    }

    if (min_precedence == 0 and scanner.token.kind == .question) {
        scanner.next() catch return Error.OutOfMemory;
        const parsed_consequent = parseLexicalDefineExpression(
            self,
            scanner,
            value,
            replacement_span,
            0,
            depth + 1,
            build_nodes,
        ) orelse return null;
        const consequent = parsed_consequent catch |err| return err;
        if (scanner.token.kind != .colon) return null;
        scanner.next() catch return Error.OutOfMemory;
        const parsed_alternate = parseLexicalDefineExpression(
            self,
            scanner,
            value,
            replacement_span,
            0,
            depth + 1,
            build_nodes,
        ) orelse return null;
        const alternate = parsed_alternate catch |err| return err;
        if (build_nodes) {
            output = self.ast.addTernaryNode(
                .conditional_expression,
                replacement_span,
                output,
                consequent,
                alternate,
            ) catch return Error.OutOfMemory;
        }
        assignment_target = .none;
    }

    // Assignment is lower precedence than conditional/binary expressions and
    // right associative. A bare identifier target must become a write edge in
    // the same semantic graph; leaving it as opaque text loses the binding
    // edge during bundler reanalysis and can turn a local write into an
    // unresolved global name.
    if (min_precedence == 0 and scanner.token.kind.isAssignment()) {
        if (assignment_target == .none) return null;
        const operator = scanner.token.kind;
        if (assignment_target == .identifier and !self.semantic_edit_enabled) return null;
        scanner.next() catch return Error.OutOfMemory;
        const parsed_right = parseLexicalDefineExpression(
            self,
            scanner,
            value,
            replacement_span,
            0,
            depth + 1,
            build_nodes,
        ) orelse return null;
        const right = parsed_right catch |err| return err;
        if (build_nodes) {
            if (assignment_target == .identifier) {
                if (self.ast.getNode(output).tag != .identifier_reference) return null;
                if (self.getSymbolIdAt(output) != null) {
                    const editor = if (self.semantic_editor) |*semantic_editor|
                        semantic_editor
                    else
                        std.debug.panic("define assignment reference has no semantic editor", .{});
                    const flags: ReferenceFlags = if (operator == .eq)
                        .{ .write = true }
                    else
                        .{ .read = true, .write = true };
                    const updated = if (self.native_arguments_reference_origins.contains(@backingInt(output)))
                        @import("../native_arguments.zig").recordAssignment(self, output, flags)
                    else
                        editor.updateReferenceFlags(output, flags);
                    updated catch |err| {
                        if (err == error.OutOfMemory) return Error.OutOfMemory;
                        std.debug.panic("define assignment reference lost its SymbolId: {s}", .{@errorName(err)});
                    };
                }
                self.ast.setTag(output, .assignment_target_identifier);
            }
            output = self.ast.addBinaryNode(
                .assignment_expression,
                replacement_span,
                output,
                right,
                @backingInt(operator),
            ) catch return Error.OutOfMemory;
        }
        assignment_target = .none;
    }
    return output;
}

fn isDefineUnaryOperator(kind: Kind) bool {
    return kind == .bang or kind == .tilde or kind == .minus or kind == .plus or
        kind == .kw_typeof or kind == .kw_void or kind == .kw_delete;
}

fn parseLexicalDefineCall(
    self: *Transformer,
    scanner: *Scanner,
    value: []const u8,
    callee: NodeIndex,
    replacement_span: @import("../../lexer/token.zig").Span,
    depth: usize,
    build_nodes: bool,
    optional: bool,
) ?Error!NodeIndex {
    scanner.next() catch return Error.OutOfMemory;
    var args: std.ArrayList(NodeIndex) = .empty;
    defer args.deinit(self.allocator);
    if (scanner.token.kind != .r_paren) {
        while (true) {
            const parsed_arg = parseLexicalDefineExpression(
                self,
                scanner,
                value,
                replacement_span,
                0,
                depth + 1,
                build_nodes,
            ) orelse return null;
            const arg = parsed_arg catch |err| return err;
            if (build_nodes) args.append(self.allocator, arg) catch return Error.OutOfMemory;

            if (scanner.token.kind == .r_paren) break;
            if (scanner.token.kind != .comma) return null;
            scanner.next() catch return Error.OutOfMemory;
            if (scanner.token.kind == .r_paren) break;
        }
    }
    if (scanner.token.kind != .r_paren) return null;
    scanner.next() catch return Error.OutOfMemory;
    if (!build_nodes) return NodeIndex.none;
    if (!optional) return es_helpers.makeCallExpr(self, callee, args.items, replacement_span) catch return Error.OutOfMemory;
    const args_list = self.ast.addNodeList(args.items) catch return Error.OutOfMemory;
    const extra = self.ast.addExtras(&.{
        @backingInt(callee),
        args_list.start,
        args_list.len,
        @import("../../parser/ast.zig").CallFlags.optional_chain,
    }) catch return Error.OutOfMemory;
    return self.ast.addNode(.{
        .tag = .call_expression,
        .span = replacement_span,
        .data = .{ .extra = extra },
    }) catch return Error.OutOfMemory;
}

fn makeDefineMemberWithFlags(
    self: *Transformer,
    tag: Node.Tag,
    object: NodeIndex,
    property: NodeIndex,
    span: @import("../../lexer/token.zig").Span,
    flags: u32,
) Error!NodeIndex {
    const extra = self.ast.addExtras(&.{ @backingInt(object), @backingInt(property), flags }) catch
        return Error.OutOfMemory;
    return self.ast.addNode(.{
        .tag = tag,
        .span = span,
        .data = .{ .extra = extra },
    }) catch return Error.OutOfMemory;
}

fn parseLexicalDefineTemplate(
    self: *Transformer,
    scanner: *Scanner,
    value: []const u8,
    replacement_span: @import("../../lexer/token.zig").Span,
    depth: usize,
    build_nodes: bool,
) ?Error!NodeIndex {
    const first_token = scanner.token;
    if (first_token.kind == .no_substitution_template) {
        scanner.next() catch return Error.OutOfMemory;
        if (!build_nodes) return NodeIndex.none;
        const list = self.ast.addNodeList(&.{}) catch return Error.OutOfMemory;
        const template_span = self.ast.addString(value[first_token.span.start..first_token.span.end]) catch
            return Error.OutOfMemory;
        return self.ast.addListNode(.template_literal, template_span, list) catch return Error.OutOfMemory;
    }

    var elements: std.ArrayList(NodeIndex) = .empty;
    defer elements.deinit(self.allocator);
    if (build_nodes) {
        const head_span = self.ast.addString(value[first_token.span.start..first_token.span.end]) catch return Error.OutOfMemory;
        const head = self.ast.addNode(.{ .tag = .template_element, .span = head_span, .data = .{ .none = 0 } }) catch
            return Error.OutOfMemory;
        elements.append(self.allocator, head) catch return Error.OutOfMemory;
    }
    scanner.next() catch return Error.OutOfMemory;
    while (true) {
        const parsed_expression = parseLexicalDefineExpression(
            self,
            scanner,
            value,
            replacement_span,
            0,
            depth + 1,
            build_nodes,
        ) orelse return null;
        const expression = parsed_expression catch |err| return err;
        if (build_nodes) elements.append(self.allocator, expression) catch return Error.OutOfMemory;
        if (scanner.token.kind != .template_middle and scanner.token.kind != .template_tail) return null;
        const tail_kind = scanner.token.kind;
        if (build_nodes) {
            const part_span = self.ast.addString(value[scanner.token.span.start..scanner.token.span.end]) catch
                return Error.OutOfMemory;
            const part = self.ast.addNode(.{ .tag = .template_element, .span = part_span, .data = .{ .none = 0 } }) catch
                return Error.OutOfMemory;
            elements.append(self.allocator, part) catch return Error.OutOfMemory;
        }
        scanner.next() catch return Error.OutOfMemory;
        if (tail_kind == .template_tail) break;
    }
    if (!build_nodes) return NodeIndex.none;
    const list = self.ast.addNodeList(elements.items) catch return Error.OutOfMemory;
    return self.ast.addListNode(.template_literal, replacement_span, list) catch return Error.OutOfMemory;
}

fn parseLexicalDefineArray(
    self: *Transformer,
    scanner: *Scanner,
    value: []const u8,
    replacement_span: @import("../../lexer/token.zig").Span,
    depth: usize,
    build_nodes: bool,
) ?Error!NodeIndex {
    scanner.next() catch return Error.OutOfMemory;
    var elements: std.ArrayList(NodeIndex) = .empty;
    defer elements.deinit(self.allocator);

    while (scanner.token.kind != .r_bracket and scanner.token.kind != .eof) {
        if (scanner.token.kind == .comma) {
            if (build_nodes) {
                const hole = self.ast.addNode(.{
                    .tag = .elision,
                    .span = replacement_span,
                    .data = .{ .none = 0 },
                }) catch return Error.OutOfMemory;
                elements.append(self.allocator, hole) catch return Error.OutOfMemory;
            }
            scanner.next() catch return Error.OutOfMemory;
            continue;
        }

        const spread = scanner.token.kind == .dot3;
        if (spread) scanner.next() catch return Error.OutOfMemory;
        const parsed_element = parseLexicalDefineExpression(
            self,
            scanner,
            value,
            replacement_span,
            0,
            depth + 1,
            build_nodes,
        ) orelse return null;
        const element = parsed_element catch |err| return err;
        if (build_nodes) {
            const output_element = if (spread)
                try self.ast.addUnaryNode(.spread_element, replacement_span, element, 0)
            else
                element;
            elements.append(self.allocator, output_element) catch return Error.OutOfMemory;
        }

        if (scanner.token.kind == .r_bracket) break;
        if (scanner.token.kind != .comma) return null;
        scanner.next() catch return Error.OutOfMemory;
    }
    if (scanner.token.kind != .r_bracket) return null;
    scanner.next() catch return Error.OutOfMemory;
    if (!build_nodes) return NodeIndex.none;
    const list = self.ast.addNodeList(elements.items) catch return Error.OutOfMemory;
    return self.ast.addListNode(.array_expression, replacement_span, list) catch return Error.OutOfMemory;
}

fn parseLexicalDefineObject(
    self: *Transformer,
    scanner: *Scanner,
    value: []const u8,
    replacement_span: @import("../../lexer/token.zig").Span,
    depth: usize,
    build_nodes: bool,
) ?Error!NodeIndex {
    scanner.next() catch return Error.OutOfMemory;
    var properties: std.ArrayList(NodeIndex) = .empty;
    defer properties.deinit(self.allocator);

    while (scanner.token.kind != .r_curly and scanner.token.kind != .eof) {
        if (scanner.token.kind == .dot3) {
            scanner.next() catch return Error.OutOfMemory;
            const parsed_value = parseLexicalDefineExpression(
                self,
                scanner,
                value,
                replacement_span,
                0,
                depth + 1,
                build_nodes,
            ) orelse return null;
            const spread_value = parsed_value catch |err| return err;
            if (build_nodes) {
                const spread = self.ast.addUnaryNode(.spread_element, replacement_span, spread_value, 0) catch
                    return Error.OutOfMemory;
                properties.append(self.allocator, spread) catch return Error.OutOfMemory;
            }
        } else {
            const key_token = scanner.token;
            var key: NodeIndex = .none;
            var key_is_identifier = false;
            if (key_token.kind == .l_bracket) {
                scanner.next() catch return Error.OutOfMemory;
                const parsed_key = parseLexicalDefineExpression(
                    self,
                    scanner,
                    value,
                    replacement_span,
                    0,
                    depth + 1,
                    build_nodes,
                ) orelse return null;
                const key_value = parsed_key catch |err| return err;
                if (scanner.token.kind != .r_bracket) return null;
                scanner.next() catch return Error.OutOfMemory;
                if (build_nodes) key = self.ast.addUnaryNode(.computed_property_key, replacement_span, key_value, 0) catch
                    return Error.OutOfMemory;
            } else if (isDefinePropertyName(key_token.kind)) {
                if (key_token.span.start >= key_token.span.end or key_token.span.end > value.len) return null;
                if (build_nodes) {
                    const key_span = self.ast.addString(value[key_token.span.start..key_token.span.end]) catch
                        return Error.OutOfMemory;
                    key = es_helpers.makePropertyNameFromSpan(self, key_span) catch return Error.OutOfMemory;
                }
                key_is_identifier = key_token.kind.canBeBindingName() and !key_token.kind.isLiteralKeyword();
                scanner.next() catch return Error.OutOfMemory;
            } else if (key_token.kind == .string_literal or key_token.kind.isNumericLiteral()) {
                if (key_token.span.start >= key_token.span.end or key_token.span.end > value.len) return null;
                if (build_nodes) {
                    const key_span = self.ast.addString(value[key_token.span.start..key_token.span.end]) catch
                        return Error.OutOfMemory;
                    const key_tag: Node.Tag = if (key_token.kind.isNumericLiteral())
                        (if (key_token.kind.isBigIntLiteral()) .bigint_literal else .numeric_literal)
                    else
                        .string_literal;
                    key = self.ast.addNode(.{
                        .tag = key_tag,
                        .span = key_span,
                        .data = if (key_tag == .string_literal) .{ .string_ref = key_span } else .{ .none = 0 },
                    }) catch return Error.OutOfMemory;
                }
                scanner.next() catch return Error.OutOfMemory;
            } else return null;

            var property_value: NodeIndex = .none;
            if (scanner.token.kind == .colon) {
                scanner.next() catch return Error.OutOfMemory;
                const parsed_value = parseLexicalDefineExpression(
                    self,
                    scanner,
                    value,
                    replacement_span,
                    0,
                    depth + 1,
                    build_nodes,
                ) orelse return null;
                property_value = parsed_value catch |err| return err;
            } else if (key_is_identifier) {
                if (build_nodes) {
                    const raw_key = value[key_token.span.start..key_token.span.end];
                    const decoded_key = Scanner.decodeIdentifierEscapesAlloc(self.allocator, raw_key) catch
                        return Error.OutOfMemory;
                    defer if (decoded_key.ptr != raw_key.ptr) self.allocator.free(decoded_key);
                    property_value = makeDefineLexicalRef(self, decoded_key) catch |err| return err;
                }
            } else return null;

            if (build_nodes) {
                const property = self.ast.addNode(.{
                    .tag = .object_property,
                    .span = replacement_span,
                    .data = .{ .binary = .{ .left = key, .right = property_value, .flags = 0 } },
                }) catch return Error.OutOfMemory;
                properties.append(self.allocator, property) catch return Error.OutOfMemory;
            }
        }

        if (scanner.token.kind == .r_curly) break;
        if (scanner.token.kind != .comma) return null;
        scanner.next() catch return Error.OutOfMemory;
    }
    if (scanner.token.kind != .r_curly) return null;
    scanner.next() catch return Error.OutOfMemory;
    if (!build_nodes) return NodeIndex.none;
    const list = self.ast.addNodeList(properties.items) catch return Error.OutOfMemory;
    return self.ast.addListNode(.object_expression, replacement_span, list) catch return Error.OutOfMemory;
}

fn isDefinePropertyName(kind: Kind) bool {
    return kind == .identifier or kind.isKeyword() or kind.isStrictModeReserved() or
        kind == .escaped_strict_reserved;
}

/// Unsupported define expressions are emitted as opaque source text, so the
/// semantic graph cannot see their lexical references. Keep the use-site
/// scope chain dynamically named until those expressions are parsed into real
/// AST references. Marking both dynamic lookup modes is deliberately
/// conservative: the opaque value may contain direct eval or `with`.
fn preserveOpaqueDefineNames(self: *Transformer, value: []const u8) Error!void {
    var scanner = Scanner.init(self.allocator, value) catch return Error.OutOfMemory;
    defer scanner.deinit();
    scanner.next() catch return Error.OutOfMemory;
    var has_identifier = false;
    while (scanner.token.kind != .eof) {
        if (scanner.token.kind.canBeBindingName() and !scanner.token.kind.isLiteralKeyword()) {
            has_identifier = true;
            break;
        }
        scanner.next() catch return Error.OutOfMemory;
    }
    if (!has_identifier or !self.semantic_edit_enabled) return;
    const scope = if (self.current_scope.isNone()) self.programScope() else self.current_scope;
    try self.markOpaqueDefineScopeChain(scope);
}

/// Direct eval and `with` require dynamic-scope semantics that the current
/// generated-reference subset cannot represent. Keep the whole define opaque
/// so its conservative scope-name preservation can protect emitted text.
fn containsDynamicDefineLookup(self: *Transformer, value: []const u8) Error!bool {
    if (std.mem.indexOf(u8, value, "eval") == null and std.mem.indexOf(u8, value, "with") == null) return false;
    var scanner = Scanner.init(self.allocator, value) catch return Error.OutOfMemory;
    defer scanner.deinit();
    scanner.next() catch return Error.OutOfMemory;
    while (scanner.token.kind != .eof) {
        if (scanner.token.kind == .kw_with) return true;
        const token = scanner.token;
        if (token.kind.canBeBindingName() and token.span.start < token.span.end and token.span.end <= value.len and
            std.mem.eql(u8, value[token.span.start..token.span.end], "eval"))
        {
            return true;
        }
        scanner.next() catch return Error.OutOfMemory;
    }
    return false;
}

/// 노드가 define 치환 대상이면 새 string_literal 노드를 반환.
/// 대상: identifier_reference / static_member_expression / chain_expression.
///
/// 매칭 규칙(#1552):
///   - optional chaining(`?.`)이 포함된 식은 `.`로 정규화 후 매칭.
///     방어적 접근 패턴(`globalThis.process?.env?.NODE_ENV`)까지 커버.
///   - `globalThis.` / `window.` / `self.` 접두어는 번들 맥락에서 의미 없는
///     global root이므로 벗기고 define key와 비교.
pub fn tryDefineReplace(self: *Transformer, node: Node) ?Error!NodeIndex {
    const value = matchedDefineValue(self.ast, node, self.options.define) orelse return null;
    if (std.mem.eql(u8, value, "true")) return es_helpers.makeBoolLiteral(self, true);
    if (std.mem.eql(u8, value, "false")) return es_helpers.makeBoolLiteral(self, false);
    if (std.mem.eql(u8, value, "null")) return es_helpers.makeNullLiteral(self);
    if (std.mem.eql(u8, value, "undefined")) return es_helpers.makeVoidZero(self, node.span);
    if (!try containsDynamicDefineLookup(self, value)) {
        if (buildLexicalDefinePath(self, value, node.span)) |parsed| return parsed;
    }
    // intern map 이 같은 entry.value 의 두 번째 호출부터 hit → 캐시 효과 흡수.
    const value_span = self.ast.addString(value) catch return Error.OutOfMemory;
    // 문자열 define은 source binding과 분리된 literal node로 만든다.
    if (isStringLiteralDefineValue(value)) return self.ast.addNode(.{
        .tag = .string_literal,
        .span = value_span,
        .data = .{ .string_ref = value_span },
    });
    // Unsupported compound define expressions remain opaque references. Their
    // names are preserved on the reachable lexical chain so text inside the
    // opaque value cannot be invalidated by identifier mangling or transforms
    // that assume no dynamic name lookup. This is a safety fallback; exact
    // SymbolId edges still require parsing the expression into the AST.
    self.has_opaque_define_replacement = true;
    try preserveOpaqueDefineNames(self, value);
    return es_helpers.makeGlobalRefFromSpan(self, value_span);
}
