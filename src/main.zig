const std = @import("std");

var total_size = std.atomic.Value(u64).init(0);
var active_workers = std.atomic.Value(u32).init(0); // for clean shutdown

// Shared queue + protection
var arena: std.heap.ArenaAllocator = undefined;
var dir_queue : std.ArrayList([]const u8) = .empty; // will be re-assigned
var queue_mutex = std.Io.Mutex.init;
const MAX_WORKERS = 16; // bump this — IO-bound loves high concurrency on SSD

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // One arena for ALL path strings in the entire scan
    arena = init.arena.*;
    const path_alloc = arena.allocator();

    // Pre-size for a huge filesystem (adjust as you like)
    //dir_queue = std.ArrayList([]const u8).init(allocator);
    try dir_queue.ensureTotalCapacity(path_alloc, 131072); // 128k directories is plenty for most machines
    //defer dir_queue.deinit(path_alloc);

    // Seed the queue with root
    {
        try queue_mutex.lock(io);
        defer queue_mutex.unlock(io);
        const root = try path_alloc.dupe(u8, ".");
        dir_queue.appendAssumeCapacity(root);
    }

    var group: std.Io.Group = .init;

    for (0..MAX_WORKERS) |_| {
        try group.concurrent(
            io, 
            worker, 
            .{
                io,
                path_alloc,
            },
        );
    }

    // Workers will run until queue is empty + all work done
    try group.await(io);

    std.debug.print("The size of the dir is: {d} bytes\n", .{total_size.load(.monotonic)});
}

fn worker(io: std.Io, path_alloc: std.mem.Allocator) std.Io.Cancelable!void {
    _ = active_workers.fetchAdd(1, .monotonic);
    defer _ = active_workers.fetchSub(1, .monotonic);

    // If the threads fire fast enough, we don't want them seeing the empty
    // queue and closing the thread
    var counter : u8 = 25;

    while (true) {
        try io.checkCancel();

        if (0 == dir_queue.items.len) {
            counter -= 1;
            if (0 == counter) {
                return;
            }
            std.Thread.yield() catch {};
            continue;
        }
        else {
            counter = 25;
        }

        const dir_path : []const u8 = blk: {
            try queue_mutex.lock(io);
            defer queue_mutex.unlock(io);

            const path = dir_queue.pop() orelse continue;
            break :blk path;
        };

        // === PROCESS THIS DIRECTORY ===
        const dir = std.Io.Dir.openDir(.cwd(), io, dir_path, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            continue;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io)) |nullable_entry| {
            const entry = nullable_entry orelse break;
            switch (entry.kind) {
                .file => {
                    const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
                    _ = total_size.fetchAdd(stat.size, .monotonic);
                },
                .directory => {
                    // Enqueue sub-directory (arena allocation is basically free)
                    const sub_path = std.fs.path.join(path_alloc, &.{ dir_path, entry.name }) catch continue;

                    try queue_mutex.lock(io);
                    defer queue_mutex.unlock(io);
                    dir_queue.appendAssumeCapacity(sub_path); // fast because of pre-capacity + arena
                },
                else => {},
            }
        }
        else |err| {
            if (error.Canceled == err) return error.Canceled;
            return;
        }
    }
}
