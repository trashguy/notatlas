//! Vertex layout + GPU mesh holder + tessellated plane generator.
//!
//! Vertex is position-only: M2.4 will displace it in the vertex shader using
//! the GLSL port of `waveDisplacement`, so a CPU-side normal would just be
//! discarded. M2.5's foam needs a normal too, but it's analytic from
//! `waveNormal` and computed in the fragment shader, not stored on vertices.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

pub const Vertex = extern struct {
    pos: [3]f32,

    pub const binding_description: vk.VkVertexInputBindingDescription = .{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
    };

    pub const attribute_descriptions = [_]vk.VkVertexInputAttributeDescription{
        .{
            .location = 0,
            .binding = 0,
            .format = vk.VK_FORMAT_R32G32B32_SFLOAT,
            .offset = @offsetOf(Vertex, "pos"),
        },
    };
};

pub const Mesh = struct {
    vertex_buffer: buffer_mod.Buffer,
    index_buffer: buffer_mod.Buffer,
    index_count: u32,

    pub fn deinit(self: *Mesh) void {
        self.vertex_buffer.deinit();
        self.index_buffer.deinit();
    }

    pub fn bindAndDraw(self: *Mesh, cb: vk.VkCommandBuffer) void {
        const vb = [_]vk.VkBuffer{self.vertex_buffer.handle};
        const offsets = [_]vk.VkDeviceSize{0};
        vk.vkCmdBindVertexBuffers(cb, 0, 1, &vb, &offsets);
        vk.vkCmdBindIndexBuffer(cb, self.index_buffer.handle, 0, vk.VK_INDEX_TYPE_UINT32);
        vk.vkCmdDrawIndexed(cb, self.index_count, 1, 0, 0, 0);
    }
};

pub const PlaneOptions = struct {
    /// Vertices per side. 2 = quad; 256 = M2.4 ocean target.
    resolution: u32,
    /// Edge length in world meters. Plane is centered on origin.
    size_m: f32,
};

/// Generate an XZ plane at y=0 and upload to GPU. Triangles wind CCW when
/// viewed from +y (front-facing under VK_FRONT_FACE_COUNTER_CLOCKWISE).
pub fn generatePlane(
    gpa: std.mem.Allocator,
    gpu: *const gpu_mod.GpuContext,
    opts: PlaneOptions,
) !Mesh {
    std.debug.assert(opts.resolution >= 2);

    const n: u32 = opts.resolution;
    const half = opts.size_m * 0.5;
    const step = opts.size_m / @as(f32, @floatFromInt(n - 1));

    const verts = try gpa.alloc(Vertex, n * n);
    defer gpa.free(verts);

    var z: u32 = 0;
    while (z < n) : (z += 1) {
        var x: u32 = 0;
        while (x < n) : (x += 1) {
            verts[z * n + x] = .{ .pos = .{
                -half + @as(f32, @floatFromInt(x)) * step,
                0.0,
                -half + @as(f32, @floatFromInt(z)) * step,
            } };
        }
    }

    const cells: u32 = (n - 1) * (n - 1);
    const indices = try gpa.alloc(u32, cells * 6);
    defer gpa.free(indices);

    var i: usize = 0;
    z = 0;
    while (z < n - 1) : (z += 1) {
        var x: u32 = 0;
        while (x < n - 1) : (x += 1) {
            const tl = z * n + x;
            const tr = z * n + x + 1;
            const bl = (z + 1) * n + x;
            const br = (z + 1) * n + x + 1;
            // Two triangles per cell, CCW from +y.
            indices[i + 0] = tl;
            indices[i + 1] = bl;
            indices[i + 2] = tr;
            indices[i + 3] = tr;
            indices[i + 4] = bl;
            indices[i + 5] = br;
            i += 6;
        }
    }

    var vbuf = try buffer_mod.Buffer.init(
        gpu,
        @sizeOf(Vertex) * verts.len,
        vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    );
    errdefer vbuf.deinit();
    vbuf.upload(std.mem.sliceAsBytes(verts));

    var ibuf = try buffer_mod.Buffer.init(
        gpu,
        @sizeOf(u32) * indices.len,
        vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
    );
    errdefer ibuf.deinit();
    ibuf.upload(std.mem.sliceAsBytes(indices));

    return .{
        .vertex_buffer = vbuf,
        .index_buffer = ibuf,
        .index_count = @intCast(indices.len),
    };
}
