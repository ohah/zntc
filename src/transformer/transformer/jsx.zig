//! JSX visitor helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const styled_components_mod = @import("styled_components.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// jsx_element: extra = [tag_name, attrs_start, attrs_len, children_start, children_len]
pub fn visitJSXElement(self: *Transformer, node: Node) Error!NodeIndex {
    const working_node = (try styled_components_mod.maybeExtractCssProp(self, node)) orelse node;
    const e = working_node.data.extra;
    const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
    const new_attrs = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
    const children_len = self.readU32(e, 4);
    const new_children = if (children_len > 0)
        try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = children_len })
    else
        NodeList{ .start = 0, .len = 0 };
    return self.addExtraNode(.jsx_element, working_node.span, &.{
        @intFromEnum(new_tag),
        new_attrs.start,
        new_attrs.len,
        new_children.start,
        new_children.len,
    });
}

/// jsx_opening_element: extra = [tag_name, attrs_start, attrs_len]
pub fn visitJSXOpeningElement(self: *Transformer, node: Node) Error!NodeIndex {
    return visitJSXExtraNode(self, .jsx_opening_element, node);
}

fn visitJSXExtraNode(self: *Transformer, tag: Tag, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
    const new_attrs = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
    return self.addExtraNode(tag, node.span, &.{
        @intFromEnum(new_tag),
        new_attrs.start,
        new_attrs.len,
    });
}
