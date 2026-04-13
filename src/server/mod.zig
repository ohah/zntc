pub const DevServer = @import("dev_server.zig").DevServer;
pub const FileWatcher = @import("file_watcher.zig").FileWatcher;
pub const ChangeEvent = @import("file_watcher.zig").ChangeEvent;
pub const ChangeKind = @import("file_watcher.zig").ChangeKind;
pub const TrackedFileSet = @import("tracked_file_set.zig").TrackedFileSet;
pub const mime = @import("mime.zig");

test {
    _ = @import("dev_server.zig");
    _ = @import("file_watcher.zig");
    _ = @import("tracked_file_set.zig");
    _ = @import("mime.zig");

    // test files
    _ = @import("dev_server_test.zig");
    _ = @import("file_watcher_test.zig");
    _ = @import("mime_test.zig");
}
