//! ES2019 다운레벨링: optional catch binding
//!
//! --target < es2019 일 때 활성화.
//! try { } catch { } → try { } catch (_unused) { }
//!
//! 스펙:
//! - optional catch binding: https://tc39.es/ecma262/#sec-try-statement (ES2019, TC39 Stage 4: 2018-05)
//!                            https://github.com/tc39/proposal-optional-catch-binding
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go
//! - oxc: crates/oxc_transformer/src/es2019/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2019(comptime Transformer: type) type {
    return struct {
        /// `catch { }` → `catch (_unused) { }`
        pub fn lowerOptionalCatchBinding(self: *Transformer, owner: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            // catch_clause: binary = { left=param, right=body }
            const param = node.data.binary.left;
            const body = node.data.binary.right;

            // 이미 binding이 있으면 통상 방문
            if (!param.isNone()) {
                const new_param = try self.visitNode(param);
                const new_body = try self.visitNode(body);
                return self.ast.addNode(.{
                    .tag = .catch_clause,
                    .span = node.span,
                    .data = .{ .binary = .{ .left = new_param, .right = new_body, .flags = 0 } },
                });
            }

            // binding 없음 → 유일한 임시 이름 합성. 고정 문자열(`_unused`)을 쓰면
            // catch body 가 같은 이름의 외부 변수를 참조할 때 섀도잉되어 잡힌 에러
            // 객체를 읽는 silent miscompile 이 된다.
            //
            // body 를 먼저 방문해 body 내부 lowering 이 temp 카운터를 소비하게 한 뒤,
            // 카운터 *너머* 의 이름을 고른다. catch 파라미터는 그 자체로 선언이라
            // hoist 가 불필요하므로 카운터를 bump 하지 않는다(= `var _a;` 누수 없음).
            // 일반 단일 파일 출력은 `_unused`를 내부 이름으로 두고, 완성된
            // SymbolId 집합을 보는 마지막 이름 단계에서 실제 이름을 배정한다.
            const new_body = try self.visitNode(body);
            const catch_scope = self.outputOwnedScope(owner) orelse self.current_scope;
            const late_output_name = canUseLateCatchName(self, catch_scope);
            const unused_span = if (late_output_name)
                try self.ast.addString("_unused")
            else blk: {
                var probe = self.temp_var_counter;
                var name_buf: [16]u8 = undefined;
                break :blk while (true) : (probe += 1) {
                    const name = es_helpers.tempVarName(probe, &name_buf);
                    if (es_helpers.collidesWithPrivateField(self, name)) continue;
                    if (try es_helpers.collidesWithUserSymbol(self, name)) continue;
                    if (try es_helpers.nameAppearsInDynamicEvalString(self, catch_scope, name)) continue;
                    break try self.ast.addString(name);
                };
            };
            const unused_binding = try es_helpers.makeSyntheticBinding(self, unused_span);
            try self.declareSyntheticCatch(unused_binding, node.span, late_output_name);
            return self.ast.addNode(.{
                .tag = .catch_clause,
                .span = node.span,
                .data = .{ .binary = .{ .left = unused_binding, .right = new_body, .flags = 0 } },
            });
        }

        fn canUseLateCatchName(self: *Transformer, catch_scope: @import("../semantic/scope.zig").ScopeId) bool {
            if (!self.semantic_edit_enabled or !self.options.defer_runtime_helper_name_resolution or
                self.options.emit_runtime_helper_imports or catch_scope.isNone()) return false;
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            var scope = catch_scope;
            var hops: usize = 0;
            while (!scope.isNone() and hops < scopes.len) : (hops += 1) {
                const raw = scope.toIndex();
                if (raw >= scopes.len or scopes[raw].blocksMangling()) return false;
                scope = scopes[raw].parent;
            }
            return scope.isNone();
        }
    };
}
