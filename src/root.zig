pub const math = @import("math.zig");
pub const wave_query = @import("wave_query.zig");
pub const ocean_params = @import("ocean_params.zig");
pub const yaml_loader = @import("yaml_loader.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
