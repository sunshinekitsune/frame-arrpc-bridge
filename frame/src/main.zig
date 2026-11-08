const std = @import("std");
const ws = @import("websocket");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Steam Frame Bridge says hi\n");
}
