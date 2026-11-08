//! Native environment role writes belong to the graph storage owner phase.
const Graph = @import("../graph.zig").ModuleGraph;
const ModuleIndex = @import("../types.zig").ModuleIndex;
const Member = @import("../native_async_module_plan.zig").Member;

pub fn restore(graph: *Graph, index: ModuleIndex, prior: Member) void {
    const module = graph.moduleAtMut(index) orelse @panic("native module role lost its graph slot");
    if (module.codegen_output_owner != prior.owner) @panic("native module role changed graph owner");
    if (module.wrap_kind == .esm) {
        module.wrap_kind = prior.previous_wrap;
        if (prior.previous_exports == .none and module.exports_kind == .esm) module.exports_kind = .none;
    }
}

pub fn promote(graph: *Graph, index: ModuleIndex) void {
    const module = graph.moduleAtMut(index) orelse @panic("native module role lost its graph slot");
    const role = graph.native_async_module_members.get(module.codegen_output_owner) orelse @panic("native module role has no constructor owner");
    if (role.index != index or role.owner != module.codegen_output_owner) @panic("native module role changed graph owner");
    if (module.exports_kind == .none) module.exports_kind = .esm;
    module.wrap_kind = .esm;
}
