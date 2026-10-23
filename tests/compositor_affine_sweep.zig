const std = @import("std");
const rendering = @import("compositor");
const sdl = rendering.sdl;
const output_width = 32;
const output_height = 24;
const background = [4]u8{ 3, 5, 7, 255 };
const uniform_opaque = [4]u8{ 241, 83, 43, 255 };
const uniform_translucent = [4]u8{ 241, 83, 43, 128 };
const Image = [output_width * output_height][4]u8;
const Parameter = enum { a, b, c, d, tx, ty };
const Profile = struct { name: []const u8, matrix: rendering.types.Affine, parameter: Parameter, focal_x: usize, focal_y: usize };
const Inverse = struct { horizontal: i128, vertical: i128, denominator: i128 };

fn pattern(horizontal: usize, vertical: usize) [4]u8 {
    return .{ @intCast(16 + horizontal * 16), @intCast(24 + vertical * 20), @intCast(32 + ((horizontal * 7 + vertical * 11) % 13) * 16), 255 };
}

fn inverse(matrix: rendering.types.Affine, horizontal: usize, vertical: usize) Inverse {
    var denominator = @as(i128, matrix.a) * matrix.d - @as(i128, matrix.b) * matrix.c;
    const relative_x = @as(i128, @intCast(horizontal)) * 256 + 128 - matrix.tx;
    const relative_y = @as(i128, @intCast(vertical)) * 256 + 128 - matrix.ty;
    var source_x = (relative_x * matrix.d - relative_y * matrix.b) * 256;
    var source_y = (relative_y * matrix.a - relative_x * matrix.c) * 256;
    if (denominator < 0) {
        denominator = -denominator;
        source_x = -source_x;
        source_y = -source_y;
    }
    return .{ .horizontal = source_x, .vertical = source_y, .denominator = denominator };
}

fn same(actual: [4]u8, expected: [4]u8) bool {
    return std.mem.eql(u8, &actual, &expected);
}

fn blendMatch(actual: [4]u8, expected: [4]u8) bool {
    for (actual, expected, 0..) |got, want, channel| {
        if (@abs(@as(i16, got) - want) > (if (channel == 3) @as(i16, 0) else 3)) return false;
    }
    return true;
}

fn translucentResult(replays: usize) [4]u8 {
    var result = background;
    for (0..replays) |_| {
        for (0..3) |channel| {
            const premultiplied: u16 = (@as(u16, uniform_translucent[channel]) * 128 + 127) / 255;
            result[channel] = @intCast(premultiplied + (@as(u16, result[channel]) * 127 + 127) / 255);
        }
    }
    return result;
}

fn visibility(instance: *rendering.Instance, layer: u8, visible: bool) !void {
    instance.state.layer_prop_buffer[0] = .{ .layer_id = layer, .field = @intFromEnum(rendering.types.LayerPropField.visible), .value = @intFromBool(visible) };
    _ = try rendering.layers.submitLayerPropCommands(instance, 1);
}

fn capture(instance: *rendering.Instance, layer: u8, matrix: rendering.types.Affine, result: *Image) !void {
    instance.state.frame_state = .updating;
    for (0..3) |index| try visibility(instance, @intCast(index), index == layer);
    try rendering.layers.setAffine(instance, layer, matrix);
    if (!sdl.SDL_SetRenderTarget(instance.context.renderer, null) or !sdl.SDL_SetRenderDrawColor(instance.context.renderer, background[0], background[1], background[2], 255) or !sdl.SDL_RenderClear(instance.context.renderer)) return error.BackgroundFailed;
    try rendering.layers.compileDirtyRetainedLayers(instance);
    try rendering.compositor.executeCompositeFrame(instance);
    const surface = sdl.SDL_RenderReadPixels(instance.context.renderer, null) orelse return error.ReadbackFailed;
    defer sdl.SDL_DestroySurface(surface);
    if (surface.*.w != output_width or surface.*.h != output_height) return error.UnexpectedOutputSize;
    for (0..output_height) |vertical| for (0..output_width) |horizontal| {
        const pixel = &result[vertical * output_width + horizontal];
        if (!sdl.SDL_ReadSurfacePixel(surface, @intCast(horizontal), @intCast(vertical), &pixel[0], &pixel[1], &pixel[2], &pixel[3])) return error.PixelReadFailed;
    };
}

fn setup(instance: *rendering.Instance, width: usize, height: usize) !void {
    instance.state.frame_state = .updating;
    for (0..3) |layer| {
        instance.state.frame_state = .idle;
        const id = try rendering.textures.createOperationDynamicTexture(instance, @intCast(width), @intCast(height), .operation_only);
        instance.state.frame_state = .updating;
        try rendering.layers.setCanvasMode(instance, @intCast(layer), .normal);
        try rendering.layers.setCanvasExtent(instance, @intCast(layer), @intCast(width), @intCast(height));
        const pixels = try std.heap.c_allocator.alloc(u8, width * height * 4);
        defer std.heap.c_allocator.free(pixels);
        for (0..height) |vertical| for (0..width) |horizontal| {
            const color = if (layer == 0) pattern(horizontal, vertical) else if (layer == 1) uniform_opaque else uniform_translucent;
            @memcpy(pixels[(vertical * width + horizontal) * 4 ..][0..4], &color);
        };
        try rendering.textures.updateDynamicTexture(instance, id, 0, 0, @intCast(width), @intCast(height), pixels, @intCast(width * 4));
        try rendering.draw.addTexturedQuadTinted(instance, id, @intCast(layer), 0, 0, 0, @intCast(width), @intCast(height), 0, 0, @intCast(width), @intCast(height), false, false, 0, 0, 0, 255, 255, 255, 255);
    }
    var warmup: Image = undefined;
    for (0..3) |layer| {
        try capture(instance, @intCast(layer), .{}, &warmup);
        const target = instance.state.texture_table[instance.state.layers[layer].target_texture_id].?;
        var scale_mode: sdl.SDL_ScaleMode = undefined;
        if (!sdl.SDL_GetTextureScaleMode(target, &scale_mode) or scale_mode != sdl.SDL_SCALEMODE_NEAREST) return error.SamplerNotNearest;
        if (!sdl.SDL_SetRenderTarget(instance.context.renderer, target)) return error.TargetSelectFailed;
        const surface = sdl.SDL_RenderReadPixels(instance.context.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        for (0..height) |vertical| for (0..width) |horizontal| {
            var actual: [4]u8 = undefined;
            if (!sdl.SDL_ReadSurfacePixel(surface, @intCast(horizontal), @intCast(vertical), &actual[0], &actual[1], &actual[2], &actual[3])) return error.PixelReadFailed;
            var expected = if (layer == 0) pattern(horizontal, vertical) else if (layer == 1) uniform_opaque else uniform_translucent;
            for (expected[0..3]) |*channel| channel.* = @intCast((@as(u16, channel.*) * expected[3] + 127) / 255);
            if (!blendMatch(actual, expected) or actual[3] != expected[3]) return error.CanvasMismatch;
        };
        if (!sdl.SDL_SetRenderTarget(instance.context.renderer, null)) return error.TargetRestoreFailed;
    }
}

fn profiles(width: usize, height: usize) [25]Profile {
    const interior = rendering.types.Affine{ .b = 32768, .c = -16384, .d = 98304, .tx = 128, .ty = 256 };
    return .{
        .{ .name = "identity_tx", .matrix = .{ .tx = 128, .ty = 128 }, .parameter = .tx, .focal_x = 2, .focal_y = 2 },
        .{ .name = "identity_ty", .matrix = .{ .tx = 128, .ty = 128 }, .parameter = .ty, .focal_x = 2, .focal_y = 2 },
        .{ .name = "magnify_tx", .matrix = .{ .a = 131072, .d = 98304, .tx = 128, .ty = 128 }, .parameter = .tx, .focal_x = 4, .focal_y = 3 },
        .{ .name = "magnify_ty", .matrix = .{ .a = 131072, .d = 98304, .tx = 128, .ty = 128 }, .parameter = .ty, .focal_x = 4, .focal_y = 3 },
        .{ .name = "minify_tx", .matrix = .{ .a = 32768, .d = 49152, .tx = 128, .ty = 256 }, .parameter = .tx, .focal_x = 1, .focal_y = 2 },
        .{ .name = "minify_ty", .matrix = .{ .a = 32768, .d = 49152, .tx = 128, .ty = 256 }, .parameter = .ty, .focal_x = 1, .focal_y = 2 },
        .{ .name = "reflect_tx", .matrix = .{ .a = -65536, .tx = @intCast(width * 256 + 128), .ty = 128 }, .parameter = .tx, .focal_x = width - 2, .focal_y = 2 },
        .{ .name = "reflect_ty", .matrix = .{ .d = -65536, .tx = 128, .ty = @intCast(height * 256 + 128) }, .parameter = .ty, .focal_x = 2, .focal_y = height - 2 },
        .{ .name = "interior_shear_a", .matrix = interior, .parameter = .a, .focal_x = 3, .focal_y = 3 },
        .{ .name = "interior_shear_b", .matrix = interior, .parameter = .b, .focal_x = 3, .focal_y = 3 },
        .{ .name = "interior_shear_c", .matrix = interior, .parameter = .c, .focal_x = 3, .focal_y = 3 },
        .{ .name = "interior_shear_d", .matrix = interior, .parameter = .d, .focal_x = 3, .focal_y = 3 },
        .{ .name = "known_edge_b", .matrix = .{ .b = 32768, .c = -16384, .d = 98304, .tx = 512, .ty = 256 }, .parameter = .b, .focal_x = 2, .focal_y = 2 },
        .{ .name = "magnify64_tx", .matrix = .{ .a = 4194304, .d = 4194304, .tx = -32640, .ty = -32640 }, .parameter = .tx, .focal_x = 0, .focal_y = 0 },
        .{ .name = "magnify64_ty", .matrix = .{ .a = 4194304, .d = 4194304, .tx = -32640, .ty = -32640 }, .parameter = .ty, .focal_x = 0, .focal_y = 0 },
        .{ .name = "minify_quarter_tx", .matrix = .{ .a = 16384, .d = 32768, .ty = -128 }, .parameter = .tx, .focal_x = 0, .focal_y = 0 },
        .{ .name = "minify_quarter_ty", .matrix = .{ .a = 16384, .d = 32768, .ty = -128 }, .parameter = .ty, .focal_x = 0, .focal_y = 0 },
        .{ .name = "magnify_a", .matrix = .{ .a = 131072, .d = 98304, .tx = 128, .ty = 128 }, .parameter = .a, .focal_x = 4, .focal_y = 3 },
        .{ .name = "magnify_d", .matrix = .{ .a = 131072, .d = 98304, .tx = 128, .ty = 128 }, .parameter = .d, .focal_x = 4, .focal_y = 3 },
        .{ .name = "minify_a", .matrix = .{ .a = 32768, .d = 49152, .tx = 128, .ty = 256 }, .parameter = .a, .focal_x = 1, .focal_y = 2 },
        .{ .name = "minify_d", .matrix = .{ .a = 32768, .d = 49152, .tx = 128, .ty = 256 }, .parameter = .d, .focal_x = 1, .focal_y = 2 },
        .{ .name = "reflected_shear_a", .matrix = .{ .a = -65536, .b = 32768, .c = -16384, .d = 98304, .tx = 1152, .ty = 256 }, .parameter = .a, .focal_x = 3, .focal_y = 3 },
        .{ .name = "reflected_shear_b", .matrix = .{ .a = -65536, .b = 32768, .c = -16384, .d = 98304, .tx = 1152, .ty = 256 }, .parameter = .b, .focal_x = 3, .focal_y = 3 },
        .{ .name = "reflected_shear_c", .matrix = .{ .a = -65536, .b = 32768, .c = -16384, .d = 98304, .tx = 1152, .ty = 256 }, .parameter = .c, .focal_x = 3, .focal_y = 3 },
        .{ .name = "reflected_shear_d", .matrix = .{ .a = -65536, .b = 32768, .c = -16384, .d = 98304, .tx = 1152, .ty = 256 }, .parameter = .d, .focal_x = 3, .focal_y = 3 },
    };
}

fn offsets() [145]i32 {
    var result: [145]i32 = undefined;
    const tails = [_]i32{ 96, 128, 192, 256, 384, 512, 768, 1024 };
    for (0..8) |index| result[index] = -tails[7 - index];
    for (0..129) |index| result[index + 8] = @as(i32, @intCast(index)) - 64;
    for (tails, 0..) |value, index| result[index + 137] = value;
    return result;
}

fn selected(pixel: [4]u8, width: usize, height: usize) [2]i128 {
    if (same(pixel, background)) return .{ -1, -1 };
    if (pixel[3] != 255 or pixel[0] < 16 or pixel[1] < 24 or (pixel[0] - 16) % 16 != 0 or (pixel[1] - 24) % 20 != 0) return .{ -2, -2 };
    const horizontal: usize = (pixel[0] - 16) / 16;
    const vertical: usize = (pixel[1] - 24) / 20;
    if (horizontal >= width or vertical >= height or !same(pixel, pattern(horizontal, vertical))) return .{ -2, -2 };
    return .{ @intCast(horizontal), @intCast(vertical) };
}

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.VideoUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("Bounded affine sampling characterization", output_width, output_height, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    const renderer_name = std.mem.span(sdl.SDL_GetRendererName(renderer));
    if (!std.mem.eql(u8, renderer_name, "metal")) {
        std.debug.print("SWEEP_UNSUPPORTED renderer={s} no operation pixel characterization\n", .{renderer_name});
        return;
    }
    const sizes = [_][2]usize{ .{ 4, 3 }, .{ 7, 5 }, .{ 11, 6 }, .{ 6, 9 } };
    var total_cases: usize = 0;
    var total_adjacent: usize = 0;
    var total_coverage: usize = 0;
    var total_hard: usize = 0;
    var patterned: Image = undefined;
    var opaque_image: Image = undefined;
    var translucent: Image = undefined;
    std.debug.print("SWEEP_META renderer={s} output=32x24 profiles=25 offsets=145 sizes=4 production_path=direct_SDL_geometry measurement_only=true\n", .{renderer_name});
    for (sizes) |size| {
        const width = size[0];
        const height = size[1];
        const instance = try std.heap.c_allocator.create(rendering.Instance);
        defer std.heap.c_allocator.destroy(instance);
        try instance.init(std.heap.c_allocator, .{ .renderer = renderer, .logical_width = output_width, .logical_height = output_height, .opaque_presentation = true });
        defer instance.deinit();
        try setup(instance, width, height);
        for (profiles(width, height)) |profile| for (offsets()) |delta| {
            var matrix = profile.matrix;
            switch (profile.parameter) {
                inline else => |parameter| @field(matrix, @tagName(parameter)) += delta,
            }
            try capture(instance, 0, matrix, &patterned);
            try capture(instance, 1, matrix, &opaque_image);
            try capture(instance, 2, matrix, &translucent);
            var adjacent_count: usize = 0;
            var coverage_count: usize = 0;
            var hard_count: usize = 0;
            var permitted_count: usize = 0;
            var focal_kind: []const u8 = "unobserved";
            var focal_selected: [2]i128 = .{ -2, -2 };
            for (0..output_height) |vertical| for (0..output_width) |horizontal| {
                const pixel_index = vertical * output_width + horizontal;
                const position = inverse(matrix, horizontal, vertical);
                const denominator = position.denominator;
                if (denominator == 0) return error.UnexpectedSingularProfile;
                const numerator_x = position.horizontal;
                const numerator_y = position.vertical;
                const inside = numerator_x >= 0 and numerator_x < @as(i128, @intCast(width)) * denominator and numerator_y >= 0 and numerator_y < @as(i128, @intCast(height)) * denominator;
                const closed_inside = numerator_x >= 0 and numerator_x <= @as(i128, @intCast(width)) * denominator and numerator_y >= 0 and numerator_y <= @as(i128, @intCast(height)) * denominator;
                const outside_edge = closed_inside and (numerator_x == 0 or numerator_x == @as(i128, @intCast(width)) * denominator or numerator_y == 0 or numerator_y == @as(i128, @intCast(height)) * denominator);
                const expected_x = @divFloor(numerator_x, denominator);
                const expected_y = @divFloor(numerator_y, denominator);
                const actual = patterned[pixel_index];
                const chosen = selected(actual, width, height);
                const covered = same(opaque_image[pixel_index], uniform_opaque);
                const uncovered = same(opaque_image[pixel_index], background);
                const seam = inside and numerator_x * @as(i128, @intCast(height)) == numerator_y * @as(i128, @intCast(width));
                const expected = if (inside) pattern(@intCast(expected_x), @intCast(expected_y)) else background;
                var kind: []const u8 = "correct";
                if (!covered and !uncovered) {
                    kind = "opaque_colour_error";
                } else if (!blendMatch(translucent[pixel_index], if (covered) translucentResult(1) else background)) {
                    kind = if (blendMatch(translucent[pixel_index], translucentResult(2))) "double_blend" else "blend_or_coverage_error";
                } else if (chosen[0] == -2) {
                    kind = "arbitrary_colour";
                } else if (covered != (chosen[0] >= 0)) {
                    kind = "pattern_coverage_error";
                } else if (covered and outside_edge and !((chosen[0] == expected_x or (@mod(numerator_x, denominator) == 0 and chosen[0] == expected_x - 1)) and (chosen[1] == expected_y or (@mod(numerator_y, denominator) == 0 and chosen[1] == expected_y - 1)))) {
                    kind = if (@abs(chosen[0] - expected_x) <= 1 and @abs(chosen[1] - expected_y) <= 1) "adjacent_sampling" else "nonadjacent_sampling";
                } else if (covered != inside) {
                    kind = if (outside_edge) "permitted_coverage_edge" else if (covered) "coverage_excess" else if (seam) "internal_hole" else "coverage_missing";
                } else if (!same(actual, expected)) {
                    if (chosen[0] == -2) {
                        kind = "arbitrary_colour";
                    } else if (chosen[0] == -1) {
                        kind = "pattern_hole";
                    } else {
                        const difference_x = chosen[0] - expected_x;
                        const difference_y = chosen[1] - expected_y;
                        const tie_x = @mod(numerator_x, denominator) == 0;
                        const tie_y = @mod(numerator_y, denominator) == 0;
                        const permitted_x = difference_x == 0 or (tie_x and difference_x == -1);
                        const permitted_y = difference_y == 0 or (tie_y and difference_y == -1);
                        kind = if (permitted_x and permitted_y) "permitted_texel_tie" else if (@abs(difference_x) <= 1 and @abs(difference_y) <= 1) "adjacent_sampling" else "nonadjacent_sampling";
                    }
                }
                const adjacent = std.mem.eql(u8, kind, "adjacent_sampling");
                const coverage = std.mem.startsWith(u8, kind, "coverage_");
                const permitted = std.mem.startsWith(u8, kind, "permitted_");
                const correct = std.mem.eql(u8, kind, "correct");
                const hard = !adjacent and !coverage and !permitted and !correct;
                if (adjacent) adjacent_count += 1;
                if (coverage) coverage_count += 1;
                if (hard) hard_count += 1;
                if (permitted) permitted_count += 1;
                if (horizontal == profile.focal_x and vertical == profile.focal_y) {
                    focal_kind = kind;
                    focal_selected = chosen;
                }
                if (!correct and !permitted) {
                    const crossed_x = if (chosen[0] > expected_x) expected_x + 1 else expected_x;
                    const crossed_y = if (chosen[1] > expected_y) expected_y + 1 else expected_y;
                    const distance_x = if (chosen[0] >= 0 and chosen[0] != expected_x) @abs(numerator_x - crossed_x * denominator) else 0;
                    const distance_y = if (chosen[1] >= 0 and chosen[1] != expected_y) @abs(numerator_y - crossed_y * denominator) else 0;
                    std.debug.print("SWEEPPIX\t{s}\t{d}\t{d}\t{d}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}", .{ profile.name, width, height, delta, @tagName(profile.parameter), horizontal, vertical, kind, matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty, numerator_x, numerator_y, denominator, expected_x, expected_y, chosen[0], chosen[1], crossed_x, crossed_y, distance_x, distance_y });
                    std.debug.print("\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ actual[0], actual[1], actual[2], actual[3], expected[0], expected[1], expected[2], expected[3] });
                }
            };
            const focal = inverse(matrix, profile.focal_x, profile.focal_y);
            std.debug.print("SWEEPCASE\t{s}\t{d}\t{d}\t{d}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ profile.name, width, height, delta, @tagName(profile.parameter), profile.focal_x, profile.focal_y, focal_kind, focal.horizontal, focal.vertical, focal.denominator, @divFloor(focal.horizontal, focal.denominator), @divFloor(focal.vertical, focal.denominator), focal_selected[0], focal_selected[1], adjacent_count, coverage_count, hard_count, permitted_count, matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty, instance.source_stats.readbacks });
            total_cases += 1;
            total_adjacent += adjacent_count;
            total_coverage += coverage_count;
            total_hard += hard_count;
        };
    }
    std.debug.print("SWEEP_TOTAL cases={d} adjacent={d} coverage={d} hard={d} qualification=false\n", .{ total_cases, total_adjacent, total_coverage, total_hard });
}
