const std = @import("std");
const zutl = @import("zutl");

const FileSystemEntry = struct {
    name : []const u8,
    size : u64,
    kind : std.Io.File.Kind,
};

const DisplayPage = struct {
    current_rel_path : ?[]const u8,
    entry_list : *std.ArrayList(FileSystemEntry),
    current_item : usize,
    max_item : usize,
    total_size : u64,
};

fn fs_lt_comp(
    _ : void,
    a : FileSystemEntry,
    b : FileSystemEntry,
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

    var arr_list_of_fs_entries : std.ArrayList(FileSystemEntry) = .empty;
    var page_to_display = try generate_initial_display(io, allocator, &arr_list_of_fs_entries);
    defer {
        if (page_to_display.current_rel_path) |path| {
            allocator.free(path);
        }
        for (page_to_display.entry_list.items) |item| {
            allocator.free(item.name);
        }
        page_to_display.entry_list.deinit(allocator);
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

    try update_the_display(
        &writer_stdout,
        &page_to_display,);

    while(true) {
        const char = try reader_stdout.interface.takeByte();
        const update_display = switch (char) {
            'j' => increment_display(&page_to_display),
            'k' => decrement_display(&page_to_display),
            '\r', '\n' => try handle_enter(io, allocator, &page_to_display),
            'q' => break,
            else => continue,
        };

        if (update_display) {
            try update_the_display(
                &writer_stdout,
                &page_to_display,);
        }
    }
    //_ = &writer_stdout;

    //try collect_file_information(io, allocator, &arr_list_fs_item);


    //std.mem.sort(FileSystemEntry, arr_list_fs_item.items, {}, fs_lt_comp);

    //const size = try zutl.Dir.get_directory_size(io, allocator, ".");

    //try old_display_function_to_delete(io, size, &arr_list_fs_item);
}

fn handle_enter(
    io : std.Io,
    allocator : std.mem.Allocator,
    display_page : *DisplayPage,
) !bool {
    if (1 == display_page.current_item) {
        // Do nothing... user is trying to refresh current view.
        return false;
    }

    var buffer_for_new_path : [std.fs.max_path_bytes]u8 = undefined;

    const new_path = blk: {
        if (0 == display_page.current_item) {
            const path = display_page.current_rel_path orelse return error.NullPath;
            const index = std.mem.lastIndexOfScalar(u8, path, std.fs.path.sep) orelse return false;
            break :blk path[0..index];
        }
        else {
            break :blk try std.fmt.bufPrint(
                &buffer_for_new_path,
                "{s}{c}{s}",
                .{
                    display_page.current_rel_path.?,
                    std.fs.path.sep,
                    display_page.entry_list.items[display_page.current_item - 2].name
                });
        }
    };

    try generate_display(
        io,
        allocator,
        display_page,
        new_path);

    return true;
}

fn increment_display(page : *DisplayPage) bool {
    if (page.current_item < (page.max_item - 1)) {
        page.current_item += 1;
        return true;
    }
    return false;
}

fn decrement_display(page : *DisplayPage) bool {
    if (page.current_item > 0) {
        page.current_item -= 1;
        return true;
    }
    return false;
}


fn old_display_function_to_delete(
    io : std.Io,
    parent_size : u64,
    fs_list : *std.ArrayList(FileSystemEntry),
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
    display : *DisplayPage,
    //arr_list : *std.ArrayList(FileSystemEntry),
) !void {
    const path = display.current_rel_path orelse ".";
    const cwd = try std.Io.Dir.openDir(.cwd(), io, path, .{ .iterate = true, .follow_symlinks = false });
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
        try display.entry_list.append(
            allocator,
            .{
                .kind = entry.kind,
                .size = size,
                .name = try allocator.dupe(u8, entry.name),
            });
        display.total_size += size;
    }
    else |err| {
        std.log.err("There was an error iterating through the directory: {any}", .{ err });
        return err;
    }

    std.mem.sort(FileSystemEntry, display.entry_list.items, {}, fs_lt_comp);
}

fn update_the_display(
    stdout : *std.Io.File.Writer,
    display_page : *DisplayPage,
) !void {
    try stdout.interface.print("\x1b[2J\x1b[H", .{});
    //try stdout.interface.flush();

    const max_name_size = blk: {
        var longest_name : usize = 0;

        for (display_page.entry_list.items) |entry| {
            if (entry.name.len > longest_name) {
                longest_name = entry.name.len;
            }
        }

        break :blk longest_name + 1;
    };

    if (display_page.current_item == 0) {
        try stdout.interface.print("- \x1b[34m../\x1b[0m\n", .{});
    }
    else {
        try stdout.interface.print("  \x1b[34m../\x1b[0m\n", .{});
    }

    if (display_page.current_item == 1) {
        try stdout.interface.print("- \x1b[34m./\x1b[0m\n", .{});
    }
    else {
        try stdout.interface.print("  \x1b[34m./\x1b[0m\n", .{});
    }

    for (display_page.entry_list.items, 2..) |entry, i| {
        const color_str_start, const color_str_end = blk: {
            if (.directory == entry.kind) {
                break :blk .{ "\x1b[34m", "\x1b[0m"};
            }
            else {
                break :blk .{ "", ""};
            }
        };
        if (display_page.current_item == i) {
            try stdout.interface.print("- {s}{s}{s}", .{ color_str_start, entry.name, color_str_end });
        }
        else {
            try stdout.interface.print("  {s}{s}{s}", .{ color_str_start, entry.name, color_str_end });
        }
        const spaces_to_write = max_name_size - entry.name.len;
        for (0..spaces_to_write) |_| {
            _ = try stdout.interface.write(" ");
        }

        const percent : f64 = ((@as(f64, @floatFromInt(entry.size)) / @as(f64, @floatFromInt(display_page.total_size))) * 100.0);

        try stdout.interface.print("- {d:.4}% ({d} bytes)\n", .{ percent, entry.size });
    }

    try stdout.interface.flush();
}

fn generate_initial_display(
    io : std.Io,
    allocator : std.mem.Allocator,
    arr_list : *std.ArrayList(FileSystemEntry),
) !DisplayPage {
    var display : DisplayPage = undefined;
    display.entry_list = arr_list;
    display.current_rel_path = null;
    try generate_display(
        io,
        allocator,
        &display,
        ".");
    return display;
}

fn generate_display(
    io : std.Io,
    allocator : std.mem.Allocator,
    display : *DisplayPage,
    new_path : []const u8,
) !void {
    std.log.debug("Just regenerated backing data for display...", .{});
    //First step is to clear the array list of entries if updating.
    for (display.entry_list.items) |item| {
        allocator.free(item.name);
    }
    display.entry_list.clearAndFree(allocator);
    
    if (display.current_rel_path) |path| {
        allocator.free(path);
    }
    display.total_size = 0;
    // End clearing arraylist
    

    display.current_rel_path = try allocator.dupe(u8, new_path);
    display.current_item = 1;

    try collect_file_information(
        io,
        allocator,
        display);

    display.max_item = blk: {
        var num : usize = 2;
        for (display.entry_list.items) |item| {
            if (.directory == item.kind) num += 1;
        }
        break :blk num;
    };

    std.log.debug("New max number of items is: {d}", .{ display.max_item });
}
