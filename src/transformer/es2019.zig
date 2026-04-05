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

pub fn ES2019(comptime Transformer: type) type {
    return struct {
        /// `catch { }` → `catch (_unused) { }`
        pub fn lowerOptionalCatchBinding(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
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

            // binding 없음 → _unused 합성
            const unused_span = try self.ast.addString("_unused");
            const unused_binding = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = unused_span,
                .data = .{ .string_ref = unused_span },
            });
            const new_body = try self.visitNode(body);
            return self.ast.addNode(.{
                .tag = .catch_clause,
                .span = node.span,
                .data = .{ .binary = .{ .left = unused_binding, .right = new_body, .flags = 0 } },
            });
        }
    };
}
