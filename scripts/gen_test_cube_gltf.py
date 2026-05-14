#!/usr/bin/env python3
# Regenerates data/props/test_cube.gltf for M13.
#
# Same 24-vert / 36-index unit cube as src/render/box.zig::cube_vertices.
# Single-file glTF 2.0 with embedded base64 buffer — no .bin sibling.
# Visual parity with the procedural cube is the M13 gate.
#
# Run: python3 scripts/gen_test_cube_gltf.py

import base64
import json
import struct
from pathlib import Path

# Faces in the same order as box.zig: +X, -X, +Y, -Y, +Z, -Z.
# Each face: 4 corners, 3-tris-per-face → 6 indices via (0,1,2),(0,2,3).
FACES = [
    {"normal": (1, 0, 0),  "corners": [(0.5, -0.5, 0.5),  (0.5, 0.5, 0.5),  (0.5, 0.5, -0.5),  (0.5, -0.5, -0.5)]},
    {"normal": (-1, 0, 0), "corners": [(-0.5, -0.5, -0.5),(-0.5, 0.5, -0.5),(-0.5, 0.5, 0.5),  (-0.5, -0.5, 0.5)]},
    {"normal": (0, 1, 0),  "corners": [(-0.5, 0.5, 0.5),  (-0.5, 0.5, -0.5),(0.5, 0.5, -0.5),  (0.5, 0.5, 0.5)]},
    {"normal": (0, -1, 0), "corners": [(-0.5, -0.5, -0.5),(-0.5, -0.5, 0.5),(0.5, -0.5, 0.5),  (0.5, -0.5, -0.5)]},
    {"normal": (0, 0, 1),  "corners": [(-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5),   (-0.5, 0.5, 0.5)]},
    {"normal": (0, 0, -1), "corners": [(0.5, -0.5, -0.5), (-0.5, -0.5, -0.5),(-0.5, 0.5, -0.5),(0.5, 0.5, -0.5)]},
]

positions = []
normals = []
for f in FACES:
    for c in f["corners"]:
        positions.extend(c)
        normals.extend(f["normal"])

indices = []
for face_idx in range(6):
    base = face_idx * 4
    indices += [base + 0, base + 1, base + 2, base + 0, base + 2, base + 3]

pos_bytes = struct.pack(f"<{len(positions)}f", *positions)
nrm_bytes = struct.pack(f"<{len(normals)}f", *normals)
idx_bytes = struct.pack(f"<{len(indices)}H", *indices)

# glTF requires bufferView byteOffsets to be multiples of the component
# size for the accessors that target them. Indices are u16 (2 bytes),
# floats are 4 bytes. Place indices last; offsets 0 and 288 are already
# aligned to 4 (positions), 288 aligned to 4 (normals), 576 aligned to 2
# (indices).
buf = pos_bytes + nrm_bytes + idx_bytes
assert len(pos_bytes) == 288
assert len(nrm_bytes) == 288
assert len(idx_bytes) == 72
assert len(buf) == 648

uri = "data:application/octet-stream;base64," + base64.b64encode(buf).decode("ascii")

gltf = {
    "asset": {"version": "2.0", "generator": "notatlas scripts/gen_test_cube_gltf.py"},
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [{"mesh": 0, "name": "M13TestCube"}],
    "meshes": [{
        "name": "TestCube",
        "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1},
            "indices": 2,
            "mode": 4  # TRIANGLES
        }]
    }],
    "accessors": [
        {"bufferView": 0, "componentType": 5126, "count": 24, "type": "VEC3",
         "min": [-0.5, -0.5, -0.5], "max": [0.5, 0.5, 0.5]},
        {"bufferView": 1, "componentType": 5126, "count": 24, "type": "VEC3"},
        {"bufferView": 2, "componentType": 5123, "count": 36, "type": "SCALAR"}
    ],
    "bufferViews": [
        {"buffer": 0, "byteOffset": 0,   "byteLength": 288, "target": 34962},  # ARRAY_BUFFER
        {"buffer": 0, "byteOffset": 288, "byteLength": 288, "target": 34962},
        {"buffer": 0, "byteOffset": 576, "byteLength": 72,  "target": 34963}   # ELEMENT_ARRAY_BUFFER
    ],
    "buffers": [
        {"byteLength": 648, "uri": uri}
    ]
}

out = Path(__file__).resolve().parent.parent / "data" / "props" / "test_cube.gltf"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(gltf, indent=2) + "\n")
print(f"wrote {out} ({out.stat().st_size} bytes)")
