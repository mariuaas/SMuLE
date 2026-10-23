const std = @import("std");
const rendering = @import("compositor");
const sdl = rendering.sdl;

test "64 user sources plus white, full-pool replacement and failed retry" {
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("Source capacity", 8, 8, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    const instance = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(instance);
    try instance.init(std.testing.allocator, .{ .renderer = renderer, .logical_width = 8, .logical_height = 8 });
    defer instance.deinit();
    const white = instance.state.texture_table[instance.state.white_texture_id];
    try std.testing.expect(white != null);
    var ids: [64]u16 = undefined;
    for (&ids) |*id| id.* = try rendering.textures.createOperationDynamicTexture(instance, 1, 1, .operation_only);
    try std.testing.expectError(error.DynamicTexturePoolExhausted, rendering.textures.createDynamicTexture(instance, 1, 1));
    const survivor = instance.state.texture_table[ids[63]];
    try rendering.textures.destroyDynamicTexture(instance, ids[0]);
    instance.faults.inject(.operation_cpu_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, rendering.textures.createOperationDynamicTexture(instance, 2, 2, .operation_only));
    ids[0] = try rendering.textures.createOperationDynamicTexture(instance, 2, 2, .operation_only);
    try std.testing.expectEqual(white, instance.state.texture_table[instance.state.white_texture_id]);
    try std.testing.expectEqual(survivor, instance.state.texture_table[ids[63]]);
    try std.testing.expectError(error.DynamicTexturePoolExhausted, rendering.textures.createOperationDynamicTexture(instance, 1, 1, .operation_only));
    for (ids) |id| try rendering.textures.destroyDynamicTexture(instance, id);
    for (&ids) |*id| id.* = try rendering.textures.createDynamicTexture(instance, 1, 1);
    try std.testing.expectError(error.DynamicTexturePoolExhausted, rendering.textures.createDynamicTexture(instance, 1, 1));
    try std.testing.expectEqual(white, instance.state.texture_table[instance.state.white_texture_id]);
}

fn beginFrame(instance: *rendering.Instance) !void {
    instance.state.frame_state = .updating;
    instance.state.instruction_count = 0;
    instance.state.draw_list_sorted = false;
    try std.testing.expect(sdl.SDL_SetRenderTarget(instance.context.renderer, null));
    try std.testing.expect(sdl.SDL_SetRenderDrawColor(instance.context.renderer, 5, 7, 11, 255));
    try std.testing.expect(sdl.SDL_RenderClear(instance.context.renderer));
}

fn compose(instance: *rendering.Instance) !void {
    try rendering.layers.compileDirtyRetainedLayers(instance);
    try rendering.compositor.executeCompositeFrame(instance);
    instance.state.frame_state = .idle;
}

fn pixel(renderer: *sdl.SDL_Renderer, x: c_int, y: c_int) ![4]u8 {
    const surface = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackFailed;
    defer sdl.SDL_DestroySurface(surface);
    var color: [4]u8 = undefined;
    try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, x, y, &color[0], &color[1], &color[2], &color[3]));
    return color;
}

test "independent consumers own separate resources, layers, staging and geometry" {
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("Compositor isolation", 64, 48, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    std.debug.print("compositor-check: SDL {d}, renderer {s}\n", .{ sdl.SDL_GetVersion(), sdl.SDL_GetRendererName(renderer) });
    const first = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(first);
    const second = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(second);
    const context: rendering.Context = .{ .renderer = renderer, .logical_width = 64, .logical_height = 48 };
    try first.init(std.testing.allocator, context);
    var first_live = true;
    defer if (first_live) first.deinit();
    try second.init(std.testing.allocator, context);
    defer second.deinit();

    try std.testing.expect(&first.state.layers != &second.state.layers);
    try std.testing.expect(&first.state.texture_table != &second.state.texture_table);
    try std.testing.expect(&first.state.geometry_vertex_buffer != &second.state.geometry_vertex_buffer);
    try std.testing.expect(&first.state.layer_staging_buffers != &second.state.layer_staging_buffers);
    try std.testing.expect(&first.state.external_batch_buffer != &second.state.external_batch_buffer);
    try std.testing.expect(&first.state.layer_prop_buffer != &second.state.layer_prop_buffer);
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(rendering.types.ExternalDrawInstruction));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(rendering.types.LayerPropCommand));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(rendering.types.DrawInstruction));
    const staging = &second.state.layer_staging_buffers[0][0];

    const first_texture = try rendering.textures.createDynamicTexture(first, 2, 2);
    const second_texture = try rendering.textures.createDynamicTexture(second, 2, 2);
    try std.testing.expect(first.state.texture_table[first_texture] != second.state.texture_table[second_texture]);
    const red = [_]u8{ 220, 30, 40, 255 } ** 4;
    const green = [_]u8{ 20, 210, 50, 255 } ** 4;
    try rendering.textures.updateDynamicTexture(first, first_texture, 0, 0, 2, 2, &red, 8);
    try rendering.textures.updateDynamicTexture(second, second_texture, 0, 0, 2, 2, &green, 8);

    try beginFrame(first);
    first.state.layer_prop_buffer[0] = .{ .layer_id = 0, .field = @intFromEnum(rendering.types.LayerPropField.clear_a), .value = 255 };
    try std.testing.expectEqual(@as(usize, 1), try rendering.layers.submitLayerPropCommands(first, 1));
    try rendering.draw.addSolidRectToLayer(first, 0, 0, 4, 4, 12, 12, 220, 30, 40, 255);
    try compose(first);
    try std.testing.expectEqual(red[0..4].*, try pixel(renderer, 8, 8));
    try std.testing.expectEqual(@as(u16, 0), second.state.layers[0].slab_count);
    try std.testing.expectEqual(@as(usize, 0), second.state.geometry_vertex_count);
    try std.testing.expect(!second.changes.scene_changed);

    first.deinit();
    first_live = false;
    try beginFrame(second);
    const target = try rendering.render_targets.create(second, 16, 16);
    try rendering.render_targets.begin(second, target, .{});
    try rendering.draw.addTexturedQuad(second, second_texture, 0, 0, 0, 2, 2, 0, 0, 16, 16, false, false, 0, 0, 0);
    try rendering.render_targets.end(second);
    try rendering.render_targets.drawTarget(second, target, 4, 4, .{});
    try compose(second);
    try std.testing.expectEqual(green[0..4].*, try pixel(renderer, 8, 8));
    try std.testing.expect(staging == &second.state.layer_staging_buffers[0][0]);
    try rendering.render_targets.destroy(second, target);

    second.state.use_geometry_backend = false;
    try beginFrame(second);
    try rendering.draw.addTexturedQuad(second, second_texture, 0, 0, 0, 2, 2, 4, 4, 16, 16, false, false, 0, 0, 0);
    try compose(second);
    try std.testing.expectEqual(green[0..4].*, try pixel(renderer, 8, 8));
    second.deinit();
    try second.init(std.testing.allocator, context);
    try std.testing.expect(staging == &second.state.layer_staging_buffers[0][0]);
    try std.testing.expectEqual(@as(u16, 1), second.state.white_texture_id);
    try beginFrame(second);
    try rendering.draw.addSolidRect(second, 0, 4, 4, 16, 16, 20, 210, 50, 255);
    try compose(second);
    try std.testing.expectEqual(green[0..4].*, try pixel(renderer, 8, 8));
}
