const std = @import("std");
const rendering = @import("compositor");

fn instance() !*rendering.Instance {
    const result = try std.testing.allocator.create(rendering.Instance);
    try result.init(std.testing.allocator, .{});
    result.state.frame_state = .updating;
    _ = rendering.textures.assignTextureId(result, @ptrFromInt(0x1000), 1, 1);
    return result;
}

fn append(context: *rendering.Instance, layer: u8) !void {
    try rendering.draw.addTexturedQuadTinted(context, 1, layer, 0, 0, 0, 1, 1, 0, 0, 4, 4, false, false, 0, 0, 0, 255, 255, 255, 255);
}

fn clean(context: *rendering.Instance) void {
    for (&context.state.layers) |*layer| {
        layer.geometry_dirty = false;
        layer.order_dirty = false;
        layer.target_dirty = false;
        layer.present_dirty = false;
    }
    context.changes = .{};
}

test "channel properties clamp and preserve distinct rasterization and presentation invalidation" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    const layer = &context.state.layers[0];
    const values = [_]struct { input: i32, expected: u8 }{
        .{ .input = -100, .expected = 0 },
        .{ .input = 128, .expected = 128 },
        .{ .input = 500, .expected = 255 },
    };
    inline for (.{ "opacity", "tint_r", "tint_g", "tint_b", "clear_r", "clear_g", "clear_b", "clear_a" }) |name| {
        @field(layer, name) = 127;
        for (values) |value| {
            clean(context);
            context.frame_ready = true;
            context.state.layer_prop_buffer[0] = .{
                .layer_id = 0,
                .field = @intFromEnum(@field(rendering.types.LayerPropField, name)),
                .value = value.input,
            };
            try std.testing.expectEqual(@as(usize, 1), try rendering.layers.submitLayerPropCommands(context, 1));
            try std.testing.expectEqual(value.expected, @field(layer, name));
            try std.testing.expectEqual(std.mem.startsWith(u8, name, "clear_"), layer.target_dirty);
            try std.testing.expect(layer.present_dirty);
            try std.testing.expect(!layer.geometry_dirty);
            try std.testing.expect(!layer.order_dirty);
            try std.testing.expect(context.changes.present_needed);
            try std.testing.expect(!context.changes.scene_changed);
            try std.testing.expect(!context.frame_ready);

            clean(context);
            context.frame_ready = true;
            try std.testing.expectEqual(@as(usize, 0), try rendering.layers.submitLayerPropCommands(context, 1));
            try std.testing.expect(!layer.target_dirty);
            try std.testing.expect(!layer.present_dirty);
            try std.testing.expect(!context.changes.present_needed);
            try std.testing.expect(context.frame_ready);
        }
    }
}

test "append invalidates pixels only after admission including first draw" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    clean(context);
    try append(context, 31);
    try std.testing.expect(context.state.layers[31].target_dirty);
    for (1..context.draw_storage.config.reserved) |_| try append(context, 31);
    clean(context);
    try std.testing.expectError(error.LayerSlabFull, append(context, 31));
    try std.testing.expect(!context.state.layers[31].target_dirty);
    try std.testing.expect(!context.changes.scene_changed);
}

test "invalidation finds every reference including hidden layers without changing order" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    try append(context, 0);
    try append(context, 31);
    context.state.layers[31].visible = false;
    clean(context);
    rendering.layers.invalidateTexture(context, 2, true);
    rendering.layers.invalidateTexture(context, 0, true);
    rendering.layers.invalidateTexture(context, rendering.types.max_texture_ids, true);
    try std.testing.expect(!context.changes.present_needed);
    rendering.layers.invalidateTexture(context, 1, false);
    for ([_]u8{ 0, 31 }) |layer| {
        try std.testing.expect(context.state.layers[layer].target_dirty);
        try std.testing.expect(context.state.layers[layer].present_dirty);
        try std.testing.expect(!context.state.layers[layer].geometry_dirty);
        try std.testing.expect(!context.state.layers[layer].order_dirty);
    }
    try std.testing.expect(context.changes.present_needed);
    try std.testing.expect(!context.changes.scene_changed);
    try std.testing.expect(!context.state.layers[1].target_dirty);
    rendering.layers.invalidateTexture(context, 1, true);
    try std.testing.expect(context.state.layers[0].geometry_dirty);
    try std.testing.expect(context.state.layers[31].geometry_dirty);
}

test "release and ID reuse invalidate geometry only in their owning instance" {
    const first = try instance();
    defer std.testing.allocator.destroy(first);
    defer first.draw_storage.deinit();
    const second = try instance();
    defer std.testing.allocator.destroy(second);
    defer second.draw_storage.deinit();
    try append(first, 0);
    try append(second, 0);
    clean(first);
    clean(second);
    rendering.textures.releaseTextureId(first, 1);
    try std.testing.expect(first.state.layers[0].geometry_dirty);
    try std.testing.expect(first.state.layers[0].target_dirty);
    try std.testing.expect(!second.state.layers[0].target_dirty);
    clean(first);
    try std.testing.expectEqual(@as(?u16, 1), rendering.textures.assignTextureId(first, @ptrFromInt(0x2000), 2, 1));
    try std.testing.expect(first.state.layers[0].geometry_dirty);
    try std.testing.expect(first.state.layers[0].target_dirty);
    try std.testing.expect(!second.state.layers[0].target_dirty);
}
