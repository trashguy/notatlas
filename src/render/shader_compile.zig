//! Runtime glslc subprocess for M2.6 hot-reload. build.zig still does the
//! same compile once at build time so release builds don't depend on
//! `glslc` being on the path; this module is only used after the sandbox
//! is already running and an editor save has fired through inotify.
//!
//! The SPIR-V is written to a per-pid tempfile and read back into a
//! 4-byte-aligned buffer so it can be handed straight to
//! `shader_mod.fromSpv`.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{
    GlslCompileFailed,
    InvalidSpirv,
};

/// Compiles `src_path` (relative to cwd) with the same flags the build
/// script uses, returns 4-byte-aligned SPIR-V owned by `allocator`.
/// On compile failure, prints glslc's stderr and returns
/// `error.GlslCompileFailed` — caller should keep the old pipeline.
pub fn compileGlsl(
    allocator: Allocator,
    src_path: []const u8,
    label: []const u8,
) ![]align(4) u8 {
    const pid = std.os.linux.getpid();
    const tmp_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/notatlas-{s}-{d}.spv",
        .{ label, pid },
    );
    defer allocator.free(tmp_path);

    const run_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "glslc",
            "--target-env=vulkan1.3",
            "-O",
            src_path,
            "-o",
            tmp_path,
        },
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const failed = switch (run_result.term) {
        .Exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.log.err("glslc {s}: compile failed\n{s}", .{ label, run_result.stderr });
        return Error.GlslCompileFailed;
    }

    var f = std.fs.openFileAbsolute(tmp_path, .{}) catch |err| {
        std.log.err("glslc {s}: cannot open output {s}: {s}", .{ label, tmp_path, @errorName(err) });
        return Error.GlslCompileFailed;
    };
    defer {
        f.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
    }

    const stat = try f.stat();
    const size: usize = @intCast(stat.size);
    if (size == 0 or size % 4 != 0) return Error.InvalidSpirv;

    const buf = try allocator.alignedAlloc(u8, .@"4", size);
    errdefer allocator.free(buf);

    var read_total: usize = 0;
    while (read_total < size) {
        const n = try f.read(buf[read_total..]);
        if (n == 0) return Error.InvalidSpirv;
        read_total += n;
    }
    return buf;
}
