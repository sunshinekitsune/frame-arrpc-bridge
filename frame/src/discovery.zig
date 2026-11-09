const std = @import("std");

pub fn findStreamPeer(allocator: std.mem.Allocator, io: std.Io, process: []const u8) !?[]const u8 {
    const res = std.process.run(allocator, io, .{
        .argv = &.{ "ss", "-nuap" },
        .stdout_limit = .limited(64 * 1024),
    }) catch |err| {
        std.log.warn("cannot run 'ss -nuap': {s}", .{@errorName(err)});
        return null;
    };
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "ESTAB") == null) continue;
        if (std.mem.indexOf(u8, line, process) == null) continue;

        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        var estab_seen = false;
        var peer_col: ?[]const u8 = null;
        var col_after_estab: usize = 0;

        // ss columns after ESTAB
        // 1 Recv-Q
        // 2 Send-Q
        // 3 Local
        // 4 Peer
        while (it.next()) |tok| {
            if (!estab_seen) {
                if (std.mem.eql(u8, tok, "ESTAB")) estab_seen = true;
                continue;
            }
            col_after_estab += 1;

            if (col_after_estab == 4) {
                peer_col = tok;
                break;
            }
        }

        if (peer_col) |raw| {
            if (parsePeerAddress(raw)) |ip| {
                return try allocator.dupe(u8, ip);
            }
        }
    }
    return null;
}

fn parsePeerAddress(raw: []const u8) ?[]const u8 {
    const last_colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return null;
    var host = raw[0..last_colon];

    if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]")) {
        host = host[1 .. host.len - 1];
    }
    if (std.mem.startsWith(u8, host, "::ffff:")) {
        host = host[7..];
    }

    // Ignore unspecified and loopback addresses
    if (std.mem.eql(u8, host, "*") or
        std.mem.startsWith(u8, host, "127.") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "0.0.0.0") or
        std.mem.eql(u8, host, "::"))
    {
        return null;
    }

    return if (host.len > 0) host else null;
}
