const std = @import("std");
const Instance = @import("root.zig").Instance;
const sdl = @import("sdl").sdl;
const types = @import("types.zig");
const Error = @import("compositor.zig").RenderError;
const textures = @import("textures.zig");
const layers = @import("layers.zig");

pub const max_source_views = 256;
pub const max_view_bytes = 64 * 1024 * 1024;
pub const View = struct {
    texture_id: u16 = 0,
    rectangle: sdl.SDL_Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    texture: ?*sdl.SDL_Texture = null,
    dirty: ?sdl.SDL_Rect = null,
    last_used: u64 = 0,
};
pub const Cache = struct {
    views: ?[]View = null,
    texture_bytes: usize = 0,
    clock: u64 = 0,
};
pub const Stats = struct {
    cpu_allocations: usize = 0,
    retained_cpu_bytes: usize = 0,
    texture_allocations: usize = 0,
    peak_texture_bytes: usize = 0,
    copy_calls: usize = 0,
    copied_bytes: usize = 0,
};
pub const Scope = struct {
    texture: *sdl.SDL_Texture,
    scale: sdl.SDL_ScaleMode,
    horizontal: sdl.SDL_TextureAddressMode,
    vertical: sdl.SDL_TextureAddressMode,
    scale_changed: bool = false,
    address_changed: bool = false,
};

pub fn setSource(
    ctx: *Instance,
    texture_id: u16,
    filter: types.Sampling,
    address: types.Addressing,
) textures.TextureError!void {
    if (ctx.state.frame_state != .idle and ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    if (texture_id == 0 or
        texture_id >= types.max_texture_ids or
        ctx.state.texture_table[texture_id] == null)
        return error.InvalidTextureId;
    const source = &ctx.state.operation_sources[texture_id];
    if (source.filter == filter and source.addressing == address) return;
    source.filter = filter;
    source.addressing = address;
    layers.invalidateOperationReferences(ctx, texture_id);
}

pub fn begin(
    ctx: *Instance,
    texture: *sdl.SDL_Texture,
    filter: types.Sampling,
    address: types.Addressing,
) Error!Scope {
    var scope: Scope = .{
        .texture = texture,
        .scale = undefined,
        .horizontal = undefined,
        .vertical = undefined,
    };
    if (!sdl.SDL_GetTextureScaleMode(texture, &scope.scale) or
        !sdl.SDL_GetRenderTextureAddressMode(ctx.context.renderer, &scope.horizontal, &scope.vertical))
        return error.TextureStateFailed;
    errdefer end(ctx, scope) catch {};
    const mode = if (address == .repeat) sdl.SDL_TEXTURE_ADDRESS_WRAP else sdl.SDL_TEXTURE_ADDRESS_CLAMP;
    if (address == .repeat and !sdl.SDL_GetBooleanProperty(
        sdl.SDL_GetRendererProperties(ctx.context.renderer),
        sdl.SDL_PROP_RENDERER_TEXTURE_WRAPPING_BOOLEAN,
        false,
    ))
        return error.TextureStateFailed;
    if (ctx.faults.check(.sampling_state)) return error.TextureStateFailed;
    const scale = if (filter == .bilinear) sdl.SDL_SCALEMODE_LINEAR else sdl.SDL_SCALEMODE_NEAREST;
    if (scope.scale != scale) {
        if (!sdl.SDL_SetTextureScaleMode(texture, scale))
            return error.TextureStateFailed;
        scope.scale_changed = true;
    }
    if (scope.horizontal != mode or scope.vertical != mode) {
        if (ctx.faults.check(.sampling_address_state) or !sdl.SDL_SetRenderTextureAddressMode(ctx.context.renderer, mode, mode))
            return error.TextureStateFailed;
        scope.address_changed = true;
    }
    return scope;
}

pub fn end(
    ctx: *Instance,
    scope: Scope,
) Error!void {
    var success = !ctx.faults.check(.sampling_restore);
    if (scope.scale_changed)
        success = sdl.SDL_SetTextureScaleMode(
            scope.texture,
            scope.scale,
        ) and success;
    if (scope.address_changed)
        success = sdl.SDL_SetRenderTextureAddressMode(
            ctx.context.renderer,
            scope.horizontal,
            scope.vertical,
        ) and success;
    if (!success) return error.TextureStateFailed;
}

fn size(
    width: c_int,
    height: c_int,
) usize {
    return @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
}

pub fn allocate(
    ctx: *Instance,
    width: c_int,
    height: c_int,
) error{
    InvalidSourceRectangle,
    SamplingPreparationFailed,
    SamplingBudgetExceeded,
}!*sdl.SDL_Texture {
    if (width <= 0 or height <= 0)
        return error.InvalidSourceRectangle;
    const limit = sdl.SDL_GetNumberProperty(
        sdl.SDL_GetRendererProperties(ctx.context.renderer),
        sdl.SDL_PROP_RENDERER_MAX_TEXTURE_SIZE_NUMBER,
        0,
    );
    if (limit > 0 and (width > limit or height > limit))
        return error.SamplingPreparationFailed;
    const bytes = std.math.mul(
        usize,
        @as(usize, @intCast(width)),
        @as(usize, @intCast(height)),
    ) catch
        return error.SamplingBudgetExceeded;
    if (bytes > max_view_bytes / 4)
        return error.SamplingBudgetExceeded;
    while (bytes * 4 > max_view_bytes - ctx.sampling_cache.texture_bytes) {
        const victim = oldest(ctx) orelse
            return error.SamplingBudgetExceeded;
        dropView(ctx, victim);
    }
    if (ctx.faults.check(.sampling_target_creation))
        return error.SamplingPreparationFailed;
    const texture = sdl.SDL_CreateTexture(
        ctx.context.renderer,
        sdl.SDL_PIXELFORMAT_RGBA32,
        sdl.SDL_TEXTUREACCESS_TARGET,
        width,
        height,
    ) orelse return error.SamplingPreparationFailed;
    ctx.sampling_cache.texture_bytes += bytes * 4;
    ctx.sampling_stats.texture_allocations += 1;
    ctx.sampling_stats.peak_texture_bytes = @max(
        ctx.sampling_stats.peak_texture_bytes,
        ctx.sampling_cache.texture_bytes,
    );
    return texture;
}

pub fn destroy(
    ctx: *Instance,
    texture: *sdl.SDL_Texture,
    width: c_int,
    height: c_int,
) void {
    sdl.SDL_DestroyTexture(texture);
    ctx.sampling_cache.texture_bytes -= size(width, height);
}

fn oldest(ctx: *Instance) ?*View {
    var victim: ?*View = null;
    if (ctx.sampling_cache.views) |views| for (views) |*view| {
        if (view.texture == null) continue;
        if (victim == null or
            ctx.sampling_cache.clock -% view.last_used >
                ctx.sampling_cache.clock -% victim.?.last_used)
            victim = view;
    };
    return victim;
}

fn dropView(
    ctx: *Instance,
    view: *View,
) void {
    if (view.texture) |texture|
        destroy(
            ctx,
            texture,
            view.rectangle.w,
            view.rectangle.h,
        );
    view.* = .{};
}

pub fn dropSource(
    ctx: *Instance,
    texture_id: u16,
) void {
    if (ctx.sampling_cache.views) |views| for (views) |*view| {
        if (view.texture_id != texture_id) continue;
        dropView(ctx, view);
    };
}

pub fn deinit(ctx: *Instance) void {
    if (ctx.sampling_cache.views) |views| {
        for (views) |view| if (view.texture) |texture| destroy(
            ctx,
            texture,
            view.rectangle.w,
            view.rectangle.h,
        );
        ctx.allocator.free(views);
    }
    ctx.sampling_cache = .{};
    ctx.sampling_stats.retained_cpu_bytes = 0;
}

fn unionRect(
    previous: ?sdl.SDL_Rect,
    rectangle: sdl.SDL_Rect,
) sdl.SDL_Rect {
    const old = previous orelse return rectangle;
    const left = @min(old.x, rectangle.x);
    const top = @min(old.y, rectangle.y);
    return .{
        .x = left,
        .y = top,
        .w = @max(old.x + old.w, rectangle.x + rectangle.w) - left,
        .h = @max(old.y + old.h, rectangle.y + rectangle.h) - top,
    };
}

pub fn dirtySource(
    ctx: *Instance,
    texture_id: u16,
    changed: ?sdl.SDL_Rect,
) void {
    if (ctx.sampling_cache.views) |views| for (views) |*view| {
        if (view.texture_id != texture_id) continue;
        const rectangle = view.rectangle;
        const update = changed orelse rectangle;
        const left = @max(rectangle.x, update.x);
        const top = @max(rectangle.y, update.y);
        const right = @min(rectangle.x + rectangle.w, update.x + update.w);
        const bottom = @min(rectangle.y + rectangle.h, update.y + update.h);
        if (right > left and bottom > top)
            view.dirty = unionRect(view.dirty, .{
                .x = left - rectangle.x,
                .y = top - rectangle.y,
                .w = right - left,
                .h = bottom - top,
            });
    };
}

const CopyState = struct {
    target: ?*sdl.SDL_Texture,
    viewport: sdl.SDL_Rect,
    viewport_set: bool,
    clip: sdl.SDL_Rect,
    clip_enabled: bool,
    scale_x: f32,
    scale_y: f32,
    color: [4]u8,
    source: *sdl.SDL_Texture,
    blend: sdl.SDL_BlendMode,
    modulation: [4]u8,
    scope: Scope,
};

fn restore(
    ctx: *Instance,
    state: CopyState,
) Error!void {
    var success = sdl.SDL_SetRenderTarget(
        ctx.context.renderer,
        state.target,
    );
    success = sdl.SDL_SetRenderScale(
        ctx.context.renderer,
        state.scale_x,
        state.scale_y,
    ) and success;
    success = sdl.SDL_SetRenderViewport(
        ctx.context.renderer,
        if (state.viewport_set) &state.viewport else null,
    ) and success;
    success = sdl.SDL_SetRenderClipRect(
        ctx.context.renderer,
        if (state.clip_enabled) &state.clip else null,
    ) and success;
    success = sdl.SDL_SetRenderDrawColor(
        ctx.context.renderer,
        state.color[0],
        state.color[1],
        state.color[2],
        state.color[3],
    ) and success;
    success = sdl.SDL_SetTextureBlendMode(
        state.source,
        state.blend,
    ) and success;
    success = sdl.SDL_SetTextureColorMod(
        state.source,
        state.modulation[0],
        state.modulation[1],
        state.modulation[2],
    ) and success;
    success = sdl.SDL_SetTextureAlphaMod(
        state.source,
        state.modulation[3],
    ) and success;
    end(ctx, state.scope) catch {
        success = false;
    };
    if (!success) return error.TextureStateFailed;
}

fn copy(
    ctx: *Instance,
    source: *sdl.SDL_Texture,
    target: *sdl.SDL_Texture,
    source_rect: sdl.SDL_Rect,
    destination: sdl.SDL_Rect,
    clear: ?[4]u8,
) Error!void {
    var state: CopyState = .{
        .target = sdl.SDL_GetRenderTarget(ctx.context.renderer),
        .viewport = undefined,
        .viewport_set = sdl.SDL_RenderViewportSet(ctx.context.renderer),
        .clip = undefined,
        .clip_enabled = sdl.SDL_RenderClipEnabled(ctx.context.renderer),
        .scale_x = undefined,
        .scale_y = undefined,
        .color = undefined,
        .source = source,
        .blend = undefined,
        .modulation = undefined,
        .scope = undefined,
    };
    if (!sdl.SDL_GetRenderViewport(
        ctx.context.renderer,
        &state.viewport,
    ) or
        !sdl.SDL_GetRenderClipRect(
            ctx.context.renderer,
            &state.clip,
        ) or
        !sdl.SDL_GetRenderScale(
            ctx.context.renderer,
            &state.scale_x,
            &state.scale_y,
        ) or
        !sdl.SDL_GetRenderDrawColor(
            ctx.context.renderer,
            &state.color[0],
            &state.color[1],
            &state.color[2],
            &state.color[3],
        ) or
        !sdl.SDL_GetTextureBlendMode(source, &state.blend) or !sdl.SDL_GetTextureColorMod(
        source,
        &state.modulation[0],
        &state.modulation[1],
        &state.modulation[2],
    ) or
        !sdl.SDL_GetTextureAlphaMod(
            source,
            &state.modulation[3],
        ))
        return error.TextureStateFailed;
    state.scope = try begin(ctx, source, .nearest, .clamp);
    errdefer restore(ctx, state) catch {};
    if (!sdl.SDL_SetRenderTarget(ctx.context.renderer, target) or
        !sdl.SDL_SetRenderScale(ctx.context.renderer, 1, 1) or
        !sdl.SDL_SetRenderViewport(ctx.context.renderer, null) or
        ctx.faults.check(.sampling_setup) or !sdl.SDL_SetRenderClipRect(ctx.context.renderer, null) or
        !sdl.SDL_SetTextureBlendMode(source, sdl.SDL_BLENDMODE_NONE) or
        !sdl.SDL_SetTextureColorMod(source, 255, 255, 255) or
        !sdl.SDL_SetTextureAlphaMod(source, 255))
        return error.TextureStateFailed;
    if (clear) |color| {
        if (!sdl.SDL_SetRenderDrawColor(
            ctx.context.renderer,
            color[0],
            color[1],
            color[2],
            color[3],
        ) or
            !sdl.SDL_RenderClear(ctx.context.renderer))
            return error.SamplingCopyFailed;
    }
    const src = sdl.SDL_FRect{
        .x = @floatFromInt(source_rect.x),
        .y = @floatFromInt(source_rect.y),
        .w = @floatFromInt(source_rect.w),
        .h = @floatFromInt(source_rect.h),
    };
    const dst = sdl.SDL_FRect{
        .x = @floatFromInt(destination.x),
        .y = @floatFromInt(destination.y),
        .w = @floatFromInt(destination.w),
        .h = @floatFromInt(destination.h),
    };
    if (ctx.faults.check(.sampling_copy) or
        !sdl.SDL_RenderTexture(ctx.context.renderer, source, &src, &dst))
        return error.SamplingCopyFailed;
    ctx.sampling_stats.copy_calls += 1;
    ctx.sampling_stats.copied_bytes += size(source_rect.w, source_rect.h);
    try restore(ctx, state);
}

pub fn prepareCanvas(
    ctx: *Instance,
    layer_id: usize,
) Error!void {
    const layer = &ctx.state.layers[layer_id];
    if (!ctx.state.layer_masks.has(.bilinear_canvas, layer_id) or ctx.state.layer_masks.has(.padded_backing, layer_id)) return;
    const extent = textures.layerExtent(ctx, layer);
    if (extent.width <= 0 or extent.height <= 0)
        return error.TargetCreationFailed;
    const backing = types.CanvasBacking{
        .width = std.math.add(c_int, extent.width, 2) catch
            return error.TargetCreationFailed,
        .height = std.math.add(c_int, extent.height, 2) catch
            return error.TargetCreationFailed,
        .border = 1,
    };
    const texture = textures.allocateLayerBacking(ctx, backing) catch |err|
        return switch (err) {
            error.SamplingBudgetExceeded => error.SamplingBudgetExceeded,
            error.SamplingPreparationFailed => error.SamplingPreparationFailed,
            else => error.TargetCreationFailed,
        };
    errdefer textures.destroyLayerBacking(ctx, texture, backing);
    const dirty = ctx.state.layer_masks.has(.target_dirty, layer_id);
    if (layer.target_texture_id != 0 and !dirty) {
        const source = ctx.state.texture_table[layer.target_texture_id] orelse
            return error.TargetCreationFailed;
        const identity: u8 = if (layer.canvas_mode == .multiply) 255 else 0;
        try copy(
            ctx,
            source,
            texture,
            .{
                .x = 0,
                .y = 0,
                .w = extent.width,
                .h = extent.height,
            },
            .{
                .x = 1,
                .y = 1,
                .w = extent.width,
                .h = extent.height,
            },
            .{
                identity,
                identity,
                identity,
                identity,
            },
        );
    }
    const had_target = layer.target_texture_id != 0;
    if (!textures.installLayerBacking(ctx, layer_id, texture, backing))
        return error.TargetCreationFailed;
    ctx.state.layer_masks.set(.target_dirty, layer_id, dirty or !had_target);
}

pub fn sourceRectangle(
    ctx: *Instance,
    texture_id: u16,
    source: *sdl.SDL_Texture,
    rectangle: sdl.SDL_Rect,
) Error!*sdl.SDL_Texture {
    if (texture_id == 0 or texture_id >= types.max_texture_ids)
        return error.InvalidSourceRectangle;
    const dims = ctx.state.texture_dims[texture_id];
    if (rectangle.x < 0 or
        rectangle.y < 0 or
        rectangle.w <= 0 or
        rectangle.h <= 0 or
        @as(i64, rectangle.x) + rectangle.w > @as(i64, @intFromFloat(dims.width)) or
        @as(i64, rectangle.y) + rectangle.h > @as(i64, @intFromFloat(dims.height)))
        return error.InvalidSourceRectangle;
    if (ctx.sampling_cache.views == null) {
        if (ctx.faults.check(.sampling_cpu_allocation))
            return error.SamplingPreparationFailed;
        const views = ctx.allocator.alloc(View, max_source_views) catch
            return error.SamplingPreparationFailed;
        @memset(views, .{});
        ctx.sampling_cache.views = views;
        ctx.sampling_stats.cpu_allocations += 1;
        ctx.sampling_stats.retained_cpu_bytes = views.len * @sizeOf(View);
    }
    var found: ?*View = null;
    var free: ?*View = null;
    for (ctx.sampling_cache.views.?) |*view| {
        if (view.texture_id == texture_id and std.meta.eql(view.rectangle, rectangle)) {
            found = view;
            break;
        }
        if (view.texture_id == 0 and free == null) free = view;
    }
    const pressure = size(rectangle.w, rectangle.h) > max_view_bytes - ctx.sampling_cache.texture_bytes;
    const view = found orelse (if (pressure) oldest(ctx) orelse free else free orelse oldest(ctx)) orelse
        return error.SamplingCacheFull;
    if (found == null and view.texture != null) {
        if (view.rectangle.w != rectangle.w or view.rectangle.h != rectangle.h) {
            dropView(ctx, view);
        } else {
            view.texture_id = texture_id;
            view.rectangle = rectangle;
            view.dirty = .{
                .x = 0,
                .y = 0,
                .w = rectangle.w,
                .h = rectangle.h,
            };
        }
    }
    if (view.texture == null) {
        const texture = try allocate(ctx, rectangle.w, rectangle.h);
        view.* = .{
            .texture_id = texture_id,
            .rectangle = rectangle,
            .texture = texture,
            .dirty = .{
                .x = 0,
                .y = 0,
                .w = rectangle.w,
                .h = rectangle.h,
            },
        };
    }
    ctx.sampling_cache.clock +%= 1;
    view.last_used = ctx.sampling_cache.clock;
    if (view.dirty) |update| {
        try copy(
            ctx,
            source,
            view.texture.?,
            .{
                .x = rectangle.x + update.x,
                .y = rectangle.y + update.y,
                .w = update.w,
                .h = update.h,
            },
            update,
            null,
        );
        view.dirty = null;
    }
    return view.texture.?;
}
