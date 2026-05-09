const std = @import("std");
const Module = @import("../module.zig").Module;
const RequestedExports = @import("state.zig").RequestedExports;

pub fn localNeedsAllRecords(m: *const Module, req: *const RequestedExports) bool {
    if (req.all) return true;
    var it = req.names.keyIterator();
    while (it.next()) |name| {
        for (m.export_bindings) |eb| {
            if (eb.kind == .local and std.mem.eql(u8, eb.exported_name, name.*)) return true;
        }
    }
    return false;
}

pub fn nameHasDirectNonStarExport(m: *const Module, name: []const u8) bool {
    for (m.export_bindings) |eb| {
        if (eb.kind == .re_export_star) continue;
        if (std.mem.eql(u8, eb.exported_name, name)) return true;
    }
    return false;
}

pub fn reExportRecordMatchesRequest(m: *const Module, rec_i: usize, req: *const RequestedExports) bool {
    if (req.all) return true;
    var names = req.names.keyIterator();
    while (names.next()) |requested_name| {
        for (m.export_bindings) |eb| {
            const eb_rec = eb.import_record_index orelse continue;
            if (eb_rec != rec_i) continue;
            switch (eb.kind) {
                .re_export,
                .re_export_namespace,
                => {
                    if (std.mem.eql(u8, eb.exported_name, requested_name.*)) return true;
                },
                .re_export_star => {
                    if (!nameHasDirectNonStarExport(m, requested_name.*)) return true;
                },
                .local => {},
            }
        }
    }
    return false;
}
