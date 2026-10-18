const std = @import("std");
const zutl = @import("zutl");

const fs_item = struct {
    name : []const u8,
    size : u64,
    kind : std.Io.File.Kind,
};

fn fs_lt_comp(
    _ : void,
    a : fs_item,
    b : fs_item,
) bool {
    if (a.kind != b.kind) {
        //This section prioritizes direcories, moving them to the front of the list.
        if (.directory == a.kind) return true;
        return false;
    }
    else {
        // These are reversed so items with the highest memory are first in the list.
        if (a.size < b.size) return false;
        return true;
    }
}

pub fn main() !void {
    var debugAllocator : std.heap.DebugAllocator(.{}) = .init;
    defer _ = debugAllocator.deinit();

    const allocator = debugAllocator.allocator();

    var threaded : std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();

    const io = threaded.io();

    var arr_list_fs_item : std.ArrayList(fs_item) = .empty;
    defer {
        for (arr_list_fs_item.items) |item| {
            allocator.free(item.name);
        }
        arr_list_fs_item.deinit(allocator);
    }

    const orig_termios = try std.posix.tcgetattr(std.Io.File.stdin().handle);
    defer {
        std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, orig_termios) catch {};
    }

    var new_termios = orig_termios;
    new_termios.lflag.ICANON = false;
    new_termios.lflag.ECHO = false;
    try std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, new_termios);

    var buffer_stdin : [64]u8 = undefined;
    var buffer_stdout : [1024] u8 = undefined;

    var writer_stdout : std.Io.File.Writer = .init(.stdout(), io, &buffer_stdout);
    var reader_stdout : std.Io.File.Reader = .init(.stdin(), io, &buffer_stdin);

    while(true) {
        const char = try reader_stdout.interface.takeByte();
        switch (char) {
            'h' => std.debug.print("Left pressed\n", .{}),
            'j' => std.debug.print("Down pressed\n", .{}),
            'k' => std.debug.print("Up pressed\n", .{}),
            'l' => std.debug.print("Right pressed\n", .{}),
            'q' => break,
            else => continue,
        }
    }
    _ = &writer_stdout;

    try collect_file_information(io, allocator, &arr_list_fs_item);


    std.mem.sort(fs_item, arr_list_fs_item.items, {}, fs_lt_comp);

    const size = try zutl.Dir.get_directory_size(io, allocator, ".");

    try display(io, size, &arr_list_fs_item);
}


fn display(
    io : std.Io,
    parent_size : u64,
    fs_list : *std.ArrayList(fs_item),
) !void {
    var buffer_stdout : [1024]u8 = undefined;
    var writer_stdout : std.Io.File.Writer = .init(.stdout(), io, &buffer_stdout);
    defer writer_stdout.end() catch {};

    const max_name_size = blk: {
        var longest_name : usize = 0;

        for (fs_list.items) |entry| {
            if (entry.name.len > longest_name) {
                longest_name = entry.name.len;
            }
        }

        break :blk longest_name + 1;
    };

    for (fs_list.items) |entry| {
        try writer_stdout.interface.print("{s}", .{ entry.name });
        const spaces_to_write = max_name_size - entry.name.len;
        for (0..spaces_to_write) |_| {
            _ = try writer_stdout.interface.write(" ");
        }

        const percent : f64 = ((@as(f64, @floatFromInt(entry.size)) / @as(f64, @floatFromInt(parent_size))) * 100.0);

        try writer_stdout.interface.print("- {d:.4}% ({d} bytes)\n", .{ percent, entry.size });
    }
    try writer_stdout.interface.print("-----\n", .{});
    try writer_stdout.interface.print("Size of current directory is: {d} bytes\n", .{ parent_size });

    try writer_stdout.interface.flush();
}


fn collect_file_information(
    io : std.Io,
    allocator : std.mem.Allocator,
    arr_list : *std.ArrayList(fs_item),
) !void {
    const cwd = try std.Io.Dir.openDir(.cwd(), io, ".", .{ .iterate = true, .follow_symlinks = false });
    defer cwd.close(io);

    var cwd_iterator = cwd.iterate();

    while (cwd_iterator.next(io)) |nullable_entry| {
        const entry = nullable_entry orelse break;
        const size = switch (entry.kind) {
            .file => blk: {
                const stat = try std.Io.Dir.statFile(
                    cwd,
                    io,
                    entry.name,
                    .{ .follow_symlinks = false });
                break :blk stat.size;
            },
            .directory => try zutl.Dir.get_directory_size(
                io,
                allocator,
                entry.name),
            else => continue,
        };
        try arr_list.append(
            allocator,
            .{
                .kind = entry.kind,
                .size = size,
                .name = try allocator.dupe(u8, entry.name),
            });
    }
    else |err| {
        std.log.err("There was an error iterating through the directory: {any}", .{ err });
        return err;
    }
}
