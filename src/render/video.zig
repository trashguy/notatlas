//! In-app video capture: read back the swapchain image each frame, pipe
//! BGRA bytes to a ffmpeg subprocess that h264-encodes to mp4. Built for
//! diagnosing TEMPORAL visual bugs (the waterline-flicker hunt at M14)
//! where RenderDoc's single-frame model isn't enough.
//!
//! Sync model:
//! - One host-visible staging buffer (W*H*4 bytes), persistently mapped.
//! - Copy commands ride inside the existing render command buffer,
//!   between `vkCmdEndRenderPass` and `vkEndCommandBuffer` — no extra
//!   submit, no extra fence.
//! - Frame N's bytes are written to ffmpeg stdin at the TOP of frame
//!   N+1's draw, after `vkWaitForFences(in_flight)` confirms the GPU is
//!   done. One-frame latency.
//! - On deinit: flush the last pending frame, close stdin (signals EOF
//!   to ffmpeg), wait for the encoder to finalize the mp4.
//!
//! Swapchain format assumption: BGRA8 byte layout. We accept both
//! `B8G8R8A8_UNORM` and `B8G8R8A8_SRGB` — the byte layout is identical;
//! the difference is gamma encoding, and we want the gamma-encoded
//! pixels (that's what hits the display, so that's what should hit the
//! video). Other formats return `Error.UnsupportedFormat`.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");

const vk = types.vk;

pub const Error = error{
    UnsupportedFormat,
    FfmpegSpawnFailed,
    FfmpegWriteFailed,
};

pub const Video = struct {
    gpa: std.mem.Allocator,
    extent: vk.VkExtent2D,
    bytes_per_frame: u64,

    staging: buffer_mod.Buffer,

    child: std.process.Child,
    has_pending: bool,

    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *const gpu_mod.GpuContext,
        extent: vk.VkExtent2D,
        format: vk.VkFormat,
        path: []const u8,
        framerate: u32,
    ) !Video {
        if (format != vk.VK_FORMAT_B8G8R8A8_UNORM and format != vk.VK_FORMAT_B8G8R8A8_SRGB)
            return Error.UnsupportedFormat;

        const bytes_per_frame: u64 = @as(u64, extent.width) * @as(u64, extent.height) * 4;

        var staging = try buffer_mod.Buffer.init(
            gpu,
            bytes_per_frame,
            vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );
        errdefer staging.deinit();
        std.debug.assert(staging.mapped.len == bytes_per_frame);

        const size_str = try std.fmt.allocPrint(gpa, "{d}x{d}", .{ extent.width, extent.height });
        defer gpa.free(size_str);
        const fps_str = try std.fmt.allocPrint(gpa, "{d}", .{framerate});
        defer gpa.free(fps_str);

        const argv = [_][]const u8{
            "ffmpeg",
            "-y",
            "-f",            "rawvideo",
            "-pixel_format", "bgra",
            "-video_size",   size_str,
            "-framerate",    fps_str,
            "-i",            "-",
            "-c:v",          "libx264",
            "-pix_fmt",      "yuv420p",
            "-preset",       "ultrafast",
            "-loglevel",     "warning",
            path,
        };

        var child = std.process.Child.init(&argv, gpa);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch |err| {
            std.log.err("video: ffmpeg spawn failed: {s}", .{@errorName(err)});
            return Error.FfmpegSpawnFailed;
        };

        std.log.info("video: {d}x{d} @ {d}fps -> {s}", .{ extent.width, extent.height, framerate, path });

        return .{
            .gpa = gpa,
            .extent = extent,
            .bytes_per_frame = bytes_per_frame,
            .staging = staging,
            .child = child,
            .has_pending = false,
        };
    }

    pub fn deinit(self: *Video) void {
        if (self.has_pending) {
            self.writePendingToFfmpeg() catch |err| {
                std.log.warn("video: final frame write failed: {s}", .{@errorName(err)});
            };
            self.has_pending = false;
        }

        if (self.child.stdin) |*stdin| {
            stdin.close();
            self.child.stdin = null;
        }
        const term = self.child.wait() catch |err| {
            std.log.warn("video: ffmpeg wait failed: {s}", .{@errorName(err)});
            self.staging.deinit();
            return;
        };
        switch (term) {
            .Exited => |code| if (code != 0) std.log.warn("video: ffmpeg exited {d}", .{code}),
            .Signal => |sig| std.log.warn("video: ffmpeg killed by signal {d}", .{sig}),
            .Stopped => |sig| std.log.warn("video: ffmpeg stopped by signal {d}", .{sig}),
            .Unknown => |code| std.log.warn("video: ffmpeg terminated unknown {d}", .{code}),
        }

        self.staging.deinit();
    }

    /// Insert the swapchain→staging readback into `cb`. Must be called
    /// AFTER `vkCmdEndRenderPass` and BEFORE `vkEndCommandBuffer`. The
    /// image enters in `PRESENT_SRC_KHR` (the render-pass finalLayout)
    /// and is restored to `PRESENT_SRC_KHR` so the subsequent present
    /// works unchanged.
    pub fn recordCopy(self: *Video, cb: vk.VkCommandBuffer, image: vk.VkImage) void {
        const to_src = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        vk.vkCmdPipelineBarrier(
            cb,
            vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &to_src,
        );

        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
        };
        vk.vkCmdCopyImageToBuffer(
            cb,
            image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.staging.handle,
            1,
            &region,
        );

        const to_present = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_READ_BIT,
            .dstAccessMask = 0,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        vk.vkCmdPipelineBarrier(
            cb,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &to_present,
        );

        self.has_pending = true;
    }

    /// Call at the TOP of `Frame.draw`, after `vkWaitForFences(in_flight)`.
    /// The previous frame's copy is observably complete at that point, so
    /// the host-coherent staging map is safe to read.
    pub fn flushPendingFrame(self: *Video) !void {
        if (!self.has_pending) return;
        try self.writePendingToFfmpeg();
        self.has_pending = false;
    }

    fn writePendingToFfmpeg(self: *Video) !void {
        const stdin = self.child.stdin orelse return Error.FfmpegWriteFailed;
        stdin.writeAll(self.staging.mapped) catch return Error.FfmpegWriteFailed;
    }
};
