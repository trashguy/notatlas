#!/usr/bin/env python3
# Regenerates the M14.3 textured-cube test asset bundle:
#
#   data/props/textured_cube.gltf            # cube geometry + UVs
#   data/materials/test_cube.yaml            # material manifest
#   data/textures/test_cube/albedo.ktx2      # 256x256 sRGB checker
#   data/textures/test_cube/normal.ktx2      # 1x1 flat normal (no perturbation)
#   data/textures/test_cube/orm.ktx2         # 1x1 (full AO, mid roughness, no metal)
#
# Same hand-rolled style as scripts/gen_test_cube_gltf.py: no PIL, no
# KTX tooling — just struct + a minimal KTX2 v2 writer for uncompressed
# RGBA8. Keeps the test-asset generation self-contained so M14.3's gate
# script doesn't depend on the full libktx tools build (we vendor
# ktx_read only — no encoder).
#
# Run: python3 scripts/gen_test_textured_cube.py

import base64
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# -----------------------------------------------------------------------------
# KTX2 writer — minimum subset for uncompressed RGBA8, single mip, single
# layer, single face. Spec: https://registry.khronos.org/KTX/specs/2.0/
# ktxspec.v2.html

VK_FORMAT_R8G8B8A8_UNORM = 37
VK_FORMAT_R8G8B8A8_SRGB = 43

KTX2_IDENTIFIER = bytes([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB,
                          0x0D, 0x0A, 0x1A, 0x0A])

# Khronos basic Data Format Descriptor — RGBA8, transferFunction picked
# per call (sRGB=2 for albedo, Linear=1 for normal/ORM/data textures).
def _build_dfd_rgba8(srgb: bool) -> bytes:
    out = bytearray()
    # Total DFD size in bytes (4 header + 24 block header + 4*16 sample blocks).
    out += struct.pack("<I", 92)
    # Descriptor block header: vendorId(17b)|descriptorType(15b)|version(16b)|blockSize(16b)
    out += struct.pack("<H H H H", 0, 0, 2, 88)
    # colorModel | colorPrimaries | transferFunction | flags (4 bytes)
    transfer_function = 2 if srgb else 1
    out += struct.pack("<B B B B", 1, 1, transfer_function, 0)
    # texelBlockDimension[0..3] all 0 (encodes 1×1×1×1)
    out += struct.pack("<B B B B", 0, 0, 0, 0)
    # bytesPlane[0..7] — 4 bytes per pixel for plane 0; rest unused
    out += struct.pack("<B B B B B B B B", 4, 0, 0, 0, 0, 0, 0, 0)

    # 4 sample blocks (16 bytes each) for R, G, B, A.
    # bitLength is encoded as size-1, so 8 bits → 7.
    # For sRGB: RGB samples have qualifiers=0 (sRGB transfer),
    #           A sample has qualifiers=1 (linear bit set).
    # For UNORM: all samples have qualifiers=1 (linear bit set).
    def sample(bit_offset, channel_id, qualifiers):
        return struct.pack("<H B B I I I",
                           bit_offset,
                           7,  # bitLength - 1
                           channel_id | (qualifiers << 4),
                           0,  # samplePosition0..3 = 0,0,0,0
                           0,  # sampleLower
                           0xFF)  # sampleUpper

    if srgb:
        out += sample(0, 0, 0)   # R sRGB
        out += sample(8, 1, 0)   # G sRGB
        out += sample(16, 2, 0)  # B sRGB
        out += sample(24, 15, 1) # A linear
    else:
        out += sample(0, 0, 1)   # R linear
        out += sample(8, 1, 1)   # G linear
        out += sample(16, 2, 1)  # B linear
        out += sample(24, 15, 1) # A linear
    assert len(out) == 92
    return bytes(out)


def write_ktx2_rgba8(path: Path, width: int, height: int, rgba: bytes, srgb: bool):
    assert len(rgba) == width * height * 4, "rgba length mismatch"

    dfd = _build_dfd_rgba8(srgb)

    # File layout:
    #   identifier (12) + header (68)               → 80
    #   levelIndex[0]  (24, one level)              → 104
    #   DFD            (92)                         → 196
    #   pixel data     (width*height*4)
    # Header is 68 bytes (13 u32 + 2 u64) — kvdByteOffset/Length and
    # sgdByteOffset/Length are u32 + u32 + u64 + u64 = 24 trailing bytes
    # after the 13 leading u32 fields. Common KTX2 docs reference 60-byte
    # header for KTX1; KTX2 added the SGD u64 pair → 68.
    dfd_offset = 104
    dfd_length = len(dfd)
    data_offset = dfd_offset + dfd_length  # 196

    # KTX2 alignment: data offset must be aligned to "lcm of 4 and texel
    # block size". For RGBA8 (texel block = 4 bytes), lcm(4,4)=4. 196%4=0.
    assert data_offset % 4 == 0

    vk_format = VK_FORMAT_R8G8B8A8_SRGB if srgb else VK_FORMAT_R8G8B8A8_UNORM

    header = struct.pack(
        "<I I I I I I I I I I I I I Q Q",
        vk_format,           # vkFormat
        1,                   # typeSize
        width, height, 0,    # pixelWidth/Height/Depth (0 = 2D)
        0,                   # layerCount (0 = non-array)
        1,                   # faceCount (1 = non-cubemap)
        1,                   # levelCount
        0,                   # supercompressionScheme = NONE
        dfd_offset, dfd_length,
        0, 0,                # kvdByteOffset/Length (no KVD)
        0, 0,                # sgdByteOffset/Length (no SGD)
    )
    assert len(header) == 68

    level_index = struct.pack("<Q Q Q",
                              data_offset, len(rgba), len(rgba))
    assert len(level_index) == 24

    out = KTX2_IDENTIFIER + header + level_index + dfd + rgba
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(out)
    print(f"wrote {path} ({len(out)} bytes, {width}x{height} {'sRGB' if srgb else 'UNORM'})")


# -----------------------------------------------------------------------------
# Test pixel patterns

def make_checker_albedo(size: int) -> bytes:
    """Bright checkerboard so face orientation + UV mapping are visually
    obvious. Two distinct colors + a 1-pixel border around each tile so
    bilinear filtering at face boundaries stays readable."""
    cell = max(1, size // 8)  # 8x8 tiles
    pixels = bytearray()
    for y in range(size):
        for x in range(size):
            tile_x = x // cell
            tile_y = y // cell
            on = (tile_x + tile_y) % 2 == 0
            if on:
                pixels += bytes([0xE0, 0x60, 0x40, 0xFF])  # warm coral
            else:
                pixels += bytes([0x20, 0x80, 0xC0, 0xFF])  # cool teal
    return bytes(pixels)


def make_flat_normal() -> bytes:
    """1x1 RGBA8: flat tangent-space normal pointing along +Z (straight
    out of the surface). Encoded as R=128 G=128 B=255 (bias-and-scale to
    0..1 = (0.5, 0.5, 1.0) maps to tangent normal (0,0,1) after the
    `*2-1` decode in the fragment shader)."""
    return bytes([0x80, 0x80, 0xFF, 0xFF])


def make_default_orm() -> bytes:
    """1x1 RGBA8 ORM-packed default: R=255 (full AO/no occlusion),
    G=128 (mid roughness ≈ 0.5), B=0 (no metallic). Per glTF KHR
    occlusion-roughness-metallic convention."""
    return bytes([0xFF, 0x80, 0x00, 0xFF])


# -----------------------------------------------------------------------------
# glTF — same FACES as the M13 cube + per-face UVs (one quad per face).

FACES = [
    {"normal": (1, 0, 0),  "corners": [(0.5, -0.5, 0.5),  (0.5, 0.5, 0.5),  (0.5, 0.5, -0.5),  (0.5, -0.5, -0.5)]},
    {"normal": (-1, 0, 0), "corners": [(-0.5, -0.5, -0.5),(-0.5, 0.5, -0.5),(-0.5, 0.5, 0.5),  (-0.5, -0.5, 0.5)]},
    {"normal": (0, 1, 0),  "corners": [(-0.5, 0.5, 0.5),  (-0.5, 0.5, -0.5),(0.5, 0.5, -0.5),  (0.5, 0.5, 0.5)]},
    {"normal": (0, -1, 0), "corners": [(-0.5, -0.5, -0.5),(-0.5, -0.5, 0.5),(0.5, -0.5, 0.5),  (0.5, -0.5, -0.5)]},
    {"normal": (0, 0, 1),  "corners": [(-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5),   (-0.5, 0.5, 0.5)]},
    {"normal": (0, 0, -1), "corners": [(0.5, -0.5, -0.5), (-0.5, -0.5, -0.5),(-0.5, 0.5, -0.5),(0.5, 0.5, -0.5)]},
]
UVS = [(0, 1), (0, 0), (1, 0), (1, 1)]  # CCW from bottom-left, per face


def write_textured_cube_gltf(path: Path):
    positions, normals, uvs, indices = [], [], [], []
    for f in FACES:
        for c, uv in zip(f["corners"], UVS):
            positions.extend(c)
            normals.extend(f["normal"])
            uvs.extend(uv)
    for face_idx in range(6):
        base = face_idx * 4
        indices += [base + 0, base + 1, base + 2, base + 0, base + 2, base + 3]

    pos_bytes = struct.pack(f"<{len(positions)}f", *positions)
    nrm_bytes = struct.pack(f"<{len(normals)}f", *normals)
    uv_bytes = struct.pack(f"<{len(uvs)}f", *uvs)
    idx_bytes = struct.pack(f"<{len(indices)}H", *indices)

    # Pack: positions @ 0, normals @ 288, uvs @ 576, indices @ 768.
    # All offsets aligned to 4 (positions/normals/uvs are floats, indices
    # are u16 aligned to 4 already).
    buf = pos_bytes + nrm_bytes + uv_bytes + idx_bytes
    assert len(pos_bytes) == 288
    assert len(nrm_bytes) == 288
    assert len(uv_bytes) == 192
    assert len(idx_bytes) == 72
    assert len(buf) == 840

    uri = "data:application/octet-stream;base64," + base64.b64encode(buf).decode("ascii")

    gltf = {
        "asset": {"version": "2.0", "generator": "notatlas scripts/gen_test_textured_cube.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "M14TexturedCube"}],
        "meshes": [{
            "name": "TexturedCube",
            "primitives": [{
                "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
                "indices": 3,
                "mode": 4,
            }],
        }],
        "buffers": [{"byteLength": len(buf), "uri": uri}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0,   "byteLength": 288, "target": 34962},  # ARRAY_BUFFER
            {"buffer": 0, "byteOffset": 288, "byteLength": 288, "target": 34962},
            {"buffer": 0, "byteOffset": 576, "byteLength": 192, "target": 34962},
            {"buffer": 0, "byteOffset": 768, "byteLength": 72,  "target": 34963},  # ELEMENT_ARRAY_BUFFER
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 24, "type": "VEC3"},
            {"bufferView": 1, "componentType": 5126, "count": 24, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": 24, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5123, "count": 36, "type": "SCALAR"},
        ],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(gltf, indent=2))
    print(f"wrote {path} ({path.stat().st_size} bytes)")


# -----------------------------------------------------------------------------
# Material YAML — flat scalar layout (per feedback_ymlz_blank_lines.md:
# ymlz panics on blank lines, can't parse fixed-size arrays; struct of
# scalars is the safe shape).

def write_material_yaml(path: Path):
    body = (
        "name: test_cube\n"
        "albedo: data/textures/test_cube/albedo.ktx2\n"
        "normal: data/textures/test_cube/normal.ktx2\n"
        "orm: data/textures/test_cube/orm.ktx2\n"
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    print(f"wrote {path}")


def main():
    tex_dir = ROOT / "data" / "textures" / "test_cube"
    write_ktx2_rgba8(tex_dir / "albedo.ktx2", 256, 256, make_checker_albedo(256), srgb=True)
    write_ktx2_rgba8(tex_dir / "normal.ktx2", 1, 1, make_flat_normal(), srgb=False)
    write_ktx2_rgba8(tex_dir / "orm.ktx2",    1, 1, make_default_orm(), srgb=False)
    write_material_yaml(ROOT / "data" / "materials" / "test_cube.yaml")
    write_textured_cube_gltf(ROOT / "data" / "props" / "textured_cube.gltf")


if __name__ == "__main__":
    main()
