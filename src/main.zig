const std = @import("std");

const MAX_NUM_OF_THREADS = 8;

const DirContents = struct {
    files : std.ArrayList([]const u8),
    nested_dirs : std.ArrayList(DirContents),
    size : u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    
    // In order to do I/O operations need an `Io` instance.
    const io = init.io;
    ////
    //// Stdout is for the actual output of your application, for example if you
    //// are implementing gzip, then only the compressed bytes should be sent to
    //// stdout, not any debugging messages.
    //var stdout_buffer: [1024]u8 = undefined;
    //var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    //const stdout_writer = &stdout_file_writer.interface;
    //defer stdout_writer.flush() catch {};
    //
    var running_sum : u64 = 0;

    const walkable_dir : std.Io.Dir = std.Io.Dir.openDir(
        .cwd(),
        io,
        ".",
        .{
            .iterate = true,
            .follow_symlinks = false,
        },
    ) catch |err| {
        std.debug.print("Error code when opening dir: {any}\n", .{ err });
        return err;
    };
    defer walkable_dir.close(io);

    var walker = try walkable_dir.walk(allocator);
    defer walker.deinit();

    while (walker.next(io)) |nullable_entry| {
        const entry = nullable_entry orelse break;

        if (.file != entry.kind) {
            continue;
        }

        const stat = std.Io.Dir.statFile (
            .cwd(),
            io,
            entry.path,
            .{
                .follow_symlinks = false,
            },
        ) catch |err| {
            std.debug.print("Error: {any}\n", .{ err });
            return;
        };

        running_sum += stat.size;
    }
    else |err| {
        std.debug.print("Error walking directory: {any}\n", .{ err });
        return err;
    }

    std.debug.print("The size of the dir is: {d} bytes\n", .{ running_sum });
}
