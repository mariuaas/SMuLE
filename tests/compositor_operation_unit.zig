const std = @import("std");
const rendering = @import("compositor");

test "atomic raw affine settings are presentation only hidden safe and instance local" {
    const first = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(first);
    try first.init(std.testing.allocator, .{});
    defer first.deinit();
    const second = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(second);
    try second.init(std.testing.allocator, .{});
    defer second.deinit();
    const extremes = rendering.types.Affine{ .a = std.math.minInt(i32), .b = std.math.maxInt(i32), .c = -1, .d = 1, .tx = std.math.minInt(i32), .ty = std.math.maxInt(i32) };
    try std.testing.expectEqualDeep(rendering.types.Affine{}, first.state.layers[0].affine);
    try std.testing.expectError(error.WrongFrameState, rendering.layers.setAffine(first, 0, extremes));
    first.state.frame_state = .updating;
    try std.testing.expectError(error.InvalidLayerId, rendering.layers.setAffine(first, 255, extremes));
    try std.testing.expectError(error.OperationCanvasRequired, rendering.layers.setAffine(first, 0, extremes));
    try rendering.layers.setCanvasMode(first, 0, .normal);
    first.state.layer_masks.set(.visible, 0, false);
    first.state.layer_masks.set(.target_dirty, 0, false);
    first.state.layer_masks.set(.geometry_dirty, 0, false);
    first.state.layer_masks.set(.present_dirty, 0, false);
    first.state.layer_masks.set(.order_dirty, 0, false);
    first.changes = .{};
    first.frame_ready = true;
    try rendering.layers.setAffine(first, 0, extremes);
    try std.testing.expectEqualDeep(extremes, first.state.layers[0].affine);
    try std.testing.expect(!first.frame_ready);
    try std.testing.expect(first.changes.present_needed);
    try std.testing.expect(first.state.layer_masks.has(.present_dirty, 0));
    try std.testing.expect(!first.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expect(!first.state.layer_masks.has(.geometry_dirty, 0));
    try std.testing.expect(!first.state.layer_masks.has(.order_dirty, 0));
    try std.testing.expectEqualDeep(rendering.types.Affine{}, second.state.layers[0].affine);
    first.changes = .{};
    first.frame_ready = true;
    try rendering.layers.setAffine(first, 0, extremes);
    try std.testing.expect(first.frame_ready);
    try std.testing.expect(!first.changes.present_needed);
    try rendering.layers.resetLayer(first, 0);
    try std.testing.expectEqualDeep(rendering.types.Affine{}, first.state.layers[0].affine);
}

test "operation premultiplication rounds encoded byte channels exactly once" {
    for (0..256) |channel| for (0..256) |alpha| {
        const expected: u8 = @intFromFloat(@round(@as(f64, @floatFromInt(channel * alpha)) / 255));
        try std.testing.expectEqual(expected, rendering.operation.scale(@intCast(channel), @intCast(alpha)));
    };
    const color = rendering.operation.premultiplyVertex(.{ .r = 1, .g = 128.0 / 255.0, .b = 0, .a = 128.0 / 255.0 });
    try std.testing.expectEqual(@as(f32, 128.0 / 255.0), color.r);
    try std.testing.expectEqual(@as(f32, 64.0 / 255.0), color.g);
    try std.testing.expectEqual(@as(f32, 128.0 / 255.0), color.a);
}

test "legacy defaults and explicit family selection preserve geometry and classify cache changes" {
    const context = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(context);
    try context.init(std.testing.allocator, .{});
    defer context.deinit();
    try std.testing.expectEqual(rendering.types.CanvasMode.legacy_rgba, context.state.layers[0].canvas_mode);
    try std.testing.expectError(error.WrongFrameState, rendering.layers.setCanvasMode(context, 0, .normal));
    context.state.frame_state = .updating;
    try std.testing.expectError(error.InvalidLayerId, rendering.layers.setCanvasMode(context, 255, .normal));
    context.frame_ready = true;
    try rendering.layers.setCanvasMode(context, 0, .multiply);
    try std.testing.expect(context.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expect(!context.state.layer_masks.has(.geometry_dirty, 0));
    try std.testing.expect(context.state.layer_masks.has(.order_dirty, 0));
    try std.testing.expect(!context.frame_ready);
    try std.testing.expect(rendering.layers.hasVisibleRetainedLayers(context));
    context.state.layer_masks.set(.target_dirty, 0, false);
    context.state.layer_masks.set(.order_dirty, 0, false);
    context.changes = .{};
    try rendering.layers.setCanvasMode(context, 0, .multiply);
    try std.testing.expect(!context.changes.scene_changed);
    context.state.layer_prop_buffer[0] = .{ .layer_id = 0, .field = @intFromEnum(rendering.types.LayerPropField.opacity), .value = 128 };
    context.state.layer_prop_buffer[1] = .{ .layer_id = 0, .field = @intFromEnum(rendering.types.LayerPropField.tint_r), .value = 128 };
    try std.testing.expectEqual(@as(usize, 2), try rendering.layers.submitLayerPropCommands(context, 2));
    try std.testing.expect(!context.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expect(!context.state.layer_masks.has(.geometry_dirty, 0));
    try std.testing.expect(context.state.layer_masks.has(.present_dirty, 0));
    try rendering.layers.setCanvasMode(context, 0, .additive);
    try std.testing.expect(context.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expect(!context.state.layer_masks.has(.geometry_dirty, 0));
    try rendering.layers.resetLayer(context, 0);
    try std.testing.expectEqual(rendering.types.CanvasMode.legacy_rgba, context.state.layers[0].canvas_mode);
}

test "operation content settings retain geometry revoke readiness and normalize disabled clips" {
    const instance = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(instance);
    try instance.init(std.testing.allocator, .{ .logical_width = 8, .logical_height = 6 });
    defer instance.deinit();
    try std.testing.expectError(error.WrongFrameState, rendering.layers.setContentScroll(instance, 0, 1, 1));
    instance.state.frame_state = .updating;
    try std.testing.expectError(error.OperationCanvasRequired, rendering.layers.setCanvasExtent(instance, 0, 4, 3));
    try std.testing.expectError(error.InvalidLayerId, rendering.layers.setSurfaceClip(instance, 255, .{}));
    try rendering.layers.setCanvasMode(instance, 0, .normal);
    instance.state.layer_masks.set(.visible, 0, false);
    try rendering.layers.setCanvasExtent(instance, 0, 0, 0);
    try std.testing.expectEqual(@as(u16, 8), instance.state.layers[0].canvas_width);
    instance.context.logical_width = 10;
    try std.testing.expectEqual(@as(c_int, 8), rendering.textures.layerExtent(instance, &instance.state.layers[0]).width);
    instance.frame_ready = true;
    try std.testing.expectError(error.InvalidDimensions, rendering.layers.setCanvasExtent(instance, 0, 1, 0));
    try std.testing.expect(instance.frame_ready);
    for (0..2) |iteration| {
        instance.state.layer_masks.set(.target_dirty, 0, false);
        instance.changes = .{};
        instance.frame_ready = true;
        try rendering.layers.setContentScroll(instance, 0, std.math.minInt(i32), std.math.maxInt(i32));
        try std.testing.expectEqual(iteration != 0, instance.frame_ready);
        try std.testing.expectEqual(iteration == 0, instance.state.layer_masks.has(.target_dirty, 0));
        try std.testing.expectEqual(iteration == 0, instance.changes.present_needed);
        try std.testing.expect(!instance.state.layer_masks.has(.geometry_dirty, 0));
    }
    try rendering.layers.setSurfaceClip(instance, 0, .{ .x = 5, .y = 2, .w = 2, .h = 3 });
    try rendering.layers.setSurfaceClip(instance, 0, .{ .x = 65535, .w = 1, .h = 0 });
    instance.frame_ready = true;
    try rendering.layers.setSurfaceClip(instance, 0, .{ .y = 65535, .w = 0, .h = 1 });
    try std.testing.expect(instance.frame_ready);
    try std.testing.expectEqualDeep(rendering.types.SurfaceClip{}, instance.state.layers[0].surface_clip);
    try rendering.layers.resetLayer(instance, 0);
    try std.testing.expectEqual(@as(u16, 0), instance.state.layers[0].canvas_width);
    try std.testing.expectEqual(@as(i32, 0), instance.state.layers[0].content_scroll_x);
}
