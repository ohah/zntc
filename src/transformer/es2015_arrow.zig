//! ES2015 다운레벨링: arrow function
//!
//! --target < es2015 일 때 활성화.
//! () => expr       → function() { return expr; }
//! () => { stmts }  → function() { stmts }
//! (x) => x + 1     → function(x) { return x + 1; }
//! x => x + 1       → function(x) { return x + 1; }
//!
//! 파서에서 arrow의 params 슬롯은 세 가지 형태:
//!   1. NodeIndex.none → 빈 파라미터 (() => ...)
//!   2. binding_identifier → 단일 파라미터 (x => ...)
//!   3. formal_parameters(list) → 괄호 형태 ((x, y) => ...)
//!
//! this/arguments 캡처:
//!   arrow body 안의 this → _this, arguments → _arguments로 치환.
//!   외부 함수(visitFunction)에서 var _this = this; / var _arguments = arguments; 삽입.
//!   중첩 arrow는 같은 _this를 공유, 내부 일반 함수는 별도 스코프.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-arrow-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/arrow.rs (~253줄)
//! - ZTS ES2017: es2017.zig lowerAsyncArrow

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const FunctionInfo = @import("ast_plugin.zig").FunctionInfo;

pub fn ES2015Arrow(comptime Transformer: type) type {
    return struct {
        /// arrow_function_expression → function_expression 변환.
        /// arrow body 안의 this → _this, arguments → _arguments 치환을 위해
        /// arrow_this_depth를 증가시킨 상태로 body를 방문한다.
        pub fn lowerArrowFunction(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;

            const params_idx: NodeIndex = self.readNodeIdx(e, 0);
            const body_idx: NodeIndex = self.readNodeIdx(e, 1);
            const flags = self.readU32(e, 2);

            const param_list = try arrowParamsToList(self, params_idx);

            // arrow body 안의 this/arguments를 캡처하기 위해 depth 증가.
            // visitNode에서 this → _this, arguments → _arguments로 치환된다.
            self.arrow_this_depth += 1;
            var new_body = try self.visitNode(body_idx);
            self.arrow_this_depth -= 1;

            // expression body → { return expr; }
            const func_body = blk: {
                if (new_body.isNone()) break :blk new_body;
                const body_node = self.ast.getNode(new_body);
                if (body_node.tag != .block_statement and body_node.tag != .function_body) {
                    const ret = try self.ast.addNode(.{
                        .tag = .return_statement,
                        .span = node.span,
                        .data = .{ .unary = .{ .operand = new_body, .flags = 0 } },
                    });
                    const list = try self.ast.addNodeList(&.{ret});
                    break :blk try self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = node.span,
                        .data = .{ .list = list },
                    });
                }
                break :blk new_body;
            };

            // function_expression: extra = [name, params_start, params_len, body, flags, return_type]
            const func_flags: u32 = if (flags & ast_mod.ArrowFlags.is_async != 0)
                ast_mod.FunctionFlags.is_async
            else
                0;

            const none = @intFromEnum(NodeIndex.none);
            const new_extra = try self.ast.addExtras(&.{
                none, // name (anonymous)
                param_list.start,
                param_list.len,
                @intFromEnum(func_body),
                func_flags,
                none, // return_type
            });

            const result = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = node.span,
                .data = .{ .extra = new_extra },
            });

            // Plugin dispatch: worklet 등 AST 플러그인 적용
            if (try self.dispatchFunctionPlugins(result, .{
                .node_idx = result,
                .node_tag = .function_expression,
                .name = null,
                .body_idx = func_body,
                .params_start = param_list.start,
                .params_len = param_list.len,
                // post-visit body 사용: ES5 변환(spread → __toConsumableArray 등)이
                // 주입한 헬퍼를 closure 분석에서 캡처하기 위함.
                // __initData.code도 post-visit body로 생성되므로 일관성 유지.
                .original_params_start = param_list.start,
                .original_params_len = param_list.len,
                .original_body_idx = func_body,
                .flags = func_flags,
                .source_path = self.options.jsx_filename,
            })) |replacement| {
                return replacement;
            }

            return result;
        }

        /// arrow params (단일 NodeIndex) → function params (NodeList) 변환.
        /// lowerAsyncArrowToStateMachine 등에서 arrow를 function으로 변환할 때 사용.
        /// visitNode로 자식을 방문한다.
        pub fn arrowParamsToList(self: *Transformer, params_idx: NodeIndex) Transformer.Error!NodeList {
            if (params_idx.isNone()) return self.ast.addNodeList(&.{});
            const params_node = self.ast.getNode(params_idx);
            return switch (params_node.tag) {
                .formal_parameters => self.visitExtraList(params_node.data.list.start, params_node.data.list.len),
                .parenthesized_expression => blk: {
                    const inner_idx = params_node.data.unary.operand;
                    if (inner_idx.isNone()) break :blk try self.ast.addNodeList(&.{});
                    const inner = self.ast.getNode(inner_idx);
                    if (inner.tag == .sequence_expression) {
                        break :blk try self.visitExtraList(inner.data.list.start, inner.data.list.len);
                    }
                    const new_param = try self.visitNode(inner_idx);
                    break :blk try self.ast.addNodeList(if (!new_param.isNone()) &.{new_param} else &.{});
                },
                else => blk: {
                    const new_param = try self.visitNode(params_idx);
                    break :blk try self.ast.addNodeList(if (!new_param.isNone()) &.{new_param} else &.{});
                },
            };
        }
    };
}

test "ES2015 arrow module compiles" {
    _ = ES2015Arrow;
}
