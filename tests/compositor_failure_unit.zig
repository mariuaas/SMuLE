const std = @import("std");
const rendering = @import("compositor");

test "fault schedules are instance-local one-shot and occurrence-based" {
    var first: rendering.faults.Faults = .{};
    var second: rendering.faults.Faults = .{};
    first.inject(.geometry, 1);
    try std.testing.expect(!first.check(.geometry));
    try std.testing.expect(!second.check(.geometry));
    try std.testing.expect(!first.check(.blit));
    try std.testing.expect(first.check(.geometry));
    try std.testing.expect(!first.check(.geometry));
}

test "unavailable renderer returns errors and preserves submissions and retry request" {
    const context = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(context);
    try context.init(std.testing.allocator, .{});
    defer context.deinit();
    context.state.instruction_count = 1;
    context.state.layers[0].present_dirty = true;
    try std.testing.expectError(error.RendererUnavailable, rendering.compositor.executeCompositeFrame(context));
    try std.testing.expect(context.changes.present_needed);
    try std.testing.expect(context.state.layers[0].present_dirty);
    try std.testing.expectEqual(@as(usize, 1), context.state.instruction_count);
    try std.testing.expect(!context.frame_ready);
    try std.testing.expectError(error.RendererUnavailable, rendering.compositor.present(context));
    try std.testing.expectEqual(@as(usize, 1), context.state.instruction_count);
}

test "resource invalidation revokes a composed frame without recompiling pixels-only edits" {
    const context = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(context);
    try context.init(std.testing.allocator, .{});
    defer context.deinit();
    context.state.layers[31].slab_count = 1;
    var retained = std.mem.zeroes(rendering.types.DrawInstruction);
    retained.sort_key = rendering.geometry.packKey(0, 1, 0, true);
    _ = try context.draw_storage.append(31, retained, .none);
    context.frame_ready = true;
    rendering.layers.invalidateTexture(context, 2, false);
    try std.testing.expect(context.frame_ready);
    rendering.layers.invalidateTexture(context, 1, false);
    try std.testing.expect(!context.frame_ready);
    try std.testing.expect(!context.state.layers[31].geometry_dirty);
    try std.testing.expect(context.state.layers[31].target_dirty);
    try std.testing.expect(context.state.layers[31].present_dirty);
}

test "invalidation checks the full bounded immediate queue without consuming submissions" {
    const context = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(context);
    try context.init(std.testing.allocator, .{});
    defer context.deinit();
    context.state.instruction_count = rendering.types.max_immediate;
    for (0..context.state.instruction_count) |index| {
        var instruction = std.mem.zeroes(rendering.types.DrawInstruction);
        instruction.sort_key = rendering.geometry.packKey(0, if (index + 1 == context.state.instruction_count) 1 else 2, index, true);
        _ = try context.draw_storage.append(rendering.draw_storage.immediate_owner, instruction, .none);
    }
    context.frame_ready = true;
    context.changes = .{};
    rendering.layers.invalidateTexture(context, 3, false);
    try std.testing.expect(context.frame_ready);
    try std.testing.expect(!context.changes.present_needed);
    rendering.layers.invalidateTexture(context, 1, false);
    try std.testing.expect(!context.frame_ready);
    try std.testing.expect(context.changes.present_needed);
    try std.testing.expectEqual(@as(usize, rendering.types.max_immediate), context.state.instruction_count);
    try std.testing.expect(!context.state.layers[0].target_dirty);
}
