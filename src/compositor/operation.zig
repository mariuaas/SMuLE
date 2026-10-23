const std = @import("std");
const sdl = @import("sdl").sdl;
const Instance = @import("root.zig").Instance;
const types = @import("types.zig");
const Error = @import("compositor.zig").RenderError;
const sampling = @import("sampling.zig");
const textures = @import("textures.zig");

pub fn scale(
    channel: u8,
    alpha: u8,
) u8 {
    return @intCast((@as(u32, channel) * alpha + 127) / 255);
}

pub fn blend(mode: types.CanvasMode) sdl.SDL_BlendMode {
    return switch (mode) {
        .normal => sdl.SDL_BLENDMODE_BLEND_PREMULTIPLIED,
        .additive => sdl.SDL_BLENDMODE_ADD_PREMULTIPLIED,
        .multiply => sdl.SDL_BLENDMODE_MUL,
        .legacy_rgba => unreachable,
    };
}

pub const Source = struct {
    pixels: ?[]u8 = null,
    dirty: ?sdl.SDL_Rect = null,
    uncertain: ?sdl.SDL_Rect = null,
    external: bool = false,
    stale: bool = false,
    exclusive: bool = false,
    palette_key: i16 = -1,
    filter: types.Sampling = .nearest,
    addressing: types.Addressing = .clamp,
};
/// Preparation workload counters, not a count of every underlying malloc call.
/// CPU allocations count owned pixel buffers and successful SDL surface conversions.
pub const Stats = struct {
    cpu_allocations: usize = 0,
    texture_allocations: usize = 0,
    converted_pixels: usize = 0,
    uploaded_bytes: usize = 0,
    legacy_uploaded_bytes: usize = 0,
    legacy_texture_allocations: usize = 0,
    readbacks: usize = 0,
};

pub fn invalidateResource(ctx: *Instance, texture_id: u16) void {
    sampling.dropSource(ctx, texture_id);
    if (ctx.state.premultiplied_textures[texture_id]) |texture| sdl.SDL_DestroyTexture(texture);
    if (ctx.state.operation_sources[texture_id].pixels) |pixels| ctx.allocator.free(pixels);
    ctx.state.premultiplied_textures[texture_id] = null;
    ctx.state.operation_sources[texture_id] = .{};
}

pub fn invalidateExternal(
    ctx: *Instance,
    texture_id: u16,
) void {
    const entry = &ctx.state.operation_sources[texture_id];
    if (!entry.external) return;
    sampling.dirtySource(ctx, texture_id, null);
    entry.stale = true;
}

pub fn allocate(
    ctx: *Instance,
    length: usize,
) error{OutOfMemory}![]u8 {
    if (ctx.faults.check(.operation_cpu_allocation))
        return error.OutOfMemory;
    const pixels = try ctx.allocator.alloc(u8, length);
    ctx.source_stats.cpu_allocations += 1;
    return pixels;
}

fn convert(
    ctx: *Instance,
    output: []u8,
    input: []const u8,
) void {
    var offset: usize = 0;
    while (offset < output.len) : (offset += 4) {
        for (0..3) |channel| output[offset + channel] = scale(input[offset + channel], input[offset + 3]);
        output[offset + 3] = input[offset + 3];
    }
    ctx.source_stats.converted_pixels += output.len / 4;
}

/// Return allocator-owned premultiplied RGBA bytes without GPU copies or readback.
/// Counts the converted SDL surface and the returned pixel buffer separately.
pub fn prepareSurface(
    ctx: *Instance,
    surface: *sdl.SDL_Surface,
) error{ OutOfMemory, ResourceConversionFailed }![]u8 {
    if (ctx.faults.check(.operation_surface_conversion))
        return error.ResourceConversionFailed;
    const rgba: *sdl.SDL_Surface = sdl.SDL_ConvertSurface(surface, sdl.SDL_PIXELFORMAT_RGBA32) orelse
        return error.ResourceConversionFailed;
    defer sdl.SDL_DestroySurface(rgba);
    ctx.source_stats.cpu_allocations += 1;
    const width: usize = @intCast(rgba.w);
    const height: usize = @intCast(rgba.h);
    const pixels = try allocate(ctx, width * height * 4);
    const input: [*]const u8 = @ptrCast(rgba.pixels);
    for (0..height) |row|
        convert(
            ctx,
            pixels[row * width * 4 ..][0 .. width * 4],
            input[row * @as(usize, @intCast(rgba.pitch)) ..][0 .. width * 4],
        );
    if (surface.format == sdl.SDL_PIXELFORMAT_INDEX8) {
        if (sdl.SDL_GetSurfacePalette(surface)) |palette| {
            const indices: [*]const u8 = @ptrCast(surface.pixels);
            for (0..height) |row| {
                for (0..width) |column| {
                    if (indices[row * @as(usize, @intCast(surface.pitch)) + column] >= palette.*.ncolors)
                        @memset(pixels[(row * width + column) * 4 ..][0..4], 0);
                }
            }
        }
    }
    return pixels;
}

pub fn commit(
    ctx: *Instance,
    texture_id: u16,
    pixels: []u8,
) void {
    sampling.dirtySource(ctx, texture_id, null);
    const entry = &ctx.state.operation_sources[texture_id];
    if (entry.pixels) |old| ctx.allocator.free(old);
    entry.pixels = pixels;
    entry.stale = false;
    const dims = ctx.state.texture_dims[texture_id];
    entry.dirty = .{ .x = 0, .y = 0, .w = @intFromFloat(dims.width), .h = @intFromFloat(dims.height) };
}

pub fn update(
    ctx: *Instance,
    texture_id: u16,
    rect: sdl.SDL_Rect,
    pixels: []const u8,
    pitch: usize,
) void {
    sampling.dirtySource(ctx, texture_id, rect);
    const entry = &ctx.state.operation_sources[texture_id];
    if (entry.uncertain) |failed| {
        if (rect.x <= failed.x and rect.y <= failed.y and
            rect.x + rect.w >= failed.x + failed.w and
            rect.y + rect.h >= failed.y + failed.h)
            entry.uncertain = null;
    }
    const output = entry.pixels orelse return;
    const stride: usize = @as(usize, @intFromFloat(ctx.state.texture_dims[texture_id].width)) * 4;
    for (0..@as(usize, @intCast(rect.h))) |row| {
        const offset = (@as(usize, @intCast(rect.y)) + row) * stride + @as(usize, @intCast(rect.x)) * 4;
        convert(
            ctx,
            output[offset..][0 .. @as(usize, @intCast(rect.w)) * 4],
            pixels[row * pitch ..][0 .. @as(usize, @intCast(rect.w)) * 4],
        );
    }
    if (entry.dirty) |old| {
        const left = @min(old.x, rect.x);
        const top = @min(old.y, rect.y);
        entry.dirty = .{
            .x = left,
            .y = top,
            .w = @max(old.x + old.w, rect.x + rect.w) - left,
            .h = @max(old.y + old.h, rect.y + rect.h) - top,
        };
    } else entry.dirty = rect;
}

pub fn premultiplyVertex(color: sdl.SDL_FColor) sdl.SDL_FColor {
    const alpha: u8 = @intFromFloat(@round(color.a * 255));
    return .{
        .r = @as(f32, @floatFromInt(scale(@intFromFloat(@round(color.r * 255)), alpha))) / 255,
        .g = @as(f32, @floatFromInt(scale(@intFromFloat(@round(color.g * 255)), alpha))) / 255,
        .b = @as(f32, @floatFromInt(scale(@intFromFloat(@round(color.b * 255)), alpha))) / 255,
        .a = color.a,
    };
}

pub fn source(ctx: *Instance, texture_id: u16) Error!?*sdl.SDL_Texture {
    const original = ctx.state.texture_table[texture_id] orelse return null;
    const entry = &ctx.state.operation_sources[texture_id];
    if (entry.uncertain != null) return error.ResourceConversionFailed;
    if (texture_id == ctx.state.white_texture_id and
        entry.pixels == null and
        !entry.stale)
        return original;
    if (entry.stale and entry.external)
        return error.UnsupportedOperationResource;
    if (entry.pixels == null) {
        const prepared = textures.prepareIndexedOperationSource(ctx, texture_id) catch
            return error.ResourceConversionFailed;
        if (prepared) |owned| {
            commit(ctx, texture_id, owned);
        } else {
            for (ctx.state.dynamic_textures) |dynamic| {
                if (dynamic.is_initialized and dynamic.texture_id == texture_id)
                    return error.OperationPixelsRequired;
            }
            return error.UnsupportedOperationResource;
        }
    }
    const pixels = entry.pixels.?;
    const dims = ctx.state.texture_dims[texture_id];
    const width: c_int = @intFromFloat(dims.width);
    const height: c_int = @intFromFloat(dims.height);
    var texture = if (entry.exclusive) original else ctx.state.premultiplied_textures[texture_id];
    if (texture == null) {
        if (ctx.faults.check(.operation_allocation))
            return error.ResourceConversionFailed;
        texture = sdl.SDL_CreateTexture(
            ctx.context.renderer,
            sdl.SDL_PIXELFORMAT_RGBA32,
            sdl.SDL_TEXTUREACCESS_STATIC,
            width,
            height,
        ) orelse
            return error.ResourceConversionFailed;
        ctx.source_stats.texture_allocations += 1;
        if (ctx.faults.check(.texture_scale) or !sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST)) {
            sdl.SDL_DestroyTexture(texture);
            return error.TextureStateFailed;
        }
        ctx.state.premultiplied_textures[texture_id] = texture;
    }
    if (entry.dirty) |rect| {
        const stride: usize = @as(usize, @intCast(width)) * 4;
        const offset = @as(usize, @intCast(rect.y)) * stride + @as(usize, @intCast(rect.x)) * 4;
        if (ctx.faults.check(.operation_upload) or
            !sdl.SDL_UpdateTexture(texture, &rect, pixels[offset..].ptr, @intCast(stride)))
            return error.ResourceConversionFailed;
        ctx.source_stats.uploaded_bytes += @as(usize, @intCast(rect.w)) * @as(usize, @intCast(rect.h)) * 4;
        entry.dirty = null;
    }
    return texture;
}
