---
name: ai-sim BT runtime split — Zig composites, Lua leaves, YAML shape
description: Locked 2026-04-30 in docs/09-ai-sim.md. Behavior tree composite vocabulary (six node types) is in Zig; tree shape is in YAML; conditions and actions are Lua functions in sibling .lua files. Don't propose pure-Lua BT or hardcoded-Zig trees.
type: project
originSessionId: c0f21592-5ca9-4571-9536-a4e657490842
---
The split:

- **Composites in Zig** (`selector`, `sequence`, `parallel`, `inverter`, `cooldown`, `repeat`). Six types, fixed vocabulary. Adding a seventh is a Zig PR + schema bump, not designer work. Status enum: `success | failure | running`.
- **Tree shape in YAML** (`data/ai/<archetype>.yaml`). Schema-validated on load via the wave-query loader pattern. Trees can `include:` shared subtrees; resolved at load time.
- **Leaves in Lua** (`data/ai/<archetype>.lua`). `cond` leaves return boolean; `action` leaves return Status string and may write into `ctx.input`. One Lua file per archetype, sibling to the YAML.
- **Per-AI state** is a Lua `self` table keyed by entity id, threaded into every leaf call. Survives hot reload of the leaf code.
- **Perception API** (`ctx`) is a deliberately bounded surface: own pose/vel/hp, wind, nearest_enemy, threats[≤8]. Extensions are Zig PRs.

**Why:** Composite vocabulary is finite-and-stable; leaf vocabulary is open-and-growing. Putting the part that grows forever in the iteration-friendly language (Lua + hot reload) and the part that's hot/stable in the fast language (Zig) is normal layering, not gamedev folklore. Composite traversal stays allocation-free; only leaves cross the FFI boundary. Tree shape as YAML gives designers a diff-able, copy-paste-friendly authoring surface and enables tree-graph debug UIs later. Decision driven by engineering trade-offs (change-frequency, FFI cost, schema stability), not BT-runtime convention.

**How to apply:**
- When implementing ai-sim, follow `docs/09-ai-sim.md` §14 implementation order: lua_bind.zig lift → BT runtime → YAML loader → service skeleton → perception → first archetype.
- Don't propose pure-Lua BT (rejected: pushes hot-path traversal into the VM with no upside).
- Don't propose hardcoded-Zig trees (rejected: kills designer iteration; trees should be data).
- Six composite types are the vocabulary. Resist adding more without a real archetype that needs it.
- Leaves return Status as strings (`"success"`/`"failure"`/`"running"`) at the FFI boundary, converted to enum on the Zig side. Strings survive copy-paste from logs better than integers.
