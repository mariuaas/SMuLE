const std = @import("std");
const log = std.log.scoped(.smule);
const sdl = @import("sdl").sdl;
const Instance = @import("root.zig").Instance;

const t = @import("types.zig");
const textures = @import("textures.zig");
const compositor = @import("compositor.zig");
const draw = @import("draw.zig");
const layers = @import("layers.zig");

pub const BeginOptions = struct {
    clear: bool = true,
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,
};

pub const DrawOptions = struct {
    scale: f32 = 1.0,
    opacity: u8 = 255,
    tint_r: u8 = 255,
    tint_g: u8 = 255,
    tint_b: u8 = 255,
    blend: bool = true,
    priority: c_int = 0,
};

pub const Error = compositor.RenderError || error{
    InvalidHandle,
    InvalidSize,
    RendererUnavailable,
    PoolExhausted,
    TextureCreationFailed,
    TextureRegistrationFailed,
    TargetInactive,
    TargetActive,
    WrongFrameState,
    NestedTarget,
    MissingTexture,
    DrawFailed,
};

fn isValidHandle(handle: i64) bool {
    return handle >= 0 and handle < t.max_render_targets;
}

fn restoreMainRenderTarget(ctx: *Instance) Error!void {
    return compositor.restoreMainRenderTarget(ctx);
}

pub fn create(ctx: *Instance, width: c_int, height: c_int) Error!u8 {
    if (width <= 0 or height <= 0) return error.InvalidSize;
    if (ctx.context.renderer == null) return error.RendererUnavailable;

    var free_index: ?usize = null;
    for (ctx.state.render_targets, 0..) |target, i| {
        if (!target.is_initialized) {
            free_index = i;
            break;
        }
    }
    const index = free_index orelse return error.PoolExhausted;

    const texture = textures.createRendererTextureWithAccess(
        ctx,
        width,
        height,
        sdl.SDL_TEXTUREACCESS_TARGET,
        "render target",
    ) orelse return error.TextureCreationFailed;
    errdefer sdl.SDL_DestroyTexture(texture);

    const texture_id = textures.assignTextureId(
        ctx,
        texture,
        @intCast(width),
        @intCast(height),
    ) orelse {
        return error.TextureRegistrationFailed;
    };

    ctx.state.render_targets[index] = .{
        .texture = texture,
        .texture_id = texture_id,
        .width = @intCast(width),
        .height = @intCast(height),
        .is_initialized = true,
    };
    return @intCast(index);
}

pub fn destroy(ctx: *Instance, handle: i64) Error!void {
    if (!isValidHandle(handle)) return error.InvalidHandle;
    const index: usize = @intCast(handle);
    const target = &ctx.state.render_targets[index];
    if (!target.is_initialized) return error.TargetInactive;
    if (ctx.state.active_render_target == handle) return error.TargetActive;

    if (target.texture) |texture| {
        sdl.SDL_DestroyTexture(texture);
    }
    textures.releaseTextureId(ctx, target.texture_id);
    target.* = .{};
}

pub fn destroyAll(ctx: *Instance) void {
    ctx.state.active_render_target = -1;
    for (&ctx.state.render_targets) |*target| {
        if (target.texture) |texture| {
            sdl.SDL_DestroyTexture(texture);
        }
        textures.releaseTextureId(ctx, target.texture_id);
        target.* = .{};
    }
}

pub fn begin(ctx: *Instance, handle: i64, opts: BeginOptions) Error!void {
    if (!isValidHandle(handle)) return error.InvalidHandle;
    if (ctx.state.active_render_target != -1) return error.NestedTarget;
    if (ctx.state.frame_state != .updating) return error.WrongFrameState;

    const target = &ctx.state.render_targets[@intCast(handle)];
    if (!target.is_initialized) return error.TargetInactive;
    const texture = target.texture orelse return error.MissingTexture;

    if (ctx.state.instruction_count > 0) {
        try compositor.renderImmediateToCurrentTarget(ctx);
    }

    if (ctx.faults.check(.target_select) or !sdl.SDL_SetRenderTarget(ctx.context.renderer, texture)) {
        if (ctx.context.debug_mode) {
            log.debug("Failed to begin render target {d}: {s}", .{ handle, sdl.SDL_GetError() });
        }
        return error.TextureRegistrationFailed;
    }
    errdefer restoreMainRenderTarget(ctx) catch {};
    if (ctx.faults.check(.render_scale) or !sdl.SDL_SetRenderScale(ctx.context.renderer, 1, 1))
        return error.RenderScaleFailed;
    ctx.state.active_render_target = @intCast(handle);
    ctx.frame_ready = false;
    errdefer ctx.state.active_render_target = -1;
    errdefer layers.invalidateTexture(ctx, target.texture_id, false);

    if (opts.clear) {
        if (ctx.faults.check(.draw_color) or !sdl.SDL_SetRenderDrawColor(
            ctx.context.renderer,
            opts.r,
            opts.g,
            opts.b,
            opts.a,
        ))
            return error.DrawColorFailed;
        if (ctx.faults.check(.clear) or !sdl.SDL_RenderClear(ctx.context.renderer))
            return error.ClearFailed;
    }
}

pub fn end(ctx: *Instance) Error!void {
    if (ctx.state.active_render_target == -1)
        return error.TargetInactive;

    errdefer layers.invalidateTexture(
        ctx,
        ctx.state.render_targets[@intCast(ctx.state.active_render_target)].texture_id,
        false,
    );
    const texture = ctx.state.render_targets[@intCast(ctx.state.active_render_target)].texture orelse
        return error.MissingTexture;
    if (ctx.faults.check(.target_select) or !sdl.SDL_SetRenderTarget(
        ctx.context.renderer,
        texture,
    ))
        return error.TargetSelectionFailed;
    if (ctx.faults.check(.render_scale) or !sdl.SDL_SetRenderScale(ctx.context.renderer, 1, 1))
        return error.RenderScaleFailed;
    try compositor.renderImmediateToCurrentTarget(ctx);
    layers.invalidateTexture(
        ctx,
        ctx.state.render_targets[@intCast(ctx.state.active_render_target)].texture_id,
        false,
    );
    try restoreMainRenderTarget(ctx);
    ctx.state.active_render_target = -1;
}

pub fn drawTarget(
    ctx: *Instance,
    handle: i64,
    x: c_int,
    y: c_int,
    opts: DrawOptions,
) Error!void {
    if (!isValidHandle(handle))
        return error.InvalidHandle;
    const target = &ctx.state.render_targets[@intCast(handle)];
    if (!target.is_initialized)
        return error.TargetInactive;
    if (target.texture_id == 0)
        return error.MissingTexture;

    if (target.texture) |texture| {
        if (ctx.faults.check(.texture_blend) or
            !sdl.SDL_SetTextureBlendMode(
                texture,
                if (opts.blend) sdl.SDL_BLENDMODE_BLEND else sdl.SDL_BLENDMODE_NONE,
            ))
            return error.TextureStateFailed;
    }

    const width_f: f32 = @floatFromInt(target.width);
    const height_f: f32 = @floatFromInt(target.height);
    const w: c_int = @intFromFloat(width_f * opts.scale);
    const h: c_int = @intFromFloat(height_f * opts.scale);

    draw.addTexturedQuadTinted(
        ctx,
        target.texture_id,
        t.immediate_layer_id,
        opts.priority,
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        x,
        y,
        w,
        h,
        false,
        false,
        0,
        0,
        0,
        opts.tint_r,
        opts.tint_g,
        opts.tint_b,
        opts.opacity,
    ) catch return error.DrawFailed;
}
