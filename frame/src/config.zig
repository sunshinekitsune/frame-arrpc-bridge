const std = @import("std");

pub const Config = struct {
    webrichpresence_port: u16 = 1337,
    remote_arrpc_port: u16 = 1337,
    remote_host_override: ?[]const u8 = null,
    poll_interval_s: u32 = 6,
};

pub fn load(init: std.process.Init, arena: std.mem.Allocator) Config {
    const default_cfg = Config{};
    const path = if (init.environ_map.get("XDG_CONFIG_HOME")) |dir|
        std.fmt.allocPrint(arena, "{s}/frame-arrpc-bridge/config.json", .{dir}) catch return default_cfg
    else if (init.environ_map.get("HOME")) |home|
        std.fmt.allocPrint(arena, "{s}/.config/frame-arrpc-bridge/config.json", .{home}) catch return default_cfg
    else
        return default_cfg;

    const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(64 * 1024)) catch |err| {
        if (err != error.FileNotFound) {
            std.log.err("failed to read config {s}: {s}", .{ path, @errorName(err) });
        }
        return default_cfg;
    };

    const parsed = std.json.parseFromSlice(Config, arena, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("invalid config {s}: {s}", .{ path, @errorName(err) });
        return default_cfg;
    };

    return parsed.value;
}
