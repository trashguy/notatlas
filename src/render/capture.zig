//! RenderDoc in-application capture API. Wayland-safe path: librenderdoc
//! is opened from inside the process and StartFrameCapture/EndFrameCapture
//! are called explicitly around the frame, bypassing RenderDoc's launcher
//! UI hooks (which rely on X11 for Vulkan apps and don't work cleanly on
//! Wayland).
//!
//! `RENDERDOC_GetAPI(version, **api)` returns a pointer to a struct of
//! function pointers. The struct grew across releases; this file mirrors
//! the 1.6.0 layout (27 slots) with `?*anyopaque` for slots we don't
//! call, properly-typed function pointers for the three we do.
//!
//! The RenderDoc layer must be loaded BEFORE Vulkan instance creation so
//! it can hook the loader. Caller is responsible for that ordering.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{
    LibraryNotFound,
    SymbolNotFound,
    GetApiFailed,
};

const ApiVersion_1_6_0: c_int = 10600;

const StartFn = *const fn (device: ?*anyopaque, window: ?*anyopaque) callconv(.c) void;
const EndFn = *const fn (device: ?*anyopaque, window: ?*anyopaque) callconv(.c) u32;
const SetPathFn = *const fn (template: [*:0]const u8) callconv(.c) void;
const GetVersionFn = *const fn (major: *c_int, minor: *c_int, patch: *c_int) callconv(.c) void;

const Api_1_6_0 = extern struct {
    GetAPIVersion: ?GetVersionFn,
    SetCaptureOptionU32: ?*anyopaque,
    SetCaptureOptionF32: ?*anyopaque,
    GetCaptureOptionU32: ?*anyopaque,
    GetCaptureOptionF32: ?*anyopaque,
    SetFocusToggleKeys: ?*anyopaque,
    SetCaptureKeys: ?*anyopaque,
    GetOverlayBits: ?*anyopaque,
    MaskOverlayBits: ?*anyopaque,
    RemoveHooks: ?*anyopaque,
    UnloadCrashHandler: ?*anyopaque,
    SetCaptureFilePathTemplate: ?SetPathFn,
    GetCaptureFilePathTemplate: ?*anyopaque,
    GetNumCaptures: ?*anyopaque,
    GetCapture: ?*anyopaque,
    TriggerCapture: ?*anyopaque,
    IsTargetControlConnected: ?*anyopaque,
    LaunchReplayUI: ?*anyopaque,
    SetActiveWindow: ?*anyopaque,
    StartFrameCapture: ?StartFn,
    IsFrameCapturing: ?*anyopaque,
    EndFrameCapture: ?EndFn,
    TriggerMultiFrameCapture: ?*anyopaque,
    SetCaptureFileComments: ?*anyopaque,
    DiscardFrameCapture: ?*anyopaque,
    ShowReplayUI: ?*anyopaque,
    SetCaptureTitle: ?*anyopaque,
};

const GetApiFn = *const fn (version: c_int, out_api: *?*Api_1_6_0) callconv(.c) c_int;

pub const Capture = struct {
    lib: std.DynLib,
    api: *Api_1_6_0,

    /// Open librenderdoc.so, query API 1.6.0, and set the capture-file
    /// path template. Call BEFORE the Vulkan instance is created — the
    /// RenderDoc layer hooks the Vulkan loader at load time.
    ///
    /// `path_template` is the prefix; RenderDoc appends `_frameN.rdc`.
    /// The directory containing the template must already exist on disk.
    pub fn init(path_template: [:0]const u8) !Capture {
        var lib = std.DynLib.open("librenderdoc.so") catch return Error.LibraryNotFound;
        errdefer lib.close();

        const get_api = lib.lookup(GetApiFn, "RENDERDOC_GetAPI") orelse
            return Error.SymbolNotFound;

        var api_ptr: ?*Api_1_6_0 = null;
        const ok = get_api(ApiVersion_1_6_0, &api_ptr);
        if (ok != 1 or api_ptr == null) return Error.GetApiFailed;
        const api = api_ptr.?;

        if (api.SetCaptureFilePathTemplate) |set_path| {
            set_path(path_template.ptr);
        }

        if (api.GetAPIVersion) |get_ver| {
            var major: c_int = 0;
            var minor: c_int = 0;
            var patch: c_int = 0;
            get_ver(&major, &minor, &patch);
            std.log.info("renderdoc loaded, api {d}.{d}.{d}", .{ major, minor, patch });
        }

        return .{ .lib = lib, .api = api };
    }

    pub fn deinit(self: *Capture) void {
        self.lib.close();
    }

    /// Begin recording the next frame. `device` and `window` may be null —
    /// RenderDoc captures the most-recently-used Vulkan device + the
    /// only swapchain surface, which is what we want for the sandbox.
    pub fn start(self: *Capture) void {
        if (self.api.StartFrameCapture) |f| f(null, null);
    }

    /// Finalize the capture and write the .rdc file. Returns true on
    /// success. The path is `<template>_frame<N>.rdc` where N is
    /// auto-assigned by RenderDoc.
    pub fn end(self: *Capture) bool {
        if (self.api.EndFrameCapture) |f| return f(null, null) == 1;
        return false;
    }
};
