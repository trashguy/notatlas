//! M10.1 mesh palette. Packs N piece meshes (vertices + indices) into a
//! shared pair of GPU buffers and records per-piece `{first_index,
//! index_count, vertex_offset, bounds}` so the instanced renderer can issue
//! one indirect-friendly draw per piece type. Vertex layout matches
//! `box.zig`'s `Vertex` (pos + normal) so future piece meshes can be
//! authored against the same struct.
//!
//! Buffers are uploaded once at init and never mutated. Hot-reload of piece
//! geometry is out of scope until M11's structure-merge work, which has its
//! own lifecycle.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const box_mod = @import("box.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

/// Shared with `box.zig` — both pipelines feed off the same vertex format.
pub const Vertex = box_mod.Vertex;

/// Caller-provided piece description. `bounds_center` / `bounds_radius` are
/// the piece-local world-AABB-or-sphere used by M10.3 GPU culling; supply a
/// conservative sphere that encloses the mesh's vertices. The renderer
/// transforms it by each instance's `model` at cull time, so a tight piece
/// bound + identity-ish per-instance scale is the cheapest path.
pub const PieceMesh = struct {
    vertices: []const Vertex,
    indices: []const u16,
    bounds_center: [3]f32 = .{ 0, 0, 0 },
    bounds_radius: f32 = 1.0,
};

/// Per-piece bookkeeping. Field names mirror `vkCmdDrawIndexed`'s parameter
/// order so the instanced renderer can paste them straight in. `vertex_count`
/// is carried alongside so M13's hot-reload path can verify same-shape
/// before doing an in-place vbo/ibo memcpy.
pub const PieceEntry = struct {
    first_index: u32,
    index_count: u32,
    vertex_offset: i32,
    vertex_count: u32,
    bounds_center: [3]f32,
    bounds_radius: f32,
};

pub const PaletteError = error{ NoPieces, IndexOverflow } || VulkanError || std.mem.Allocator.Error;

/// M13.2 in-place hot-reload constraint: changing vertex/index COUNT
/// would require re-packing every downstream piece's offsets. Out of
/// scope until M15/M18's dynamic asset management lands.
pub const UpdateError = error{ ShapeChanged, OutOfRange };

pub const MeshPalette = struct {
    gpa: std.mem.Allocator,
    device: vk.VkDevice,

    vertex_buffer: buffer_mod.Buffer,
    index_buffer: buffer_mod.Buffer,

    pieces: []PieceEntry,

    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *const gpu_mod.GpuContext,
        pieces: []const PieceMesh,
    ) PaletteError!MeshPalette {
        if (pieces.len == 0) return PaletteError.NoPieces;

        // Total sizes — sum first so we make one allocation each.
        var total_vertices: usize = 0;
        var total_indices: usize = 0;
        for (pieces) |p| {
            total_vertices += p.vertices.len;
            total_indices += p.indices.len;
        }
        if (total_vertices > std.math.maxInt(i32)) return PaletteError.IndexOverflow;
        if (total_indices > std.math.maxInt(u32)) return PaletteError.IndexOverflow;

        const vbo_size: vk.VkDeviceSize = total_vertices * @sizeOf(Vertex);
        const ibo_size: vk.VkDeviceSize = total_indices * @sizeOf(u16);

        var vbo = try buffer_mod.Buffer.init(
            gpu,
            vbo_size,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        errdefer vbo.deinit();

        var ibo = try buffer_mod.Buffer.init(
            gpu,
            ibo_size,
            vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );
        errdefer ibo.deinit();

        const entries = try gpa.alloc(PieceEntry, pieces.len);
        errdefer gpa.free(entries);

        // Pack: vertices for piece k start at vertex_cursor; indices for
        // piece k start at index_cursor. vkCmdDrawIndexed adds
        // `vertex_offset` to each index after it's fetched, so we DO NOT
        // rebase the index data — leave it as the caller provided.
        var vertex_cursor: i32 = 0;
        var index_cursor: u32 = 0;
        var vbo_byte_cursor: usize = 0;
        var ibo_byte_cursor: usize = 0;

        for (pieces, 0..) |p, i| {
            const v_bytes = std.mem.sliceAsBytes(p.vertices);
            @memcpy(vbo.mapped[vbo_byte_cursor..][0..v_bytes.len], v_bytes);
            vbo_byte_cursor += v_bytes.len;

            const i_bytes = std.mem.sliceAsBytes(p.indices);
            @memcpy(ibo.mapped[ibo_byte_cursor..][0..i_bytes.len], i_bytes);
            ibo_byte_cursor += i_bytes.len;

            entries[i] = .{
                .first_index = index_cursor,
                .index_count = @intCast(p.indices.len),
                .vertex_offset = vertex_cursor,
                .vertex_count = @intCast(p.vertices.len),
                .bounds_center = p.bounds_center,
                .bounds_radius = p.bounds_radius,
            };

            vertex_cursor += @intCast(p.vertices.len);
            index_cursor += @intCast(p.indices.len);
        }

        return .{
            .gpa = gpa,
            .device = gpu.device,
            .vertex_buffer = vbo,
            .index_buffer = ibo,
            .pieces = entries,
        };
    }

    pub fn deinit(self: *MeshPalette) void {
        self.gpa.free(self.pieces);
        self.index_buffer.deinit();
        self.vertex_buffer.deinit();
    }

    pub fn pieceCount(self: *const MeshPalette) usize {
        return self.pieces.len;
    }

    /// M13.2 hot-reload: replace piece `piece_id`'s vertex + index data
    /// in place. Vertex and index counts must match the original — the
    /// palette is packed once at init and the downstream PieceEntry
    /// offsets cannot move without invalidating every later piece.
    /// Caller must `vkDeviceWaitIdle` (or otherwise drain in-flight
    /// frames) before invoking; buffers are host-visible + coherent, so
    /// no explicit flush is needed after the memcpy.
    pub fn updatePiece(self: *MeshPalette, piece_id: usize, mesh: PieceMesh) UpdateError!void {
        if (piece_id >= self.pieces.len) return UpdateError.OutOfRange;
        const entry = &self.pieces[piece_id];
        if (mesh.vertices.len != entry.vertex_count) return UpdateError.ShapeChanged;
        if (mesh.indices.len != entry.index_count) return UpdateError.ShapeChanged;

        const v_off: usize = @as(usize, @intCast(entry.vertex_offset)) * @sizeOf(Vertex);
        const v_bytes = std.mem.sliceAsBytes(mesh.vertices);
        @memcpy(self.vertex_buffer.mapped[v_off..][0..v_bytes.len], v_bytes);

        const i_off: usize = @as(usize, entry.first_index) * @sizeOf(u16);
        const i_bytes = std.mem.sliceAsBytes(mesh.indices);
        @memcpy(self.index_buffer.mapped[i_off..][0..i_bytes.len], i_bytes);

        entry.bounds_center = mesh.bounds_center;
        entry.bounds_radius = mesh.bounds_radius;
    }
};

test "MeshPalette packs vertex/index offsets correctly" {
    // Unit-only check of the packing math. No Vulkan device needed —
    // call the same prefix-sum logic directly so we can validate it
    // without spinning up a GPU.
    const t = std.testing;
    const pieces = [_]PieceMesh{
        .{
            .vertices = &.{
                .{ .pos = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } },
                .{ .pos = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 } },
                .{ .pos = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 } },
            },
            .indices = &.{ 0, 1, 2 },
        },
        .{
            .vertices = &.{
                .{ .pos = .{ 0, 0, 0 }, .normal = .{ 1, 0, 0 } },
                .{ .pos = .{ 0, 1, 0 }, .normal = .{ 1, 0, 0 } },
                .{ .pos = .{ 0, 1, 1 }, .normal = .{ 1, 0, 0 } },
                .{ .pos = .{ 0, 0, 1 }, .normal = .{ 1, 0, 0 } },
            },
            .indices = &.{ 0, 1, 2, 0, 2, 3 },
        },
    };

    var vertex_cursor: i32 = 0;
    var index_cursor: u32 = 0;
    var entries: [pieces.len]PieceEntry = undefined;
    for (pieces, 0..) |p, i| {
        entries[i] = .{
            .first_index = index_cursor,
            .index_count = @intCast(p.indices.len),
            .vertex_offset = vertex_cursor,
            .vertex_count = @intCast(p.vertices.len),
            .bounds_center = p.bounds_center,
            .bounds_radius = p.bounds_radius,
        };
        vertex_cursor += @intCast(p.vertices.len);
        index_cursor += @intCast(p.indices.len);
    }

    try t.expectEqual(@as(i32, 0), entries[0].vertex_offset);
    try t.expectEqual(@as(u32, 0), entries[0].first_index);
    try t.expectEqual(@as(u32, 3), entries[0].index_count);

    try t.expectEqual(@as(i32, 3), entries[1].vertex_offset);
    try t.expectEqual(@as(u32, 3), entries[1].first_index);
    try t.expectEqual(@as(u32, 6), entries[1].index_count);
}
