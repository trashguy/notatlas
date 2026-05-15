//! Persistent VkPipelineCache for AAA-style first-frame stutter elimination.
//!
//! Loads the cache blob from `$XDG_CACHE_HOME/notatlas/pipeline_cache.bin` (or
//! `$HOME/.cache/notatlas/pipeline_cache.bin` if XDG_CACHE_HOME is unset) on
//! init, validates the 32-byte VkPipelineCacheHeaderVersionOne against the
//! current physical device's vendor / device / UUID, and discards on mismatch
//! (driver upgrade or different GPU). Saves back atomically (write to .tmp +
//! rename) on shutdown.
//!
//! On Windows the cache lives under `%LOCALAPPDATA%\notatlas\pipeline_cache.bin`.
//! No fallback if neither env var is set — the cache is silently skipped.

const std = @import("std");
const builtin = @import("builtin");

const types = @import("vulkan_types.zig");
const vk = types.vk;
const VulkanError = types.VulkanError;

const dir_segment = "notatlas";
const cache_filename = "pipeline_cache.bin";

fn getEnvOpt(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(gpa, name) catch null;
}

/// Returns the absolute cache directory path; caller frees. Returns null if
/// no suitable env var is available (cache then becomes a no-op).
fn cacheDir(gpa: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag == .windows) {
        if (getEnvOpt(gpa, "LOCALAPPDATA")) |base| {
            defer gpa.free(base);
            return std.fs.path.join(gpa, &.{ base, dir_segment }) catch null;
        }
        return null;
    }
    if (getEnvOpt(gpa, "XDG_CACHE_HOME")) |base| {
        defer gpa.free(base);
        return std.fs.path.join(gpa, &.{ base, dir_segment }) catch null;
    }
    if (getEnvOpt(gpa, "HOME")) |home| {
        defer gpa.free(home);
        return std.fs.path.join(gpa, &.{ home, ".cache", dir_segment }) catch null;
    }
    return null;
}

fn cachePath(gpa: std.mem.Allocator) ?[]u8 {
    const dir = cacheDir(gpa) orelse return null;
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, cache_filename }) catch null;
}

/// VkPipelineCacheHeaderVersionOne layout (Vulkan spec, 32 bytes):
///   u32 headerSize       (must be 32)
///   u32 headerVersion    (must be VK_PIPELINE_CACHE_HEADER_VERSION_ONE = 1)
///   u32 vendorID
///   u32 deviceID
///   u8[VK_UUID_SIZE=16]  pipelineCacheUUID
fn blobMatchesDevice(blob: []const u8, props: *const vk.VkPhysicalDeviceProperties) bool {
    if (blob.len < 32) return false;
    const header_size = std.mem.readInt(u32, blob[0..4], .little);
    const header_version = std.mem.readInt(u32, blob[4..8], .little);
    const vendor_id = std.mem.readInt(u32, blob[8..12], .little);
    const device_id = std.mem.readInt(u32, blob[12..16], .little);
    if (header_size != 32) return false;
    if (header_version != vk.VK_PIPELINE_CACHE_HEADER_VERSION_ONE) return false;
    if (vendor_id != props.vendorID) return false;
    if (device_id != props.deviceID) return false;
    if (!std.mem.eql(u8, blob[16..32], props.pipelineCacheUUID[0..16])) return false;
    return true;
}

fn loadBlob(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const stat = f.stat() catch return null;
    const size: usize = @intCast(stat.size);
    if (size == 0 or size > 256 * 1024 * 1024) return null;
    const buf = gpa.alloc(u8, size) catch return null;
    var read_total: usize = 0;
    while (read_total < size) {
        const n = f.read(buf[read_total..]) catch {
            gpa.free(buf);
            return null;
        };
        if (n == 0) break;
        read_total += n;
    }
    if (read_total != size) {
        gpa.free(buf);
        return null;
    }
    return buf;
}

pub fn init(
    gpa: std.mem.Allocator,
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
) !vk.VkPipelineCache {
    var props: vk.VkPhysicalDeviceProperties = undefined;
    vk.vkGetPhysicalDeviceProperties(physical_device, &props);

    var initial_data: ?[]u8 = null;
    defer if (initial_data) |d| gpa.free(d);

    if (cachePath(gpa)) |path| {
        defer gpa.free(path);
        if (loadBlob(gpa, path)) |buf| {
            if (blobMatchesDevice(buf, &props)) {
                initial_data = buf;
            } else {
                gpa.free(buf);
                std.log.info("pipeline cache: discarded stale blob (driver/device mismatch)", .{});
            }
        }
    }

    const ci = vk.VkPipelineCacheCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .initialDataSize = if (initial_data) |d| d.len else 0,
        .pInitialData = if (initial_data) |d| @ptrCast(d.ptr) else null,
    };
    var cache: vk.VkPipelineCache = undefined;
    try types.check(
        vk.vkCreatePipelineCache(device, &ci, null, &cache),
        VulkanError.PipelineCreationFailed,
    );

    if (initial_data) |d| {
        std.log.info("pipeline cache: loaded {d} bytes", .{d.len});
    } else {
        std.log.info("pipeline cache: starting empty", .{});
    }
    return cache;
}

pub fn save(
    gpa: std.mem.Allocator,
    device: vk.VkDevice,
    cache: vk.VkPipelineCache,
) void {
    var size: usize = 0;
    if (vk.vkGetPipelineCacheData(device, cache, &size, null) != vk.VK_SUCCESS or size == 0) return;

    const buf = gpa.alloc(u8, size) catch return;
    defer gpa.free(buf);
    if (vk.vkGetPipelineCacheData(device, cache, &size, @ptrCast(buf.ptr)) != vk.VK_SUCCESS) return;

    const dir = cacheDir(gpa) orelse return;
    defer gpa.free(dir);
    std.fs.cwd().makePath(dir) catch return;

    const path = cachePath(gpa) orelse return;
    defer gpa.free(path);
    const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{path}) catch return;
    defer gpa.free(tmp);

    {
        var f = std.fs.createFileAbsolute(tmp, .{ .truncate = true }) catch return;
        defer f.close();
        f.writeAll(buf[0..size]) catch return;
    }
    std.fs.renameAbsolute(tmp, path) catch {
        std.fs.deleteFileAbsolute(tmp) catch {};
        return;
    };
    std.log.info("pipeline cache: saved {d} bytes", .{size});
}

pub fn deinit(device: vk.VkDevice, cache: vk.VkPipelineCache) void {
    vk.vkDestroyPipelineCache(device, cache, null);
}
