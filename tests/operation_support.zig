pub const std = @import("std");
pub const rendering = @import("compositor");
pub const sdl = rendering.sdl;
pub const Mode = rendering.types.CanvasMode;
pub const families = [_]Mode{ .normal, .additive, .multiply };
pub const background = [4]u8{ 80, 120, 160, 255 };

pub fn copySourcePixel(fixture: *Fixture, texture_id: u16, horizontal: c_int, vertical: c_int) ![4]u8 {
    const texture = (try rendering.operation.source(fixture.instance, texture_id)).?;
    try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_NONE));
    try std.testing.expect(sdl.SDL_SetTextureColorMod(texture, 255, 255, 255));
    try std.testing.expect(sdl.SDL_SetTextureAlphaMod(texture, 255));
    try std.testing.expect(sdl.SDL_RenderTexture(fixture.renderer, texture, null, null));
    return fixture.pixel(horizontal, vertical);
}

pub const Fixture = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    instance: *rendering.Instance,
    supported: bool,

    pub fn init() !Fixture {
        try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
        errdefer sdl.SDL_Quit();
        const window = sdl.SDL_CreateWindow("Operation canvas checks", 8, 8, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
        errdefer sdl.SDL_DestroyWindow(window);
        const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
        errdefer sdl.SDL_DestroyRenderer(renderer);
        const instance = try std.testing.allocator.create(rendering.Instance);
        try instance.init(std.testing.allocator, .{ .renderer = renderer, .logical_width = 8, .logical_height = 8, .opaque_presentation = true });
        const supported = !std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(renderer)), "software");
        std.debug.print("operation-check: renderer={s} path={s}\n", .{ sdl.SDL_GetRendererName(renderer), if (supported) "SDL geometry operation accumulation/presentation (no CPU raster fallback)" else "UNSUPPORTED operation blends; checking rejection only" });
        return .{ .window = window, .renderer = renderer, .instance = instance, .supported = supported };
    }

    pub fn deinit(self: *Fixture) void {
        self.instance.deinit();
        std.testing.allocator.destroy(self.instance);
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }

    pub fn begin(self: *Fixture) !void {
        self.instance.state.frame_state = .updating;
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(self.renderer, background[0], background[1], background[2], 255));
        try std.testing.expect(sdl.SDL_RenderClear(self.renderer));
    }

    pub fn execute(self: *Fixture) !void {
        try rendering.layers.compileDirtyRetainedLayers(self.instance);
        try rendering.compositor.executeCompositeFrame(self.instance);
    }

    pub fn property(self: *Fixture, field: rendering.types.LayerPropField, value: i32) !void {
        self.instance.state.layer_prop_buffer[0] = .{ .layer_id = 0, .field = @intFromEnum(field), .value = value };
        _ = try rendering.layers.submitLayerPropCommands(self.instance, 1);
    }

    pub fn rect(self: *Fixture, color: [4]u8, horizontal: c_int, vertical: c_int, width: c_int, height: c_int) !void {
        try rendering.draw.addSolidRectToLayer(self.instance, 0, 0, horizontal, vertical, width, height, color[0], color[1], color[2], color[3]);
    }

    pub fn texture(self: *Fixture, color: [4]u8) !u16 {
        self.instance.state.frame_state = .idle;
        const texture_id = try rendering.textures.createOperationDynamicTexture(self.instance, 1, 1, .shared);
        try rendering.textures.updateDynamicTexture(self.instance, texture_id, 0, 0, 1, 1, &color, 4);
        self.instance.state.frame_state = .updating;
        return texture_id;
    }

    pub fn textured(self: *Fixture, texture_id: u16, tint: [4]u8, horizontal: c_int, vertical: c_int, width: c_int, height: c_int) !void {
        try rendering.draw.addTexturedQuadTinted(self.instance, texture_id, 0, 0, 0, 0, 1, 1, horizontal, vertical, width, height, false, false, 0, 0, 0, tint[0], tint[1], tint[2], tint[3]);
    }

    pub fn pixel(self: *Fixture, horizontal: c_int, vertical: c_int) ![4]u8 {
        const surface = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        var actual: [4]u8 = undefined;
        try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, horizontal, vertical, &actual[0], &actual[1], &actual[2], &actual[3]));
        return actual;
    }

    pub fn canvas(self: *Fixture) ![4]u8 {
        const target = self.instance.state.texture_table[self.instance.state.layers[0].target_texture_id].?;
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, target));
        defer _ = sdl.SDL_SetRenderTarget(self.renderer, null);
        return self.pixel(2, 2);
    }

    pub fn unsupported(self: *Fixture) !bool {
        if (self.supported) return false;
        for (families) |family| {
            try self.begin();
            try rendering.layers.setCanvasMode(self.instance, 0, family);
            try std.testing.expectError(error.UnsupportedCanvasBackend, self.execute());
            try std.testing.expect(self.instance.state.layers[0].target_dirty);
            try std.testing.expect(!self.instance.frame_ready);
            try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(self.instance));
        }
        return true;
    }
};

pub fn near(expected: [4]u8, actual: [4]u8) !void {
    for (expected, actual, 0..) |want, got, channel| try std.testing.expect(@abs(@as(i16, want) - got) <= (if (channel == 3) @as(i16, 0) else 3));
}

pub fn affinePattern(horizontal: usize, vertical: usize) [4]u8 {
    return .{ @intCast(20 + horizontal * 60), @intCast(20 + vertical * 80), @intCast(20 + ((horizontal + vertical) % 2) * 160), 255 };
}

pub fn affineExpected(affine: rendering.types.Affine, family: Mode, horizontal: usize, vertical: usize) [4]u8 {
    const determinant = @as(i128, affine.a) * affine.d - @as(i128, affine.b) * affine.c;
    if (determinant == 0) return background;
    const relative_x = (@as(f64, @floatFromInt(horizontal)) + 0.5) * 256 - @as(f64, @floatFromInt(affine.tx));
    const relative_y = (@as(f64, @floatFromInt(vertical)) + 0.5) * 256 - @as(f64, @floatFromInt(affine.ty));
    const source_x = (relative_x * @as(f64, @floatFromInt(affine.d)) - relative_y * @as(f64, @floatFromInt(affine.b))) * 256 / @as(f64, @floatFromInt(determinant));
    const source_y = (relative_y * @as(f64, @floatFromInt(affine.a)) - relative_x * @as(f64, @floatFromInt(affine.c))) * 256 / @as(f64, @floatFromInt(determinant));
    if (source_x < 0 or source_y < 0 or source_x >= 4 or source_y >= 3) return background;
    const color = affinePattern(@intFromFloat(@floor(source_x)), @intFromFloat(@floor(source_y)));
    return reference(family, &.{color}, 255, .{ 255, 255, 255 });
}

pub const AffinePresentation = struct {
    family: Mode = .normal,
    opacity: u8 = 255,
    tint: [3]u8 = .{ 255, 255, 255 },
    uniform: ?[4]u8 = null,
    width: i32 = 4,
    height: i32 = 3,
    alpha: u8 = 255,
};

pub const AffineOutcomes = struct {
    reference_pixel: [4]u8 = background,
    allowed: [5][4]u8 = undefined,
    count: usize = 0,
    coverage_boundary: bool = false,
    texel_boundary: bool = false,

    pub fn matches(self: AffineOutcomes, actual: [4]u8) bool {
        for (self.allowed[0..self.count]) |expected| {
            var accepted = true;
            for (expected, actual, 0..) |want, got, channel| {
                if (@abs(@as(i16, want) - got) > (if (channel == 3) @as(i16, 0) else 3)) accepted = false;
            }
            if (accepted) return true;
        }
        return false;
    }
};

pub fn affineSample(presentation: AffinePresentation, horizontal: i128, vertical: i128) [4]u8 {
    if (horizontal < 0 or horizontal >= presentation.width or vertical < 0 or vertical >= presentation.height) return reference(presentation.family, &.{}, presentation.opacity, presentation.tint);
    if (presentation.uniform == null and (horizontal >= 4 or vertical >= 3)) return reference(presentation.family, &.{}, presentation.opacity, presentation.tint);
    var color = presentation.uniform orelse affinePattern(@intCast(horizontal), @intCast(vertical));
    if (presentation.uniform == null) color[3] = presentation.alpha;
    return reference(presentation.family, &.{color}, presentation.opacity, presentation.tint);
}

pub fn affineCoveragePermitted(affine: rendering.types.Affine, width: i32, height: i32, horizontal: usize, vertical: usize) bool {
    const point = [2]i256{ @as(i256, @intCast(horizontal)) * 65536 + 32768, @as(i256, @intCast(vertical)) * 65536 + 32768 };
    const coordinates = [4][2]i256{ .{ 0, 0 }, .{ width, 0 }, .{ width, height }, .{ 0, height } };
    var corners: [4][2]i256 = undefined;
    for (coordinates, 0..) |coordinate, index| {
        corners[index] = .{ @as(i256, affine.a) * coordinate[0] + @as(i256, affine.b) * coordinate[1] + @as(i256, affine.tx) * 256, @as(i256, affine.c) * coordinate[0] + @as(i256, affine.d) * coordinate[1] + @as(i256, affine.ty) * 256 };
    }
    for (corners, 0..) |start, index| {
        const end = corners[(index + 1) % 4];
        const direction = [2]i256{ end[0] - start[0], end[1] - start[1] };
        const relative = [2]i256{ point[0] - start[0], point[1] - start[1] };
        const length_squared = direction[0] * direction[0] + direction[1] * direction[1];
        const projection = relative[0] * direction[0] + relative[1] * direction[1];
        if (projection <= 0 or length_squared == 0) {
            if (relative[0] * relative[0] + relative[1] * relative[1] <= 65536) return true;
        } else if (projection >= length_squared) {
            const end_relative = [2]i256{ point[0] - end[0], point[1] - end[1] };
            if (end_relative[0] * end_relative[0] + end_relative[1] * end_relative[1] <= 65536) return true;
        } else {
            const cross = relative[0] * direction[1] - relative[1] * direction[0];
            if (cross * cross <= 65536 * length_squared) return true;
        }
    }
    return false;
}

pub fn affineAxisChoices(numerator: i128, denominator: i128) struct { indices: [2]i128, count: usize } {
    const index = @divFloor(numerator, denominator);
    const remainder = @mod(numerator, denominator);
    if (remainder * 256 <= denominator) return .{ .indices = .{ index, index - 1 }, .count = 2 };
    if ((denominator - remainder) * 256 <= denominator) return .{ .indices = .{ index, index + 1 }, .count = 2 };
    return .{ .indices = .{ index, index }, .count = 1 };
}

pub fn affineOutcomes(affine: rendering.types.Affine, presentation: AffinePresentation, horizontal: usize, vertical: usize) AffineOutcomes {
    var result: AffineOutcomes = .{};
    var denominator = @as(i128, affine.a) * affine.d - @as(i128, affine.b) * affine.c;
    if (denominator == 0) {
        result.allowed[0] = background;
        result.count = 1;
        return result;
    }
    const relative_x = @as(i128, @intCast(horizontal)) * 256 + 128 - affine.tx;
    const relative_y = @as(i128, @intCast(vertical)) * 256 + 128 - affine.ty;
    var numerator_x = (relative_x * affine.d - relative_y * affine.b) * 256;
    var numerator_y = (relative_y * affine.a - relative_x * affine.c) * 256;
    if (denominator < 0) {
        denominator = -denominator;
        numerator_x = -numerator_x;
        numerator_y = -numerator_y;
    }
    const inside = numerator_x >= 0 and numerator_x < denominator * presentation.width and numerator_y >= 0 and numerator_y < denominator * presentation.height;
    const internal_seam = inside and numerator_x > 0 and numerator_y > 0 and numerator_x * presentation.height == numerator_y * presentation.width;
    result.coverage_boundary = !internal_seam and affineCoveragePermitted(affine, presentation.width, presentation.height, horizontal, vertical);
    if (!inside and !result.coverage_boundary) {
        result.allowed[0] = background;
        result.count = 1;
        return result;
    }
    const horizontal_choices = affineAxisChoices(numerator_x, denominator);
    const vertical_choices = affineAxisChoices(numerator_y, denominator);
    result.texel_boundary = horizontal_choices.count > 1 or vertical_choices.count > 1;
    const source_x = @divFloor(numerator_x, denominator);
    const source_y = @divFloor(numerator_y, denominator);
    if (inside) result.reference_pixel = affineSample(presentation, source_x, source_y);
    if (result.coverage_boundary) {
        result.allowed[result.count] = background;
        result.count += 1;
    }
    for (horizontal_choices.indices[0..horizontal_choices.count]) |horizontal_choice| {
        for (vertical_choices.indices[0..vertical_choices.count]) |vertical_choice| {
            result.allowed[result.count] = affineSample(presentation, horizontal_choice, vertical_choice);
            result.count += 1;
        }
    }
    return result;
}

pub fn byte(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

pub fn reference(family: Mode, colors: []const [4]u8, opacity: u8, tint: [3]u8) [4]u8 {
    var operation: [4]f64 = if (family == .multiply) .{ 1, 1, 1, 1 } else .{ 0, 0, 0, 0 };
    for (colors) |color| {
        const alpha = @as(f64, @floatFromInt(color[3])) / 255;
        for (0..3) |channel| {
            const source = @as(f64, @floatFromInt(color[channel])) / 255 * alpha;
            const accumulated = switch (family) {
                .normal => source + (1 - alpha) * operation[channel],
                .additive => @min(1, operation[channel] + source),
                .multiply => operation[channel] * (1 - alpha + source),
                .legacy_rgba => unreachable,
            };
            operation[channel] = @as(f64, @floatFromInt(byte(accumulated))) / 255;
        }
        operation[3] = if (family == .normal) @as(f64, @floatFromInt(byte(alpha + (1 - alpha) * operation[3]))) / 255 else if (family == .multiply) 1 else 0;
    }
    const lambda = @as(f64, @floatFromInt(opacity)) / 255;
    var result: [4]u8 = .{ 0, 0, 0, 255 };
    for (0..3) |channel| {
        const destination = @as(f64, @floatFromInt(background[channel])) / 255;
        const modulation = @as(f64, @floatFromInt(tint[channel])) / 255;
        result[channel] = byte(switch (family) {
            .normal => lambda * modulation * operation[channel] + (1 - lambda * operation[3]) * destination,
            .additive => @min(1, destination + lambda * modulation * operation[channel]),
            .multiply => destination * (1 - lambda + lambda * modulation * operation[channel]),
            .legacy_rgba => unreachable,
        });
    }
    return result;
}

pub fn mumTriangleQuad(fixture: *Fixture, texture_id: u16, x: i32, y: i32, extent: i32, uv_first: i32, uv_last: i32, left: [4]u8, right: [4]u8) !void {
    const corners = [_]rendering.types.TriangleVertex{
        .{ .x = x * 256, .y = y * 256, .u = uv_first, .v = uv_first, .color = left },
        .{ .x = (x + extent) * 256, .y = y * 256, .u = uv_last, .v = uv_first, .color = right },
        .{ .x = (x + extent) * 256, .y = (y + extent) * 256, .u = uv_last, .v = uv_last, .color = right },
        .{ .x = x * 256, .y = (y + extent) * 256, .u = uv_first, .v = uv_last, .color = left },
    };
    for ([_][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }) |indices| try rendering.draw.addTexturedTriangle(fixture.instance, .{ .texture_id = texture_id, .layer_id = 0, .vertices = .{ corners[indices[0]], corners[indices[1]], corners[indices[2]] } });
}
