//! M14.1 smoke binary: open a KTX2 file, print metadata, exit non-zero
//! on any libktx error. Lowest-level proof that the libktx vendoring +
//! thin C binding round-trip works without any Vulkan integration.
//!
//! Usage:
//!   m14-ktx-dump <path/to/foo.ktx2>
//!
//! Output is plaintext key=value lines (one per field) plus a final
//! "OK" sentinel on success — easy to grep in `scripts/m14_gate_smoke.sh`.

const std = @import("std");
const ktx = @import("ktx");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.debug.print("usage: {s} <ktx2-file>\n", .{args[0]});
        std.process.exit(2);
    }

    const path = try allocator.dupeZ(u8, args[1]);

    var tex = ktx.Texture2.fromFile(path, .{}) catch |err| {
        std.debug.print("error: failed to open {s}: {s}\n", .{ args[1], @errorName(err) });
        std.process.exit(1);
    };
    defer tex.deinit();

    std.debug.print("path={s}\n", .{args[1]});
    std.debug.print("width={d}\n", .{tex.width()});
    std.debug.print("height={d}\n", .{tex.height()});
    std.debug.print("depth={d}\n", .{tex.depth()});
    std.debug.print("vk_format={d}\n", .{tex.vkFormat()});
    std.debug.print("levels={d}\n", .{tex.numLevels()});
    std.debug.print("layers={d}\n", .{tex.numLayers()});
    std.debug.print("faces={d}\n", .{tex.numFaces()});
    std.debug.print("data_size={d}\n", .{tex.dataSize()});
    std.debug.print("needs_transcode={s}\n", .{if (tex.needsTranscode()) "true" else "false"});
    std.debug.print("OK\n", .{});
}
