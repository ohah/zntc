pub const DevServer = @import("dev_server.zig").DevServer;
pub const FileWatcher = @import("file_watcher.zig").FileWatcher;
pub const ChangeEvent = @import("file_watcher.zig").ChangeEvent;
pub const ChangeKind = @import("file_watcher.zig").ChangeKind;
pub const TrackedFileSet = @import("tracked_file_set.zig").TrackedFileSet;
pub const mime = @import("mime.zig");
pub const watch_scan = @import("watch_scan.zig");
pub const events = @import("events.zig");
pub const boringssl = @import("boringssl.zig");
pub const tls = @import("tls.zig");
pub const mcp_stdio = @import("mcp_stdio.zig");

test {
    _ = @import("dev_server.zig");
    _ = @import("file_watcher.zig");
    _ = @import("tracked_file_set.zig");
    _ = @import("mime.zig");
    _ = @import("watch_scan.zig");
    _ = @import("events.zig");
    _ = @import("boringssl.zig");
    _ = @import("tls.zig");
    _ = @import("mcp_stdio.zig");

    // test files
    _ = @import("dev_server_test.zig");
    _ = @import("file_watcher_test.zig");
    _ = @import("mime_test.zig");
}
