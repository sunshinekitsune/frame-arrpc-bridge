const std = @import("std");
const ws = @import("websocket");
const config = @import("config.zig");
const state = @import("state.zig");
const relay = @import("relay.zig");

var global_server: ?*ws.Server(state.LocalHandler) = null;
var running: std.atomic.Value(bool) = .init(true);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    running.store(false, .seq_cst);
    if (global_server) |s| {
        s.stop();
    }
}

pub fn main(init: std.process.Init) !void {
    var cfg_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer cfg_arena.deinit();

    const cfg = config.load(init, cfg_arena.allocator());

    // Register signal handlers for systemd shutdown
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);

    var app = state.App.init(init.gpa, init.io, cfg);
    defer app.deinit();

    var server = try ws.Server(state.LocalHandler).init(init.io, init.gpa, .{
        .port = cfg.webrichpresence_port,
        .address = "127.0.0.1",
        .handshake = .{ .timeout = 3, .max_size = 1024, .max_headers = 0 },
    });
    defer server.deinit();

    global_server = &server;
    defer global_server = null;

    std.log.info("Listening on 127.0.0.1:{d}", .{cfg.webrichpresence_port});
    if (cfg.remote_host_override) |override| {
        std.log.info("Remote host override: {s}:{d}", .{ override, cfg.remote_arrpc_port });
    }

    const worker = try std.Thread.spawn(.{}, relay.supervisorWorker, .{ &app, &server, &running });

    server.listen(&app) catch |err| {
        std.log.err("server.listen error: {s}", .{@errorName(err)});
    };

    running.store(false, .seq_cst);
    worker.join();

    std.log.info("Daemon exited cleanly", .{});
}
