const std = @import("std");
const ws = @import("websocket");
const Config = @import("config.zig").Config;

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    mutex: std.Io.Mutex = .init,
    clients: std.AutoHashMap(*ws.Conn, void),
    activities: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) App {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .clients = std.AutoHashMap(*ws.Conn, void).init(allocator),
            .activities = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.activities.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.activities.deinit();
        self.clients.deinit();
    }

    pub fn addClient(self: *App, conn: *ws.Conn) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.clients.put(conn, {});
        std.log.info("Vesktop connected ({d} client{s})", .{
            self.clients.count(),
            if (self.clients.count() == 1) "" else "s",
        });

        // Replay cached presence to new client once handshake has flushed
        if (self.activities.count() > 0) {
            const CatchUp = struct {
                app: *App,
                c: *ws.Conn,

                fn run(ctx: @This()) void {
                    std.Io.sleep(ctx.app.io, std.Io.Duration.fromMilliseconds(15), .awake) catch {};

                    ctx.app.mutex.lockUncancelable(ctx.app.io);
                    defer ctx.app.mutex.unlock(ctx.app.io);

                    if (!ctx.app.clients.contains(ctx.c)) return;

                    var it = ctx.app.activities.valueIterator();
                    while (it.next()) |val| {
                        ctx.c.write(val.*) catch {};
                    }
                }
            };
            if (std.Thread.spawn(.{}, CatchUp.run, .{CatchUp{ .app = self, .c = conn }})) |thread| {
                thread.detach();
            } else |_| {}
        }
    }

    pub fn removeClient(self: *App, conn: *ws.Conn) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        _ = self.clients.remove(conn);
        std.log.info("Vesktop disconnected ({d} left)", .{self.clients.count()});
    }

    fn broadcastLocked(self: *App, text: []const u8) void {
        var it = self.clients.keyIterator();
        while (it.next()) |conn_ptr| {
            conn_ptr.*.write(text) catch {};
        }
    }

    pub fn onUpstreamMessage(self: *App, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Check if message updates or clears a socketId
        if (std.json.parseFromSlice(std.json.Value, arena.allocator(), text, .{}) catch null) |p| {
            if (p.value == .object) {
                const obj = p.value.object;
                if (obj.get("socketId")) |sid_val| {
                    var sid_buf: [64]u8 = undefined;
                    const sid = switch (sid_val) {
                        .string => |s| s,
                        .integer => |i| std.fmt.bufPrint(&sid_buf, "{d}", .{i}) catch null,
                        else => null,
                    };

                    if (sid) |id| {
                        const is_null = if (obj.get("activity")) |a| a == .null else true;
                        if (is_null) {
                            if (self.activities.fetchRemove(id)) |kv| {
                                self.allocator.free(kv.key);
                                self.allocator.free(kv.value);
                            }
                        } else {
                            if (self.activities.getEntry(id)) |entry| {
                                self.allocator.free(entry.value_ptr.*);
                                entry.value_ptr.* = try self.allocator.dupe(u8, text);
                            } else {
                                const k = try self.allocator.dupe(u8, id);
                                errdefer self.allocator.free(k);
                                const v = try self.allocator.dupe(u8, text);
                                try self.activities.put(k, v);
                            }
                        }
                    }
                }
            }
        }

        self.broadcastLocked(text);
    }

    pub fn clearActivities(self: *App) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.activities.count() == 0) return;

        std.log.info("Clearing {d} activities", .{self.activities.count()});
        self.broadcastLocked("{\"activity\":null}");

        var it = self.activities.keyIterator();
        while (it.next()) |k| {
            var buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{{\"activity\":null,\"socketId\":\"{s}\"}}", .{k.*})) |msg| {
                self.broadcastLocked(msg);
            } else |_| {}
        }

        var entry_it = self.activities.iterator();
        while (entry_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.activities.clearRetainingCapacity();
    }
};

pub const LocalHandler = struct {
    app: *App,
    conn: *ws.Conn,

    pub fn init(_: *ws.Handshake, conn: *ws.Conn, app: *App) !LocalHandler {
        try app.addClient(conn);
        return .{ .app = app, .conn = conn };
    }
    pub fn clientMessage(_: *LocalHandler, _: []const u8) !void {}
    pub fn close(self: *LocalHandler) void {
        self.app.removeClient(self.conn);
    }
};
