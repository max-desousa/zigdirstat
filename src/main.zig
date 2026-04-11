const std = @import("std");

const MAX_NUM_OF_THREADS = 8;

const DirContents = struct {
    files : std.ArrayList([]const u8),
    nested_dirs : std.ArrayList(DirContents),
    size : u64,
};

var Strings_Backing_Buffers : [MAX_NUM_OF_THREADS - 1][4096]u8 = undefined;
var Strings : [MAX_NUM_OF_THREADS - 1][]u8 = undefined;
var AtomicFlags : [MAX_NUM_OF_THREADS - 1]std.atomic.Value(bool) = undefined;

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

    for (0..(MAX_NUM_OF_THREADS - 1)) |i| {
        Strings_Backing_Buffers[i] = undefined;
        Strings[i] = undefined;
    }

    for (0..(MAX_NUM_OF_THREADS - 1)) |i| {
        AtomicFlags[i] = .init(false);
    }

    var summing_queue_buffer : [MAX_NUM_OF_THREADS * 2]u64 = undefined;
    var summing_queue : std.Io.Queue(u64) = .init(&summing_queue_buffer);

    var future_summing = io.async(
        summing_thread,
        .{
            io,
            &summing_queue,
        },
    );

    var group : std.Io.Group = .init;
    for (0..(MAX_NUM_OF_THREADS - 1)) |i| {
        try group.concurrent(
            io,
            stat_thread,
            .{
                io,
                &AtomicFlags[i],
                &Strings[i],
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

        var index_to_write : ?usize = null;

        while (null == index_to_write) {
            for(AtomicFlags, 0..) |flag, i| {
                if (false == flag.load(.monotonic)) {
                    index_to_write = i;
                    break;
                }
            }
            if (index_to_write == null) {
                std.Thread.yield() catch {};
            }
        }

        std.mem.copyForwards(u8, &Strings_Backing_Buffers[index_to_write.?], entry.path);
        Strings[index_to_write.?] = Strings_Backing_Buffers[index_to_write.?][0..entry.path.len];
        AtomicFlags[index_to_write.?].store(true, .monotonic);
    }
    else |err| {
        std.debug.print("Error walking directory: {any}\n", .{ err });
        return err;
    }

    var ready_to_close_workers = false;
    while (!ready_to_close_workers) {
        ready_to_close_workers = true;
        for (AtomicFlags) |flag| {
            if (flag.load(.monotonic)) {
                ready_to_close_workers = false;
                break;
            }
        }
        if (!ready_to_close_workers) {
            std.Thread.yield() catch {};   // prevents ReleaseFast infinite spin
        }
    }

    group.cancel(io);
    try group.await(io);

    summing_queue.close(io);

    const memory_used, const number_of_files = future_summing.await(io);
    std.debug.print("The size of the dir is: {d} bytes\n", .{ memory_used });
    std.debug.print("The number of files found: {d} files\n", .{ number_of_files });

}



fn summing_thread(io : std.Io, queue : *std.Io.Queue(u64)) struct { u64, u64 } {
    var running_sum : u64 = 0;
    var number_of_files : u64 = 0;

    while (queue.getOne(io)) |val| {
        running_sum += val;
        number_of_files += 1;
    }
    else |err| {
        switch (err) {
            error.Canceled => return .{ 0, 0 },
            error.Closed => return .{ running_sum, number_of_files },
            else => unreachable,
        }
    }

    return .{ running_sum, number_of_files };
}

fn stat_thread(
    io: std.Io,
    flag: *std.atomic.Value(bool),
    path: *[]u8,
    queue: *std.Io.Queue(u64),
) std.Io.Cancelable!void {
    while (true) {
        try io.checkCancel();

        if (!flag.load(.monotonic)) {
            std.Thread.yield() catch |err| {
                if (err == error.Canceled) return error.Canceled;
            };
            continue;
        }

        // Copy the path immediately while we own the slot
        const current_path = path.*;
        defer flag.store(false, .monotonic);   // clear BEFORE any I/O

        const stat = std.Io.Dir.statFile(.cwd(), io, current_path, .{
            .follow_symlinks = false,
        }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            // Comment this out in production if you don't want spam
            // std.debug.print("stat error: {any} for {s}\n", .{ err, current_path });
            continue;
        };

        queue.putOne(io, stat.size) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            continue;
        };
    }
}
