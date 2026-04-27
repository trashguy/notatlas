//! Public render-layer surface. Window + GPU context (M2.1) plus the
//! swapchain and per-frame loop (M2.2).

pub const types = @import("vulkan_types.zig");
pub const window = @import("window.zig");
pub const gpu = @import("gpu.zig");
pub const swapchain = @import("swapchain.zig");
pub const frame = @import("frame.zig");

pub const Window = window.Window;
pub const GpuContext = gpu.GpuContext;
pub const Swapchain = swapchain.Swapchain;
pub const Frame = frame.Frame;
pub const DrawResult = frame.DrawResult;
