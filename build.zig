const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_zutl = b.dependency("zutl", .{
        .target = target,
        .optimize = optimize,
    });
    const mod_zutl = dep_zutl.module("zutl_all");

    const exe = b.addExecutable(.{
        .name = "zigdirstat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zutl", .module = mod_zutl },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const installDir_docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const step_docs = b.step("docs", "Generate HTML documentation from the doc comments");
    step_docs.dependOn(&installDir_docs.step);
    step_docs.dependOn(b.getInstallStep());

    const step_publish = b.step("publish", "Copys the production version of this binay (size optimized unless otherwise stated) to `~/.local/bin`");
    const exe_publish = b.addExecutable(.{
        .name = "zds", 
        .root_module = b.createModule(.{
            .target = target,
            .optimize = blk: {
                switch (optimize) {
                    .debug, .small => break :blk .small,
                    .fast => break :blk .fast,
                    .safe => break :blk .safe,
                    else => unreachable,
                }
            },
            .imports = &.{
                .{ .name = "zutl", .module = mod_zutl },
            },
        })
    });
    b.addInstallArtifact(exe_publish, .{})
}
