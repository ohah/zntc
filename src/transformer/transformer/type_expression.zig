//! Type-expression visitor helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const es_helpers = @import("../es_helpers.zig");

/// TS/Flow expression wrappers keep only their runtime operand when type stripping is enabled.
pub fn visitTsExpression(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(idx);
    if (!self.options.strip_types) {
        return self.copyNodeDirect(idx);
    }
    const operand = node.data.unary.operand;
    if (node.tag == .ts_type_assertion and !operand.isNone()) {
        const op_node = self.ast.getNode(operand);
        if (op_node.tag == .parenthesized_expression and !op_node.data.unary.operand.isNone()) {
            // TS prefix-assertion `<T>(x)`: x 가 안전하면 괄호까지 제거(`<T>(obj)`→`obj`).
            // load-bearing 이면(`<T>(a+b)*c` / `<T>(a?.b).c` / sequence) 괄호 유지 — 아래 일반
            // 경로가 parenthesized_expression 노드를 그대로 보존해 의미를 지킨다.
            if (!es_helpers.castOperandNeedsParen(self.ast, op_node.data.unary.operand)) {
                return self.visitNode(op_node.data.unary.operand);
            }
        }
    }
    // Flow colon-cast `(expr: T)` 는 괄호를 노드에 absorb 한 단일 flow_type_cast_expression 이라
    // (TS `as`/`!` 처럼 parenthesized_expression 으로 감싸지 않으므로) node_dispatch 의 paren
    // 핸들러를 거치지 않는다. codegen 은 paren-node 기반이라 우선순위로 괄호를 재유도하지
    // 않으므로, 흡수했던 source 괄호가 load-bearing 이면(precedence/optional-chain/statement-start)
    // paren 노드를 복원해 보존한다. 안전한 primary/postfix 면 종전대로 제거(최소 출력).
    //   - `(a + b: T) * c` → `(a + b) * c` (precedence)
    //   - `(a?.b: T).c`    → `(a?.b).c`    (optional chain break)
    //   - `({x:1}: T).c`   → `({x:1}).c`   (statement-start 모호성)
    //   - `(obj: T)`       → `obj`         (안전 → 제거)
    // operand 이 또 flow_type_cast 면(중첩 `((a?.b: U): T)`) inner 가 제 괄호를 합성하므로 여기선
    // 생략 — 안 그러면 레벨마다 괄호가 쌓여 `((a?.b)).c` 가 된다.
    if (node.tag == .flow_type_cast_expression and
        self.ast.getNode(operand).tag != .flow_type_cast_expression and
        es_helpers.castOperandNeedsParen(self.ast, operand))
    {
        const paren = try self.ast.addNode(.{
            .tag = .parenthesized_expression,
            .span = node.span,
            .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
        });
        return self.visitNode(paren);
    }
    return self.visitNode(operand);
}
