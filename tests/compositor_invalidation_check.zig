const std = @import("std");
const rendering = @import("compositor");
const sdl = rendering.sdl;
const red = [4]u8{ 230, 30, 50, 255 };
const green = [4]u8{ 20, 210, 70, 255 };
const black = [4]u8{ 0, 0, 0, 255 };
const palette = [_]u8{ 230, 30, 50, 20, 210, 70 };

const Fixture = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    instance: *rendering.Instance,

    fn init() !Fixture {
        try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
        errdefer sdl.SDL_Quit();
        const window = sdl.SDL_CreateWindow("Compositor invalidation", 64, 64, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
        errdefer sdl.SDL_DestroyWindow(window);
        const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
        errdefer sdl.SDL_DestroyRenderer(renderer);
        const instance = try std.testing.allocator.create(rendering.Instance);
        try instance.init(std.testing.allocator, .{ .renderer = renderer, .logical_width = 64, .logical_height = 64 });
        instance.state.frame_state = .updating;
        for ([_]u8{ 0, 1, 2, 31 }) |layer| {
            instance.state.layer_prop_buffer[0] = .{ .layer_id = layer, .field = @intFromEnum(rendering.types.LayerPropField.clear_r), .value = 1 };
            _ = try rendering.layers.submitLayerPropCommands(instance, 1);
        }
        instance.state.frame_state = .idle;
        std.debug.print("invalidation-check: renderer {s}\n", .{sdl.SDL_GetRendererName(renderer)});
        return .{ .window = window, .renderer = renderer, .instance = instance };
    }

    fn deinit(self: *Fixture) void {
        self.instance.deinit();
        std.testing.allocator.destroy(self.instance);
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }

    fn begin(self: *Fixture) !void {
        self.instance.state.frame_state = .updating;
        self.instance.changes = .{};
        self.instance.state.render_stats = .{};
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255));
        try std.testing.expect(sdl.SDL_RenderClear(self.renderer));
    }

    fn draw(self: *Fixture, texture_id: u16, layer: u8, horizontal: c_int) !void {
        try rendering.draw.addTexturedQuadTinted(self.instance, texture_id, layer, 0, 0, 0, 1, 1, horizontal, 8, 16, 16, false, false, 0, 0, 0, 255, 255, 255, 255);
    }

    fn property(self: *Fixture, layer: u8, field: rendering.types.LayerPropField, value: i32) !void {
        self.instance.state.layer_prop_buffer[0] = .{ .layer_id = layer, .field = @intFromEnum(field), .value = value };
        _ = try rendering.layers.submitLayerPropCommands(self.instance, 1);
    }

    fn render(self: *Fixture) !void {
        try rendering.layers.compileDirtyRetainedLayers(self.instance);
        try rendering.compositor.executeCompositeFrame(self.instance);
        self.instance.state.frame_state = .idle;
    }

    fn expect(self: *Fixture, horizontal: c_int, expected: [4]u8) !void {
        const surface = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        var actual: [4]u8 = undefined;
        try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, horizontal, 16, &actual[0], &actual[1], &actual[2], &actual[3]));
        try std.testing.expectEqual(expected, actual);
    }

    fn texture(self: *Fixture, color: [4]u8) !u16 {
        const texture_id = try rendering.textures.createDynamicTexture(self.instance, 1, 1);
        try rendering.textures.updateDynamicTexture(self.instance, texture_id, 0, 0, 1, 1, &color, 4);
        return texture_id;
    }
};

test "clear alpha changes empty legacy membership with a nonempty cached composition list" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.begin();
    try fixture.property(0, .clear_a, 255);
    try fixture.property(31, .clear_r, 230);
    try fixture.property(31, .clear_g, 30);
    try fixture.property(31, .clear_b, 50);
    try fixture.render();
    try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.retained_composite_entry_count);
    for ([_]i32{ 255, 0, 255, 0 }) |alpha| {
        try fixture.begin();
        try fixture.property(31, .clear_a, alpha);
        try std.testing.expect(fixture.instance.state.layers[31].order_dirty);
        try fixture.render();
        try std.testing.expectEqual(@as(usize, if (alpha == 0) 1 else 2), fixture.instance.state.retained_composite_entry_count);
        try fixture.expect(16, if (alpha == 0) .{ 1, 0, 0, 255 } else red);
    }
}

test "retained single append refreshes an already rasterized layer without replacement" {
    for ([_]bool{ true, false }) |geometry_backend| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.instance.state.use_geometry_backend = geometry_backend;
        const red_id = try fixture.texture(red);
        const green_id = try fixture.texture(green);
        try fixture.begin();
        try fixture.draw(red_id, 31, 8);
        try fixture.render();
        try fixture.expect(16, red);
        try fixture.begin();
        try fixture.draw(green_id, 31, 8);
        try fixture.render();
        try fixture.expect(16, green);
        try std.testing.expectEqual(@as(u16, 2), fixture.instance.state.layers[31].slab_count);
    }
}

test "dynamic uploads refresh every referencing layer but reuse compiled geometry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const texture_id = try fixture.texture(red);
    const unrelated_id = try fixture.texture(red);
    try fixture.begin();
    try fixture.draw(texture_id, 0, 8);
    try fixture.draw(texture_id, 1, 32);
    try fixture.draw(unrelated_id, 2, 48);
    try fixture.render();
    try fixture.expect(16, red);
    try fixture.expect(40, red);
    fixture.instance.changes = .{};
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 1, 1, &green, 4);
    try std.testing.expect(fixture.instance.changes.present_needed);
    for (0..2) |layer| {
        try std.testing.expect(fixture.instance.state.layers[layer].target_dirty);
        try std.testing.expect(!fixture.instance.state.layers[layer].geometry_dirty);
        try std.testing.expect(!fixture.instance.state.layers[layer].order_dirty);
    }
    try std.testing.expect(!fixture.instance.state.layers[2].target_dirty);
    try fixture.begin();
    try fixture.render();
    try fixture.expect(16, green);
    try fixture.expect(40, green);
    try fixture.expect(56, red);
    try fixture.begin();
    try fixture.render();
    try std.testing.expectEqual(@as(usize, 3), fixture.instance.state.render_stats.draw_calls);
    fixture.instance.changes = .{};
    try std.testing.expectError(error.InvalidTextureRegion, rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 1, 0, 1, 1, &red, 4));
    try std.testing.expect(!fixture.instance.changes.present_needed);
    try std.testing.expect(!fixture.instance.state.layers[0].target_dirty);
    try fixture.begin();
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 1, 1, &red, 4);
    try fixture.render();
    try fixture.expect(16, red);
    try fixture.expect(40, red);
}

test "hidden retained layer keeps resource dirtiness until revival" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const texture_id = try fixture.texture(red);
    try fixture.begin();
    try fixture.draw(texture_id, 0, 8);
    try fixture.render();
    try fixture.begin();
    try fixture.property(0, .visible, 0);
    try fixture.render();
    try fixture.expect(16, black);
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 1, 1, &green, 4);
    try fixture.begin();
    try fixture.render();
    try fixture.expect(16, black);
    try std.testing.expect(fixture.instance.state.layers[0].target_dirty);
    try fixture.begin();
    try fixture.property(0, .visible, 1);
    try fixture.render();
    try fixture.expect(16, green);
}

test "indexed pixel and palette edits refresh retained pixels" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try rendering.textures.addGraphics8Bit(fixture.instance, 0, &.{0}, 2, &palette, 1, 1, 2);
    try rendering.textures.addPalette(fixture.instance, 0, 1, 2, &palette, 2);
    try fixture.begin();
    var command = std.mem.zeroes(rendering.types.ExternalDrawInstruction);
    command.width = 1;
    command.height = 1;
    command.x_dest = 8;
    command.y_dest = 8;
    command.w_dest = 16;
    command.h_dest = 16;
    fixture.instance.state.layer_staging_buffers[0][0] = command;
    try std.testing.expectEqual(@as(usize, 1), try rendering.layers.submitLayer(fixture.instance, 0, 1));
    try fixture.draw(fixture.instance.state.graphics[0].texture_ids[1], 1, 32);
    try fixture.render();
    try fixture.expect(16, red);
    try fixture.expect(40, red);
    try fixture.begin();
    try rendering.textures.updateGraphics8BitPixels(fixture.instance, 0, &.{1}, 1, 1);
    try std.testing.expect(!fixture.instance.state.layers[0].geometry_dirty);
    try std.testing.expect(!fixture.instance.state.layers[1].geometry_dirty);
    try fixture.render();
    try fixture.expect(16, green);
    try fixture.expect(40, green);
    const swapped = [_]u8{ 20, 210, 70, 230, 30, 50 };
    try rendering.textures.addPalette(fixture.instance, 0, 1, 2, &swapped, 2);
    try std.testing.expect(!fixture.instance.state.layers[1].geometry_dirty);
    try fixture.begin();
    try fixture.render();
    try fixture.expect(16, green);
    try fixture.expect(40, red);
}

test "graphic dimension replacement recompiles normalized UVs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try rendering.textures.addGraphics8Bit(fixture.instance, 0, &.{0}, 2, &palette, 1, 1, 2);
    const texture_id = fixture.instance.state.graphics[0].texture_ids[0];
    try fixture.begin();
    try fixture.draw(texture_id, 0, 8);
    try fixture.render();
    try fixture.expect(16, red);
    try rendering.textures.addGraphics8Bit(fixture.instance, 0, &.{ 1, 0 }, 2, &palette, 2, 1, 2);
    try std.testing.expectEqual(texture_id, fixture.instance.state.graphics[0].texture_ids[0]);
    try fixture.begin();
    try fixture.render();
    try fixture.expect(16, green);
    try fixture.expect(22, green);
    try std.testing.expectEqual(@as(f32, 0.5), rendering.geometry.cachedVertex(fixture.instance, 0, 1).tex_coord.x);
}

test "released and reused physical texture IDs invalidate retained pixels and UVs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const texture_id = try fixture.texture(red);
    try fixture.begin();
    try fixture.draw(texture_id, 0, 8);
    try fixture.render();
    try fixture.expect(16, red);
    try rendering.textures.destroyDynamicTexture(fixture.instance, texture_id);
    try fixture.begin();
    try fixture.render();
    try fixture.expect(16, black);
    const reused = try rendering.textures.createDynamicTexture(fixture.instance, 2, 1);
    try std.testing.expectEqual(texture_id, reused);
    const pixels = green ++ red;
    try rendering.textures.updateDynamicTexture(fixture.instance, reused, 0, 0, 2, 1, &pixels, 8);
    try fixture.begin();
    try fixture.render();
    try fixture.expect(22, green);
    try std.testing.expectEqual(@as(f32, 0.5), rendering.geometry.cachedVertex(fixture.instance, 0, 1).tex_coord.x);
}

test "explicit render target edits refresh referencing retained canvases" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const handle = try rendering.render_targets.create(fixture.instance, 1, 1);
    try fixture.begin();
    try rendering.render_targets.begin(fixture.instance, handle, .{ .r = red[0], .g = red[1], .b = red[2], .a = 255 });
    try rendering.render_targets.end(fixture.instance);
    try fixture.draw(fixture.instance.state.render_targets[handle].texture_id, 0, 8);
    try fixture.render();
    try fixture.expect(16, red);
    try fixture.begin();
    try rendering.render_targets.begin(fixture.instance, handle, .{ .r = green[0], .g = green[1], .b = green[2], .a = 255 });
    try rendering.render_targets.end(fixture.instance);
    try fixture.render();
    try fixture.expect(16, green);
    try fixture.begin();
    try rendering.render_targets.begin(fixture.instance, handle, .{ .clear = false });
    try rendering.draw.addSolidRect(fixture.instance, 0, 0, 0, 1, 1, red[0], red[1], red[2], 255);
    try rendering.render_targets.end(fixture.instance);
    try std.testing.expect(!fixture.instance.state.layers[0].geometry_dirty);
    try fixture.render();
    try fixture.expect(16, red);
}
