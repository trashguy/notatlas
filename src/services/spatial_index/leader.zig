//! Leader-election for spatial-index N=3 active/standby per
//! docs/08 §7.1.
//!
//! Pattern: NATS KV optimistic-lock on `idx_spatial_leader` bucket,
//! key `leader`. Bucket TTL = 3 s; leader heartbeats every 1 s. On
//! crash, entry ages out at most 3 s later; standbys claim via
//! put-and-read-back.
//!
//! nats-zig at v0.2.2 doesn't expose an Update-with-revision CAS
//! primitive (the standard NATS KV "expected_revision" header).
//! Without CAS, two standbys hitting `put` simultaneously both
//! succeed, but the second put wins (higher seq). The read-back
//! after put resolves the race deterministically: whoever's id
//! appears in the latest read is leader; the loser yields. NATS
//! subject sequencing is total-ordered so both processes converge
//! on the same view by the next tick.
//!
//! Failover budget: ~3-5 s per spec.
//!
//!     | t       | event                                                 |
//!     | 0       | leader process dies                                   |
//!     | 0–3 s   | bucket TTL ages out leader entry                       |
//!     | 3 s     | next election tick on standbys; race to claim          |
//!     | 3–4 s   | one standby wins read-back; promotes self              |
//!     | 4–5 s   | new leader resumes publishing deltas + serving queries |
//!
//! Standbys keep ingesting the `sim.entity.*.state` firehose
//! continuously regardless of role — they're state-current at NATS
//! callback granularity, no leader→follower replication. Only the
//! act of *publishing* (deltas, attach deltas, query replies) is
//! gated by `is_leader`.
//!
//! No Phase 2 dependencies on this module's internals; the public
//! surface is `init`, `tick`, `isLeader`, `deinit`.

const std = @import("std");
const nats = @import("nats");

const bucket_name = "idx_spatial_leader";
const leader_key = "leader";
const lease_ttl_ns: u64 = 3 * std.time.ns_per_s;
const heartbeat_interval_ns: u64 = std.time.ns_per_s;

pub const Election = struct {
    allocator: std.mem.Allocator,
    bucket: nats.KeyValue.Bucket,
    /// Stable per-process id used to disambiguate puts. Not freed by
    /// `deinit` — caller owns the buffer (typically a CLI arg or a
    /// heap-alloced random hex string in main).
    my_id: []const u8,
    is_leader: bool = false,
    /// Last time we successfully renewed the lease. Used to back off
    /// renew traffic — we put once per heartbeat_interval_ns, not
    /// on every tick.
    last_renew_ns: u64 = 0,
    /// Identity reported by the most recent get(). Useful for
    /// diagnostics ("standby — leader is X").
    last_seen_leader: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *nats.Client,
        my_id: []const u8,
    ) !Election {
        // Try to open the bucket first; if it doesn't exist, create
        // it. Two procs racing here both call create — one succeeds,
        // the other gets a "stream exists" error. We fall through to
        // open in either case so both end up with a usable handle.
        const bucket = nats.KeyValue.Bucket.open(client, bucket_name) catch blk: {
            const created = nats.KeyValue.Bucket.create(client, bucket_name, .{
                .ttl_ns = @as(i64, @intCast(lease_ttl_ns)),
                .history = 1,
                .num_replicas = 1,
                .max_value_size = 256, // node ids are small
                .storage = .file,
                .max_bytes = 1024 * 1024,
            }) catch {
                // Race lost (or other create failure) — try open again.
                break :blk try nats.KeyValue.Bucket.open(client, bucket_name);
            };
            break :blk created;
        };

        return .{
            .allocator = allocator,
            .bucket = bucket,
            .my_id = my_id,
        };
    }

    pub fn deinit(self: *Election) void {
        if (self.last_seen_leader) |s| self.allocator.free(s);
        self.last_seen_leader = null;
    }

    pub fn isLeader(self: *const Election) bool {
        return self.is_leader;
    }

    /// One election tick. Caller invokes ~1× per second.
    ///
    /// Returns true if this tick changed the role (promotion or
    /// demotion). Useful for logging / publish-cadence resets.
    pub fn tick(self: *Election, now_ns: u64) !bool {
        const was_leader = self.is_leader;

        // Read current leader entry. Bucket TTL handles staleness —
        // an aged-out entry returns null.
        const maybe_entry = self.bucket.get(leader_key) catch null;
        if (maybe_entry) |e| {
            var owned = e;
            defer owned.deinit();
            try self.recordSeenLeader(owned.value);
            if (std.mem.eql(u8, owned.value, self.my_id)) {
                // I am leader — renew if it's been a heartbeat
                // interval since last put.
                if (now_ns -% self.last_renew_ns >= heartbeat_interval_ns) {
                    _ = self.bucket.put(leader_key, self.my_id) catch {
                        // Failed renew; demote ourselves so we don't
                        // serve stale data.
                        self.is_leader = false;
                        return self.is_leader != was_leader;
                    };
                    self.last_renew_ns = now_ns;
                }
                self.is_leader = true;
            } else {
                // Someone else holds the lease; remain standby.
                self.is_leader = false;
            }
        } else {
            // No leader — claim. Read back to resolve concurrent
            // claims deterministically.
            _ = self.bucket.put(leader_key, self.my_id) catch {
                self.is_leader = false;
                return self.is_leader != was_leader;
            };
            self.last_renew_ns = now_ns;

            const after = self.bucket.get(leader_key) catch null;
            if (after) |e2| {
                var owned = e2;
                defer owned.deinit();
                try self.recordSeenLeader(owned.value);
                self.is_leader = std.mem.eql(u8, owned.value, self.my_id);
            } else {
                // Disappeared between our put and read — TTL very
                // short, or transient JetStream issue. Treat as
                // standby until next tick stabilizes.
                self.is_leader = false;
            }
        }

        return self.is_leader != was_leader;
    }

    fn recordSeenLeader(self: *Election, value: []const u8) !void {
        if (self.last_seen_leader) |old| {
            if (std.mem.eql(u8, old, value)) return;
            self.allocator.free(old);
        }
        self.last_seen_leader = try self.allocator.dupe(u8, value);
    }
};

/// Generate a process-unique node id from random bytes encoded as
/// 16 lowercase hex chars. Heap-alloc'd; caller frees.
pub fn generateNodeId(allocator: std.mem.Allocator) ![]u8 {
    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const hex = std.fmt.bytesToHex(seed, .lower);
    return allocator.dupe(u8, &hex);
}

const testing = std.testing;

test "generateNodeId: 16 hex chars, two calls differ" {
    const a = try generateNodeId(testing.allocator);
    defer testing.allocator.free(a);
    const b = try generateNodeId(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 16), a.len);
    try testing.expectEqual(@as(usize, 16), b.len);
    try testing.expect(!std.mem.eql(u8, a, b));
}
