---
name: notatlas pillar — competent FPS player combat
description: On-foot/melee/firearms combat. Quoted: "smooth as we can fps combat for people, but most players are used to jank." Lower priority than naval combat — execution territory, not innovation. Target "Rust-grade" feel, not Tarkov-grade.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
User framing: "the other obviously is smooth as we can fps combat for people, but most players are used to jank."

**Priority interpretation:** competent, not differentiator. Atlas players accepted clunky combat because the game was the only pirate sandbox. notatlas can clear the same bar more easily because:
- Naval combat is the actual selling point
- Sub-200 player engagements (most player-vs-player is a boarding party of <20)
- Custom engine = no UE4 ARK-fork legacy bugs to inherit

**Targets:**
- Rust-grade or better. Tarkov-grade not required.
- 60Hz authoritative server tick for player-on-player engagements.
- Lag compensation / rollback for hit registration on hitscan or fast projectiles.
- Client-side prediction for own movement; reconciliation on mismatch.
- Hit feedback that doesn't lie (no "shot through wall" — geometry-aware hit reg).
- Honest ping display + region-aware matchmaking.

**Standard FPS netcode pattern (well-trodden):**
- Client predicts own movement at 60Hz
- Server simulates authoritatively, broadcasts state at 30-60Hz
- Client interpolates remote players (~100ms buffer)
- Hit registration: server rewinds time using each client's reported latency to validate hits at the client's view (lag comp window capped at ~250ms to limit "shot around corners")
- Movement input as command stream (input + sequence number); server replays
- Reconciliation: when server-state diverges from client prediction, smooth-correct over a few frames

**Combat loadout (Atlas-derived):**
- Melee: fists, sword, saber, pike, sickle, shield (block)
- Throwing: spears, javelins, grenades, bolas (taming/CC)
- Bow + crossbow with arrow types (simple, fire)
- Flintlock pistol, blunderbuss, carbine — slow reload, big damage, ammo as crafted item
- Hand mortar, possibly grenades
- Whip, bola for CC/tame-knockdown

**Don't over-invest:**
- No Mordhau-grade directional melee with chamber/parry windows (decade of work)
- No Tarkov-grade ballistics modeling (overkill for flintlocks)
- Hitscan for muskets/pistols at typical 1-30m engagement is fine and indistinguishable from fast projectile in feel
- Cannon/mortar/ballista projectiles already deterministic from naval system — reuse

**Engine work needed beyond fallen-runes (likely already has most of this):**
- Lag compensation framework (rollback last N ticks for hit validation)
- Hitbox system per character pose (capsule + per-bone shapes)
- Recoil + spread model
- Animation cancel windows for melee
- Damage-direction indicator UI

**What NOT to do:**
- Don't replicate every projectile as a networked entity. Same deterministic-arc pattern as cannons.
- Don't pursue first-person realism if the engine is third-person primary; pick one camera mode for ranged combat and commit.
- Don't try to make 200ms-ping players feel like 20ms-ping. Be honest about it.
