const std = @import("std");
const shared = @import("compositor");
const sdl = shared.sdl;

const Stroke = struct { start: [2]i32, end: [2]i32, width: u8, scroll: [2]i32 = .{ 0, 0 }, clip: bool = false };
const strokes = [_]Stroke{
    .{ .start = .{ 2, 4 }, .end = .{ 13, 4 }, .width = 0 },
    .{ .start = .{ 13, 4 }, .end = .{ 2, 4 }, .width = 1 },
    .{ .start = .{ 4, 2 }, .end = .{ 4, 13 }, .width = 2 },
    .{ .start = .{ 4, 13 }, .end = .{ 4, 2 }, .width = 3 },
    .{ .start = .{ 2, 3 }, .end = .{ 13, 11 }, .width = 3 },
    .{ .start = .{ 13, 11 }, .end = .{ 2, 3 }, .width = 4 },
    .{ .start = .{ 2, 2 }, .end = .{ 13, 13 }, .width = 1 },
    .{ .start = .{ 13, 2 }, .end = .{ 2, 13 }, .width = 2 },
    .{ .start = .{ 7, 7 }, .end = .{ 7, 7 }, .width = 0 },
    .{ .start = .{ 7, 7 }, .end = .{ 7, 7 }, .width = 3 },
    .{ .start = .{ 32758, 32759 }, .end = .{ 32767, 32765 }, .width = 3, .scroll = .{ 32756, 32756 }, .clip = true },
    .{ .start = .{ -32766, -32765 }, .end = .{ -32755, -32757 }, .width = 4, .scroll = .{ -32768, -32768 }, .clip = true },
};

fn number(value: i32) f64 {
    return @floatFromInt(value);
}

fn corners(stroke: Stroke) [4][2]f64 {
    const sx = number(stroke.start[0]);
    const sy = number(stroke.start[1]);
    const dx = number(stroke.end[0]) - sx;
    const dy = number(stroke.end[1]) - sy;
    const half = number(@max(1, stroke.width)) / 2;
    const length = @sqrt(dx * dx + dy * dy);
    const nx = if (length == 0) half else -dy * half / length;
    const ny = if (length == 0) half else dx * half / length;
    var points = if (length == 0) [4][2]f64{ .{ sx - half, sy - half }, .{ sx + half, sy - half }, .{ sx + half, sy + half }, .{ sx - half, sy + half } } else [4][2]f64{ .{ sx + nx, sy + ny }, .{ sx + dx + nx, sy + dy + ny }, .{ sx + dx - nx, sy + dy - ny }, .{ sx - nx, sy - ny } };
    for (&points) |*point| for (0..2) |axis| {
        point[axis] -= number(stroke.scroll[axis]);
    };
    return points;
}

fn coverage(stroke: Stroke, horizontal: usize, vertical: usize) bool {
    const px = number(@intCast(horizontal)) + 0.5 + number(stroke.scroll[0]) - number(stroke.start[0]);
    const py = number(@intCast(vertical)) + 0.5 + number(stroke.scroll[1]) - number(stroke.start[1]);
    const dx: i64 = @as(i64, stroke.end[0]) - stroke.start[0];
    const dy: i64 = @as(i64, stroke.end[1]) - stroke.start[1];
    const squared = dx * dx + dy * dy;
    const half = number(@max(1, stroke.width)) / 2;
    if (squared == 0) return px >= -half and px < half and py >= -half and py < half;
    const along = px * @as(f64, @floatFromInt(dx)) + py * @as(f64, @floatFromInt(dy));
    const across = px * @as(f64, @floatFromInt(dy)) - py * @as(f64, @floatFromInt(dx));
    const start_included = dx > 0 or (dx == 0 and dy > 0);
    const end_included = dx < 0 or (dx == 0 and dy < 0);
    if (!(along > 0 or (along == 0 and start_included))) return false;
    const end = @as(f64, @floatFromInt(squared));
    if (!(along < end or (along == end and end_included))) return false;
    const cross_squared = across * across;
    const limit = half * half * end;
    if (cross_squared != limit) return cross_squared < limit;
    return if (across > 0) (dy < 0 or (dy == 0 and dx > 0)) else (dy > 0 or (dy == 0 and dx < 0));
}

fn outsidePermission(stroke: Stroke, horizontal: usize, vertical: usize) bool {
    const points = corners(stroke);
    const point = [2]f64{ number(@intCast(horizontal)) + 0.5, number(@intCast(vertical)) + 0.5 };
    for (points, 0..) |first, index| {
        const last = points[(index + 1) % 4];
        const dx = last[0] - first[0];
        const dy = last[1] - first[1];
        const squared = dx * dx + dy * dy;
        const fraction = if (squared == 0) 0 else std.math.clamp(((point[0] - first[0]) * dx + (point[1] - first[1]) * dy) / squared, 0, 1);
        const distance_x = point[0] - first[0] - fraction * dx;
        const distance_y = point[1] - first[1] - fraction * dy;
        if (distance_x * distance_x + distance_y * distance_y <= 1.0 / 65536.0) return true;
    }
    return false;
}

fn matches(actual: [4]u8, wanted: [4]u8) bool {
    for (actual, wanted, 0..) |got, want, channel| if (@abs(@as(i16, got) - want) > (if (channel == 3) @as(i16, 0) else 3)) return false;
    return true;
}

test "direct SDL butt strokes preserve coverage and single translucent accumulation" {
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("Line gate", 16, 16, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(renderer)), "software")) {
        std.debug.print("LINE_GATE software operation rejection is not pixel qualification\n", .{});
        return;
    }
    const target = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_TARGET, 18, 18) orelse return error.TextureUnavailable;
    defer sdl.SDL_DestroyTexture(target);
    var strict_differences: usize = 0;
    for ([_]shared.types.CanvasMode{ .normal, .additive, .multiply }) |family| for (strokes, 0..) |stroke, case| {
        const identity: [4]u8 = if (family == .multiply) @splat(255) else @splat(0);
        const fragment: [4]u8 = .{ 120, 40, 20, 128 };
        const filled: [4]u8 = .{ if (family == .multiply) 247 else fragment[0], if (family == .multiply) 167 else fragment[1], if (family == .multiply) 147 else fragment[2], if (family == .normal) 128 else identity[3] };
        try std.testing.expect(sdl.SDL_SetRenderTarget(renderer, target));
        try std.testing.expect(sdl.SDL_SetRenderClipRect(renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(renderer, identity[0], identity[1], identity[2], identity[3]));
        try std.testing.expect(sdl.SDL_RenderClear(renderer));
        const clip: sdl.SDL_Rect = if (stroke.clip) .{ .x = 5, .y = 4, .w = 7, .h = 8 } else .{ .x = 1, .y = 1, .w = 16, .h = 16 };
        try std.testing.expect(sdl.SDL_SetRenderClipRect(renderer, &clip));
        try std.testing.expect(sdl.SDL_SetRenderDrawBlendMode(renderer, shared.operation.blend(family)));
        var vertices: [4]sdl.SDL_Vertex = undefined;
        for (&vertices, corners(stroke)) |*vertex, point| vertex.* = .{ .position = .{ .x = @floatCast(point[0] + 1), .y = @floatCast(point[1] + 1) }, .color = .{ .r = 120.0 / 255.0, .g = 40.0 / 255.0, .b = 20.0 / 255.0, .a = 128.0 / 255.0 }, .tex_coord = .{ .x = 0, .y = 0 } };
        try std.testing.expect(sdl.SDL_RenderGeometry(renderer, null, &vertices, 4, &[_]c_int{ 0, 1, 2, 2, 3, 0 }, 6));
        try std.testing.expect(sdl.SDL_SetRenderClipRect(renderer, null));
        const surface = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        for (0..16) |vertical| for (0..16) |horizontal| {
            var actual: [4]u8 = undefined;
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(horizontal + 1), @intCast(vertical + 1), &actual[0], &actual[1], &actual[2], &actual[3]));
            const clipped = stroke.clip and (horizontal < 4 or horizontal >= 11 or vertical < 3 or vertical >= 11);
            const wanted = if (!clipped and coverage(stroke, horizontal, vertical)) filled else identity;
            if (!matches(actual, wanted)) {
                strict_differences += 1;
                if (!clipped and outsidePermission(stroke, horizontal, vertical) and (matches(actual, identity) or matches(actual, filled))) continue;
                std.debug.print("LINE_GATE_FAILURE case={d} family={s} pixel={d},{d} expected={any} actual={any}\n", .{ case, @tagName(family), horizontal, vertical, wanted, actual });
                return error.LineSemanticsMismatch;
            }
        };
    };
    std.debug.print("LINE_GATE cases=36 strict_boundary_differences={d} policy=outside-edge-only alpha=exact seams=strict\n", .{strict_differences});
}

test "retained lines preserve raw lowering padding clips cache ownership and retry" {
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("Retained line gate", 16, 16, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    const instance = try std.testing.allocator.create(shared.Instance);
    defer std.testing.allocator.destroy(instance);
    try instance.init(std.testing.allocator, .{ .renderer = renderer, .logical_width = 16, .logical_height = 16, .opaque_presentation = true });
    defer instance.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(renderer)), "software")) return;
    instance.state.frame_state = .updating;
    try std.testing.expectError(error.OperationCanvasRequired, shared.draw.addLine(instance, .{ .layer_id = 0, .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }));
    try shared.layers.setCanvasMode(instance, 0, .normal);
    instance.faults.inject(.line_metadata_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, shared.draw.addLine(instance, .{ .layer_id = 0, .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }));
    try std.testing.expect(instance.draw_storage.owners[0].payloads == 0);
    try std.testing.expectEqual(@as(u16, 0), instance.draw_storage.owners[0].count);
    var strict_differences: usize = 0;
    for ([_]shared.types.CanvasMode{ .normal, .additive, .multiply }) |family| for (strokes) |stroke| {
        instance.state.frame_state = .updating;
        try shared.layers.clearLayerContents(instance, 0);
        try shared.layers.setCanvasMode(instance, 0, family);
        try shared.layers.setCanvasExtent(instance, 0, 16, 16);
        try shared.layers.setCanvasSampling(instance, 0, .bilinear);
        try shared.layers.setAffine(instance, 0, .{ .tx = 128 });
        try shared.layers.setContentScroll(instance, 0, stroke.scroll[0], stroke.scroll[1]);
        try shared.layers.setSurfaceClip(instance, 0, if (stroke.clip) .{ .x = 4, .y = 3, .w = 7, .h = 8 } else .{});
        try shared.draw.addLine(instance, .{ .layer_id = 0, .x0 = @intCast(stroke.start[0]), .y0 = @intCast(stroke.start[1]), .x1 = @intCast(stroke.end[0]), .y1 = @intCast(stroke.end[1]), .width = stroke.width, .color = .{ 240, 80, 40, 128 } });
        const metadata = instance.draw_storage.backing.payloads.ptr;
        try shared.layers.compileDirtyRetainedLayers(instance);
        try std.testing.expectEqual(@as(u16, 1), instance.state.layers[0].slab_count);
        try std.testing.expectEqual(@as(u16, 4), instance.state.layers[0].cached_vertex_count);
        try std.testing.expectEqual(@as(u16, 6), instance.state.layers[0].cached_index_count);
        instance.faults.inject(.geometry, 0);
        try std.testing.expectError(error.GeometryFailed, shared.compositor.executeCompositeFrame(instance));
        try std.testing.expect(instance.state.layers[0].target_dirty);
        try shared.compositor.executeCompositeFrame(instance);
        try std.testing.expect(!instance.state.layers[0].target_dirty);
        const stats = instance.canvas_stats;
        try shared.compositor.executeCompositeFrame(instance);
        try std.testing.expectEqualDeep(stats, instance.canvas_stats);
        try std.testing.expectEqual(metadata, instance.draw_storage.backing.payloads.ptr);
        const layer = instance.state.layers[0];
        try std.testing.expect(layer.backing.border != 0);
        try std.testing.expect(sdl.SDL_SetRenderTarget(renderer, instance.state.texture_table[layer.target_texture_id]));
        const surface = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        const identity: [4]u8 = if (family == .multiply) @splat(255) else @splat(0);
        const filled: [4]u8 = .{ if (family == .multiply) 247 else 120, if (family == .multiply) 167 else 40, if (family == .multiply) 147 else 20, if (family == .normal) 128 else identity[3] };
        for (0..16) |vertical| for (0..16) |horizontal| {
            var actual: [4]u8 = undefined;
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @as(c_int, @intCast(horizontal)) + layer.backing.border, @as(c_int, @intCast(vertical)) + layer.backing.border, &actual[0], &actual[1], &actual[2], &actual[3]));
            const clipped = stroke.clip and (horizontal < 4 or horizontal >= 11 or vertical < 3 or vertical >= 11);
            const wanted = if (!clipped and coverage(stroke, horizontal, vertical)) filled else identity;
            if (!matches(actual, wanted)) {
                strict_differences += 1;
                if (!clipped and outsidePermission(stroke, horizontal, vertical) and (matches(actual, identity) or matches(actual, filled))) continue;
                std.debug.print("RETAINED_LINE_FAILURE family={s} pixel={d},{d} expected={any} actual={any}\n", .{ @tagName(family), horizontal, vertical, wanted, actual });
                return error.LineSemanticsMismatch;
            }
        };
        try std.testing.expect(sdl.SDL_SetRenderTarget(renderer, null));
    };
    instance.state.frame_state = .updating;
    try std.testing.expectError(error.OperationCanvasRequired, shared.layers.setCanvasMode(instance, 0, .legacy_rgba));
    try shared.layers.clearLayerContents(instance, 0);
    try shared.draw.addSolidRectToLayer(instance, 0, 0, 0, 0, 2, 2, 255, 0, 0, 255);
    var rectangles = try instance.draw_storage.iterator(0);
    try std.testing.expect(rectangles.next().?.command.kind != shared.types.DrawKind.line);
    try shared.layers.compileDirtyRetainedLayers(instance);
    try std.testing.expectEqual(@as(u16, 0), instance.draw_storage.owners[0].payloads);
    try shared.compositor.executeCompositeFrame(instance);
    instance.state.frame_state = .updating;
    try shared.layers.resetLayer(instance, 0);
    try std.testing.expect(instance.draw_storage.owners[0].payloads == 0);
    try std.testing.expect(instance.draw_storage.owners[1].payloads == 0);
    try shared.layers.setCanvasMode(instance, 0, .normal);
    const white = instance.state.white_texture_id;
    instance.state.white_texture_id = 0;
    defer instance.state.white_texture_id = white;
    const source_allocations = instance.source_stats.cpu_allocations;
    try shared.draw.addLine(instance, .{ .layer_id = 0, .x0 = 2, .y0 = 6, .x1 = 14, .y1 = 6, .width = 4, .color = .{ 240, 80, 40, 128 } });
    try shared.draw.addTexturedTriangle(instance, .{ .layer_id = 0, .vertices = .{
        .{ .x = 0, .y = 0, .color = .{ 40, 240, 80, 128 } },
        .{ .x = 4096, .y = 0, .color = .{ 40, 240, 80, 128 } },
        .{ .x = 0, .y = 4096, .color = .{ 40, 240, 80, 128 } },
    } });
    try shared.draw.addLine(instance, .{ .layer_id = 0, .x0 = 2, .y0 = 6, .x1 = 14, .y1 = 6, .width = 4, .color = .{ 80, 40, 240, 128 } });
    try shared.layers.compileDirtyRetainedLayers(instance);
    try std.testing.expectEqual(@as(u16, 3), instance.state.layers[0].slab_count);
    try std.testing.expectEqual(@as(u16, 1), instance.state.layers[0].run_count);
    try std.testing.expectEqual(@as(u32, 15), instance.state.layers[0].runs[0].index_count);
    try std.testing.expectEqual(@as(u16, 0), instance.state.layers[0].runs[0].texture_id);
    try shared.compositor.executeCompositeFrame(instance);
    const target = instance.state.texture_table[instance.state.layers[0].target_texture_id];
    try std.testing.expect(sdl.SDL_SetRenderTarget(renderer, target));
    const mixed = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackFailed;
    defer sdl.SDL_DestroySurface(mixed);
    var actual: [4]u8 = undefined;
    try std.testing.expect(sdl.SDL_ReadSurfacePixel(mixed, 5, 5, &actual[0], &actual[1], &actual[2], &actual[3]));
    try std.testing.expect(matches(actual, .{ 80, 90, 145, 224 }));
    try std.testing.expectEqual(source_allocations, instance.source_stats.cpu_allocations);
    try std.testing.expect(sdl.SDL_SetRenderTarget(renderer, null));
    instance.state.frame_state = .updating;
    for (3..instance.draw_storage.config.reserved) |_| try shared.draw.addLine(instance, .{ .layer_id = 0, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .color = .{ 0, 0, 0, 0 } });
    try std.testing.expectError(error.LayerSlabFull, shared.draw.addLine(instance, .{ .layer_id = 0, .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }));
    std.debug.print("RETAINED_LINE cases=36 strict_boundary_differences={d} allocation_retry=pass geometry_retry=pass cache=pass\n", .{strict_differences});
}
