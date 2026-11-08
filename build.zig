const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ws_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const frame_exe = b.addExecutable(.{
        .name = "frame-arrpc-bridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("frame/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    frame_exe.root_module.addImport("websocket", ws_dep.module("websocket"));
    b.installArtifact(frame_exe);

    const frame_step = b.step("frame", "Build the Steam Frame bridge daemon");
    frame_step.dependOn(&b.addInstallArtifact(frame_exe, .{}).step);
}
