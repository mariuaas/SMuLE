const std = @import("std");
const log = std.log.scoped(.smule);
const sdl = @import("sdl").sdl;
const Instance = @import("root.zig").Instance;

const t = @import("types.zig");
const geometry = @import("geometry.zig");
const layers = @import("layers.zig");
const textures = @import("textures.zig");
const operation = @import("operation.zig");
const sampling = @import("sampling.zig");
const draw_storage = @import("draw_storage.zig");

pub const RenderError = layers.LayerError || error{
    SamplingPreparationFailed,
    SamplingCopyFailed,
    SamplingBudgetExceeded,
    SamplingCacheFull,
    InvalidSourceRectangle,
    OperationPixelsRequired,
    RendererUnavailable,
    TargetCreationFailed,
    TargetSelectionFailed,
    TargetRestoreFailed,
    RenderScaleFailed,
    DrawColorFailed,
    ClearFailed,
    TextureStateFailed,
    ClipFailed,
    GeometryFailed,
    BlitFailed,
    PresentFailed,
    FrameNotReady,
    TargetActive,
    UnsupportedCanvasBackend,
    UnsupportedOperationResource,
    OpaqueBackgroundRequired,
    ResourceConversionFailed,
    ViewportFailed,
};

fn resetRenderStats(ctx: *Instance) void {
    ctx.state.render_stats = .{};
}

fn toSdlBlendMode(layer_blend_mode: u8) c_uint {
    const blend_mode: t.LayerBlendMode = switch (layer_blend_mode) {
        @intFromEnum(t.LayerBlendMode.normal) => .normal,
        @intFromEnum(t.LayerBlendMode.additive) => .additive,
        @intFromEnum(t.LayerBlendMode.multiply) => .multiply,
        @intFromEnum(t.LayerBlendMode.none) => .none,
        else => .normal,
    };
    return switch (blend_mode) {
        .normal => sdl.SDL_BLENDMODE_BLEND,
        .additive => sdl.SDL_BLENDMODE_ADD,
        .multiply => sdl.SDL_BLENDMODE_MOD,
        .none => sdl.SDL_BLENDMODE_NONE,
    };
}

fn applyLayerClip(
    ctx: *Instance,
    layer: *const t.LayerState,
) RenderError!void {
    if (layer.clip_w == 0 or layer.clip_h == 0) {
        return clearLayerClip(ctx);
    }

    const clip_rect = sdl.SDL_Rect{
        .x = layer.clip_x,
        .y = layer.clip_y,
        .w = layer.clip_w,
        .h = layer.clip_h,
    };
    if (ctx.faults.check(.clip) or !sdl.SDL_SetRenderClipRect(
        ctx.context.renderer,
        &clip_rect,
    )) return error.ClipFailed;
}

fn clearLayerClip(ctx: *Instance) RenderError!void {
    if (ctx.faults.check(.clip) or !sdl.SDL_SetRenderClipRect(
        ctx.context.renderer,
        null,
    )) return error.ClipFailed;
}

pub fn restoreMainRenderTarget(ctx: *Instance) RenderError!void {
    if (ctx.faults.check(.target_restore) or !sdl.SDL_SetRenderTarget(
        ctx.context.renderer,
        ctx.context.composition_target,
    )) {
        _ = sdl.SDL_SetRenderTarget(
            ctx.context.renderer,
            ctx.context.composition_target,
        );
        _ = sdl.SDL_SetRenderScale(
            ctx.context.renderer,
            ctx.context.output_scale,
            ctx.context.output_scale,
        );
        return error.TargetRestoreFailed;
    }
    if (ctx.faults.check(.render_scale) or !sdl.SDL_SetRenderScale(
        ctx.context.renderer,
        ctx.context.output_scale,
        ctx.context.output_scale,
    )) return error.RenderScaleFailed;
}

fn getLayerTargetTexture(
    ctx: *Instance,
    layer: *const t.LayerState,
) ?*sdl.SDL_Texture {
    if (layer.target_texture_id == 0) return null;
    return ctx.state.texture_table[layer.target_texture_id];
}

fn refreshRetainedLayerTarget(
    ctx: *Instance,
    layer_id: usize,
) RenderError!void {
    const layer = &ctx.state.layers[layer_id];
    if (layer.target_texture_id == 0 and !textures.ensureLayerTarget(ctx, layer_id)) {
        if (ctx.context.debug_mode) {
            log.debug("WARNING: Failed to allocate retained layer {d} target", .{layer_id});
        }
        return error.TargetCreationFailed;
    }
    const target_texture = getLayerTargetTexture(ctx, layer) orelse return error.TargetCreationFailed;

    if (ctx.faults.check(.target_select) or !sdl.SDL_SetRenderTarget(ctx.context.renderer, target_texture)) {
        if (ctx.context.debug_mode) {
            log.debug(
                "WARNING: Failed to set retained layer {d} render target: {s}",
                .{ layer_id, sdl.SDL_GetError() },
            );
        }
        return error.TargetSelectionFailed;
    }
    errdefer restoreMainRenderTarget(ctx) catch {};
    if (ctx.faults.check(.render_scale) or !sdl.SDL_SetRenderScale(ctx.context.renderer, 1, 1))
        return error.RenderScaleFailed;

    const is_operation = ctx.state.layer_masks.has(.operation, layer_id);
    errdefer if (is_operation) {
        _ = sdl.SDL_SetRenderClipRect(ctx.context.renderer, null);
    };
    if (is_operation) {
        try clearLayerClip(ctx);
        if (ctx.faults.check(.viewport) or !sdl.SDL_SetRenderViewport(ctx.context.renderer, null))
            return error.ViewportFailed;
    }
    const identity: u8 = if (layer.canvas_mode == .multiply) 255 else 0;
    if (ctx.faults.check(.draw_color) or !sdl.SDL_SetRenderDrawColor(
        ctx.context.renderer,
        if (is_operation) identity else layer.clear_r,
        if (is_operation) identity else layer.clear_g,
        if (is_operation) identity else layer.clear_b,
        if (is_operation) identity else layer.clear_a,
    )) return error.DrawColorFailed;
    if (ctx.faults.check(.clear) or !sdl.SDL_RenderClear(ctx.context.renderer))
        return error.ClearFailed;
    ctx.canvas_stats.rasterized_canvases += 1;

    if (layer.cached_index_count == 0 or layer.slab_count == 0) {
        try restoreMainRenderTarget(ctx);
        ctx.state.layer_masks.set(.target_dirty, layer_id, false);
        return;
    }

    geometry.transferCache(ctx, layer_id, false);
    ctx.state.render_stats.quads_batched += layer.slab_count;
    ctx.state.render_stats.vertices_submitted += layer.cached_vertex_count;
    ctx.state.render_stats.indices_submitted += layer.cached_index_count;
    ctx.state.render_stats.simple_draws += layer.simple_draw_count;
    ctx.state.render_stats.complex_draws += layer.complex_draw_count;

    if (is_operation) {
        try renderOperationLayer(ctx, layer_id);
        return;
    }

    for (layer.runs[0..layer.run_count]) |run| {
        try renderGeometryRun(
            ctx,
            ctx.state.cached_vertex_buffer[0..],
            ctx.state.cached_index_buffer[0..],
            layer.cached_vertex_start,
            layer.cached_vertex_count,
            layer.cached_index_start + run.index_start,
            run.index_count,
            run.texture_id,
            @intFromEnum(t.LayerBlendMode.normal),
        );
    }

    try restoreMainRenderTarget(ctx);
    ctx.state.layer_masks.set(.target_dirty, layer_id, false);
}

fn renderOperationLayer(
    ctx: *Instance,
    layer_id: usize,
) RenderError!void {
    const layer = &ctx.state.layers[layer_id];
    const extent = textures.layerExtent(ctx, layer);
    const clip = layer.surface_clip;
    const border: c_int = layer.backing.border;
    if (clip.w != 0 and clip.h != 0) {
        const right = @min(@as(u32, clip.x) + clip.w, @as(u32, @intCast(extent.width)));
        const bottom = @min(@as(u32, clip.y) + clip.h, @as(u32, @intCast(extent.height)));
        if (clip.x >= right or clip.y >= bottom) {
            try restoreMainRenderTarget(ctx);
            ctx.state.layer_masks.set(.target_dirty, layer_id, false);
            return;
        }
        const rect: sdl.SDL_Rect = .{
            .x = @as(c_int, clip.x) + border,
            .y = @as(c_int, clip.y) + border,
            .w = @intCast(right - clip.x),
            .h = @intCast(bottom - clip.y),
        };
        if (ctx.faults.check(.clip) or !sdl.SDL_SetRenderClipRect(ctx.context.renderer, &rect))
            return error.ClipFailed;
    } else if (border != 0) {
        const rect: sdl.SDL_Rect = .{ .x = border, .y = border, .w = extent.width, .h = extent.height };
        if (ctx.faults.check(.clip) or !sdl.SDL_SetRenderClipRect(ctx.context.renderer, &rect))
            return error.ClipFailed;
    }
    const vertices = ctx.state.cached_vertex_buffer[0..layer.cached_vertex_count];
    const content_scroll_x: f64 = @floatFromInt(layer.content_scroll_x);
    const content_scroll_y: f64 = @floatFromInt(layer.content_scroll_y);
    const backing_border: f64 = @floatFromInt(border);
    for (vertices) |*vertex| {
        vertex.color = operation.premultiplyVertex(vertex.color);
        vertex.position.x = @floatCast(@as(f64, vertex.position.x) - content_scroll_x + backing_border);
        vertex.position.y = @floatCast(@as(f64, vertex.position.y) - content_scroll_y + backing_border);
    }
    ctx.canvas_stats.lowered_vertices += vertices.len;
    geometry.lowerPayloads(ctx, layer_id, vertices);
    try renderOperationRuns(ctx, layer, vertices);
    try clearLayerClip(ctx);
    try restoreMainRenderTarget(ctx);
    ctx.state.layer_masks.set(.target_dirty, layer_id, false);
}

fn renderOperationRuns(
    ctx: *Instance,
    layer: *const t.LayerState,
    vertices: []sdl.SDL_Vertex,
) RenderError!void {
    var run_index: usize = 0;
    while (run_index < layer.run_count) {
        const run = layer.runs[run_index];
        run_index += 1;
        if (run.index_count == 0) continue;
        if (run.texture_id == 0) {
            try renderGeometryTexture(
                ctx,
                vertices,
                ctx.state.cached_index_buffer[0..],
                0,
                vertices.len,
                layer.cached_index_start + run.index_start,
                run.index_count,
                null,
                operation.blend(layer.canvas_mode),
            );
            continue;
        }
        const texture = (try operation.source(ctx, run.texture_id)) orelse continue;
        const source_state = ctx.state.operation_sources[run.texture_id];
        const addressing = directRunAddressing(
            run,
            vertices,
            source_state.filter,
            source_state.addressing,
        );
        if (addressing == null) {
            const dims = ctx.state.texture_dims[run.texture_id];
            var offset: usize = run.vertex_start;
            const finish = offset + run.vertex_count;
            while (offset < finish) {
                // Recover integer pixel bounds from cached UVs for the isolated texture cache.
                // Convert those bounds back to floats to remap UVs into the isolated texture.
                const rectangle = sourceRectangle(vertices[offset..][0..4], dims);
                if (rectangle.w <= 0 or rectangle.h <= 0) return error.InvalidSourceRectangle;
                var batch_end = offset + 4;
                while (batch_end < finish and
                    std.meta.eql(
                        rectangle,
                        sourceRectangle(
                            vertices[batch_end..][0..4],
                            dims,
                        ),
                    )) : (batch_end += 4)
                {}
                const source_x: f32 = @floatFromInt(rectangle.x);
                const source_y: f32 = @floatFromInt(rectangle.y);
                const source_width: f32 = @floatFromInt(rectangle.w);
                const source_height: f32 = @floatFromInt(rectangle.h);
                const full = rectangle.x == 0 and
                    rectangle.y == 0 and
                    source_width == dims.width and
                    source_height == dims.height;
                const isolated = if (full)
                    texture
                else
                    try sampling.sourceRectangle(ctx, run.texture_id, texture, rectangle);
                if (!full) {
                    for (vertices[offset..batch_end]) |*vertex| {
                        vertex.tex_coord.x = (vertex.tex_coord.x * dims.width - source_x) / source_width;
                        vertex.tex_coord.y = (vertex.tex_coord.y * dims.height - source_y) / source_height;
                    }
                }
                const first_index = layer.cached_index_start + run.index_start + (offset - run.vertex_start) / 4 * 6;
                try renderSampledGeometry(
                    ctx,
                    vertices,
                    ctx.state.cached_index_buffer[0..],
                    first_index,
                    (batch_end - offset) / 4 * 6,
                    isolated,
                    operation.blend(layer.canvas_mode),
                    source_state.filter,
                    .clamp,
                );
                offset = batch_end;
            }
        } else {
            var index_count = run.index_count;
            while (run_index < layer.run_count) {
                const next = layer.runs[run_index];
                if (next.texture_id != run.texture_id or
                    next.index_start != run.index_start + index_count or
                    directRunAddressing(next, vertices, source_state.filter, source_state.addressing) != addressing)
                    break;
                index_count += next.index_count;
                run_index += 1;
            }
            try renderSampledGeometry(
                ctx,
                vertices,
                ctx.state.cached_index_buffer[0..],
                layer.cached_index_start + run.index_start,
                index_count,
                texture,
                operation.blend(layer.canvas_mode),
                source_state.filter,
                addressing.?,
            );
        }
    }
}

fn directRunAddressing(
    run: t.TextureRun,
    vertices: []const sdl.SDL_Vertex,
    filter: t.Sampling,
    addressing: t.Addressing,
) ?t.Addressing {
    if (!run.raw_uv and
        (filter == .bilinear or run.isolate_nearest) and
        needsRectangleIsolation(vertices[run.vertex_start..][0..run.vertex_count]))
        return null;
    return if (run.raw_uv) addressing else .clamp;
}

fn sourceRectangle(
    vertices: []const sdl.SDL_Vertex,
    dims: t.TextureDims,
) sdl.SDL_Rect {
    var left: f32 = 1;
    var top: f32 = 1;
    var right: f32 = 0;
    var bottom: f32 = 0;
    for (vertices) |vertex| {
        left = @min(left, vertex.tex_coord.x);
        top = @min(top, vertex.tex_coord.y);
        right = @max(right, vertex.tex_coord.x);
        bottom = @max(bottom, vertex.tex_coord.y);
    }
    return .{
        .x = @intFromFloat(@round(left * dims.width)),
        .y = @intFromFloat(@round(top * dims.height)),
        .w = @intFromFloat(@round((right - left) * dims.width)),
        .h = @intFromFloat(@round((bottom - top) * dims.height)),
    };
}

fn needsRectangleIsolation(
    vertices: []const sdl.SDL_Vertex,
) bool {
    var offset: usize = 0;
    while (offset < vertices.len) : (offset += 4) {
        var left: f32 = 1;
        var top: f32 = 1;
        var right: f32 = 0;
        var bottom: f32 = 0;
        for (vertices[offset..][0..4]) |vertex| {
            left = @min(left, vertex.tex_coord.x);
            top = @min(top, vertex.tex_coord.y);
            right = @max(right, vertex.tex_coord.x);
            bottom = @max(bottom, vertex.tex_coord.y);
        }
        if (left != 0 or top != 0 or right != 1 or bottom != 1) return true;
    }
    return false;
}

fn compareCompositeEntry(
    _: void,
    a: t.CompositeEntry,
    b: t.CompositeEntry,
) bool {
    if (a.composite_priority != b.composite_priority) return a.composite_priority < b.composite_priority;
    if (a.domain != b.domain) return @intFromEnum(a.domain) < @intFromEnum(b.domain);
    return a.index < b.index;
}

fn buildRetainedCompositeOrder(ctx: *Instance) void {
    ctx.state.retained_composite_entry_count = 0;

    var remaining = ctx.state.layer_masks.presentable();
    while (remaining != 0) {
        const layer_id = @ctz(remaining);
        remaining &= remaining - 1;
        const layer = &ctx.state.layers[layer_id];
        ctx.state.retained_composite_entries[ctx.state.retained_composite_entry_count] = .{
            .composite_priority = layer.z,
            .domain = .retained,
            .index = @intCast(layer_id),
        };
        ctx.state.retained_composite_entry_count += 1;
    }

    std.mem.sort(
        t.CompositeEntry,
        ctx.state.retained_composite_entries[0..ctx.state.retained_composite_entry_count],
        {},
        compareCompositeEntry,
    );

    ctx.state.layer_masks.order_dirty = 0;
}

fn compileImmediateGeometry(ctx: *Instance) void {
    ctx.state.geometry_vertex_count = 0;
    ctx.state.geometry_index_count = 0;
    ctx.state.immediate_run_count = 0;

    if (ctx.state.instruction_count == 0) return;

    geometry.sortDrawInstructions(ctx);

    var index: usize = 0;
    while (index < ctx.state.instruction_count) {
        const first_ref = ctx.state.sorted_draw_indices[index];
        const texture_id = geometry.unpackTextureId(first_ref.key);
        const texture_dims = ctx.state.texture_dims[texture_id];
        const run_priority = geometry.unpackPriority(first_ref.key);

        var run_end = index + 1;
        while (run_end < ctx.state.instruction_count and
            geometry.unpackTextureId(ctx.state.sorted_draw_indices[run_end].key) == texture_id and
            geometry.unpackPriority(ctx.state.sorted_draw_indices[run_end].key) == run_priority) : (run_end += 1)
        {}

        const run_vertex_start: u32 = @intCast(ctx.state.geometry_vertex_count);
        const run_index_start: u32 = @intCast(ctx.state.geometry_index_count);

        for (ctx.state.sorted_draw_indices[index..run_end]) |sorted_ref| {
            const instruction = geometry.commandAt(ctx, sorted_ref.index);
            if (!geometry.emitQuadGeometryTo(
                ctx.state.geometry_vertex_buffer[0..],
                ctx.state.geometry_index_buffer[0..],
                0,
                0,
                &ctx.state.geometry_vertex_count,
                &ctx.state.geometry_index_count,
                instruction,
                texture_dims,
            )) {
                break;
            }

            geometry.recordQuadWorkload(ctx, geometry.isSimpleInstruction(instruction));
        }

        ctx.state.immediate_texture_runs[ctx.state.immediate_run_count] = .{
            .texture_id = texture_id,
            .composite_priority = run_priority,
            .vertex_start = run_vertex_start,
            .vertex_count = @intCast(ctx.state.geometry_vertex_count - run_vertex_start),
            .index_start = run_index_start,
            .index_count = @intCast(ctx.state.geometry_index_count - run_index_start),
        };
        ctx.state.immediate_run_count += 1;
        index = run_end;
    }
}

fn buildCompositeMergeOrder(ctx: *Instance) void {
    ctx.state.composite_entry_count = 0;

    for (ctx.state.retained_composite_entries[0..ctx.state.retained_composite_entry_count]) |entry| {
        ctx.state.composite_entries[ctx.state.composite_entry_count] = entry;
        ctx.state.composite_entry_count += 1;
    }

    for (ctx.state.immediate_texture_runs[0..ctx.state.immediate_run_count], 0..) |run, run_index| {
        if (run.index_count == 0) continue;
        ctx.state.composite_entries[ctx.state.composite_entry_count] = .{
            .composite_priority = run.composite_priority,
            .domain = .immediate,
            .index = @intCast(run_index),
        };
        ctx.state.composite_entry_count += 1;
    }

    if (ctx.state.immediate_run_count > 0) {
        std.mem.sort(
            t.CompositeEntry,
            ctx.state.composite_entries[0..ctx.state.composite_entry_count],
            {},
            compareCompositeEntry,
        );
    }
}

fn renderGeometryRun(
    ctx: *Instance,
    vertex_buffer: []const sdl.SDL_Vertex,
    index_buffer: []const u32,
    vertex_base_start: usize,
    vertex_count_total: usize,
    index_start: usize,
    index_count: usize,
    texture_id: u16,
    blend_mode: u8,
) RenderError!void {
    if (vertex_count_total == 0 or index_count == 0) return;
    if (ctx.state.operation_sources[texture_id].exclusive) return error.UnsupportedOperationResource;
    const texture = ctx.state.texture_table[texture_id] orelse return;
    return renderGeometryTexture(
        ctx,
        vertex_buffer,
        index_buffer,
        vertex_base_start,
        vertex_count_total,
        index_start,
        index_count,
        texture,
        toSdlBlendMode(blend_mode),
    );
}

fn renderGeometryTexture(
    ctx: *Instance,
    vertex_buffer: []const sdl.SDL_Vertex,
    index_buffer: []const u32,
    vertex_base_start: usize,
    vertex_count_total: usize,
    index_start: usize,
    index_count: usize,
    texture: ?*sdl.SDL_Texture,
    blend_mode: sdl.SDL_BlendMode,
) RenderError!void {
    var previous_blend: sdl.SDL_BlendMode = undefined;
    if (texture) |handle| {
        if (ctx.faults.check(.texture_blend) or !sdl.SDL_SetTextureBlendMode(handle, blend_mode))
            return error.TextureStateFailed;
        if (ctx.faults.check(.texture_color) or !sdl.SDL_SetTextureColorMod(handle, 255, 255, 255))
            return error.TextureStateFailed;
        if (ctx.faults.check(.texture_alpha) or !sdl.SDL_SetTextureAlphaMod(handle, 255))
            return error.TextureStateFailed;
    } else {
        if (!sdl.SDL_GetRenderDrawBlendMode(ctx.context.renderer, &previous_blend))
            return error.TextureStateFailed;
        if (ctx.faults.check(.texture_blend) or !sdl.SDL_SetRenderDrawBlendMode(ctx.context.renderer, blend_mode))
            return error.TextureStateFailed;
    }
    errdefer if (texture == null) {
        _ = sdl.SDL_SetRenderDrawBlendMode(ctx.context.renderer, previous_blend);
    };
    const first_vertex = &vertex_buffer[vertex_base_start];
    const xy_ptr: [*c]const f32 = @ptrCast(&first_vertex.position.x);
    const color_ptr: [*c]const sdl.SDL_FColor = @ptrCast(&first_vertex.color);
    const uv_ptr: [*c]const f32 = @ptrCast(&first_vertex.tex_coord.x);

    if (ctx.faults.check(.geometry) or !sdl.SDL_RenderGeometryRaw(
        ctx.context.renderer,
        texture,
        xy_ptr,
        @sizeOf(sdl.SDL_Vertex),
        color_ptr,
        @sizeOf(sdl.SDL_Vertex),
        uv_ptr,
        @sizeOf(sdl.SDL_Vertex),
        @intCast(vertex_count_total),
        @ptrCast(&index_buffer[index_start]),
        @intCast(index_count),
        @sizeOf(u32),
    )) return error.GeometryFailed;
    if (texture == null and (ctx.faults.check(.untextured_blend_restore) or
        !sdl.SDL_SetRenderDrawBlendMode(ctx.context.renderer, previous_blend)))
        return error.TextureStateFailed;
    ctx.state.render_stats.draw_calls += 1;
    ctx.state.render_stats.texture_swaps += 1;
}

fn renderSampledGeometry(
    ctx: *Instance,
    vertices: []const sdl.SDL_Vertex,
    indices: []const u32,
    start: usize,
    count: usize,
    texture: *sdl.SDL_Texture,
    blend: sdl.SDL_BlendMode,
    filter: t.Sampling,
    address: t.Addressing,
) RenderError!void {
    const scope = try sampling.begin(ctx, texture, filter, address);
    errdefer sampling.end(ctx, scope) catch {};
    try renderGeometryTexture(
        ctx,
        vertices,
        indices,
        0,
        vertices.len,
        start,
        count,
        texture,
        blend,
    );
    try sampling.end(ctx, scope);
}

fn prepareRetainedLayer(
    ctx: *Instance,
    layer_id: usize,
) RenderError!void {
    if (ctx.state.layer_masks.has(.operation, layer_id)) {
        if (!ctx.context.opaque_presentation)
            return error.OpaqueBackgroundRequired;
        if (std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(ctx.context.renderer)), "software"))
            return error.UnsupportedCanvasBackend;
        try sampling.prepareCanvas(ctx, layer_id);
    }
    if (ctx.state.layer_masks.has(.target_dirty, layer_id)) {
        try refreshRetainedLayerTarget(ctx, layer_id);
    }
}

fn renderRetainedLayer(
    ctx: *Instance,
    layer_id: usize,
) RenderError!void {
    const layer = &ctx.state.layers[layer_id];
    const target_texture = getLayerTargetTexture(ctx, layer) orelse return error.TargetCreationFailed;
    if (!ctx.state.layer_masks.has(.operation, layer_id)) {
        if (ctx.faults.check(.texture_blend) or !sdl.SDL_SetTextureBlendMode(
            target_texture,
            toSdlBlendMode(layer.blend_mode),
        ))
            return error.TextureStateFailed;
        if (ctx.faults.check(.texture_color) or !sdl.SDL_SetTextureColorMod(
            target_texture,
            layer.tint_r,
            layer.tint_g,
            layer.tint_b,
        ))
            return error.TextureStateFailed;
        if (ctx.faults.check(.texture_alpha) or !sdl.SDL_SetTextureAlphaMod(
            target_texture,
            layer.opacity,
        ))
            return error.TextureStateFailed;
    }

    const extent = textures.layerExtent(ctx, layer);
    const layer_width = @as(f32, @floatFromInt(extent.width));
    const layer_height = @as(f32, @floatFromInt(extent.height));
    const scroll_x = @as(f32, @floatFromInt(layer.scroll_x));
    const scroll_y = @as(f32, @floatFromInt(layer.scroll_y));
    const src_x = @max(scroll_x, 0);
    const src_y = @max(scroll_y, 0);
    const dst_x = @max(-scroll_x, 0);
    const dst_y = @max(-scroll_y, 0);
    const visible_w = layer_width - @abs(scroll_x);
    const visible_h = layer_height - @abs(scroll_y);

    if (visible_w <= 0 or visible_h <= 0) {
        try clearLayerClip(ctx);
        return;
    }

    const src = sdl.SDL_FRect{
        .x = src_x,
        .y = src_y,
        .w = visible_w,
        .h = visible_h,
    };
    const dst = sdl.SDL_FRect{
        .x = dst_x,
        .y = dst_y,
        .w = visible_w,
        .h = visible_h,
    };

    errdefer _ = sdl.SDL_SetRenderClipRect(ctx.context.renderer, null);
    try applyLayerClip(ctx, layer);

    if (!ctx.state.layer_masks.has(.operation, layer_id)) {
        if (ctx.faults.check(.blit) or !sdl.SDL_RenderTexture(ctx.context.renderer, target_texture, &src, &dst))
            return error.BlitFailed;
        ctx.state.render_stats.draw_calls += 1;
        ctx.state.render_stats.texture_swaps += 1;
        ctx.state.render_stats.quads_batched += 1;
    } else {
        const affine = layer.affine;
        const determinant = @as(i128, affine.a) * affine.d - @as(i128, affine.b) * affine.c;
        if (determinant == 0) {
            try clearLayerClip(ctx);
            return;
        }
        const opacity = @as(f32, @floatFromInt(layer.opacity)) / 255;
        const color: sdl.SDL_FColor = .{
            .r = opacity * @as(f32, @floatFromInt(layer.tint_r)) / 255,
            .g = opacity * @as(f32, @floatFromInt(layer.tint_g)) / 255,
            .b = opacity * @as(f32, @floatFromInt(layer.tint_b)) / 255,
            .a = opacity,
        };
        const vertices = ctx.state.layer_present_vertex_buffer[0..4];
        const positions = [_]sdl.SDL_FPoint{
            .{ .x = dst.x, .y = dst.y },
            .{ .x = dst.x + dst.w, .y = dst.y },
            .{ .x = dst.x + dst.w, .y = dst.y + dst.h },
            .{ .x = dst.x, .y = dst.y + dst.h },
        };
        const border: f32 = @floatFromInt(layer.backing.border);
        const sample_width = layer_width + 2 * border;
        const sample_height = layer_height + 2 * border;
        const uv = [_]sdl.SDL_FPoint{
            .{ .x = (src.x + border) / sample_width, .y = (src.y + border) / sample_height },
            .{ .x = (src.x + src.w + border) / sample_width, .y = (src.y + border) / sample_height },
            .{ .x = (src.x + src.w + border) / sample_width, .y = (src.y + src.h + border) / sample_height },
            .{ .x = (src.x + border) / sample_width, .y = (src.y + src.h + border) / sample_height },
        };
        const matrix_a: f64 = @floatFromInt(affine.a);
        const matrix_b: f64 = @floatFromInt(affine.b);
        const matrix_c: f64 = @floatFromInt(affine.c);
        const matrix_d: f64 = @floatFromInt(affine.d);
        const translation_x: f64 = @floatFromInt(affine.tx);
        const translation_y: f64 = @floatFromInt(affine.ty);
        for (vertices, positions, uv) |*vertex, position, coordinate| {
            const horizontal: f64 = position.x;
            const vertical: f64 = position.y;
            vertex.* = .{
                .position = .{
                    .x = @floatCast(
                        (matrix_a * horizontal + matrix_b * vertical) / 65536 +
                            translation_x / 256,
                    ),
                    .y = @floatCast(
                        (matrix_c * horizontal + matrix_d * vertical) / 65536 +
                            translation_y / 256,
                    ),
                },
                .tex_coord = coordinate,
                .color = color,
            };
        }
        try renderSampledGeometry(
            ctx,
            vertices,
            &.{ 0, 1, 2, 2, 3, 0 },
            0,
            6,
            target_texture,
            operation.blend(layer.canvas_mode),
            layer.sampling,
            .clamp,
        );
        ctx.state.render_stats.quads_batched += 1;
        ctx.state.render_stats.vertices_submitted += 4;
        ctx.state.render_stats.indices_submitted += 6;
    }

    try clearLayerClip(ctx);
}

fn renderImmediateRun(
    ctx: *Instance,
    run_index: usize,
) RenderError!void {
    const run = ctx.state.immediate_texture_runs[run_index];
    try renderGeometryRun(
        ctx,
        ctx.state.geometry_vertex_buffer[0..],
        ctx.state.geometry_index_buffer[0..],
        0,
        ctx.state.geometry_vertex_count,
        run.index_start,
        run.index_count,
        run.texture_id,
        @intFromEnum(t.LayerBlendMode.normal),
    );
}

fn canMergeImmediateRuns(
    ctx: *Instance,
    current_run_index: usize,
    next_run_index: usize,
) bool {
    const current = ctx.state.immediate_texture_runs[current_run_index];
    const next = ctx.state.immediate_texture_runs[next_run_index];
    return current.texture_id == next.texture_id and
        current.index_start + current.index_count == next.index_start and
        current.vertex_start + current.vertex_count == next.vertex_start;
}

fn renderMergedImmediateRuns(
    ctx: *Instance,
    first_run_index: usize,
    last_run_index: usize,
) RenderError!void {
    const first = ctx.state.immediate_texture_runs[first_run_index];
    const last = ctx.state.immediate_texture_runs[last_run_index];
    const merged_index_count = (last.index_start + last.index_count) - first.index_start;

    try renderGeometryRun(
        ctx,
        ctx.state.geometry_vertex_buffer[0..],
        ctx.state.geometry_index_buffer[0..],
        0,
        ctx.state.geometry_vertex_count,
        first.index_start,
        merged_index_count,
        first.texture_id,
        @intFromEnum(t.LayerBlendMode.normal),
    );
}

fn resetImmediateState(ctx: *Instance) void {
    ctx.draw_storage.clear(draw_storage.immediate_owner) catch unreachable;
    ctx.state.instruction_count = 0;
    ctx.state.draw_list_sorted = false;
    ctx.state.geometry_vertex_count = 0;
    ctx.state.geometry_index_count = 0;
    ctx.state.immediate_run_count = 0;
}

fn executeDrawInstructionsBlit(
    ctx: *Instance,
    reset_stats: bool,
) RenderError!void {
    if (reset_stats) {
        resetRenderStats(ctx);
    }

    var last_tex_id: u16 = 0;
    var last_tint_tex_id: u16 = 0;
    var last_tint = [_]u8{ 0, 0, 0, 0 };
    var tint_initialized = false;

    geometry.sortDrawInstructions(ctx);

    for (ctx.state.sorted_draw_indices[0..ctx.state.instruction_count]) |sorted_ref| {
        const instruction = geometry.commandAt(ctx, sorted_ref.index);
        const tex_id = geometry.unpackTextureId(instruction.sort_key);

        if (tex_id != last_tex_id) {
            ctx.state.render_stats.texture_swaps += 1;
            last_tex_id = tex_id;
        }

        if (ctx.state.operation_sources[tex_id].exclusive) return error.UnsupportedOperationResource;
        const texture = ctx.state.texture_table[tex_id] orelse continue;

        const tint = [_]u8{
            instruction.tint_r,
            instruction.tint_g,
            instruction.tint_b,
            instruction.tint_a,
        };
        if (!tint_initialized or tex_id != last_tint_tex_id or !std.mem.eql(u8, tint[0..], last_tint[0..])) {
            if (ctx.faults.check(.texture_color) or !sdl.SDL_SetTextureColorMod(
                texture,
                instruction.tint_r,
                instruction.tint_g,
                instruction.tint_b,
            )) return error.TextureStateFailed;
            if (ctx.faults.check(.texture_alpha) or !sdl.SDL_SetTextureAlphaMod(
                texture,
                instruction.tint_a,
            ))
                return error.TextureStateFailed;
            last_tint = tint;
            last_tint_tex_id = tex_id;
            tint_initialized = true;
        }

        const src_rect = sdl.SDL_FRect{
            .x = instruction.x_loc,
            .y = instruction.y_loc,
            .w = instruction.width,
            .h = instruction.height,
        };

        const dst_rect = sdl.SDL_FRect{
            .x = instruction.x_dest,
            .y = instruction.y_dest,
            .w = instruction.w_dest,
            .h = instruction.h_dest,
        };

        const is_simple = geometry.isSimpleInstruction(instruction);
        geometry.recordQuadWorkload(ctx, is_simple);

        if (is_simple) {
            if (ctx.faults.check(.blit) or !sdl.SDL_RenderTexture(
                ctx.context.renderer,
                texture,
                &src_rect,
                &dst_rect,
            )) return error.BlitFailed;
        } else {
            const center = if (instruction.center_x != 0 or instruction.center_y != 0)
                &sdl.SDL_FPoint{
                    .x = instruction.center_x,
                    .y = instruction.center_y,
                }
            else
                null;

            if (ctx.faults.check(.blit) or !sdl.SDL_RenderTextureRotated(
                ctx.context.renderer,
                texture,
                &src_rect,
                &dst_rect,
                instruction.angle,
                center,
                @as(c_uint, instruction.flip_mode),
            )) return error.BlitFailed;
        }
        ctx.state.render_stats.draw_calls += 1;
    }
}

pub fn executeCompositeFrame(ctx: *Instance) RenderError!void {
    ctx.frame_ready = false;
    errdefer {
        ctx.changes.present_needed = true;
        ctx.state.layer_masks.present_dirty |= ctx.state.layer_masks.visible;
    }
    if (ctx.draw_storage.transaction != null) return error.TransactionActive;
    if (ctx.context.renderer == null) return error.RendererUnavailable;
    if (ctx.state.active_render_target != -1) return error.TargetActive;
    resetRenderStats(ctx);

    const has_retained = layers.hasVisibleRetainedLayers(ctx);
    if (!ctx.state.use_geometry_backend and has_retained and ctx.context.debug_mode) {
        log.debug(
            "WARNING: Retained layers and retained layer presentation props " ++
                "require geometry replay; ignoring use_geometry_backend=false " ++
                "for this frame",
            .{},
        );
    }
    if (!ctx.state.use_geometry_backend and !has_retained) {
        try executeDrawInstructionsBlit(ctx, true);
        ctx.frame_ready = true;
        return;
    }

    if (layers.hasRetainedOrderDirty(ctx)) buildRetainedCompositeOrder(ctx);
    for (ctx.state.retained_composite_entries[0..ctx.state.retained_composite_entry_count]) |entry|
        try prepareRetainedLayer(ctx, entry.index);
    compileImmediateGeometry(ctx);

    buildCompositeMergeOrder(ctx);

    var entry_index: usize = 0;
    while (entry_index < ctx.state.composite_entry_count) {
        const entry = ctx.state.composite_entries[entry_index];
        switch (entry.domain) {
            .retained => {
                try renderRetainedLayer(ctx, entry.index);
                entry_index += 1;
            },
            .immediate => {
                var last_run_index = entry.index;
                var next_entry_index = entry_index + 1;
                while (next_entry_index < ctx.state.composite_entry_count) {
                    const next_entry = ctx.state.composite_entries[next_entry_index];
                    if (next_entry.domain != .immediate) break;
                    if (!canMergeImmediateRuns(ctx, last_run_index, next_entry.index)) break;
                    last_run_index = next_entry.index;
                    next_entry_index += 1;
                }

                if (last_run_index == entry.index) {
                    try renderImmediateRun(ctx, entry.index);
                } else {
                    try renderMergedImmediateRuns(ctx, entry.index, last_run_index);
                }
                entry_index = next_entry_index;
            },
        }
    }

    ctx.frame_ready = true;
}

pub fn renderImmediateToCurrentTarget(ctx: *Instance) RenderError!void {
    errdefer ctx.changes.present_needed = true;
    if (ctx.draw_storage.transaction != null)
        return error.TransactionActive;
    if (ctx.context.renderer == null)
        return error.RendererUnavailable;
    try executeDrawInstructionsBlit(ctx, false);
    resetImmediateState(ctx);
}

pub fn invalidatePresentation(ctx: *Instance) void {
    ctx.frame_ready = false;
    ctx.changes.present_needed = true;
    ctx.state.layer_masks.present_dirty |= ctx.state.layer_masks.visible;
}

pub fn present(ctx: *Instance) RenderError!void {
    errdefer invalidatePresentation(ctx);
    if (ctx.draw_storage.transaction != null)
        return error.TransactionActive;
    if (ctx.context.renderer == null)
        return error.RendererUnavailable;
    if (!ctx.frame_ready)
        return error.FrameNotReady;
    if (ctx.state.active_render_target != -1)
        return error.TargetActive;
    if (ctx.faults.check(.present) or !sdl.SDL_RenderPresent(ctx.context.renderer))
        return error.PresentFailed;
    ctx.state.layer_masks.present_dirty &= ~ctx.state.layer_masks.visible;
    resetImmediateState(ctx);
    ctx.frame_ready = false;
}
