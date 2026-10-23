const std = @import("std");
const rendering = @import("compositor");
const sdl = rendering.sdl;
const Affine = rendering.types.Affine;
const Mode = rendering.types.CanvasMode;
const families = [_]Mode{ .normal, .additive, .multiply };
const interior = [_][4]u8{ .{ 240, 40, 80, 128 }, .{ 20, 220, 60, 128 }, .{ 255, 255, 255, 0 }, .{ 80, 120, 240, 128 }, .{ 200, 40, 120, 128 }, .{ 40, 200, 160, 128 } };
const matrices = [_]Affine{
    .{ .tx = 256, .ty = 256 },
    .{ .a = 131072, .d = 98304, .tx = 64, .ty = 192 },
    .{ .a = 0, .b = -65536, .c = 65536, .d = 0, .tx = 1280, .ty = 256 },
    .{ .b = 32768, .c = -16384, .tx = 320, .ty = 576 },
    .{ .a = -98304, .d = 131072, .tx = 1600, .ty = 64 },
    .{ .a = -65536, .d = -65536, .tx = 640, .ty = 896 },
    .{ .a = 32768, .d = 32768, .tx = 320, .ty = 320 },
    .{ .a = 65536, .b = 65536, .c = 65536, .d = 65536 },
    .{ .a = 65536, .b = 65535, .c = 65537, .d = 65536, .tx = 256 },
    .{ .a = std.math.maxInt(i32), .b = -std.math.maxInt(i32), .d = 98304, .tx = 64, .ty = 64 },
    .{ .a = std.math.maxInt(i32), .b = -std.math.maxInt(i32), .c = std.math.maxInt(i32), .d = -std.math.maxInt(i32) + 65536, .tx = std.math.maxInt(i32), .ty = std.math.minInt(i32) },
    .{ .tx = std.math.maxInt(i32), .ty = std.math.minInt(i32) },
};

const Inverse = struct { horizontal: i128, vertical: i128, denominator: i128 };

fn inverse(matrix: Affine, horizontal: usize, vertical: usize, scroll: [2]i32) Inverse {
    var denominator = @as(i128, matrix.a) * matrix.d - @as(i128, matrix.b) * matrix.c;
    const relative_x = (@as(i128, @intCast(horizontal)) + scroll[0]) * 256 + 128 - matrix.tx;
    const relative_y = (@as(i128, @intCast(vertical)) + scroll[1]) * 256 + 128 - matrix.ty;
    var source_x = (relative_x * matrix.d - relative_y * matrix.b) * 256;
    var source_y = (relative_y * matrix.a - relative_x * matrix.c) * 256;
    if (denominator < 0) {
        denominator = -denominator;
        source_x = -source_x;
        source_y = -source_y;
    }
    return .{ .horizontal = source_x, .vertical = source_y, .denominator = denominator };
}

fn corner(matrix: Affine, horizontal: f64, vertical: f64, scroll: [2]i32) [2]f64 {
    return .{
        (@as(f64, @floatFromInt(matrix.a)) * horizontal + @as(f64, @floatFromInt(matrix.b)) * vertical) / 65536 + @as(f64, @floatFromInt(matrix.tx)) / 256 - @as(f64, @floatFromInt(scroll[0])),
        (@as(f64, @floatFromInt(matrix.c)) * horizontal + @as(f64, @floatFromInt(matrix.d)) * vertical) / 65536 + @as(f64, @floatFromInt(matrix.ty)) / 256 - @as(f64, @floatFromInt(scroll[1])),
    };
}

fn coveragePermission(matrix: Affine, horizontal: usize, vertical: usize, scroll: [2]i32) bool {
    const corners = [_][2]f64{ corner(matrix, 0, 0, scroll), corner(matrix, 2, 0, scroll), corner(matrix, 2, 3, scroll), corner(matrix, 0, 3, scroll) };
    const point = [2]f64{ @as(f64, @floatFromInt(horizontal)) + 0.5, @as(f64, @floatFromInt(vertical)) + 0.5 };
    for (corners, 0..) |start, index| {
        const end = corners[(index + 1) % 4];
        const delta = [2]f64{ end[0] - start[0], end[1] - start[1] };
        const length_squared = delta[0] * delta[0] + delta[1] * delta[1];
        const fraction = if (length_squared == 0) 0 else std.math.clamp(((point[0] - start[0]) * delta[0] + (point[1] - start[1]) * delta[1]) / length_squared, 0, 1);
        const distance_x = point[0] - start[0] - fraction * delta[0];
        const distance_y = point[1] - start[1] - fraction * delta[1];
        if (distance_x * distance_x + distance_y * distance_y <= 1.0 / 65536.0) return true;
    }
    return false;
}

fn identity(family: Mode) [4]u8 {
    return if (family == .multiply) .{ 255, 255, 255, 255 } else .{ 0, 0, 0, 0 };
}

fn tap(horizontal: i128, vertical: i128) [4]f64 {
    const pixel = interior[@as(usize, @intCast(std.math.clamp(vertical, 0, 2))) * 2 + @as(usize, @intCast(std.math.clamp(horizontal, 0, 1)))];
    var result: [4]f64 = undefined;
    for (0..3) |channel| result[channel] = @as(f64, @floatFromInt((@as(u32, pixel[channel]) * pixel[3] + 127) / 255)) / 255;
    result[3] = @as(f64, @floatFromInt(pixel[3])) / 255;
    return result;
}

fn fragment(coordinates: Inverse, linear: bool, horizontal: i128, vertical: i128) [4]f64 {
    if (!linear) return tap(horizontal, vertical);
    const source_x = @as(f64, @floatFromInt(coordinates.horizontal)) / @as(f64, @floatFromInt(coordinates.denominator)) - 0.5;
    const source_y = @as(f64, @floatFromInt(coordinates.vertical)) / @as(f64, @floatFromInt(coordinates.denominator)) - 0.5;
    const left: i128 = @intFromFloat(@floor(source_x));
    const top: i128 = @intFromFloat(@floor(source_y));
    const fraction_x = source_x - @floor(source_x);
    const fraction_y = source_y - @floor(source_y);
    var result: [4]f64 = @splat(0);
    for (0..2) |row| for (0..2) |column| {
        const weight = (if (column == 0) 1 - fraction_x else fraction_x) * (if (row == 0) 1 - fraction_y else fraction_y);
        const pixel = tap(left + column, top + row);
        for (&result, pixel) |*value, source| value.* += weight * source;
    };
    return result;
}

fn accumulated(source: [4]f64, family: Mode, tint: [4]u8) [4]u8 {
    const alpha = source[3] * @as(f64, @floatFromInt(tint[3])) / 255;
    var result = identity(family);
    for (0..3) |channel| {
        const modulation = @as(f64, @floatFromInt((@as(u32, tint[channel]) * tint[3] + 127) / 255)) / 255;
        const energy = source[channel] * modulation;
        result[channel] = @intFromFloat(@round(255 * (if (family == .multiply) 1 - alpha + energy else energy)));
    }
    result[3] = if (family == .normal) @intFromFloat(@round(alpha * 255)) else if (family == .multiply) 255 else 0;
    return result;
}

fn matches(actual: [4]u8, expected: [4]u8) bool {
    for (actual, expected, 0..) |got, wanted, channel| if (@abs(@as(i16, got) - wanted) > (if (channel == 3) @as(i16, 0) else 3)) return false;
    return true;
}

fn axisPermission(numerator: i128, denominator: i128, reference: i128, selected: i128) bool {
    if (selected == reference) return true;
    if (@abs(selected - reference) != 1) return false;
    const boundary = @max(selected, reference) * denominator;
    return @abs(numerator - boundary) * 256 <= denominator;
}

fn accepts(actual: [4]u8, matrix: Affine, horizontal: usize, vertical: usize, scroll: [2]i32, linear: bool, family: Mode, tint: [4]u8) bool {
    const coordinates = inverse(matrix, horizontal, vertical, scroll);
    if (coordinates.denominator == 0) return matches(actual, identity(family));
    const covered = coordinates.horizontal >= 0 and coordinates.vertical >= 0 and coordinates.horizontal < 2 * coordinates.denominator and coordinates.vertical < 3 * coordinates.denominator;
    const edge = coveragePermission(matrix, horizontal, vertical, scroll);
    if ((!covered or edge) and matches(actual, identity(family))) return true;
    if (!covered and !edge) return false;
    const reference_x = @divFloor(coordinates.horizontal, coordinates.denominator);
    const reference_y = @divFloor(coordinates.vertical, coordinates.denominator);
    if (linear) return matches(actual, accumulated(fragment(coordinates, true, reference_x, reference_y), family, tint));
    var delta_y: i128 = -1;
    while (delta_y <= 1) : (delta_y += 1) {
        var delta_x: i128 = -1;
        while (delta_x <= 1) : (delta_x += 1) {
            if (!axisPermission(coordinates.horizontal, coordinates.denominator, reference_x, reference_x + delta_x) or !axisPermission(coordinates.vertical, coordinates.denominator, reference_y, reference_y + delta_y)) continue;
            if (matches(actual, accumulated(fragment(coordinates, false, reference_x + delta_x, reference_y + delta_y), family, tint))) return true;
        }
    }
    return false;
}

const Fixture = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,

    fn init() !Fixture {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.VideoUnavailable;
        const window = sdl.SDL_CreateWindow("Affine sprite pixels", 8, 8, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
        errdefer sdl.SDL_DestroyWindow(window);
        const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
        return .{ .window = window, .renderer = renderer };
    }

    fn deinit(self: Fixture) void {
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }

    fn supported(self: Fixture) bool {
        return !std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(self.renderer)), "software");
    }

    fn check(self: Fixture, matrix: Affine, scroll: [2]i32, linear: bool, family: Mode, tint: [4]u8, border: usize, clip: ?sdl.SDL_Rect) !void {
        const surface = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        for (0..8 + 2 * border) |row| for (0..8 + 2 * border) |column| {
            var actual: [4]u8 = undefined;
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(column), @intCast(row), &actual[0], &actual[1], &actual[2], &actual[3]));
            const ring = row < border or column < border or row >= 8 + border or column >= 8 + border;
            const outside_clip = if (clip) |rect| column < border + @as(usize, @intCast(rect.x)) or row < border + @as(usize, @intCast(rect.y)) or column >= border + @as(usize, @intCast(rect.x + rect.w)) or row >= border + @as(usize, @intCast(rect.y + rect.h)) else false;
            const accepted = if (ring or outside_clip) matches(actual, identity(family)) else accepts(actual, matrix, column - border, row - border, scroll, linear, family, tint);
            if (accepted and !ring and !outside_clip) {
                const coordinates = inverse(matrix, column - border, row - border, scroll);
                if (coordinates.denominator != 0) {
                    const covered = coordinates.horizontal >= 0 and coordinates.vertical >= 0 and coordinates.horizontal < 2 * coordinates.denominator and coordinates.vertical < 3 * coordinates.denominator;
                    const reference = if (covered) accumulated(fragment(coordinates, linear, @divFloor(coordinates.horizontal, coordinates.denominator), @divFloor(coordinates.vertical, coordinates.denominator)), family, tint) else identity(family);
                    if (!matches(actual, reference)) std.debug.print("SPRITE_PRECISION matrix={any} scroll={any} linear={} family={s} pixel={d},{d} inverse={any} reference={any} actual={any}\n", .{ matrix, scroll, linear, @tagName(family), column - border, row - border, coordinates, reference, actual });
                }
            }
            if (!accepted) std.debug.print("SPRITE_MISMATCH matrix={any} scroll={any} linear={} family={s} pixel={d},{d} inverse={any} actual={any}\n", .{ matrix, scroll, linear, @tagName(family), column, row, inverse(matrix, column -| border, row -| border, scroll), actual });
            try std.testing.expect(accepted);
        };
    }
};

test "direct SDL affine sprite accumulation uses independent inverse sampling coverage and strict seams" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    if (!fixture.supported()) {
        std.debug.print("SPRITE_PROBE software operation pixels unsupported\n", .{});
        return;
    }
    var pixels: [6][4]u8 = undefined;
    for (interior, &pixels) |pixel, *result| {
        for (0..3) |channel| result[channel] = @intCast((@as(u32, pixel[channel]) * pixel[3] + 127) / 255);
        result[3] = pixel[3];
    }
    const texture = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, 2, 3) orelse return error.TextureUnavailable;
    defer sdl.SDL_DestroyTexture(texture);
    try std.testing.expect(sdl.SDL_UpdateTexture(texture, null, &pixels, 8));
    const target = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_TARGET, 10, 10) orelse return error.TextureUnavailable;
    defer sdl.SDL_DestroyTexture(target);
    const tint = [4]u8{ 192, 240, 128, 128 };
    for (matrices, 0..) |matrix, index| for (families) |family| for ([_]bool{ false, true }) |linear| {
        const scroll: [2]i32 = if (index >= matrices.len - 2) .{ 8388607, -8388608 } else .{ 0, 0 };
        try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, target));
        try std.testing.expect(sdl.SDL_SetRenderClipRect(fixture.renderer, null));
        const clear = identity(family);
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(fixture.renderer, clear[0], clear[1], clear[2], clear[3]));
        try std.testing.expect(sdl.SDL_RenderClear(fixture.renderer));
        const clip = sdl.SDL_Rect{ .x = 1, .y = 1, .w = 8, .h = 8 };
        try std.testing.expect(sdl.SDL_SetRenderClipRect(fixture.renderer, &clip));
        try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, rendering.operation.blend(family)));
        try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, if (linear) sdl.SDL_SCALEMODE_LINEAR else sdl.SDL_SCALEMODE_NEAREST));
        const local = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 3 }, .{ 0, 3 } };
        var vertices: [4]sdl.SDL_Vertex = undefined;
        for (local, &vertices) |point, *vertex| {
            const position = corner(matrix, point[0], point[1], scroll);
            vertex.* = .{ .position = .{ .x = @floatCast(position[0] + 1), .y = @floatCast(position[1] + 1) }, .tex_coord = .{ .x = @floatCast(point[0] / 2), .y = @floatCast(point[1] / 3) }, .color = .{ .r = @as(f32, @floatFromInt((@as(u32, tint[0]) * tint[3] + 127) / 255)) / 255, .g = @as(f32, @floatFromInt((@as(u32, tint[1]) * tint[3] + 127) / 255)) / 255, .b = @as(f32, @floatFromInt((@as(u32, tint[2]) * tint[3] + 127) / 255)) / 255, .a = @as(f32, @floatFromInt(tint[3])) / 255 } };
        }
        try std.testing.expect(sdl.SDL_RenderGeometry(fixture.renderer, texture, &vertices, 4, &[_]c_int{ 0, 1, 2, 2, 3, 0 }, 6));
        try fixture.check(matrix, scroll, linear, family, tint, 1, null);
    };
    try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, null));
    std.debug.print("SPRITE_PROBE Metal SDL geometry {d} accumulation cases; no extra clipping or tolerance\n", .{matrices.len * families.len * 2});
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
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.fixture.renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(self.fixture.renderer, 80, 120, 160, 255));
        try std.testing.expect(sdl.SDL_RenderClear(self.fixture.renderer));
    }

    fn execute(self: *Client) !void {
        try rendering.layers.compileDirtyRetainedLayers(self.instance);
        try rendering.compositor.executeCompositeFrame(self.instance);
    }

    fn image(self: *Client) ![64][4]u8 {
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.fixture.renderer, null));
        const surface = sdl.SDL_RenderReadPixels(self.fixture.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        var result: [64][4]u8 = undefined;
        for (&result, 0..) |*pixel, index| try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(index % 8), @intCast(index / 8), &pixel[0], &pixel[1], &pixel[2], &pixel[3]));
        return result;
    }

    fn atlas(self: *Client, capability: rendering.textures.OperationTextureMode) !u16 {
        var pixels: [20][4]u8 = @splat(.{ 255, 0, 255, 255 });
        for (interior, 0..) |pixel, index| pixels[(index / 2 + 1) * 4 + index % 2 + 1] = pixel;
        const id = try rendering.textures.createOperationDynamicTexture(self.instance, 4, 5, capability);
        try rendering.textures.updateDynamicTexture(self.instance, id, 0, 0, 4, 5, std.mem.asBytes(&pixels), 16);
        return id;
    }

    fn check(self: *Client, matrix: Affine, scroll: [2]i32, linear: bool, family: Mode, tint: [4]u8, clip: ?sdl.SDL_Rect) !void {
        const layer = self.instance.state.layers[0];
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.fixture.renderer, self.instance.state.texture_table[layer.target_texture_id]));
        defer _ = sdl.SDL_SetRenderTarget(self.fixture.renderer, null);
        try self.fixture.check(matrix, scroll, linear, family, tint, layer.backing.border, clip);
    }
};

test "integrated affine sprites isolate atlas taps and retain exact raw transforms across scroll padded and unpadded canvases" {
    var client = try Client.init();
    defer client.deinit();
    const id = try client.atlas(.operation_only);
    const tint = [4]u8{ 192, 240, 128, 128 };
    if (!client.fixture.supported()) {
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, .normal);
        try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sx = 1, .sy = 1, .sw = 2, .sh = 3 });
        try std.testing.expectError(error.UnsupportedCanvasBackend, client.execute());
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
        std.debug.print("SPRITE_INTEGRATION software operation rejection only\n", .{});
        return;
    }
    for (families) |family| for ([_]bool{ false, true }) |padded| for ([_]bool{ false, true }) |linear| for (matrices, 0..) |matrix, index| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.layers.setCanvasSampling(client.instance, 0, if (padded) .bilinear else .nearest);
        try rendering.sampling.setSource(client.instance, id, if (linear) .bilinear else .nearest, if (index % 2 == 0) .repeat else .clamp);
        const scroll: [2]i32 = if (index >= matrices.len - 2) .{ 8388607, -8388608 } else .{ 0, 0 };
        try rendering.layers.setContentScroll(client.instance, 0, scroll[0], scroll[1]);
        try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sx = 1, .sy = 1, .sw = 2, .sh = 3, .affine = matrix, .tint = tint });
        try client.execute();
        try client.check(matrix, scroll, linear, family, tint, null);
        const compiled = client.instance.canvas_stats.compiled_layers;
        const lowered = client.instance.canvas_stats.lowered_vertices;
        const copies = client.instance.sampling_stats.copy_calls;
        const source = client.instance.source_stats;
        try client.begin();
        try client.execute();
        try std.testing.expectEqual(compiled, client.instance.canvas_stats.compiled_layers);
        try std.testing.expectEqual(lowered, client.instance.canvas_stats.lowered_vertices);
        try std.testing.expectEqual(copies, client.instance.sampling_stats.copy_calls);
        try std.testing.expectEqualDeep(source, client.instance.source_stats);
        try rendering.layers.setContentScroll(client.instance, 0, scroll[0] + 1, scroll[1] - 1);
        try rendering.layers.setSurfaceClip(client.instance, 0, .{ .x = 1, .y = 2, .w = 5, .h = 4 });
        try client.execute();
        try std.testing.expectEqual(compiled, client.instance.canvas_stats.compiled_layers);
        try client.check(matrix, .{ scroll[0] + 1, scroll[1] - 1 }, linear, family, tint, .{ .x = 1, .y = 2, .w = 5, .h = 4 });
    };
    std.debug.print("SPRITE_INTEGRATION Metal SDL geometry {d} patterned atlas cases plus clipped scroll replay; exact alpha and unchanged precision caps\n", .{matrices.len * families.len * 4});
}

fn property(client: *Client, field: rendering.types.LayerPropField, value: i32) !void {
    client.instance.state.layer_prop_buffer[0] = .{ .layer_id = 0, .field = @intFromEnum(field), .value = value };
    _ = try rendering.layers.submitLayerPropCommands(client.instance, 1);
}

fn presented(operation: [4]u8, family: Mode, opacity: u8, tint: [3]u8) [4]u8 {
    var result = [4]u8{ 80, 120, 160, 255 };
    const fraction = @as(f64, @floatFromInt(opacity)) / 255;
    for (0..3) |channel| {
        const energy = @as(f64, @floatFromInt(operation[channel])) / 255;
        const modulation = @as(f64, @floatFromInt(tint[channel])) / 255;
        const destination = @as(f64, @floatFromInt(result[channel])) / 255;
        const output = switch (family) {
            .normal => fraction * modulation * energy + (1 - fraction * @as(f64, @floatFromInt(operation[3])) / 255) * destination,
            .additive => @min(1, destination + fraction * modulation * energy),
            .multiply => destination * (1 - fraction + fraction * modulation * energy),
            else => unreachable,
        };
        result[channel] = @intFromFloat(@round(output * 255));
    }
    return result;
}

test "sprite and completed layer transforms compose independently with tint opacity and promoted nearest presentation" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.fixture.supported()) return;
    const id = try client.atlas(.shared);
    const matrix = Affine{ .a = 131072, .tx = 256, .ty = 256 };
    const tint = [4]u8{ 192, 240, 128, 128 };
    for (families) |family| for ([_]bool{ false, true }) |linear| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.sampling.setSource(client.instance, id, if (linear) .bilinear else .nearest, .repeat);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sx = 1, .sy = 1, .sw = 2, .sh = 3, .affine = matrix, .tint = tint });
        try client.execute();
        try client.check(matrix, .{ 0, 0 }, linear, family, tint, null);
        const before = client.instance.canvas_stats;
        try client.begin();
        try rendering.layers.setCanvasSampling(client.instance, 0, .nearest);
        try rendering.layers.setAffine(client.instance, 0, .{ .a = 0, .b = -65536, .c = 65536, .d = 0, .tx = 2048 });
        try property(&client, .opacity, 128);
        try property(&client, .tint_r, 160);
        try property(&client, .tint_g, 240);
        try property(&client, .tint_b, 128);
        try client.execute();
        try std.testing.expectEqualDeep(before, client.instance.canvas_stats);
        for (try client.image(), 0..) |actual, index| {
            const canvas_x = index / 8;
            const canvas_y = 7 - index % 8;
            const coordinates = inverse(matrix, canvas_x, canvas_y, .{ 0, 0 });
            const covered = canvas_x >= 1 and canvas_x < 5 and canvas_y >= 1 and canvas_y < 4;
            const operation = if (covered) accumulated(fragment(coordinates, linear, @divFloor(coordinates.horizontal, coordinates.denominator), @divFloor(coordinates.vertical, coordinates.denominator)), family, tint) else identity(family);
            try std.testing.expect(matches(actual, presented(operation, family, 128, .{ 160, 240, 128 })));
        }
    };
}

test "sprites rectangles and raw UV quads preserve stable translucent order and strict shared diagonal seams" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.fixture.supported()) return;
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .shared);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 255, 255, 255, 255 }, 4);
    const colors = [_][4]u8{ .{ 240, 40, 80, 128 }, .{ 40, 220, 80, 128 }, .{ 80, 40, 240, 128 } };
    for (families) |family| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 1, 1, 1, 1, 4, 4, false, false, 0, 0, 0, colors[0][0], colors[0][1], colors[0][2], colors[0][3]);
        try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sw = 1, .sh = 1, .affine = .{ .a = 262144, .d = 262144, .tx = 256, .ty = 256 }, .tint = colors[1] });
        try rendering.draw.addOperationQuadUV(client.instance, id, 0, 0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = 1, .y = 1, .w = 4, .h = 4 }, colors[2]);
        try client.execute();
        const layer = client.instance.state.layers[0];
        try std.testing.expectEqual(@as(u16, 2), layer.run_count);
        try std.testing.expectEqual(@as(u32, 12), layer.cached_vertex_count);
        var expected = identity(family);
        for (colors) |color| for (0..3) |channel| {
            const energy: u32 = (@as(u32, color[channel]) * color[3] + 127) / 255;
            expected[channel] = @intCast(switch (family) {
                .normal => @min(255, energy + (@as(u32, expected[channel]) * (255 - color[3]) + 127) / 255),
                .additive => @min(255, @as(u32, expected[channel]) + energy),
                .multiply => (@as(u32, expected[channel]) * (255 - color[3] + energy) + 127) / 255,
                else => unreachable,
            });
        };
        if (family == .normal) expected[3] = 224;
        for (try client.image(), 0..) |actual, index| {
            const covered = index % 8 >= 1 and index % 8 < 5 and index / 8 >= 1 and index / 8 < 5;
            try std.testing.expect(matches(actual, presented(if (covered) expected else identity(family), family, 255, .{ 255, 255, 255 })));
        }
    }
}

test "sprite resource edits release incompatible reuse revival and hidden edits retain raw instructions" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.fixture.supported()) return;
    const id = try client.atlas(.operation_only);
    try client.begin();
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sx = 1, .sy = 1, .sw = 2, .sh = 3, .affine = .{ .tx = 256, .ty = 256 } });
    try client.execute();
    const compiled = client.instance.canvas_stats.compiled_layers;
    try rendering.textures.updateDynamicTexture(client.instance, id, 1, 1, 1, 1, &.{ 20, 240, 80, 255 }, 4);
    try std.testing.expect(!client.instance.frame_ready);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(compiled, client.instance.canvas_stats.compiled_layers);
    try std.testing.expectEqual([4]u8{ 20, 240, 80, 255 }, (try client.image())[9]);
    try property(&client, .visible, 0);
    client.instance.state.frame_state = .idle;
    try rendering.textures.destroyDynamicTexture(client.instance, id);
    const small = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .operation_only);
    try std.testing.expectEqual(id, small);
    try rendering.textures.updateDynamicTexture(client.instance, small, 0, 0, 1, 1, &.{ 255, 0, 255, 255 }, 4);
    try client.begin();
    try client.execute();
    try property(&client, .visible, 1);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(@as(u16, 1), client.instance.state.layers[0].slab_count);
    try std.testing.expectEqual(@as(u32, 0), client.instance.state.layers[0].cached_vertex_count);
    for (try client.image()) |actual| try std.testing.expectEqual([4]u8{ 80, 120, 160, 255 }, actual);
    client.instance.state.frame_state = .idle;
    try rendering.textures.destroyDynamicTexture(client.instance, small);
    const revived = try client.atlas(.shared);
    try std.testing.expectEqual(id, revived);
    try client.begin();
    try client.execute();
    try client.check(.{ .tx = 256, .ty = 256 }, .{ 0, 0 }, false, .normal, .{ 255, 255, 255, 255 }, null);
    try rendering.layers.setContentScroll(client.instance, 0, -1000, -1000);
    try client.begin();
    try client.execute();
    const before = client.instance.canvas_stats.compiled_layers;
    try rendering.layers.setContentScroll(client.instance, 0, 0, 0);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(before, client.instance.canvas_stats.compiled_layers);
    try client.check(.{ .tx = 256, .ty = 256 }, .{ 0, 0 }, false, .normal, .{ 255, 255, 255, 255 }, null);
}

test "sprite preparation accumulation and presentation failures keep immediate submissions and retry" {
    const points = [_]rendering.faults.Point{ .operation_allocation, .operation_upload, .sampling_cpu_allocation, .sampling_target_creation, .sampling_setup, .sampling_copy, .sampling_restore, .sampling_state, .sampling_address_state, .target_select, .texture_blend, .texture_color, .texture_alpha, .clip, .geometry, .target_restore, .present };
    for (points) |point| {
        var client = try Client.init();
        defer client.deinit();
        if (!client.fixture.supported()) return;
        const id = try client.atlas(.shared);
        try client.begin();
        try rendering.layers.setCanvasMode(client.instance, 0, .normal);
        try rendering.sampling.setSource(client.instance, id, .bilinear, .repeat);
        try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sx = 1, .sy = 1, .sw = 2, .sh = 3 });
        try rendering.draw.addSolidRect(client.instance, 1, 7, 7, 1, 1, 255, 255, 255, 255);
        client.instance.faults.inject(point, 0);
        if (point == .present) {
            try client.execute();
            try std.testing.expectError(error.PresentFailed, rendering.compositor.present(client.instance));
        } else if (client.execute()) |_| {
            std.debug.print("SPRITE_FAULT not reached={s}\n", .{@tagName(point)});
            return error.InjectedFailureNotObserved;
        } else |_| {}
        try std.testing.expect(!client.instance.frame_ready);
        try std.testing.expectEqual(@as(usize, 1), client.instance.state.instruction_count);
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
        try client.begin();
        try client.execute();
        try client.check(.{}, .{ 0, 0 }, true, .normal, .{ 255, 255, 255, 255 }, null);
        try rendering.compositor.present(client.instance);
        try std.testing.expectEqual(@as(usize, 0), client.instance.state.instruction_count);
    }
}

test "sprite oracle rejects one axis sampling escape near coverage and internal double accumulation" {
    try std.testing.expect(axisPermission(257, 256, 1, 0));
    try std.testing.expect(!axisPermission(258, 256, 1, 0));
    try std.testing.expect(!axisPermission(256, 256, 1, -1));
    try std.testing.expect(!(axisPermission(257, 256, 1, 0) and axisPermission(384, 256, 1, 0)));
    try std.testing.expect(coveragePermission(.{ .a = std.math.maxInt(i32), .d = std.math.maxInt(i32), .tx = 129 }, 0, 0, .{ 0, 0 }));
    try std.testing.expect(!coveragePermission(.{ .a = std.math.maxInt(i32), .d = std.math.maxInt(i32), .tx = 130 }, 0, 0, .{ 0, 0 }));
    const matrix = Affine{ .a = 131072, .d = 131072 };
    const tint = [4]u8{ 255, 255, 255, 255 };
    const coordinates = inverse(matrix, 0, 0, .{ 0, 0 });
    const single = accumulated(fragment(coordinates, false, 0, 0), .normal, tint);
    try std.testing.expect(accepts(single, matrix, 0, 0, .{ 0, 0 }, false, .normal, tint));
    try std.testing.expect(!accepts(identity(.normal), matrix, 0, 0, .{ 0, 0 }, false, .normal, tint));
    var doubled = single;
    doubled[3] = 192;
    try std.testing.expect(!accepts(doubled, matrix, 0, 0, .{ 0, 0 }, false, .normal, tint));
}

test "identity translation and quarter rotation sprites match existing rectangle pixels and ordinary draws after operation" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.fixture.supported()) return;
    const id = try client.atlas(.shared);
    for (families) |family| for ([_]bool{ false, true }) |linear| for ([_]bool{ false, true }) |rotated| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.sampling.setSource(client.instance, id, if (linear) .bilinear else .nearest, .repeat);
        const matrix: Affine = if (rotated) .{ .a = 0, .b = -65536, .c = 65536, .d = 0, .tx = 1024, .ty = 256 } else .{ .tx = 512, .ty = 256 };
        try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sx = 1, .sy = 1, .sw = 2, .sh = 3, .affine = matrix });
        try rendering.draw.addTexturedQuad(client.instance, id, 1, 1, 1, 2, 3, 5, 4, 2, 3, false, false, 0, 0, 0);
        try client.execute();
        const sprite_image = try client.image();
        try client.begin();
        try rendering.layers.clearLayerContents(client.instance, 0);
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 1, 1, 2, 3, 2, 1, 2, 3, false, false, if (rotated) 1 else 0, if (rotated) 1 else 0, if (rotated) 90 else 0, 255, 255, 255, 255);
        try client.execute();
        try std.testing.expectEqualDeep(sprite_image, try client.image());
        try rendering.compositor.present(client.instance);
    };
}

test "sprite admission is transactional and degenerate sprites still validate source bounds and charge one slot" {
    var client = try Client.init();
    defer client.deinit();
    const id = try client.atlas(.shared);
    try client.begin();
    const sprite = rendering.types.AffineSprite{ .texture_id = id, .layer_id = 0, .sx = 1, .sy = 1, .sw = 2, .sh = 3 };
    try std.testing.expectError(error.OperationCanvasRequired, rendering.draw.addAffineSprite(client.instance, sprite));
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    client.instance.faults.inject(.sprite_metadata_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, rendering.draw.addAffineSprite(client.instance, sprite));
    try std.testing.expect(client.instance.draw_storage.owners[0].payloads == 0);
    try std.testing.expectEqual(@as(u16, 0), client.instance.draw_storage.owners[0].count);
    var invalid = sprite;
    invalid.sw = 0;
    invalid.sx = 5;
    try std.testing.expectError(error.InvalidSourceRectangle, rendering.draw.addAffineSprite(client.instance, invalid));
    invalid = sprite;
    invalid.affine = .{ .a = 0, .d = 0 };
    invalid.sh = 5;
    try std.testing.expectError(error.InvalidSourceRectangle, rendering.draw.addAffineSprite(client.instance, invalid));
    invalid = sprite;
    invalid.texture_id = 0;
    try std.testing.expectError(error.InvalidTextureId, rendering.draw.addAffineSprite(client.instance, invalid));
    invalid = sprite;
    invalid.layer_id = 255;
    try std.testing.expectError(error.InvalidLayerId, rendering.draw.addAffineSprite(client.instance, invalid));
    invalid = sprite;
    invalid.sw = 0;
    try rendering.draw.addAffineSprite(client.instance, invalid);
    invalid = sprite;
    invalid.affine = .{ .a = std.math.minInt(i32), .b = std.math.minInt(i32), .c = std.math.minInt(i32), .d = std.math.minInt(i32) };
    try rendering.draw.addAffineSprite(client.instance, invalid);
    try rendering.layers.compileDirtyRetainedLayers(client.instance);
    try std.testing.expectEqual(@as(u16, 2), client.instance.state.layers[0].slab_count);
    try std.testing.expectEqual(@as(u32, 0), client.instance.state.layers[0].cached_index_count);
    try std.testing.expectError(error.OperationCanvasRequired, rendering.layers.setCanvasMode(client.instance, 0, .legacy_rgba));
    for (2..client.instance.draw_storage.config.reserved) |_| try rendering.draw.addAffineSprite(client.instance, sprite);
    const before = client.instance.changes;
    try std.testing.expectError(error.LayerSlabFull, rendering.draw.addAffineSprite(client.instance, sprite));
    try std.testing.expectEqualDeep(before, client.instance.changes);
    try rendering.layers.clearLayerContents(client.instance, 0);
    try rendering.layers.setCanvasMode(client.instance, 0, .legacy_rgba);
    try rendering.layers.resetLayer(client.instance, 0);
    try std.testing.expect(client.instance.draw_storage.owners[0].payloads == 0);
    client.instance.state.frame_state = .idle;
    try std.testing.expectError(error.WrongFrameState, rendering.draw.addAffineSprite(client.instance, sprite));
}
