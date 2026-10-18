const std = @import("std");
const zutl = @import("zutl");

pub fn main() !void {
    var debugAllocator : std.heap.DebugAllocator(.{}) = .init;
    defer _ = debugAllocator.deinit();

    const allocator = debugAllocator.allocator();

    var threaded : std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();

    const io = threaded.io();

    const size = try zutl.Dir.get_directory_size(io, allocator, ".");
    std.log.debug("Size of current directory is: {d}", .{ size });
}
