//! M14.3 material v1 manifest loader.
//!
//! Schema (data/materials/<name>.yaml — flat scalars per
//! `feedback_ymlz_blank_lines.md`):
//!
//!   name: oak_wood_001
//!   albedo: data/textures/oak_wood_001/albedo.ktx2
//!   normal: data/textures/oak_wood_001/normal.ktx2
//!   orm: data/textures/oak_wood_001/orm.ktx2
//!
//! Channels follow glTF KHR_materials convention:
//!   - albedo: sRGB RGBA8 (gamma applied)
//!   - normal: linear RGBA8, tangent-space, (0,0,1) → (128,128,255)
//!   - orm:    linear RGBA8 packed: R=ambient occlusion, G=roughness,
//!             B=metallic. Per glTF KHR_materials_pbrSpecularGlossiness's
//!             successor (KHR_materials_pbrMetallicRoughness uses
//!             metallicRoughness as a 2-channel image; we pack AO in
//!             unused R for one fewer descriptor).
//!
//! Parser is ymlz (project standard) — flat struct of scalars; no
//! arrays, no nested objects in the schema yet.

const std = @import("std");
const ymlz = @import("ymlz");

pub const MaterialError = error{
    InvalidPath,
    OutOfMemory,
    YamlLoadFailed,
};

/// Parsed material manifest. All paths are owned (caller frees via
/// `deinit`); they're project-relative paths the loader resolves at
/// texture-upload time.
pub const Material = struct {
    name: []const u8,
    albedo_path: []const u8,
    normal_path: []const u8,
    orm_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Material) void {
        self.allocator.free(self.name);
        self.allocator.free(self.albedo_path);
        self.allocator.free(self.normal_path);
        self.allocator.free(self.orm_path);
        self.* = undefined;
    }
};

/// Raw struct ymlz binds against. Mirrors the schema above 1:1.
const RawMaterial = struct {
    name: []const u8,
    albedo: []const u8,
    normal: []const u8,
    orm: []const u8,
};

/// Load a material manifest from disk. `rel_path` is project-relative
/// (resolved against cwd). Returned Material owns its strings.
pub fn loadFromFile(gpa: std.mem.Allocator, rel_path: []const u8) MaterialError!Material {
    const abs = std.fs.cwd().realpathAlloc(gpa, rel_path) catch return MaterialError.InvalidPath;
    defer gpa.free(abs);

    var parser = ymlz.Ymlz(RawMaterial).init(gpa) catch return MaterialError.YamlLoadFailed;
    const raw = parser.loadFile(abs) catch return MaterialError.YamlLoadFailed;
    defer parser.deinit(raw);

    return .{
        .name = try gpa.dupe(u8, raw.name),
        .albedo_path = try gpa.dupe(u8, raw.albedo),
        .normal_path = try gpa.dupe(u8, raw.normal),
        .orm_path = try gpa.dupe(u8, raw.orm),
        .allocator = gpa,
    };
}

test "load test_cube material manifest" {
    var mat = try loadFromFile(std.testing.allocator, "data/materials/test_cube.yaml");
    defer mat.deinit();

    try std.testing.expectEqualStrings("test_cube", mat.name);
    try std.testing.expectEqualStrings("data/textures/test_cube/albedo.ktx2", mat.albedo_path);
    try std.testing.expectEqualStrings("data/textures/test_cube/normal.ktx2", mat.normal_path);
    try std.testing.expectEqualStrings("data/textures/test_cube/orm.ktx2", mat.orm_path);
}
