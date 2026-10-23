const std = @import("std");
const rendering = @import("compositor");
const types = rendering.types;

fn instance() !*rendering.Instance {
    const result = try std.testing.allocator.create(rendering.Instance);
    try result.init(std.testing.allocator, .{});
    result.state.frame_state = .updating;
    const fake_texture: *rendering.sdl.SDL_Texture = @ptrFromInt(0x1000);
    _ = rendering.textures.assignTextureId(result, fake_texture, 1, 1);
    _ = rendering.textures.assignTextureId(result, fake_texture, 1, 1);
    result.state.graphics[0].texture_ids[0] = 1;
    result.state.graphics[1].texture_ids[0] = 2;
    return result;
}

fn append(context: *rendering.Instance, texture: u16, layer: u8, priority: c_int, angle: f64) !void {
    try rendering.draw.addTexturedQuadTinted(context, texture, layer, priority, 0, 0, 1, 1, 0, 0, 4, 4, false, false, 2, 2, angle, 255, 255, 255, 255);
}

fn external(graphic: c_int) types.ExternalDrawInstruction {
    return .{
        .x_loc = 0,
        .y_loc = 0,
        .width = 1,
        .height = 1,
        .x_dest = 0,
        .y_dest = 0,
        .w_dest = 4,
        .h_dest = 4,
        .graphic_index = graphic,
        .palette_index = 0,
        .layer_id = 0,
        .priority = 0,
        .center_x = 0,
        .center_y = 0,
        .angle = 0,
        .flip_h = 0,
        .flip_v = 0,
    };
}

test "ordering ignores texture and complexity while retaining priority and decoding" {
    const earlier: types.SortedDrawRef = .{ .key = rendering.geometry.packKey(0, 500, 0, false) };
    const later: types.SortedDrawRef = .{ .key = rendering.geometry.packKey(0, 1, 1, true) };
    try std.testing.expect(rendering.geometry.compareRenderKey({}, earlier, later));
    try std.testing.expect(!rendering.geometry.compareRenderKey({}, later, earlier));
    const lower: types.SortedDrawRef = .{ .key = rendering.geometry.packKey(-1, 600, 20, false) };
    try std.testing.expect(rendering.geometry.compareRenderKey({}, lower, earlier));
    for ([_]i32{ -50000, -32768, -1, 0, 32767, 50000 }) |priority| {
        const key = rendering.geometry.packKey(priority, 500, 16383, false);
        try std.testing.expectEqual(@as(u16, 500), rendering.geometry.unpackTextureId(key));
        try std.testing.expectEqual(@as(i16, @intCast(std.math.clamp(priority, -32768, 32767))), rendering.geometry.unpackPriority(key));
    }
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(types.DrawInstruction));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(types.ExternalDrawInstruction));
}

test "single and bulk immediate submission share sequence and priority ordering" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    try append(context, 2, types.immediate_layer_id, 0, 0);
    const batch = [_]types.ExternalDrawInstruction{ external(0), external(1) };
    try std.testing.expectEqual(@as(usize, 2), try rendering.draw.submitDrawInstructionsBulk(context, &batch, batch.len));
    try append(context, 1, types.immediate_layer_id, 0, 27);
    try append(context, 2, types.immediate_layer_id, -4, 0);
    rendering.geometry.sortDrawInstructions(context);
    for ([_]u16{ 4, 0, 1, 2, 3 }, 0..) |expected, position| {
        try std.testing.expectEqual(expected, context.state.sorted_draw_indices[position].index);
    }
}

test "bulk admission inspects a capacity bounded prefix and returns accepted rather than consumed count" {
    const context = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(context);
    try context.initWithDrawCapacity(std.testing.allocator, .{}, .{ .ceiling = 2, .reserved = 2 });
    defer context.draw_storage.deinit();
    context.state.frame_state = .updating;
    _ = rendering.textures.assignTextureId(context, @ptrFromInt(0x1000), 1, 1);
    context.state.graphics[0].texture_ids[0] = 1;
    const batch = [_]types.ExternalDrawInstruction{ external(-1), external(0), external(0) };
    try std.testing.expectEqual(@as(usize, 1), try rendering.draw.submitDrawInstructionsBulk(context, &batch, batch.len));
    try std.testing.expectEqual(@as(u32, 1), context.draw_storage.count);
    try std.testing.expectEqual(@as(usize, 1), try rendering.draw.submitDrawInstructionsBulk(context, batch[2..].ptr, 1));
    try std.testing.expectEqual(@as(u32, 2), context.draw_storage.count);
    try std.testing.expectEqual(@as(usize, 2), context.state.frame_stats.bulk_items_submitted);
}

test "quad geometry indices exceed u16 without narrowing" {
    const vertex_start = 65536;
    const vertices = try std.testing.allocator.alloc(rendering.sdl.SDL_Vertex, vertex_start + 4);
    defer std.testing.allocator.free(vertices);
    var indices: [6]u32 = undefined;
    var vertex_count: usize = vertex_start;
    var index_count: usize = 0;
    var instruction = std.mem.zeroes(types.DrawInstruction);
    instruction.width = 1;
    instruction.height = 1;
    instruction.w_dest = 1;
    instruction.h_dest = 1;
    try std.testing.expect(rendering.geometry.emitQuadGeometryTo(vertices, &indices, 0, 0, &vertex_count, &index_count, &instruction, .{ .width = 1, .height = 1 }));
    try std.testing.expectEqualSlices(u32, &.{ 65536, 65537, 65538, 65538, 65539, 65536 }, &indices);
}

test "typed draw kinds preserve transport bytes and reject unknown or nonfinite staged encodings" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(types.DrawInstruction));
    try std.testing.expectEqual(@as(usize, 63), @offsetOf(types.DrawInstruction, "kind"));
    var instruction = std.mem.zeroes(types.DrawInstruction);
    inline for (.{ types.DrawKind.clamped_quad, types.DrawKind.raw_uv_quad, types.DrawKind.line }) |kind| {
        instruction.kind = kind;
        try std.testing.expectEqual(@intFromEnum(kind), std.mem.asBytes(&instruction)[63]);
    }
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    try rendering.layers.setCanvasMode(context, 0, .normal);
    try rendering.layers.beginLayerReplacement(context, 0);
    defer context.draw_storage.abortReplacement();
    instruction.sort_key = rendering.geometry.packKey(0, 1, 0, false);
    instruction.width = 1;
    instruction.height = 1;
    instruction.w_dest = 1;
    instruction.h_dest = 1;
    instruction.kind = @enumFromInt(255);
    try std.testing.expectError(error.InvalidSamplingCoordinates, rendering.layers.stageLayerInstruction(context, instruction, .none));
    instruction.kind = .raw_uv_quad;
    instruction.x_loc = std.math.nan(f32);
    try std.testing.expectError(error.InvalidSamplingCoordinates, rendering.layers.stageLayerInstruction(context, instruction, .none));
    instruction.x_loc = 0;
    try rendering.layers.stageLayerInstruction(context, instruction, .none);
}

test "retained replacement followed by append preserves sequence" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    context.state.layer_staging_buffers[0][0] = external(1);
    context.state.layer_staging_buffers[0][1] = external(0);
    try std.testing.expectEqual(@as(usize, 2), try rendering.layers.submitLayer(context, 0, 2));
    try append(context, 2, 0, 0, 27);
    try rendering.layers.compileDirtyRetainedLayers(context);
    for (0..3) |position| try std.testing.expectEqual(@as(u16, @intCast(position)), context.state.layer_sorted_refs[position].index);
    try std.testing.expectEqual(@as(u16, 3), context.state.layers[0].run_count);
}

test "full retained capacity covers every run and index at the final layer offset" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    const layer_id: u8 = types.max_layers - 1;
    for (0..context.draw_storage.config.reserved) |position| try append(context, @intCast(1 + position % 2), layer_id, 0, 0);
    try std.testing.expectError(error.LayerSlabFull, append(context, 1, layer_id, 0, 0));
    try rendering.layers.compileDirtyRetainedLayers(context);
    const layer = context.state.layers[layer_id];
    try std.testing.expectEqual(context.draw_storage.config.reserved, layer.run_count);
    try std.testing.expectEqual(context.draw_storage.config.reserved * 4, layer.cached_vertex_count);
    try std.testing.expectEqual(context.draw_storage.config.reserved * 6, layer.cached_index_count);
    try std.testing.expectEqual(@as(u32, 0), layer.cached_vertex_start);
    try std.testing.expectEqual(@as(u32, 0), layer.cached_index_start);
    for (layer.runs[0..layer.run_count], 0..) |run, position| {
        try std.testing.expectEqual(@as(u16, @intCast(1 + position % 2)), run.texture_id);
        try std.testing.expectEqual(@as(u32, @intCast(position * 6)), run.index_start);
        try std.testing.expectEqual(@as(u32, 6), run.index_count);
        try std.testing.expectEqual(@as(u32, @intCast(position * 4)), run.vertex_start);
        try std.testing.expectEqual(@as(u32, 4), run.vertex_count);
        for ([_]u16{ 0, 1, 2, 2, 3, 0 }, 0..) |offset, triangle_index| {
            try std.testing.expectEqual(@as(u32, @intCast(position * 4 + offset)), context.state.cached_index_buffer[layer.cached_index_start + position * 6 + triangle_index]);
        }
    }
}

test "maximum immediate admission retains sequence without overflowing reference indices" {
    const context = try instance();
    defer std.testing.allocator.destroy(context);
    defer context.draw_storage.deinit();
    for (0..context.draw_storage.config.reserved) |position| try append(context, @intCast(2 - position % 2), types.immediate_layer_id, 0, 0);
    try std.testing.expectError(error.ImmediateQueueFull, append(context, 1, types.immediate_layer_id, 0, 0));
    rendering.geometry.sortDrawInstructions(context);
    for (context.state.sorted_draw_indices[0..context.draw_storage.config.reserved], 0..) |reference, position| {
        try std.testing.expectEqual(@as(u16, @intCast(position)), reference.index);
    }
}
