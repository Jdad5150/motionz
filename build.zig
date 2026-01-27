const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const targets: []const std.Target.Query = &.{
        .{}, // Native
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu }, // Pi 4 64-bit
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf }, // Pi 4 32-bit
    };

    for (targets) |t| {
        const target = b.resolveTargetQuery(t);

        const exe = b.addExecutable(.{
            .name = "motionz",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const httpz = b.dependency("httpz", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("httpz", httpz.module("httpz"));

        const target_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = if (t.cpu_arch) |arch| @tagName(arch) else "native",
                },
            },
        });
        b.getInstallStep().dependOn(&target_output.step);
    }
}
