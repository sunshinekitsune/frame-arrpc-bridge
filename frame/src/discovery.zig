const std = @import("std");

/// Discovers the active vrlink UDP streaming peer.
/// If `preferred` is provided and remains active among the detected peers, it is retained.
pub fn findStreamPeer(
    allocator: std.mem.Allocator,
    io: std.Io,
    process: []const u8,
    preferred: ?[]const u8,
) !?[]const u8 {
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

    var first_candidate: ?[]const u8 = null;
    defer if (first_candidate) |fc| allocator.free(fc);

    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "ESTAB") == null) continue;
        if (std.mem.indexOf(u8, line, process) == null) continue;

        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        var estab_seen = false;
        var peer_col: ?[]const u8 = null;
        var col_after_estab: usize = 0;

        // ss columns after ESTAB:
        // 1: Recv-Q, 2: Send-Q, 3: Local Address:Port, 4: Peer Address:Port
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
                // If this matches our current active target, keep it (peer affinity)
                if (preferred) |pref| {
                    if (std.mem.eql(u8, ip, pref)) {
                        return try allocator.dupe(u8, ip);
                    }
                }

                // Otherwise save the first valid local streaming candidate
                if (first_candidate == null) {
                    first_candidate = try allocator.dupe(u8, ip);
                }
            }
        }
    }

    if (first_candidate) |fc| {
        const ret = try allocator.dupe(u8, fc);
        return ret;
    }

    return null;
}

fn parsePeerAddress(raw: []const u8) ?[]const u8 {
    const last_colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return null;

    // Filter out port 443 (Discord/telemetry QUIC/HTTPS), port 80, 53
    const port_str = raw[last_colon + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch 0;
    if (port == 443 or port == 80 or port == 53) return null;

    var host = raw[0..last_colon];

    if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]")) {
        host = host[1 .. host.len - 1];
    }
    if (std.mem.startsWith(u8, host, "::ffff:")) {
        host = host[7..];
    }

    // Ignore unspecified and loopback
    if (std.mem.eql(u8, host, "*") or
        std.mem.startsWith(u8, host, "127.") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "0.0.0.0") or
        std.mem.eql(u8, host, "::"))
    {
        return null;
    }

    // Must be a private LAN or link-local address
    if (!isPrivateOrLocal(host)) {
        return null;
    }

    return if (host.len > 0) host else null;
}

fn isPrivateOrLocal(host: []const u8) bool {
    // 10.0.0.0/8, 192.168.0.0/16, 169.254.0.0/16
    if (std.mem.startsWith(u8, host, "10.") or
        std.mem.startsWith(u8, host, "192.168.") or
        std.mem.startsWith(u8, host, "169.254."))
    {
        return true;
    }

    // 172.16.0.0/12 (172.16.x.x - 172.31.x.x)
    if (std.mem.startsWith(u8, host, "172.")) {
        var it = std.mem.splitScalar(u8, host, '.');
        _ = it.next(); // 172
        if (it.next()) |second| {
            if (std.fmt.parseInt(u8, second, 10)) |val| {
                if (val >= 16 and val <= 31) return true;
            } else |_| {}
        }
    }

    // IPv6 Unique Local (fc00::/7) or Link-Local (fe80::/10)
    if (std.ascii.startsWithIgnoreCase(host, "fe80:") or
        std.ascii.startsWithIgnoreCase(host, "fd") or
        std.ascii.startsWithIgnoreCase(host, "fc"))
    {
        return true;
    }

    return false;
}
