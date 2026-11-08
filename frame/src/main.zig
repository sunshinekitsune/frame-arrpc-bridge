const std = @import("std");
const ws = @import("websocket");

const app_name = "frame-arrpc-bridge";

const Config = struct {
    port: u16 = 1337,
};

pub fn main(init: std.process.Init) !void {
    const config = try loadConfig(init);
    std.log.info("Steam Frame Bridge says hi (port {d})", .{config.port});

    while (true) {
        try std.Io.sleep(init.io, std.Io.Duration.fromSeconds(3600), .awake);
    }
}

fn loadConfig(init: std.process.Init) !Config {
    const gpa = init.gpa;
    const path = if (init.environ_map.get("XDG_CONFIG_HOME")) |dir|
        try std.fmt.allocPrint(gpa, "{s}/{s}/config.json", .{ dir, app_name })
    else if (init.environ_map.get("HOME")) |home|
        try std.fmt.allocPrint(gpa, "{s}/.config/{s}/config.json", .{ home, app_name })
    else
        return .{};
    defer gpa.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("no config at {s}, using defaults", .{path});
            return .{};
        },
        else => {
            std.log.err("can't read {s}: {s}", .{ path, @errorName(err) });
            return err;
        },
    };
    defer gpa.free(data);

    const parsed = std.json.parseFromSlice(Config, gpa, data, .{}) catch |err| {
        std.log.err("invalid config {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer parsed.deinit();
    return parsed.value;
}
