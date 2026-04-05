//! JSX Lowering — JSX AST 노드를 일반 call_expression으로 변환
//!
//! jsx_element → call_expression(_jsx/_jsxs/React.createElement)
//! jsx_fragment → call_expression(_jsx/_jsxs/React.createElement + Fragment)
//!
//! 3가지 모드:
//! - classic: React.createElement(tag, props, ...children)
//! - automatic: _jsx(tag, {props, children}) / _jsxs(tag, {props, children: [...]})
//! - automatic_dev: _jsxDEV(tag, {props, children}, key, isStatic, source, this)
//!
//! Transformer 패턴 (ES lowering 모듈과 동일): pub fn JsxLowering(comptime Transformer: type) type
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser.go (visitExprInParens → JSX lowering)
//! - oxc: crates/oxc_transformer/src/jsx/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const CallFlags = ast_mod.CallFlags;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const helpers = @import("es_helpers.zig");

/// JSX 런타임 모드 (codegen의 JsxRuntime을 그대로 사용)
pub const JsxRuntime = @import("../codegen/codegen.zig").JsxRuntime;

/// JSX 변환에서 사용된 import 추적.
/// transformer가 채우고, transpile.zig에서 import문 생성에 사용.
pub const JsxImportInfo = struct {
    used_jsx: bool = false,
    used_jsxs: bool = false,
    used_jsxDEV: bool = false,
    used_fragment: bool = false,
    used_createElement: bool = false,

    pub fn hasImports(self: JsxImportInfo) bool {
        return self.used_jsx or self.used_jsxs or self.used_jsxDEV or
            self.used_fragment or self.used_createElement;
    }

    /// "import { jsx as _jsx, ... } from "react/jsx-runtime";\n" 문자열 생성.
    /// 사용된 헬퍼가 없으면 null 반환.
    pub fn buildImportString(self: JsxImportInfo, allocator: std.mem.Allocator, source: []const u8, is_dev: bool) ?[]const u8 {
        if (!self.hasImports()) return null;

        var buf: std.ArrayList(u8) = .empty;

        // jsx-runtime (또는 jsx-dev-runtime) import
        if (self.used_jsx or self.used_jsxs or self.used_jsxDEV or self.used_fragment) {
            buf.appendSlice(allocator, "import { ") catch return null;
            var first = true;
            if (is_dev) {
                if (self.used_jsxDEV) {
                    buf.appendSlice(allocator, "jsxDEV as _jsxDEV") catch return null;
                    first = false;
                }
            } else {
                if (self.used_jsx) {
                    buf.appendSlice(allocator, "jsx as _jsx") catch return null;
                    first = false;
                }
                if (self.used_jsxs) {
                    if (!first) buf.appendSlice(allocator, ", ") catch return null;
                    buf.appendSlice(allocator, "jsxs as _jsxs") catch return null;
                    first = false;
                }
            }
            if (self.used_fragment) {
                if (!first) buf.appendSlice(allocator, ", ") catch return null;
                buf.appendSlice(allocator, "Fragment as _Fragment") catch return null;
            }
            buf.appendSlice(allocator, " } from \"") catch return null;
            buf.appendSlice(allocator, source) catch return null;
            if (is_dev) {
                buf.appendSlice(allocator, "/jsx-dev-runtime\";\n") catch return null;
            } else {
                buf.appendSlice(allocator, "/jsx-runtime\";\n") catch return null;
            }
        }

        // createElement import (key-after-spread 폴백용)
        if (self.used_createElement) {
            buf.appendSlice(allocator, "import { createElement as _createElement } from \"") catch return null;
            buf.appendSlice(allocator, source) catch return null;
            buf.appendSlice(allocator, "\";\n") catch return null;
        }

        return buf.items;
    }
};

/// Transformer 타입 (순환 import 방지를 위해 generic)
pub fn JsxLowering(comptime Transformer: type) type {
    return struct {

        // ================================================================
        // 공개 API
        // ================================================================

        /// jsx_element → call_expression 변환
        pub fn lowerJSXElement(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const tag_name_idx = self.readNodeIdx(e, 0);
            const attrs_start = self.readU32(e, 1);
            const attrs_len = self.readU32(e, 2);
            const children_start = self.readU32(e, 3);
            const children_len = self.readU32(e, 4);

            return switch (self.options.jsx_runtime) {
                .classic => lowerElementClassic(self, node.span, tag_name_idx, attrs_start, attrs_len, children_start, children_len),
                .automatic => lowerElementAutomatic(self, node.span, tag_name_idx, attrs_start, attrs_len, children_start, children_len, false),
                .automatic_dev => lowerElementAutomatic(self, node.span, tag_name_idx, attrs_start, attrs_len, children_start, children_len, true),
            };
        }

        /// jsx_fragment → call_expression 변환
        pub fn lowerJSXFragment(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const list = node.data.list;
            return switch (self.options.jsx_runtime) {
                .classic => lowerFragmentClassic(self, node.span, list.start, list.len),
                .automatic => lowerFragmentAutomatic(self, node.span, list.start, list.len, false),
                .automatic_dev => lowerFragmentAutomatic(self, node.span, list.start, list.len, true),
            };
        }

        /// jsx_text → string_literal 변환. 공백만인 텍스트는 .none 반환.
        pub fn lowerJSXText(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const source = self.ast.source;
            const raw = source[node.span.start..node.span.end];

            // 공백 트리밍 (esbuild 호환)
            const trimmed = std.mem.trim(u8, raw, " \t\n\r");
            if (trimmed.len == 0) return .none;

            // 줄바꿈이 없으면 원본 텍스트 사용 (entity 디코딩만 수행)
            const has_newline = std.mem.indexOfAny(u8, raw, "\n\r") != null;
            const effective_text = if (!has_newline) raw else trimmed;

            // JSX 텍스트를 정규화하여 string_literal로 변환
            const processed = try processJSXText(self, effective_text);
            if (processed.len == 0) return .none;

            // 따옴표로 감싸기 (codegen의 writeStringLiteral이 "..." 형태를 기대)
            // 내부의 " 와 \ 를 이스케이프
            const quoted = try quoteString(self, processed);
            const str_span = try self.ast.addString(quoted);
            return self.ast.addNode(.{
                .tag = .string_literal,
                .span = str_span,
                .data = .{ .string_ref = str_span },
            });
        }

        /// jsx_expression_container → inner expression만 반환
        pub fn lowerJSXExpressionContainer(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            if (node.data.unary.operand.isNone()) return .none;
            return self.visitNode(node.data.unary.operand);
        }

        // ================================================================
        // Classic 모드
        // ================================================================

        /// Classic: React.createElement(tag, props, ...children)
        fn lowerElementClassic(
            self: *Transformer,
            span: Span,
            tag_name_idx: NodeIndex,
            attrs_start: u32,
            attrs_len: u32,
            children_start: u32,
            children_len: u32,
        ) Transformer.Error!NodeIndex {
            // callee: React.createElement (또는 커스텀 factory)
            const callee = try makeFactoryCallee(self, self.options.jsx_factory);

            // 1st arg: tag name
            const tag_arg = try lowerTagName(self, tag_name_idx);

            // 2nd arg: props object or null
            const props_arg = try buildClassicProps(self, attrs_start, attrs_len, span);

            // remaining args: children
            const children = try collectChildren(self, children_start, children_len);

            // call_expression 생성
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try self.scratch.append(self.allocator, callee);
            try self.scratch.append(self.allocator, tag_arg);
            try self.scratch.append(self.allocator, props_arg);
            for (children) |child| {
                try self.scratch.append(self.allocator, child);
            }

            const all_args = self.scratch.items[scratch_top..];
            return makeCallExpr(self, all_args[0], all_args[1..], span, true);
        }

        /// Classic fragment: React.createElement(React.Fragment, null, ...children)
        fn lowerFragmentClassic(
            self: *Transformer,
            span: Span,
            children_start: u32,
            children_len: u32,
        ) Transformer.Error!NodeIndex {
            const callee = try makeFactoryCallee(self, self.options.jsx_factory);
            const fragment_ref = try makeFactoryCallee(self, self.options.jsx_fragment);
            const null_node = try makeNullLiteral(self, span);
            const children = try collectChildren(self, children_start, children_len);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try self.scratch.append(self.allocator, callee);
            try self.scratch.append(self.allocator, fragment_ref);
            try self.scratch.append(self.allocator, null_node);
            for (children) |child| {
                try self.scratch.append(self.allocator, child);
            }

            const all_args = self.scratch.items[scratch_top..];
            return makeCallExpr(self, all_args[0], all_args[1..], span, true);
        }

        // ================================================================
        // Automatic 모드
        // ================================================================

        /// Automatic/Dev: _jsx(tag, props) / _jsxs(tag, props) / _jsxDEV(tag, props, key, isStatic, source, this)
        fn lowerElementAutomatic(
            self: *Transformer,
            span: Span,
            tag_name_idx: NodeIndex,
            attrs_start: u32,
            attrs_len: u32,
            children_start: u32,
            children_len: u32,
            is_dev: bool,
        ) Transformer.Error!NodeIndex {
            // key가 spread 뒤에 오면 createElement 폴백
            const key_result = findKeyAttr(self, attrs_start, attrs_len);
            if (key_result.key_after_spread) {
                return lowerElementCreateElementFallback(self, span, tag_name_idx, attrs_start, attrs_len, children_start, children_len);
            }

            const effective_children = countEffective(self, children_start, children_len);
            const is_static = effective_children > 1;

            // callee 선택
            const callee = if (is_dev) blk: {
                self.jsx_import_info.used_jsxDEV = true;
                break :blk try helpers.makeIdentifierRef(self, "_jsxDEV");
            } else if (is_static) blk: {
                self.jsx_import_info.used_jsxs = true;
                break :blk try helpers.makeIdentifierRef(self, "_jsxs");
            } else blk: {
                self.jsx_import_info.used_jsx = true;
                break :blk try helpers.makeIdentifierRef(self, "_jsx");
            };

            // 1st arg: tag name
            const tag_arg = try lowerTagName(self, tag_name_idx);

            // 2nd arg: props object { ...attrs(key제외), children }
            const props_arg = try buildAutomaticProps(self, attrs_start, attrs_len, children_start, children_len, key_result.key_idx, effective_children, span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try self.scratch.append(self.allocator, callee);
            try self.scratch.append(self.allocator, tag_arg);
            try self.scratch.append(self.allocator, props_arg);

            if (is_dev) {
                // key arg
                if (key_result.key_idx) |ki| {
                    const key_val = try getKeyValue(self, attrs_start, ki);
                    try self.scratch.append(self.allocator, key_val);
                } else {
                    try self.scratch.append(self.allocator, try helpers.makeIdentifierRef(self, "undefined"));
                }
                // isStaticChildren
                const bool_text = if (is_static) "true" else "false";
                const bool_span = try self.ast.addString(bool_text);
                const bool_node = try self.ast.addNode(.{
                    .tag = .boolean_literal,
                    .span = bool_span,
                    .data = .{ .none = 0 },
                });
                try self.scratch.append(self.allocator, bool_node);

                // source info: { fileName, lineNumber, columnNumber }
                const source_obj = try buildDevSourceInfo(self, span);
                try self.scratch.append(self.allocator, source_obj);

                // this
                const this_span = try self.ast.addString("this");
                const this_node = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = this_span,
                    .data = .{ .none = 0 },
                });
                try self.scratch.append(self.allocator, this_node);
            } else if (key_result.key_idx) |ki| {
                // key arg (non-dev)
                const key_val = try getKeyValue(self, attrs_start, ki);
                try self.scratch.append(self.allocator, key_val);
            }

            const all_args = self.scratch.items[scratch_top..];
            return makeCallExpr(self, all_args[0], all_args[1..], span, true);
        }

        /// Automatic fragment: _jsx/_jsxs(_Fragment, {children: ...})
        fn lowerFragmentAutomatic(
            self: *Transformer,
            span: Span,
            children_start: u32,
            children_len: u32,
            is_dev: bool,
        ) Transformer.Error!NodeIndex {
            self.jsx_import_info.used_fragment = true;
            const effective_children = countEffective(self, children_start, children_len);
            const is_static = effective_children > 1;

            const callee = if (is_dev) blk: {
                self.jsx_import_info.used_jsxDEV = true;
                break :blk try helpers.makeIdentifierRef(self, "_jsxDEV");
            } else if (is_static) blk: {
                self.jsx_import_info.used_jsxs = true;
                break :blk try helpers.makeIdentifierRef(self, "_jsxs");
            } else blk: {
                self.jsx_import_info.used_jsx = true;
                break :blk try helpers.makeIdentifierRef(self, "_jsx");
            };

            const fragment_ref = try helpers.makeIdentifierRef(self, "_Fragment");

            // props: {children: ...} or {}
            const props_arg = try buildAutomaticProps(self, 0, 0, children_start, children_len, null, effective_children, span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try self.scratch.append(self.allocator, callee);
            try self.scratch.append(self.allocator, fragment_ref);
            try self.scratch.append(self.allocator, props_arg);

            if (is_dev) {
                // undefined key
                try self.scratch.append(self.allocator, try helpers.makeIdentifierRef(self, "undefined"));
                // isStaticChildren
                const bool_text = if (is_static) "true" else "false";
                const bool_span = try self.ast.addString(bool_text);
                const bool_node = try self.ast.addNode(.{
                    .tag = .boolean_literal,
                    .span = bool_span,
                    .data = .{ .none = 0 },
                });
                try self.scratch.append(self.allocator, bool_node);
                // source info
                try self.scratch.append(self.allocator, try buildDevSourceInfo(self, span));
                // this
                const this_span = try self.ast.addString("this");
                const this_node = try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = this_span,
                    .data = .{ .none = 0 },
                });
                try self.scratch.append(self.allocator, this_node);
            }

            const all_args = self.scratch.items[scratch_top..];
            return makeCallExpr(self, all_args[0], all_args[1..], span, true);
        }

        /// key-after-spread 폴백: _createElement(tag, {...props, key: value}, ...children)
        fn lowerElementCreateElementFallback(
            self: *Transformer,
            span: Span,
            tag_name_idx: NodeIndex,
            attrs_start: u32,
            attrs_len: u32,
            children_start: u32,
            children_len: u32,
        ) Transformer.Error!NodeIndex {
            self.jsx_import_info.used_createElement = true;
            const callee = try helpers.makeIdentifierRef(self, "_createElement");
            const tag_arg = try lowerTagName(self, tag_name_idx);

            // classic-style props (key 포함)
            const props_arg = try buildClassicProps(self, attrs_start, attrs_len, span);

            const children = try collectChildren(self, children_start, children_len);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try self.scratch.append(self.allocator, callee);
            try self.scratch.append(self.allocator, tag_arg);
            try self.scratch.append(self.allocator, props_arg);
            for (children) |child| {
                try self.scratch.append(self.allocator, child);
            }

            const all_args = self.scratch.items[scratch_top..];
            return makeCallExpr(self, all_args[0], all_args[1..], span, true);
        }

        // ================================================================
        // Tag name 처리
        // ================================================================

        /// JSX tag name을 적절한 AST 노드로 변환:
        /// - 소문자 시작 → string_literal ("div")
        /// - 대문자 시작 → identifier_reference (MyComp) — visitNode로 재귀
        /// - member expression → 그대로 visitNode
        fn lowerTagName(self: *Transformer, tag_name_idx: NodeIndex) Transformer.Error!NodeIndex {
            const tag_node = self.ast.getNode(tag_name_idx);

            switch (tag_node.tag) {
                .jsx_identifier => {
                    const text = self.ast.source[tag_node.span.start..tag_node.span.end];
                    if (text.len > 0 and text[0] >= 'a' and text[0] <= 'z') {
                        // 소문자 → string_literal (따옴표 포함: codegen의 writeStringLiteral이 기대)
                        const quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{text});
                        const str_span = try self.ast.addString(quoted);
                        return self.ast.addNode(.{
                            .tag = .string_literal,
                            .span = str_span,
                            .data = .{ .string_ref = str_span },
                        });
                    } else {
                        // 대문자 → identifier_reference (symbol_id 전파로 번들러 rename 반영)
                        const id_span = try self.ast.addString(text);
                        const new_idx = try self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = tag_node.span,
                            .data = .{ .string_ref = id_span },
                        });
                        self.propagateSymbolId(tag_name_idx, new_idx);
                        return new_idx;
                    }
                },
                .jsx_member_expression => {
                    // Foo.Bar → static_member_expression (재귀적으로 처리)
                    return lowerJSXMemberExpr(self, tag_node);
                },
                .jsx_namespaced_name => {
                    // <xml:lang> → string_literal "xml:lang"
                    const text = self.ast.source[tag_node.span.start..tag_node.span.end];
                    const quoted = try quoteString(self, text);
                    const str_span = try self.ast.addString(quoted);
                    return self.ast.addNode(.{
                        .tag = .string_literal,
                        .span = str_span,
                        .data = .{ .string_ref = str_span },
                    });
                },
                else => {
                    return self.visitNode(tag_name_idx);
                },
            }
        }

        /// jsx_member_expression → static_member_expression 변환 (재귀)
        fn lowerJSXMemberExpr(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const left_idx = node.data.binary.left;
            const right_idx = node.data.binary.right;

            // left: jsx_identifier or jsx_member_expression
            const left_node = self.ast.getNode(left_idx);
            const new_left = if (left_node.tag == .jsx_member_expression)
                try lowerJSXMemberExpr(self, left_node)
            else blk: {
                // jsx_identifier → identifier_reference (symbol_id 전파로 번들러 rename 반영)
                const text = self.ast.source[left_node.span.start..left_node.span.end];
                const id_span = try self.ast.addString(text);
                const new_idx = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = left_node.span,
                    .data = .{ .string_ref = id_span },
                });
                self.propagateSymbolId(left_idx, new_idx);
                break :blk new_idx;
            };

            // right: always jsx_identifier → identifier_reference
            // data.string_ref는 원본 소스 span을 사용해야 함.
            // codegen의 emitStaticMember가 source[span.start..end]로 프로퍼티 이름을 읽기 때문.
            const right_node = self.ast.getNode(right_idx);
            const new_right = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = right_node.span,
                .data = .{ .string_ref = right_node.span },
            });

            return helpers.makeStaticMember(self, new_left, new_right, node.span);
        }

        // ================================================================
        // Props 빌드
        // ================================================================

        /// Classic 모드: attrs → {key: val, ...} or null
        fn buildClassicProps(self: *Transformer, attrs_start: u32, attrs_len: u32, span: Span) Transformer.Error!NodeIndex {
            if (attrs_len == 0) return makeNullLiteral(self, span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // while 인덱스 루프: lowerAttribute→visitNode가 extra_data를 재할당할 수 있으므로 슬라이스 캐시 금지
            var j: u32 = 0;
            while (j < attrs_len) : (j += 1) {
                const raw_idx = self.ast.extra_data.items[attrs_start + j];
                const attr = self.ast.getNode(@enumFromInt(raw_idx));
                const prop = try lowerAttribute(self, attr, span);
                if (!prop.isNone()) {
                    try self.scratch.append(self.allocator, prop);
                }
            }

            const props = self.scratch.items[scratch_top..];
            if (props.len == 0) return makeNullLiteral(self, span);

            // object_expression 생성
            return makeObjectExpr(self, props, span);
        }

        /// Automatic 모드: { ...attrs(key제외), children: ... } or {}
        fn buildAutomaticProps(
            self: *Transformer,
            attrs_start: u32,
            attrs_len: u32,
            children_start: u32,
            children_len: u32,
            key_idx: ?u32,
            effective_children: u32,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const has_attrs = attrs_len > (if (key_idx != null) @as(u32, 1) else @as(u32, 0));

            if (!has_attrs and effective_children == 0) {
                // 빈 객체 {}
                const empty_list = NodeList{ .start = 0, .len = 0 };
                return self.ast.addNode(.{
                    .tag = .object_expression,
                    .span = span,
                    .data = .{ .list = empty_list },
                });
            }

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // attrs (key 제외)
            // while 인덱스 루프: lowerAttribute→visitNode가 extra_data를 재할당할 수 있으므로 슬라이스 캐시 금지
            if (attrs_len > 0) {
                var j: u32 = 0;
                while (j < attrs_len) : (j += 1) {
                    if (key_idx != null and j == key_idx.?) continue;
                    const raw_idx = self.ast.extra_data.items[attrs_start + j];
                    const attr = self.ast.getNode(@enumFromInt(raw_idx));
                    const prop = try lowerAttribute(self, attr, span);
                    if (!prop.isNone()) {
                        try self.scratch.append(self.allocator, prop);
                    }
                }
            }

            // children
            if (effective_children > 0) {
                const children_prop = try buildChildrenProp(self, children_start, children_len, effective_children, span);
                if (!children_prop.isNone()) {
                    try self.scratch.append(self.allocator, children_prop);
                }
            }

            const props = self.scratch.items[scratch_top..];
            return makeObjectExpr(self, props, span);
        }

        /// children property 노드 생성: children: value or children: [arr]
        fn buildChildrenProp(
            self: *Transformer,
            children_start: u32,
            children_len: u32,
            effective_children: u32,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const key_span = try self.ast.addString("children");
            const key_node = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = key_span,
                .data = .{ .string_ref = key_span },
            });

            if (effective_children > 1) {
                // 배열로 감싸기
                const children = try collectChildren(self, children_start, children_len);
                const list = try self.ast.addNodeList(children);
                const arr_node = try self.ast.addNode(.{
                    .tag = .array_expression,
                    .span = span,
                    .data = .{ .list = list },
                });
                return self.ast.addNode(.{
                    .tag = .object_property,
                    .span = span,
                    .data = .{ .binary = .{ .left = key_node, .right = arr_node, .flags = 0 } },
                });
            } else {
                // 단일 child
                const child = try collectSingleChild(self, children_start, children_len);
                if (child.isNone()) return .none;
                return self.ast.addNode(.{
                    .tag = .object_property,
                    .span = span,
                    .data = .{ .binary = .{ .left = key_node, .right = child, .flags = 0 } },
                });
            }
        }

        // ================================================================
        // Attribute 처리
        // ================================================================

        /// JSX attribute → object_property or spread_element
        fn lowerAttribute(self: *Transformer, attr: Node, span: Span) Transformer.Error!NodeIndex {
            if (attr.tag == .jsx_attribute) {
                return lowerJSXAttribute(self, attr, span);
            } else if (attr.tag == .jsx_spread_attribute) {
                // {...props} → spread_element
                const inner = try self.visitNode(attr.data.unary.operand);
                return self.ast.addNode(.{
                    .tag = .spread_element,
                    .span = attr.span,
                    .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
                });
            }
            return .none;
        }

        /// jsx_attribute: binary = {left=name, right=value}
        /// → object_property: binary = {left=key, right=val}
        fn lowerJSXAttribute(self: *Transformer, attr: Node, span: Span) Transformer.Error!NodeIndex {
            _ = span;
            const name_idx = attr.data.binary.left;
            const value_idx = attr.data.binary.right;

            const name_node = self.ast.getNode(name_idx);
            const name_text = self.ast.source[name_node.span.start..name_node.span.end];

            // key: identifier_reference로 생성
            const key_span = try self.ast.addString(name_text);
            const key_node = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = key_span,
                .data = .{ .string_ref = key_span },
            });

            // value: 없으면 true
            const val_node = if (value_idx.isNone()) blk: {
                const true_span = try self.ast.addString("true");
                break :blk try self.ast.addNode(.{
                    .tag = .boolean_literal,
                    .span = true_span,
                    .data = .{ .none = 0 },
                });
            } else try self.visitNode(value_idx);

            return self.ast.addNode(.{
                .tag = .object_property,
                .span = attr.span,
                .data = .{ .binary = .{ .left = key_node, .right = val_node, .flags = 0 } },
            });
        }

        // ================================================================
        // Children 처리
        // ================================================================

        /// children 노드를 수집하여 NodeIndex 슬라이스로 반환 (공백 텍스트, 빈 expression 제외)
        fn collectChildren(self: *Transformer, start: u32, len: u32) Transformer.Error![]const NodeIndex {
            if (len == 0) return &.{};

            const scratch_top = self.scratch.items.len;
            // Note: 이 함수는 caller가 scratch를 복원하므로, 여기선 복원하지 않음

            // while 인덱스 루프: visitNode/addNode가 extra_data를 재할당할 수 있으므로 슬라이스 캐시 금지
            var j: u32 = 0;
            while (j < len) : (j += 1) {
                const raw_idx = self.ast.extra_data.items[start + j];
                const child_idx: NodeIndex = @enumFromInt(raw_idx);
                const child = self.ast.getNode(child_idx);

                switch (child.tag) {
                    .jsx_text => {
                        const new_child = try lowerJSXText(self, child);
                        if (!new_child.isNone()) {
                            try self.scratch.append(self.allocator, new_child);
                        }
                    },
                    .jsx_expression_container => {
                        if (child.data.unary.operand.isNone()) continue;
                        const new_child = try self.visitNode(child.data.unary.operand);
                        if (!new_child.isNone()) {
                            try self.scratch.append(self.allocator, new_child);
                        }
                    },
                    .jsx_spread_child => {
                        const inner = try self.visitNode(child.data.unary.operand);
                        const spread = try self.ast.addNode(.{
                            .tag = .spread_element,
                            .span = child.span,
                            .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
                        });
                        try self.scratch.append(self.allocator, spread);
                    },
                    else => {
                        // jsx_element, jsx_fragment 등은 visitNode로 재귀
                        const new_child = try self.visitNode(child_idx);
                        if (!new_child.isNone()) {
                            try self.scratch.append(self.allocator, new_child);
                        }
                    },
                }
            }

            // 결과를 별도 버퍼에 복사 (scratch가 caller에 의해 재사용되므로)
            const result = self.scratch.items[scratch_top..];
            const copy = try self.allocator.alloc(NodeIndex, result.len);
            @memcpy(copy, result);
            self.scratch.shrinkRetainingCapacity(scratch_top);
            return copy;
        }

        /// 단일 effective child를 반환
        fn collectSingleChild(self: *Transformer, start: u32, len: u32) Transformer.Error!NodeIndex {
            // while 인덱스 루프: visitNode/addNode가 extra_data를 재할당할 수 있으므로 슬라이스 캐시 금지
            var j: u32 = 0;
            while (j < len) : (j += 1) {
                const raw_idx = self.ast.extra_data.items[start + j];
                const child_idx: NodeIndex = @enumFromInt(raw_idx);
                const child = self.ast.getNode(child_idx);

                switch (child.tag) {
                    .jsx_text => {
                        const result = try lowerJSXText(self, child);
                        if (!result.isNone()) return result;
                    },
                    .jsx_expression_container => {
                        if (child.data.unary.operand.isNone()) continue;
                        return self.visitNode(child.data.unary.operand);
                    },
                    .jsx_spread_child => {
                        const inner = try self.visitNode(child.data.unary.operand);
                        return self.ast.addNode(.{
                            .tag = .spread_element,
                            .span = child.span,
                            .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
                        });
                    },
                    else => {
                        return self.visitNode(child_idx);
                    },
                }
            }
            return .none;
        }

        /// 유효 children 수 카운트 (공백만인 text와 빈 expression 제외)
        fn countEffective(self: *Transformer, start: u32, len: u32) u32 {
            if (len == 0) return 0;
            var count: u32 = 0;
            const indices = self.ast.extra_data.items[start .. start + len];
            for (indices) |raw_idx| {
                const child = self.ast.getNode(@enumFromInt(raw_idx));
                if (child.tag == .jsx_text) {
                    const text = self.ast.source[child.span.start..child.span.end];
                    const trimmed = std.mem.trim(u8, text, " \t\n\r");
                    if (trimmed.len == 0) continue;
                } else if (child.tag == .jsx_expression_container and child.data.unary.operand.isNone()) {
                    continue;
                }
                count += 1;
            }
            return count;
        }

        // ================================================================
        // Key 검색
        // ================================================================

        const KeySearchResult = struct {
            key_idx: ?u32,
            key_after_spread: bool,
        };

        /// attrs에서 key attribute의 인덱스와 spread 뒤 여부를 판별
        fn findKeyAttr(self: *Transformer, attrs_start: u32, attrs_len: u32) KeySearchResult {
            if (attrs_len == 0) return .{ .key_idx = null, .key_after_spread = false };
            var seen_spread = false;
            const attr_indices = self.ast.extra_data.items[attrs_start .. attrs_start + attrs_len];
            for (attr_indices, 0..) |raw_idx, i| {
                const attr = self.ast.getNode(@enumFromInt(raw_idx));
                if (attr.tag == .jsx_spread_attribute) {
                    seen_spread = true;
                } else if (attr.tag == .jsx_attribute) {
                    const key_node = self.ast.getNode(attr.data.binary.left);
                    const name = self.ast.source[key_node.span.start..key_node.span.end];
                    if (std.mem.eql(u8, name, "key")) {
                        return .{ .key_idx = @intCast(i), .key_after_spread = seen_spread };
                    }
                }
            }
            return .{ .key_idx = null, .key_after_spread = false };
        }

        /// key attribute의 value 노드를 방문하여 반환
        fn getKeyValue(self: *Transformer, attrs_start: u32, key_idx: u32) Transformer.Error!NodeIndex {
            const attr_node_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[attrs_start + key_idx]);
            const attr = self.ast.getNode(attr_node_idx);
            return self.visitNode(attr.data.binary.right);
        }

        // ================================================================
        // Dev source info
        // ================================================================

        /// { fileName: "...", lineNumber: N, columnNumber: N } 객체 생성
        fn buildDevSourceInfo(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const loc = spanToLineCol(self, span.start);

            // fileName property
            const fn_key_span = try self.ast.addString("fileName");
            const fn_key = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = fn_key_span,
                .data = .{ .string_ref = fn_key_span },
            });
            const quoted_filename = try quoteString(self, self.options.jsx_filename);
            const fn_val_span = try self.ast.addString(quoted_filename);
            const fn_val = try self.ast.addNode(.{
                .tag = .string_literal,
                .span = fn_val_span,
                .data = .{ .string_ref = fn_val_span },
            });
            const fn_prop = try self.ast.addNode(.{
                .tag = .object_property,
                .span = fn_key_span,
                .data = .{ .binary = .{ .left = fn_key, .right = fn_val, .flags = 0 } },
            });

            // lineNumber property
            const ln_key_span = try self.ast.addString("lineNumber");
            const ln_key = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = ln_key_span,
                .data = .{ .string_ref = ln_key_span },
            });
            var ln_buf: [10]u8 = undefined;
            const ln_text = std.fmt.bufPrint(&ln_buf, "{d}", .{loc.line}) catch "0";
            const ln_val_span = try self.ast.addString(ln_text);
            const ln_val = try self.ast.addNode(.{
                .tag = .numeric_literal,
                .span = ln_val_span,
                .data = .{ .none = 0 },
            });
            const ln_prop = try self.ast.addNode(.{
                .tag = .object_property,
                .span = ln_key_span,
                .data = .{ .binary = .{ .left = ln_key, .right = ln_val, .flags = 0 } },
            });

            // columnNumber property
            const cn_key_span = try self.ast.addString("columnNumber");
            const cn_key = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = cn_key_span,
                .data = .{ .string_ref = cn_key_span },
            });
            var cn_buf: [10]u8 = undefined;
            const cn_text = std.fmt.bufPrint(&cn_buf, "{d}", .{loc.col}) catch "0";
            const cn_val_span = try self.ast.addString(cn_text);
            const cn_val = try self.ast.addNode(.{
                .tag = .numeric_literal,
                .span = cn_val_span,
                .data = .{ .none = 0 },
            });
            const cn_prop = try self.ast.addNode(.{
                .tag = .object_property,
                .span = cn_key_span,
                .data = .{ .binary = .{ .left = cn_key, .right = cn_val, .flags = 0 } },
            });

            return makeObjectExpr(self, &.{ fn_prop, ln_prop, cn_prop }, span);
        }

        const LineLoc = struct { line: u32, col: u32 };

        fn spanToLineCol(self: *Transformer, offset: u32) LineLoc {
            if (self.line_offsets.len == 0) return .{ .line = 1, .col = 1 };
            var lo: u32 = 0;
            var hi: u32 = @intCast(self.line_offsets.len);
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.line_offsets[mid] <= offset) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            const line = lo; // 1-based
            const line_start = if (line > 1) self.line_offsets[line - 1] else 0;

            // UTF-16 code unit 기준 column 계산 (JSX devtools 호환)
            const source = self.ast.source;
            var col: u32 = 0;
            var i: u32 = line_start;
            while (i < offset and i < source.len) {
                const byte = source[i];
                if (byte < 0x80) {
                    col += 1;
                    i += 1;
                } else if (byte < 0xC0) {
                    i += 1;
                } else if (byte < 0xE0) {
                    col += 1;
                    i += @min(2, @as(u32, @intCast(source.len)) - i);
                } else if (byte < 0xF0) {
                    col += 1;
                    i += @min(3, @as(u32, @intCast(source.len)) - i);
                } else {
                    col += 2;
                    i += @min(4, @as(u32, @intCast(source.len)) - i);
                }
            }
            return .{ .line = line, .col = col + 1 };
        }

        // ================================================================
        // JSX 텍스트 처리
        // ================================================================

        /// JSX 텍스트를 정규화: 라인별 trim, 라인 간 공백 1개, entity 디코딩
        fn processJSXText(self: *Transformer, text: []const u8) Transformer.Error![]const u8 {
            // 최대 출력 크기: 원본 + entity 확장 여유
            var buf = try self.allocator.alloc(u8, text.len * 4 + 16);
            var out_len: usize = 0;
            var has_output = false;
            var line_start: usize = 0;
            var line_idx: usize = 0;

            while (line_start < text.len) {
                var line_end = line_start;
                while (line_end < text.len and text[line_end] != '\n' and text[line_end] != '\r') {
                    line_end += 1;
                }

                const line = text[line_start..line_end];
                const is_first_line = (line_idx == 0);

                var next_start = line_end;
                if (next_start < text.len) {
                    next_start += 1;
                    if (text[line_end] == '\r' and next_start < text.len and text[next_start] == '\n') {
                        next_start += 1;
                    }
                }
                const is_last_line = (next_start >= text.len);

                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len > 0) {
                    if (has_output) {
                        buf[out_len] = ' ';
                        out_len += 1;
                    }
                    has_output = true;

                    const output_text = if (is_first_line and is_last_line)
                        line
                    else if (is_first_line)
                        std.mem.trimRight(u8, line, " \t")
                    else if (is_last_line)
                        std.mem.trimLeft(u8, line, " \t")
                    else
                        trimmed;

                    // entity 디코딩 + 출력
                    var i: usize = 0;
                    while (i < output_text.len) {
                        const c = output_text[i];
                        if (c == '&') {
                            if (tryDecodeHTMLEntity(output_text, i)) |result| {
                                const n = std.unicode.utf8Encode(result.codepoint, buf[out_len..][0..4]) catch 0;
                                out_len += n;
                                i = result.end;
                                continue;
                            }
                        }
                        buf[out_len] = c;
                        out_len += 1;
                        i += 1;
                    }
                }

                line_start = next_start;
                line_idx += 1;
            }

            return buf[0..out_len];
        }

        /// 텍스트를 "..."로 감싸고 특수 문자를 이스케이프.
        /// codegen의 writeStringLiteral이 따옴표가 포함된 문자열을 기대하므로 필수.
        fn quoteString(self: *Transformer, text: []const u8) Transformer.Error![]const u8 {
            // 최악의 경우: 모든 문자가 \xHH (4배) + 앞뒤 따옴표
            var buf = try self.allocator.alloc(u8, text.len * 4 + 2);
            var out: usize = 0;
            buf[out] = '"';
            out += 1;
            for (text) |c| {
                switch (c) {
                    '"' => {
                        buf[out] = '\\';
                        buf[out + 1] = '"';
                        out += 2;
                    },
                    '\\' => {
                        buf[out] = '\\';
                        buf[out + 1] = '\\';
                        out += 2;
                    },
                    '\n' => {
                        buf[out] = '\\';
                        buf[out + 1] = 'n';
                        out += 2;
                    },
                    '\r' => {
                        buf[out] = '\\';
                        buf[out + 1] = 'r';
                        out += 2;
                    },
                    '\t' => {
                        buf[out] = '\\';
                        buf[out + 1] = 't';
                        out += 2;
                    },
                    else => {
                        if (c < 0x20) {
                            // 제어 문자 → \xHH
                            const hex = "0123456789abcdef";
                            buf[out] = '\\';
                            buf[out + 1] = 'x';
                            buf[out + 2] = hex[(c >> 4) & 0xF];
                            buf[out + 3] = hex[c & 0xF];
                            out += 4;
                        } else {
                            buf[out] = c;
                            out += 1;
                        }
                    },
                }
            }
            buf[out] = '"';
            out += 1;
            return buf[0..out];
        }

        const EntityResult = struct { codepoint: u21, end: usize };

        fn tryDecodeHTMLEntity(text: []const u8, start: usize) ?EntityResult {
            const after_amp = start + 1;
            if (after_amp >= text.len) return null;
            const next = text[after_amp];
            if (next == ' ' or next == '\t' or next == '\n' or next == '\r') return null;

            const max_end = @min(after_amp + 12, text.len);
            var semi_pos: ?usize = null;
            for (after_amp..max_end) |j| {
                if (text[j] == ';') {
                    semi_pos = j;
                    break;
                }
            }
            const semi = semi_pos orelse return null;
            const entity_body = text[after_amp..semi];

            if (entity_body.len >= 2 and entity_body[0] == '#') {
                if (entity_body[1] == 'x' or entity_body[1] == 'X') {
                    const hex_str = entity_body[2..];
                    if (hex_str.len == 0) return null;
                    const cp = std.fmt.parseInt(u21, hex_str, 16) catch return null;
                    return .{ .codepoint = cp, .end = semi + 1 };
                } else {
                    const dec_str = entity_body[1..];
                    if (dec_str.len == 0) return null;
                    const cp = std.fmt.parseInt(u21, dec_str, 10) catch return null;
                    return .{ .codepoint = cp, .end = semi + 1 };
                }
            }

            const cp = namedEntityToCodepoint(entity_body) orelse return null;
            return .{ .codepoint = cp, .end = semi + 1 };
        }

        fn namedEntityToCodepoint(name: []const u8) ?u21 {
            return jsx_entity_map.get(name);
        }

        // ================================================================
        // AST 헬퍼
        // ================================================================

        /// call_expression 생성: extra = [callee, args_start, args_len, flags]
        fn makeCallExpr(self: *Transformer, callee: NodeIndex, args: []const NodeIndex, span: Span, pure: bool) Transformer.Error!NodeIndex {
            const args_list = try self.ast.addNodeList(args);
            const flags: u32 = if (pure) CallFlags.is_pure else 0;
            return self.addExtraNode(.call_expression, span, &.{
                @intFromEnum(callee),
                args_list.start,
                args_list.len,
                flags,
            });
        }

        /// null 리터럴 노드 생성
        fn makeNullLiteral(self: *Transformer, _: Span) Transformer.Error!NodeIndex {
            const null_span = try self.ast.addString("null");
            return self.ast.addNode(.{
                .tag = .null_literal,
                .span = null_span,
                .data = .{ .none = 0 },
            });
        }

        /// object_expression 노드 생성 (properties 리스트로)
        /// --target < es2018 이면 spread가 포함된 경우 Object.assign()으로 변환
        fn makeObjectExpr(self: *Transformer, properties: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // ES2018 object spread 다운레벨링: JSX lowering이 만든 object에 spread가 있으면
            // Object.assign({a: 1}, obj, {b: 2}) 형태로 변환해야 한다.
            // (JSX lowering이 ast에 직접 노드를 생성하므로, transformer의 visitNode를
            //  다시 거치지 않아 es2018.lowerObjectSpread가 적용되지 않기 때문)
            if (self.options.unsupported.object_spread) {
                for (properties) |prop_idx| {
                    const prop = self.ast.getNode(prop_idx);
                    if (prop.tag == .spread_element) {
                        return helpers.lowerObjectSpreadProps(self, properties, span);
                    }
                }
            }

            const list = try self.ast.addNodeList(properties);
            return self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = list },
            });
        }

        /// "A.B.C" 형태의 factory 문자열을 static_member_expression 체인으로 변환.
        /// "React.createElement" → static_member(React, createElement)
        fn makeFactoryCallee(self: *Transformer, factory: []const u8) Transformer.Error!NodeIndex {
            // dot이 없으면 단순 identifier
            const dot_pos = std.mem.indexOf(u8, factory, ".");
            if (dot_pos == null) {
                return helpers.makeIdentifierRef(self, factory);
            }

            // dot 기반 분할: "A.B.C" → ["A", "B", "C"]
            var current: NodeIndex = .none;
            var start: usize = 0;
            while (start < factory.len) {
                const end = std.mem.indexOfPos(u8, factory, start, ".") orelse factory.len;
                const part = factory[start..end];
                const part_node = try helpers.makeIdentifierRef(self, part);

                if (current.isNone()) {
                    current = part_node;
                } else {
                    const span_val = try self.ast.addString(factory);
                    current = try helpers.makeStaticMember(self, current, part_node, span_val);
                }
                start = end + 1;
            }

            return current;
        }
    };
}

// ================================================================
// JSX HTML Entity Map
// ================================================================
const jsx_entity_map = std.StaticStringMap(u21).initComptime(.{
    // 필수 5개
    .{ "amp", '&' },
    .{ "lt", '<' },
    .{ "gt", '>' },
    .{ "quot", '"' },
    .{ "apos", '\'' },
    // 공백/포맷
    .{ "nbsp", 0xA0 },
    .{ "ensp", 0x2002 },
    .{ "emsp", 0x2003 },
    .{ "thinsp", 0x2009 },
    .{ "zwnj", 0x200C },
    .{ "zwj", 0x200D },
    // 구두점/기호
    .{ "mdash", 0x2014 },
    .{ "ndash", 0x2013 },
    .{ "laquo", 0xAB },
    .{ "raquo", 0xBB },
    .{ "bull", 0x2022 },
    .{ "hellip", 0x2026 },
    .{ "prime", 0x2032 },
    .{ "Prime", 0x2033 },
    .{ "lsquo", 0x2018 },
    .{ "rsquo", 0x2019 },
    .{ "ldquo", 0x201C },
    .{ "rdquo", 0x201D },
    .{ "sbquo", 0x201A },
    .{ "bdquo", 0x201E },
    .{ "lsaquo", 0x2039 },
    .{ "rsaquo", 0x203A },
    // 수학/기술
    .{ "minus", 0x2212 },
    .{ "times", 0xD7 },
    .{ "divide", 0xF7 },
    .{ "plusmn", 0xB1 },
    .{ "le", 0x2264 },
    .{ "ge", 0x2265 },
    .{ "ne", 0x2260 },
    .{ "asymp", 0x2248 },
    .{ "infin", 0x221E },
    .{ "sum", 0x2211 },
    .{ "prod", 0x220F },
    .{ "radic", 0x221A },
    .{ "permil", 0x2030 },
    .{ "deg", 0xB0 },
    .{ "micro", 0xB5 },
    .{ "frac14", 0xBC },
    .{ "frac12", 0xBD },
    .{ "frac34", 0xBE },
    // 화폐/법률
    .{ "euro", 0x20AC },
    .{ "pound", 0xA3 },
    .{ "yen", 0xA5 },
    .{ "cent", 0xA2 },
    .{ "curren", 0xA4 },
    .{ "copy", 0xA9 },
    .{ "reg", 0xAE },
    .{ "trade", 0x2122 },
    .{ "sect", 0xA7 },
    .{ "para", 0xB6 },
    // 화살표
    .{ "larr", 0x2190 },
    .{ "uarr", 0x2191 },
    .{ "rarr", 0x2192 },
    .{ "darr", 0x2193 },
    .{ "harr", 0x2194 },
    .{ "lArr", 0x21D0 },
    .{ "rArr", 0x21D2 },
    // 기타 기호
    .{ "hearts", 0x2665 },
    .{ "diams", 0x2666 },
    .{ "clubs", 0x2663 },
    .{ "spades", 0x2660 },
    .{ "check", 0x2713 },
    .{ "cross", 0x2717 },
    .{ "star", 0x22C6 },
    // 라틴 확장
    .{ "iexcl", 0xA1 },
    .{ "iquest", 0xBF },
    .{ "Agrave", 0xC0 },
    .{ "Aacute", 0xC1 },
    .{ "Acirc", 0xC2 },
    .{ "Atilde", 0xC3 },
    .{ "Auml", 0xC4 },
    .{ "Aring", 0xC5 },
    .{ "AElig", 0xC6 },
    .{ "Ccedil", 0xC7 },
    .{ "Egrave", 0xC8 },
    .{ "Eacute", 0xC9 },
    .{ "Euml", 0xCB },
    .{ "Igrave", 0xCC },
    .{ "Iacute", 0xCD },
    .{ "Iuml", 0xCF },
    .{ "Ntilde", 0xD1 },
    .{ "Ograve", 0xD2 },
    .{ "Oacute", 0xD3 },
    .{ "Ouml", 0xD6 },
    .{ "Oslash", 0xD8 },
    .{ "Ugrave", 0xD9 },
    .{ "Uacute", 0xDA },
    .{ "Uuml", 0xDC },
    .{ "szlig", 0xDF },
    .{ "agrave", 0xE0 },
    .{ "aacute", 0xE1 },
    .{ "acirc", 0xE2 },
    .{ "atilde", 0xE3 },
    .{ "auml", 0xE4 },
    .{ "aring", 0xE5 },
    .{ "aelig", 0xE6 },
    .{ "ccedil", 0xE7 },
    .{ "egrave", 0xE8 },
    .{ "eacute", 0xE9 },
    .{ "euml", 0xEB },
    .{ "igrave", 0xEC },
    .{ "iacute", 0xED },
    .{ "iuml", 0xEF },
    .{ "ntilde", 0xF1 },
    .{ "ograve", 0xF2 },
    .{ "oacute", 0xF3 },
    .{ "ouml", 0xF6 },
    .{ "oslash", 0xF8 },
    .{ "ugrave", 0xF9 },
    .{ "uacute", 0xFA },
    .{ "uuml", 0xFC },
});
