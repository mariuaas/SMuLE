const std = @import("std");
const rendering = @import("compositor");
const sdl = rendering.sdl;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn quad(instance: *rendering.Instance, owner: u8, horizontal: c_int, vertical: c_int, color: [4]u8) !void {
    try rendering.draw.addTexturedQuadTinted(instance, instance.state.white_texture_id, owner, 0, 0, 0, 1, 1, horizontal, vertical, 1, 1, false, false, 0, 0, 0, color[0], color[1], color[2], color[3]);
}

fn boundaryQuad(instance: *rendering.Instance, texture: u16, ordinal: usize, raw: bool) !void {
    const destination: sdl.SDL_Rect = .{ .x = @intCast(ordinal % 16), .y = @intCast(ordinal / 16), .w = if (ordinal != 0 and ordinal % 7 == 0) 0 else 1, .h = 1 };
    if (raw) {
        try rendering.draw.addOperationQuadUV(instance, texture, 0, @intCast(ordinal), .{ .x = 0, .y = 0, .w = 1, .h = 1 }, destination, .{ 64, 96, 128, 255 });
    } else {
        try rendering.draw.addTexturedQuadTinted(instance, texture, 0, @intCast(ordinal), 0, 0, 1, 1, destination.x, destination.y, destination.w, destination.h, false, false, 0, 0, 0, 64, 96, 128, 255);
    }
}

fn checkBoundaryCache(instance: *rendering.Instance, count: u32) !void {
    const previous = instance.canvas_stats.cache_store_bytes;
    try rendering.layers.compileDirtyRetainedLayers(instance);
    const layer = &instance.state.layers[0];
    try equal(count * 4, layer.cached_vertex_count);
    try equal(count * 6, layer.cached_index_count);
    try equal(count, layer.run_count);
    try equal(@as(usize, if (count > 64) count * (4 * @sizeOf(sdl.SDL_Vertex) + 6 * @sizeOf(u32) + @sizeOf(rendering.types.TextureRun)) else 0), instance.canvas_stats.cache_store_bytes - previous);
    for (0..count) |ordinal| {
        const vertex = rendering.geometry.cachedVertex(instance, 0, ordinal * 4);
        try equal(@as(f32, @floatFromInt(ordinal % 16)), vertex.position.x);
        try equal(@as(f32, @floatFromInt(ordinal / 16)), vertex.position.y);
        var page = instance.draw_storage.owners[0].cache_first;
        for (0..ordinal / 64) |_| page = instance.draw_storage.backing.cache_pages[page].next;
        const cache = &instance.draw_storage.backing.cache[page];
        for ([_]u32{ 0, 1, 2, 2, 3, 0 }, 0..) |offset, index| try equal(@as(u32, @intCast(ordinal * 4)) + offset, cache.indices[ordinal % 64 * 6 + index]);
        try equal(@as(u32, @intCast(ordinal * 6)), layer.runs[ordinal].index_start);
    }
}

test "single page compilation boundaries reuse canonical cache through append replacement clear and growth" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const instance = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(instance);
    try instance.initWithDrawCapacity(allocator.allocator(), .{}, .{ .ceiling = 256, .reserved = 128, .payloads = 128 });
    defer instance.deinit();
    const texture = rendering.textures.assignTextureId(instance, @ptrFromInt(0x1000), 1, 1).?;
    instance.state.frame_state = .updating;
    try rendering.layers.setCanvasMode(instance, 0, .normal);
    const calls = allocator.alloc_index;
    allocator.fail_index = calls;
    try checkBoundaryCache(instance, 0);
    for (0..65) |ordinal| {
        try boundaryQuad(instance, texture, ordinal, ordinal % 2 != 0);
        if (ordinal == 0 or ordinal >= 62) try checkBoundaryCache(instance, @intCast(ordinal + 1));
    }
    for ([_]u32{ 64, 63, 1, 0 }) |count| {
        var commands: [64]rendering.types.DrawInstruction = undefined;
        var iterator = try instance.draw_storage.iterator(0);
        for (commands[0..count]) |*command| command.* = iterator.next().?.command.*;
        try rendering.layers.beginLayerReplacement(instance, 0);
        for (commands[0..count]) |command| try rendering.layers.stageLayerInstruction(instance, command, .none);
        try rendering.layers.commitLayerReplacement(instance);
        try checkBoundaryCache(instance, count);
    }
    for (0..64) |ordinal| try boundaryQuad(instance, texture, ordinal, ordinal % 2 != 0);
    try checkBoundaryCache(instance, 64);
    try rendering.layers.clearLayerContents(instance, 0);
    try checkBoundaryCache(instance, 0);
    try boundaryQuad(instance, texture, 1, true);
    try rendering.layers.compileDirtyRetainedLayers(instance);
    const canonical = rendering.geometry.cachedVertex(instance, 0, 0);
    const scratch = instance.state.cached_vertex_buffer.ptr;
    try equal(calls, allocator.alloc_index);
    allocator.fail_index = std.math.maxInt(usize);
    try instance.reserveDrawStorage(.{ .ceiling = 256, .reserved = 256, .payloads = 128 });
    try expect(scratch != instance.state.cached_vertex_buffer.ptr);
    try std.testing.expectEqualDeep(canonical, rendering.geometry.cachedVertex(instance, 0, 0));
    rendering.geometry.transferCache(instance, 0, false);
    try std.testing.expectEqualDeep(canonical, instance.state.cached_vertex_buffer[0]);
    try equal(@as(u32, 6), instance.state.layers[0].runs[0].index_count);
    var iterator = try instance.draw_storage.iterator(0);
    var sprite = iterator.next().?.command.*;
    sprite.kind = .clamped_quad;
    try rendering.layers.beginLayerReplacement(instance, 0);
    try rendering.layers.stageLayerInstruction(instance, sprite, .{ .sprite = .{} });
    try rendering.layers.commitLayerReplacement(instance);
    const stored = instance.canvas_stats.cache_store_bytes;
    const after_growth = allocator.alloc_index;
    allocator.fail_index = after_growth;
    try rendering.layers.compileDirtyRetainedLayers(instance);
    try equal(@as(usize, 4 * @sizeOf(sdl.SDL_Vertex) + 6 * @sizeOf(u32) + @sizeOf(rendering.types.TextureRun)), instance.canvas_stats.cache_store_bytes - stored);
    try equal(after_growth, allocator.alloc_index);
    try expect(!allocator.has_induced_failure);
}

test "single page pixels survive dirty refresh growth and failed rendering with pending immediates" {
    try expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("Cache page boundary", 64, 8, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    const software = std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(renderer)), "software");
    const instance = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(instance);
    try instance.initWithDrawCapacity(std.testing.allocator, .{ .renderer = renderer, .logical_width = 64, .logical_height = 8, .opaque_presentation = true }, .{ .ceiling = 256, .reserved = 128 });
    defer instance.deinit();
    instance.state.frame_state = .updating;
    if (!software) try rendering.layers.setCanvasMode(instance, 0, .normal);
    for ([_]u32{ 0, 1, 63, 64, 65 }) |count| {
        try rendering.layers.clearLayerContents(instance, 0);
        for (0..count) |ordinal| try boundaryQuad(instance, instance.state.white_texture_id, ordinal, !software and ordinal % 2 != 0);
        try rendering.layers.compileDirtyRetainedLayers(instance);
        const compiled = instance.canvas_stats.compiled_layers;
        const stored = instance.canvas_stats.cache_store_bytes;
        if (count == 63) try instance.reserveDrawStorage(.{ .ceiling = 256, .reserved = 256 });
        try quad(instance, rendering.types.immediate_layer_id, 63, 7, .{ 0, 0, 0, 255 });
        instance.faults.inject(.geometry, 0);
        try clear(renderer);
        try std.testing.expectError(error.GeometryFailed, rendering.compositor.executeCompositeFrame(instance));
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(instance));
        try equal(@as(usize, 1), instance.state.instruction_count);
        for (0..2) |pass| {
            try clear(renderer);
            try rendering.layers.compileDirtyRetainedLayers(instance);
            try rendering.compositor.executeCompositeFrame(instance);
            try equal(compiled, instance.canvas_stats.compiled_layers);
            try equal(stored, instance.canvas_stats.cache_store_bytes);
            const surface = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackFailed;
            defer sdl.SDL_DestroySurface(surface);
            for (0..8) |vertical| for (0..64) |horizontal| {
                var actual: [4]u8 = undefined;
                try expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(horizontal), @intCast(vertical), &actual[0], &actual[1], &actual[2], &actual[3]));
                const ordinal = vertical * 16 + horizontal;
                const wanted: [4]u8 = if (horizontal < 16 and ordinal < count and (ordinal == 0 or ordinal % 7 != 0)) .{ 64, 96, 128, 255 } else .{ 0, 0, 0, 255 };
                try std.testing.expectEqualDeep(wanted, actual);
            };
            try rendering.compositor.present(instance);
            if (pass == 0) rendering.layers.invalidateTexture(instance, instance.state.white_texture_id, false);
        }
    }
}

test "shared admission full replacement and live growth retain handles but rebind every borrowed workspace" {
    for ([_]u32{ 4096, 16384, 65536 }) |capacity| {
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const instance = try std.testing.allocator.create(rendering.Instance);
        defer std.testing.allocator.destroy(instance);
        try instance.initWithDrawCapacity(allocator.allocator(), .{}, .{ .ceiling = capacity * 2, .reserved = capacity, .payloads = capacity });
        defer instance.deinit();
        const id = rendering.textures.assignTextureId(instance, @ptrFromInt(0x1000), 1, 1).?;
        instance.state.white_texture_id = id;
        instance.state.graphics[0].texture_ids[0] = id;
        instance.state.frame_state = .updating;
        const allocated = allocator.alloc_index;
        allocator.fail_index = allocated;
        for (0..capacity - 1) |_| try quad(instance, 0, 0, 0, @splat(255));
        try quad(instance, rendering.types.immediate_layer_id, 0, 0, @splat(255));
        try std.testing.expectError(error.ReservationExceeded, quad(instance, 31, 0, 0, @splat(255)));
        try rendering.layers.compileDirtyRetainedLayers(instance);
        try equal(capacity - 1, instance.state.layers[0].slab_count);
        try equal(@as(u32, 1), instance.state.layers[0].run_count);
        try equal((capacity - 1) * 4 - 1, instance.state.cached_index_buffer[(capacity - 1) * 6 - 2]);
        var immediate = try instance.draw_storage.iterator(rendering.draw_storage.immediate_owner);
        const accepted = immediate.next().?;
        const handle = accepted.handle;
        const borrowed = accepted.command;
        const scratch = instance.state.geometry_vertex_buffer.ptr;
        var retained = try instance.draw_storage.iterator(0);
        const old = retained.next().?.handle;
        var external = std.mem.zeroes(rendering.types.ExternalDrawInstruction);
        external.width = 1;
        external.height = 1;
        external.w_dest = 1;
        external.h_dest = 1;
        const batch: [256]rendering.types.ExternalDrawInstruction = @splat(external);
        try rendering.layers.beginLayerReplacement(instance, 0);
        for (0..capacity / batch.len) |_| _ = try rendering.layers.stageLayerDraws(instance, &batch);
        instance.frame_ready = true;
        try std.testing.expectError(error.ReservationExceeded, rendering.layers.commitLayerReplacement(instance));
        try expect(instance.frame_ready);
        try expect(instance.draw_storage.get(old) != null);
        instance.draw_storage.abortReplacement();
        try rendering.layers.beginLayerReplacement(instance, 0);
        var remaining: usize = capacity - 1;
        while (remaining != 0) {
            const count = @min(remaining, batch.len);
            try equal(count, try rendering.layers.stageLayerDraws(instance, batch[0..count]));
            remaining -= count;
        }
        try rendering.layers.commitLayerReplacement(instance);
        try expect(instance.draw_storage.get(old) == null);
        try equal(borrowed, instance.draw_storage.get(handle).?.command);
        try rendering.layers.compileDirtyRetainedLayers(instance);
        try equal(allocated, allocator.alloc_index);
        try expect(!allocator.has_induced_failure);
        const cached = rendering.geometry.cachedVertex(instance, 0, 0);
        instance.frame_ready = true;
        try std.testing.expectError(error.OutOfMemory, instance.reserveDrawStorage(.{ .ceiling = capacity * 2, .reserved = capacity * 2, .payloads = capacity }));
        try equal(scratch, instance.state.geometry_vertex_buffer.ptr);
        try equal(borrowed, instance.draw_storage.get(handle).?.command);
        try expect(instance.frame_ready);
        allocator.fail_index = std.math.maxInt(usize);
        try instance.reserveDrawStorage(.{ .ceiling = capacity * 2, .reserved = capacity * 2, .payloads = capacity });
        try expect(!instance.frame_ready);
        try expect(instance.changes.present_needed);
        try expect(scratch != instance.state.geometry_vertex_buffer.ptr);
        try expect(borrowed != instance.draw_storage.get(handle).?.command);
        try equal(instance.draw_storage.backing.vertices.ptr, instance.state.geometry_vertex_buffer.ptr);
        try equal(instance.draw_storage.backing.indices.ptr, instance.state.geometry_index_buffer.ptr);
        try equal(instance.draw_storage.backing.sort_refs.ptr, instance.state.sorted_draw_indices.ptr);
        try equal(instance.draw_storage.backing.runs.ptr, instance.state.immediate_texture_runs.ptr);
        try equal(instance.draw_storage.backing.composition.ptr, instance.state.composite_entries.ptr);
        try equal(@as(usize, 1), instance.state.instruction_count);
        try std.testing.expectEqualDeep(cached, rendering.geometry.cachedVertex(instance, 0, 0));
        const calls = allocator.alloc_index;
        allocator.fail_index = calls;
        try quad(instance, 31, 0, 0, @splat(255));
        try rendering.layers.compileDirtyRetainedLayers(instance);
        try rendering.layers.setCanvasMode(instance, 31, .normal);
        var owner_draws = try instance.draw_storage.iterator(31);
        const rectangle = owner_draws.next().?.command.*;
        try rendering.layers.beginLayerReplacement(instance, 31);
        var invalid = rectangle;
        invalid.width = 2;
        instance.frame_ready = true;
        try std.testing.expectError(error.InvalidSourceRectangle, rendering.layers.stageLayerInstruction(instance, invalid, .{ .sprite = .{} }));
        try expect(instance.frame_ready);
        try equal(@as(u32, 1), instance.draw_storage.owners[31].count);
        instance.draw_storage.abortReplacement();
        try rendering.layers.beginLayerReplacement(instance, 31);
        try rendering.layers.stageLayerInstruction(instance, rectangle, .{ .sprite = .{} });
        instance.state.texture_dims[id].width = 0;
        try std.testing.expectError(error.InvalidSourceRectangle, rendering.layers.commitLayerReplacement(instance));
        try equal(@as(u32, 1), instance.draw_storage.owners[31].count);
        instance.state.texture_dims[id].width = 1;
        try std.testing.expectError(error.TransactionActive, rendering.compositor.present(instance));
        try std.testing.expectError(error.TransactionActive, rendering.compositor.executeCompositeFrame(instance));
        try std.testing.expectError(error.TransactionActive, rendering.compositor.renderImmediateToCurrentTarget(instance));
        try equal(@as(usize, 1), instance.state.instruction_count);
        instance.draw_storage.abortReplacement();
        try rendering.layers.beginLayerReplacement(instance, 31);
        for (0..capacity - 1) |index| {
            var instruction = rectangle;
            const primitive: rendering.draw_storage.Payload = switch (index % 4) {
                0 => .none,
                1 => .{ .sprite = .{} },
                2 => .{ .triangle = .{ .{ .x = 0, .y = 0 }, .{ .x = 256, .y = 0 }, .{ .x = 0, .y = 256 } } },
                else => .{ .line = .{ .layer_id = 31, .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 } },
            };
            if (primitive == .line) {
                instruction.sort_key = rendering.geometry.packKey(0, 0, 0, false);
                instruction.kind = rendering.types.DrawKind.line;
            }
            try rendering.layers.stageLayerInstruction(instance, instruction, primitive);
        }
        try rendering.layers.commitLayerReplacement(instance);
        try rendering.layers.compileDirtyRetainedLayers(instance);
        try equal((capacity - 1) * 4 - capacity / 4, instance.state.layers[31].cached_vertex_count);
        try equal((capacity - 1) * 6 - capacity / 4 * 3, instance.state.layers[31].cached_index_count);
        rendering.geometry.transferCache(instance, 31, false);
        rendering.geometry.lowerPayloads(instance, 31, instance.state.cached_vertex_buffer[0..instance.state.layers[31].cached_vertex_count]);
        try equal(@as(f32, 1), instance.state.cached_vertex_buffer[10].position.y);
        try std.testing.expectEqualDeep(cached, rendering.geometry.cachedVertex(instance, 0, 0));
        try equal(calls, allocator.alloc_index);
    }
}

fn checkPixels(renderer: *sdl.SDL_Renderer, alpha: u8, output_alpha: u8) !void {
    const surface = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackFailed;
    defer sdl.SDL_DestroySurface(surface);
    for (0..256) |vertical| for (0..256) |horizontal| {
        var actual: [4]u8 = undefined;
        try expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(horizontal), @intCast(vertical), &actual[0], &actual[1], &actual[2], &actual[3]));
        const wanted: [4]u8 = .{ @intCast(((horizontal * 73 + vertical * 19) % 256 * alpha + 127) / 255), @intCast(((horizontal * 29 + vertical * 131) % 256 * alpha + 127) / 255), @intCast((@as(u32, 71) * alpha + 127) / 255), output_alpha };
        for (0..3) |channel| try expect(@abs(@as(i16, actual[channel]) - wanted[channel]) <= 3);
        try equal(wanted[3], actual[3]);
    };
}

fn fill(instance: *rendering.Instance, owner: u8, alpha: u8) !void {
    for (0..256) |vertical| for (0..256) |horizontal| try quad(instance, owner, @intCast(horizontal), @intCast(vertical), .{ @intCast((horizontal * 73 + vertical * 19) % 256), @intCast((horizontal * 29 + vertical * 131) % 256), 71, alpha });
}

fn clear(renderer: *sdl.SDL_Renderer) !void {
    try expect(sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255));
    try expect(sdl.SDL_RenderClear(renderer));
}

test "65536 quads submit u32 indices as one run across pages with full independent pixels and retry" {
    try expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("Shared capacity", 256, 256, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    const software = std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(renderer)), "software");
    const instance = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(instance);
    try instance.initWithDrawCapacity(std.testing.allocator, .{ .renderer = renderer, .logical_width = 256, .logical_height = 256, .opaque_presentation = true }, .{ .ceiling = 65536, .reserved = 65536 });
    defer instance.deinit();
    instance.state.frame_state = .updating;
    if (!software) try rendering.layers.setCanvasMode(instance, 0, .normal);
    try fill(instance, 0, 255);
    try std.testing.expectError(error.LayerSlabFull, quad(instance, 31, 0, 0, @splat(255)));
    try std.testing.expectError(error.ImmediateQueueFull, quad(instance, rendering.types.immediate_layer_id, 0, 0, @splat(255)));
    try rendering.layers.compileDirtyRetainedLayers(instance);
    try equal(@as(u32, 262144), instance.state.layers[0].cached_vertex_count);
    try equal(@as(u32, 1), instance.state.layers[0].run_count);
    try equal(@as(u32, 262143), instance.state.cached_index_buffer[393214]);
    try clear(renderer);
    try rendering.compositor.executeCompositeFrame(instance);
    try equal(@as(usize, 2), instance.state.render_stats.draw_calls);
    try checkPixels(renderer, 255, 255);
    try rendering.compositor.present(instance);
    const stats = instance.canvas_stats;
    try clear(renderer);
    try rendering.layers.compileDirtyRetainedLayers(instance);
    try rendering.compositor.executeCompositeFrame(instance);
    try equal(@as(usize, 1), instance.state.render_stats.draw_calls);
    try std.testing.expectEqualDeep(stats, instance.canvas_stats);
    try checkPixels(renderer, 255, 255);
    try rendering.compositor.present(instance);
    if (!software) {
        try rendering.layers.clearLayerContents(instance, 0);
        try fill(instance, 0, 128);
        try rendering.layers.compileDirtyRetainedLayers(instance);
        try clear(renderer);
        try rendering.compositor.executeCompositeFrame(instance);
        try equal(@as(usize, 2), instance.state.render_stats.draw_calls);
        try checkPixels(renderer, 128, 255);
        const target = instance.state.texture_table[instance.state.layers[0].target_texture_id];
        try expect(sdl.SDL_SetRenderTarget(renderer, target));
        try checkPixels(renderer, 128, 128);
        try expect(sdl.SDL_SetRenderTarget(renderer, null));
        try rendering.compositor.present(instance);
    }
    try rendering.layers.resetLayer(instance, 0);
    try fill(instance, rendering.types.immediate_layer_id, 255);
    instance.faults.inject(.geometry, 0);
    try std.testing.expectError(error.GeometryFailed, rendering.compositor.executeCompositeFrame(instance));
    try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(instance));
    try equal(@as(usize, 65536), instance.state.instruction_count);
    try clear(renderer);
    try rendering.compositor.executeCompositeFrame(instance);
    try equal(@as(usize, 1), instance.state.render_stats.draw_calls);
    try equal(@as(usize, 262144), instance.state.geometry_vertex_count);
    try equal(@as(u32, 262143), instance.state.geometry_index_buffer[393214]);
    try checkPixels(renderer, 255, 255);
    try rendering.compositor.present(instance);
    try equal(@as(u32, 0), instance.draw_storage.count);
    try equal(@as(usize, 0), instance.state.instruction_count);
    std.debug.print("CAPACITY renderer={s} N=65536 retained_draws=2 cached_draws=1 immediate_draws=1 vertices=262144 indices=393216 index_bytes=4 operation_pixels={} production_readbacks={d}\n", .{ sdl.SDL_GetRendererName(renderer), !software, instance.source_stats.readbacks });
}
