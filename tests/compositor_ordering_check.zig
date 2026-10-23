const std = @import("std");
const rendering = @import("compositor");
const types = rendering.types;
const sdl = rendering.sdl;
const red = [4]u8{ 230, 30, 50, 255 };
const green = [4]u8{ 20, 210, 70, 255 };
const modes = [_]Mode{ .geometry, .blit, .retained, .retained_blit };

const Mode = enum {
    geometry,
    blit,
    retained,
    retained_blit,

    fn layer(self: Mode) u8 {
        return if (self == .retained or self == .retained_blit) types.max_layers - 1 else types.immediate_layer_id;
    }
};

const Capture = struct {
    surface: *sdl.SDL_Surface,

    fn deinit(self: Capture) void {
        sdl.SDL_DestroySurface(self.surface);
    }

    fn expect(self: Capture, horizontal: c_int, vertical: c_int, expected: [4]u8) !void {
        var actual: [4]u8 = undefined;
        try std.testing.expect(sdl.SDL_ReadSurfacePixel(self.surface, horizontal, vertical, &actual[0], &actual[1], &actual[2], &actual[3]));
        try std.testing.expectEqual(expected, actual);
    }
};

const Fixture = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    instance: *rendering.Instance,

    fn init() !Fixture {
        try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
        errdefer sdl.SDL_Quit();
        const window = sdl.SDL_CreateWindow("Compositor ordering", 64, 64, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
        errdefer sdl.SDL_DestroyWindow(window);
        const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
        errdefer sdl.SDL_DestroyRenderer(renderer);
        const instance = try std.testing.allocator.create(rendering.Instance);
        try instance.init(std.testing.allocator, .{ .renderer = renderer, .logical_width = 64, .logical_height = 64 });
        std.debug.print("ordering-check: SDL {d}, renderer {s}\n", .{ sdl.SDL_GetVersion(), sdl.SDL_GetRendererName(renderer) });
        return .{ .window = window, .renderer = renderer, .instance = instance };
    }

    fn deinit(self: *Fixture) void {
        self.instance.deinit();
        std.testing.allocator.destroy(self.instance);
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }

    fn graphic(self: *Fixture, slot: usize, color: [4]u8) !void {
        const palette = [_]u8{ color[0], color[1], color[2], 0, 0, 0 };
        try rendering.textures.addGraphics8Bit(self.instance, slot, &.{0}, 1, &palette, 1, 1, 2);
    }

    fn reset(self: *Fixture, mode: Mode) !void {
        self.instance.deinit();
        try self.instance.init(std.testing.allocator, .{ .renderer = self.renderer, .logical_width = 64, .logical_height = 64 });
        self.instance.state.use_geometry_backend = mode != .blit and mode != .retained_blit;
        try self.graphic(0, red);
        try self.graphic(1, green);
    }

    fn begin(self: *Fixture, mode: Mode) !void {
        self.instance.state.frame_state = .updating;
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255));
        try std.testing.expect(sdl.SDL_RenderClear(self.renderer));
        if (mode.layer() != types.immediate_layer_id) try self.property(mode.layer(), .clear_a, 255);
    }

    fn property(self: *Fixture, layer: u8, field: types.LayerPropField, value: i32) !void {
        self.instance.state.layer_prop_buffer[0] = .{ .layer_id = layer, .field = @intFromEnum(field), .value = value };
        _ = try rendering.layers.submitLayerPropCommands(self.instance, 1);
    }

    fn submit(self: *Fixture, mode: Mode, graphic_slot: usize, priority: c_int, angle: f64) !void {
        try rendering.draw.addTexturedQuadTinted(self.instance, self.instance.state.graphics[graphic_slot].texture_ids[0], mode.layer(), priority, 0, 0, 1, 1, 8, 8, 24, 24, false, false, 0, 0, angle, 255, 255, 255, 255);
    }

    fn batch(self: *Fixture, mode: Mode, commands: []const types.ExternalDrawInstruction) !void {
        if (mode.layer() == types.immediate_layer_id) {
            try std.testing.expectEqual(commands.len, try rendering.draw.submitDrawInstructionsBulk(self.instance, commands.ptr, commands.len));
        } else {
            @memcpy(self.instance.state.layer_staging_buffers[mode.layer()][0..commands.len], commands);
            try std.testing.expectEqual(commands.len, try rendering.layers.submitLayer(self.instance, mode.layer(), commands.len));
        }
    }

    fn capture(self: *Fixture) !Capture {
        try rendering.layers.compileDirtyRetainedLayers(self.instance);
        try rendering.compositor.executeCompositeFrame(self.instance);
        self.instance.state.frame_state = .idle;
        return .{ .surface = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadbackFailed };
    }
};

fn command(graphic: c_int, priority: c_int, angle: f64, horizontal: c_int, vertical: c_int, width: c_int, height: c_int) types.ExternalDrawInstruction {
    return .{
        .x_loc = 0,
        .y_loc = 0,
        .width = 1,
        .height = 1,
        .x_dest = horizontal,
        .y_dest = vertical,
        .w_dest = width,
        .h_dest = height,
        .graphic_index = graphic,
        .palette_index = 0,
        .layer_id = 0,
        .priority = priority,
        .center_x = 0,
        .center_y = 0,
        .angle = angle,
        .flip_h = 0,
        .flip_v = 0,
    };
}

test "texture allocation does not override submission order in single or bulk replay" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for (modes) |mode| {
        for ([_]bool{ false, true }) |reverse| {
            for ([_]bool{ false, true }) |bulk| {
                try fixture.reset(mode);
                try fixture.begin(mode);
                const first: usize = if (reverse) 1 else 0;
                const last = 1 - first;
                if (bulk) {
                    const commands = [_]types.ExternalDrawInstruction{ command(@intCast(first), 0, 0, 8, 8, 24, 24), command(@intCast(last), 0, 0, 8, 8, 24, 24) };
                    try fixture.batch(mode, &commands);
                } else {
                    try fixture.submit(mode, first, 0, 0);
                    try fixture.submit(mode, last, 0, 0);
                }
                const capture = try fixture.capture();
                defer capture.deinit();
                try capture.expect(20, 20, if (last == 0) red else green);
            }
        }
    }
}

test "genuinely rotated and simple quads retain both submission directions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for (modes) |mode| {
        for ([_]bool{ false, true }) |rotated_first| {
            for ([_]bool{ false, true }) |bulk| {
                try fixture.reset(mode);
                if (bulk) {
                    const palette = [_]u8{ red[0], red[1], red[2], green[0], green[1], green[2], 0, 0, 0 };
                    try rendering.textures.addGraphics8Bit(fixture.instance, 0, &.{ 0, 1 }, 2, &palette, 2, 1, 3);
                }
                try fixture.begin(mode);
                if (bulk) {
                    var commands = [_]types.ExternalDrawInstruction{ command(0, 0, if (rotated_first) 27 else 0, 8, 8, 24, 24), command(0, 0, if (rotated_first) 0 else 27, 12, 12, 16, 16) };
                    commands[1].x_loc = 1;
                    try fixture.batch(mode, &commands);
                } else {
                    try rendering.draw.addTexturedQuadTinted(fixture.instance, fixture.instance.state.white_texture_id, mode.layer(), 0, 0, 0, 1, 1, 8, 8, 24, 24, false, false, 0, 0, if (rotated_first) 27 else 0, red[0], red[1], red[2], 255);
                    try rendering.draw.addTexturedQuadTinted(fixture.instance, fixture.instance.state.white_texture_id, mode.layer(), 0, 0, 0, 1, 1, 8, 8, 24, 24, false, false, 0, 0, if (rotated_first) 0 else 27, green[0], green[1], green[2], 255);
                }
                const capture = try fixture.capture();
                defer capture.deinit();
                try capture.expect(20, 20, green);
                if (bulk) {
                    const references = if (mode.layer() == types.immediate_layer_id) fixture.instance.state.sorted_draw_indices[0..2] else fixture.instance.state.layer_sorted_refs[0..2];
                    try std.testing.expectEqual(@as(u16, 0), references[0].index);
                    try std.testing.expectEqual(@as(u16, 1), references[1].index);
                }
            }
        }
    }
}

test "priority wins over reverse submission order" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for (modes) |mode| {
        for ([_]bool{ false, true }) |bulk| {
            try fixture.reset(mode);
            try fixture.begin(mode);
            if (bulk) {
                const commands = [_]types.ExternalDrawInstruction{ command(0, 7, 0, 8, 8, 24, 24), command(1, -7, 0, 8, 8, 24, 24) };
                try fixture.batch(mode, &commands);
            } else {
                try fixture.submit(mode, 0, 7, 0);
                try fixture.submit(mode, 1, -7, 0);
            }
            const capture = try fixture.capture();
            defer capture.deinit();
            try capture.expect(20, 20, red);
        }
    }
}

test "consecutive compatible draws batch and separated draws stay separated" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for (modes) |mode| {
        try fixture.reset(mode);
        try fixture.begin(mode);
        const commands = [_]types.ExternalDrawInstruction{
            command(0, 0, 0, 8, 8, 24, 24), command(0, 0, 0, 8, 8, 24, 24),
            command(1, 0, 0, 8, 8, 24, 24), command(0, 0, 0, 8, 8, 8, 24),
        };
        try fixture.batch(mode, &commands);
        const capture = try fixture.capture();
        defer capture.deinit();
        try capture.expect(12, 20, red);
        try capture.expect(24, 20, green);
        if (mode.layer() != types.immediate_layer_id) {
            const layer = fixture.instance.state.layers[mode.layer()];
            try std.testing.expectEqual(@as(u16, 3), layer.run_count);
            try std.testing.expectEqual(@as(u32, 12), layer.runs[0].index_count);
        } else if (mode == .geometry) {
            try std.testing.expectEqual(@as(usize, 3), fixture.instance.state.composite_entry_count);
            try std.testing.expectEqual(@as(u32, 12), fixture.instance.state.immediate_texture_runs[0].index_count);
            try std.testing.expectEqual(@as(usize, 3), fixture.instance.state.render_stats.draw_calls);
        }
    }
}

test "equal-z composition uses layer IDs then immediate run sequence" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.reset(.geometry);
    try fixture.begin(.geometry);
    for ([_]u8{ 5, 2 }) |layer| {
        try fixture.property(layer, .clear_a, 0);
        try fixture.property(layer, .z, 7);
        const color = if (layer == 5) red else green;
        try fixture.property(layer, .clear_r, color[0]);
        try fixture.property(layer, .clear_g, color[1]);
        try fixture.property(layer, .clear_b, color[2]);
        try fixture.property(layer, .clear_a, 255);
    }
    const commands = [_]types.ExternalDrawInstruction{
        command(1, 7, 0, 0, 16, 64, 16), command(0, 7, 0, 0, 16, 32, 16), command(1, 7, 0, 0, 16, 16, 16),
    };
    try fixture.batch(.geometry, &commands);
    const capture = try fixture.capture();
    defer capture.deinit();
    try capture.expect(8, 8, red);
    try capture.expect(8, 24, green);
    try capture.expect(24, 24, red);
    try capture.expect(48, 24, green);
    try std.testing.expectEqual(@as(usize, 5), fixture.instance.state.composite_entry_count);
    for ([_]u16{ 2, 5, 0, 1, 2 }, 0..) |expected, position| {
        const entry = fixture.instance.state.composite_entries[position];
        try std.testing.expectEqual(expected, entry.index);
        try std.testing.expectEqual(if (position < 2) types.CompositeDomain.retained else types.CompositeDomain.immediate, entry.domain);
    }
}

test "seventeen distinct retained textures replay the final accepted draw" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.reset(.retained);
    for (0..17) |position| try fixture.graphic(2 + position, .{ @intCast(30 + position * 9), @intCast(230 - position * 7), 90, 255 });
    try fixture.begin(.retained);
    var commands: [17]types.ExternalDrawInstruction = undefined;
    for (&commands, 0..) |*entry, position| entry.* = command(@intCast(2 + position), 0, 0, @intCast(position % 16 * 4), @intCast(position / 16 * 4), 4, 4);
    try fixture.batch(.retained, &commands);
    const capture = try fixture.capture();
    defer capture.deinit();
    for (0..17) |position| try capture.expect(@intCast(position % 16 * 4 + 2), @intCast(position / 16 * 4 + 2), .{ @intCast(30 + position * 9), @intCast(230 - position * 7), 90, 255 });
    try std.testing.expectEqual(@as(u16, 17), fixture.instance.state.layers[modes[2].layer()].run_count);
}

test "all 256 alternating retained draws replay with single and bulk submission" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for ([_]Mode{ .retained, .retained_blit }) |mode| {
        for ([_]bool{ false, true }) |bulk| {
            try fixture.reset(mode);
            try fixture.begin(mode);
            var commands: [types.max_slab_size]types.ExternalDrawInstruction = undefined;
            for (&commands, 0..) |*entry, position| {
                entry.* = command(@intCast(position % 2), 0, 0, @intCast(position % 16 * 4), @intCast(position / 16 * 4), 4, 4);
                if (!bulk) try rendering.draw.addTexturedQuadTinted(fixture.instance, fixture.instance.state.graphics[position % 2].texture_ids[0], mode.layer(), 0, 0, 0, 1, 1, entry.x_dest, entry.y_dest, 4, 4, false, false, 0, 0, 0, 255, 255, 255, 255);
            }
            if (bulk) try fixture.batch(mode, &commands);
            const capture = try fixture.capture();
            defer capture.deinit();
            for (0..types.max_slab_size) |position| try capture.expect(@intCast(position % 16 * 4 + 2), @intCast(position / 16 * 4 + 2), if (position % 2 == 0) red else green);
            const layer = fixture.instance.state.layers[mode.layer()];
            try std.testing.expectEqual(@as(u16, 256), layer.run_count);
            try std.testing.expectEqual(@as(u32, 1024), layer.cached_vertex_count);
            try std.testing.expectEqual(@as(u32, 1536), layer.cached_index_count);
            try std.testing.expectEqual(@as(usize, 257), fixture.instance.state.render_stats.draw_calls);
            try std.testing.expectEqual(@as(usize, 256 * 4), fixture.instance.state.render_stats.vertices_submitted);
            try std.testing.expectEqual(@as(usize, 256 * 6), fixture.instance.state.render_stats.indices_submitted);
        }
    }
}
