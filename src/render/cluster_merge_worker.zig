//! M11.3 off-thread cluster-merge worker.
//!
//! Owns one `std.Thread` that runs `mergeCluster` on `MergeJob`s from a
//! mutex-guarded queue. Producers (main thread) enqueue jobs; consumers
//! (also main thread) drain completed results. The worker NEVER touches
//! Vulkan — by contract, command-buffer recording is single-threaded on
//! the main thread in this engine (see Frame in `frame.zig`). The
//! worker's product is a pair of CPU-side `MergedVertex` / `u32` slices
//! plus the bounding-sphere stats; the main thread converts those into a
//! `MergedMesh` via `MergedMesh.initFromCpu`.
//!
//! Why a worker for what is effectively a memcpy + transform: damage /
//! placement events in Phase 3 will re-trigger merges, and the gate
//! says <100 ms with no main-thread stall. Even at the 2-3 ms sync
//! ceiling (measured at M11.1 / M11.2), a stutter at the start of the
//! next frame is unwanted. Pushing the bake to a worker hides that
//! cost behind the in-flight GPU work.
//!
//! Double-buffering: applied on the `Anchorage` side via
//! `Anchorage.applyMerge`, which does a `vkDeviceWaitIdle` before
//! freeing the old `MergedMesh`. Acceptable for v0 because invalidate
//! is rare (damage events / placement, not per-frame). When the merge
//! rate climbs in Phase 3 content scaling, swap this for a per-frame
//! pending-destroy ring keyed on the in-flight fence.
//!
//! Initial merge is still synchronous (see `Anchorage.init`). Worker
//! handles invalidate paths only — keeps the "anchorage is always
//! renderable" invariant and avoids a "merge pending" branch in the
//! render path. Fully-async initial merge is a follow-up if Phase 3
//! ever needs streaming anchorages.

const std = @import("std");
const notatlas = @import("notatlas");
const palette_mod = @import("mesh_palette.zig");
const cm = @import("cluster_merge.zig");

const Mat4 = notatlas.math.Mat4;

/// Worker-owned job copy. The caller hands us slices it owns; we dup
/// them into worker-allocated storage so the worker thread can outlive
/// the call frame. `pieces` is a slice of value structs (PieceMesh =
/// pointer + length to vertex/index slices that ARE caller-owned). We
/// assume those vertex/index slices are static palette data with a
/// lifetime longer than the worker — palette geometry doesn't churn.
pub const Job = struct {
    anchorage_id: u64,
    pieces: []palette_mod.PieceMesh,
    transforms: []Mat4,
    albedos: [][4]f32,
};

/// Worker-allocated result. Caller frees slices after applying.
pub const Result = struct {
    anchorage_id: u64,
    vertices: []cm.MergedVertex,
    indices: []u32,
    stats: cm.MergeStats,
    elapsed_ns: u64,
};

pub const WorkerError = error{
    WorkerNotRunning,
} || cm.MergeError || std.Thread.SpawnError;

pub const Worker = struct {
    gpa: std.mem.Allocator,
    thread: std.Thread,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    jobs: std.ArrayList(Job),
    results: std.ArrayList(Result),
    /// Acquire-release; producer sets, worker reads. Worker also wakes
    /// from `cond.wait` to re-check.
    shutdown: std.atomic.Value(bool),

    pub fn spawn(gpa: std.mem.Allocator) WorkerError!*Worker {
        // Heap-allocate so the thread can hold a pointer that outlives
        // the call frame; caller stores it for the program lifetime.
        const self = try gpa.create(Worker);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .thread = undefined,
            .jobs = .empty,
            .results = .empty,
            .shutdown = .init(false),
        };

        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Worker) void {
        // Tell the worker to stop, kick the cond so it wakes from any
        // wait, join the thread. Then drain whatever's left in queues.
        self.mutex.lock();
        self.shutdown.store(true, .release);
        self.cond.signal();
        self.mutex.unlock();
        self.thread.join();

        // Free any unconsumed results.
        for (self.results.items) |r| {
            self.gpa.free(r.vertices);
            self.gpa.free(r.indices);
        }
        self.results.deinit(self.gpa);
        // Free any un-processed jobs — same dup pattern as enqueue.
        for (self.jobs.items) |j| freeJob(self.gpa, j);
        self.jobs.deinit(self.gpa);

        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Producer-side: deep-copy the caller's slices into worker storage
    /// and signal the worker. Returns once the job is queued — does
    /// NOT wait for the merge to complete. `pieces` slice contents are
    /// duplicated; the inner vertex/index slices they point at must
    /// outlive the worker (palette geometry — fine).
    pub fn enqueue(self: *Worker, anchorage_id: u64, job_in: cm.MergeJob) WorkerError!void {
        if (self.shutdown.load(.acquire)) return WorkerError.WorkerNotRunning;

        const n = job_in.pieces.len;
        const pieces_dup = try self.gpa.alloc(palette_mod.PieceMesh, n);
        errdefer self.gpa.free(pieces_dup);
        const transforms_dup = try self.gpa.alloc(Mat4, n);
        errdefer self.gpa.free(transforms_dup);
        const albedos_dup = try self.gpa.alloc([4]f32, n);
        errdefer self.gpa.free(albedos_dup);

        @memcpy(pieces_dup, job_in.pieces);
        @memcpy(transforms_dup, job_in.transforms);
        @memcpy(albedos_dup, job_in.albedos);

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.jobs.append(self.gpa, .{
            .anchorage_id = anchorage_id,
            .pieces = pieces_dup,
            .transforms = transforms_dup,
            .albedos = albedos_dup,
        });
        self.cond.signal();
    }

    /// Consumer-side: drain all completed results into the caller's
    /// list. Caller takes ownership of the result slices and is
    /// responsible for `gpa.free` on each `.vertices` / `.indices`.
    /// Returns 0 if nothing's ready.
    pub fn drain(self: *Worker, out: *std.ArrayList(Result)) std.mem.Allocator.Error!usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = self.results.items.len;
        if (n == 0) return 0;
        try out.appendSlice(self.gpa, self.results.items);
        self.results.clearRetainingCapacity();
        return n;
    }
};

fn freeJob(gpa: std.mem.Allocator, job: Job) void {
    gpa.free(job.pieces);
    gpa.free(job.transforms);
    gpa.free(job.albedos);
}

fn workerLoop(self: *Worker) void {
    while (true) {
        // Wait for work. Wake on either: a new job, or shutdown.
        self.mutex.lock();
        while (self.jobs.items.len == 0 and !self.shutdown.load(.acquire)) {
            self.cond.wait(&self.mutex);
        }
        if (self.shutdown.load(.acquire) and self.jobs.items.len == 0) {
            self.mutex.unlock();
            return;
        }
        const job = self.jobs.orderedRemove(0);
        self.mutex.unlock();

        // Bake outside the lock so the producer can keep enqueuing.
        const measured = cm.measureCluster(.{
            .pieces = job.pieces,
            .transforms = job.transforms,
            .albedos = job.albedos,
        }) catch |err| {
            std.log.err("worker measure[{d}]: {s}", .{ job.anchorage_id, @errorName(err) });
            freeJob(self.gpa, job);
            continue;
        };

        const verts = self.gpa.alloc(cm.MergedVertex, measured.vertices) catch |err| {
            std.log.err("worker alloc verts[{d}]: {s}", .{ job.anchorage_id, @errorName(err) });
            freeJob(self.gpa, job);
            continue;
        };
        const idxs = self.gpa.alloc(u32, measured.indices) catch |err| {
            std.log.err("worker alloc idx[{d}]: {s}", .{ job.anchorage_id, @errorName(err) });
            self.gpa.free(verts);
            freeJob(self.gpa, job);
            continue;
        };

        var timer = std.time.Timer.start() catch unreachable;
        const stats = cm.mergeCluster(.{
            .pieces = job.pieces,
            .transforms = job.transforms,
            .albedos = job.albedos,
        }, verts, idxs) catch |err| {
            std.log.err("worker merge[{d}]: {s}", .{ job.anchorage_id, @errorName(err) });
            self.gpa.free(verts);
            self.gpa.free(idxs);
            freeJob(self.gpa, job);
            continue;
        };
        const elapsed_ns = timer.read();

        freeJob(self.gpa, job);

        // Hand off.
        self.mutex.lock();
        self.results.append(self.gpa, .{
            .anchorage_id = job.anchorage_id,
            .vertices = verts,
            .indices = idxs,
            .stats = stats,
            .elapsed_ns = elapsed_ns,
        }) catch |err| {
            std.log.err("worker results append[{d}]: {s}", .{ job.anchorage_id, @errorName(err) });
            self.gpa.free(verts);
            self.gpa.free(idxs);
        };
        self.mutex.unlock();
    }
}

// --- tests ---

test "Worker spawn/enqueue/drain round-trips a synthetic job" {
    const t = std.testing;
    const gpa = std.testing.allocator;

    var worker = try Worker.spawn(gpa);
    defer worker.deinit();

    // Trivial 2-piece cluster — identity transform, single triangle each.
    const a_verts = [_]palette_mod.Vertex{
        .{ .pos = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } },
        .{ .pos = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 } },
        .{ .pos = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 } },
    };
    const idx = [_]u16{ 0, 1, 2 };
    const pieces = [_]palette_mod.PieceMesh{
        .{ .vertices = &a_verts, .indices = &idx },
        .{ .vertices = &a_verts, .indices = &idx },
    };
    const transforms = [_]Mat4{ Mat4.identity, Mat4.identity };
    const albedos = [_][4]f32{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 } };

    try worker.enqueue(0xDEAD, .{
        .pieces = &pieces,
        .transforms = &transforms,
        .albedos = &albedos,
    });

    // Spin-wait up to 1 s for the worker. In practice the merge
    // completes within microseconds; this gives CI headroom on a busy
    // box without flaking.
    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(gpa);
    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        const n = try worker.drain(&results);
        if (n > 0) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    try t.expectEqual(@as(usize, 1), results.items.len);
    const r = results.items[0];
    defer gpa.free(r.vertices);
    defer gpa.free(r.indices);

    try t.expectEqual(@as(u64, 0xDEAD), r.anchorage_id);
    try t.expectEqual(@as(u32, 6), r.stats.vertex_count);
    try t.expectEqual(@as(u32, 6), r.stats.index_count);
    try t.expectEqual(@as(f32, 1), r.vertices[0].albedo[0]);
    try t.expectEqual(@as(f32, 1), r.vertices[3].albedo[1]); // piece B green
}
