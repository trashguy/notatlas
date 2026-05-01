-- notatlas — Dev Database Bootstrap
-- Auto-runs on first podman-compose up via docker-entrypoint-initdb.d
--
-- Schema scope: persistence-writer service (sole PG writer per locked
-- architecture decision 5, docs/02-architecture.md §5). Tables are split
-- into three persistence scopes:
--
--   1. Wipe-scoped       — characters, disciplines, inventories, claims,
--                          market, fog-of-war. Cascade-deleted (or row-
--                          tombstoned) on wipe via cycle_id FK.
--   2. Account-persistent — accounts, cosmetics, veteran tier. Survive
--                          all wipes.
--   3. Cycle metadata    — wipe_cycles, the source of truth for "what
--                          cycle is current".
--
-- Seasonal wipe cadence: 8-12 weeks (memory: design_wipe_cycle.md). v0
-- target = 10 weeks (locked_design_caps.md). Every wipe-scoped row
-- references cycle_id so a wipe is `INSERT INTO wipe_cycles ...` plus
-- a cascade delete; no schema migration.

-- =============================================================================
-- Cycle metadata
-- =============================================================================

CREATE TABLE wipe_cycles (
    id           BIGSERIAL PRIMARY KEY,
    label        VARCHAR(64) NOT NULL,           -- e.g. "S1", "S2-rerun"
    started_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ends_at      TIMESTAMPTZ,                    -- NULL = current cycle
    notes        TEXT
);

-- Exactly one current cycle (ends_at IS NULL).
CREATE UNIQUE INDEX wipe_cycles_one_current
    ON wipe_cycles ((ends_at IS NULL))
    WHERE ends_at IS NULL;

-- =============================================================================
-- Account-persistent (survive all wipes)
-- =============================================================================

CREATE TABLE accounts (
    id           BIGSERIAL PRIMARY KEY,
    username     VARCHAR(32) UNIQUE NOT NULL,
    email        VARCHAR(255) UNIQUE,
    pass_hash    BYTEA NOT NULL,
    display_name VARCHAR(64),
    veteran_tier INTEGER DEFAULT 0,              -- bumped per cycle survived
    cosmetics    JSONB DEFAULT '{}'::JSONB,      -- unlocked cosmetics, account-wide
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_login   TIMESTAMPTZ,
    banned_until TIMESTAMPTZ,
    ban_reason   TEXT
);

-- =============================================================================
-- Wipe-scoped — characters and progression
-- =============================================================================

CREATE TABLE characters (
    id          BIGSERIAL PRIMARY KEY,
    account_id  BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    cycle_id    BIGINT NOT NULL REFERENCES wipe_cycles(id) ON DELETE CASCADE,
    name        VARCHAR(32) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen   TIMESTAMPTZ,
    UNIQUE (cycle_id, name),                     -- name unique per cycle
    UNIQUE (account_id, cycle_id)                -- one character per account per cycle (v0)
);

-- Discipline progress (Sailing, Combat, Survival, Crafting, ?Captaineering).
-- Mastery-based per design_leveling_no_discovery_grind.md — no Atlas
-- discovery-point grind. Discipline names are data-driven; column names
-- here are NOT enums so we can add disciplines without DDL.
CREATE TABLE disciplines (
    id            BIGSERIAL PRIMARY KEY,
    character_id  BIGINT NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
    discipline    VARCHAR(32) NOT NULL,          -- "sailing" | "combat" | ...
    level         INTEGER NOT NULL DEFAULT 1,
    xp            BIGINT  NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (character_id, discipline)
);

-- Inventory: one JSONB blob per character (decision 5, JSONB row).
-- Shape sketched, not locked — slot list with item_def_id + quantity +
-- durability + per-slot metadata. Versioned so persistence-writer can
-- migrate older rows.
CREATE TABLE inventories (
    character_id  BIGINT PRIMARY KEY REFERENCES characters(id) ON DELETE CASCADE,
    version       INTEGER NOT NULL DEFAULT 1,
    blob          JSONB   NOT NULL DEFAULT '{"slots":[]}'::JSONB,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fog-of-war: per-character chunk-discovery state. Atlas's discovery
-- map UX is preserved even though leveling no longer hangs off it
-- (design_leveling_no_discovery_grind.md). One JSONB blob keyed by
-- discovered chunk IDs.
CREATE TABLE fog_of_war (
    character_id  BIGINT PRIMARY KEY REFERENCES characters(id) ON DELETE CASCADE,
    version       INTEGER NOT NULL DEFAULT 1,
    blob          JSONB   NOT NULL DEFAULT '{"chunks":[]}'::JSONB,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- Wipe-scoped — claims and structures
-- =============================================================================

-- Claims: anchorages + structures placed within. World position lives
-- here (not in pose firehose) — claims are static state by definition.
-- 500 structures/anchorage cap is a design knob, not enforced here.
CREATE TABLE claims (
    id          BIGSERIAL PRIMARY KEY,
    cycle_id    BIGINT NOT NULL REFERENCES wipe_cycles(id) ON DELETE CASCADE,
    owner_id    BIGINT REFERENCES characters(id) ON DELETE SET NULL,
    company_id  BIGINT,                          -- FK pending (companies table)
    kind        VARCHAR(32) NOT NULL,            -- "anchorage" | "structure" | ...
    cell_x      INTEGER NOT NULL,
    cell_y      INTEGER NOT NULL,
    pos_x       REAL NOT NULL,
    pos_y       REAL NOT NULL,
    pos_z       REAL NOT NULL,
    rot_quat    REAL[] NOT NULL,                 -- [x, y, z, w]
    metadata    JSONB DEFAULT '{}'::JSONB,       -- structure type, hp, etc.
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX claims_cell_idx ON claims (cycle_id, cell_x, cell_y);
CREATE INDEX claims_owner_idx ON claims (owner_id) WHERE owner_id IS NOT NULL;

-- =============================================================================
-- Wipe-scoped — market
-- =============================================================================

CREATE TABLE market_orders (
    id            BIGSERIAL PRIMARY KEY,
    cycle_id      BIGINT NOT NULL REFERENCES wipe_cycles(id) ON DELETE CASCADE,
    character_id  BIGINT NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
    side          CHAR(1) NOT NULL CHECK (side IN ('B', 'S')),  -- buy/sell
    item_def_id   INTEGER NOT NULL,
    quantity      INTEGER NOT NULL,
    price         BIGINT  NOT NULL,              -- copper or smallest unit
    cell_x        INTEGER NOT NULL,              -- market is geo-scoped
    cell_y        INTEGER NOT NULL,
    posted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at    TIMESTAMPTZ
);

CREATE INDEX market_orders_lookup_idx
    ON market_orders (cycle_id, cell_x, cell_y, item_def_id, side, price);

CREATE TABLE market_trades (
    id              BIGSERIAL PRIMARY KEY,
    cycle_id        BIGINT NOT NULL REFERENCES wipe_cycles(id) ON DELETE CASCADE,
    buy_order_id    BIGINT REFERENCES market_orders(id) ON DELETE SET NULL,
    sell_order_id   BIGINT REFERENCES market_orders(id) ON DELETE SET NULL,
    buyer_id        BIGINT REFERENCES characters(id) ON DELETE SET NULL,
    seller_id       BIGINT REFERENCES characters(id) ON DELETE SET NULL,
    item_def_id     INTEGER NOT NULL,
    quantity        INTEGER NOT NULL,
    price           BIGINT  NOT NULL,
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX market_trades_item_idx ON market_trades (cycle_id, item_def_id, executed_at);

-- =============================================================================
-- Wipe-scoped — damage / event log (analytics aggregate)
-- =============================================================================
--
-- Decision 5 says the live damage log is JetStream KV with TTL. This
-- table is the persistence-writer's batched aggregate for end-of-cycle
-- stats and leaderboards — not on the read path during play. Workqueue
-- consumer ack-once → batch insert here.
CREATE TABLE damage_log (
    id              BIGSERIAL PRIMARY KEY,
    cycle_id        BIGINT NOT NULL REFERENCES wipe_cycles(id) ON DELETE CASCADE,
    attacker_id     BIGINT,                      -- entity_id (top-byte tagged)
    victim_id       BIGINT NOT NULL,
    damage          REAL   NOT NULL,
    hp_after        REAL,
    cell_x          INTEGER,
    cell_y          INTEGER,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX damage_log_victim_idx ON damage_log (cycle_id, victim_id, occurred_at);
CREATE INDEX damage_log_attacker_idx ON damage_log (cycle_id, attacker_id, occurred_at);

-- =============================================================================
-- Wipe-scoped — cross-cell handoff log (analytics aggregate)
-- =============================================================================
--
-- One row per entity cell-transition. The live oracle is spatial-index
-- (idx.spatial.cell.<x>_<y>.delta is the canonical wire); this PG table
-- is the post-cycle audit trail — useful for "who-was-where-when" and
-- detecting spawn-camp / cross-cell griefing patterns. NOT on the read
-- path during play.
CREATE TABLE cell_handoffs (
    id              BIGSERIAL PRIMARY KEY,
    cycle_id        BIGINT NOT NULL REFERENCES wipe_cycles(id) ON DELETE CASCADE,
    entity_id       BIGINT NOT NULL,
    from_cell_x     INTEGER NOT NULL,
    from_cell_y     INTEGER NOT NULL,
    to_cell_x       INTEGER NOT NULL,
    to_cell_y       INTEGER NOT NULL,
    pos_x           REAL,
    pos_y           REAL,
    pos_z           REAL,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX cell_handoffs_entity_idx ON cell_handoffs (cycle_id, entity_id, occurred_at);
CREATE INDEX cell_handoffs_to_cell_idx ON cell_handoffs (cycle_id, to_cell_x, to_cell_y, occurred_at);

-- =============================================================================
-- Bootstrap: open the first wipe cycle.
-- =============================================================================

INSERT INTO wipe_cycles (label, started_at)
VALUES ('S0-dev', NOW());
