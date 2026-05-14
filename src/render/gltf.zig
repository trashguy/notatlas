//! M13 glTF static mesh loader. Hand-rolled minimal parser scoped to the
//! M13 deliverable: single mesh, single primitive, POSITION + NORMAL +
//! u16 indices, embedded base64 buffer (data URI). Outputs a
//! `palette_mod.PieceMesh`-compatible `LoadedMesh` so the result feeds
//! the existing M10 instancing path without a new pipeline.
//!
//! Out of scope for M13:
//!   - .glb binary container (chunked JSON + bin)
//!   - .bin sibling files (external buffer URIs)
//!   - Materials, textures, texcoords     → M14
//!   - Skinning, joints, weights, anim    → M16
//!   - Multi-primitive meshes, scene hierarchy transforms
//!   - Draco / mesh compression
//!   - Sparse accessors, accessor min/max validation
//!
//! Each gap above is M14+ territory; the parser stays narrow so the M13
//! gate is "load + render a static mesh," nothing more.

const std = @import("std");
const box_mod = @import("box.zig");
const palette_mod = @import("mesh_palette.zig");

const Vertex = box_mod.Vertex;

pub const GltfError = error{
    JsonParse,
    MissingAsset,
    UnsupportedAssetVersion,
    MissingMesh,
    MissingPrimitive,
    UnsupportedPrimitiveMode,
    MissingPositionAccessor,
    MissingIndexAccessor,
    UnsupportedComponentType,
    UnsupportedAccessorType,
    AccessorCountMismatch,
    MissingBufferView,
    MissingBuffer,
    UnsupportedBufferUri,
    Base64Decode,
    BufferTooSmall,
};

/// Owned vertex + index buffers in CPU memory. Caller hands these to
/// `MeshPalette.init` (which memcpys into GPU buffers) and then deinits
/// this struct. Bounds are computed from accessor min/max if present,
/// otherwise from a vertex sweep.
pub const LoadedMesh = struct {
    vertices: []Vertex,
    indices: []u16,
    bounds_center: [3]f32,
    bounds_radius: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LoadedMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }

    /// View as a `PieceMesh`. Valid until `deinit`.
    pub fn pieceMesh(self: *const LoadedMesh) palette_mod.PieceMesh {
        return .{
            .vertices = self.vertices,
            .indices = self.indices,
            .bounds_center = self.bounds_center,
            .bounds_radius = self.bounds_radius,
        };
    }
};

/// Read + parse a .gltf file from disk and return a `LoadedMesh`. The
/// file must contain a single mesh with a single primitive; POSITION +
/// NORMAL + u16 indices; one buffer with an embedded data: URI.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !LoadedMesh {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    return loadFromBytes(allocator, bytes);
}

/// Parse from an in-memory glTF JSON blob. Split out so tests can drive
/// the parser without touching the filesystem.
pub fn loadFromBytes(allocator: std.mem.Allocator, json_bytes: []const u8) !LoadedMesh {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch {
        return GltfError.JsonParse;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return GltfError.JsonParse,
    };

    try checkAssetVersion(root);

    const meshes = (root.get("meshes") orelse return GltfError.MissingMesh).array;
    if (meshes.items.len == 0) return GltfError.MissingMesh;
    const primitives = (meshes.items[0].object.get("primitives") orelse return GltfError.MissingPrimitive).array;
    if (primitives.items.len == 0) return GltfError.MissingPrimitive;
    const prim = primitives.items[0].object;

    if (prim.get("mode")) |m| {
        if (m.integer != 4) return GltfError.UnsupportedPrimitiveMode; // TRIANGLES
    }

    const attributes = (prim.get("attributes") orelse return GltfError.MissingPositionAccessor).object;
    const pos_idx = intField(attributes.get("POSITION") orelse return GltfError.MissingPositionAccessor);
    const nrm_idx_opt: ?u32 = if (attributes.get("NORMAL")) |v| intField(v) else null;
    const idx_idx = intField(prim.get("indices") orelse return GltfError.MissingIndexAccessor);

    const accessors = (root.get("accessors") orelse return GltfError.MissingPositionAccessor).array;
    const buffer_views = (root.get("bufferViews") orelse return GltfError.MissingBufferView).array;
    const buffers = (root.get("buffers") orelse return GltfError.MissingBuffer).array;

    // Decode the single buffer once. (Multi-buffer glTFs go to M14.)
    if (buffers.items.len == 0) return GltfError.MissingBuffer;
    const uri_val = buffers.items[0].object.get("uri") orelse return GltfError.UnsupportedBufferUri;
    const uri = uri_val.string;
    const buf_bytes = try decodeDataUri(allocator, uri);
    defer allocator.free(buf_bytes);

    // Positions: VEC3 float.
    const pos_acc = accessors.items[pos_idx].object;
    if (!std.mem.eql(u8, pos_acc.get("type").?.string, "VEC3")) return GltfError.UnsupportedAccessorType;
    if (pos_acc.get("componentType").?.integer != 5126) return GltfError.UnsupportedComponentType;
    const vert_count: usize = @intCast(pos_acc.get("count").?.integer);
    const pos_data = try readAccessorSlice(f32, pos_acc, buffer_views, buf_bytes, 3 * vert_count);

    // Normals: optional VEC3 float. Default to (0,1,0) if absent.
    var nrm_data: []const f32 = &.{};
    var nrm_owned = false;
    var nrm_buf: []f32 = &.{};
    defer if (nrm_owned) allocator.free(nrm_buf);
    if (nrm_idx_opt) |nrm_idx| {
        const nrm_acc = accessors.items[nrm_idx].object;
        if (!std.mem.eql(u8, nrm_acc.get("type").?.string, "VEC3")) return GltfError.UnsupportedAccessorType;
        if (nrm_acc.get("componentType").?.integer != 5126) return GltfError.UnsupportedComponentType;
        const n_count: usize = @intCast(nrm_acc.get("count").?.integer);
        if (n_count != vert_count) return GltfError.AccessorCountMismatch;
        nrm_data = try readAccessorSlice(f32, nrm_acc, buffer_views, buf_bytes, 3 * vert_count);
    } else {
        nrm_buf = try allocator.alloc(f32, 3 * vert_count);
        nrm_owned = true;
        var i: usize = 0;
        while (i < vert_count) : (i += 1) {
            nrm_buf[i * 3 + 0] = 0;
            nrm_buf[i * 3 + 1] = 1;
            nrm_buf[i * 3 + 2] = 0;
        }
        nrm_data = nrm_buf;
    }

    // Indices: u16 scalar (M13 scope).
    const idx_acc = accessors.items[idx_idx].object;
    if (!std.mem.eql(u8, idx_acc.get("type").?.string, "SCALAR")) return GltfError.UnsupportedAccessorType;
    if (idx_acc.get("componentType").?.integer != 5123) return GltfError.UnsupportedComponentType;
    const idx_count: usize = @intCast(idx_acc.get("count").?.integer);
    const idx_data = try readAccessorSlice(u16, idx_acc, buffer_views, buf_bytes, idx_count);

    // Pack into the renderer's interleaved Vertex layout.
    const verts = try allocator.alloc(Vertex, vert_count);
    errdefer allocator.free(verts);
    {
        var i: usize = 0;
        while (i < vert_count) : (i += 1) {
            verts[i] = .{
                .pos = .{ pos_data[i * 3 + 0], pos_data[i * 3 + 1], pos_data[i * 3 + 2] },
                .normal = .{ nrm_data[i * 3 + 0], nrm_data[i * 3 + 1], nrm_data[i * 3 + 2] },
            };
        }
    }

    const indices = try allocator.alloc(u16, idx_count);
    errdefer allocator.free(indices);
    @memcpy(indices, idx_data);

    const bounds = computeBounds(pos_acc, verts);
    return .{
        .vertices = verts,
        .indices = indices,
        .bounds_center = bounds.center,
        .bounds_radius = bounds.radius,
        .allocator = allocator,
    };
}

fn intField(v: std.json.Value) u32 {
    return @intCast(v.integer);
}

fn checkAssetVersion(root: std.json.ObjectMap) !void {
    const asset = (root.get("asset") orelse return GltfError.MissingAsset).object;
    const version = (asset.get("version") orelse return GltfError.MissingAsset).string;
    // M13 only requires the 2.x major; minor extensions vary by exporter.
    if (!std.mem.startsWith(u8, version, "2.")) return GltfError.UnsupportedAssetVersion;
}

/// Resolve an accessor's bufferView + byteOffset + (typed) count into a
/// borrowed slice over `buf_bytes`. Caller does NOT free the slice.
fn readAccessorSlice(
    comptime T: type,
    accessor: std.json.ObjectMap,
    buffer_views: std.json.Array,
    buf_bytes: []const u8,
    elem_count: usize,
) ![]const T {
    const bv_idx: usize = @intCast(accessor.get("bufferView").?.integer);
    const bv = buffer_views.items[bv_idx].object;
    var byte_offset: usize = 0;
    if (bv.get("byteOffset")) |v| byte_offset = @intCast(v.integer);
    if (accessor.get("byteOffset")) |v| byte_offset += @intCast(v.integer);

    const needed = elem_count * @sizeOf(T);
    if (byte_offset + needed > buf_bytes.len) return GltfError.BufferTooSmall;
    const raw = buf_bytes[byte_offset .. byte_offset + needed];
    // glTF data is little-endian per spec; assume host is LE (notatlas
    // targets x86_64 / aarch64 LE only). Reinterpret via ptrCast.
    const ptr: [*]const T = @ptrCast(@alignCast(raw.ptr));
    return ptr[0..elem_count];
}

const Bounds = struct { center: [3]f32, radius: f32 };

fn computeBounds(pos_acc: std.json.ObjectMap, verts: []const Vertex) Bounds {
    // Prefer accessor.min/max if both present (the exporter computed it).
    if (pos_acc.get("min")) |min_v| {
        if (pos_acc.get("max")) |max_v| {
            const mn = min_v.array.items;
            const mx = max_v.array.items;
            if (mn.len >= 3 and mx.len >= 3) {
                const c: [3]f32 = .{
                    @as(f32, @floatCast(jsonNum(mn[0]) + jsonNum(mx[0]))) * 0.5,
                    @as(f32, @floatCast(jsonNum(mn[1]) + jsonNum(mx[1]))) * 0.5,
                    @as(f32, @floatCast(jsonNum(mn[2]) + jsonNum(mx[2]))) * 0.5,
                };
                const hx: f32 = @floatCast((jsonNum(mx[0]) - jsonNum(mn[0])) * 0.5);
                const hy: f32 = @floatCast((jsonNum(mx[1]) - jsonNum(mn[1])) * 0.5);
                const hz: f32 = @floatCast((jsonNum(mx[2]) - jsonNum(mn[2])) * 0.5);
                return .{ .center = c, .radius = @sqrt(hx * hx + hy * hy + hz * hz) };
            }
        }
    }
    // Fall back to a sweep over the vertex positions.
    var lo: [3]f32 = .{ verts[0].pos[0], verts[0].pos[1], verts[0].pos[2] };
    var hi: [3]f32 = lo;
    for (verts[1..]) |v| {
        for (0..3) |k| {
            lo[k] = @min(lo[k], v.pos[k]);
            hi[k] = @max(hi[k], v.pos[k]);
        }
    }
    const c: [3]f32 = .{ (lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5 };
    const hx = (hi[0] - lo[0]) * 0.5;
    const hy = (hi[1] - lo[1]) * 0.5;
    const hz = (hi[2] - lo[2]) * 0.5;
    return .{ .center = c, .radius = @sqrt(hx * hx + hy * hy + hz * hz) };
}

fn jsonNum(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

/// Decode `data:application/octet-stream;base64,<...>` URIs. External
/// buffer URIs (relative paths to .bin siblings) are M14+ scope.
fn decodeDataUri(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, uri, prefix)) return GltfError.UnsupportedBufferUri;
    const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return GltfError.UnsupportedBufferUri;
    const header = uri[prefix.len..comma];
    if (std.mem.indexOf(u8, header, "base64") == null) return GltfError.UnsupportedBufferUri;
    const b64 = uri[comma + 1 ..];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return GltfError.Base64Decode;
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    std.base64.standard.Decoder.decode(out, b64) catch return GltfError.Base64Decode;
    return out;
}

test "load embedded glTF round-trip matches procedural cube" {
    const t = std.testing;
    const file = try std.fs.cwd().openFile("data/props/test_cube.gltf", .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(t.allocator, 1 << 20);
    defer t.allocator.free(bytes);

    var mesh = try loadFromBytes(t.allocator, bytes);
    defer mesh.deinit();

    try t.expectEqual(@as(usize, box_mod.cube_vertices.len), mesh.vertices.len);
    try t.expectEqual(@as(usize, box_mod.cube_indices.len), mesh.indices.len);

    for (mesh.vertices, box_mod.cube_vertices) |got, want| {
        try t.expectApproxEqAbs(want.pos[0], got.pos[0], 1e-6);
        try t.expectApproxEqAbs(want.pos[1], got.pos[1], 1e-6);
        try t.expectApproxEqAbs(want.pos[2], got.pos[2], 1e-6);
        try t.expectApproxEqAbs(want.normal[0], got.normal[0], 1e-6);
        try t.expectApproxEqAbs(want.normal[1], got.normal[1], 1e-6);
        try t.expectApproxEqAbs(want.normal[2], got.normal[2], 1e-6);
    }
    for (mesh.indices, box_mod.cube_indices) |got, want| {
        try t.expectEqual(want, got);
    }

    // Bounds match procedural cube within float epsilon.
    try t.expectApproxEqAbs(@as(f32, 0), mesh.bounds_center[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0), mesh.bounds_center[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0), mesh.bounds_center[2], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.8660254), mesh.bounds_radius, 1e-5);
}
