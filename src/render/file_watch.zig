//! Linux-only inotify wrapper for M2.6 hot-reload. Watches three
//! directories (data/, data/waves/, assets/shaders/) and filters events
//! to the specific filenames the renderer cares about.
//!
//! Why directories, not files: editors save by writing a temp file then
//! renaming over the target. An inotify watch on the *file* points at
//! the original inode and never fires for the new one. Watching the
//! parent directory + matching by basename catches both atomic-rename
//! and direct-write workflows.
//!
//! `poll()` is non-blocking and intended to run once per frame. Multiple
//! events for the same target within a single poll coalesce into one
//! flag.
//!
//! On non-Linux targets (Windows cross-compile for soak builds) `Watcher`
//! is a no-op stub with the same API — hot-reload is a dev-only feature.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

pub const Events = packed struct {
    wave: bool = false,
    ocean: bool = false,
    hull: bool = false,
    wind: bool = false,
    shader: bool = false,
    /// M13.2 — any `.gltf` file under `data/props/` changed. Single
    /// bool because there's one active glTF asset in the sandbox; M15
    /// will fan this out per-manifest-entry.
    gltf: bool = false,

    pub fn any(self: Events) bool {
        return self.wave or self.ocean or self.hull or self.wind or self.shader or self.gltf;
    }
};

pub const Paths = struct {
    data_dir: [:0]const u8 = "data",
    waves_dir: [:0]const u8 = "data/waves",
    ships_dir: [:0]const u8 = "data/ships",
    props_dir: [:0]const u8 = "data/props",
    shaders_dir: [:0]const u8 = "assets/shaders",
    wave_basename: []const u8 = "storm.yaml",
    hull_basename: []const u8 = "box.yaml",
};

pub const Watcher = if (builtin.os.tag == .linux) LinuxWatcher else StubWatcher;

const LinuxWatcher = struct {
    fd: i32,
    wd_data: i32,
    wd_waves: i32,
    wd_ships: i32,
    wd_props: i32,
    wd_shaders: i32,

    /// Basename of the active wave config, e.g. "storm.yaml". The watcher
    /// only flags `wave` when an event matches this name; other files in
    /// data/waves/ are ignored.
    wave_basename: []const u8,
    /// Basename of the active hull config, e.g. "box.yaml". Same filter
    /// pattern as `wave_basename`.
    hull_basename: []const u8,

    pub fn init(paths: Paths) !LinuxWatcher {
        const fd = try posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        errdefer posix.close(fd);

        const mask: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO;
        const wd_data = try posix.inotify_add_watch(fd, paths.data_dir, mask);
        const wd_waves = try posix.inotify_add_watch(fd, paths.waves_dir, mask);
        const wd_ships = try posix.inotify_add_watch(fd, paths.ships_dir, mask);
        // Props dir is optional — only fail-soft if missing so older
        // setups without data/props/ don't error at startup.
        const wd_props = posix.inotify_add_watch(fd, paths.props_dir, mask) catch -1;
        const wd_shaders = try posix.inotify_add_watch(fd, paths.shaders_dir, mask);

        return .{
            .fd = fd,
            .wd_data = wd_data,
            .wd_waves = wd_waves,
            .wd_ships = wd_ships,
            .wd_props = wd_props,
            .wd_shaders = wd_shaders,
            .wave_basename = paths.wave_basename,
            .hull_basename = paths.hull_basename,
        };
    }

    pub fn deinit(self: *LinuxWatcher) void {
        posix.close(self.fd);
    }

    /// Drain the event queue and return what was touched. Never blocks.
    pub fn poll(self: *LinuxWatcher) Events {
        var events: Events = .{};
        // 4 KiB holds ~250 events worst case — far more than a single
        // editor save produces. If a flood ever exceeds this, the next
        // frame drains the rest; nothing is lost beyond a one-frame delay.
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        while (true) {
            const n = posix.read(self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return events,
                else => return events,
            };
            if (n == 0) return events;

            var off: usize = 0;
            while (off < n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                const total = @sizeOf(linux.inotify_event) + ev.len;
                defer off += total;

                const name = ev.getName() orelse continue;
                if (ev.wd == self.wd_data) {
                    if (std.mem.eql(u8, name, "ocean.yaml")) events.ocean = true;
                    if (std.mem.eql(u8, name, "wind.yaml")) events.wind = true;
                } else if (ev.wd == self.wd_waves) {
                    if (std.mem.eql(u8, name, self.wave_basename)) events.wave = true;
                } else if (ev.wd == self.wd_ships) {
                    if (std.mem.eql(u8, name, self.hull_basename)) events.hull = true;
                } else if (ev.wd == self.wd_props and self.wd_props >= 0) {
                    // M13.2 — fire on any `.gltf` save. M15 will fan
                    // out per-manifest-entry; for now there's a single
                    // active glTF asset in the sandbox.
                    if (std.mem.endsWith(u8, name, ".gltf")) {
                        events.gltf = true;
                    }
                } else if (ev.wd == self.wd_shaders) {
                    // Match by extension so future passes (M5+ ships,
                    // structures) auto-reload without an enumeration.
                    if (std.mem.endsWith(u8, name, ".vert") or
                        std.mem.endsWith(u8, name, ".frag"))
                    {
                        events.shader = true;
                    }
                }
            }
        }
    }
};

const StubWatcher = struct {
    pub fn init(_: Paths) !StubWatcher {
        return .{};
    }
    pub fn deinit(_: *StubWatcher) void {}
    pub fn poll(_: *StubWatcher) Events {
        return .{};
    }
};
