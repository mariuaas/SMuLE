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
    context.state.layer_masks.geometry_dirty = 0;
    context.state.layer_masks.order_dirty = 0;
    context.state.layer_masks.target_dirty = 0;
    context.state.layer_masks.present_dirty = 0;
    context.changes = .{};
}

fn expectDerivedMasks(context: *const rendering.Instance) !void {
    for (&context.state.layers, 0..) |*layer, layer_id| {
        try std.testing.expectEqual(layer.slab_count != 0, context.state.layer_masks.has(.nonempty, layer_id));
        try std.testing.expectEqual(layer.canvas_mode != .legacy_rgba, context.state.layer_masks.has(.operation, layer_id));
        try std.testing.expectEqual(layer.clear_a != 0, context.state.layer_masks.has(.clear_alpha_nonzero, layer_id));
        try std.testing.expectEqual(layer.sampling == .bilinear, context.state.layer_masks.has(.bilinear_canvas, layer_id));
        try std.testing.expectEqual(layer.backing.border != 0, context.state.layer_masks.has(.padded_backing, layer_id));
    }
}

test "public layer mutations maintain derived masks without caller synchronization" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    try expectDerivedMasks(context);
    for ([_]u8{ 0, 15, 31 }) |layer_id| {
        context.state.layer_prop_buffer[0] = .{
            .layer_id = layer_id,
            .field = @intFromEnum(rendering.types.LayerPropField.visible),
            .value = 0,
        };
        _ = try rendering.layers.submitLayerPropCommands(context, 1);
        try std.testing.expect(!context.state.layer_masks.has(.visible, layer_id));
        for ([_]i32{ 255, 0, 1, -1, 300, 0 }) |alpha| {
            context.state.layer_prop_buffer[0] = .{
                .layer_id = layer_id,
                .field = @intFromEnum(rendering.types.LayerPropField.clear_a),
                .value = alpha,
            };
            _ = try rendering.layers.submitLayerPropCommands(context, 1);
            try expectDerivedMasks(context);
        }
        try append(context, layer_id);
        try expectDerivedMasks(context);
        for ([_]rendering.types.CanvasMode{ .normal, .multiply, .legacy_rgba, .normal }) |mode| {
            try rendering.layers.setCanvasMode(context, layer_id, mode);
            try expectDerivedMasks(context);
        }
        for ([_]rendering.types.Sampling{ .bilinear, .bilinear, .nearest }) |filter| {
            try rendering.layers.setCanvasSampling(context, layer_id, filter);
            try expectDerivedMasks(context);
        }
        try rendering.layers.beginLayerReplacement(context, layer_id);
        try expectDerivedMasks(context);
        try std.testing.expectError(error.TransactionActive, rendering.layers.clearLayerContents(context, layer_id));
        try expectDerivedMasks(context);
        context.draw_storage.abortReplacement();
        try expectDerivedMasks(context);
        try rendering.layers.beginLayerReplacement(context, layer_id);
        try rendering.layers.commitLayerReplacement(context);
        try expectDerivedMasks(context);
        try std.testing.expect(!context.state.layer_masks.has(.nonempty, layer_id));
        try append(context, layer_id);
        try rendering.layers.clearLayerContents(context, layer_id);
        try expectDerivedMasks(context);
        try rendering.layers.resetLayer(context, layer_id);
        try expectDerivedMasks(context);
        try std.testing.expect(context.state.layer_masks.has(.visible, layer_id));
    }
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
        context.state.layer_prop_buffer[0] = .{
            .layer_id = 0,
            .field = @intFromEnum(@field(rendering.types.LayerPropField, name)),
            .value = 127,
        };
        _ = try rendering.layers.submitLayerPropCommands(context, 1);
        for (values) |value| {
            const previous_alpha = layer.clear_a;
            clean(context);
            context.frame_ready = true;
            context.state.layer_prop_buffer[0] = .{
                .layer_id = 0,
                .field = @intFromEnum(@field(rendering.types.LayerPropField, name)),
                .value = value.input,
            };
            try std.testing.expectEqual(@as(usize, 1), try rendering.layers.submitLayerPropCommands(context, 1));
            try std.testing.expectEqual(value.expected, @field(layer, name));
            try std.testing.expectEqual(std.mem.startsWith(u8, name, "clear_"), context.state.layer_masks.has(.target_dirty, 0));
            try std.testing.expect(context.state.layer_masks.has(.present_dirty, 0));
            try std.testing.expect(!context.state.layer_masks.has(.geometry_dirty, 0));
            try std.testing.expectEqual(std.mem.eql(u8, name, "clear_a") and ((previous_alpha == 0) != (value.expected == 0)), context.state.layer_masks.has(.order_dirty, 0));
            try std.testing.expect(context.changes.present_needed);
            try std.testing.expect(!context.changes.scene_changed);
            try std.testing.expect(!context.frame_ready);

            clean(context);
            context.frame_ready = true;
            try std.testing.expectEqual(@as(usize, 0), try rendering.layers.submitLayerPropCommands(context, 1));
            try std.testing.expect(!context.state.layer_masks.has(.target_dirty, 0));
            try std.testing.expect(!context.state.layer_masks.has(.present_dirty, 0));
            try std.testing.expect(!context.changes.present_needed);
            try std.testing.expect(context.frame_ready);
        }
    }
}

test "geometry dirty traversal preserves ascending failure and empty disposal order" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    try append(context, 1);
    context.state.layer_masks.set(.visible, 1, false);
    context.state.layer_masks.set(.visible, 31, false);
    context.state.layer_masks.set(.geometry_dirty, 31, true);
    context.state.layers[31].cached_vertex_count = 19;
    const generation = context.draw_storage.generation;
    context.draw_storage.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, rendering.layers.compileDirtyRetainedLayers(context));
    try std.testing.expectEqual(@as(u32, 19), context.state.layers[31].cached_vertex_count);
    try std.testing.expect(context.state.layer_masks.has(.geometry_dirty, 31));
    context.draw_storage.generation = generation;
    try rendering.layers.compileDirtyRetainedLayers(context);
    try std.testing.expectEqual(@as(u32, 4), context.state.layers[1].cached_vertex_count);
    try std.testing.expectEqual(@as(u32, 0), context.state.layers[31].cached_vertex_count);
    try std.testing.expectEqual(@as(rendering.types.OwnerMask, 0), context.state.layer_masks.geometry_dirty);
}

test "derived layer masks follow append mode sampling clear and reset" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    try append(context, 31);
    try rendering.layers.setCanvasMode(context, 31, .normal);
    try rendering.layers.setCanvasSampling(context, 31, .bilinear);
    try std.testing.expect(context.state.layer_masks.has(.nonempty, 31));
    try std.testing.expect(context.state.layer_masks.has(.operation, 31));
    try std.testing.expect(context.state.layer_masks.has(.bilinear_canvas, 31));
    try rendering.layers.clearLayerContents(context, 31);
    try std.testing.expect(!context.state.layer_masks.has(.nonempty, 31));
    try std.testing.expect(context.state.layer_masks.has(.operation, 31));
    try rendering.layers.resetLayer(context, 31);
    try std.testing.expect(!context.state.layer_masks.has(.operation, 31));
    try std.testing.expect(!context.state.layer_masks.has(.bilinear_canvas, 31));
    try std.testing.expect(context.state.layer_masks.has(.visible, 31));
    try std.testing.expectEqual(@as(rendering.types.OwnerMask, 0), context.draw_storage.texture_owners[1]);
}

test "append invalidates pixels only after admission including first draw" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    clean(context);
    try append(context, 31);
    try std.testing.expect(context.state.layer_masks.has(.target_dirty, 31));
    for (1..context.draw_storage.config.reserved) |_| try append(context, 31);
    clean(context);
    try std.testing.expectError(error.LayerSlabFull, append(context, 31));
    try std.testing.expect(!context.state.layer_masks.has(.target_dirty, 31));
    try std.testing.expect(!context.changes.scene_changed);
}

test "invalidation finds every reference including hidden layers without changing order" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    try append(context, 0);
    try append(context, 31);
    context.state.layer_masks.set(.visible, 31, false);
    clean(context);
    rendering.layers.invalidateTexture(context, 2, true);
    rendering.layers.invalidateTexture(context, 0, true);
    rendering.layers.invalidateTexture(context, rendering.types.max_texture_ids, true);
    try std.testing.expect(!context.changes.present_needed);
    rendering.layers.invalidateTexture(context, 1, false);
    for ([_]u8{ 0, 31 }) |layer| {
        try std.testing.expect(context.state.layer_masks.has(.target_dirty, layer));
        try std.testing.expect(context.state.layer_masks.has(.present_dirty, layer));
        try std.testing.expect(!context.state.layer_masks.has(.geometry_dirty, layer));
        try std.testing.expect(!context.state.layer_masks.has(.order_dirty, layer));
    }
    try std.testing.expect(context.changes.present_needed);
    try std.testing.expect(!context.changes.scene_changed);
    try std.testing.expect(!context.state.layer_masks.has(.target_dirty, 1));
    rendering.layers.invalidateTexture(context, 1, true);
    try std.testing.expect(context.state.layer_masks.has(.geometry_dirty, 0));
    try std.testing.expect(context.state.layer_masks.has(.geometry_dirty, 31));
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
    try std.testing.expectEqual(rendering.types.ownerBit(0), first.draw_storage.texture_owners[1]);
    try std.testing.expect(first.state.layer_masks.has(.geometry_dirty, 0));
    try std.testing.expect(first.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expect(!second.state.layer_masks.has(.target_dirty, 0));
    clean(first);
    try std.testing.expectEqual(@as(?u16, 1), rendering.textures.assignTextureId(first, @ptrFromInt(0x2000), 2, 1));
    try std.testing.expectEqual(rendering.types.ownerBit(0), first.draw_storage.texture_owners[1]);
    try std.testing.expect(first.state.layer_masks.has(.geometry_dirty, 0));
    try std.testing.expect(first.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expect(!second.state.layer_masks.has(.target_dirty, 0));
}
