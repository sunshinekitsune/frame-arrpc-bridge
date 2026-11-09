const std = @import("std");
const ws = @import("websocket");
const App = @import("state.zig").App;
const LocalHandler = @import("state.zig").LocalHandler;
const discovery = @import("discovery.zig");

const STREAM_PROCESS = "vrlink";

pub fn supervisorWorker(
    app: *App,
    server: *ws.Server(LocalHandler),
    running: *std.atomic.Value(bool),
) void {
    var current_target: ?[]const u8 = null;
    defer if (current_target) |ct| app.allocator.free(ct);

    var delay_s: u32 = 1;
    var quiet = false;

    while (running.load(.seq_cst)) {
        const target_ip: ?[]const u8 = if (app.config.remote_host_override) |override|
            app.allocator.dupe(u8, override) catch null
        else
            discovery.findStreamPeer(app.allocator, app.io, STREAM_PROCESS) catch null;

        defer if (target_ip) |ip| app.allocator.free(ip);

        // Check if peer changed
        const target_changed = blk: {
            if (target_ip == null and current_target == null) break :blk false;
            if (target_ip != null and current_target != null) {
                break :blk !std.mem.eql(u8, target_ip.?, current_target.?);
            }
            break :blk true;
        };

        if (target_changed) {
            if (current_target) |ct| {
                std.log.info("Stream to {s} ended", .{ct});
                app.allocator.free(ct);
                current_target = null;
                app.clearActivities();
            }
            if (target_ip) |tip| {
                std.log.info("Stream to {s} detected", .{tip});
                current_target = app.allocator.dupe(u8, tip) catch null;
                delay_s = 1;
                quiet = false;
            }
        }

        if (current_target) |ip| {
            var live = false;
            relaySession(app, ip, app.config.remote_arrpc_port, running, &live, &quiet) catch |err| {
                const reason = @errorName(err);
                if (live) {
                    std.log.warn("Lost arRPC at {s}:{d}: {s}", .{ ip, app.config.remote_arrpc_port, reason });
                } else if (!quiet) {
                    std.log.warn("Cannot reach arRPC at {s}:{d}: {s}", .{ ip, app.config.remote_arrpc_port, reason });
                    quiet = true;
                }
            };

            if (live) {
                app.clearActivities();
                delay_s = 1;
            } else {
                delay_s = @min(delay_s * 2, 15);
            }

            sleepInterruptible(app.io, running, delay_s);
        } else {
            sleepInterruptible(app.io, running, app.config.poll_interval_s);
        }
    }

    server.stop();
}

fn relaySession(
    app: *App,
    ip: []const u8,
    port: u16,
    running: *std.atomic.Value(bool),
    live: *bool,
    quiet: *bool,
) !void {
    var client = try ws.Client.init(app.io, app.allocator, .{
        .port = port,
        .host = ip,
        .max_size = 1024 * 1024,
    });
    defer client.deinit();

    const host_hdr = if (std.mem.indexOfScalar(u8, ip, ':') != null)
        try std.fmt.allocPrint(app.allocator, "Host: [{s}]:{d}", .{ ip, port })
    else
        try std.fmt.allocPrint(app.allocator, "Host: {s}:{d}", .{ ip, port });
    defer app.allocator.free(host_hdr);

    try client.handshake("/", .{
        .timeout_ms = 2000,
        .headers = host_hdr,
    });

    live.* = true;
    quiet.* = false;
    std.log.info("Connected to arRPC at {s}:{d}", .{ ip, port });

    const poll_ms = app.config.poll_interval_s * 1000;
    const read_timeout_ms: u32 = @min(1000, @max(250, poll_ms / 2));
    try client.readTimeout(read_timeout_ms);

    var elapsed_poll_ms: u32 = 0;

    while (running.load(.seq_cst)) {
        const message = (try client.read()) orelse {
            // Read tick expired without data. Check shutdown flag immediately.
            if (!running.load(.seq_cst)) return;

            elapsed_poll_ms += read_timeout_ms;
            if (elapsed_poll_ms >= poll_ms) {
                elapsed_poll_ms = 0;

                // If vrlink discovery, verify stream is still up
                if (app.config.remote_host_override == null) {
                    const current_peer = discovery.findStreamPeer(app.allocator, app.io, STREAM_PROCESS) catch null;
                    defer if (current_peer) |p| app.allocator.free(p);

                    if (current_peer == null or !std.mem.eql(u8, current_peer.?, ip)) {
                        std.log.info("vrlink stream ended", .{});
                        return;
                    }
                }
            }
            continue;
        };
        defer client.done(message);

        // Active game RPC traffic confirms the connection is alive; reset timer
        elapsed_poll_ms = 0;

        switch (message.type) {
            .text => try app.onUpstreamMessage(message.data),
            .close => return error.ConnectionClosed,
            .ping => try client.writePong(message.data),
            else => {},
        }
    }
}

fn sleepInterruptible(io: std.Io, running: *std.atomic.Value(bool), seconds: u32) void {
    const total_ms = seconds * 1000;
    var elapsed: u32 = 0;
    while (elapsed < total_ms and running.load(.seq_cst)) {
        const chunk = @min(250, total_ms - elapsed);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(chunk), .awake) catch {};
        elapsed += chunk;
    }
}
