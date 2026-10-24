const std = @import("std");
const log = std.log.scoped(.smule);
const sdl = @import("sdl").sdl;
const Instance = @import("root.zig").Instance;

const t = @import("types.zig");
const layers = @import("layers.zig");
const operation = @import("operation.zig");

fn isIndexedTexture(ctx: *Instance, texture_id: u16) bool {
    for (ctx.state.graphics) |graphic| {
        if (!graphic.is_initialized or !graphic.is_indexed) continue;
        for (graphic.texture_ids, graphic.flags) |id, active| {
            if (active and id == texture_id) return true;
        }
    }
    return false;
}

pub fn prepareIndexedOperationSource(ctx: *Instance, texture_id: u16) TextureError!?[]u8 {
    for (&ctx.state.graphics) |*graphic| {
        if (!graphic.is_initialized or !graphic.is_indexed) continue;
        for (graphic.texture_ids, graphic.flags, 0..) |id, active, palette_index| {
            if (!active or id != texture_id) continue;
            const surface = graphic.surface orelse
                return error.GraphicUnavailable;
            const colors = graphic.colors[palette_index] orelse
                return error.GraphicUnavailable;
            var previous_key: u32 = 0;
            const had_key = sdl.SDL_GetSurfaceColorKey(surface, &previous_key);
            defer _ = sdl.SDL_SetSurfaceColorKey(surface, had_key, previous_key);
            const key = ctx.state.operation_sources[texture_id].palette_key;
            if (!sdl.SDL_SetSurfaceColorKey(surface, key >= 0, if (key >= 0) @intCast(key) else 0))
                return error.SurfaceColorKeyFailed;
            if (ctx.faults.check(.palette_creation)) return error.PaletteCreationFailed;
            const palette = sdl.SDL_CreatePalette(@intCast(graphic.ncolors[palette_index])) orelse
                return error.PaletteCreationFailed;
            defer sdl.SDL_DestroyPalette(palette);
            if (ctx.faults.check(.palette_colors) or !sdl.SDL_SetPaletteColors(palette, colors, 0, @intCast(graphic.ncolors[palette_index])))
                return error.PaletteUpdateFailed;
            if (ctx.faults.check(.surface_palette) or !sdl.SDL_SetSurfacePalette(surface, palette))
                return error.SurfacePaletteFailed;
            defer _ = sdl.SDL_SetSurfacePalette(surface, null);
            return try operation.prepareSurface(ctx, surface);
        }
    }
    return null;
}

pub const TextureError = error{
    WrongFrameState,
    InvalidGraphicIndex,
    InvalidPaletteIndex,
    RendererUnavailable,
    GraphicUnavailable,
    InvalidDimensions,
    InvalidPaletteSize,
    InvalidPixelData,
    InvalidSurfacePitch,
    SurfaceCreationFailed,
    PaletteAllocationFailed,
    PaletteCreationFailed,
    PaletteUpdateFailed,
    SurfacePaletteFailed,
    SurfaceColorKeyFailed,
    TextureCreationFailed,
    TextureUpdateFailed,
    TextureIdPoolExhausted,
    DynamicTexturePoolExhausted,
    InvalidTextureId,
    ProtectedTexture,
    InvalidTextureRegion,
    OutOfMemory,
    NoPaletteTextureRebuilt,
    ResourceConversionFailed,
    SamplingBudgetExceeded,
    SamplingPreparationFailed,
    InvalidSourceRectangle,
};

pub fn setAllocator(
    ctx: *Instance,
    app_allocator: std.mem.Allocator,
) void {
    ctx.allocator = app_allocator;
}

pub fn assignTextureId(
    ctx: *Instance,
    texture: *sdl.SDL_Texture,
    width: u32,
    height: u32,
) ?u16 {
    const texture_id: u16 = if (ctx.state.free_texture_id_count > 0) blk: {
        ctx.state.free_texture_id_count -= 1;
        break :blk ctx.state.free_texture_ids[ctx.state.free_texture_id_count];
    } else blk: {
        if (ctx.state.next_texture_id >= t.max_texture_ids) return null;
        const id = ctx.state.next_texture_id;
        ctx.state.next_texture_id += 1;
        break :blk id;
    };
    ctx.state.texture_table[texture_id] = texture;
    ctx.state.texture_dims[texture_id] = .{
        .width = @as(f32, @floatFromInt(width)),
        .height = @as(f32, @floatFromInt(height)),
    };
    layers.invalidateTexture(ctx, texture_id, true);
    return texture_id;
}

pub fn releaseTextureId(
    ctx: *Instance,
    texture_id: u16,
) void {
    if (texture_id != 0 and texture_id < t.max_texture_ids) {
        layers.invalidateTexture(ctx, texture_id, true);
        operation.invalidateResource(ctx, texture_id);
        ctx.state.texture_table[texture_id] = null;
        ctx.state.texture_dims[texture_id] = .{};
        if (ctx.state.free_texture_id_count < t.max_texture_ids) {
            ctx.state.free_texture_ids[ctx.state.free_texture_id_count] = texture_id;
            ctx.state.free_texture_id_count += 1;
        }
    }
}

pub fn provideOperationPixels(
    ctx: *Instance,
    texture_id: u16,
    pixels: []const u8,
    pitch: usize,
) TextureError!void {
    if (ctx.state.frame_state != .idle and ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    if (texture_id == 0 or texture_id >= t.max_texture_ids)
        return error.InvalidTextureId;
    const entry = &ctx.state.operation_sources[texture_id];
    const dynamic = findDynamicTexture(ctx, texture_id);
    if (entry.exclusive or (dynamic == null and !entry.external and isIndexedTexture(ctx, texture_id)))
        return error.ProtectedTexture;
    const texture = ctx.state.texture_table[texture_id] orelse
        return error.InvalidTextureId;
    const properties = sdl.SDL_GetTextureProperties(texture);
    if (properties == 0 or
        sdl.SDL_GetNumberProperty(
            properties,
            sdl.SDL_PROP_TEXTURE_ACCESS_NUMBER,
            sdl.SDL_TEXTUREACCESS_STATIC,
        ) == sdl.SDL_TEXTUREACCESS_TARGET)
        return error.InvalidTextureId;
    const dims = ctx.state.texture_dims[texture_id];
    const width: usize = @intFromFloat(dims.width);
    const height: usize = @intFromFloat(dims.height);
    if (width == 0 or height == 0 or width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int))
        return error.InvalidDimensions;
    const row_bytes = std.math.mul(usize, width, 4) catch
        return error.InvalidDimensions;
    if (pitch < row_bytes)
        return error.InvalidPixelData;
    const length = std.math.mul(usize, pitch, height) catch
        return error.InvalidPixelData;
    if (pixels.len < length)
        return error.InvalidPixelData;
    const owned = try operation.allocate(ctx, std.math.mul(usize, row_bytes, height) catch
        return error.InvalidDimensions);
    layers.invalidateTexture(ctx, texture_id, false);
    operation.commit(ctx, texture_id, owned);
    operation.update(
        ctx,
        texture_id,
        .{
            .x = 0,
            .y = 0,
            .w = @intCast(width),
            .h = @intCast(height),
        },
        pixels,
        pitch,
    );
    ctx.state.operation_sources[texture_id].external = dynamic == null;
}

fn findDynamicTexture(
    ctx: *Instance,
    texture_id: u16,
) ?*t.DynamicTexture {
    for (&ctx.state.dynamic_textures) |*dynamic_texture| {
        if (dynamic_texture.is_initialized and dynamic_texture.texture_id == texture_id) {
            return dynamic_texture;
        }
    }
    return null;
}

pub fn destroyGraphicSlot(
    ctx: *Instance,
    graphic: *t.Graphic,
) void {
    if (graphic.surface) |surface| {
        sdl.SDL_DestroySurface(surface);
    }

    for (0..t.max_palettes) |palette_index| {
        if (graphic.textures[palette_index]) |texture| {
            sdl.SDL_DestroyTexture(texture);
        }
        if (graphic.colors[palette_index]) |colors| {
            sdl.SDL_free(colors);
        }
        releaseTextureId(ctx, graphic.texture_ids[palette_index]);
    }

    graphic.* = std.mem.zeroes(t.Graphic);
}

pub fn createRendererTextureWithAccess(
    ctx: *Instance,
    width: c_int,
    height: c_int,
    access: c_uint,
    debug_label: []const u8,
) ?*sdl.SDL_Texture {
    const texture = sdl.SDL_CreateTexture(
        ctx.context.renderer,
        sdl.SDL_PIXELFORMAT_RGBA32,
        access,
        width,
        height,
    );
    if (texture == null) {
        if (ctx.context.debug_mode) {
            log.debug("Failed to create {s} texture: {s}", .{ debug_label, sdl.SDL_GetError() });
        }
        return null;
    }
    ctx.source_stats.legacy_texture_allocations += 1;

    if (ctx.faults.check(.texture_scale) or !sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST)) {
        sdl.SDL_DestroyTexture(texture);
        return null;
    }

    if (ctx.faults.check(.texture_blend) or !sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_BLEND)) {
        sdl.SDL_DestroyTexture(texture);
        return null;
    }

    return texture;
}

fn createRendererTexture(
    ctx: *Instance,
    width: c_int,
    height: c_int,
) ?*sdl.SDL_Texture {
    return createRendererTextureWithAccess(ctx, width, height, sdl.SDL_TEXTUREACCESS_STREAMING, "dynamic");
}

pub fn layerExtent(
    ctx: *Instance,
    layer: *const t.LayerState,
) struct { width: c_int, height: c_int } {
    if (layer.canvas_mode != .legacy_rgba and layer.canvas_width != 0)
        return .{
            .width = layer.canvas_width,
            .height = layer.canvas_height,
        };
    return .{
        .width = ctx.context.logical_width,
        .height = ctx.context.logical_height,
    };
}

pub fn resizeLayerTarget(
    ctx: *Instance,
    layer_id: usize,
    width: c_int,
    height: c_int,
) TextureError!void {
    return resizeLayerTargetForMode(
        ctx,
        layer_id,
        width,
        height,
        ctx.state.layers[layer_id].canvas_mode,
    );
}

pub fn allocateLayerBacking(
    ctx: *Instance,
    backing: t.CanvasBacking,
) TextureError!*sdl.SDL_Texture {
    if (ctx.faults.check(.target_creation))
        return error.TextureCreationFailed;
    if (backing.border == 0)
        return createRendererTextureWithAccess(
            ctx,
            backing.width,
            backing.height,
            sdl.SDL_TEXTUREACCESS_TARGET,
            "layer target",
        ) orelse error.TextureCreationFailed;
    const sampling = @import("sampling.zig");
    const texture = try sampling.allocate(
        ctx,
        backing.width,
        backing.height,
    );
    errdefer sampling.destroy(
        ctx,
        texture,
        backing.width,
        backing.height,
    );
    if (ctx.faults.check(.texture_scale) or
        !sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST) or
        ctx.faults.check(.texture_blend) or
        !sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_BLEND))
        return error.TextureCreationFailed;
    return texture;
}

pub fn destroyLayerBacking(
    ctx: *Instance,
    texture: *sdl.SDL_Texture,
    backing: t.CanvasBacking,
) void {
    if (backing.border != 0)
        @import("sampling.zig").destroy(ctx, texture, backing.width, backing.height)
    else
        sdl.SDL_DestroyTexture(texture);
}

pub fn installLayerBacking(
    ctx: *Instance,
    layer_id: usize,
    texture: *sdl.SDL_Texture,
    backing: t.CanvasBacking,
) bool {
    const layer = &ctx.state.layers[layer_id];
    if (layer.target_texture_id == 0) {
        layer.target_texture_id = assignTextureId(
            ctx,
            texture,
            @intCast(backing.width),
            @intCast(backing.height),
        ) orelse return false;
    } else {
        const previous = ctx.state.texture_table[layer.target_texture_id];
        ctx.state.texture_table[layer.target_texture_id] = texture;
        ctx.state.texture_dims[layer.target_texture_id] = .{
            .width = @floatFromInt(backing.width),
            .height = @floatFromInt(backing.height),
        };
        layers.invalidateTexture(
            ctx,
            layer.target_texture_id,
            true,
        );
        if (previous) |handle|
            destroyLayerBacking(
                ctx,
                handle,
                layer.backing,
            );
    }
    layer.backing = backing;
    ctx.state.layer_masks.set(.padded_backing, layer_id, backing.border != 0);
    ctx.state.layer_masks.set(.target_dirty, layer_id, true);
    ctx.canvas_stats.target_allocations += 1;
    return true;
}

pub fn resizeLayerTargetForMode(
    ctx: *Instance,
    layer_id: usize,
    width: c_int,
    height: c_int,
    mode: t.CanvasMode,
) TextureError!void {
    if (width <= 0 or height <= 0 or width > 65535 or height > 65535)
        return error.InvalidDimensions;
    _ = std.math.mul(usize, @as(usize, @intCast(width)) * 4, @intCast(height)) catch
        return error.InvalidDimensions;
    if (ctx.context.renderer) |renderer| {
        const limit = sdl.SDL_GetNumberProperty(
            sdl.SDL_GetRendererProperties(renderer),
            sdl.SDL_PROP_RENDERER_MAX_TEXTURE_SIZE_NUMBER,
            0,
        );
        if (limit > 0 and (width > limit or height > limit))
            return error.InvalidDimensions;
    }
    const layer = &ctx.state.layers[layer_id];
    const texture_id = layer.target_texture_id;
    if (texture_id == 0) return;
    const same_extent = layer.backing.width - 2 * @as(c_int, layer.backing.border) == width and
        layer.backing.height - 2 * @as(c_int, layer.backing.border) == height;
    const border: u8 = if (mode == .legacy_rgba)
        0
    else if (same_extent)
        layer.backing.border
    else if (layer.sampling == .bilinear)
        1
    else
        0;
    const backing = t.CanvasBacking{
        .width = width + 2 * @as(c_int, border),
        .height = height + 2 * @as(c_int, border),
        .border = border,
    };
    if (std.meta.eql(backing, layer.backing)) return;
    const replacement = try allocateLayerBacking(ctx, backing);
    if (!installLayerBacking(ctx, layer_id, replacement, backing)) {
        destroyLayerBacking(ctx, replacement, backing);
        return error.TextureIdPoolExhausted;
    }
}

pub fn ensureLayerTarget(ctx: *Instance, layer_id: usize) bool {
    if (ctx.context.renderer == null) return false;
    if (ctx.context.logical_width <= 0 or ctx.context.logical_height <= 0) return false;
    if (layer_id >= t.max_layers) return false;

    const layer = &ctx.state.layers[layer_id];
    const extent = layerExtent(ctx, layer);
    if (layer.target_texture_id != 0) {
        resizeLayerTarget(ctx, layer_id, extent.width, extent.height) catch return false;
        return true;
    }

    const border: u8 = if (layer.canvas_mode != .legacy_rgba and layer.sampling == .bilinear) 1 else 0;
    const backing = t.CanvasBacking{
        .width = std.math.add(c_int, extent.width, 2 * @as(c_int, border)) catch return false,
        .height = std.math.add(c_int, extent.height, 2 * @as(c_int, border)) catch return false,
        .border = border,
    };
    const texture = allocateLayerBacking(ctx, backing) catch return false;
    if (installLayerBacking(ctx, layer_id, texture, backing)) return true;
    destroyLayerBacking(ctx, texture, backing);
    return false;
}

pub fn destroyLayerTargets(ctx: *Instance) void {
    for (&ctx.state.layers, 0..) |*layer, layer_id| {
        if (layer.target_texture_id == 0) continue;

        if (ctx.state.texture_table[layer.target_texture_id]) |texture| {
            destroyLayerBacking(ctx, texture, layer.backing);
        }
        releaseTextureId(ctx, layer.target_texture_id);
        layer.target_texture_id = 0;
        layer.backing = .{};
        ctx.state.layer_masks.set(.padded_backing, layer_id, false);
        ctx.state.layer_masks.set(.target_dirty, layer_id, false);
    }
}

pub fn destroyLogicalLayerTargets(ctx: *Instance) void {
    for (&ctx.state.layers, 0..) |*layer, layer_id| {
        if (layer.canvas_mode != .legacy_rgba and layer.canvas_width != 0) continue;
        if (layer.target_texture_id == 0) continue;
        if (ctx.state.texture_table[layer.target_texture_id]) |texture|
            destroyLayerBacking(ctx, texture, layer.backing);
        releaseTextureId(ctx, layer.target_texture_id);
        layer.target_texture_id = 0;
        layer.backing = .{};
        ctx.state.layer_masks.set(.padded_backing, layer_id, false);
        ctx.state.layer_masks.set(.target_dirty, layer_id, true);
    }
    ctx.frame_ready = false;
    ctx.changes.present_needed = true;
}

pub fn createWhiteTexture(ctx: *Instance) void {
    const texture_id = createDynamicTexture(ctx, 1, 1) catch |err| {
        if (ctx.context.debug_mode) {
            log.debug("ERROR: Failed to create white fill texture: {s}", .{@errorName(err)});
        }
        return;
    };

    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    updateDynamicTexture(ctx, texture_id, 0, 0, 1, 1, white_pixel[0..], 4) catch |err| {
        if (ctx.context.debug_mode) {
            log.debug("ERROR: Failed to initialize white fill texture: {s}", .{@errorName(err)});
        }
        destroyDynamicTexture(ctx, texture_id) catch {};
        return;
    };

    ctx.state.white_texture_id = texture_id;
}

pub const OperationTextureMode = enum { shared, operation_only };

pub fn createDynamicTexture(ctx: *Instance, width: c_int, height: c_int) TextureError!u16 {
    return createDynamicTextureImpl(ctx, width, height, null);
}

pub fn createOperationDynamicTexture(
    ctx: *Instance,
    width: c_int,
    height: c_int,
    mode: OperationTextureMode,
) TextureError!u16 {
    return createDynamicTextureImpl(ctx, width, height, mode); // Fix this...
}

fn createDynamicTextureImpl(
    ctx: *Instance,
    width: c_int,
    height: c_int,
    mode: ?OperationTextureMode,
) TextureError!u16 {
    if (ctx.state.frame_state != .idle) {
        if (ctx.context.debug_mode) {
            log.debug(
                "ERROR: createDynamicTexture called during {s} (only allowed during idle)",
                .{@tagName(ctx.state.frame_state)},
            );
        }
        return error.WrongFrameState;
    }

    if (ctx.context.renderer == null)
        return error.RendererUnavailable;
    if (width <= 0 or height <= 0)
        return error.InvalidDimensions;

    var free_slot: ?*t.DynamicTexture = null;
    for (&ctx.state.dynamic_textures) |*dynamic_texture| {
        if (!dynamic_texture.is_initialized) {
            free_slot = dynamic_texture;
            break;
        }
    }
    if (free_slot == null)
        return error.DynamicTexturePoolExhausted;
    const texture = createRendererTexture(ctx, width, height) orelse
        return error.TextureCreationFailed;
    errdefer sdl.SDL_DestroyTexture(texture);

    const width_usize: usize = @intCast(width);
    const height_usize: usize = @intCast(height);
    const bytes_per_row = std.math.mul(usize, width_usize, 4) catch
        return error.InvalidDimensions;
    const clear_len = std.math.mul(usize, bytes_per_row, height_usize) catch
        return error.InvalidDimensions;
    const exclusive = mode != null and mode.? == .operation_only;
    const clear_pixels = if (mode != null) try operation.allocate(ctx, clear_len) else ctx.allocator.alloc(u8, clear_len) catch
        return error.OutOfMemory;
    errdefer ctx.allocator.free(clear_pixels);
    @memset(clear_pixels, 0);

    if (!exclusive and !sdl.SDL_UpdateTexture(texture, null, clear_pixels.ptr, @intCast(bytes_per_row))) {
        if (ctx.context.debug_mode) {
            log.debug(
                "Failed to clear dynamic texture: {s}",
                .{sdl.SDL_GetError()},
            );
        }
        return error.TextureUpdateFailed;
    }

    const texture_id = assignTextureId(ctx, texture, @intCast(width), @intCast(height)) orelse
        return error.TextureIdPoolExhausted;
    if (mode != null) {
        operation.commit(ctx, texture_id, clear_pixels);
        ctx.state.operation_sources[texture_id].exclusive = exclusive;
    } else ctx.allocator.free(clear_pixels);
    if (!exclusive) ctx.source_stats.legacy_uploaded_bytes += clear_len;

    free_slot.?.* = .{
        .texture = texture,
        .texture_id = texture_id,
        .width = @intCast(width),
        .height = @intCast(height),
        .is_initialized = true,
    };

    if (ctx.context.debug_mode) {
        log.debug(
            "Created dynamic texture {d}: {d}x{d}",
            .{ texture_id, width, height },
        );
    }

    return texture_id;
}

pub fn destroyDynamicTexture(ctx: *Instance, texture_id: u16) TextureError!void {
    if (ctx.state.frame_state != .idle) {
        if (ctx.context.debug_mode) {
            log.debug(
                "ERROR: destroyDynamicTexture called during {s} (only allowed during idle)",
                .{@tagName(ctx.state.frame_state)},
            );
        }
        return error.WrongFrameState;
    }

    if (texture_id == 0) return error.InvalidTextureId;
    if (texture_id == ctx.state.white_texture_id) return error.ProtectedTexture;

    const dynamic_texture = findDynamicTexture(ctx, texture_id) orelse return error.InvalidTextureId;
    if (dynamic_texture.texture) |texture| {
        sdl.SDL_DestroyTexture(texture);
    }

    releaseTextureId(ctx, texture_id);
    dynamic_texture.* = .{};
}

pub fn updateDynamicTexture(
    ctx: *Instance,
    texture_id: u16,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    pixels: []const u8,
    pitch: c_int,
) TextureError!void {
    if (ctx.state.frame_state != .idle and ctx.state.frame_state != .updating) {
        if (ctx.context.debug_mode) {
            log.debug(
                "ERROR: updateDynamicTexture called during {s}",
                .{@tagName(ctx.state.frame_state)},
            );
        }
        return error.WrongFrameState;
    }

    if (width <= 0 or height <= 0)
        return error.InvalidDimensions;
    if (pitch <= 0)
        return error.InvalidSurfacePitch;

    const dynamic_texture = findDynamicTexture(ctx, texture_id) orelse
        return error.InvalidTextureId;
    const texture = dynamic_texture.texture orelse
        return error.InvalidTextureId;

    if (x < 0 or y < 0) return error.InvalidTextureRegion;

    const x_u: u32 = @intCast(x);
    const y_u: u32 = @intCast(y);
    const width_u: u32 = @intCast(width);
    const height_u: u32 = @intCast(height);
    if (x_u + width_u > dynamic_texture.width or y_u + height_u > dynamic_texture.height)
        return error.InvalidTextureRegion;

    const pitch_usize: usize = @intCast(pitch);
    if (pitch_usize < @as(usize, @intCast(width)) * 4)
        return error.InvalidSurfacePitch;
    const height_usize: usize = @intCast(height);
    const required_len = std.math.mul(usize, pitch_usize, height_usize) catch
        return error.InvalidPixelData;
    if (pixels.len < required_len)
        return error.InvalidPixelData;

    const rect = sdl.SDL_Rect{
        .x = x,
        .y = y,
        .w = width,
        .h = height,
    };

    layers.invalidateTexture(ctx, texture_id, false);
    const source_entry = &ctx.state.operation_sources[texture_id];
    if (source_entry.exclusive) {
        operation.update(ctx, texture_id, rect, pixels, pitch_usize);
        return;
    }
    if (ctx.faults.check(.texture_upload) or !sdl.SDL_UpdateTexture(texture, &rect, pixels.ptr, pitch)) {
        const entry = &ctx.state.operation_sources[texture_id];
        if (entry.uncertain) |old| {
            const left = @min(old.x, rect.x);
            const top = @min(old.y, rect.y);
            entry.uncertain = .{
                .x = left,
                .y = top,
                .w = @max(old.x + old.w, rect.x + rect.w) - left,
                .h = @max(old.y + old.h, rect.y + rect.h) - top,
            };
        } else entry.uncertain = rect;
        if (ctx.context.debug_mode) {
            log.debug(
                "Failed to update dynamic texture {d}: {s}",
                .{ texture_id, sdl.SDL_GetError() },
            );
        }
        return error.TextureUpdateFailed;
    }
    operation.update(ctx, texture_id, rect, pixels, pitch_usize);
    if (texture_id == ctx.state.white_texture_id and source_entry.pixels == null)
        source_entry.stale = pixels[3] != 255;
    ctx.source_stats.legacy_uploaded_bytes += @as(usize, @intCast(width)) * height_usize * 4;
}

pub fn addGraphics8Bit(
    ctx: *Instance,
    graphic_index: usize,
    data: []const u8,
    transparent_key: c_int,
    rgba: []const u8,
    w: c_int,
    h: c_int,
    ncolors: c_int,
) TextureError!void {
    if (ctx.state.frame_state != .idle) {
        if (ctx.context.debug_mode) {
            log.debug(
                "ERROR: addGraphics8Bit called during {s} (only allowed during idle)",
                .{@tagName(ctx.state.frame_state)},
            );
        }
        return error.WrongFrameState;
    }

    if (graphic_index >= t.max_graphics) return error.InvalidGraphicIndex;
    if (ctx.context.renderer == null) return error.RendererUnavailable;
    if (w <= 0 or h <= 0) return error.InvalidDimensions;
    if (ncolors <= 0 or ncolors > 256) return error.InvalidPaletteSize;

    const w_usize: usize = @intCast(w);
    const h_usize: usize = @intCast(h);
    const expected_size = w_usize * h_usize;
    if (data.len < expected_size) return error.InvalidPixelData;

    const ncolors_usize: usize = @intCast(ncolors);
    const expected_palette_size = ncolors_usize * 3;
    if (rgba.len < expected_palette_size) return error.InvalidPaletteSize;

    var graphic = &ctx.state.graphics[graphic_index];
    destroyGraphicSlot(ctx, graphic);

    graphic.surface = sdl.SDL_CreateSurface(
        w,
        h,
        sdl.SDL_PIXELFORMAT_INDEX8,
    );

    if (graphic.surface == null) {
        if (ctx.context.debug_mode) {
            log.debug(
                "Failed to create surface: {s}",
                .{sdl.SDL_GetError()},
            );
        }
        return error.SurfaceCreationFailed;
    }
    errdefer {
        if (graphic.surface) |surface| sdl.SDL_DestroySurface(surface);
        graphic.surface = null;
        graphic.is_initialized = false;
        graphic.is_indexed = false;
    }

    const surf = graphic.surface.?;
    const dst_ptr = @as([*]u8, @ptrCast(surf.pixels));
    const pitch_usize: usize = @intCast(surf.pitch);

    if (pitch_usize < w_usize) {
        return error.InvalidSurfacePitch;
    }

    const dst = dst_ptr[0 .. pitch_usize * h_usize];
    for (0..h_usize) |y| {
        const dst_row = dst[y * pitch_usize .. y * pitch_usize + w_usize];
        const src_row = data[y * w_usize .. y * w_usize + w_usize];
        @memcpy(dst_row, src_row);
    }

    graphic.is_indexed = true;
    graphic.is_initialized = true;

    try addPalette(
        ctx,
        graphic_index,
        0,
        transparent_key,
        rgba,
        ncolors,
    );

    if (ctx.context.debug_mode) {
        log.debug(
            "Added 8-bit graphic {d}: {d}x{d}, {d} colors",
            .{ graphic_index, w, h, ncolors },
        );
    }
}

pub fn addPalette(
    ctx: *Instance,
    graphic_index: usize,
    palette_index: usize,
    transparent_key: c_int,
    rgba: []const u8,
    ncolors: c_int,
) TextureError!void {
    if (ctx.state.frame_state != .idle) {
        if (ctx.context.debug_mode) {
            log.debug(
                "ERROR: addPalette called during {s} (only allowed during idle)",
                .{@tagName(ctx.state.frame_state)},
            );
        }
        return error.WrongFrameState;
    }

    if (graphic_index >= t.max_graphics) return error.InvalidGraphicIndex;
    if (palette_index >= t.max_palettes) return error.InvalidPaletteIndex;
    if (ctx.context.renderer == null) return error.RendererUnavailable;

    var graphic = &ctx.state.graphics[graphic_index];
    if (!graphic.is_initialized or graphic.surface == null) return error.GraphicUnavailable;
    if (ncolors <= 0 or ncolors > 256) return error.InvalidPaletteSize;

    const ncolors_usize: usize = @intCast(ncolors);
    const expected_palette_size = ncolors_usize * 3;
    if (rgba.len < expected_palette_size) return error.InvalidPaletteSize;

    const old_tid = graphic.texture_ids[palette_index];

    const num_colors: usize = ncolors_usize;
    if (ctx.faults.check(.palette_allocation)) return error.PaletteAllocationFailed;
    const colors = sdl.SDL_malloc(@intCast(num_colors * @sizeOf(sdl.SDL_Color)));
    if (colors == null) return error.PaletteAllocationFailed;
    errdefer sdl.SDL_free(colors);

    const color_array = @as([*]sdl.SDL_Color, @ptrCast(@alignCast(colors)));
    for (0..num_colors) |i| {
        color_array[i].r = rgba[i * 3];
        color_array[i].g = rgba[i * 3 + 1];
        color_array[i].b = rgba[i * 3 + 2];
        color_array[i].a = 255;
    }

    if (ctx.faults.check(.palette_creation)) return error.PaletteCreationFailed;
    const palette = sdl.SDL_CreatePalette(ncolors);
    if (palette == null) {
        if (ctx.context.debug_mode) {
            log.debug(
                "Failed to create palette: {s}",
                .{sdl.SDL_GetError()},
            );
        }
        return error.PaletteCreationFailed;
    }
    defer sdl.SDL_DestroyPalette(palette);

    if (ctx.faults.check(.palette_colors) or !sdl.SDL_SetPaletteColors(palette, color_array, 0, ncolors)) {
        if (ctx.context.debug_mode) {
            log.debug(
                "Failed to set palette colors: {s}",
                .{sdl.SDL_GetError()},
            );
        }
        return error.PaletteUpdateFailed;
    }

    if (ctx.faults.check(.surface_palette) or !sdl.SDL_SetSurfacePalette(graphic.surface, palette)) {
        if (ctx.context.debug_mode) {
            log.debug(
                "Failed to set surface palette: {s}",
                .{sdl.SDL_GetError()},
            );
        }
        return error.SurfacePaletteFailed;
    }
    defer _ = sdl.SDL_SetSurfacePalette(graphic.surface, null);
    var previous_key: u32 = 0;
    const had_key = sdl.SDL_GetSurfaceColorKey(graphic.surface, &previous_key);
    errdefer _ = sdl.SDL_SetSurfaceColorKey(graphic.surface, had_key, previous_key);

    const valid_key = transparent_key >= 0 and transparent_key < ncolors;
    if (!sdl.SDL_SetSurfaceColorKey(
        graphic.surface,
        valid_key,
        if (valid_key) @intCast(transparent_key) else 0,
    )) {
        return error.SurfaceColorKeyFailed;
    }

    if (ctx.faults.check(.texture_creation)) return error.TextureCreationFailed;
    const texture = sdl.SDL_CreateTextureFromSurface(
        ctx.context.renderer,
        graphic.surface,
    );
    if (texture == null) {
        if (ctx.context.debug_mode) {
            log.debug("Failed to create texture: {s}", .{sdl.SDL_GetError()});
        }
        return error.TextureCreationFailed;
    }
    errdefer sdl.SDL_DestroyTexture(texture);

    if (ctx.faults.check(.texture_scale) or !sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST))
        return error.TextureUpdateFailed;
    ctx.source_stats.legacy_texture_allocations += 1;
    ctx.source_stats.legacy_uploaded_bytes +=
        @as(usize, @intCast(graphic.surface.?.w)) * @as(usize, @intCast(graphic.surface.?.h)) * 4;

    const surface = graphic.surface.?;
    const source_pixels = if (old_tid != 0 and ctx.state.operation_sources[old_tid].pixels != null)
        try operation.prepareSurface(ctx, surface)
    else
        null;
    errdefer if (source_pixels) |owned| ctx.allocator.free(owned);
    const tid = if (old_tid != 0)
        old_tid
    else
        assignTextureId(
            ctx,
            texture,
            @intCast(surface.w),
            @intCast(surface.h),
        ) orelse {
            if (ctx.context.debug_mode) {
                log.debug(
                    "ERROR: Texture ID pool exhausted adding palette {d} to graphic {d}",
                    .{
                        palette_index,
                        graphic_index,
                    },
                );
            }
            return error.TextureIdPoolExhausted;
        };
    if (graphic.textures[palette_index]) |old_tex| sdl.SDL_DestroyTexture(old_tex);
    if (graphic.colors[palette_index]) |old_colors| sdl.SDL_free(old_colors);
    graphic.textures[palette_index] = texture;
    ctx.state.texture_table[tid] = texture;
    graphic.texture_ids[palette_index] = tid;

    graphic.colors[palette_index] = color_array;
    graphic.flags[palette_index] = true;
    graphic.ncolors[palette_index] = @intCast(ncolors);
    layers.invalidateTexture(ctx, tid, false);
    if (source_pixels) |owned| operation.commit(ctx, tid, owned);
    ctx.state.operation_sources[tid].palette_key = if (valid_key) @intCast(transparent_key) else -1;

    if (palette_index >= graphic.palette_count) {
        graphic.palette_count = @intCast(palette_index + 1);
    }

    if (ctx.context.debug_mode) {
        log.debug(
            "Added palette {d} to graphic {d}: {d} colors (TexID: {d})",
            .{ palette_index, graphic_index, ncolors, graphic.texture_ids[palette_index] },
        );
    }
}

const PreparedPalette = struct { texture: *sdl.SDL_Texture, pixels: ?[]u8 };

fn prepareGraphicPaletteTexture(
    ctx: *Instance,
    graphic: *const t.Graphic,
    surface: *sdl.SDL_Surface,
    palette_index: usize,
) TextureError!PreparedPalette {
    const colors = graphic.colors[palette_index] orelse return error.GraphicUnavailable;
    const ncolors: c_int = @intCast(graphic.ncolors[palette_index]);
    if (ncolors <= 0) return error.InvalidPaletteSize;
    const renderer = ctx.context.renderer orelse return error.RendererUnavailable;

    if (ctx.faults.check(.palette_creation)) return error.PaletteCreationFailed;
    const palette = sdl.SDL_CreatePalette(ncolors) orelse return error.PaletteCreationFailed;
    defer sdl.SDL_DestroyPalette(palette);

    if (ctx.faults.check(.palette_colors) or !sdl.SDL_SetPaletteColors(palette, colors, 0, ncolors))
        return error.PaletteUpdateFailed;
    if (ctx.faults.check(.surface_palette) or !sdl.SDL_SetSurfacePalette(surface, palette))
        return error.SurfacePaletteFailed;
    defer _ = sdl.SDL_SetSurfacePalette(surface, null);
    if (ctx.faults.check(.texture_creation)) return error.TextureCreationFailed;
    const texture = sdl.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureCreationFailed;
    ctx.source_stats.legacy_texture_allocations += 1;
    ctx.source_stats.legacy_uploaded_bytes += @as(usize, @intCast(surface.w)) * @as(usize, @intCast(surface.h)) * 4;
    errdefer sdl.SDL_DestroyTexture(texture);
    if (ctx.faults.check(.texture_scale) or !sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST))
        return error.TextureUpdateFailed;
    const pixels = if (ctx.state.operation_sources[graphic.texture_ids[palette_index]].pixels != null)
        try operation.prepareSurface(ctx, surface)
    else
        null;
    return .{ .texture = texture, .pixels = pixels };
}

/// Prepares indexed pixels and all attached palette textures before committing
/// them together. Full-surface refresh is fine for small
/// sprites; larger canvases should move toward dirty rects or direct texture
/// uploads instead of rebuilding all palette variants each edit.
pub fn updateGraphics8BitPixels(
    ctx: *Instance,
    graphic_index: usize,
    data: []const u8,
    w: c_int,
    h: c_int,
) TextureError!void {
    if (ctx.state.frame_state != .idle and ctx.state.frame_state != .updating) {
        if (ctx.context.debug_mode) {
            log.debug(
                "ERROR: updateGraphics8BitPixels called during {s}",
                .{@tagName(ctx.state.frame_state)},
            );
        }
        return error.WrongFrameState;
    }

    if (graphic_index >= t.max_graphics)
        return error.InvalidGraphicIndex;
    const graphic = &ctx.state.graphics[graphic_index];
    if (!graphic.is_initialized or !graphic.is_indexed or graphic.surface == null)
        return error.GraphicUnavailable;
    if (w <= 0 or h <= 0)
        return error.InvalidDimensions;

    const surf = graphic.surface.?;
    if (surf.w != w or surf.h != h)
        return error.InvalidDimensions;

    const w_usize: usize = @intCast(w);
    const h_usize: usize = @intCast(h);
    if (data.len < w_usize * h_usize)
        return error.InvalidPixelData;

    if (ctx.faults.check(.surface_creation))
        return error.SurfaceCreationFailed;
    const replacement: *sdl.SDL_Surface = sdl.SDL_CreateSurface(w, h, sdl.SDL_PIXELFORMAT_INDEX8) orelse
        return error.SurfaceCreationFailed;
    errdefer sdl.SDL_DestroySurface(replacement);
    var color_key: u32 = 0;
    if (sdl.SDL_GetSurfaceColorKey(surf, &color_key)) {
        if (!sdl.SDL_SetSurfaceColorKey(replacement, true, color_key))
            return error.SurfaceColorKeyFailed;
    }
    const dst_ptr = @as([*]u8, @ptrCast(replacement.pixels));
    const pitch_usize: usize = @intCast(replacement.pitch);
    if (pitch_usize < w_usize)
        return error.InvalidSurfacePitch;
    const dst = dst_ptr[0 .. pitch_usize * h_usize];

    for (0..h_usize) |y| {
        const dst_row = dst[y * pitch_usize .. y * pitch_usize + w_usize];
        const src_row = data[y * w_usize .. y * w_usize + w_usize];
        @memcpy(dst_row, src_row);
    }

    var prepared: [t.max_palettes]?PreparedPalette = @splat(null);
    defer for (prepared) |item| {
        if (item) |value| {
            sdl.SDL_DestroyTexture(value.texture);
            if (value.pixels) |owned| ctx.allocator.free(owned);
        }
    };
    var rebuilt = false;
    for (0..t.max_palettes) |palette_index| {
        if (!graphic.flags[palette_index]) continue;
        if (graphic.texture_ids[palette_index] == 0)
            return error.GraphicUnavailable;
        prepared[palette_index] = try prepareGraphicPaletteTexture(ctx, graphic, replacement, palette_index);
        rebuilt = true;
    }

    if (!rebuilt)
        return error.NoPaletteTextureRebuilt;
    for (&prepared, 0..) |*texture, palette_index| {
        const item = texture.* orelse continue;
        const handle = item.texture;
        const tid = graphic.texture_ids[palette_index];
        if (graphic.textures[palette_index]) |old| sdl.SDL_DestroyTexture(old);
        graphic.textures[palette_index] = handle;
        ctx.state.texture_table[tid] = handle;
        texture.* = null;
        layers.invalidateTexture(ctx, tid, false);
        if (item.pixels) |owned| operation.commit(ctx, tid, owned);
        ctx.state.operation_sources[tid].palette_key = if (sdl.SDL_GetSurfaceColorKey(
            replacement,
            &color_key,
        ))
            @intCast(color_key)
        else
            -1;
    }
    graphic.surface = replacement;
    sdl.SDL_DestroySurface(surf);
}
