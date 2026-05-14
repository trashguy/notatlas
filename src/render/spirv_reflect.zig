//! Hand-rolled SPIR-V reflector — narrow scope: extract descriptor
//! set + binding + descriptor-type from compiled SPIR-V, enough to
//! build VkDescriptorSetLayouts without hand-mirroring binding numbers
//! between the .glsl source and the Zig setup code.
//!
//! Why hand-roll instead of vendoring spirv-cross or rspirv:
//!   - Surface is tiny (~5 opcodes, ~6 decorations). Full reflection
//!     libs cover SPIR-V's whole ~80-opcode range; we use 6.
//!   - Already on `feedback_hand_roll_narrow_parsers.md`'s narrow case:
//!     the format is stable, the surface is small, and our tests cover
//!     the round-trip on every shader we ship.
//!   - spirv-cross is C++ + ~50K LOC; even via CMake-from-zig that's
//!     a multi-day vendor project for ~3 hours of code.
//!
//! Spec reference: https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html
//!
//! Coverage:
//!   - Descriptor types: UNIFORM_BUFFER, STORAGE_BUFFER, SAMPLED_IMAGE,
//!     STORAGE_IMAGE, SAMPLER, COMBINED_IMAGE_SAMPLER
//!   - Single-descriptor bindings (no arrays). Array bindings (texture
//!     atlases) land at M14.3+ with a new opcode handler.
//!   - Set + binding decorations
//! Not covered (deliberately): push constant ranges (declared by
//! OpVariable+PushConstant storage class but layouts come from the
//! Zig-side struct; @sizeOf is more reliable than parsing OpTypeStruct
//! offsets), input/output variables, specialization constants.

const std = @import("std");
const types = @import("vulkan_types.zig");
const vk = types.vk;

pub const Error = error{
    NotSpirv,
    UnsupportedVersion,
    UnexpectedEof,
    UnknownDescriptorType,
    OutOfMemory,
};

/// One descriptor binding extracted from a single SPIR-V module.
/// Caller merges bindings across stages and OR-s `stage_flags`.
pub const Binding = struct {
    set: u32,
    binding: u32,
    descriptor_type: vk.VkDescriptorType,
    descriptor_count: u32 = 1,
    stage_flags: vk.VkShaderStageFlags,
};

/// Parse a single SPIR-V module's descriptor bindings. Caller passes
/// the shader stage flag the SPIR-V was compiled for so the returned
/// bindings carry stage info.
///
/// Returns owned slice; caller frees with the same allocator.
pub fn reflectBindings(
    gpa: std.mem.Allocator,
    spv: []align(4) const u8,
    stage: vk.VkShaderStageFlags,
) Error![]Binding {
    if (spv.len < 20) return Error.UnexpectedEof; // 5-word header minimum
    if (spv.len % 4 != 0) return Error.NotSpirv;

    const words: []const u32 = std.mem.bytesAsSlice(u32, spv);

    // Header: magic, version, generator, bound, schema.
    if (words[0] != 0x07230203) return Error.NotSpirv;
    // Versions we tolerate: 1.0 through 1.6 (high byte 0, low bytes
    // major+minor). glslc with --target-env=vulkan1.3 emits 1.6.
    const version_major = (words[1] >> 16) & 0xff;
    const version_minor = (words[1] >> 8) & 0xff;
    if (version_major != 1 or version_minor > 6) return Error.UnsupportedVersion;
    const id_bound = words[3];

    // Per-id info we collect during the walk. Indexing by id directly
    // keeps lookups O(1); SPIR-V ids are small dense u32s starting at 1.
    const IdInfo = struct {
        set: ?u32 = null,
        binding: ?u32 = null,
        // For OpVariable: result type (a pointer type id).
        var_type_id: ?u32 = null,
        var_storage_class: ?u32 = null,
        // For OpTypePointer: storage class + pointee type id.
        ptr_storage_class: ?u32 = null,
        ptr_type_id: ?u32 = null,
        // Type kind tags for the pointee resolution chain.
        is_struct: bool = false,
        is_image: bool = false,
        is_sampler: bool = false,
        is_sampled_image: bool = false,
        // For OpTypeStruct decorated with Block / BufferBlock — used to
        // distinguish UBO vs SSBO when storage class is StorageBuffer
        // (post-1.3 spec deprecates BufferBlock; both UBO/SSBO use Block).
        is_block: bool = false,
        is_buffer_block: bool = false,
    };

    const info = try gpa.alloc(IdInfo, id_bound);
    defer gpa.free(info);
    @memset(info, .{});

    // SPIR-V opcodes we care about.
    const op_decorate: u16 = 71;
    const op_member_decorate: u16 = 72;
    const op_type_pointer: u16 = 32;
    const op_type_struct: u16 = 30;
    const op_type_image: u16 = 25;
    const op_type_sampler: u16 = 26;
    const op_type_sampled_image: u16 = 27;
    const op_variable: u16 = 59;

    // Decoration enum values.
    const dec_block: u32 = 2;
    const dec_buffer_block: u32 = 3;
    const dec_binding: u32 = 33;
    const dec_descriptor_set: u32 = 34;

    // Storage classes.
    const sc_uniform_constant: u32 = 0;
    const sc_uniform: u32 = 2;
    const sc_storage_buffer: u32 = 12;

    var i: usize = 5; // skip header
    while (i < words.len) {
        const word = words[i];
        const opcode: u16 = @truncate(word & 0xffff);
        const word_count: u16 = @truncate(word >> 16);
        if (word_count == 0 or i + word_count > words.len) return Error.UnexpectedEof;

        const operands = words[i + 1 .. i + word_count];

        switch (opcode) {
            op_decorate => {
                // OpDecorate <target_id> <decoration> [literal_args...]
                if (operands.len >= 2) {
                    const target = operands[0];
                    const decoration = operands[1];
                    if (target < id_bound) {
                        switch (decoration) {
                            dec_descriptor_set => if (operands.len >= 3) {
                                info[target].set = operands[2];
                            },
                            dec_binding => if (operands.len >= 3) {
                                info[target].binding = operands[2];
                            },
                            dec_block => info[target].is_block = true,
                            dec_buffer_block => info[target].is_buffer_block = true,
                            else => {},
                        }
                    }
                }
            },
            op_member_decorate => {
                // Skipped — Block/BufferBlock decorate the type, not its members.
            },
            op_type_struct => {
                if (operands.len >= 1) {
                    const id = operands[0];
                    if (id < id_bound) info[id].is_struct = true;
                }
            },
            op_type_image => {
                if (operands.len >= 1) {
                    const id = operands[0];
                    if (id < id_bound) info[id].is_image = true;
                }
            },
            op_type_sampler => {
                if (operands.len >= 1) {
                    const id = operands[0];
                    if (id < id_bound) info[id].is_sampler = true;
                }
            },
            op_type_sampled_image => {
                if (operands.len >= 1) {
                    const id = operands[0];
                    if (id < id_bound) info[id].is_sampled_image = true;
                }
            },
            op_type_pointer => {
                // OpTypePointer <result_id> <storage_class> <pointee_type_id>
                if (operands.len >= 3) {
                    const id = operands[0];
                    if (id < id_bound) {
                        info[id].ptr_storage_class = operands[1];
                        info[id].ptr_type_id = operands[2];
                    }
                }
            },
            op_variable => {
                // OpVariable <result_type_id> <result_id> <storage_class> [initializer]
                if (operands.len >= 3) {
                    const result_type = operands[0];
                    const result_id = operands[1];
                    const storage_class = operands[2];
                    if (result_id < id_bound) {
                        info[result_id].var_type_id = result_type;
                        info[result_id].var_storage_class = storage_class;
                    }
                }
            },
            else => {},
        }

        i += word_count;
    }

    // Second pass: walk OpVariable entries, classify each as a
    // descriptor binding by following the type chain.
    var bindings: std.ArrayList(Binding) = .empty;
    errdefer bindings.deinit(gpa);

    var id: u32 = 1;
    while (id < id_bound) : (id += 1) {
        const v = info[id];
        const var_storage = v.var_storage_class orelse continue;
        // Only descriptor-bound storage classes. PushConstant (9) is
        // declared via OpVariable too but isn't part of a descriptor set.
        if (var_storage != sc_uniform and
            var_storage != sc_uniform_constant and
            var_storage != sc_storage_buffer) continue;

        const set = v.set orelse continue; // unbound — generated by glslc for nothing useful
        const binding = v.binding orelse continue;

        // Resolve pointee type via OpTypePointer chain.
        const ptr_id = v.var_type_id orelse continue;
        if (ptr_id >= id_bound) continue;
        const ptr = info[ptr_id];
        const pointee_id = ptr.ptr_type_id orelse continue;
        if (pointee_id >= id_bound) continue;
        const pointee = info[pointee_id];

        // Map (storage class, pointee kind) → VkDescriptorType.
        const descriptor_type: vk.VkDescriptorType = blk: {
            if (var_storage == sc_uniform and pointee.is_struct) {
                break :blk vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            }
            if (var_storage == sc_storage_buffer and pointee.is_struct) {
                break :blk vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            }
            // Pre-1.3 SSBO style: storage class Uniform + struct
            // decorated BufferBlock. glslc emits this when targeting
            // older Vulkan versions.
            if (var_storage == sc_uniform and pointee.is_buffer_block) {
                break :blk vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            }
            if (var_storage == sc_uniform_constant) {
                if (pointee.is_sampled_image) break :blk vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                if (pointee.is_image) break :blk vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
                if (pointee.is_sampler) break :blk vk.VK_DESCRIPTOR_TYPE_SAMPLER;
            }
            return Error.UnknownDescriptorType;
        };

        try bindings.append(gpa, .{
            .set = set,
            .binding = binding,
            .descriptor_type = descriptor_type,
            .descriptor_count = 1,
            .stage_flags = stage,
        });
    }

    return bindings.toOwnedSlice(gpa);
}

/// Merge bindings from multiple shader stages into the union expected
/// by VkDescriptorSetLayoutBinding[]. Same (set, binding) seen in
/// multiple stages OR their stage_flags together; descriptor_type
/// must match (asserted).
///
/// Returns owned slice sorted by (set, binding); caller frees.
pub fn merge(
    gpa: std.mem.Allocator,
    sources: []const []const Binding,
) ![]Binding {
    var merged: std.ArrayList(Binding) = .empty;
    errdefer merged.deinit(gpa);

    for (sources) |src| {
        for (src) |b| {
            // Find existing entry with matching (set, binding).
            var found = false;
            for (merged.items) |*m| {
                if (m.set == b.set and m.binding == b.binding) {
                    std.debug.assert(m.descriptor_type == b.descriptor_type);
                    std.debug.assert(m.descriptor_count == b.descriptor_count);
                    m.stage_flags |= b.stage_flags;
                    found = true;
                    break;
                }
            }
            if (!found) try merged.append(gpa, b);
        }
    }

    std.mem.sort(Binding, merged.items, {}, lessThanBinding);
    return merged.toOwnedSlice(gpa);
}

fn lessThanBinding(_: void, a: Binding, b: Binding) bool {
    if (a.set != b.set) return a.set < b.set;
    return a.binding < b.binding;
}

// -----------------------------------------------------------------------------
// Tests — round-trip against the embedded SPIR-V the sandbox uses,
// so any glslc / shader change that breaks reflection trips here.

const box_vert_spv align(4) = @embedFile("box_vert_spv").*;
const box_frag_spv align(4) = @embedFile("box_frag_spv").*;

test "reflect box.vert: one UBO at set=0 binding=0" {
    const bindings = try reflectBindings(
        std.testing.allocator,
        &box_vert_spv,
        vk.VK_SHADER_STAGE_VERTEX_BIT,
    );
    defer std.testing.allocator.free(bindings);

    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqual(@as(u32, 0), bindings[0].set);
    try std.testing.expectEqual(@as(u32, 0), bindings[0].binding);
    try std.testing.expectEqual(
        @as(vk.VkDescriptorType, vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER),
        bindings[0].descriptor_type,
    );
}

test "merge: same binding across stages OR-s stage_flags" {
    const v = try reflectBindings(std.testing.allocator, &box_vert_spv, vk.VK_SHADER_STAGE_VERTEX_BIT);
    defer std.testing.allocator.free(v);
    const f = try reflectBindings(std.testing.allocator, &box_frag_spv, vk.VK_SHADER_STAGE_FRAGMENT_BIT);
    defer std.testing.allocator.free(f);

    const merged = try merge(std.testing.allocator, &.{ v, f });
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    const expected_stages: vk.VkShaderStageFlags =
        vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT;
    try std.testing.expectEqual(expected_stages, merged[0].stage_flags);
}

test "reflect rejects non-SPIRV input" {
    const garbage align(4) = [_]u8{ 0xde, 0xad, 0xbe, 0xef } ** 6;
    const result = reflectBindings(std.testing.allocator, &garbage, vk.VK_SHADER_STAGE_VERTEX_BIT);
    try std.testing.expectError(Error.NotSpirv, result);
}

test "reflect rejects too-short input" {
    const tiny align(4) = [_]u8{ 0x03, 0x02, 0x23, 0x07 };
    const result = reflectBindings(std.testing.allocator, &tiny, vk.VK_SHADER_STAGE_VERTEX_BIT);
    try std.testing.expectError(Error.UnexpectedEof, result);
}
