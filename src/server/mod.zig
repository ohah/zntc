pub const DevServer = @import("dev_server.zig").DevServer;
pub const FileWatcher = @import("file_watcher.zig").FileWatcher;
pub const mime = @import("mime.zig");

test {
    _ = @import("dev_server.zig");
    _ = @import("file_watcher.zig");
    _ = @import("mime.zig");

    // test files
    _ = @import("dev_server_test.zig");
    _ = @import("file_watcher_test.zig");
    _ = @import("mime_test.zig");
}
