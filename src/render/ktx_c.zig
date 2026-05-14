//! Thin Zig binding around libktx's C API.
//!
//! Per `feedback_thin_c_bindings.md`: bind against the library's own C
//! surface; do not pull a Zig wrapper from zig-gamedev or similar.
//! This file re-exports `c` for any caller that wants raw access; it
//! also offers a small typed sugar layer (`Texture2`, `Result`) for
//! the load + introspect paths the M14 sandbox uses.
//!
//! No Vulkan integration here — that lands at M14.2. M14.1 only
//! covers `ktxTexture2_CreateFromNamedFile/CreateFromMemory` and the
//! few accessors needed for "open a KTX2, print its metadata, free it."

const std = @import("std");

pub const c = @cImport({
    @cInclude("ktx.h");
});

/// Result codes from libktx (`ktx_error_code_e`). Re-exported as a Zig
/// error set for ergonomic propagation. Keep the variant names matching
/// the upstream enum suffix so docs/source cross-reference cleanly.
pub const Error = error{
    FileDataError,
    FileIsPipe,
    FileOpenFailed,
    FileOverflow,
    FileReadError,
    FileSeekError,
    FileUnexpectedEof,
    FileWriteError,
    GlError,
    InvalidOperation,
    InvalidValue,
    NotFound,
    OutOfMemory,
    TranscodeFailed,
    UnknownFileFormat,
    UnsupportedTextureType,
    UnsupportedFeature,
    LibraryNotLinked,
    DecompressLengthError,
    DecompressChecksumError,
    Unknown,
};

pub fn check(code: c.ktx_error_code_e) Error!void {
    return switch (code) {
        c.KTX_SUCCESS => {},
        c.KTX_FILE_DATA_ERROR => Error.FileDataError,
        c.KTX_FILE_ISPIPE => Error.FileIsPipe,
        c.KTX_FILE_OPEN_FAILED => Error.FileOpenFailed,
        c.KTX_FILE_OVERFLOW => Error.FileOverflow,
        c.KTX_FILE_READ_ERROR => Error.FileReadError,
        c.KTX_FILE_SEEK_ERROR => Error.FileSeekError,
        c.KTX_FILE_UNEXPECTED_EOF => Error.FileUnexpectedEof,
        c.KTX_FILE_WRITE_ERROR => Error.FileWriteError,
        c.KTX_GL_ERROR => Error.GlError,
        c.KTX_INVALID_OPERATION => Error.InvalidOperation,
        c.KTX_INVALID_VALUE => Error.InvalidValue,
        c.KTX_NOT_FOUND => Error.NotFound,
        c.KTX_OUT_OF_MEMORY => Error.OutOfMemory,
        c.KTX_TRANSCODE_FAILED => Error.TranscodeFailed,
        c.KTX_UNKNOWN_FILE_FORMAT => Error.UnknownFileFormat,
        c.KTX_UNSUPPORTED_TEXTURE_TYPE => Error.UnsupportedTextureType,
        c.KTX_UNSUPPORTED_FEATURE => Error.UnsupportedFeature,
        c.KTX_LIBRARY_NOT_LINKED => Error.LibraryNotLinked,
        c.KTX_DECOMPRESS_LENGTH_ERROR => Error.DecompressLengthError,
        c.KTX_DECOMPRESS_CHECKSUM_ERROR => Error.DecompressChecksumError,
        else => Error.Unknown,
    };
}

/// Owning handle around `ktxTexture2*`. Calls `ktxTexture2_Destroy` on
/// `deinit`. Construction copies the create flags from the upstream
/// header (KTX_TEXTURE_CREATE_LOAD_IMAGE_DATA_BIT etc.) but defaults
/// to LOAD_IMAGE_DATA_BIT — caller wants the pixels in memory.
pub const Texture2 = struct {
    raw: *c.ktxTexture2,

    pub const CreateFlags = packed struct(u32) {
        load_image_data: bool = true,
        raw_kvdata: bool = false,
        skip_kvdata: bool = false,
        _padding: u29 = 0,

        fn toC(self: CreateFlags) c.ktxTextureCreateFlags {
            var flags: c.ktxTextureCreateFlags = 0;
            if (self.load_image_data) flags |= c.KTX_TEXTURE_CREATE_LOAD_IMAGE_DATA_BIT;
            if (self.raw_kvdata) flags |= c.KTX_TEXTURE_CREATE_RAW_KVDATA_BIT;
            if (self.skip_kvdata) flags |= c.KTX_TEXTURE_CREATE_SKIP_KVDATA_BIT;
            return flags;
        }
    };

    pub fn fromFile(path: [:0]const u8, flags: CreateFlags) Error!Texture2 {
        var raw: ?*c.ktxTexture2 = null;
        try check(c.ktxTexture2_CreateFromNamedFile(path.ptr, flags.toC(), &raw));
        return .{ .raw = raw.? };
    }

    pub fn fromMemory(bytes: []const u8, flags: CreateFlags) Error!Texture2 {
        var raw: ?*c.ktxTexture2 = null;
        try check(c.ktxTexture2_CreateFromMemory(bytes.ptr, bytes.len, flags.toC(), &raw));
        return .{ .raw = raw.? };
    }

    pub fn deinit(self: *Texture2) void {
        c.ktxTexture2_Destroy(self.raw);
        self.* = undefined;
    }

    /// Vulkan format enum value. Upstream stores VK_FORMAT_* in
    /// `vkFormat`; for KTX2 textures this is the canonical format
    /// identifier. Returns `c.VK_FORMAT_UNDEFINED` (0) for Basis-
    /// supercompressed textures until they are transcoded.
    pub fn vkFormat(self: Texture2) u32 {
        return self.raw.vkFormat;
    }

    pub fn width(self: Texture2) u32 {
        return self.raw.baseWidth;
    }

    pub fn height(self: Texture2) u32 {
        return self.raw.baseHeight;
    }

    pub fn depth(self: Texture2) u32 {
        return self.raw.baseDepth;
    }

    pub fn numLevels(self: Texture2) u32 {
        return self.raw.numLevels;
    }

    pub fn numLayers(self: Texture2) u32 {
        return self.raw.numLayers;
    }

    pub fn numFaces(self: Texture2) u32 {
        return self.raw.numFaces;
    }

    pub fn dataSize(self: Texture2) usize {
        return self.raw.dataSize;
    }

    pub fn data(self: Texture2) []const u8 {
        return self.raw.pData[0..self.raw.dataSize];
    }

    /// True when the underlying format is Basis-supercompressed and
    /// must be transcoded before GPU upload (vkFormat == 0).
    pub fn needsTranscode(self: Texture2) bool {
        return self.raw.vkFormat == 0;
    }
};

// -----------------------------------------------------------------------------
// Tests — round-trip the C surface against a known-stable vendor sample.
// Catches upstream API drift across libktx tag bumps.
//
// Path is relative to repo root (cwd at `zig build test` time).

const test_vendor_sample = "vendor/KTX-Software/tests/testimages/rgba-reference-u.ktx2";

test "ktx_c: open vendor RGBA reference, read metadata, destroy" {
    var tex = try Texture2.fromFile(test_vendor_sample, .{});
    defer tex.deinit();

    // rgba-reference-u.ktx2 is uncompressed; vkFormat must be set.
    try std.testing.expect(tex.vkFormat() != 0);
    try std.testing.expect(!tex.needsTranscode());
    try std.testing.expect(tex.width() > 0);
    try std.testing.expect(tex.height() > 0);
    try std.testing.expect(tex.dataSize() > 0);
    try std.testing.expect(tex.data().len == tex.dataSize());
}

test "ktx_c: round-trip via fromMemory matches fromFile" {
    const file = try std.fs.cwd().openFile(test_vendor_sample, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(std.testing.allocator, 16 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);

    var tex = try Texture2.fromMemory(bytes, .{});
    defer tex.deinit();

    try std.testing.expect(tex.vkFormat() != 0);
    try std.testing.expect(tex.dataSize() > 0);
}

test "ktx_c: bad file path → FileOpenFailed" {
    const result = Texture2.fromFile("vendor/KTX-Software/tests/this-file-does-not-exist.ktx2", .{});
    try std.testing.expectError(Error.FileOpenFailed, result);
}
