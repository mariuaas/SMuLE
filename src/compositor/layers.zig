const std = @import("std");
const log = std.log.scoped(.smule);
const Instance = @import("root.zig").Instance;

const t = @import("types.zig");
const geometry = @import("geometry.zig");
const textures = @import("textures.zig");
const draw = @import("draw.zig");
const operation = @import("operation.zig");
const sampling = @import("sampling.zig");
const draw_storage = @import("draw_storage.zig");

pub const LayerError = textures.TextureError || draw.DrawError || error{
    NoTransaction,
    WrongFrameState,
    InvalidLayerId,
    OperationCanvasRequired,
};

fn operationLayer(
    ctx: *Instance,
    layer_id: u8,
) LayerError!*t.LayerState {
    if (ctx.state.frame_state != .updating) return error.WrongFrameState;
    if (layer_id >= t.max_layers) return error.InvalidLayerId;
    const layer = &ctx.state.layers[layer_id];
    if (layer.canvas_mode == .legacy_rgba) return error.OperationCanvasRequired;
    return layer;
}

fn invalidateCanvas(
    ctx: *Instance,
    layer: *t.LayerState,
) void {
    layer.target_dirty = true;
    layer.present_dirty = true;
    ctx.frame_ready = false;
    ctx.changes.present_needed = true;
}

pub fn setCanvasExtent(
    ctx: *Instance,
    layer_id: u8,
    width: u16,
    height: u16,
) LayerError!void {
    const layer = try operationLayer(ctx, layer_id);
    if ((width == 0) != (height == 0))
        return error.InvalidDimensions;
    const resolved_width = if (width == 0) ctx.context.logical_width else @as(c_int, width);
    const resolved_height = if (height == 0) ctx.context.logical_height else @as(c_int, height);
    if (resolved_width <= 0 or resolved_height <= 0 or resolved_width > 65535 or resolved_height > 65535)
        return error.InvalidDimensions;
    if (layer.canvas_width == resolved_width and layer.canvas_height == resolved_height)
        return;
    try textures.resizeLayerTarget(ctx, layer_id, resolved_width, resolved_height);
    layer.canvas_width = @intCast(resolved_width);
    layer.canvas_height = @intCast(resolved_height);
    invalidateCanvas(ctx, layer);
}

pub fn setContentScroll(
    ctx: *Instance,
    layer_id: u8,
    horizontal: i32,
    vertical: i32,
) LayerError!void {
    const layer = try operationLayer(ctx, layer_id);
    if (layer.content_scroll_x == horizontal and layer.content_scroll_y == vertical)
        return;
    layer.content_scroll_x = horizontal;
    layer.content_scroll_y = vertical;
    invalidateCanvas(ctx, layer);
}

pub fn setSurfaceClip(
    ctx: *Instance,
    layer_id: u8,
    clip: t.SurfaceClip,
) LayerError!void {
    const layer = try operationLayer(ctx, layer_id);
    const effective: t.SurfaceClip = if (clip.w == 0 or clip.h == 0) .{} else clip;
    if (std.meta.eql(layer.surface_clip, effective)) return;
    layer.surface_clip = effective;
    invalidateCanvas(ctx, layer);
}

pub fn setAffine(
    ctx: *Instance,
    layer_id: u8,
    affine: t.Affine,
) LayerError!void {
    const layer = try operationLayer(ctx, layer_id);
    if (std.meta.eql(layer.affine, affine)) return;
    layer.affine = affine;
    layer.present_dirty = true;
    ctx.frame_ready = false;
    ctx.changes.present_needed = true;
}

pub fn setCanvasSampling(
    ctx: *Instance,
    layer_id: u8,
    mode: t.Sampling,
) LayerError!void {
    const layer = try operationLayer(ctx, layer_id);
    if (layer.sampling == mode) return;
    layer.sampling = mode;
    layer.present_dirty = true;
    ctx.frame_ready = false;
    ctx.changes.present_needed = true;
}

fn isLayerVisible(
    ctx: *Instance,
    layer_id: usize,
) bool {
    return layer_id < t.max_layers and ctx.state.layers[layer_id].visible;
}

fn hasPresentableSurface(
    layer: *const t.LayerState,
) bool {
    return layer.canvas_mode != .legacy_rgba or layer.slab_count > 0 or layer.clear_a > 0;
}

pub fn setCanvasMode(
    ctx: *Instance,
    layer_id: u8,
    mode: t.CanvasMode,
) LayerError!void {
    if (ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    if (layer_id >= t.max_layers)
        return error.InvalidLayerId;
    const layer = &ctx.state.layers[layer_id];
    if (layer.canvas_mode == mode) return;
    if (mode == .legacy_rgba and ctx.draw_storage.owners[layer_id].payloads != 0)
        return error.OperationCanvasRequired;
    if (layer.target_texture_id != 0) {
        const width = if (mode != .legacy_rgba and layer.canvas_width != 0)
            @as(c_int, layer.canvas_width)
        else
            ctx.context.logical_width;
        const height = if (mode != .legacy_rgba and layer.canvas_height != 0)
            @as(c_int, layer.canvas_height)
        else
            ctx.context.logical_height;
        try textures.resizeLayerTargetForMode(
            ctx,
            layer_id,
            width,
            height,
            mode,
        );
    }
    layer.canvas_mode = mode;
    layer.target_dirty = true;
    layer.present_dirty = true;
    layer.order_dirty = true;
    ctx.frame_ready = false;
    ctx.changes.scene_changed = true;
}

fn setLayerChannel(
    layer: *t.LayerState,
    channel: *u8,
    value: i32,
) t.LayerPropWake {
    const clamped: u8 = @intCast(std.math.clamp(value, 0, 255));
    if (channel.* == clamped) return .none;
    channel.* = clamped;
    layer.present_dirty = true;
    return .present_needed;
}

fn applyLayerProp(
    ctx: *Instance,
    cmd: *const t.LayerPropCommand,
) t.LayerPropWake {
    if (cmd.layer_id >= t.max_layers) return .none;

    const layer = &ctx.state.layers[cmd.layer_id];
    const field = @as(t.LayerPropField, @enumFromInt(cmd.field));
    switch (field) {
        .visible => {
            const visible = cmd.value != 0;
            if (layer.visible == visible) return .none;
            layer.visible = visible;
            layer.order_dirty = true;
            return .scene_changed;
        },
        .z => {
            const z = std.math.clamp(cmd.value, -32768, 32767);
            const z_i16: i16 = @intCast(z);
            if (layer.z == z_i16) return .none;
            layer.z = z_i16;
            layer.order_dirty = true;
            return .scene_changed;
        },
        .opacity => return setLayerChannel(layer, &layer.opacity, cmd.value),
        .tint_r => return setLayerChannel(layer, &layer.tint_r, cmd.value),
        .tint_g => return setLayerChannel(layer, &layer.tint_g, cmd.value),
        .tint_b => return setLayerChannel(layer, &layer.tint_b, cmd.value),
        .clear_r, .clear_g, .clear_b, .clear_a => {
            const channel = switch (field) {
                .clear_r => &layer.clear_r,
                .clear_g => &layer.clear_g,
                .clear_b => &layer.clear_b,
                .clear_a => &layer.clear_a,
                else => unreachable,
            };
            const wake = setLayerChannel(layer, channel, cmd.value);
            if (wake != .none) layer.target_dirty = true;
            return wake;
        },
        .scroll_x => {
            if (layer.scroll_x == cmd.value) return .none;
            layer.scroll_x = cmd.value;
            layer.present_dirty = true;
            return .present_needed;
        },
        .scroll_y => {
            if (layer.scroll_y == cmd.value) return .none;
            layer.scroll_y = cmd.value;
            layer.present_dirty = true;
            return .present_needed;
        },
        .clip_x => {
            const clip_x = std.math.clamp(cmd.value, -32768, 32767);
            const clip_x_i16: i16 = @intCast(clip_x);
            if (layer.clip_x == clip_x_i16) return .none;
            layer.clip_x = clip_x_i16;
            layer.present_dirty = true;
            return .present_needed;
        },
        .clip_y => {
            const clip_y = std.math.clamp(cmd.value, -32768, 32767);
            const clip_y_i16: i16 = @intCast(clip_y);
            if (layer.clip_y == clip_y_i16) return .none;
            layer.clip_y = clip_y_i16;
            layer.present_dirty = true;
            return .present_needed;
        },
        .clip_w => {
            const clip_w = std.math.clamp(cmd.value, 0, 65535);
            const clip_w_u16: u16 = @intCast(clip_w);
            if (layer.clip_w == clip_w_u16) return .none;
            layer.clip_w = clip_w_u16;
            layer.present_dirty = true;
            return .present_needed;
        },
        .clip_h => {
            const clip_h = std.math.clamp(cmd.value, 0, 65535);
            const clip_h_u16: u16 = @intCast(clip_h);
            if (layer.clip_h == clip_h_u16) return .none;
            layer.clip_h = clip_h_u16;
            layer.present_dirty = true;
            return .present_needed;
        },
        .blend_mode => {
            const blend_mode = std.math.clamp(cmd.value, 0, 3);
            const blend_mode_u8: u8 = @intCast(blend_mode);
            if (layer.blend_mode == blend_mode_u8) return .none;
            layer.blend_mode = blend_mode_u8;
            layer.present_dirty = true;
            return .present_needed;
        },
        _ => {
            if (ctx.context.debug_mode) {
                log.debug(
                    "WARNING: Unknown layer prop field {d} for layer {d}",
                    .{ cmd.field, cmd.layer_id },
                );
            }
            return .none;
        },
    }
}

pub fn hasVisibleRetainedLayers(ctx: *Instance) bool {
    for (ctx.state.layers) |layer| {
        if (layer.visible and hasPresentableSurface(&layer)) {
            return true;
        }
    }
    return false;
}

pub fn invalidateTexture(
    ctx: *Instance,
    texture_id: u16,
    geometry_changed: bool,
) void {
    if (texture_id == 0 or texture_id >= t.max_texture_ids) return;
    operation.invalidateExternal(ctx, texture_id);
    if (geometry_changed) sampling.dropSource(ctx, texture_id);
    invalidateReferences(ctx, texture_id, geometry_changed, false);
}

pub fn invalidateOperationReferences(ctx: *Instance, texture_id: u16) void {
    invalidateReferences(ctx, texture_id, false, true);
}

fn invalidateReferences(
    ctx: *Instance,
    texture_id: u16,
    geometry_changed: bool,
    comptime operation_only: bool,
) void {
    for (&ctx.state.layers, 0..) |*layer, layer_id| {
        if (operation_only and layer.canvas_mode == .legacy_rgba) continue;
        var iterator = ctx.draw_storage.iterator(@intCast(layer_id)) catch unreachable;
        while (iterator.nextRef()) |reference| {
            if (geometry.unpackTextureId(reference.key) != texture_id) continue;
            if (geometry_changed) layer.geometry_dirty = true;
            layer.target_dirty = true;
            layer.present_dirty = true;
            ctx.changes.present_needed = true;
            ctx.frame_ready = false;
            break;
        }
    }
    if (!operation_only) {
        var iterator = ctx.draw_storage.iterator(draw_storage.immediate_owner) catch unreachable;
        while (iterator.nextRef()) |reference| {
            if (geometry.unpackTextureId(reference.key) != texture_id) continue;
            ctx.changes.present_needed = true;
            ctx.frame_ready = false;
            break;
        }
    }
}

fn isolateNearestSprite(
    ctx: *Instance,
    slot: u32,
    dims: t.TextureDims,
    comptime metadata: bool,
) bool {
    if (!metadata) return false;
    const primitive = geometry.payload(ctx, slot) orelse return false;
    if (primitive.* != .sprite) return false;
    const instruction = geometry.commandAt(ctx, slot);
    return instruction.x_loc != 0 or
        instruction.y_loc != 0 or
        instruction.width != dims.width or
        instruction.height != dims.height;
}

fn rawUV(
    ctx: *Instance,
    slot: u32,
    comptime metadata: bool,
) bool {
    if (metadata) if (geometry.payload(ctx, slot)) |primitive| {
        if (primitive.* == .triangle or primitive.* == .line) return true;
    };
    return geometry.commandAt(ctx, slot).kind != .clamped_quad;
}

fn compileRetainedLayer(
    ctx: *Instance,
    layer_id: usize,
) LayerError!void {
    if (ctx.draw_storage.owners[layer_id].payloads != 0) return compileRetainedLayerWithMetadata(ctx, layer_id, true);
    return compileRetainedLayerWithMetadata(ctx, layer_id, false);
}
fn compileRetainedLayerWithMetadata(
    ctx: *Instance,
    layer_id: usize,
    comptime metadata: bool,
) LayerError!void {
    const pool = &ctx.draw_storage;
    try pool.ensureCache(@intCast(layer_id));
    ctx.canvas_stats.compiled_layers += 1;
    ctx.state.draw_list_sorted = false;
    const layer = &ctx.state.layers[layer_id];
    var iterator = try pool.iterator(@intCast(layer_id));
    var count: usize = 0;
    while (iterator.nextRef()) |reference| : (count += 1) ctx.state.layer_sorted_refs[count] = reference;
    std.mem.sort(t.SortedDrawRef, ctx.state.layer_sorted_refs[0..count], {}, geometry.compareRenderKey);
    layer.cached_vertex_start = 0;
    layer.cached_index_start = 0;
    layer.cached_vertex_count = 0;
    layer.cached_index_count = 0;
    layer.run_count = 0;
    const direct_cache = !metadata and count != 0 and count <= draw_storage.page_size;
    const destination = if (direct_cache) &pool.backing.cache[pool.owners[layer_id].cache_first] else null;
    const vertices = if (destination) |page| page.vertices[0..] else ctx.state.cached_vertex_buffer;
    const indices = if (destination) |page| page.indices[0..] else ctx.state.cached_index_buffer;
    layer.runs = if (destination) |page| page.runs[0..] else pool.backing.runs;
    var cache_page = pool.owners[layer_id].cache_first;
    var reset_page = cache_page;
    while (metadata and reset_page != draw_storage.none) {
        pool.backing.cache_pages[reset_page].used = 0;
        reset_page = pool.backing.cache_pages[reset_page].next;
    }
    var cache_slot: u32 = 0;
    var local_vertex_count: usize = 0;
    var local_index_count: usize = 0;
    var index: usize = 0;
    var simple_draws: u32 = 0;
    var complex_draws: u32 = 0;
    while (index < count) {
        const first = ctx.state.layer_sorted_refs[index];
        const texture_id = geometry.unpackTextureId(first.key);
        const dims = ctx.state.texture_dims[texture_id];
        const isolate_nearest = isolateNearestSprite(ctx, first.index, dims, metadata);
        const raw_uv = rawUV(ctx, first.index, metadata);
        var run_end = index + 1;
        while (run_end < count and
            geometry.unpackTextureId(ctx.state.layer_sorted_refs[run_end].key) == texture_id and
            rawUV(ctx, ctx.state.layer_sorted_refs[run_end].index, metadata) == raw_uv and
            isolateNearestSprite(
                ctx,
                ctx.state.layer_sorted_refs[run_end].index,
                dims,
                metadata,
            ) == isolate_nearest) : (run_end += 1)
        {}
        const run_vertex_start: u32 = @intCast(local_vertex_count);
        const run_index_start: u32 = @intCast(local_index_count);
        for (ctx.state.layer_sorted_refs[index..run_end]) |reference| {
            const instruction = geometry.commandAt(ctx, reference.index);
            const primitive = if (metadata) geometry.payload(ctx, reference.index) else null;
            const triangle = if (primitive != null and primitive.?.* == .triangle) primitive.?.triangle else null;
            const line = primitive != null and primitive.?.* == .line;
            if (primitive != null and primitive.?.* == .sprite) {
                if (!geometry.spriteHasFragments(instruction, primitive.?.sprite, dims)) continue;
            }
            const emitted = if (triangle) |triangle_vertices|
                geometry.emitTriangleGeometry(
                    ctx,
                    layer_id,
                    triangle_vertices,
                    dims,
                    texture_id == 0,
                    &local_vertex_count,
                    &local_index_count,
                )
            else
                geometry.emitQuadGeometryTo(
                    vertices,
                    indices,
                    0,
                    0,
                    &local_vertex_count,
                    &local_index_count,
                    instruction,
                    if (line) .{ .width = 1, .height = 1 } else dims,
                );
            if (!emitted) continue;
            if (metadata) {
                if (cache_slot == 64) {
                    cache_page = pool.backing.cache_pages[cache_page].next;
                    cache_slot = 0;
                }
                pool.backing.source_handles[cache_page * 64 + cache_slot] = reference.index;
                pool.backing.cache_pages[cache_page].used += 1;
                cache_slot += 1;
            }
            if ((primitive == null or
                primitive.?.* == .sprite) and
                geometry.isSimpleInstruction(instruction))
                simple_draws += 1
            else
                complex_draws += 1;
        }
        layer.runs[layer.run_count] = .{
            .texture_id = texture_id,
            .raw_uv = raw_uv,
            .isolate_nearest = isolate_nearest,
            .vertex_start = run_vertex_start,
            .vertex_count = @intCast(local_vertex_count - run_vertex_start),
            .index_start = run_index_start,
            .index_count = @intCast(local_index_count - run_index_start),
        };
        layer.run_count += 1;
        index = run_end;
    }
    layer.cached_vertex_count = @intCast(local_vertex_count);
    layer.cached_index_count = @intCast(local_index_count);
    layer.simple_draw_count = simple_draws;
    layer.complex_draw_count = complex_draws;
    if (!direct_cache) geometry.transferCache(ctx, layer_id, true);
    layer.geometry_dirty = false;
}
pub fn compileDirtyRetainedLayers(ctx: *Instance) LayerError!void {
    for (&ctx.state.layers, 0..) |*layer, layer_id| {
        if (!layer.geometry_dirty) continue;
        if (!layer.visible and layer.slab_count == 0) {
            layer.cached_vertex_count = 0;
            layer.cached_index_count = 0;
            layer.run_count = 0;
            layer.geometry_dirty = false;
            continue;
        }
        try compileRetainedLayer(ctx, layer_id);
    }
}

pub fn hasRetainedOrderDirty(ctx: *Instance) bool {
    for (ctx.state.layers) |layer| {
        if (layer.order_dirty) return true;
    }

    return ctx.state.retained_composite_entry_count == 0;
}

pub fn getLayerStateSnapshot(ctx: *Instance, layer_id: u8) ?t.LayerStateSnapshot {
    if (layer_id >= t.max_layers) return null;

    const layer = &ctx.state.layers[layer_id];
    return .{
        .visible = layer.visible,
        .z = layer.z,
        .opacity = layer.opacity,
        .tint_r = layer.tint_r,
        .tint_g = layer.tint_g,
        .tint_b = layer.tint_b,
        .clear_r = layer.clear_r,
        .clear_g = layer.clear_g,
        .clear_b = layer.clear_b,
        .clear_a = layer.clear_a,
        .geometry_dirty = layer.geometry_dirty,
        .order_dirty = layer.order_dirty,
        .present_dirty = layer.present_dirty,
        .slab_count = layer.slab_count,
        .scroll_x = layer.scroll_x,
        .scroll_y = layer.scroll_y,
        .clip_x = layer.clip_x,
        .clip_y = layer.clip_y,
        .clip_w = layer.clip_w,
        .clip_h = layer.clip_h,
        .blend_mode = layer.blend_mode,
    };
}

pub fn beginLayerReplacement(ctx: *Instance, layer_id: u8) LayerError!void {
    if (ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    if (layer_id >= t.max_layers)
        return error.InvalidLayerId;
    try ctx.draw_storage.beginReplacement(layer_id);
}

pub fn stageLayerDraws(ctx: *Instance, instructions: []const t.ExternalDrawInstruction) LayerError!usize {
    if (ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    const layer_id = ctx.draw_storage.transaction orelse
        return error.NoTransaction;
    if (layer_id >= t.max_layers)
        return error.InvalidLayerId;
    var written: usize = 0;
    for (instructions) |ext| {
        if (ext.graphic_index < 0 or
            ext.graphic_index >= t.max_graphics or
            ext.palette_index < 0 or
            ext.palette_index >= t.max_palettes)
            continue;
        const texture_id = ctx.state.graphics[@intCast(ext.graphic_index)].texture_ids[@intCast(ext.palette_index)];
        if (texture_id == 0 or texture_id >= t.max_texture_ids) continue;
        if (ctx.state.operation_sources[texture_id].exclusive and ctx.state.layers[layer_id].canvas_mode == .legacy_rgba)
            return error.UnsupportedOperationResource;
        var flip: u16 = 0;
        if (ext.flip_h != 0) flip |= 1;
        if (ext.flip_v != 0) flip |= 2;
        const simple = ext.angle == 0 and
            flip == 0 and
            ext.center_x == 0 and
            ext.center_y == 0;
        try ctx.draw_storage.stage(.{
            .sort_key = geometry.packKey(
                ext.priority,
                texture_id,
                ctx.draw_storage.staged_count,
                simple,
            ),
            .x_loc = @floatFromInt(ext.x_loc),
            .y_loc = @floatFromInt(ext.y_loc),
            .width = @floatFromInt(ext.width),
            .height = @floatFromInt(ext.height),
            .x_dest = @floatFromInt(ext.x_dest),
            .y_dest = @floatFromInt(ext.y_dest),
            .w_dest = @floatFromInt(ext.w_dest),
            .h_dest = @floatFromInt(ext.h_dest),
            .flip_mode = flip,
            .center_x = @floatFromInt(ext.center_x),
            .center_y = @floatFromInt(ext.center_y),
            .angle = ext.angle,
            .tint_r = 255,
            .tint_g = 255,
            .tint_b = 255,
            .tint_a = 255,
            .layer_id = layer_id,
            .kind = .clamped_quad,
        }, .none);
        written += 1;
    }
    return written;
}

fn validateLayerInstruction(
    ctx: *Instance,
    owner: u8,
    instruction: t.DrawInstruction,
    primitive: draw_storage.Payload,
) LayerError!void {
    if (owner >= t.max_layers or instruction.layer_id != owner)
        return error.InvalidLayerId;
    if (primitive == .line and primitive.line.layer_id != owner)
        return error.InvalidLayerId;
    if (primitive != .none and ctx.state.layers[owner].canvas_mode == .legacy_rgba)
        return error.OperationCanvasRequired;
    const texture_id = geometry.unpackTextureId(instruction.sort_key);
    if (primitive == .line and texture_id != 0)
        return error.InvalidTextureId;
    const untextured = texture_id == 0 and (primitive == .triangle or primitive == .line);
    if (!untextured) {
        if (texture_id == 0 or texture_id >= t.max_texture_ids or ctx.state.texture_table[texture_id] == null)
            return error.InvalidTextureId;
        if (ctx.state.operation_sources[texture_id].exclusive and ctx.state.layers[owner].canvas_mode == .legacy_rgba)
            return error.UnsupportedOperationResource;
    }
    if (primitive == .sprite or (primitive == .none and instruction.kind == .raw_uv_quad)) {
        for (
            [_]f32{
                instruction.x_loc,
                instruction.y_loc,
                instruction.width,
                instruction.height,
                instruction.x_loc + instruction.width,
                instruction.y_loc + instruction.height,
            },
        ) |value| if (!std.math.isFinite(value))
            return error.InvalidSamplingCoordinates;
    }
    if (primitive == .sprite) {
        const dims = ctx.state.texture_dims[texture_id];
        if (instruction.x_loc < 0 or
            instruction.y_loc < 0 or
            instruction.width < 0 or
            instruction.height < 0 or
            instruction.x_loc + instruction.width > dims.width or
            instruction.y_loc + instruction.height > dims.height)
            return error.InvalidSourceRectangle;
        for ([_]f32{
            instruction.x_loc,
            instruction.y_loc,
            instruction.width,
            instruction.height,
        }) |value| if (@floor(value) != value or value > 65535)
            return error.InvalidSourceRectangle;
    }
}

pub fn stageLayerInstruction(
    ctx: *Instance,
    instruction: t.DrawInstruction,
    primitive: draw_storage.Payload,
) LayerError!void {
    if (ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    const owner = ctx.draw_storage.transaction orelse
        return error.NoTransaction;
    ctx.draw_storage.validated = false;
    try validateLayerInstruction(ctx, owner, instruction, primitive);
    const texture_id = geometry.unpackTextureId(instruction.sort_key);
    var staged = instruction;
    switch (primitive) {
        .none => if (@intFromEnum(instruction.kind) > @intFromEnum(t.DrawKind.raw_uv_quad))
            return error.InvalidSamplingCoordinates,
        .sprite, .triangle => staged.kind = .clamped_quad,
        .line => |line| {
            staged.kind = t.DrawKind.line;
            staged.tint_r = line.color[0];
            staged.tint_g = line.color[1];
            staged.tint_b = line.color[2];
            staged.tint_a = line.color[3];
        },
    }
    staged.sort_key = geometry.packKey(
        geometry.unpackPriority(instruction.sort_key),
        texture_id,
        ctx.draw_storage.staged_count,
        (instruction.sort_key & (1 << 31)) == 0,
    );
    try ctx.draw_storage.stage(
        staged,
        primitive,
    );
}

pub fn commitLayerReplacement(ctx: *Instance) LayerError!void {
    if (ctx.state.frame_state != .updating) return error.WrongFrameState;
    const layer_id = ctx.draw_storage.transaction orelse return error.NoTransaction;
    if (layer_id >= t.max_layers) return error.InvalidLayerId;
    ctx.draw_storage.validated = false;
    for (0..ctx.draw_storage.staged_count) |index| {
        const primitive = if (ctx.draw_storage.backing.staged_payloads.len == 0)
            .none
        else
            ctx.draw_storage.backing.staged_payloads[index];
        try validateLayerInstruction(
            ctx,
            layer_id,
            ctx.draw_storage.backing.staged_commands[index],
            primitive,
        );
    }
    try ctx.draw_storage.validateReplacement();
    ctx.draw_storage.commitReplacement();
    const layer = &ctx.state.layers[layer_id];
    layer.slab_count = ctx.draw_storage.owners[layer_id].count;
    layer.geometry_dirty = true;
    layer.order_dirty = true;
    layer.target_dirty = true;
    layer.present_dirty = true;
    layer.run_count = 0;
    layer.runs = &.{};
    layer.cached_vertex_count = 0;
    layer.cached_index_count = 0;
    ctx.changes.scene_changed = true;
    ctx.frame_ready = false;
}

pub fn submitLayer(
    ctx: *Instance,
    layer_id: u8,
    count: usize,
) LayerError!usize {
    try beginLayerReplacement(ctx, layer_id);
    errdefer ctx.draw_storage.abortReplacement();
    const written = try stageLayerDraws(
        ctx,
        ctx.state.layer_staging_buffers[layer_id][0..@min(count, t.max_slab_size)],
    );
    try commitLayerReplacement(ctx);
    return written;
}
pub fn clearLayerContents(ctx: *Instance, layer_id: u8) LayerError!void {
    if (ctx.state.frame_state != .updating) {
        if (ctx.context.debug_mode) {
            log.debug("ERROR: clearLayerContents called outside frame update", .{});
        }
        return error.WrongFrameState;
    }

    if (layer_id >= t.max_layers)
        return error.InvalidLayerId;

    if (ctx.draw_storage.transaction != null)
        return error.TransactionActive;
    const layer = &ctx.state.layers[layer_id];
    layer.slab_count = 0;
    layer.geometry_dirty = true;
    layer.order_dirty = true;
    layer.target_dirty = true;
    layer.present_dirty = true;
    layer.run_count = 0;
    layer.cached_vertex_count = 0;
    layer.cached_index_count = 0;
    try ctx.draw_storage.clear(layer_id);
    ctx.changes.scene_changed = true;
    ctx.frame_ready = false;
}

pub fn resetLayer(ctx: *Instance, layer_id: u8) LayerError!void {
    if (ctx.state.frame_state != .updating) {
        if (ctx.context.debug_mode) {
            log.debug("ERROR: resetLayer called outside frame update", .{});
        }
        return error.WrongFrameState;
    }

    if (layer_id >= t.max_layers)
        return error.InvalidLayerId;
    if (ctx.draw_storage.transaction != null)
        return error.TransactionActive;
    const old_target_texture_id = ctx.state.layers[layer_id].target_texture_id;
    if (old_target_texture_id != 0)
        try textures.resizeLayerTargetForMode(
            ctx,
            layer_id,
            ctx.context.logical_width,
            ctx.context.logical_height,
            .legacy_rgba,
        );
    const backing = ctx.state.layers[layer_id].backing;
    ctx.state.layers[layer_id] = .{
        .target_texture_id = old_target_texture_id,
        .backing = backing,
        .geometry_dirty = true,
        .order_dirty = true,
        .target_dirty = true,
        .present_dirty = true,
    };
    try ctx.draw_storage.clear(layer_id);
    ctx.changes.scene_changed = true;
    ctx.frame_ready = false;
}

pub fn submitLayerPropCommands(ctx: *Instance, count: usize) LayerError!usize {
    if (ctx.state.frame_state != .updating) {
        if (ctx.context.debug_mode) {
            log.debug("ERROR: submitLayerPropCommands called outside frame update", .{});
        }
        return error.WrongFrameState;
    }

    const to_process = @min(count, t.max_layer_batch_commands);
    var accepted: usize = 0;
    var saw_scene_change = false;
    var saw_present_needed = false;
    for (0..to_process) |i| {
        switch (applyLayerProp(ctx, &ctx.state.layer_prop_buffer[i])) {
            .none => {},
            .scene_changed => {
                accepted += 1;
                saw_scene_change = true;
            },
            .present_needed => {
                accepted += 1;
                saw_present_needed = true;
            },
        }
    }

    if (saw_scene_change) ctx.changes.scene_changed = true;
    if (saw_present_needed) ctx.changes.present_needed = true;
    if (accepted > 0) ctx.frame_ready = false;

    return accepted;
}
