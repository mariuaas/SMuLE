const std = @import("std");
const rendering = @import("compositor");
const sdl = rendering.sdl;
const Mode = rendering.types.CanvasMode;
const families = [_]Mode{ .normal, .additive, .multiply };
const colors = [_][4]u8{ .{ 230, 25, 80, 64 }, .{ 20, 220, 60, 160 }, .{ 75, 100, 240, 224 } };
const positions = [_][2]i32{ .{ 256, 256 }, .{ 3328, 512 }, .{ 512, 3584 } };
const coordinates = [_][2]i32{ .{ 64, 96 }, .{ 672, 192 }, .{ -96, 1088 } };

fn premultiplied(pixel: [4]u8) [4]f64 {
    var result: [4]f64 = undefined;
    for (0..3) |channel| result[channel] = @as(f64, @floatFromInt((@as(u32, pixel[channel]) * pixel[3] + 127) / 255)) / 255;
    result[3] = @as(f64, @floatFromInt(pixel[3])) / 255;
    return result;
}

fn edge(first: [2]i32, second: [2]i32, point: [2]i32) i128 {
    return (@as(i128, second[0]) - first[0]) * (@as(i128, point[1]) - first[1]) - (@as(i128, second[1]) - first[1]) * (@as(i128, point[0]) - first[0]);
}

fn weights(horizontal: usize, vertical: usize) [3]i128 {
    const point = [2]i32{ @as(i32, @intCast(horizontal)) * 256 + 128, @as(i32, @intCast(vertical)) * 256 + 128 };
    return .{ edge(positions[1], positions[2], point), edge(positions[2], positions[0], point), edge(positions[0], positions[1], point) };
}

fn sourceTap(pixels: []const [4]u8, width: usize, height: usize, horizontal: i64, vertical: i64, repeat: bool) [4]f64 {
    const column: usize = @intCast(if (repeat) @mod(horizontal, @as(i64, @intCast(width))) else std.math.clamp(horizontal, 0, @as(i64, @intCast(width)) - 1));
    const row: usize = @intCast(if (repeat) @mod(vertical, @as(i64, @intCast(height))) else std.math.clamp(vertical, 0, @as(i64, @intCast(height)) - 1));
    return premultiplied(pixels[row * width + column]);
}

fn sample(pixels: []const [4]u8, width: usize, height: usize, horizontal: f64, vertical: f64, linear: bool, repeat: bool) [4]f64 {
    if (!linear) return sourceTap(pixels, width, height, @intFromFloat(@floor(horizontal)), @intFromFloat(@floor(vertical)), repeat);
    const left = @floor(horizontal - 0.5);
    const top = @floor(vertical - 0.5);
    const fraction_x = horizontal - 0.5 - left;
    const fraction_y = vertical - 0.5 - top;
    var result: [4]f64 = @splat(0);
    for (0..2) |row| for (0..2) |column| {
        const weight = (if (column == 0) 1 - fraction_x else fraction_x) * (if (row == 0) 1 - fraction_y else fraction_y);
        const tap = sourceTap(pixels, width, height, @as(i64, @intFromFloat(left)) + @as(i64, @intCast(column)), @as(i64, @intFromFloat(top)) + @as(i64, @intCast(row)), repeat);
        for (&result, tap) |*value, source| value.* += weight * source;
    };
    return result;
}

fn expected(barycentric: [3]i128, pixels: []const [4]u8, width: usize, height: usize, linear: bool, repeat: bool, family: Mode) [4]u8 {
    const area = edge(positions[0], positions[1], positions[2]);
    var modulation: [4]f64 = @splat(0);
    var source_uv: [2]f64 = @splat(0);
    for (barycentric, colors, coordinates) |numerator, color, uv| {
        const weight = @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(area));
        const premultiplied_color = premultiplied(color);
        for (&modulation, premultiplied_color) |*value, channel| value.* += weight * channel;
        for (&source_uv, uv) |*value, coordinate| value.* += weight * @as(f64, @floatFromInt(coordinate)) / 256;
    }
    const sampled = sample(pixels, width, height, source_uv[0], source_uv[1], linear, repeat);
    var fragment: [4]f64 = undefined;
    for (&fragment, sampled, modulation) |*value, texture, vertex| value.* = texture * vertex;
    var result: [4]u8 = undefined;
    for (0..3) |channel| result[channel] = @intFromFloat(@round(255 * (if (family == .multiply) 1 - fragment[3] + fragment[channel] else fragment[channel])));
    result[3] = if (family == .normal) @intFromFloat(@round(255 * fragment[3])) else if (family == .multiply) 255 else 0;
    return result;
}

fn matches(actual: [4]u8, wanted: [4]u8) bool {
    return matchesAlpha(actual, wanted, 0);
}

fn matchesAlpha(actual: [4]u8, wanted: [4]u8, alpha_tolerance: u8) bool {
    for (actual, wanted, 0..) |got, want, channel| if (@abs(@as(i16, got) - want) > (if (channel == 3) @as(i16, alpha_tolerance) else 3)) return false;
    return true;
}

fn observeFragment(renderer: *sdl.SDL_Renderer, texture: *sdl.SDL_Texture, vertices: [3]sdl.SDL_Vertex) !void {
    const previous = sdl.SDL_GetRenderTarget(renderer);
    defer _ = sdl.SDL_SetRenderTarget(renderer, previous);
    var blend: sdl.SDL_BlendMode = undefined;
    try std.testing.expect(sdl.SDL_GetTextureBlendMode(texture, &blend));
    defer _ = sdl.SDL_SetTextureBlendMode(texture, blend);
    try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_NONE));
    const target = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA64_FLOAT, sdl.SDL_TEXTUREACCESS_TARGET, 16, 16) orelse return error.FloatDiagnosticUnavailable;
    defer sdl.SDL_DestroyTexture(target);
    for ([_]bool{ false, true }) |neutral| {
        try std.testing.expect(sdl.SDL_SetRenderTarget(renderer, target));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0));
        try std.testing.expect(sdl.SDL_RenderClear(renderer));
        var submitted = vertices;
        if (neutral) for (&submitted) |*vertex| {
            vertex.color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
        };
        try std.testing.expect(sdl.SDL_RenderGeometry(renderer, texture, &submitted, 3, &[_]c_int{ 0, 1, 2 }, 3));
        const surface = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        var actual: [4]f32 = undefined;
        try std.testing.expect(sdl.SDL_ReadSurfacePixelFloat(surface, 5, 3, &actual[0], &actual[1], &actual[2], &actual[3]));
        std.debug.print("TRIANGLE_GATE_FLOAT neutral_vertex={} pixel=5,3 rgba={any} alpha_in_byte_units={d:.9}\n", .{ neutral, actual, actual[3] * 255 });
    }
}

test "native SDL textured triangles interpolate premultiplied vertex colours before texture modulation" {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.VideoUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("Triangle interpolation gate", 16, 16, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    const renderer_name = std.mem.span(sdl.SDL_GetRendererName(renderer));
    if (std.mem.eql(u8, renderer_name, "software")) {
        std.debug.print("TRIANGLE_GATE software operation pixels unsupported; probe skipped\n", .{});
        return;
    }
    const target = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_TARGET, 16, 16) orelse return error.TextureUnavailable;
    defer sdl.SDL_DestroyTexture(target);
    var pattern: [15][4]u8 = undefined;
    for (&pattern, 0..) |*pixel, index| pixel.* = .{ @intCast(25 + (index % 3) * 100), @intCast(20 + (index / 3) * 50), if (index % 4 == 0) 255 else 80, switch (index % 4) {
        0 => 0,
        1 => 96,
        2 => 192,
        else => 255,
    } };
    const white = [_][4]u8{.{ 255, 255, 255, 255 }};
    var checked: usize = 0;
    var mismatches: usize = 0;
    var violations: usize = 0;
    for ([_]bool{ false, true }) |patterned| for (families) |family| for ([_]bool{ false, true }) |linear| for ([_]bool{ false, true }) |repeat| {
        if (!patterned and repeat) continue;
        const pixels: []const [4]u8 = if (patterned) &pattern else &white;
        const width: usize = if (patterned) 3 else 1;
        const height: usize = if (patterned) 5 else 1;
        var upload: [15][4]u8 = undefined;
        for (pixels, upload[0..pixels.len]) |pixel, *output| {
            for (0..3) |channel| output[channel] = @intCast((@as(u32, pixel[channel]) * pixel[3] + 127) / 255);
            output[3] = pixel[3];
        }
        const texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, @intCast(width), @intCast(height)) orelse return error.TextureUnavailable;
        defer sdl.SDL_DestroyTexture(texture);
        try std.testing.expect(sdl.SDL_UpdateTexture(texture, null, &upload, @intCast(width * 4)));
        try std.testing.expect(sdl.SDL_SetTextureScaleMode(texture, if (linear) sdl.SDL_SCALEMODE_LINEAR else sdl.SDL_SCALEMODE_NEAREST));
        const address = if (repeat) sdl.SDL_TEXTURE_ADDRESS_WRAP else sdl.SDL_TEXTURE_ADDRESS_CLAMP;
        try std.testing.expect(sdl.SDL_SetRenderTextureAddressMode(renderer, address, address));
        const blend = switch (family) {
            .normal => sdl.SDL_BLENDMODE_BLEND_PREMULTIPLIED,
            .additive => sdl.SDL_BLENDMODE_ADD_PREMULTIPLIED,
            .multiply => sdl.SDL_BLENDMODE_MUL,
            else => unreachable,
        };
        try std.testing.expect(sdl.SDL_SetTextureBlendMode(texture, blend));
        try std.testing.expect(sdl.SDL_SetRenderTarget(renderer, target));
        const clear: u8 = if (family == .multiply) 255 else 0;
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(renderer, clear, clear, clear, clear));
        try std.testing.expect(sdl.SDL_RenderClear(renderer));
        var vertices: [3]sdl.SDL_Vertex = undefined;
        for (&vertices, positions, coordinates, colors) |*vertex, position, uv, color| {
            const premultiplied_color = premultiplied(color);
            vertex.* = .{ .position = .{ .x = @as(f32, @floatFromInt(position[0])) / 256, .y = @as(f32, @floatFromInt(position[1])) / 256 }, .tex_coord = .{ .x = @as(f32, @floatFromInt(uv[0])) / 256 / @as(f32, @floatFromInt(width)), .y = @as(f32, @floatFromInt(uv[1])) / 256 / @as(f32, @floatFromInt(height)) }, .color = .{ .r = @floatCast(premultiplied_color[0]), .g = @floatCast(premultiplied_color[1]), .b = @floatCast(premultiplied_color[2]), .a = @floatCast(premultiplied_color[3]) } };
        }
        try std.testing.expect(sdl.SDL_RenderGeometry(renderer, texture, &vertices, 3, &[_]c_int{ 0, 1, 2 }, 3));
        const surface = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        var case_mismatches: usize = 0;
        for (0..16) |row| for (0..16) |column| {
            const barycentric = weights(column, row);
            const area = edge(positions[0], positions[1], positions[2]);
            var interior = true;
            for (barycentric) |weight| if (weight * 12 <= area) {
                interior = false;
            };
            if (!interior) continue;
            if (!linear) {
                var away = true;
                for (0..2) |axis| {
                    var numerator: i128 = 0;
                    for (barycentric, coordinates) |weight, uv| numerator += weight * uv[axis];
                    const denominator = area * 256;
                    const remainder = @mod(numerator, denominator);
                    if (@min(remainder, denominator - remainder) * 256 <= denominator) away = false;
                }
                if (!away) continue;
            }
            var actual: [4]u8 = undefined;
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(column), @intCast(row), &actual[0], &actual[1], &actual[2], &actual[3]));
            const wanted = expected(barycentric, pixels, width, height, linear, repeat, family);
            checked += 1;
            if (!matchesAlpha(actual, wanted, if (family == .normal and linear) 1 else 0)) violations += 1;
            if (!matches(actual, wanted)) {
                std.debug.print("TRIANGLE_GATE_MISMATCH renderer={s} pattern={} family={s} linear={} repeat={} pixel={d},{d} barycentric={any}/{d} expected={any} actual={any}\n", .{ renderer_name, patterned, @tagName(family), linear, repeat, column, row, barycentric, area, wanted, actual });
                case_mismatches += 1;
            }
        };
        mismatches += case_mismatches;
        if (patterned and family == .normal and linear and !repeat) try observeFragment(renderer, texture, vertices);
        std.debug.print("TRIANGLE_GATE_CASE pattern={} family={s} linear={} repeat={} mismatches={d}\n", .{ patterned, @tagName(family), linear, repeat, case_mismatches });
    };
    try std.testing.expect(sdl.SDL_SetRenderTarget(renderer, null));
    std.debug.print("TRIANGLE_GATE renderer={s} strict_interior_pixels={d} strict_mismatches={d} outside_approved_policy={d}\n", .{ renderer_name, checked, mismatches, violations });
    try std.testing.expectEqual(@as(usize, 0), violations);
}

const Vertex = rendering.types.TriangleVertex;
const Location = struct { weights: [3]i128, area: i128, u: i128, v: i128, covered: bool };

fn cross(first: [2]i64, second: [2]i64, point: [2]i64) i128 {
    return (@as(i128, second[0]) - first[0]) * (@as(i128, point[1]) - first[1]) - (@as(i128, second[1]) - first[1]) * (@as(i128, point[0]) - first[0]);
}

fn locate(vertices: [3]Vertex, column: usize, row: usize, scroll: [2]i32) Location {
    const points = [3][2]i64{ .{ vertices[0].x, vertices[0].y }, .{ vertices[1].x, vertices[1].y }, .{ vertices[2].x, vertices[2].y } };
    const point = [2]i64{ (@as(i64, @intCast(column)) + scroll[0]) * 256 + 128, (@as(i64, @intCast(row)) + scroll[1]) * 256 + 128 };
    const signed_area = cross(points[0], points[1], points[2]);
    var result = Location{ .weights = .{ cross(points[1], points[2], point), cross(points[2], points[0], point), cross(points[0], points[1], point) }, .area = if (signed_area < 0) -signed_area else signed_area, .u = 0, .v = 0, .covered = signed_area != 0 };
    for (&result.weights, 0..) |*weight, index| {
        if (signed_area < 0) weight.* = -weight.*;
        var first = points[(index + 1) % 3];
        var second = points[(index + 2) % 3];
        if (signed_area < 0) std.mem.swap([2]i64, &first, &second);
        const top_left = second[1] < first[1] or (second[1] == first[1] and second[0] > first[0]);
        if (weight.* < 0 or (weight.* == 0 and !top_left)) result.covered = false;
        result.u += weight.* * vertices[index].u;
        result.v += weight.* * vertices[index].v;
    }
    return result;
}

fn nearEdge(vertices: [3]Vertex, column: usize, row: usize, scroll: [2]i32, outside_edges: [3]bool) bool {
    const point = [2]i256{ (@as(i256, @intCast(column)) + scroll[0]) * 256 + 128, (@as(i256, @intCast(row)) + scroll[1]) * 256 + 128 };
    for (outside_edges, 0..) |outside, index| {
        if (!outside) continue;
        const first = vertices[(index + 1) % 3];
        const second = vertices[(index + 2) % 3];
        const dx = @as(i256, second.x) - first.x;
        const dy = @as(i256, second.y) - first.y;
        const px = point[0] - first.x;
        const py = point[1] - first.y;
        const length = dx * dx + dy * dy;
        const dot = px * dx + py * dy;
        if (dot <= 0 or length == 0) {
            if (px * px + py * py <= 1) return true;
        } else if (dot >= length) {
            const ex = point[0] - second.x;
            const ey = point[1] - second.y;
            if (ex * ex + ey * ey <= 1) return true;
        } else {
            const perpendicular = px * dy - py * dx;
            if (perpendicular * perpendicular <= length) return true;
        }
    }
    return false;
}

fn canvasIdentity(family: Mode) [4]u8 {
    return if (family == .multiply) .{ 255, 255, 255, 255 } else .{ 0, 0, 0, 0 };
}

fn accumulated(previous: [4]u8, fragment: [4]f64, family: Mode) [4]u8 {
    var result: [4]u8 = undefined;
    for (0..3) |channel| {
        const old = @as(f64, @floatFromInt(previous[channel])) / 255;
        const output = switch (family) {
            .normal => fragment[channel] + (1 - fragment[3]) * old,
            .additive => old + fragment[channel],
            .multiply => old * (1 - fragment[3] + fragment[channel]),
            else => unreachable,
        };
        result[channel] = @intFromFloat(@round(std.math.clamp(output, 0, 1) * 255));
    }
    const alpha = fragment[3] + (1 - fragment[3]) * @as(f64, @floatFromInt(previous[3])) / 255;
    result[3] = if (family == .normal) @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255)) else if (family == .multiply) 255 else 0;
    return result;
}

const Scene = struct {
    vertices: [3]Vertex,
    pixels: []const [4]u8,
    width: usize = 3,
    height: usize = 5,
    family: Mode = .normal,
    linear: bool = false,
    repeat: bool = false,
    textured: bool = true,
    scroll: [2]i32 = .{ 0, 0 },
    replays: usize = 1,
    clip: ?rendering.types.SurfaceClip = null,
    outside_edges: [3]bool = .{ true, true, true },
};

fn reference(scene: Scene, location: Location, selected_x: i128, selected_y: i128) [4]u8 {
    var fragment: [4]f64 = @splat(0);
    for (scene.vertices, location.weights) |vertex, numerator| {
        const weight = @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(location.area));
        for (&fragment, premultiplied(vertex.color)) |*value, channel| value.* += weight * channel;
    }
    if (scene.textured) {
        const sampled = if (scene.linear) sample(scene.pixels, scene.width, scene.height, @as(f64, @floatFromInt(location.u)) / @as(f64, @floatFromInt(location.area * 256)), @as(f64, @floatFromInt(location.v)) / @as(f64, @floatFromInt(location.area * 256)), true, scene.repeat) else sourceTap(scene.pixels, scene.width, scene.height, @intCast(selected_x), @intCast(selected_y), scene.repeat);
        for (&fragment, sampled) |*value, channel| value.* *= channel;
    }
    var result = canvasIdentity(scene.family);
    for (0..scene.replays) |_| result = accumulated(result, fragment, scene.family);
    return result;
}

fn allowedAxis(numerator: i128, denominator: i128, exact: i128, candidate: i128) bool {
    return candidate == exact or (@abs(candidate - exact) == 1 and @abs(numerator - @max(candidate, exact) * denominator) * 256 <= denominator);
}

fn accepts(scene: Scene, column: usize, row: usize, actual: [4]u8) bool {
    if (scene.clip) |clip| if (column < clip.x or row < clip.y or column >= @as(u32, clip.x) + clip.w or row >= @as(u32, clip.y) + clip.h) return matches(actual, canvasIdentity(scene.family));
    const location = locate(scene.vertices, column, row, scene.scroll);
    if (location.area == 0) return matches(actual, canvasIdentity(scene.family));
    const boundary = nearEdge(scene.vertices, column, row, scene.scroll, scene.outside_edges);
    if ((!location.covered or boundary) and matches(actual, canvasIdentity(scene.family))) return true;
    if (!location.covered and !boundary) return false;
    const denominator = location.area * 256;
    const exact_x = @divFloor(location.u, denominator);
    const exact_y = @divFloor(location.v, denominator);
    const alpha_tolerance: u8 = if (scene.textured and scene.linear and scene.family == .normal) 1 else 0;
    const exact = reference(scene, location, exact_x, exact_y);
    if (matchesAlpha(actual, exact, alpha_tolerance)) return true;
    if (!scene.textured or scene.linear) return false;
    var delta_y: i128 = -1;
    while (delta_y <= 1) : (delta_y += 1) {
        var delta_x: i128 = -1;
        while (delta_x <= 1) : (delta_x += 1) {
            if (!allowedAxis(location.u, denominator, exact_x, exact_x + delta_x) or !allowedAxis(location.v, denominator, exact_y, exact_y + delta_y)) continue;
            if (matches(actual, reference(scene, location, exact_x + delta_x, exact_y + delta_y))) return true;
        }
    }
    return false;
}

const Client = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    instance: *rendering.Instance,

    fn init() !Client {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.VideoUnavailable;
        const window = sdl.SDL_CreateWindow("Retained triangles", 16, 16, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
        errdefer sdl.SDL_DestroyWindow(window);
        const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
        errdefer sdl.SDL_DestroyRenderer(renderer);
        const instance = try std.testing.allocator.create(rendering.Instance);
        try instance.init(std.testing.allocator, .{ .renderer = renderer, .logical_width = 16, .logical_height = 16, .opaque_presentation = true });
        return .{ .window = window, .renderer = renderer, .instance = instance };
    }

    fn deinit(self: *Client) void {
        self.instance.deinit();
        std.testing.allocator.destroy(self.instance);
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }

    fn supported(self: Client) bool {
        return !std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(self.renderer)), "software");
    }

    fn begin(self: *Client) !void {
        self.instance.state.frame_state = .updating;
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(self.renderer, 80, 120, 160, 255));
        try std.testing.expect(sdl.SDL_RenderClear(self.renderer));
    }

    fn execute(self: *Client) !void {
        try rendering.layers.compileDirtyRetainedLayers(self.instance);
        try rendering.compositor.executeCompositeFrame(self.instance);
    }

    fn canvas(self: *Client) ![256][4]u8 {
        const layer = self.instance.state.layers[0];
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, self.instance.state.texture_table[layer.target_texture_id]));
        defer _ = sdl.SDL_SetRenderTarget(self.renderer, null);
        const surface: *sdl.SDL_Surface = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        var result: [256][4]u8 = undefined;
        for (&result, 0..) |*pixel, index| try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @as(c_int, @intCast(index % 16)) + layer.backing.border, @as(c_int, @intCast(index / 16)) + layer.backing.border, &pixel[0], &pixel[1], &pixel[2], &pixel[3]));
        return result;
    }

    fn check(self: *Client, scene: Scene) !void {
        const layer = self.instance.state.layers[0];
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, self.instance.state.texture_table[layer.target_texture_id]));
        defer _ = sdl.SDL_SetRenderTarget(self.renderer, null);
        const surface: *sdl.SDL_Surface = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        const border: usize = layer.backing.border;
        for (0..@as(usize, @intCast(surface.h))) |row| for (0..@as(usize, @intCast(surface.w))) |column| {
            var actual: [4]u8 = undefined;
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(column), @intCast(row), &actual[0], &actual[1], &actual[2], &actual[3]));
            const ring = column < border or row < border or column >= 16 + border or row >= 16 + border;
            const accepted = if (ring) std.mem.eql(u8, &actual, &canvasIdentity(scene.family)) else accepts(scene, column - border, row - border, actual);
            if (!accepted) std.debug.print("TRIANGLE_INTEGRATED_MISMATCH scene={any} pixel={d},{d} actual={any} location={any}\n", .{ scene, column, row, actual, locate(scene.vertices, column -| border, row -| border, scene.scroll) });
            try std.testing.expect(accepted);
        };
    }
};

fn patternPixels() [15][4]u8 {
    var result: [15][4]u8 = undefined;
    for (&result, 0..) |*pixel, index| pixel.* = .{ @intCast(25 + (index % 3) * 100), @intCast(20 + (index / 3) * 50), if (index % 4 == 0) 255 else 80, switch (index % 4) {
        0 => 0,
        1 => 96,
        2 => 192,
        else => 255,
    } };
    return result;
}

test "untextured triangles retain exact alpha and fractional negative coordinates independent of UV and white resource" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.supported()) return;
    for (families) |family| for ([_]bool{ false, true }) |reversed| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        var vertices = inputVertices();
        for (&vertices) |*vertex| {
            vertex.x -= 353;
            vertex.y -= 145;
            vertex.u = std.math.minInt(i32);
            vertex.v = std.math.maxInt(i32);
        }
        if (reversed) std.mem.swap(Vertex, &vertices[0], &vertices[2]);
        try rendering.draw.addTexturedTriangle(client.instance, .{ .layer_id = 0, .vertices = vertices });
        try client.execute();
        try std.testing.expectEqual(@as(u16, 0), client.instance.state.layers[0].runs[0].texture_id);
        try client.check(.{ .vertices = vertices, .pixels = &.{}, .family = family, .textured = false });
        const before = client.instance.canvas_stats;
        try rendering.layers.setContentScroll(client.instance, 0, -3, -2);
        try client.begin();
        try client.execute();
        try client.check(.{ .vertices = vertices, .pixels = &.{}, .family = family, .textured = false, .scroll = .{ -3, -2 } });
        try std.testing.expectEqual(before.compiled_layers, client.instance.canvas_stats.compiled_layers);
    };
}

fn quadTriangles(color: [4]u8) [2][3]Vertex {
    const corners = [4]Vertex{
        .{ .x = 256, .y = 256, .u = 0, .v = 0, .color = color },
        .{ .x = 2304, .y = 256, .u = 768, .v = 0, .color = color },
        .{ .x = 2304, .y = 2304, .u = 768, .v = 1280, .color = color },
        .{ .x = 256, .y = 2304, .u = 0, .v = 1280, .color = color },
    };
    return .{ .{ corners[0], corners[1], corners[2] }, .{ corners[0], corners[2], corners[3] } };
}

fn presented(operation: [4]u8, family: Mode) [4]u8 {
    const background = [3]u8{ 80, 120, 160 };
    const tint = [3]u8{ 160, 240, 128 };
    const opacity = 128.0 / 255.0;
    var result: [4]u8 = .{ 0, 0, 0, 255 };
    for (0..3) |channel| {
        const energy = @as(f64, @floatFromInt(operation[channel])) / 255;
        const modulation = @as(f64, @floatFromInt(tint[channel])) / 255;
        const old = @as(f64, @floatFromInt(background[channel])) / 255;
        const value = switch (family) {
            .normal => opacity * modulation * energy + (1 - opacity * @as(f64, @floatFromInt(operation[3])) / 255) * old,
            .additive => @min(1, old + opacity * modulation * energy),
            .multiply => old * (1 - opacity + opacity * modulation * energy),
            else => unreachable,
        };
        result[channel] = @intFromFloat(@round(value * 255));
    }
    return result;
}

test "paired translucent triangles have strict shared edges and compose through independent canvas presentation" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.supported()) return;
    const pixels = patternPixels();
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 5, .shared);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 3, 5, std.mem.asBytes(&pixels), 12);
    for (families) |family| for ([_]bool{ false, true }) |textured| for ([_]bool{ false, true }) |linear| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try rendering.sampling.setSource(client.instance, id, if (linear) .bilinear else .nearest, .repeat);
        const triangles = quadTriangles(.{ 200, 160, 80, 128 });
        for (triangles) |vertices| try rendering.draw.addTexturedTriangle(client.instance, .{ .texture_id = if (textured) id else 0xffff, .layer_id = 0, .vertices = vertices });
        try client.execute();
        const image = try client.canvas();
        var expected_image: [256][4]u8 = undefined;
        for (image, &expected_image, 0..) |actual, *wanted, index| {
            var operation = canvasIdentity(family);
            var owners: usize = 0;
            for (triangles) |vertices| {
                const location = locate(vertices, index % 16, index / 16, .{ 0, 0 });
                if (location.covered) {
                    owners += 1;
                    operation = reference(.{ .vertices = vertices, .pixels = &pixels, .family = family, .textured = textured, .linear = linear, .repeat = true }, location, @divFloor(location.u, location.area * 256), @divFloor(location.v, location.area * 256));
                }
            }
            const covered = index % 16 >= 1 and index % 16 < 9 and index / 16 >= 1 and index / 16 < 9;
            try std.testing.expectEqual(@as(usize, if (covered) 1 else 0), owners);
            if (!matchesAlpha(actual, operation, if (textured and linear and family == .normal) 1 else 0)) std.debug.print("TRIANGLE_SEAM_MISMATCH textured={} linear={} family={s} pixel={d},{d} reference={any} actual={any}\n", .{ textured, linear, @tagName(family), index % 16, index / 16, operation, actual });
            try std.testing.expect(matchesAlpha(actual, operation, if (textured and linear and family == .normal) 1 else 0));
            wanted.* = operation;
        }
        const before = client.instance.canvas_stats;
        try client.begin();
        try rendering.layers.setCanvasSampling(client.instance, 0, .nearest);
        try rendering.layers.setAffine(client.instance, 0, .{ .a = 0, .b = -65536, .c = 65536, .d = 0, .tx = 4096 });
        const fields = [_]rendering.types.LayerPropField{ .opacity, .tint_r, .tint_g, .tint_b };
        const values = [_]i32{ 128, 160, 240, 128 };
        for (fields, values, 0..) |field, value, index| client.instance.state.layer_prop_buffer[index] = .{ .layer_id = 0, .field = @intFromEnum(field), .value = value };
        _ = try rendering.layers.submitLayerPropCommands(client.instance, fields.len);
        try client.execute();
        try std.testing.expectEqualDeep(before, client.instance.canvas_stats);
        const surface: *sdl.SDL_Surface = sdl.SDL_RenderReadPixels(client.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        for (0..256) |index| {
            var actual: [4]u8 = undefined;
            try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, @intCast(index % 16), @intCast(index / 16), &actual[0], &actual[1], &actual[2], &actual[3]));
            const operation = expected_image[(15 - index % 16) * 16 + index / 16];
            try std.testing.expect(matches(actual, presented(operation, family)));
        }
    };
}

test "mixed triangle sprite rectangle and raw UV runs retain order and variable vertex mappings" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.supported()) return;
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .shared);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &.{ 255, 255, 255, 255 }, 4);
    const colors_in_order = [_][4]u8{ .{ 240, 40, 80, 128 }, .{ 40, 200, 80, 128 }, .{ 40, 80, 240, 128 }, .{ 40, 200, 80, 128 }, .{ 160, 160, 160, 64 } };
    for (families) |family| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        const triangles = quadTriangles(colors_in_order[1]);
        try rendering.draw.addSolidRectToLayer(client.instance, 0, 0, 1, 1, 8, 8, 240, 40, 80, 128);
        try rendering.draw.addTexturedTriangle(client.instance, .{ .texture_id = id, .layer_id = 0, .vertices = triangles[0] });
        try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sw = 1, .sh = 1, .affine = .{ .a = 524288, .d = 524288, .tx = 256, .ty = 256 }, .tint = colors_in_order[2] });
        try rendering.draw.addTexturedTriangle(client.instance, .{ .texture_id = id, .layer_id = 0, .vertices = triangles[1] });
        try rendering.draw.addOperationQuadUV(client.instance, id, 0, 0, .{ .x = -1, .y = -1, .w = 3, .h = 3 }, .{ .x = 1, .y = 1, .w = 8, .h = 8 }, colors_in_order[4]);
        for ([_]rendering.types.Sampling{ .nearest, .bilinear }) |filter| for ([_]rendering.types.Addressing{ .clamp, .repeat, .clamp }) |address| {
            try rendering.sampling.setSource(client.instance, id, filter, address);
            try client.execute();
            try std.testing.expectEqual(@as(u32, if (address == .clamp) 3 else 5), client.instance.state.render_stats.draw_calls);
            try std.testing.expectEqual(@as(u32, 18), client.instance.state.layers[0].cached_vertex_count);
            try std.testing.expectEqual(@as(u32, 24), client.instance.state.layers[0].cached_index_count);
            for (try client.canvas(), 0..) |actual, index| {
                var wanted = canvasIdentity(family);
                if (index % 16 >= 1 and index % 16 < 9 and index / 16 >= 1 and index / 16 < 9) {
                    wanted = accumulated(wanted, premultiplied(colors_in_order[0]), family);
                    if (locate(triangles[0], index % 16, index / 16, .{ 0, 0 }).covered) wanted = accumulated(wanted, premultiplied(colors_in_order[1]), family);
                    wanted = accumulated(wanted, premultiplied(colors_in_order[2]), family);
                    if (locate(triangles[1], index % 16, index / 16, .{ 0, 0 }).covered) wanted = accumulated(wanted, premultiplied(colors_in_order[3]), family);
                    wanted = accumulated(wanted, premultiplied(colors_in_order[4]), family);
                }
                try std.testing.expect(matches(actual, wanted));
            }
        };
    }
}

test "mixed effective sampler batches preserve repeat atlas isolation cached geometry and failed retry" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.supported()) return;
    const pixels = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 } };
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 1, .shared);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 3, 1, std.mem.asBytes(&pixels), 12);
    for (families) |family| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        const corners = [_]Vertex{
            .{ .x = 0, .y = 0, .u = -256, .v = 128 },
            .{ .x = 1024, .y = 0, .u = 1280, .v = 128 },
            .{ .x = 1024, .y = 1024, .u = 1280, .v = 128 },
            .{ .x = 0, .y = 1024, .u = -256, .v = 128 },
        };
        for ([_][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }) |indices| try rendering.draw.addTexturedTriangle(client.instance, .{ .layer_id = 0, .texture_id = id, .vertices = .{ corners[indices[0]], corners[indices[1]], corners[indices[2]] } });
        try rendering.draw.addTexturedQuadTinted(client.instance, id, 0, 0, 0, 0, 3, 1, 4, 0, 4, 4, false, false, 0, 0, 0, 255, 255, 255, 255);
        try rendering.draw.addAffineSprite(client.instance, .{ .texture_id = id, .layer_id = 0, .sx = 1, .sw = 1, .sh = 1, .affine = .{ .a = 262144, .d = 262144, .tx = 2048 } });
        try rendering.draw.addOperationQuadUV(client.instance, id, 0, 0, .{ .x = -1, .y = 0.5, .w = 6, .h = 0 }, .{ .x = 12, .y = 0, .w = 4, .h = 4 }, .{ 255, 255, 255, 255 });
        var compiled: ?u64 = null;
        for ([_]rendering.types.Sampling{ .nearest, .bilinear, .nearest }) |filter| for ([_]rendering.types.Addressing{ .clamp, .repeat, .clamp }) |address| {
            try client.begin();
            try rendering.sampling.setSource(client.instance, id, filter, address);
            try client.execute();
            if (client.instance.state.render_stats.draw_calls != @as(u32, if (address == .clamp) 4 else 5)) std.debug.print("MIXED_SAMPLER family={s} filter={s} address={s} calls={d} runs={any}\n", .{ @tagName(family), @tagName(filter), @tagName(address), client.instance.state.render_stats.draw_calls, client.instance.state.layers[0].runs[0..client.instance.state.layers[0].run_count] });
            try std.testing.expectEqual(@as(u32, if (address == .clamp) 4 else 5), client.instance.state.render_stats.draw_calls);
            if (compiled) |count| try std.testing.expectEqual(count, client.instance.canvas_stats.compiled_layers);
            compiled = client.instance.canvas_stats.compiled_layers;
            for (try client.canvas(), 0..) |actual, index| {
                const column = index % 16;
                var wanted = canvasIdentity(family);
                if (index / 16 < 4) {
                    const cell = column / 4;
                    const position = @as(f64, @floatFromInt(column % 4)) + 0.5;
                    const fragment = if (cell == 2) premultiplied(pixels[1]) else sample(&pixels, 3, 1, if (cell == 1) position * 0.75 else -1 + position * 1.5, 0.5, filter == .bilinear, cell != 1 and address == .repeat);
                    wanted = accumulated(wanted, fragment, family);
                }
                try std.testing.expect(matches(actual, wanted));
            }
        };
        for ([_]rendering.faults.Point{ .sampling_state, .geometry, .sampling_restore }) |point| {
            try client.begin();
            try rendering.layers.setContentScroll(client.instance, 0, 1, 0);
            try rendering.layers.setContentScroll(client.instance, 0, 0, 0);
            try rendering.draw.addSolidRect(client.instance, 10, 15, 15, 1, 1, 255, 255, 255, 255);
            client.instance.faults.inject(point, 0);
            if (point == .geometry) try std.testing.expectError(error.GeometryFailed, client.execute()) else try std.testing.expectError(error.TextureStateFailed, client.execute());
            try std.testing.expect(client.instance.state.layers[0].target_dirty);
            try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
            try std.testing.expectEqual(@as(usize, 1), client.instance.state.instruction_count);
            try client.begin();
            try client.execute();
            try std.testing.expectEqual(compiled.?, client.instance.canvas_stats.compiled_layers);
            try rendering.compositor.present(client.instance);
        }
    }
}

test "triangle admission allocation ownership reset and untextured failure retry are transactional" {
    var client = try Client.init();
    defer client.deinit();
    try client.begin();
    const triangle = rendering.types.TexturedTriangle{ .layer_id = 0, .vertices = inputVertices() };
    try std.testing.expectError(error.OperationCanvasRequired, rendering.draw.addTexturedTriangle(client.instance, triangle));
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    client.instance.frame_ready = true;
    client.instance.changes = .{};
    client.instance.faults.inject(.triangle_metadata_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, rendering.draw.addTexturedTriangle(client.instance, triangle));
    try std.testing.expect(client.instance.frame_ready);
    try std.testing.expectEqualDeep(rendering.Changes{}, client.instance.changes);
    try std.testing.expect(client.instance.draw_storage.owners[0].payloads == 0);
    var invalid = triangle;
    invalid.texture_id = 0;
    try std.testing.expectError(error.InvalidTextureId, rendering.draw.addTexturedTriangle(client.instance, invalid));
    invalid.texture_id = rendering.types.max_texture_ids;
    try std.testing.expectError(error.InvalidTextureId, rendering.draw.addTexturedTriangle(client.instance, invalid));
    invalid = triangle;
    invalid.layer_id = 255;
    try std.testing.expectError(error.InvalidLayerId, rendering.draw.addTexturedTriangle(client.instance, invalid));
    var degenerate = triangle;
    degenerate.vertices[1] = degenerate.vertices[0];
    try rendering.draw.addTexturedTriangle(client.instance, degenerate);
    try rendering.layers.compileDirtyRetainedLayers(client.instance);
    try std.testing.expectEqual(@as(u32, 0), client.instance.state.layers[0].cached_vertex_count);
    for (1..client.instance.draw_storage.config.reserved) |_| try rendering.draw.addTexturedTriangle(client.instance, triangle);
    const metadata = client.instance.draw_storage.backing.payloads.ptr;
    try std.testing.expectError(error.LayerSlabFull, rendering.draw.addTexturedTriangle(client.instance, triangle));
    try std.testing.expectEqual(client.instance.draw_storage.config.reserved, client.instance.state.layers[0].slab_count);
    try std.testing.expectError(error.OperationCanvasRequired, rendering.layers.setCanvasMode(client.instance, 0, .legacy_rgba));
    _ = try rendering.layers.submitLayer(client.instance, 0, 0);
    try rendering.layers.setCanvasMode(client.instance, 0, .legacy_rgba);
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    try rendering.draw.addTexturedTriangle(client.instance, triangle);
    try std.testing.expectEqual(metadata, client.instance.draw_storage.backing.payloads.ptr);
    try rendering.layers.clearLayerContents(client.instance, 0);
    try rendering.draw.addTexturedTriangle(client.instance, triangle);
    if (client.supported()) {
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        try client.execute();
        client.instance.faults.inject(.target_creation, 0);
        try std.testing.expectError(error.TextureCreationFailed, rendering.layers.resetLayer(client.instance, 0));
        try std.testing.expectEqual(metadata, client.instance.draw_storage.backing.payloads.ptr);
        try std.testing.expectEqual(@as(u16, 1), client.instance.state.layers[0].slab_count);
        for ([_]rendering.faults.Point{ .geometry, .untextured_blend_restore }) |point| {
            try rendering.layers.setContentScroll(client.instance, 0, 1, 0);
            try rendering.layers.setContentScroll(client.instance, 0, 0, 0);
            try rendering.draw.addSolidRect(client.instance, 10, 15, 15, 1, 1, 255, 255, 255, 255);
            try std.testing.expect(sdl.SDL_SetRenderDrawBlendMode(client.renderer, sdl.SDL_BLENDMODE_ADD));
            client.instance.faults.inject(point, 0);
            if (point == .geometry) try std.testing.expectError(error.GeometryFailed, client.execute()) else try std.testing.expectError(error.TextureStateFailed, client.execute());
            var restored: sdl.SDL_BlendMode = undefined;
            try std.testing.expect(sdl.SDL_GetRenderDrawBlendMode(client.renderer, &restored));
            try std.testing.expectEqual(@as(sdl.SDL_BlendMode, sdl.SDL_BLENDMODE_ADD), restored);
            try std.testing.expect(client.instance.state.layers[0].target_dirty);
            try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
            try std.testing.expectEqual(@as(usize, 1), client.instance.state.instruction_count);
            try client.begin();
            try client.execute();
            try client.check(.{ .vertices = triangle.vertices, .pixels = &.{}, .textured = false });
            try rendering.compositor.present(client.instance);
        }
    }
    try rendering.layers.resetLayer(client.instance, 0);
    try std.testing.expect(client.instance.draw_storage.owners[0].payloads == 0);
    client.instance.state.frame_state = .idle;
    try std.testing.expectError(error.WrongFrameState, rendering.draw.addTexturedTriangle(client.instance, triangle));
}

test "triangle resource edits hidden release dimension changes and physical ID revival refresh UVs without rectangle clamping" {
    var client = try Client.init();
    defer client.deinit();
    if (!client.supported()) return;
    var pixels = patternPixels();
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 5, .shared);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 3, 5, std.mem.asBytes(&pixels), 12);
    try client.begin();
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    try rendering.draw.addTexturedTriangle(client.instance, .{ .texture_id = id, .layer_id = 0, .vertices = inputVertices() });
    try client.execute();
    const compiled = client.instance.canvas_stats.compiled_layers;
    pixels[0] = .{ 240, 80, 120, 255 };
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 1, 1, &pixels[0], 4);
    try std.testing.expect(!client.instance.frame_ready);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(compiled, client.instance.canvas_stats.compiled_layers);
    try client.check(.{ .vertices = inputVertices(), .pixels = &pixels });
    client.instance.state.layer_prop_buffer[0] = .{ .layer_id = 0, .field = @intFromEnum(rendering.types.LayerPropField.visible), .value = 0 };
    _ = try rendering.layers.submitLayerPropCommands(client.instance, 1);
    client.instance.state.frame_state = .idle;
    try rendering.textures.destroyDynamicTexture(client.instance, id);
    try client.begin();
    try client.execute();
    try std.testing.expectEqual(@as(u32, 0), client.instance.state.layers[0].cached_vertex_count);
    client.instance.state.frame_state = .idle;
    const small = try rendering.textures.createOperationDynamicTexture(client.instance, 1, 1, .operation_only);
    try std.testing.expectEqual(id, small);
    const solid = [_][4]u8{.{ 240, 80, 40, 128 }};
    try rendering.textures.updateDynamicTexture(client.instance, small, 0, 0, 1, 1, &solid[0], 4);
    try client.begin();
    client.instance.state.layer_prop_buffer[0].value = 1;
    _ = try rendering.layers.submitLayerPropCommands(client.instance, 1);
    try client.execute();
    try std.testing.expectEqual(@as(u32, 3), client.instance.state.layers[0].cached_vertex_count);
    try client.check(.{ .vertices = inputVertices(), .pixels = &solid, .width = 1, .height = 1 });
    client.instance.state.frame_state = .idle;
    try rendering.textures.destroyDynamicTexture(client.instance, small);
    const revived = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 5, .shared);
    try std.testing.expectEqual(id, revived);
    try rendering.textures.updateDynamicTexture(client.instance, revived, 0, 0, 3, 5, std.mem.asBytes(&pixels), 12);
    try client.begin();
    try client.execute();
    try client.check(.{ .vertices = inputVertices(), .pixels = &pixels });
}

test "triangle precision permission is final normal bilinear alpha only and never excuses seam errors" {
    const pixels = patternPixels();
    var scene = Scene{ .vertices = inputVertices(), .pixels = &pixels, .linear = true };
    const location = locate(scene.vertices, 5, 3, .{ 0, 0 });
    const wanted = reference(scene, location, 0, 0);
    var changed = wanted;
    changed[3] += 1;
    try std.testing.expect(accepts(scene, 5, 3, changed));
    changed[3] += 1;
    try std.testing.expect(!accepts(scene, 5, 3, changed));
    scene.replays = 3;
    changed = reference(scene, location, 0, 0);
    changed[3] += 2;
    try std.testing.expect(!accepts(scene, 5, 3, changed));
    scene.replays = 1;
    for ([_]bool{ false, true }) |textured| {
        scene.textured = textured;
        scene.linear = !textured;
        const exact = reference(scene, location, @divFloor(location.u, location.area * 256), @divFloor(location.v, location.area * 256));
        changed = exact;
        changed[3] += 1;
        try std.testing.expect(!accepts(scene, 5, 3, changed));
    }
    for ([_]Mode{ .additive, .multiply }) |family| {
        scene.family = family;
        scene.textured = true;
        scene.linear = true;
        changed = reference(scene, location, 0, 0);
        changed[3] = if (family == .additive) 1 else 254;
        try std.testing.expect(!accepts(scene, 5, 3, changed));
    }
    const triangle = quadTriangles(.{ 200, 160, 80, 128 })[0];
    const seam_scene = Scene{ .vertices = triangle, .pixels = &.{}, .textured = false, .outside_edges = .{ true, false, true } };
    try std.testing.expect(locate(triangle, 4, 4, .{ 0, 0 }).covered);
    try std.testing.expect(!nearEdge(triangle, 4, 4, .{ 0, 0 }, seam_scene.outside_edges));
    try std.testing.expect(!accepts(seam_scene, 4, 4, canvasIdentity(.normal)));
    const double_scene = Scene{ .vertices = triangle, .pixels = &.{}, .textured = false, .replays = 2 };
    const doubled = reference(double_scene, locate(triangle, 4, 4, .{ 0, 0 }), 0, 0);
    try std.testing.expect(!accepts(seam_scene, 4, 4, doubled));
    var bilinear_seam = seam_scene;
    bilinear_seam.textured = true;
    bilinear_seam.linear = true;
    bilinear_seam.width = 1;
    bilinear_seam.height = 1;
    bilinear_seam.pixels = &.{.{ 255, 255, 255, 255 }};
    try std.testing.expect(!accepts(bilinear_seam, 4, 4, canvasIdentity(.normal)));
    try std.testing.expect(!accepts(bilinear_seam, 4, 4, doubled));
    try std.testing.expect(allowedAxis(257, 256, 1, 0));
    try std.testing.expect(!allowedAxis(258, 256, 1, 0));
    try std.testing.expect(!(allowedAxis(257, 256, 1, 0) and allowedAxis(384, 256, 1, 0)));
}

fn inputVertices() [3]Vertex {
    var result: [3]Vertex = undefined;
    for (&result, positions, coordinates, colors) |*vertex, point, uv, color| vertex.* = .{ .x = point[0], .y = point[1], .u = uv[0], .v = uv[1], .color = color };
    return result;
}

test "retained triangles preserve independent colours sampling overlap precision clip padding and scroll cancellation" {
    var client = try Client.init();
    defer client.deinit();
    const pixels = patternPixels();
    const id = try rendering.textures.createOperationDynamicTexture(client.instance, 3, 5, .operation_only);
    try rendering.textures.updateDynamicTexture(client.instance, id, 0, 0, 3, 5, std.mem.asBytes(&pixels), 12);
    try client.begin();
    try rendering.layers.setCanvasMode(client.instance, 0, .normal);
    if (!client.supported()) {
        try rendering.draw.addTexturedTriangle(client.instance, .{ .texture_id = id, .layer_id = 0, .vertices = inputVertices() });
        try std.testing.expectError(error.UnsupportedCanvasBackend, client.execute());
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(client.instance));
        std.debug.print("TRIANGLE_INTEGRATION software operation rejection only\n", .{});
        return;
    }
    var cases: usize = 0;
    for (families) |family| for ([_]bool{ false, true }) |linear| for ([_]bool{ false, true }) |repeat| for ([_]bool{ false, true }) |padded| for ([_]usize{ 1, 2, 3 }) |replays| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.layers.setCanvasSampling(client.instance, 0, if (padded) .bilinear else .nearest);
        try rendering.sampling.setSource(client.instance, id, if (linear) .bilinear else .nearest, if (repeat) .repeat else .clamp);
        var vertices = inputVertices();
        if (repeat) {
            for (&vertices) |*vertex| {
                vertex.u = vertex.u * 3 - 768;
                vertex.v = vertex.v * 3 - 1280;
            }
        }
        if (padded) std.mem.swap(Vertex, &vertices[1], &vertices[2]);
        for (0..replays) |_| try rendering.draw.addTexturedTriangle(client.instance, .{ .texture_id = id, .layer_id = 0, .vertices = vertices });
        try client.execute();
        try std.testing.expectEqual(@as(u32, @intCast(replays * 3)), client.instance.state.layers[0].cached_vertex_count);
        try std.testing.expect(client.instance.sampling_cache.views == null);
        try std.testing.expectEqual(@as(u32, @intCast(replays * 3)), client.instance.state.layers[0].cached_index_count);
        var scene = Scene{ .vertices = vertices, .pixels = &pixels, .family = family, .linear = linear, .repeat = repeat, .replays = replays };
        try client.check(scene);
        const before = client.instance.canvas_stats;
        const source_before = client.instance.source_stats;
        const sampling_before = client.instance.sampling_stats;
        try client.begin();
        try client.execute();
        try std.testing.expectEqualDeep(before, client.instance.canvas_stats);
        try std.testing.expectEqualDeep(source_before, client.instance.source_stats);
        try std.testing.expectEqualDeep(sampling_before, client.instance.sampling_stats);
        try rendering.sampling.setSource(client.instance, id, if (linear) .nearest else .bilinear, if (repeat) .clamp else .repeat);
        try client.begin();
        try client.execute();
        var switched = scene;
        switched.linear = !linear;
        switched.repeat = !repeat;
        try client.check(switched);
        try std.testing.expectEqual(before.compiled_layers, client.instance.canvas_stats.compiled_layers);
        try std.testing.expectEqualDeep(source_before, client.instance.source_stats);
        try rendering.sampling.setSource(client.instance, id, if (linear) .bilinear else .nearest, if (repeat) .repeat else .clamp);
        try rendering.layers.setContentScroll(client.instance, 0, 1, -1);
        try rendering.layers.setSurfaceClip(client.instance, 0, .{ .x = 2, .y = 3, .w = 9, .h = 8 });
        try client.begin();
        try client.execute();
        scene.scroll = .{ 1, -1 };
        scene.clip = .{ .x = 2, .y = 3, .w = 9, .h = 8 };
        try client.check(scene);
        try std.testing.expectEqual(before.compiled_layers, client.instance.canvas_stats.compiled_layers);
        try std.testing.expectEqual(before.target_allocations, client.instance.canvas_stats.target_allocations);
        cases += 1;
    };
    for (families) |family| {
        try client.begin();
        try rendering.layers.resetLayer(client.instance, 0);
        try rendering.layers.setCanvasMode(client.instance, 0, family);
        try rendering.layers.setCanvasSampling(client.instance, 0, .bilinear);
        var vertices = inputVertices();
        for (&vertices) |*vertex| {
            vertex.x += 2147479615;
            vertex.y += 2147479615;
        }
        try rendering.draw.addTexturedTriangle(client.instance, .{ .texture_id = id, .layer_id = 0, .vertices = vertices });
        try rendering.sampling.setSource(client.instance, id, .nearest, .clamp);
        try rendering.layers.setContentScroll(client.instance, 0, 8388592, 8388592);
        try client.execute();
        try client.check(.{ .vertices = vertices, .pixels = &pixels, .family = family, .scroll = .{ 8388592, 8388592 } });
    }
    std.debug.print("TRIANGLE_INTEGRATION Metal SDL geometry cases={d} plus clipped scroll replay and 3 cancellation cases; accumulated bilinear normal alpha cap=1 independent of replay count\n", .{cases});
}
