const std = @import("std");
const rendering = @import("compositor");
const sdl = rendering.sdl;
const Mode = rendering.types.CanvasMode;
const background = [4]u8{ 80, 120, 160, 255 };
const families = [_]Mode{ .normal, .additive, .multiply };

fn probeSolid(fixture: Fixture, rectangle: sdl.SDL_FRect, color: sdl.SDL_FColor) !void {
    const vertices = [_]sdl.SDL_Vertex{
        .{ .position = .{ .x = rectangle.x, .y = rectangle.y }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = rectangle.x + rectangle.w, .y = rectangle.y }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = rectangle.x + rectangle.w, .y = rectangle.y + rectangle.h }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = rectangle.x, .y = rectangle.y + rectangle.h }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
    };
    try std.testing.expect(sdl.SDL_RenderGeometry(fixture.renderer, null, &vertices, 4, &[_]c_int{ 0, 1, 2, 2, 3, 0 }, 6));
}

test "direct padded accumulation independently protects ring clip cancellation and both presentation filters" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(fixture.renderer)), "software")) return;
    for ([_][2]usize{ .{ 3, 5 }, .{ 1, 1 }, .{ 8, 8 } }) |extent| for (families) |family| for ([_]bool{ false, true }) |clipped| {
        const width = extent[0];
        const height = extent[1];
        const target = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_TARGET, @intCast(width + 2), @intCast(height + 2)) orelse return error.TextureUnavailable;
        defer sdl.SDL_DestroyTexture(target);
        try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, target));
        try std.testing.expect(sdl.SDL_SetRenderViewport(fixture.renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderClipRect(fixture.renderer, null));
        const clear = identity(family);
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(fixture.renderer, clear[0], clear[1], clear[2], clear[3]));
        try std.testing.expect(sdl.SDL_RenderClear(fixture.renderer));
        const clip = sdl.SDL_Rect{ .x = if (clipped) 2 else 1, .y = if (clipped) 2 else 1, .w = if (clipped) @intCast(width -| 2) else @intCast(width), .h = if (clipped) @intCast(height -| 2) else @intCast(height) };
        try std.testing.expect(sdl.SDL_SetRenderClipRect(fixture.renderer, &clip));
        try std.testing.expect(sdl.SDL_SetRenderDrawBlendMode(fixture.renderer, rendering.operation.blend(family)));
        var expected: [64][4]u8 = @splat(clear);
        for (0..height + 2) |row| for (0..width + 2) |column| {
            const source = [4]u8{ @intCast(40 + column * 17), @intCast(30 + row * 19), 120, 128 };
            const premultiplied = [4]u8{ @intCast((@as(u32, source[0]) * 128 + 127) / 255), @intCast((@as(u32, source[1]) * 128 + 127) / 255), @intCast((@as(u32, source[2]) * 128 + 127) / 255), 128 };
            var completed_pixel: [1][4]u8 = undefined;
            completed(&.{source}, &completed_pixel, family);
            const inside = column >= @as(usize, @intCast(clip.x)) and column < @as(usize, @intCast(clip.x + clip.w)) and row >= @as(usize, @intCast(clip.y)) and row < @as(usize, @intCast(clip.y + clip.h));
            if (inside) expected[(row - 1) * width + column - 1] = completed_pixel[0];
            if (clip.w > 0 and clip.h > 0) try probeSolid(fixture, .{ .x = @floatFromInt(column), .y = @floatFromInt(row), .w = 1, .h = 1 }, .{ .r = @as(f32, @floatFromInt(premultiplied[0])) / 255, .g = @as(f32, @floatFromInt(premultiplied[1])) / 255, .b = @as(f32, @floatFromInt(premultiplied[2])) / 255, .a = 128.0 / 255.0 });
        };
        if (width == 8 and !clipped) {
            try std.testing.expect(sdl.SDL_RenderClear(fixture.renderer));
            const low: f32 = 16_777_216;
            const high: f32 = 16_777_224;
            const left: f32 = @floatCast(@as(f64, low) - 16_777_217 + 1);
            const right: f32 = @floatCast(@as(f64, high) - 16_777_217 + 1);
            try probeSolid(fixture, .{ .x = left, .y = left, .w = right - left, .h = right - left }, .{ .r = 0.5, .g = 0, .b = 0, .a = 1 });
            for (0..height) |row| for (0..width) |column| {
                expected[row * width + column] = if (row < 7 and column < 7) .{ 128, 0, 0, if (family == .additive) @as(u8, 0) else 255 } else clear;
            };
        }
        const surface = sdl.SDL_RenderReadPixels(fixture.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        for (0..height + 2) |row| for (0..width + 2) |column| {
            var actual: [4]u8 = undefined;
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(column), @intCast(row), &actual[0], &actual[1], &actual[2], &actual[3]));
            const ring = column == 0 or row == 0 or column == width + 1 or row == height + 1;
            if ((ring and !std.meta.eql(clear, actual)) or (!ring and !matches(expected[(row - 1) * width + column - 1], actual))) std.debug.print("PADDED_ACCUMULATION extent={any} family={s} clipped={} physical={d},{d} ring={} expected={any} actual={any}\n", .{ extent, @tagName(family), clipped, column, row, ring, if (ring) clear else expected[(row - 1) * width + column - 1], actual });
            if (ring) try std.testing.expectEqual(clear, actual) else try std.testing.expect(matches(expected[(row - 1) * width + column - 1], actual));
        };
        try std.testing.expect(sdl.SDL_SetRenderClipRect(fixture.renderer, null));
        for ([_]bool{ false, true }) |linear| {
            try fixture.clear();
            try std.testing.expect(sdl.SDL_SetTextureScaleMode(target, if (linear) sdl.SDL_SCALEMODE_LINEAR else sdl.SDL_SCALEMODE_NEAREST));
            try std.testing.expect(sdl.SDL_SetTextureBlendMode(target, rendering.operation.blend(family)));
            try std.testing.expect(sdl.SDL_SetRenderTextureAddressMode(fixture.renderer, sdl.SDL_TEXTURE_ADDRESS_CLAMP, sdl.SDL_TEXTURE_ADDRESS_CLAMP));
            const color = sdl.SDL_FColor{ .r = 1, .g = 1, .b = 1, .a = 1 };
            const positions = [_][2]f32{ .{ 0.25, 0.25 }, .{ @as(f32, @floatFromInt(width)) + 0.25, 0.25 }, .{ @as(f32, @floatFromInt(width)) + 0.25, @as(f32, @floatFromInt(height)) + 0.25 }, .{ 0.25, @as(f32, @floatFromInt(height)) + 0.25 } };
            const coordinates = [_][2]f32{ .{ 1, 1 }, .{ @floatFromInt(width + 1), 1 }, .{ @floatFromInt(width + 1), @floatFromInt(height + 1) }, .{ 1, @floatFromInt(height + 1) } };
            var vertices: [4]sdl.SDL_Vertex = undefined;
            for (&vertices, positions, coordinates) |*vertex, position, coordinate| vertex.* = .{ .position = .{ .x = position[0], .y = position[1] }, .color = color, .tex_coord = .{ .x = coordinate[0] / @as(f32, @floatFromInt(width + 2)), .y = coordinate[1] / @as(f32, @floatFromInt(height + 2)) } };
            try std.testing.expect(sdl.SDL_RenderGeometry(fixture.renderer, target, &vertices, 4, &[_]c_int{ 0, 1, 2, 2, 3, 0 }, 6));
            for (try fixture.image(), 0..) |actual, index| {
                const horizontal = @as(f64, @floatFromInt(index % 8)) + 0.25;
                const vertical = @as(f64, @floatFromInt(index / 8)) + 0.25;
                const within = horizontal < @as(f64, @floatFromInt(width)) and vertical < @as(f64, @floatFromInt(height));
                const operation = if (linear) sample(expected[0 .. width * height], width, height, horizontal, vertical, family) else nearestSource(expected[0 .. width * height], @intCast(width), @intCast(height), horizontal, vertical, false);
                const wanted = if (within) present(operation, family, 255, .{ 255, 255, 255 }) else background;
                if (!matches(wanted, actual)) std.debug.print("PADDED_PROBE extent={any} family={s} clip={} linear={} pixel={d},{d} expected={any} actual={any}\n", .{ extent, @tagName(family), clipped, linear, index % 8, index / 8, wanted, actual });
                try std.testing.expect(matches(wanted, actual));
            }
        }
    };
}

const Client = struct {
    fixture: Fixture,
    instance: *rendering.Instance,

    fn init() !Client {
        const fixture = try Fixture.init();
        errdefer fixture.deinit();
        const instance = try std.testing.allocator.create(rendering.Instance);
        try instance.init(std.testing.allocator, .{ .renderer = fixture.renderer, .logical_width = 8, .logical_height = 8, .opaque_presentation = true });
        return .{ .fixture = fixture, .instance = instance };
    }

    fn deinit(self: *Client) void {
        self.instance.deinit();
        std.testing.allocator.destroy(self.instance);
        self.fixture.deinit();
    }

    fn begin(self: *Client) !void {
        self.instance.state.frame_state = .updating;
        try self.fixture.clear();
    }

    fn execute(self: *Client) !void {
        try rendering.layers.compileDirtyRetainedLayers(self.instance);
        try rendering.compositor.executeCompositeFrame(self.instance);
    }
};

fn checkCanvas(client: *Client, family: Mode, expected: []const [4]u8) !void {
    const layer = client.instance.state.layers[0];
    const extent = rendering.textures.layerExtent(client.instance, &layer);
    const target = client.instance.state.texture_table[layer.target_texture_id].?;
    const dimensions = client.instance.state.texture_dims[layer.target_texture_id];
    try std.testing.expectEqual(@as(f32, @floatFromInt(layer.backing.width)), dimensions.width);
    try std.testing.expectEqual(@as(f32, @floatFromInt(layer.backing.height)), dimensions.height);
    try std.testing.expect(sdl.SDL_SetRenderTarget(client.fixture.renderer, target));
    defer _ = sdl.SDL_SetRenderTarget(client.fixture.renderer, null);
    const surface: *sdl.SDL_Surface = sdl.SDL_RenderReadPixels(client.fixture.renderer, null) orelse return error.ReadbackFailed;
    defer sdl.SDL_DestroySurface(surface);
    try std.testing.expectEqual(layer.backing.width, surface.w);
    try std.testing.expectEqual(layer.backing.height, surface.h);
    var row: c_int = 0;
    while (row < layer.backing.height) : (row += 1) {
        var column: c_int = 0;
        while (column < layer.backing.width) : (column += 1) {
            var actual: [4]u8 = undefined;
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, column, row, &actual[0], &actual[1], &actual[2], &actual[3]));
            const horizontal = column - layer.backing.border;
            const vertical = row - layer.backing.border;
            if (horizontal < 0 or vertical < 0 or horizontal >= extent.width or vertical >= extent.height) {
                try std.testing.expectEqual(identity(family), actual);
            } else {
                try std.testing.expect(matches(expected[@intCast(vertical * extent.width + horizontal)], actual));
            }
        }
    }
}

test "canonical padded canvas promotion reuse edits clipping resizing reset and cleanup" {
    for (families) |family| {
        var client = try Client.init();
        defer client.deinit();
        if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
        const id = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .operation_only);
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 240, 0, 0, 128 }, 4);
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.layers.setCanvasExtent(client.instance, 0, 3, 5);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 1, 1, -2, -2, 7, 9, false, false, 0, 0, 0, 255, 255, 255, 255);
        try client.execute();
        const layer = &client.instance.state.layers[0];
        const target_id = layer.target_texture_id;
        const old = client.instance.state.texture_table[target_id];
        try std.testing.expectEqual(@as(u8, 0), layer.backing.border);
        const before = client.instance.canvas_stats;
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
        try client.begin();
        try client.execute();
        const padded = client.instance.state.texture_table[target_id];
        try std.testing.expect(old != padded);
        try std.testing.expectEqual(target_id, layer.target_texture_id);
        try std.testing.expectEqual(@as(u8, 1), layer.backing.border);
        try std.testing.expectEqual(before.compiled_layers, client.instance.canvas_stats.compiled_layers);
        try std.testing.expectEqual(before.rasterized_canvases, client.instance.canvas_stats.rasterized_canvases);
        try std.testing.expectEqual(@as(usize, 1), client.instance.sampling_stats.copy_calls);
        try std.testing.expectEqual(@as(usize, 60), client.instance.sampling_stats.copied_bytes);
        try std.testing.expectEqual(@as(usize, 140), client.instance.sampling_cache.texture_bytes);
        var red: [1][4]u8 = undefined;
        completed(&.{.{ 240, 0, 0, 128 }}, &red, family);
        var expected: [15][4]u8 = @splat(red[0]);
        try checkCanvas(&client, family, &expected);
        const sampling_before = client.instance.sampling_stats;
        for (0..6) |iteration| {
            try client.begin();
            try rendering.layers.setCanvasSampling(client.instance, 0, if (iteration % 2 == 0) .nearest else .bilinear);
            try client.execute();
            try std.testing.expectEqual(padded, client.instance.state.texture_table[target_id]);
            try std.testing.expectEqualDeep(sampling_before, client.instance.sampling_stats);
            for (try client.fixture.image(), 0..) |pixel, index| {
                var normalized: [4]f64 = undefined;
                for (red[0], &normalized) |channel, *value| value.* = @as(f64, @floatFromInt(channel)) / 255;
                const want = if (index % 8 < 3 and index / 8 < 5) present(normalized, family, 255, .{ 255, 255, 255 }) else background;
                try std.testing.expect(matches(want, pixel));
            }
        }
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 0, 220, 0, 128 }, 4);
        try client.begin();
        try client.execute();
        var green: [1][4]u8 = undefined;
        completed(&.{.{ 0, 220, 0, 128 }}, &green, family);
        @memset(&expected, green[0]);
        try checkCanvas(&client, family, &expected);
        try rendering.layers.setSurfaceClip(client.instance, 0, .{ .x = 1, .y = 1, .w = 1, .h = 3 });
        try rendering.layers.setContentScroll(client.instance, 0, -3, -3);
        try client.begin();
        try client.execute();
        for (&expected, 0..) |*pixel, index| pixel.* = if (index % 3 == 1 and index / 3 >= 1 and index / 3 < 4) green[0] else identity(family);
        try checkCanvas(&client, family, &expected);
        try rendering.layers.setSurfaceClip(client.instance, 0, .{ .x = 7, .y = 7, .w = 1, .h = 1 });
        try client.begin();
        try client.execute();
        @memset(&expected, identity(family));
        try checkCanvas(&client, family, &expected);
        try rendering.layers.setCanvasExtent(client.instance, 0, 4, 2);
        try rendering.layers.setSurfaceClip(client.instance, 0, .{});
        try client.begin();
        try client.execute();
        var resized: [8][4]u8 = undefined;
        for (&resized, 0..) |*pixel, index| pixel.* = if (index % 4 >= 1 and index / 4 >= 1) green[0] else identity(family);
        try checkCanvas(&client, family, &resized);
        try std.testing.expectEqual(@as(usize, 96), client.instance.sampling_cache.texture_bytes);
        try std.testing.expectEqual(@as(usize, 1), client.instance.sampling_stats.copy_calls);
        try std.testing.expectEqual(before.compiled_layers, client.instance.canvas_stats.compiled_layers);
        try rendering.layers.setCanvasSampling(client.instance, 0, .nearest);
        try rendering.layers.setCanvasExtent(client.instance, 0, 5, 3);
        try client.begin();
        try client.execute();
        try std.testing.expectEqual(@as(u8, 0), layer.backing.border);
        try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try client.begin();
        try client.execute();
        if (family == .multiply) {
            client.instance.faults.inject(.target_creation, 0);
            try std.testing.expectError(error.TextureCreationFailed, rendering.layers.resetLayer(client.instance, 0));
            try std.testing.expectEqual(@as(u8, 1), layer.backing.border);
            try std.testing.expectEqual(Mode.multiply, layer.canvas_mode);
            try rendering.layers.resetLayer(client.instance, 0);
        } else {
            try rendering.layers.setCanvasMode(client.instance, 0, .legacy_rgba);
        }
        try std.testing.expectEqual(@as(u8, 0), layer.backing.border);
        try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
        try rendering.layers.resetLayer(client.instance, 0);
        try std.testing.expectEqual(target_id, layer.target_texture_id);
        try std.testing.expectEqual(rendering.types.Sampling.nearest, layer.sampling);
        client.instance.deinit();
        try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
    }
}

test "retained padded scroll cancellation revives distant geometry and nearest minification reflects correctly" {
    for (families) |family| {
        var client = try Client.init();
        defer client.deinit();
        if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
        const id = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .operation_only);
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 240, 60, 20, 255 }, 4);
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.layers.setCanvasExtent(client.instance, 0, 8, 8);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 1, 1, 16_777_216, 16_777_216, 8, 8, false, false, 0, 0, 0, 255, 255, 255, 255);
        try client.execute();
        var expected: [64][4]u8 = @splat(identity(family));
        try checkCanvas(&client, family, &expected);
        const target = client.instance.state.texture_table[client.instance.state.layers[0].target_texture_id];
        const compiled = client.instance.canvas_stats.compiled_layers;
        try rendering.layers.setContentScroll(client.instance, 0, 16_777_217, 16_777_217);
        try client.begin();
        try client.execute();
        for (&expected, 0..) |*pixel, index| pixel.* = if (index % 8 < 7 and index / 8 < 7) .{ 240, 60, 20, if (family == .additive) @as(u8, 0) else 255 } else identity(family);
        try checkCanvas(&client, family, &expected);
        const rasterized = client.instance.canvas_stats.rasterized_canvases;
        for ([_]bool{ false, true }) |reflected| {
            try rendering.layers.setCanvasSampling(client.instance, 0, .nearest);
            try rendering.layers.setAffine(client.instance, 0, .{ .a = if (reflected) -32768 else 32768, .d = 32768, .tx = if (reflected) 1088 else 64, .ty = 64 });
            try client.begin();
            try client.execute();
            for (try client.fixture.image(), 0..) |pixel, index| {
                const horizontal = if (reflected) 7.5 - @as(f64, @floatFromInt(index % 8)) * 2 else @as(f64, @floatFromInt(index % 8)) * 2 + 0.5;
                const vertical = @as(f64, @floatFromInt(index / 8)) * 2 + 0.5;
                const inside = horizontal >= 0 and horizontal < 8 and vertical < 8;
                const want = if (inside) present(nearestSource(&expected, 8, 8, horizontal, vertical, false), family, 255, .{ 255, 255, 255 }) else background;
                try std.testing.expect(matches(want, pixel));
            }
        }
        try std.testing.expectEqual(target, client.instance.state.texture_table[client.instance.state.layers[0].target_texture_id]);
        try std.testing.expectEqual(compiled, client.instance.canvas_stats.compiled_layers);
        try std.testing.expectEqual(rasterized, client.instance.canvas_stats.rasterized_canvases);
        try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_stats.copy_calls);
    }
}

test "padded promotion respects renderer limits budgets and texture ID reuse" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    try client.begin();
    try rendering.layers.setCanvasMode(client.instance, 0, .multiply);
    try client.execute();
    const layer = &client.instance.state.layers[0];
    const target_id = layer.target_texture_id;
    const old = client.instance.state.texture_table[target_id];
    client.instance.sampling_cache.texture_bytes = rendering.sampling.max_view_bytes;
    try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
    try std.testing.expectError(error.SamplingBudgetExceeded, client.execute());
    try std.testing.expectEqual(old, client.instance.state.texture_table[target_id]);
    try std.testing.expectEqual(@as(u8, 0), layer.backing.border);
    client.instance.sampling_cache.texture_bytes = 0;
    try client.begin();
    try client.execute();
    rendering.textures.destroyLogicalLayerTargets(client.instance);
    try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
    try std.testing.expectEqual(@as(c_int, 0), layer.backing.width);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(target_id, layer.target_texture_id);
    try checkCanvas(&client, .multiply, &([_][4]u8{.{ 255, 255, 255, 255 }} ** 64));
    const limit = sdl.SDL_GetNumberProperty(sdl.SDL_GetRendererProperties(client.fixture.renderer), sdl.SDL_PROP_RENDERER_MAX_TEXTURE_SIZE_NUMBER, 0);
    if (limit <= 0 or limit > 65535) return;
    try rendering.layers.setCanvasSampling(client.instance, 0, .nearest);
    try rendering.layers.setCanvasExtent(client.instance, 0, @intCast(limit), 1);
    try client.begin();
    try client.execute();
    const maximum = client.instance.state.texture_table[target_id];
    try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
    try std.testing.expectError(error.SamplingPreparationFailed, client.execute());
    try std.testing.expectEqual(maximum, client.instance.state.texture_table[target_id]);
    try std.testing.expectEqual(@as(u8, 0), layer.backing.border);
    try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
}

test "clean promotion failures keep old pixels ownership and submissions retryable" {
    const cases = .{
        .{ rendering.faults.Point.sampling_target_creation, error.SamplingPreparationFailed },
        .{ rendering.faults.Point.sampling_setup, error.TextureStateFailed },
        .{ rendering.faults.Point.sampling_copy, error.SamplingCopyFailed },
        .{ rendering.faults.Point.sampling_restore, error.TextureStateFailed },
        .{ rendering.faults.Point.target_creation, error.TargetCreationFailed },
        .{ rendering.faults.Point.texture_scale, error.TargetCreationFailed },
        .{ rendering.faults.Point.texture_blend, error.TargetCreationFailed },
    };
    inline for (cases) |case| {
        var client = try Client.init();
        defer client.deinit();
        if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
        const id = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .shared);
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 240, 0, 0, 128 }, 4);
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, .normal);
        try rendering.layers.setCanvasExtent(client.instance, 0, 1, 1);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, false, false, 0, 0, 0, 255, 255, 255, 255);
        try client.execute();
        const layer = &client.instance.state.layers[0];
        const target_id = layer.target_texture_id;
        const old = client.instance.state.texture_table[target_id];
        const before = client.instance.canvas_stats;
        try client.begin();
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try rendering.draw.addTexturedQuad(client.instance, id, 0, 0, 0, 1, 1, 4, 4, 2, 2, false, false, 0, 0, 0);
        client.instance.faults.inject(case[0], 0);
        try std.testing.expectError(case[1], client.execute());
        try std.testing.expectEqual(old, client.instance.state.texture_table[target_id]);
        try std.testing.expectEqual(@as(u8, 0), layer.backing.border);
        try std.testing.expect(!layer.target_dirty);
        try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
        try std.testing.expectEqual(@as(usize, 1), client.instance.state.instruction_count);
        try std.testing.expect(!client.instance.frame_ready);
        try client.begin();
        try client.execute();
        try std.testing.expectEqual(before.compiled_layers, client.instance.canvas_stats.compiled_layers);
        try std.testing.expectEqual(before.rasterized_canvases, client.instance.canvas_stats.rasterized_canvases);
        try checkCanvas(&client, .normal, &.{.{ 120, 0, 0, 128 }});
        try rendering.compositor.present(client.instance);
        try std.testing.expectEqual(@as(usize, 0), client.instance.state.instruction_count);
    }
}

test "dirty padded accumulation failures retain one backing and never copy on retry" {
    const cases = .{
        .{ rendering.faults.Point.target_select, error.TargetSelectionFailed },
        .{ rendering.faults.Point.clear, error.ClearFailed },
        .{ rendering.faults.Point.clip, error.ClipFailed },
        .{ rendering.faults.Point.geometry, error.GeometryFailed },
        .{ rendering.faults.Point.target_restore, error.TargetRestoreFailed },
    };
    inline for (cases) |case| {
        var client = try Client.init();
        defer client.deinit();
        if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
        const id = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .shared);
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 240, 0, 0, 128 }, 4);
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, .multiply);
        try rendering.layers.setCanvasExtent(client.instance, 0, 1, 1);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 1, 1, -1, -1, 3, 3, false, false, 0, 0, 0, 255, 255, 255, 255);
        try client.execute();
        const target = client.instance.state.texture_table[client.instance.state.layers[0].target_texture_id];
        try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_stats.copy_calls);
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 0, 220, 0, 128 }, 4);
        try client.begin();
        client.instance.faults.inject(case[0], 0);
        try std.testing.expectError(case[1], client.execute());
        try std.testing.expect(client.instance.state.layers[0].target_dirty);
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
        try client.begin();
        try client.execute();
        try std.testing.expectEqual(target, client.instance.state.texture_table[client.instance.state.layers[0].target_texture_id]);
        try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_stats.copy_calls);
        try std.testing.expectEqual(@as(usize, 1), client.instance.sampling_stats.texture_allocations);
        try checkCanvas(&client, .multiply, &.{.{ 127, 237, 127, 255 }});
    }
}

test "operation source metadata edits leave legacy-only canvases and immediate readiness unchanged" {
    var client = try Client.init();
    defer client.deinit();
    const id = try rendering.textures.createDynamicTexture(client.instance, 1, 1);
    try client.begin();
    try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 1, 1, 0, 0, 2, 2, false, false, 0, 0, 0, 255, 255, 255, 255);
    try rendering.draw.addTexturedQuad(client.instance, id, 0, 0, 0, 1, 1, 4, 4, 2, 2, false, false, 0, 0, 0);
    try client.execute();
    client.instance.changes = .{};
    const rasterized = client.instance.canvas_stats.rasterized_canvases;
    try rendering.sampling.setSource(client.instance, id, .bilinear, .repeat);
    try std.testing.expect(client.instance.frame_ready);
    try std.testing.expect(!client.instance.changes.present_needed);
    try std.testing.expect(!client.instance.state.layers[0].target_dirty);
    try std.testing.expectEqual(@as(usize, 1), client.instance.state.instruction_count);
    try std.testing.expect(client.instance.state.operation_sources[id].pixels == null);
    try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_stats.texture_allocations);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(rasterized, client.instance.canvas_stats.rasterized_canvases);
    try rendering.compositor.present(client.instance);
}

fn completed(pixels: []const [4]u8, output: [][4]u8, family: Mode) void {
    for (pixels, output) |pixel, *result| {
        for (0..3) |channel| {
            const premultiplied = (@as(u32, pixel[channel]) * pixel[3] + 127) / 255;
            result[channel] = @intCast(if (family == .multiply) 255 - pixel[3] + premultiplied else premultiplied);
        }
        result[3] = switch (family) {
            .normal => pixel[3],
            .additive => 0,
            .multiply => 255,
            .legacy_rgba => unreachable,
        };
    }
}

test "shared compositor bilinear canvases preserve independent identity interpolation and presentation-only reuse" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) {
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, .normal);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try std.testing.expectError(error.UnsupportedCanvasBackend, client.execute());
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
        std.debug.print("SHARED_CANVAS software=unsupported operation rejection only\n", .{});
        return;
    }
    const pixels = [_][4]u8{ .{ 255, 0, 0, 128 }, .{ 255, 255, 255, 0 }, .{ 0, 255, 0, 128 }, .{ 0, 0, 255, 255 } };
    const matrices = [_]rendering.types.Affine{
        .{ .a = 131072, .d = 131072, .tx = 64, .ty = 64 },
        .{ .a = -131072, .d = 131072, .tx = 1088, .ty = 64 },
        .{ .a = 65536, .b = 32768, .c = -32768, .d = 131072, .tx = 320, .ty = 576 },
        .{ .a = 32768, .d = 32768, .tx = 320, .ty = 320 },
        .{ .a = std.math.maxInt(i32), .b = -std.math.maxInt(i32), .d = 98304, .tx = 64, .ty = 64 },
        .{ .a = 65536, .b = 65536, .c = 65536, .d = 65536 },
        .{ .a = 0, .b = -65536, .c = 65536, .d = 0, .tx = 1088, .ty = 64 },
    };
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 2, 2, .operation_only);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 2, 2, std.mem.asBytes(&pixels), 8);
    for (families) |family| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.layers.setCanvasExtent(client.instance, 0, 2, 2);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 2, 2, 0, 0, 2, 2, false, false, 0, 0, 0, 255, 255, 255, 255);
        var canvas: [4][4]u8 = undefined;
        completed(&pixels, &canvas, family);
        for (matrices) |matrix| {
            try client.begin();
            try rendering.layers.setAffine(client.instance, 0, matrix);
            try client.execute();
            const image = try client.fixture.image();
            const determinant = @as(f64, @floatFromInt(@as(i128, matrix.a) * matrix.d - @as(i128, matrix.b) * matrix.c));
            for (image, 0..) |actual, index| {
                const horizontal = @as(f64, @floatFromInt(index % 8)) + 0.5 - @as(f64, @floatFromInt(matrix.tx)) / 256;
                const vertical = @as(f64, @floatFromInt(index / 8)) + 0.5 - @as(f64, @floatFromInt(matrix.ty)) / 256;
                const source_x = if (determinant == 0) 0 else 65536 * (@as(f64, @floatFromInt(matrix.d)) * horizontal - @as(f64, @floatFromInt(matrix.b)) * vertical) / determinant;
                const source_y = if (determinant == 0) 0 else 65536 * (-@as(f64, @floatFromInt(matrix.c)) * horizontal + @as(f64, @floatFromInt(matrix.a)) * vertical) / determinant;
                const expected = if (determinant != 0 and source_x >= 0 and source_y >= 0 and source_x < 2 and source_y < 2) present(sample(&canvas, 2, 2, source_x, source_y, family), family, 255, .{ 255, 255, 255 }) else background;
                if (!matches(expected, actual)) std.debug.print("SHARED_BILINEAR_MISMATCH family={s} matrix={any} pixel={d},{d} inverse={d},{d} expected={any} actual={any}\n", .{ @tagName(family), matrix, index % 8, index / 8, source_x, source_y, expected, actual });
                try std.testing.expect(matches(expected, actual));
            }
        }
        const rasterized = client.instance.canvas_stats.rasterized_canvases;
        const compiled = client.instance.canvas_stats.compiled_layers;
        const stats = client.instance.sampling_stats;
        try rendering.layers.setCanvasSampling(client.instance, 0, .nearest);
        try std.testing.expect(!client.instance.frame_ready);
        try client.begin();
        try client.execute();
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try client.begin();
        try client.execute();
        client.instance.state.layer_prop_buffer[0] = .{ .layer_id = 0, .field = @intFromEnum(rendering.types.LayerPropField.opacity), .value = 128 };
        client.instance.state.layer_prop_buffer[1] = .{ .layer_id = 0, .field = @intFromEnum(rendering.types.LayerPropField.tint_r), .value = 80 };
        _ = try rendering.layers.submitLayerPropCommands(client.instance, 2);
        try client.begin();
        try client.execute();
        try std.testing.expectEqual(rasterized, client.instance.canvas_stats.rasterized_canvases);
        try std.testing.expectEqual(compiled, client.instance.canvas_stats.compiled_layers);
        try std.testing.expectEqualDeep(stats, client.instance.sampling_stats);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try std.testing.expect(client.instance.frame_ready);
    }
    std.debug.print("SHARED_CANVAS path=SDL_geometry_and_lazy_identity_border families=3 transforms=7 sampling_only_rerasterizations=0\n", .{});
}

test "shared source filtering wraps NPOT taps after premultiplication and isolates rectangle edits" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    var pixels: [15][4]u8 = undefined;
    var premultiplied: [15][4]u8 = undefined;
    for (&pixels, 0..) |*pixel, index| pixel.* = .{ @intCast(90 * (index % 3)), @intCast(50 * (index / 3)), 255, if (index % 3 == 0) 0 else 128 };
    completed(&pixels, &premultiplied, .normal);
    inline for (.{ rendering.textures.OperationTextureMode.shared, rendering.textures.OperationTextureMode.operation_only }) |capability| {
        client.instance.state.frame_state = .idle;
        const id = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 5, capability);
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 3, 5, std.mem.asBytes(&pixels), 12);
        inline for (.{ rendering.types.Addressing.clamp, rendering.types.Addressing.repeat }) |address| for ([_]rendering.types.Sampling{ .nearest, .bilinear }) |filter| for ([_]f32{ 1, 3, 6, 12 }) |span| {
            try client.begin();
            try rendering.layers.resetLayer(client.instance, 0);
            try rendering.layers.setCanvasMode(client.instance, 0, .normal);
            try rendering.sampling.setSource(client.instance, id, filter, address);
            const origin: f32 = if (filter == .nearest) -0.375 else -0.5;
            try rendering.draw.addOperationQuadUV(client.instance, id, 0, 0, .{ .x = origin, .y = origin, .w = span, .h = span }, .{ .x = 0, .y = 0, .w = 6, .h = 6 }, .{ 255, 255, 255, 255 });
            try client.execute();
            const image = try client.fixture.image();
            for (image, 0..) |actual, index| {
                const source_x = @as(f64, origin) + (@as(f64, @floatFromInt(index % 8)) + 0.5) * span / 6;
                const source_y = @as(f64, origin) + (@as(f64, @floatFromInt(index / 8)) + 0.5) * span / 6;
                const expected = if (index % 8 < 6 and index / 8 < 6) present(if (filter == .bilinear) sourceSample(&premultiplied, 3, 5, source_x, source_y, address == .repeat) else nearestSource(&premultiplied, 3, 5, source_x, source_y, address == .repeat), .normal, 255, .{ 255, 255, 255 }) else background;
                if (!matches(expected, actual)) std.debug.print("SHARED_SOURCE_MISMATCH capability={s} address={s} pixel={d},{d} expected={any} actual={any}\n", .{ @tagName(capability), @tagName(address), index % 8, index / 8, expected, actual });
                try std.testing.expect(matches(expected, actual));
            }
            try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_stats.copy_calls);
        };
    }
    var expected_canvas: [64][4]u8 = undefined;
    for (&expected_canvas, 0..) |*pixel, index| {
        pixel.* = .{ 0, 0, 0, 0 };
        if (index % 8 < 6 and index / 8 < 6) {
            const fragment = sourceSample(&premultiplied, 3, 5, @as(f64, @floatFromInt(index % 8)) * 2 + 0.5, @as(f64, @floatFromInt(index / 8)) * 2 + 0.5, true);
            for (0..4) |channel| pixel[channel] = @intFromFloat(@round(fragment[channel] * 255));
        }
    }
    const rasterizations = client.instance.canvas_stats.rasterized_canvases;
    try client.begin();
    try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
    try rendering.layers.setAffine(client.instance, 0, .{ .tx = 64 });
    try client.execute();
    try std.testing.expectEqual(rasterizations, client.instance.canvas_stats.rasterized_canvases);
    for (try client.fixture.image(), 0..) |actual, index| {
        const expected = present(sample(&expected_canvas, 8, 8, @as(f64, @floatFromInt(index % 8)) + 0.25, @as(f64, @floatFromInt(index / 8)) + 0.5, .normal), .normal, 255, .{ 255, 255, 255 });
        try std.testing.expect(matches(expected, actual));
    }
    var atlas = [_][4]u8{.{ 255, 0, 255, 255 }} ** 9;
    atlas[4] = .{ 20, 220, 80, 255 };
    client.instance.state.frame_state = .idle;
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 3, .operation_only);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 3, 3, std.mem.asBytes(&atlas), 12);
    try client.begin();
    try rendering.layers.resetLayer(client.instance, 0);
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    try rendering.sampling.setSource(client.instance, id, .bilinear, .repeat);
    try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 1, 1, 1, 1, 0, 0, 6, 6, false, false, 0, 0, 0, 255, 255, 255, 255);
    try client.execute();
    for (try client.fixture.image(), 0..) |pixel, index| try std.testing.expectEqual(if (index % 8 < 6 and index / 8 < 6) atlas[4] else background, pixel);
    const allocation_count = client.instance.sampling_stats.texture_allocations;
    const copy_count = client.instance.sampling_stats.copy_calls;
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(copy_count, client.instance.sampling_stats.copy_calls);
    try rendering.textures.updateDynamicTexture(client.instance, id, 1, 1, 1, 1, &.{ 10, 40, 80, 255 }, 4);
    try std.testing.expect(!client.instance.frame_ready);
    try client.begin();
    client.instance.faults.inject(.sampling_copy, 0);
    try std.testing.expectError(error.SamplingCopyFailed, client.execute());
    try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
    try std.testing.expect(client.instance.state.layers[0].target_dirty);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(allocation_count, client.instance.sampling_stats.texture_allocations);
    try std.testing.expectEqual(copy_count + 1, client.instance.sampling_stats.copy_calls);
    for (try client.fixture.image(), 0..) |pixel, index| try std.testing.expectEqual(if (index % 8 < 6 and index / 8 < 6) [4]u8{ 10, 40, 80, 255 } else background, pixel);
    std.debug.print("SHARED_SOURCE paths=SDL_native_NPOT_wrap,SDL_cropped_rectangle shared_and_operation_only=true region_copy_bytes=4 reused=true\n", .{});
}

fn nearestSource(pixels: []const [4]u8, width: i64, height: i64, horizontal: f64, vertical: f64, repeat: bool) [4]f64 {
    const left: i64 = @intFromFloat(@floor(horizontal));
    const top: i64 = @intFromFloat(@floor(vertical));
    const source_x = if (repeat) @mod(left, width) else std.math.clamp(left, 0, width - 1);
    const source_y = if (repeat) @mod(top, height) else std.math.clamp(top, 0, height - 1);
    const pixel = pixels[@intCast(source_y * width + source_x)];
    var result: [4]f64 = undefined;
    for (pixel, &result) |value, *channel| channel.* = @as(f64, @floatFromInt(value)) / 255;
    return result;
}

test "sampler scopes read incoming SDL state and restore only successful changes" {
    var client = try Client.init();
    defer client.deinit();
    const texture = sdl.SDL_CreateTexture(client.fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, 1, 1) orelse return error.TextureCreationFailed;
    defer sdl.SDL_DestroyTexture(texture);
    const wrapping = sdl.SDL_GetBooleanProperty(sdl.SDL_GetRendererProperties(client.fixture.renderer), sdl.SDL_PROP_RENDERER_TEXTURE_WRAPPING_BOOLEAN, false);
    const addresses = [_][2]sdl.SDL_TextureAddressMode{
        .{ sdl.SDL_TEXTURE_ADDRESS_AUTO, sdl.SDL_TEXTURE_ADDRESS_AUTO },
        .{ sdl.SDL_TEXTURE_ADDRESS_CLAMP, sdl.SDL_TEXTURE_ADDRESS_WRAP },
        .{ sdl.SDL_TEXTURE_ADDRESS_WRAP, sdl.SDL_TEXTURE_ADDRESS_CLAMP },
        .{ sdl.SDL_TEXTURE_ADDRESS_CLAMP, sdl.SDL_TEXTURE_ADDRESS_CLAMP },
        .{ sdl.SDL_TEXTURE_ADDRESS_WRAP, sdl.SDL_TEXTURE_ADDRESS_WRAP },
    };
    for ([_]sdl.SDL_ScaleMode{ sdl.SDL_SCALEMODE_NEAREST, sdl.SDL_SCALEMODE_LINEAR }) |incoming_scale| for (addresses) |incoming_address| {
        for ([_]rendering.types.Sampling{ .nearest, .bilinear }) |filter| for ([_]rendering.types.Addressing{ .clamp, .repeat }) |address| {
            if (address == .repeat and !wrapping) continue;
            try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, incoming_scale));
            try std.testing.expect(sdl.SDL_SetRenderTextureAddressMode(client.fixture.renderer, incoming_address[0], incoming_address[1]));
            const desired_scale = if (filter == .nearest) sdl.SDL_SCALEMODE_NEAREST else sdl.SDL_SCALEMODE_LINEAR;
            const desired_address = if (address == .clamp) sdl.SDL_TEXTURE_ADDRESS_CLAMP else sdl.SDL_TEXTURE_ADDRESS_WRAP;
            const scope = try rendering.sampling.begin(client.instance, texture, filter, address);
            try std.testing.expectEqual(incoming_scale != desired_scale, scope.scale_changed);
            try std.testing.expectEqual(incoming_address[0] != desired_address or incoming_address[1] != desired_address, scope.address_changed);
            var scale: sdl.SDL_ScaleMode = undefined;
            var horizontal: sdl.SDL_TextureAddressMode = undefined;
            var vertical: sdl.SDL_TextureAddressMode = undefined;
            try std.testing.expect(sdl.SDL_GetTextureScaleMode(texture, &scale));
            try std.testing.expect(sdl.SDL_GetRenderTextureAddressMode(client.fixture.renderer, &horizontal, &vertical));
            try std.testing.expectEqual(desired_scale, scale);
            try std.testing.expectEqual(desired_address, horizontal);
            try std.testing.expectEqual(desired_address, vertical);
            try rendering.sampling.end(client.instance, scope);
            try std.testing.expect(sdl.SDL_GetTextureScaleMode(texture, &scale));
            try std.testing.expect(sdl.SDL_GetRenderTextureAddressMode(client.fixture.renderer, &horizontal, &vertical));
            try std.testing.expectEqual(incoming_scale, scale);
            try std.testing.expectEqual(incoming_address[0], horizontal);
            try std.testing.expectEqual(incoming_address[1], vertical);
        };
    };
    try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST));
    try std.testing.expect(sdl.SDL_SetRenderTextureAddressMode(client.fixture.renderer, sdl.SDL_TEXTURE_ADDRESS_AUTO, sdl.SDL_TEXTURE_ADDRESS_AUTO));
    client.instance.faults.inject(.sampling_address_state, 0);
    try std.testing.expectError(error.TextureStateFailed, rendering.sampling.begin(client.instance, texture, .bilinear, .clamp));
    var restored_scale: sdl.SDL_ScaleMode = undefined;
    var restored_horizontal: sdl.SDL_TextureAddressMode = undefined;
    var restored_vertical: sdl.SDL_TextureAddressMode = undefined;
    try std.testing.expect(sdl.SDL_GetTextureScaleMode(texture, &restored_scale));
    try std.testing.expect(sdl.SDL_GetRenderTextureAddressMode(client.fixture.renderer, &restored_horizontal, &restored_vertical));
    try std.testing.expectEqual(sdl.SDL_SCALEMODE_NEAREST, restored_scale);
    try std.testing.expectEqual(sdl.SDL_TEXTURE_ADDRESS_AUTO, restored_horizontal);
    try std.testing.expectEqual(sdl.SDL_TEXTURE_ADDRESS_AUTO, restored_vertical);
    const retry = try rendering.sampling.begin(client.instance, texture, .bilinear, .clamp);
    try std.testing.expect(retry.scale_changed and retry.address_changed);
    client.instance.faults.inject(.sampling_restore, 0);
    try std.testing.expectError(error.TextureStateFailed, rendering.sampling.end(client.instance, retry));
    try std.testing.expect(sdl.SDL_GetTextureScaleMode(texture, &restored_scale));
    try std.testing.expect(sdl.SDL_GetRenderTextureAddressMode(client.fixture.renderer, &restored_horizontal, &restored_vertical));
    try std.testing.expectEqual(sdl.SDL_SCALEMODE_NEAREST, restored_scale);
    try std.testing.expectEqual(sdl.SDL_TEXTURE_ADDRESS_AUTO, restored_horizontal);
    try std.testing.expectEqual(sdl.SDL_TEXTURE_ADDRESS_AUTO, restored_vertical);
}

test "sampling preparation and submission faults preserve ownership renderer state and immediate retry" {
    const cases = .{
        .{ rendering.faults.Point.sampling_target_creation, error.SamplingPreparationFailed },
        .{ rendering.faults.Point.sampling_copy, error.SamplingCopyFailed },
        .{ rendering.faults.Point.sampling_state, error.TextureStateFailed },
        .{ rendering.faults.Point.sampling_address_state, error.TextureStateFailed },
        .{ rendering.faults.Point.sampling_setup, error.TextureStateFailed },
        .{ rendering.faults.Point.sampling_restore, error.TextureStateFailed },
        .{ rendering.faults.Point.geometry, error.GeometryFailed },
        .{ rendering.faults.Point.clip, error.ClipFailed },
    };
    inline for (cases) |case| {
        var client = try Client.init();
        defer client.deinit();
        if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
        const id = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .shared);
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 255, 0, 0, 128 }, 4);
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, .normal);
        try rendering.layers.setCanvasExtent(client.instance, 0, 1, 1);
        try client.execute();
        try client.begin();
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try rendering.draw.addTexturedQuad(client.instance, id, 0, 0, 0, 1, 1, 4, 4, 2, 2, false, false, 0, 0, 0);
        client.instance.faults.inject(case[0], 0);
        try std.testing.expectError(case[1], client.execute());
        try std.testing.expect(!client.instance.frame_ready);
        try std.testing.expectEqual(@as(usize, 1), client.instance.state.instruction_count);
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
        try std.testing.expect(sdl.SDL_GetRenderTarget(client.fixture.renderer) == null);
        var horizontal: sdl.SDL_TextureAddressMode = undefined;
        var vertical: sdl.SDL_TextureAddressMode = undefined;
        try std.testing.expect(sdl.SDL_GetRenderTextureAddressMode(client.fixture.renderer, &horizontal, &vertical));
        try std.testing.expectEqual(sdl.SDL_TEXTURE_ADDRESS_AUTO, horizontal);
        try std.testing.expectEqual(sdl.SDL_TEXTURE_ADDRESS_AUTO, vertical);
        try client.begin();
        try client.execute();
        try rendering.compositor.present(client.instance);
        try std.testing.expectEqual(@as(usize, 0), client.instance.state.instruction_count);
        const before = client.instance.canvas_stats;
        try client.begin();
        try rendering.layers.setCanvasSampling(client.instance, 0, .nearest);
        try client.execute();
        try std.testing.expectEqualDeep(before, client.instance.canvas_stats);
    }
}

test "source sampler edits preserve unrelated readiness invalidate hidden references and release isolated views" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 3, .shared);
    const unrelated = try rendering.textures.createDynamicTexture(client.instance, 1, 1);
    try client.begin();
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    try rendering.sampling.setSource(client.instance, id, .bilinear, .repeat);
    try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 1, 1, 1, 1, 0, 0, 4, 4, false, false, 0, 0, 0, 255, 255, 255, 255);
    try client.execute();
    try std.testing.expectEqual(@as(usize, 4), client.instance.sampling_cache.texture_bytes);
    try rendering.sampling.setSource(client.instance, unrelated, .bilinear, .repeat);
    try std.testing.expect(client.instance.frame_ready);
    client.instance.state.layers[0].visible = false;
    try rendering.sampling.setSource(client.instance, id, .nearest, .clamp);
    try std.testing.expect(!client.instance.frame_ready);
    try std.testing.expect(client.instance.state.layers[0].target_dirty);
    client.instance.state.layers[0].visible = true;
    try client.begin();
    try client.execute();
    try rendering.sampling.setSource(client.instance, id, .nearest, .clamp);
    try std.testing.expect(client.instance.frame_ready);
    client.instance.state.frame_state = .idle;
    try rendering.textures.destroyDynamicTexture(client.instance, id);
    try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
    const replacement = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .operation_only);
    try std.testing.expectEqual(id, replacement);
    try std.testing.expectEqual(rendering.types.Sampling.nearest, client.instance.state.operation_sources[id].filter);
    try std.testing.expectEqual(rendering.types.Addressing.clamp, client.instance.state.operation_sources[id].addressing);
}

test "bilinear thin NPOT clipped canvases retain identity taps tint opacity and stationary coverage" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    const dimensions = [_][2]u16{ .{ 1, 1 }, .{ 1, 5 }, .{ 3, 1 }, .{ 3, 5 } };
    for (dimensions) |dimension| for (families) |family| for ([_]u8{ 128, 255 }) |opacity| {
        client.instance.deinit();
        try client.instance.init(std.testing.allocator, .{ .renderer = client.fixture.renderer, .logical_width = 8, .logical_height = 8, .opaque_presentation = true });
        const width = dimension[0];
        const height = dimension[1];
        const count: usize = @as(usize, width) * height;
        var pixels: [15][4]u8 = undefined;
        for (pixels[0..count], 0..) |*pixel, index| pixel.* = .{ @intCast(index * 13), @intCast(255 - index * 11), 128, if (index % 2 == 0) 128 else 255 };
        var canvas: [15][4]u8 = undefined;
        completed(pixels[0..count], canvas[0..count], family);
        const id = try rendering.textures.createOperationDynamicTexture(client.instance, width, height, .operation_only);
        try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, width, height, std.mem.sliceAsBytes(pixels[0..count]), @as(c_int, width) * 4);
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.layers.setCanvasExtent(client.instance, 0, width, height);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        const tint = [3]u8{ 128, 240, 80 };
        const fields = [_]rendering.types.LayerPropField{ .opacity, .tint_r, .tint_g, .tint_b };
        const values = [_]i32{ opacity, tint[0], tint[1], tint[2] };
        for (fields, values, 0..) |field, value, index| client.instance.state.layer_prop_buffer[index] = .{ .layer_id = 0, .field = @intFromEnum(field), .value = value };
        _ = try rendering.layers.submitLayerPropCommands(client.instance, 4);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, width, height, 0, 0, width, height, false, false, 0, 0, 0, 255, 255, 255, 255);
        if (height > 1) {
            try rendering.layers.setSurfaceClip(client.instance, 0, .{ .x = 0, .y = 1, .w = width, .h = height - 1 });
            @memset(canvas[0..width], identity(family));
        }
        try rendering.layers.setAffine(client.instance, 0, .{ .a = 98304, .d = 65536, .tx = 64, .ty = 64 });
        try client.execute();
        for (try client.fixture.image(), 0..) |actual, index| {
            const source_x = (@as(f64, @floatFromInt(index % 8)) + 0.25) / 1.5;
            const source_y = @as(f64, @floatFromInt(index / 8)) + 0.25;
            const expected = if (source_x < width and source_y < height) present(sample(canvas[0..count], width, height, source_x, source_y, family), family, opacity, tint) else background;
            if (!matches(expected, actual)) std.debug.print("THIN_CANVAS_MISMATCH extent={any} family={s} opacity={d} pixel={d},{d} inverse={d},{d} expected={any} actual={any}\n", .{ dimension, @tagName(family), opacity, index % 8, index / 8, source_x, source_y, expected, actual });
            try std.testing.expect(matches(expected, actual));
        }
    };
}

test "interleaved source samplers restore ordinary draws and failed rectangle allocation retries" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    const pixels = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 } };
    const first = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 1, .shared);
    const second = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 1, .shared);
    for ([_]u16{ first, second }) |id| try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 3, 1, std.mem.asBytes(&pixels), 12);
    try rendering.sampling.setSource(client.instance, first, .bilinear, .repeat);
    try client.begin();
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    try rendering.draw.addOperationQuadUV(client.instance, first, 0, 0, .{ .x = -0.5, .y = 0, .w = 6, .h = 1 }, .{ .x = 0, .y = 0, .w = 6, .h = 1 }, .{ 255, 255, 255, 255 });
    try rendering.draw.addOperationQuadUV(client.instance, second, 0, 1, .{ .x = -0.375, .y = 0, .w = 6, .h = 1 }, .{ .x = 0, .y = 1, .w = 6, .h = 1 }, .{ 255, 255, 255, 255 });
    try rendering.draw.addTexturedQuad(client.instance, first, 0, 0, 0, 3, 1, 0, 2, 6, 1, false, false, 0, 0, 0);
    try client.execute();
    for (try client.fixture.image(), 0..) |actual, index| {
        const horizontal = index % 8;
        const vertical = index / 8;
        const expected = if (horizontal >= 6 or vertical >= 3) background else present(if (vertical == 0) sourceSample(&pixels, 3, 1, @floatFromInt(horizontal), 0.5, true) else nearestSource(&pixels, 3, 1, if (vertical == 1) @as(f64, @floatFromInt(horizontal)) + 0.125 else (@as(f64, @floatFromInt(horizontal)) + 0.5) / 2, 0.5, false), .normal, 255, .{ 255, 255, 255 });
        try std.testing.expect(matches(expected, actual));
    }
    try rendering.sampling.setSource(client.instance, first, .bilinear, .clamp);
    try client.begin();
    try rendering.layers.clearLayerContents(client.instance, 0);
    try rendering.draw.addTexturedQuadTinted(client.instance, first, 0, 0, 1, 0, 1, 1, 0, 0, 6, 1, false, false, 0, 0, 0, 255, 255, 255, 255);
    client.instance.faults.inject(.sampling_cpu_allocation, 0);
    try std.testing.expectError(error.SamplingPreparationFailed, client.execute());
    try std.testing.expect(client.instance.sampling_cache.views == null);
    try std.testing.expectEqual(@as(usize, 1), client.instance.state.instruction_count);
    try client.begin();
    try client.execute();
    for (try client.fixture.image(), 0..) |pixel, index| if (index / 8 == 0 and index % 8 < 6) try std.testing.expectEqual(pixels[1], pixel);
}

test "indexed isolated views track palette transactions and regional ownership limits" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    try rendering.textures.addGraphics8Bit(client.instance, 0, &.{ 0, 1, 1, 0 }, -1, &.{ 20, 220, 80, 255, 0, 255 }, 2, 2, 2);
    const id = client.instance.state.graphics[0].texture_ids[0];
    try rendering.sampling.setSource(client.instance, id, .bilinear, .repeat);
    try client.begin();
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 1, 1, 0, 0, 6, 6, false, false, 0, 0, 0, 255, 255, 255, 255);
    try client.execute();
    const allocations = client.instance.sampling_stats.texture_allocations;
    client.instance.state.frame_state = .idle;
    client.instance.faults.inject(.texture_creation, 0);
    try std.testing.expectError(error.TextureCreationFailed, rendering.textures.addPalette(client.instance, 0, 0, -1, &.{ 40, 80, 120, 255, 0, 255 }, 2));
    try rendering.textures.addPalette(client.instance, 0, 0, -1, &.{ 40, 80, 120, 255, 0, 255 }, 2);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(allocations, client.instance.sampling_stats.texture_allocations);
    for (try client.fixture.image(), 0..) |pixel, index| if (index % 8 < 6 and index / 8 < 6) try std.testing.expectEqual([4]u8{ 40, 80, 120, 255 }, pixel);
    const source = (try rendering.operation.source(client.instance, id)).?;
    try std.testing.expectError(error.InvalidSourceRectangle, rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = -1, .y = 0, .w = 1, .h = 1 }));
    const original_bytes = client.instance.sampling_cache.texture_bytes;
    client.instance.sampling_cache.texture_bytes = rendering.sampling.max_view_bytes;
    try std.testing.expectError(error.SamplingBudgetExceeded, rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = 0, .y = 0, .w = 2, .h = 1 }));
    try std.testing.expectEqual(rendering.sampling.max_view_bytes - original_bytes, client.instance.sampling_cache.texture_bytes);
    client.instance.sampling_cache.texture_bytes = 0;
    _ = try rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = 1, .y = 1, .w = 1, .h = 1 });
    client.instance.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_stats.retained_cpu_bytes);
    try std.testing.expectEqual(@as(usize, 0), client.instance.sampling_cache.texture_bytes);
    try client.instance.init(std.testing.allocator, .{ .renderer = client.fixture.renderer, .logical_width = 8, .logical_height = 8, .opaque_presentation = true });
    try std.testing.expectEqual(rendering.types.Sampling.nearest, client.instance.state.layers[0].sampling);
    try std.testing.expect(client.instance.sampling_cache.views == null);
}

test "rectangle cache evicts historical views across frames and retries replacement without allocations" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    const count = rendering.sampling.max_source_views * 2 + 9;
    var pixels: [count][4]u8 = undefined;
    for (&pixels, 0..) |*pixel, index| pixel.* = .{ @intCast(index % 251), @intCast(index / 251), 120, 255 };
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, count, 1, .operation_only);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, count, 1, std.mem.asBytes(&pixels), count * 4);
    try rendering.sampling.setSource(client.instance, id, .bilinear, .clamp);
    for (0..count) |index| {
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, .normal);
        try rendering.layers.clearLayerContents(client.instance, 0);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, @intCast(index), 0, 1, 1, 0, 0, 6, 6, false, false, 0, 0, 0, 255, 255, 255, 255);
        if (index == rendering.sampling.max_source_views) {
            client.instance.faults.inject(.sampling_copy, 0);
            try std.testing.expectError(error.SamplingCopyFailed, client.execute());
            try std.testing.expect(!client.instance.frame_ready);
            try std.testing.expect(client.instance.state.layers[0].target_dirty);
            try client.begin();
        }
        try client.execute();
        for (try client.fixture.image(), 0..) |pixel, offset| if (offset % 8 < 6 and offset / 8 < 6) try std.testing.expectEqual(pixels[index], pixel);
    }
    try std.testing.expectEqual(rendering.sampling.max_source_views, client.instance.sampling_stats.texture_allocations);
    try std.testing.expectEqual(rendering.sampling.max_source_views * 4, client.instance.sampling_cache.texture_bytes);
    const copies = client.instance.sampling_stats.copy_calls;
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(copies, client.instance.sampling_stats.copy_calls);
}

test "rectangle eviction preserves recently used views across clock rollover" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    const count = rendering.sampling.max_source_views;
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, count + 1, 1, .operation_only);
    const pixels = [_]u8{255} ** ((count + 1) * 4);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, count + 1, 1, &pixels, (count + 1) * 4);
    const source = (try rendering.operation.source(client.instance, id)).?;
    client.instance.sampling_cache.clock = std.math.maxInt(u64) - 2;
    for (0..count) |index| _ = try rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = @intCast(index), .y = 0, .w = 1, .h = 1 });
    const copies = client.instance.sampling_stats.copy_calls;
    _ = try rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try std.testing.expectEqual(copies, client.instance.sampling_stats.copy_calls);
    _ = try rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = count, .y = 0, .w = 1, .h = 1 });
    for (client.instance.sampling_cache.views.?) |view| try std.testing.expect(view.rectangle.x != 1);
    _ = try rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try std.testing.expectEqual(copies + 1, client.instance.sampling_stats.copy_calls);
    try std.testing.expectEqual(count, client.instance.sampling_stats.texture_allocations);
    client.instance.faults.inject(.sampling_target_creation, 0);
    try std.testing.expectError(error.SamplingPreparationFailed, rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = 0, .y = 0, .w = 2, .h = 1 }));
    try std.testing.expectEqual((count - 1) * 4, client.instance.sampling_cache.texture_bytes);
    _ = try rendering.sampling.sourceRectangle(client.instance, id, source, .{ .x = 0, .y = 0, .w = 2, .h = 1 });
    try std.testing.expectEqual((count - 1) * 4 + 8, client.instance.sampling_cache.texture_bytes);
}

test "rectangle byte pressure evicts views while preserving pinned canvas budget" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    const pixels = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 255, 0, 255 } };
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 4, 1, .operation_only);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 4, 1, std.mem.asBytes(&pixels), 16);
    try rendering.sampling.setSource(client.instance, id, .bilinear, .clamp);
    const reserved = rendering.sampling.max_view_bytes - 8;
    client.instance.sampling_cache.texture_bytes = reserved;
    defer client.instance.sampling_cache.texture_bytes -= reserved;
    for (0..12) |index| {
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, .normal);
        try rendering.layers.clearLayerContents(client.instance, 0);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, @intCast(index % 4), 0, 1, 1, 0, 0, 6, 6, false, false, 0, 0, 0, 255, 255, 255, 255);
        try client.execute();
        try std.testing.expect(client.instance.sampling_cache.texture_bytes <= rendering.sampling.max_view_bytes);
        for (try client.fixture.image(), 0..) |pixel, offset| if (offset % 8 < 6 and offset / 8 < 6) try std.testing.expectEqual(pixels[index % 4], pixel);
    }
    try std.testing.expectEqual(@as(usize, 2), client.instance.sampling_stats.texture_allocations);
    rendering.sampling.dropSource(client.instance, id);
    try std.testing.expectEqual(reserved, client.instance.sampling_cache.texture_bytes);
}

test "interior atlas rectangles retain every bilinear neighbourhood without UV insets" {
    var client = try Client.init();
    defer client.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(client.fixture.renderer)), "software")) return;
    const interior = [_][4]u8{ .{ 255, 0, 0, 128 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 128 }, .{ 255, 255, 0, 255 } };
    var atlas = [_][4]u8{.{ 255, 0, 255, 255 }} ** 16;
    atlas[5] = interior[0];
    atlas[6] = interior[1];
    atlas[9] = interior[2];
    atlas[10] = interior[3];
    var premultiplied: [4][4]u8 = undefined;
    completed(&interior, &premultiplied, .normal);
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 4, 4, .operation_only);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 4, 4, std.mem.asBytes(&atlas), 16);
    for ([_]rendering.types.Addressing{ .clamp, .repeat }) |address| for ([_]bool{ false, true }) |reflected| {
        try client.begin();
        try rendering.layers.clearLayerContents(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, .normal);
        try rendering.sampling.setSource(client.instance, id, .bilinear, address);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 1, 1, 2, 2, 0, 0, 6, 6, reflected, false, 0, 0, 0, 255, 255, 255, 255);
        try client.execute();
        for (try client.fixture.image(), 0..) |actual, index| {
            var source_x = (@as(f64, @floatFromInt(index % 8)) + 0.5) / 3;
            if (reflected) source_x = 2 - source_x;
            const source_y = (@as(f64, @floatFromInt(index / 8)) + 0.5) / 3;
            const expected = if (index % 8 < 6 and index / 8 < 6) present(sourceSample(&premultiplied, 2, 2, source_x, source_y, false), .normal, 255, .{ 255, 255, 255 }) else background;
            try std.testing.expect(matches(expected, actual));
        }
    };
    try std.testing.expectEqual(@as(usize, 1), client.instance.sampling_stats.texture_allocations);
    try std.testing.expectEqual(@as(usize, 1), client.instance.sampling_stats.copy_calls);
}

fn identity(family: Mode) [4]u8 {
    return if (family == .multiply) .{ 255, 255, 255, 255 } else .{ 0, 0, 0, 0 };
}

fn canvasPixels(family: Mode) [4][4]u8 {
    if (family == .multiply) return .{ .{ 128, 64, 200, 255 }, .{ 255, 255, 255, 255 }, .{ 10, 200, 80, 255 }, .{ 240, 20, 120, 255 } };
    var pixels = [4][4]u8{ .{ 128, 0, 0, 128 }, .{ 0, 0, 0, 0 }, .{ 0, 128, 0, 128 }, .{ 0, 0, 255, 255 } };
    if (family == .additive) for (&pixels) |*pixel| {
        pixel[3] = 0;
    };
    return pixels;
}

fn sample(pixels: []const [4]u8, width: usize, height: usize, horizontal: f64, vertical: f64, family: Mode) [4]f64 {
    const left: i64 = @intFromFloat(@floor(horizontal - 0.5));
    const top: i64 = @intFromFloat(@floor(vertical - 0.5));
    const fraction_x = horizontal - 0.5 - @as(f64, @floatFromInt(left));
    const fraction_y = vertical - 0.5 - @as(f64, @floatFromInt(top));
    var result: [4]f64 = .{ 0, 0, 0, 0 };
    for (0..2) |offset_y| for (0..2) |offset_x| {
        const source_x = left + @as(i64, @intCast(offset_x));
        const source_y = top + @as(i64, @intCast(offset_y));
        const pixel = if (source_x < 0 or source_y < 0 or source_x >= width or source_y >= height) identity(family) else pixels[@as(usize, @intCast(source_y)) * width + @as(usize, @intCast(source_x))];
        const weight = (if (offset_x == 0) 1 - fraction_x else fraction_x) * (if (offset_y == 0) 1 - fraction_y else fraction_y);
        for (0..4) |channel| result[channel] += @as(f64, @floatFromInt(pixel[channel])) / 255 * weight;
    };
    return result;
}

fn present(operation: [4]f64, family: Mode, opacity: u8, tint: [3]u8) [4]u8 {
    const lambda = @as(f64, @floatFromInt(opacity)) / 255;
    var result = background;
    for (0..3) |channel| {
        const destination = @as(f64, @floatFromInt(background[channel])) / 255;
        const modulation = @as(f64, @floatFromInt(tint[channel])) / 255;
        const value = switch (family) {
            .normal => lambda * modulation * operation[channel] + (1 - lambda * operation[3]) * destination,
            .additive => destination + lambda * modulation * operation[channel],
            .multiply => destination * (1 - lambda + lambda * modulation * operation[channel]),
            .legacy_rgba => unreachable,
        };
        result[channel] = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
    }
    return result;
}

fn matches(expected: [4]u8, actual: [4]u8) bool {
    for (expected, actual, 0..) |want, got, channel| {
        if (@abs(@as(i16, want) - got) > (if (channel == 3) @as(i16, 0) else 3)) return false;
    }
    return true;
}

fn sourceSample(pixels: []const [4]u8, width: usize, height: usize, horizontal: f64, vertical: f64, repeat: bool) [4]f64 {
    const left: i64 = @intFromFloat(@floor(horizontal - 0.5));
    const top: i64 = @intFromFloat(@floor(vertical - 0.5));
    const fraction_x = horizontal - 0.5 - @as(f64, @floatFromInt(left));
    const fraction_y = vertical - 0.5 - @as(f64, @floatFromInt(top));
    var result: [4]f64 = .{ 0, 0, 0, 0 };
    for (0..2) |offset_y| for (0..2) |offset_x| {
        var source_x = left + @as(i64, @intCast(offset_x));
        var source_y = top + @as(i64, @intCast(offset_y));
        source_x = if (repeat) @mod(source_x, @as(i64, @intCast(width))) else std.math.clamp(source_x, 0, @as(i64, @intCast(width)) - 1);
        source_y = if (repeat) @mod(source_y, @as(i64, @intCast(height))) else std.math.clamp(source_y, 0, @as(i64, @intCast(height)) - 1);
        const pixel = pixels[@as(usize, @intCast(source_y)) * width + @as(usize, @intCast(source_x))];
        const weight = (if (offset_x == 0) 1 - fraction_x else fraction_x) * (if (offset_y == 0) 1 - fraction_y else fraction_y);
        for (0..4) |channel| result[channel] += @as(f64, @floatFromInt(pixel[channel])) / 255 * weight;
    };
    return result;
}

fn nativeQuad(fixture: Fixture, texture: *sdl.SDL_Texture, source: sdl.SDL_FRect) !void {
    const color = sdl.SDL_FColor{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const vertices = [_]sdl.SDL_Vertex{
        .{ .position = .{ .x = 0, .y = 0 }, .color = color, .tex_coord = .{ .x = source.x, .y = source.y } },
        .{ .position = .{ .x = 6, .y = 0 }, .color = color, .tex_coord = .{ .x = source.x + source.w, .y = source.y } },
        .{ .position = .{ .x = 6, .y = 6 }, .color = color, .tex_coord = .{ .x = source.x + source.w, .y = source.y + source.h } },
        .{ .position = .{ .x = 0, .y = 6 }, .color = color, .tex_coord = .{ .x = source.x, .y = source.y + source.h } },
    };
    try std.testing.expect(sdl.SDL_RenderGeometry(fixture.renderer, texture, &vertices, 4, &[_]c_int{ 0, 1, 2, 2, 3, 0 }, 6));
}

const Fixture = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,

    fn init() !Fixture {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.VideoUnavailable;
        const window = sdl.SDL_CreateWindow("Explicit sampling qualification", 8, 8, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
        errdefer sdl.SDL_DestroyWindow(window);
        const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
        const software = std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(renderer)), "software");
        std.debug.print("sampling-check renderer={s} path={s}\n", .{ sdl.SDL_GetRendererName(renderer), if (software) "UNSUPPORTED operation rendering; rejection/state checks only" else "SDL_geometry" });
        return .{ .window = window, .renderer = renderer };
    }

    fn deinit(self: Fixture) void {
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }

    fn clear(self: Fixture) !void {
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(self.renderer, background[0], background[1], background[2], 255));
        try std.testing.expect(sdl.SDL_RenderClear(self.renderer));
    }

    fn image(self: Fixture) ![64][4]u8 {
        const surface = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        var result: [64][4]u8 = undefined;
        for (0..8) |vertical| for (0..8) |horizontal| {
            const pixel = &result[vertical * 8 + horizontal];
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(horizontal), @intCast(vertical), &pixel[0], &pixel[1], &pixel[2], &pixel[3]));
        };
        return result;
    }
};

test "native linear canvas probe preserves the independent identity edge diagnostic" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(fixture.renderer)), "software")) {
        std.debug.print("sampling-check UNSUPPORTED software operation blends; no operation pixel qualification\n", .{});
        return;
    }
    for (families) |family| {
        const pixels = canvasPixels(family);
        const texture = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, 2, 2) orelse return error.TextureUnavailable;
        defer sdl.SDL_DestroyTexture(texture);
        try std.testing.expect(sdl.SDL_UpdateTexture(texture, null, &pixels, 8));
        try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_LINEAR));
        try std.testing.expect(sdl.SDL_SetRenderTextureAddressMode(fixture.renderer, sdl.SDL_TEXTURE_ADDRESS_CLAMP, sdl.SDL_TEXTURE_ADDRESS_CLAMP));
        const blend = switch (family) {
            .normal => sdl.SDL_BLENDMODE_BLEND_PREMULTIPLIED,
            .additive => sdl.SDL_BLENDMODE_ADD_PREMULTIPLIED,
            .multiply => sdl.SDL_BLENDMODE_MUL,
            else => unreachable,
        };
        try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, blend));
        const color = sdl.SDL_FColor{ .r = 1, .g = 1, .b = 1, .a = 1 };
        const vertices = [_]sdl.SDL_Vertex{
            .{ .position = .{ .x = 0.25, .y = 0.25 }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
            .{ .position = .{ .x = 4.25, .y = 0.25 }, .color = color, .tex_coord = .{ .x = 1, .y = 0 } },
            .{ .position = .{ .x = 4.25, .y = 4.25 }, .color = color, .tex_coord = .{ .x = 1, .y = 1 } },
            .{ .position = .{ .x = 0.25, .y = 4.25 }, .color = color, .tex_coord = .{ .x = 0, .y = 1 } },
        };
        try fixture.clear();
        try std.testing.expect(sdl.SDL_RenderGeometry(fixture.renderer, texture, &vertices, 4, &[_]c_int{ 0, 1, 2, 2, 3, 0 }, 6));
        const actual = try fixture.image();
        var failures: usize = 0;
        for (0..8) |vertical| for (0..8) |horizontal| {
            const source_x = (@as(f64, @floatFromInt(horizontal)) + 0.25) / 2;
            const source_y = (@as(f64, @floatFromInt(vertical)) + 0.25) / 2;
            const expected = if (source_x >= 2 or source_y >= 2) background else present(sample(&pixels, 2, 2, source_x, source_y, family), family, 255, .{ 255, 255, 255 });
            if (!matches(expected, actual[vertical * 8 + horizontal])) {
                failures += 1;
                std.debug.print("DIRECT_CANVAS_EDGE family={s} pixel={d},{d} inverse={d}/8,{d}/8 expected={any} actual={any}\n", .{ @tagName(family), horizontal, vertical, horizontal * 4 + 1, vertical * 4 + 1, expected, actual[vertical * 8 + horizontal] });
            }
        };
        std.debug.print("DIRECT_CANVAS_RESULT family={s} failures={d} contract_supported=false\n", .{ @tagName(family), failures });
        try std.testing.expect(failures > 0);
    }
}

test "bounded SDL identity border copy qualifies canvas bilinear without changing coverage" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(fixture.renderer)), "software")) return;
    for (families) |family| {
        const pixels = canvasPixels(family);
        const texture = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, 2, 2) orelse return error.TextureUnavailable;
        defer sdl.SDL_DestroyTexture(texture);
        const view = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_TARGET, 4, 4) orelse return error.TextureUnavailable;
        defer sdl.SDL_DestroyTexture(view);
        try std.testing.expect(sdl.SDL_UpdateTexture(texture, null, &pixels, 8));
        try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST));
        try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_NONE));
        try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, view));
        const clear = identity(family);
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(fixture.renderer, clear[0], clear[1], clear[2], clear[3]));
        try std.testing.expect(sdl.SDL_RenderClear(fixture.renderer));
        const destination = sdl.SDL_FRect{ .x = 1, .y = 1, .w = 2, .h = 2 };
        try std.testing.expect(sdl.SDL_RenderTexture(fixture.renderer, texture, null, &destination));
        try std.testing.expect(sdl.SDL_SetTextureScaleMode(view, sdl.SDL_SCALEMODE_LINEAR));
        const blend = switch (family) {
            .normal => sdl.SDL_BLENDMODE_BLEND_PREMULTIPLIED,
            .additive => sdl.SDL_BLENDMODE_ADD_PREMULTIPLIED,
            .multiply => sdl.SDL_BLENDMODE_MUL,
            else => unreachable,
        };
        try std.testing.expect(sdl.SDL_SetTextureBlendMode(view, blend));
        const color = sdl.SDL_FColor{ .r = 1, .g = 1, .b = 1, .a = 1 };
        const vertices = [_]sdl.SDL_Vertex{
            .{ .position = .{ .x = 0.25, .y = 0.25 }, .color = color, .tex_coord = .{ .x = 0.25, .y = 0.25 } },
            .{ .position = .{ .x = 4.25, .y = 0.25 }, .color = color, .tex_coord = .{ .x = 0.75, .y = 0.25 } },
            .{ .position = .{ .x = 4.25, .y = 4.25 }, .color = color, .tex_coord = .{ .x = 0.75, .y = 0.75 } },
            .{ .position = .{ .x = 0.25, .y = 4.25 }, .color = color, .tex_coord = .{ .x = 0.25, .y = 0.75 } },
        };
        try fixture.clear();
        try std.testing.expect(sdl.SDL_SetRenderTextureAddressMode(fixture.renderer, sdl.SDL_TEXTURE_ADDRESS_CLAMP, sdl.SDL_TEXTURE_ADDRESS_CLAMP));
        try std.testing.expect(sdl.SDL_RenderGeometry(fixture.renderer, view, &vertices, 4, &[_]c_int{ 0, 1, 2, 2, 3, 0 }, 6));
        const actual = try fixture.image();
        for (0..8) |vertical| for (0..8) |horizontal| {
            const source_x = (@as(f64, @floatFromInt(horizontal)) + 0.25) / 2;
            const source_y = (@as(f64, @floatFromInt(vertical)) + 0.25) / 2;
            const expected = if (source_x >= 2 or source_y >= 2) background else present(sample(&pixels, 2, 2, source_x, source_y, family), family, 255, .{ 255, 255, 255 });
            if (!matches(expected, actual[vertical * 8 + horizontal])) std.debug.print("PADDED_CANVAS_EXCEPTION family={s} pixel={d},{d} expected={any} actual={any}\n", .{ @tagName(family), horizontal, vertical, expected, actual[vertical * 8 + horizontal] });
            try std.testing.expect(matches(expected, actual[vertical * 8 + horizontal]));
        };
        std.debug.print("PADDED_CANVAS_RESULT family={s} path=SDL_copy_then_geometry allocations=1 extra_bytes=48 copy_bytes=16 submissions=1 no_coverage_growth=true\n", .{@tagName(family)});
    }
}

test "native source linear NPOT repeat and negative seam sampling are independently qualified" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(fixture.renderer)), "software")) return;
    try std.testing.expect(sdl.SDL_GetBooleanProperty(sdl.SDL_GetRendererProperties(fixture.renderer), sdl.SDL_PROP_RENDERER_TEXTURE_WRAPPING_BOOLEAN, false));
    var pixels: [15][4]u8 = undefined;
    for (0..5) |vertical| for (0..3) |horizontal| {
        pixels[vertical * 3 + horizontal] = .{ @intCast(horizontal * 90), @intCast(vertical * 50), 0, 255 };
    };
    const texture = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, 3, 5) orelse return error.TextureUnavailable;
    defer sdl.SDL_DestroyTexture(texture);
    try std.testing.expect(sdl.SDL_UpdateTexture(texture, null, &pixels, 12));
    try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_LINEAR));
    try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_BLEND_PREMULTIPLIED));
    for ([_]bool{ false, true }) |repeat| {
        const mode = if (repeat) sdl.SDL_TEXTURE_ADDRESS_WRAP else sdl.SDL_TEXTURE_ADDRESS_CLAMP;
        try std.testing.expect(sdl.SDL_SetRenderTextureAddressMode(fixture.renderer, mode, mode));
        try fixture.clear();
        try nativeQuad(fixture, texture, .{ .x = -0.5 / 3.0, .y = -0.5 / 5.0, .w = 6.0 / 3.0, .h = 6.0 / 5.0 });
        const actual = try fixture.image();
        for (0..8) |vertical| for (0..8) |horizontal| {
            const expected = if (horizontal >= 6 or vertical >= 6) background else present(sourceSample(&pixels, 3, 5, @floatFromInt(horizontal), @floatFromInt(vertical), repeat), .normal, 255, .{ 255, 255, 255 });
            try std.testing.expect(matches(expected, actual[vertical * 8 + horizontal]));
        };
        std.debug.print("DIRECT_SOURCE_RESULT dimensions=3x5 linear=true repeat={} negative_uv=true both_seams=true path=SDL_geometry\n", .{repeat});
    }
}

test "native source rectangle probe records foreign atlas colour leakage" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(fixture.renderer)), "software")) return;
    var pixels: [9][4]u8 = @splat(.{ 255, 0, 255, 255 });
    pixels[4] = .{ 20, 220, 80, 255 };
    const texture = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, 3, 3) orelse return error.TextureUnavailable;
    defer sdl.SDL_DestroyTexture(texture);
    try std.testing.expect(sdl.SDL_UpdateTexture(texture, null, &pixels, 12));
    try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_LINEAR));
    try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_BLEND_PREMULTIPLIED));
    try std.testing.expect(sdl.SDL_SetRenderTextureAddressMode(fixture.renderer, sdl.SDL_TEXTURE_ADDRESS_CLAMP, sdl.SDL_TEXTURE_ADDRESS_CLAMP));
    try fixture.clear();
    try nativeQuad(fixture, texture, .{ .x = 1.0 / 3.0, .y = 1.0 / 3.0, .w = 1.0 / 3.0, .h = 1.0 / 3.0 });
    const actual = try fixture.image();
    var failures: usize = 0;
    for (0..6) |vertical| for (0..6) |horizontal| {
        if (!matches(pixels[4], actual[vertical * 8 + horizontal])) {
            failures += 1;
            std.debug.print("DIRECT_RECTANGLE_EDGE pixel={d},{d} expected={any} actual={any}\n", .{ horizontal, vertical, pixels[4], actual[vertical * 8 + horizontal] });
        }
    };
    try std.testing.expect(failures > 0);
    std.debug.print("DIRECT_RECTANGLE_RESULT foreign_colour_failures={d} required_rectangle_clamp_supported=false\n", .{failures});
    try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST));
    try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_NONE));
    const view = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_TARGET, 1, 1) orelse return error.TextureUnavailable;
    defer sdl.SDL_DestroyTexture(view);
    try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, view));
    const rect = sdl.SDL_FRect{ .x = 1, .y = 1, .w = 1, .h = 1 };
    try std.testing.expect(sdl.SDL_RenderTexture(fixture.renderer, texture, &rect, null));
    try std.testing.expect(sdl.SDL_SetTextureScaleMode(view, sdl.SDL_SCALEMODE_LINEAR));
    try std.testing.expect(sdl.SDL_SetTextureBlendMode(view, sdl.SDL_BLENDMODE_BLEND_PREMULTIPLIED));
    try fixture.clear();
    try nativeQuad(fixture, view, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    const isolated = try fixture.image();
    for (0..6) |vertical| for (0..6) |horizontal| {
        try std.testing.expect(matches(pixels[4], isolated[vertical * 8 + horizontal]));
    };
    std.debug.print("ISOLATED_RECTANGLE_RESULT path=SDL_copy_then_geometry extra_gpu_bytes=4 copy_bytes=4 correct=true\n", .{});
}
