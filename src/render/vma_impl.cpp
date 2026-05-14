// VMA is a single-header C++ library. The header is the API by default;
// to compile the implementation into our binary we include it once with
// VMA_IMPLEMENTATION defined. This file is that one TU.
//
// Per `feedback_thin_c_bindings.md`: we vendor VMA's source under
// vendor/VulkanMemoryAllocator (pinned to v3.3.0) and bind against its
// own C API (extern "C" in vk_mem_alloc.h). The Zig side is
// src/render/vma.zig — purely a @cImport on the same header.
//
// Static-dispatch knobs:
//   - VMA_STATIC_VULKAN_FUNCTIONS=1: VMA looks up vk* function pointers
//     via the linker (since we statically link libvulkan / vulkan-1.lib).
//     Avoids requiring the caller to pass a VmaVulkanFunctions table.
//   - VMA_DYNAMIC_VULKAN_FUNCTIONS=0: no runtime vkGetInstanceProcAddr
//     dance; we already have the function symbols at link time.

#define VMA_STATIC_VULKAN_FUNCTIONS 1
#define VMA_DYNAMIC_VULKAN_FUNCTIONS 0
#define VMA_IMPLEMENTATION
#include "vk_mem_alloc.h"
