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

    var summing_queue_buffer : [100]u64 = undefined;
    var summing_queue : std.Io.Queue(u64) = .init(&summing_queue_buffer);

    var path_queue_buffer : [100][]u8 = undefined;
    var path_queue : std.Io.Queue([]u8) = .init(&path_queue_buffer);

    var future_summing = io.async(
        summing_thread,
        .{
            io,
            &summing_queue,
        },
    );

    var group : std.Io.Group = .init;
    for (0..MAX_NUM_OF_THREADS) |_| {
        try group.concurrent(
            io,
            stat_thread,
            .{
                io,
                allocator,
                &path_queue,
                &summing_queue,
            }
        );
    }

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

        const path = try allocator.dupe(u8, entry.path);
        try path_queue.putOne(io, path);
    }
    else |err| {
        std.debug.print("Error walking directory: {any}\n", .{ err });
        return err;
    }

    path_queue.close(io);
    try group.await(io);

    summing_queue.close(io);

    const final_val = future_summing.await(io);
    std.debug.print("The size of the dir is: {d} bytes\n", .{ final_val });
}



fn summing_thread(io : std.Io, queue : *std.Io.Queue(u64)) u64 {
    var running_sum : u64 = 0;

    while (queue.getOne(io)) |val| {
        running_sum += val;
    }
    else |err| {
        switch (err) {
            error.Canceled => return 0,
            error.Closed => return running_sum,
            else => unreachable,
        }
    }

    return running_sum;
}

fn stat_thread(
    io : std.Io,
    allocator : std.mem.Allocator,
    path_queue : *std.Io.Queue([]u8),
    summing_queue : *std.Io.Queue(u64)
) void {
    while (true) {
        io.checkCancel() catch return;
        const path = path_queue.getOne(io) catch return;
        defer allocator.free(path);

        const stat = std.Io.Dir.statFile (
            .cwd(),
            io,
            path,
            .{
                .follow_symlinks = false,
            },
        ) catch |err| {
            std.debug.print("Error: {any}\n", .{ err });
            return;
        };

        summing_queue.putOne(io, stat.size) catch |err| {
            std.debug.print("Error: {any}\n", .{ err });
            return;
        };
    }
}
