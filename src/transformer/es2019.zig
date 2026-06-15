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

            // binding 없음 → 유일한 임시 이름 합성. 고정 문자열(`_unused`)을 쓰면
            // catch body 가 같은 이름의 외부 변수를 참조할 때 섀도잉되어 잡힌 에러
            // 객체를 읽는 silent miscompile 이 된다.
            //
            // body 를 먼저 방문해 body 내부 lowering 이 temp 카운터를 소비하게 한 뒤,
            // 카운터 *너머* 의 이름을 고른다. catch 파라미터는 그 자체로 선언이라
            // hoist 가 불필요하므로 카운터를 bump 하지 않는다(= `var _a;` 누수 없음).
            // 고른 이름은 body temp(카운터 미만)·사용자 심볼·private field 어느 것과도
            // 겹치지 않으므로 어떤 외부 참조도 섀도잉하지 않는다.
            const new_body = try self.visitNode(body);
            var probe = self.temp_var_counter;
            var name_buf: [16]u8 = undefined;
            const unused_span = while (true) : (probe += 1) {
                const name = es_helpers.tempVarName(probe, &name_buf);
                if (es_helpers.collidesWithPrivateField(self, name)) continue;
                if (try es_helpers.collidesWithUserSymbol(self, name)) continue;
                break try self.ast.addString(name);
            };
            const unused_binding = try es_helpers.makeBindingIdentifier(self, unused_span);
            return self.ast.addNode(.{
                .tag = .catch_clause,
                .span = node.span,
                .data = .{ .binary = .{ .left = unused_binding, .right = new_body, .flags = 0 } },
            });
        }
    };
}
