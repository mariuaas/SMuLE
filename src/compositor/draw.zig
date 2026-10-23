const std = @import("std");
const log = std.log.scoped(.smule);
const sdl = @import("sdl").sdl;
const Instance = @import("root.zig").Instance;

const t = @import("types.zig");
const geometry = @import("geometry.zig");
const draw_storage = @import("draw_storage.zig");

pub const DrawError = error{
    InvalidOwner,
    TransactionActive,
    CapacityExceeded,
    ReservationExceeded,
    PayloadCapacityExceeded,
    GenerationExhausted,
    OutOfMemory,
    InvalidSourceRectangle,
    InvalidSamplingCoordinates,
    OperationCanvasRequired,
    UnsupportedOperationResource,
    WrongFrameState,
    InvalidTextureId,
    InvalidLayerId,
    ImmediateQueueFull,
    LayerSlabFull,
    WhiteTextureUnavailable,
};

pub fn addAffineSprite(
    ctx: *Instance,
    sprite: t.AffineSprite,
) DrawError!void {
    if (ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    if (sprite.layer_id >= t.max_layers)
        return error.InvalidLayerId;
    if (ctx.state.layers[sprite.layer_id].canvas_mode == .legacy_rgba)
        return error.OperationCanvasRequired;
    if (sprite.texture_id == 0 or
        sprite.texture_id >= t.max_texture_ids or
        ctx.state.texture_table[sprite.texture_id] == null)
        return error.InvalidTextureId;
    const dims = ctx.state.texture_dims[sprite.texture_id];
    if (@as(f32, @floatFromInt(@as(u32, sprite.sx) + sprite.sw)) > dims.width or
        @as(f32, @floatFromInt(@as(u32, sprite.sy) + sprite.sh)) > dims.height)
        return error.InvalidSourceRectangle;
    if (ctx.faults.check(.sprite_metadata_allocation))
        return error.OutOfMemory;
    try queueDrawInstructionWithTexture(ctx, .{
        .texture_id = sprite.texture_id,
        .layer_id = sprite.layer_id,
        .priority = sprite.priority,
        .source = .{ .x = sprite.sx, .y = sprite.sy, .w = sprite.sw, .h = sprite.sh },
        .destination = .{ .x = 0, .y = 0, .w = sprite.sw, .h = sprite.sh },
        .tint = sprite.tint,
        .primitive = .{ .sprite = sprite.affine },
    });
}
pub fn addTexturedTriangle(
    ctx: *Instance,
    triangle: t.TexturedTriangle,
) DrawError!void {
    if (ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    if (triangle.layer_id >= t.max_layers)
        return error.InvalidLayerId;
    if (ctx.state.layers[triangle.layer_id].canvas_mode == .legacy_rgba)
        return error.OperationCanvasRequired;
    const texture_id = if (triangle.texture_id == 0xffff) 0 else triangle.texture_id;
    if (triangle.texture_id != 0xffff and
        (texture_id == 0 or texture_id >= t.max_texture_ids or ctx.state.texture_table[texture_id] == null))
        return error.InvalidTextureId;
    const slot = ctx.draw_storage.owners[triangle.layer_id].count;
    if (ctx.faults.check(.triangle_metadata_allocation))
        return error.OutOfMemory;
    var instruction = std.mem.zeroes(t.DrawInstruction);
    instruction.layer_id = triangle.layer_id;
    instruction.sort_key = geometry.packKey(
        triangle.priority,
        texture_id,
        slot,
        false,
    );
    try admit(ctx, instruction, .{ .triangle = triangle.vertices });
    ctx.changes.scene_changed = true;
    ctx.state.draw_list_sorted = false;
    ctx.frame_ready = false;
}

pub fn addLine(
    ctx: *Instance,
    line: t.Line,
) DrawError!void {
    if (ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    if (line.layer_id >= t.max_layers)
        return error.InvalidLayerId;
    if (ctx.state.layers[line.layer_id].canvas_mode == .legacy_rgba)
        return error.OperationCanvasRequired;
    const slot = ctx.draw_storage.owners[line.layer_id].count;
    if (ctx.faults.check(.line_metadata_allocation)) return error.OutOfMemory;
    var instruction = std.mem.zeroes(t.DrawInstruction);
    instruction.layer_id = line.layer_id;
    instruction.sort_key = geometry.packKey(line.priority, 0, slot, false);
    instruction.kind = t.DrawKind.line;
    instruction.width = 1;
    instruction.height = 1;
    instruction.w_dest = 1;
    instruction.h_dest = 1;
    instruction.tint_r = line.color[0];
    instruction.tint_g = line.color[1];
    instruction.tint_b = line.color[2];
    instruction.tint_a = line.color[3];
    try admit(ctx, instruction, .{ .line = line });
    ctx.changes.scene_changed = true;
    ctx.state.draw_list_sorted = false;
    ctx.frame_ready = false;
}

fn admit(
    ctx: *Instance,
    instruction: t.DrawInstruction,
    primitive: draw_storage.Payload,
) DrawError!void {
    const immediate = instruction.layer_id == t.immediate_layer_id;
    const owner: u8 = if (immediate) draw_storage.immediate_owner else instruction.layer_id;
    _ = ctx.draw_storage.append(owner, instruction, primitive) catch |err| switch (err) {
        error.CapacityExceeded => return if (immediate) error.ImmediateQueueFull else error.LayerSlabFull,
        else => return err,
    };
    if (immediate) {
        ctx.state.instruction_count = ctx.draw_storage.owners[owner].count;
        ctx.changes.immediate_submitted = true;
    } else {
        const layer = &ctx.state.layers[owner];
        layer.slab_count = ctx.draw_storage.owners[owner].count;
        layer.geometry_dirty = true;
        layer.order_dirty = true;
        layer.target_dirty = true;
        layer.present_dirty = true;
        ctx.changes.scene_changed = true;
    }
    ctx.state.draw_list_sorted = false;
    ctx.frame_ready = false;
}

fn lastCommand(
    ctx: *Instance,
    owner: u8,
) *t.DrawInstruction {
    const page = ctx.draw_storage.owners[owner].last;
    const used = ctx.draw_storage.backing.command_pages[page].used;
    return &ctx.draw_storage.backing.commands[page].commands[used - 1];
}
pub fn addOperationQuadUV(
    ctx: *Instance,
    texture_id: u16,
    layer_id: u8,
    priority: c_int,
    source: sdl.SDL_FRect,
    destination: sdl.SDL_Rect,
    tint: [4]u8,
) DrawError!void {
    if (ctx.state.frame_state != .updating)
        return error.WrongFrameState;
    if (layer_id >= t.max_layers)
        return error.InvalidLayerId;
    if (ctx.state.layers[layer_id].canvas_mode == .legacy_rgba)
        return error.OperationCanvasRequired;
    for ([_]f32{
        source.x,
        source.y,
        source.w,
        source.h,
        source.x + source.w,
        source.y + source.h,
    }) |value| if (!std.math.isFinite(value))
        return error.InvalidSamplingCoordinates;
    try queueDrawInstructionWithTexture(ctx, .{
        .texture_id = texture_id,
        .layer_id = layer_id,
        .priority = priority,
        .source = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .destination = destination,
        .tint = tint,
    });
    const index = ctx.draw_storage.owners[layer_id].count - 1;
    const instruction = lastCommand(ctx, layer_id);
    instruction.x_loc = source.x;
    instruction.y_loc = source.y;
    instruction.width = source.w;
    instruction.height = source.h;
    instruction.kind = .raw_uv_quad;
    instruction.sort_key = geometry.packKey(
        priority,
        texture_id,
        index,
        false,
    );
}

const QueueDrawOptions = struct {
    texture_id: u16,
    layer_id: u8,
    priority: c_int = 0,
    source: sdl.SDL_Rect,
    destination: sdl.SDL_Rect,
    flip_h: bool = false,
    flip_v: bool = false,
    center: sdl.SDL_Point = .{ .x = 0, .y = 0 },
    angle: f64 = 0,
    tint: [4]u8 = .{ 255, 255, 255, 255 },
    primitive: draw_storage.Payload = .none,
};

fn queueDrawInstructionWithTexture(
    ctx: *Instance,
    options: QueueDrawOptions,
) DrawError!void {
    if (ctx.state.frame_state != .updating) {
        if (ctx.context.debug_mode) {
            log.debug(
                "ERROR: draw submission called outside frame update (state: {s})",
                .{@tagName(ctx.state.frame_state)},
            );
        }
        return error.WrongFrameState;
    }

    if (options.texture_id == 0 or options.texture_id >= t.max_texture_ids or ctx.state.texture_table[options.texture_id] == null) {
        if (ctx.context.debug_mode) {
            log.debug("ERROR: Invalid direct texture ID {d}", .{options.texture_id});
        }
        return error.InvalidTextureId;
    }

    if (options.layer_id != t.immediate_layer_id and options.layer_id >= t.max_layers) {
        if (ctx.context.debug_mode) {
            log.debug("ERROR: Invalid layer ID {d}", .{options.layer_id});
        }
        return error.InvalidLayerId;
    }
    if (ctx.state.operation_sources[options.texture_id].exclusive and
        (options.layer_id == t.immediate_layer_id or ctx.state.layers[options.layer_id].canvas_mode == .legacy_rgba))
        return error.UnsupportedOperationResource;

    var flip: u16 = 0;
    if (options.flip_h) flip |= 1;
    if (options.flip_v) flip |= 2;

    const is_simple = options.angle == 0.0 and
        !options.flip_h and
        !options.flip_v and
        options.center.x == 0 and
        options.center.y == 0;

    const sequence: usize = if (options.layer_id == t.immediate_layer_id)
        ctx.state.instruction_count
    else
        ctx.draw_storage.owners[options.layer_id].count;

    const instruction: t.DrawInstruction = .{
        .sort_key = geometry.packKey(options.priority, options.texture_id, sequence, is_simple),
        .x_loc = @floatFromInt(options.source.x),
        .y_loc = @floatFromInt(options.source.y),
        .width = @floatFromInt(options.source.w),
        .height = @floatFromInt(options.source.h),
        .x_dest = @floatFromInt(options.destination.x),
        .y_dest = @floatFromInt(options.destination.y),
        .w_dest = @floatFromInt(options.destination.w),
        .h_dest = @floatFromInt(options.destination.h),
        .flip_mode = flip,
        .center_x = @floatFromInt(options.center.x),
        .center_y = @floatFromInt(options.center.y),
        .angle = options.angle,
        .tint_r = options.tint[0],
        .tint_g = options.tint[1],
        .tint_b = options.tint[2],
        .tint_a = options.tint[3],
        .layer_id = options.layer_id,
        .kind = .clamped_quad,
    };

    try admit(ctx, instruction, options.primitive);
}

pub fn addTexturedQuad(
    ctx: *Instance,
    texture_id: u16,
    priority: c_int,
    x_src: c_int,
    y_src: c_int,
    w_src: c_int,
    h_src: c_int,
    x_dst: c_int,
    y_dst: c_int,
    w_dst: c_int,
    h_dst: c_int,
    flip_h: bool,
    flip_v: bool,
    center_x: c_int,
    center_y: c_int,
    angle: f64,
) DrawError!void {
    return addTexturedQuadTinted(
        ctx,
        texture_id,
        t.immediate_layer_id,
        priority,
        x_src,
        y_src,
        w_src,
        h_src,
        x_dst,
        y_dst,
        w_dst,
        h_dst,
        flip_h,
        flip_v,
        center_x,
        center_y,
        angle,
        255,
        255,
        255,
        255,
    );
}

pub fn addTexturedQuadTinted(
    ctx: *Instance,
    texture_id: u16,
    layer_id: u8,
    priority: c_int,
    x_src: c_int,
    y_src: c_int,
    w_src: c_int,
    h_src: c_int,
    x_dst: c_int,
    y_dst: c_int,
    w_dst: c_int,
    h_dst: c_int,
    flip_h: bool,
    flip_v: bool,
    center_x: c_int,
    center_y: c_int,
    angle: f64,
    tint_r: u8,
    tint_g: u8,
    tint_b: u8,
    tint_a: u8,
) DrawError!void {
    return queueDrawInstructionWithTexture(ctx, .{
        .texture_id = texture_id,
        .layer_id = layer_id,
        .priority = priority,
        .source = .{ .x = x_src, .y = y_src, .w = w_src, .h = h_src },
        .destination = .{ .x = x_dst, .y = y_dst, .w = w_dst, .h = h_dst },
        .flip_h = flip_h,
        .flip_v = flip_v,
        .center = .{ .x = center_x, .y = center_y },
        .angle = angle,
        .tint = .{ tint_r, tint_g, tint_b, tint_a },
    });
}

pub fn addSolidRect(
    ctx: *Instance,
    priority: c_int,
    x_dst: c_int,
    y_dst: c_int,
    w_dst: c_int,
    h_dst: c_int,
    tint_r: u8,
    tint_g: u8,
    tint_b: u8,
    tint_a: u8,
) DrawError!void {
    if (ctx.state.white_texture_id == 0) return error.WhiteTextureUnavailable;

    return addSolidRectToLayer(
        ctx,
        t.immediate_layer_id,
        priority,
        x_dst,
        y_dst,
        w_dst,
        h_dst,
        tint_r,
        tint_g,
        tint_b,
        tint_a,
    );
}

pub fn addSolidRectToLayer(
    ctx: *Instance,
    layer_id: u8,
    priority: c_int,
    x_dst: c_int,
    y_dst: c_int,
    w_dst: c_int,
    h_dst: c_int,
    tint_r: u8,
    tint_g: u8,
    tint_b: u8,
    tint_a: u8,
) DrawError!void {
    if (ctx.state.white_texture_id == 0) return error.WhiteTextureUnavailable;

    return addTexturedQuadTinted(
        ctx,
        ctx.state.white_texture_id,
        layer_id,
        priority,
        0,
        0,
        1,
        1,
        x_dst,
        y_dst,
        w_dst,
        h_dst,
        false,
        false,
        0,
        0,
        0.0,
        tint_r,
        tint_g,
        tint_b,
        tint_a,
    );
}

/// Inspect min(count, available draw slots) inputs and return the accepted count.
/// Invalid entries in that prefix are skipped; later inputs are not scanned to
/// fill holes. The return value is not an input-consumption offset for retries.
pub fn submitDrawInstructionsBulk(
    ctx: *Instance,
    ext_instructions: [*]const t.ExternalDrawInstruction,
    count: usize,
) DrawError!usize {
    if (ctx.state.frame_state != .updating) {
        if (ctx.context.debug_mode) {
            log.debug(
                "ERROR: submitDrawInstructionsBulk called outside frame update",
                .{},
            );
        }
        return error.WrongFrameState;
    }

    ctx.state.frame_stats.bulk_api_calls += 1;

    const available = @min(ctx.draw_storage.config.ceiling, ctx.draw_storage.config.reserved) - ctx.draw_storage.count;
    const to_add = @min(count, available);

    if (to_add < count and ctx.context.debug_mode) {
        log.debug(
            "WARNING: Draw queue full, only added {d}/{d} instructions",
            .{ to_add, count },
        );
    }

    var added: usize = 0;
    for (0..to_add) |i| {
        const ext = ext_instructions[i];

        if (ext.graphic_index < 0 or ext.graphic_index >= t.max_graphics) continue;
        if (ext.palette_index < 0 or ext.palette_index >= t.max_palettes) continue;

        const tex_id = ctx.state.graphics[@intCast(ext.graphic_index)].texture_ids[@intCast(ext.palette_index)];
        if (tex_id == 0 or tex_id >= t.max_texture_ids) {
            if (ctx.context.debug_mode) {
                log.debug(
                    "WARNING: Skipping draw for invalid texture ID {d} (graphic {d}, palette {d})",
                    .{ tex_id, ext.graphic_index, ext.palette_index },
                );
            }
            continue;
        }

        var flip: u16 = 0;
        if (ext.flip_h != 0) flip |= 1;
        if (ext.flip_v != 0) flip |= 2;

        const is_simple = ext.angle == 0.0 and
            ext.flip_h == 0 and
            ext.flip_v == 0 and
            ext.center_x == 0 and
            ext.center_y == 0;
        const layer_id: u8 = t.immediate_layer_id;
        const sequence: usize = ctx.state.instruction_count;
        const instruction: t.DrawInstruction = .{
            .sort_key = geometry.packKey(ext.priority, tex_id, sequence, is_simple),
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
        };

        try admit(ctx, instruction, .none);
        added += 1;
    }

    if (added > 0) {
        ctx.state.draw_list_sorted = false;
        ctx.frame_ready = false;
    }

    ctx.state.frame_stats.bulk_items_submitted += added;
    if (added > 0) {
        ctx.changes.immediate_submitted = true;
    }

    return added;
}
