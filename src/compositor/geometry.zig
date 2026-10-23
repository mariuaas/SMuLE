const std = @import("std");
const log = std.log.scoped(.smule);
const sdl = @import("sdl").sdl;
const Instance = @import("root.zig").Instance;

const t = @import("types.zig");
const store = @import("draw_storage.zig");

fn normalizeChannel(channel: u8) f32 {
    return @as(f32, @floatFromInt(channel)) / 255.0;
}

pub fn spriteHasFragments(
    draw: *const t.DrawInstruction,
    matrix: t.Affine,
    dims: t.TextureDims,
) bool {
    if (draw.width == 0 or draw.height == 0) return false;
    if (draw.x_loc + draw.width > dims.width or
        draw.y_loc + draw.height > dims.height) return false;
    return @as(i128, matrix.a) * matrix.d - @as(i128, matrix.b) * matrix.c != 0;
}

pub fn commandAt(
    ctx: *const Instance,
    index: u32,
) *const t.DrawInstruction {
    return &ctx.draw_storage.backing.commands[index / 64].commands[index % 64];
}

pub fn payload(
    ctx: *const Instance,
    index: u32,
) ?*const store.Payload {
    const backing = &ctx.draw_storage.backing;
    if (backing.payload_handles.len == 0) return null;
    const handle = backing.payload_handles[index];
    return if (handle == store.none) null else &backing.payloads[handle];
}

pub fn lowerPayloads(
    ctx: *Instance,
    layer_id: usize,
    vertices: []sdl.SDL_Vertex,
) void {
    if (ctx.draw_storage.owners[layer_id].payloads == 0) return;
    const layer = &ctx.state.layers[layer_id];
    const scroll_x: f64 = @floatFromInt(layer.content_scroll_x);
    const scroll_y: f64 = @floatFromInt(layer.content_scroll_y);
    const border: f64 = @floatFromInt(layer.backing.border);
    var page = ctx.draw_storage.owners[layer_id].cache_first;
    var offset: usize = 0;
    while (page != store.none) {
        const descriptor = ctx.draw_storage.backing.cache_pages[page];
        for (0..descriptor.used) |slot| {
            const source = ctx.draw_storage.backing.source_handles[page * 64 + slot];
            const metadata = payload(ctx, source);
            const count: usize = if (metadata != null and metadata.?.* == .triangle) 3 else 4;
            if (metadata) |raw| switch (raw.*) {
                .sprite => |matrix| {
                    const draw = commandAt(ctx, source);
                    const matrix_a: f64 = @floatFromInt(matrix.a);
                    const matrix_b: f64 = @floatFromInt(matrix.b);
                    const matrix_c: f64 = @floatFromInt(matrix.c);
                    const matrix_d: f64 = @floatFromInt(matrix.d);
                    const translation_x: f64 = @floatFromInt(matrix.tx);
                    const translation_y: f64 = @floatFromInt(matrix.ty);
                    const corners = [_][2]f64{
                        .{ 0, 0 },
                        .{ draw.width, 0 },
                        .{ draw.width, draw.height },
                        .{ 0, draw.height },
                    };
                    for (corners, vertices[offset..][0..4]) |point, *vertex| {
                        vertex.position.x = @floatCast(
                            (matrix_a * point[0] + matrix_b * point[1]) / 65536 +
                                translation_x / 256 - scroll_x + border,
                        );
                        vertex.position.y = @floatCast(
                            (matrix_c * point[0] + matrix_d * point[1]) / 65536 +
                                translation_y / 256 - scroll_y + border,
                        );
                    }
                },
                .triangle => |triangle| {
                    for (triangle, vertices[offset..][0..3]) |input, *vertex| {
                        const position_x: f64 = @floatFromInt(input.x);
                        const position_y: f64 = @floatFromInt(input.y);
                        vertex.position = .{
                            .x = @floatCast(position_x / 256 - scroll_x + border),
                            .y = @floatCast(position_y / 256 - scroll_y + border),
                        };
                    }
                },
                .line => |line| lowerLine(layer, line, vertices[offset..][0..4]),
                .none => unreachable,
            };
            offset += count;
        }
        page = descriptor.next;
    }
}

fn lowerLine(
    layer: *const t.LayerState,
    line: t.Line,
    vertices: []sdl.SDL_Vertex,
) void {
    const sx: f64 = @floatFromInt(line.x0);
    const sy: f64 = @floatFromInt(line.y0);
    const end_x: f64 = @floatFromInt(line.x1);
    const end_y: f64 = @floatFromInt(line.y1);
    const width: f64 = @floatFromInt(@max(1, line.width));
    const scroll_x: f64 = @floatFromInt(layer.content_scroll_x);
    const scroll_y: f64 = @floatFromInt(layer.content_scroll_y);
    const border: f64 = @floatFromInt(layer.backing.border);
    const dx = end_x - sx;
    const dy = end_y - sy;
    const length = @sqrt(dx * dx + dy * dy);
    const half = width / 2;
    const nx = if (length == 0) half else -dy * half / length;
    const ny = if (length == 0) half else dx * half / length;
    const points = if (length == 0) [4][2]f64{
        .{ sx - half, sy - half },
        .{ sx + half, sy - half },
        .{ sx + half, sy + half },
        .{ sx - half, sy + half },
    } else [4][2]f64{
        .{ sx + nx, sy + ny },
        .{ sx + dx + nx, sy + dy + ny },
        .{ sx + dx - nx, sy + dy - ny },
        .{ sx - nx, sy - ny },
    };
    for (points, vertices) |point, *vertex| vertex.position = .{
        .x = @floatCast(point[0] - scroll_x + border),
        .y = @floatCast(point[1] - scroll_y + border),
    };
}

pub fn transferCache(
    ctx: *Instance,
    layer_id: usize,
    comptime store_cache: bool,
) void {
    const layer = &ctx.state.layers[layer_id];
    const bytes = @as(usize, layer.cached_vertex_count) * @sizeOf(sdl.SDL_Vertex) +
        @as(usize, layer.cached_index_count) * @sizeOf(u32) +
        @as(usize, layer.run_count) * @sizeOf(t.TextureRun);
    if (store_cache) ctx.canvas_stats.cache_store_bytes += bytes else ctx.canvas_stats.cache_gather_bytes += bytes;
    var page = ctx.draw_storage.owners[layer_id].cache_first;
    var vertex_offset: usize = 0;
    var index_offset: usize = 0;
    var run_offset: usize = 0;
    while (page != store.none) {
        const cached = &ctx.draw_storage.backing.cache[page];
        const vertex_count = @min(cached.vertices.len, layer.cached_vertex_count - vertex_offset);
        const index_count = @min(cached.indices.len, layer.cached_index_count - index_offset);
        const run_count = @min(cached.runs.len, layer.run_count - run_offset);
        if (store_cache) {
            @memcpy(cached.vertices[0..vertex_count], ctx.state.cached_vertex_buffer[vertex_offset..][0..vertex_count]);
            @memcpy(cached.indices[0..index_count], ctx.state.cached_index_buffer[index_offset..][0..index_count]);
            @memcpy(cached.runs[0..run_count], ctx.draw_storage.backing.runs[run_offset..][0..run_count]);
        } else {
            @memcpy(ctx.state.cached_vertex_buffer[vertex_offset..][0..vertex_count], cached.vertices[0..vertex_count]);
            @memcpy(ctx.state.cached_index_buffer[index_offset..][0..index_count], cached.indices[0..index_count]);
            @memcpy(ctx.draw_storage.backing.runs[run_offset..][0..run_count], cached.runs[0..run_count]);
        }
        vertex_offset += vertex_count;
        index_offset += index_count;
        run_offset += run_count;
        page = ctx.draw_storage.backing.cache_pages[page].next;
    }
    layer.runs = ctx.draw_storage.backing.runs[0..layer.run_count];
}

pub fn cachedVertex(
    ctx: *const Instance,
    layer_id: usize,
    index: usize,
) sdl.SDL_Vertex {
    std.debug.assert(index < ctx.state.layers[layer_id].cached_vertex_count);
    var page = ctx.draw_storage.owners[layer_id].cache_first;
    for (0..index / 256) |_| page = ctx.draw_storage.backing.cache_pages[page].next;
    return ctx.draw_storage.backing.cache[page].vertices[index % 256];
}

pub fn cachedQuad(
    ctx: *const Instance,
    layer_id: usize,
) [4]sdl.SDL_Vertex {
    var result: [4]sdl.SDL_Vertex = undefined;
    for (&result, 0..) |*vertex, index| vertex.* = cachedVertex(ctx, layer_id, index);
    return result;
}

pub fn triangleArea(vertices: [3]t.TriangleVertex) i128 {
    const dx1: i128 = @as(i128, vertices[1].x) - vertices[0].x;
    const dy1: i128 = @as(i128, vertices[1].y) - vertices[0].y;
    const dx2: i128 = @as(i128, vertices[2].x) - vertices[0].x;
    const dy2: i128 = @as(i128, vertices[2].y) - vertices[0].y;
    return dx1 * dy2 - dy1 * dx2;
}

pub fn emitTriangleGeometry(
    ctx: *Instance,
    layer_id: usize,
    triangle: [3]t.TriangleVertex,
    dims: t.TextureDims,
    untextured: bool,
    vertex_count: *usize,
    index_count: *usize,
) bool {
    if (triangleArea(triangle) == 0 or
        (!untextured and (dims.width <= 0 or dims.height <= 0)))
        return false;
    const layer = &ctx.state.layers[layer_id];
    for (triangle, 0..) |vertex, index| {
        const texture_u: f64 = @floatFromInt(vertex.u);
        const texture_v: f64 = @floatFromInt(vertex.v);
        ctx.state.cached_vertex_buffer[layer.cached_vertex_start + vertex_count.* + index] = .{
            .position = .{ .x = 0, .y = 0 },
            .tex_coord = .{
                .x = if (untextured) 0 else @floatCast(texture_u / 256 / dims.width),
                .y = if (untextured) 0 else @floatCast(texture_v / 256 / dims.height),
            },
            .color = .{
                .r = normalizeChannel(vertex.color[0]),
                .g = normalizeChannel(vertex.color[1]),
                .b = normalizeChannel(vertex.color[2]),
                .a = normalizeChannel(vertex.color[3]),
            },
        };
        ctx.state.cached_index_buffer[layer.cached_index_start + index_count.* + index] = @intCast(vertex_count.* + index);
    }
    vertex_count.* += 3;
    index_count.* += 3;
    return true;
}

pub fn packKey(
    priority: i32,
    tex_id: u16,
    seq: usize,
    is_simple: bool,
) u64 {
    const p = std.math.clamp(priority, -32768, 32767);
    const p_u: u64 = @as(u64, @intCast(p + 32768));
    const tex_u: u64 = @as(u64, tex_id);
    const complex_bit: u64 = if (is_simple) 0 else (1 << 31);
    const seq_u: u64 = (@as(u64, @intCast(seq)) & 0x7FFF_FFFF) | complex_bit;
    return (p_u << 48) | (tex_u << 32) | seq_u;
}

pub fn unpackTextureId(sort_key: u64) u16 {
    return @truncate(sort_key >> 32);
}

pub fn unpackPriority(sort_key: u64) i16 {
    const biased: u16 = @truncate(sort_key >> 48);
    return @as(i16, @bitCast(biased -% 32768));
}

pub fn compareRenderKey(
    _: void,
    a: t.SortedDrawRef,
    b: t.SortedDrawRef,
) bool {
    const left_priority = unpackPriority(a.key);
    const right_priority = unpackPriority(b.key);
    if (left_priority != right_priority) return left_priority < right_priority;
    return (a.key & 0x7FFF_FFFF) < (b.key & 0x7FFF_FFFF);
}

fn emitGeometryVertexTo(
    buffer: []sdl.SDL_Vertex,
    index: usize,
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) void {
    buffer[index] = .{
        .position = .{ .x = x, .y = y },
        .color = .{ .r = r, .g = g, .b = b, .a = a },
        .tex_coord = .{ .x = u, .y = v },
    };
}

fn emitGeometryIndicesTo(
    index_buffer: []u32,
    absolute_index_start: usize,
    local_index_count: usize,
    base_index: usize,
) void {
    index_buffer[absolute_index_start + local_index_count + 0] = @intCast(base_index + 0);
    index_buffer[absolute_index_start + local_index_count + 1] = @intCast(base_index + 1);
    index_buffer[absolute_index_start + local_index_count + 2] = @intCast(base_index + 2);
    index_buffer[absolute_index_start + local_index_count + 3] = @intCast(base_index + 2);
    index_buffer[absolute_index_start + local_index_count + 4] = @intCast(base_index + 3);
    index_buffer[absolute_index_start + local_index_count + 5] = @intCast(base_index + 0);
}

pub fn emitQuadGeometryTo(
    vertex_buffer: []sdl.SDL_Vertex,
    index_buffer: []u32,
    absolute_vertex_start: usize,
    absolute_index_start: usize,
    vertex_count: *usize,
    index_count: *usize,
    instruction: *const t.DrawInstruction,
    texture_dims: t.TextureDims,
) bool {
    return emitQuadGeometryInto(
        vertex_buffer,
        index_buffer,
        absolute_vertex_start,
        absolute_index_start,
        vertex_count,
        index_count,
        instruction,
        texture_dims,
        instruction.kind == .clamped_quad,
    );
}

fn emitQuadGeometryInto(
    vertex_buffer: []sdl.SDL_Vertex,
    index_buffer: []u32,
    absolute_vertex_start: usize,
    absolute_index_start: usize,
    vertex_count: *usize,
    index_count: *usize,
    instruction: *const t.DrawInstruction,
    texture_dims: t.TextureDims,
    clamp_uv: bool,
) bool {
    if (texture_dims.width <= 0 or texture_dims.height <= 0) return false;

    const base_index = vertex_count.*;

    var tex_u0 = instruction.x_loc / texture_dims.width;
    var tex_v0 = instruction.y_loc / texture_dims.height;
    var tex_u1 = (instruction.x_loc + instruction.width) / texture_dims.width;
    var tex_v1 = (instruction.y_loc + instruction.height) / texture_dims.height;

    if (clamp_uv) {
        tex_u0 = std.math.clamp(tex_u0, 0.0, 1.0);
        tex_v0 = std.math.clamp(tex_v0, 0.0, 1.0);
        tex_u1 = std.math.clamp(tex_u1, 0.0, 1.0);
        tex_v1 = std.math.clamp(tex_v1, 0.0, 1.0);
    }

    if ((instruction.flip_mode & 1) != 0) {
        const swap = tex_u0;
        tex_u0 = tex_u1;
        tex_u1 = swap;
    }
    if ((instruction.flip_mode & 2) != 0) {
        const swap = tex_v0;
        tex_v0 = tex_v1;
        tex_v1 = swap;
    }

    const tint_r = normalizeChannel(instruction.tint_r);
    const tint_g = normalizeChannel(instruction.tint_g);
    const tint_b = normalizeChannel(instruction.tint_b);
    const tint_a = normalizeChannel(instruction.tint_a);

    var positions = [_]sdl.SDL_FPoint{
        .{ .x = 0, .y = 0 },
        .{ .x = instruction.w_dest, .y = 0 },
        .{ .x = instruction.w_dest, .y = instruction.h_dest },
        .{ .x = 0, .y = instruction.h_dest },
    };

    const pivot_local = if (instruction.center_x == 0 and instruction.center_y == 0)
        sdl.SDL_FPoint{ .x = instruction.w_dest * 0.5, .y = instruction.h_dest * 0.5 }
    else
        sdl.SDL_FPoint{ .x = instruction.center_x, .y = instruction.center_y };

    if (instruction.angle != 0.0) {
        const radians = instruction.angle * std.math.pi / 180.0;
        const sin_theta: f32 = @floatCast(std.math.sin(radians));
        const cos_theta: f32 = @floatCast(std.math.cos(radians));

        for (&positions) |*position| {
            const local_x = position.x - pivot_local.x;
            const local_y = position.y - pivot_local.y;
            position.x = instruction.x_dest + pivot_local.x + (local_x * cos_theta - local_y * sin_theta);
            position.y = instruction.y_dest + pivot_local.y + (local_x * sin_theta + local_y * cos_theta);
        }
    } else {
        for (&positions) |*position| {
            position.x += instruction.x_dest;
            position.y += instruction.y_dest;
        }
    }

    emitGeometryVertexTo(
        vertex_buffer,
        absolute_vertex_start + base_index + 0,
        positions[0].x,
        positions[0].y,
        tex_u0,
        tex_v0,
        tint_r,
        tint_g,
        tint_b,
        tint_a,
    );
    emitGeometryVertexTo(
        vertex_buffer,
        absolute_vertex_start + base_index + 1,
        positions[1].x,
        positions[1].y,
        tex_u1,
        tex_v0,
        tint_r,
        tint_g,
        tint_b,
        tint_a,
    );
    emitGeometryVertexTo(
        vertex_buffer,
        absolute_vertex_start + base_index + 2,
        positions[2].x,
        positions[2].y,
        tex_u1,
        tex_v1,
        tint_r,
        tint_g,
        tint_b,
        tint_a,
    );
    emitGeometryVertexTo(
        vertex_buffer,
        absolute_vertex_start + base_index + 3,
        positions[3].x,
        positions[3].y,
        tex_u0,
        tex_v1,
        tint_r,
        tint_g,
        tint_b,
        tint_a,
    );

    emitGeometryIndicesTo(
        index_buffer,
        absolute_index_start,
        index_count.*,
        base_index,
    );

    vertex_count.* += 4;
    index_count.* += 6;
    return true;
}

pub fn recordQuadBatchWorkload(
    ctx: *Instance,
    simple_count: usize,
    complex_count: usize,
) void {
    const total = simple_count + complex_count;
    ctx.state.render_stats.quads_batched += total;
    ctx.state.render_stats.vertices_submitted += total * 4;
    ctx.state.render_stats.indices_submitted += total * 6;
    ctx.state.render_stats.simple_draws += simple_count;
    ctx.state.render_stats.complex_draws += complex_count;
}

pub fn recordQuadWorkload(
    ctx: *Instance,
    is_simple: bool,
) void {
    recordQuadBatchWorkload(ctx, if (is_simple) 1 else 0, if (is_simple) 0 else 1);
}

pub fn isSimpleInstruction(
    instruction: *const t.DrawInstruction,
) bool {
    return instruction.kind == .clamped_quad and instruction.angle == 0.0 and
        instruction.flip_mode == 0 and
        instruction.center_x == 0 and
        instruction.center_y == 0;
}

fn emitGeometryVertex(
    ctx: *Instance,
    index: usize,
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) void {
    ctx.state.geometry_vertex_buffer[index] = .{
        .position = .{ .x = x, .y = y },
        .color = .{ .r = r, .g = g, .b = b, .a = a },
        .tex_coord = .{ .x = u, .y = v },
    };
}

fn emitGeometryIndices(
    ctx: *Instance,
    base_index: usize,
) void {
    ctx.state.geometry_index_buffer[ctx.state.geometry_index_count + 0] = @intCast(base_index + 0);
    ctx.state.geometry_index_buffer[ctx.state.geometry_index_count + 1] = @intCast(base_index + 1);
    ctx.state.geometry_index_buffer[ctx.state.geometry_index_count + 2] = @intCast(base_index + 2);
    ctx.state.geometry_index_buffer[ctx.state.geometry_index_count + 3] = @intCast(base_index + 2);
    ctx.state.geometry_index_buffer[ctx.state.geometry_index_count + 4] = @intCast(base_index + 3);
    ctx.state.geometry_index_buffer[ctx.state.geometry_index_count + 5] = @intCast(base_index + 0);
}

fn clampVec01(values: t.GeometryLaneVec) t.GeometryLaneVec {
    return @max(
        @as(t.GeometryLaneVec, @splat(0.0)),
        @min(@as(t.GeometryLaneVec, @splat(1.0)), values),
    );
}

fn loadGeometryCompilerBlock(
    ctx: *Instance,
    block: *t.GeometryCompilerBlock,
    sorted_instruction_refs: []const t.SortedDrawRef,
) void {
    block.* = .{};
    block.count = sorted_instruction_refs.len;

    for (sorted_instruction_refs, 0..) |sorted_ref, lane| {
        const instruction = commandAt(ctx, sorted_ref.index);
        block.x_loc[lane] = instruction.x_loc;
        block.y_loc[lane] = instruction.y_loc;
        block.width[lane] = instruction.width;
        block.height[lane] = instruction.height;
        block.x_dest[lane] = instruction.x_dest;
        block.y_dest[lane] = instruction.y_dest;
        block.w_dest[lane] = instruction.w_dest;
        block.h_dest[lane] = instruction.h_dest;
        block.center_x[lane] = instruction.center_x;
        block.center_y[lane] = instruction.center_y;
        block.angle[lane] = instruction.angle;
        block.flip_mode[lane] = instruction.flip_mode;
        block.tint_r[lane] = normalizeChannel(instruction.tint_r);
        block.tint_g[lane] = normalizeChannel(instruction.tint_g);
        block.tint_b[lane] = normalizeChannel(instruction.tint_b);
        block.tint_a[lane] = normalizeChannel(instruction.tint_a);
    }
}

fn emitSimpleGeometryBlock(
    ctx: *Instance,
    block: *const t.GeometryCompilerBlock,
    texture_dims: t.TextureDims,
) bool {
    if (block.count == 0) return true;
    if (ctx.state.geometry_vertex_count + block.count * 4 > ctx.state.geometry_vertex_buffer.len or
        ctx.state.geometry_index_count + block.count * 6 > ctx.state.geometry_index_buffer.len)
    {
        return false;
    }

    const dims_x = @as(t.GeometryLaneVec, @splat(texture_dims.width));
    const dims_y = @as(t.GeometryLaneVec, @splat(texture_dims.height));

    const src_x: t.GeometryLaneVec = @bitCast(block.x_loc);
    const src_y: t.GeometryLaneVec = @bitCast(block.y_loc);
    const src_w: t.GeometryLaneVec = @bitCast(block.width);
    const src_h: t.GeometryLaneVec = @bitCast(block.height);
    const dst_x: t.GeometryLaneVec = @bitCast(block.x_dest);
    const dst_y: t.GeometryLaneVec = @bitCast(block.y_dest);
    const dst_w: t.GeometryLaneVec = @bitCast(block.w_dest);
    const dst_h: t.GeometryLaneVec = @bitCast(block.h_dest);

    const tex_u0: [t.geometry_compiler_lanes]f32 = @bitCast(clampVec01(src_x / dims_x));
    const tex_v0: [t.geometry_compiler_lanes]f32 = @bitCast(clampVec01(src_y / dims_y));
    const tex_u1: [t.geometry_compiler_lanes]f32 = @bitCast(clampVec01((src_x + src_w) / dims_x));
    const tex_v1: [t.geometry_compiler_lanes]f32 = @bitCast(clampVec01((src_y + src_h) / dims_y));

    const x0: [t.geometry_compiler_lanes]f32 = @bitCast(dst_x);
    const y0: [t.geometry_compiler_lanes]f32 = @bitCast(dst_y);
    const x1: [t.geometry_compiler_lanes]f32 = @bitCast(dst_x + dst_w);
    const y1: [t.geometry_compiler_lanes]f32 = @bitCast(dst_y + dst_h);

    for (0..block.count) |lane| {
        const base_index = ctx.state.geometry_vertex_count;

        emitGeometryVertex(
            ctx,
            base_index + 0,
            x0[lane],
            y0[lane],
            tex_u0[lane],
            tex_v0[lane],
            block.tint_r[lane],
            block.tint_g[lane],
            block.tint_b[lane],
            block.tint_a[lane],
        );
        emitGeometryVertex(
            ctx,
            base_index + 1,
            x1[lane],
            y0[lane],
            tex_u1[lane],
            tex_v0[lane],
            block.tint_r[lane],
            block.tint_g[lane],
            block.tint_b[lane],
            block.tint_a[lane],
        );
        emitGeometryVertex(
            ctx,
            base_index + 2,
            x1[lane],
            y1[lane],
            tex_u1[lane],
            tex_v1[lane],
            block.tint_r[lane],
            block.tint_g[lane],
            block.tint_b[lane],
            block.tint_a[lane],
        );
        emitGeometryVertex(
            ctx,
            base_index + 3,
            x0[lane],
            y1[lane],
            tex_u0[lane],
            tex_v1[lane],
            block.tint_r[lane],
            block.tint_g[lane],
            block.tint_b[lane],
            block.tint_a[lane],
        );

        emitGeometryIndices(ctx, base_index);

        ctx.state.geometry_vertex_count += 4;
        ctx.state.geometry_index_count += 6;
    }

    recordQuadBatchWorkload(ctx, block.count, 0);
    return true;
}

fn emitTransformedGeometryBlock(
    ctx: *Instance,
    block: *const t.GeometryCompilerBlock,
    texture_dims: t.TextureDims,
) bool {
    if (block.count == 0) return true;
    if (ctx.state.geometry_vertex_count + block.count * 4 > ctx.state.geometry_vertex_buffer.len or
        ctx.state.geometry_index_count + block.count * 6 > ctx.state.geometry_index_buffer.len)
    {
        return false;
    }

    const dims_x = @as(t.GeometryLaneVec, @splat(texture_dims.width));
    const dims_y = @as(t.GeometryLaneVec, @splat(texture_dims.height));

    const src_x: t.GeometryLaneVec = @bitCast(block.x_loc);
    const src_y: t.GeometryLaneVec = @bitCast(block.y_loc);
    const src_w: t.GeometryLaneVec = @bitCast(block.width);
    const src_h: t.GeometryLaneVec = @bitCast(block.height);
    const dst_x: t.GeometryLaneVec = @bitCast(block.x_dest);
    const dst_y: t.GeometryLaneVec = @bitCast(block.y_dest);
    const dst_w: t.GeometryLaneVec = @bitCast(block.w_dest);
    const dst_h: t.GeometryLaneVec = @bitCast(block.h_dest);

    var tex_u0: [t.geometry_compiler_lanes]f32 = @bitCast(clampVec01(src_x / dims_x));
    var tex_v0: [t.geometry_compiler_lanes]f32 = @bitCast(clampVec01(src_y / dims_y));
    var tex_u1: [t.geometry_compiler_lanes]f32 = @bitCast(clampVec01((src_x + src_w) / dims_x));
    var tex_v1: [t.geometry_compiler_lanes]f32 = @bitCast(clampVec01((src_y + src_h) / dims_y));

    for (0..block.count) |lane| {
        if ((block.flip_mode[lane] & 1) != 0) {
            const swap = tex_u0[lane];
            tex_u0[lane] = tex_u1[lane];
            tex_u1[lane] = swap;
        }
        if ((block.flip_mode[lane] & 2) != 0) {
            const swap = tex_v0[lane];
            tex_v0[lane] = tex_v1[lane];
            tex_v1[lane] = swap;
        }
    }

    var pivot_x_values = [_]f32{0} ** t.geometry_compiler_lanes;
    var pivot_y_values = [_]f32{0} ** t.geometry_compiler_lanes;
    var radians_values = [_]f32{0} ** t.geometry_compiler_lanes;

    for (0..block.count) |lane| {
        const default_pivot = block.center_x[lane] == 0 and block.center_y[lane] == 0;
        pivot_x_values[lane] = if (default_pivot) block.w_dest[lane] * 0.5 else block.center_x[lane];
        pivot_y_values[lane] = if (default_pivot) block.h_dest[lane] * 0.5 else block.center_y[lane];
        radians_values[lane] = @floatCast(block.angle[lane] * std.math.pi / 180.0);
    }

    const pivot_x: t.GeometryLaneVec = @bitCast(pivot_x_values);
    const pivot_y: t.GeometryLaneVec = @bitCast(pivot_y_values);
    const radians: t.GeometryLaneVec = @bitCast(radians_values);
    const sin_theta = @sin(radians);
    const cos_theta = @cos(radians);

    const corner_x = [_]t.GeometryLaneVec{
        @as(t.GeometryLaneVec, @splat(0.0)),
        dst_w,
        dst_w,
        @as(t.GeometryLaneVec, @splat(0.0)),
    };
    const corner_y = [_]t.GeometryLaneVec{
        @as(t.GeometryLaneVec, @splat(0.0)),
        @as(t.GeometryLaneVec, @splat(0.0)),
        dst_h,
        dst_h,
    };

    var corner_positions_x = [_][t.geometry_compiler_lanes]f32{[_]f32{0} ** t.geometry_compiler_lanes} ** 4;
    var corner_positions_y = [_][t.geometry_compiler_lanes]f32{[_]f32{0} ** t.geometry_compiler_lanes} ** 4;

    for (0..4) |corner| {
        const local_x = corner_x[corner] - pivot_x;
        const local_y = corner_y[corner] - pivot_y;
        const position_x = dst_x + pivot_x + (local_x * cos_theta - local_y * sin_theta);
        const position_y = dst_y + pivot_y + (local_x * sin_theta + local_y * cos_theta);
        corner_positions_x[corner] = @bitCast(position_x);
        corner_positions_y[corner] = @bitCast(position_y);
    }

    for (0..block.count) |lane| {
        const base_index = ctx.state.geometry_vertex_count;

        emitGeometryVertex(
            ctx,
            base_index + 0,
            corner_positions_x[0][lane],
            corner_positions_y[0][lane],
            tex_u0[lane],
            tex_v0[lane],
            block.tint_r[lane],
            block.tint_g[lane],
            block.tint_b[lane],
            block.tint_a[lane],
        );
        emitGeometryVertex(
            ctx,
            base_index + 1,
            corner_positions_x[1][lane],
            corner_positions_y[1][lane],
            tex_u1[lane],
            tex_v0[lane],
            block.tint_r[lane],
            block.tint_g[lane],
            block.tint_b[lane],
            block.tint_a[lane],
        );
        emitGeometryVertex(
            ctx,
            base_index + 2,
            corner_positions_x[2][lane],
            corner_positions_y[2][lane],
            tex_u1[lane],
            tex_v1[lane],
            block.tint_r[lane],
            block.tint_g[lane],
            block.tint_b[lane],
            block.tint_a[lane],
        );
        emitGeometryVertex(
            ctx,
            base_index + 3,
            corner_positions_x[3][lane],
            corner_positions_y[3][lane],
            tex_u0[lane],
            tex_v1[lane],
            block.tint_r[lane],
            block.tint_g[lane],
            block.tint_b[lane],
            block.tint_a[lane],
        );

        emitGeometryIndices(ctx, base_index);

        ctx.state.geometry_vertex_count += 4;
        ctx.state.geometry_index_count += 6;
    }

    recordQuadBatchWorkload(ctx, 0, block.count);
    return true;
}

fn emitQuadGeometry(
    ctx: *Instance,
    instruction: *const t.DrawInstruction,
    texture_dims: t.TextureDims,
) bool {
    if (texture_dims.width <= 0 or texture_dims.height <= 0) return false;
    if (ctx.state.geometry_vertex_count + 4 > ctx.state.geometry_vertex_buffer.len or
        ctx.state.geometry_index_count + 6 > ctx.state.geometry_index_buffer.len)
    {
        return false;
    }

    if (!emitQuadGeometryInto(
        ctx.state.geometry_vertex_buffer,
        ctx.state.geometry_index_buffer,
        0,
        0,
        &ctx.state.geometry_vertex_count,
        &ctx.state.geometry_index_count,
        instruction,
        texture_dims,
        true,
    )) return false;

    recordQuadWorkload(ctx, isSimpleInstruction(instruction));
    return true;
}

pub fn compileGeometryTextureRun(
    ctx: *Instance,
    texture_id: u16,
    sorted_instruction_refs: []const t.SortedDrawRef,
    texture_dims: t.TextureDims,
) void {
    var split: usize = 0;
    while (split < sorted_instruction_refs.len and
        (sorted_instruction_refs[split].key & (1 << 31)) == 0) : (split += 1)
    {}

    var index: usize = 0;
    while (index < split) {
        const block_count = @min(t.geometry_compiler_lanes, split - index);
        loadGeometryCompilerBlock(
            ctx,
            &ctx.state.geometry_compiler_block,
            sorted_instruction_refs[index .. index + block_count],
        );
        if (!emitSimpleGeometryBlock(ctx, &ctx.state.geometry_compiler_block, texture_dims)) {
            flushGeometryBatch(ctx, texture_id);
            if (!emitSimpleGeometryBlock(ctx, &ctx.state.geometry_compiler_block, texture_dims) and ctx.context.debug_mode) {
                log.debug(
                    "WARNING: Failed to emit geometry compiler block " ++
                        "(TexID: {d}, Count: {d})",
                    .{ texture_id, block_count },
                );
            }
        }
        index += block_count;
    }

    index = split;
    while (index < sorted_instruction_refs.len) {
        const block_count = @min(t.geometry_compiler_lanes, sorted_instruction_refs.len - index);
        loadGeometryCompilerBlock(ctx, &ctx.state.geometry_compiler_block, sorted_instruction_refs[index .. index + block_count]);
        if (!emitTransformedGeometryBlock(ctx, &ctx.state.geometry_compiler_block, texture_dims)) {
            flushGeometryBatch(ctx, texture_id);
            if (!emitTransformedGeometryBlock(ctx, &ctx.state.geometry_compiler_block, texture_dims) and ctx.context.debug_mode) {
                log.debug(
                    "WARNING: Failed to emit transformed geometry block " ++
                        "(TexID: {d}, Count: {d})",
                    .{ texture_id, block_count },
                );
            }
        }
        index += block_count;
    }
}

pub fn flushGeometryBatch(
    ctx: *Instance,
    texture_id: u16,
) void {
    if (ctx.state.geometry_vertex_count == 0 or ctx.state.geometry_index_count == 0) return;

    const texture = ctx.state.texture_table[texture_id] orelse {
        ctx.state.geometry_vertex_count = 0;
        ctx.state.geometry_index_count = 0;
        return;
    };
    _ = sdl.SDL_SetTextureColorMod(texture, 255, 255, 255);
    _ = sdl.SDL_SetTextureAlphaMod(texture, 255);

    const first_vertex = &ctx.state.geometry_vertex_buffer[0];
    const xy_ptr: [*c]const f32 = @ptrCast(&first_vertex.position.x);
    const color_ptr: [*c]const sdl.SDL_FColor = @ptrCast(&first_vertex.color);
    const uv_ptr: [*c]const f32 = @ptrCast(&first_vertex.tex_coord.x);

    if (sdl.SDL_RenderGeometryRaw(
        ctx.context.renderer,
        texture,
        xy_ptr,
        @sizeOf(sdl.SDL_Vertex),
        color_ptr,
        @sizeOf(sdl.SDL_Vertex),
        uv_ptr,
        @sizeOf(sdl.SDL_Vertex),
        @intCast(ctx.state.geometry_vertex_count),
        @ptrCast(&ctx.state.geometry_index_buffer[0]),
        @intCast(ctx.state.geometry_index_count),
        @sizeOf(u32),
    )) {
        ctx.state.render_stats.draw_calls += 1;
        ctx.state.render_stats.texture_swaps += 1;
    }

    ctx.state.geometry_vertex_count = 0;
    ctx.state.geometry_index_count = 0;
}

pub fn sortDrawInstructions(ctx: *Instance) void {
    if (ctx.state.instruction_count == 0 or ctx.state.draw_list_sorted) return;
    var iterator = ctx.draw_storage.iterator(store.immediate_owner) catch unreachable;
    var index: usize = 0;
    while (iterator.nextRef()) |reference| : (index += 1) ctx.state.sorted_draw_indices[index] = reference;
    std.mem.sort(t.SortedDrawRef, ctx.state.sorted_draw_indices[0..index], {}, compareRenderKey);
    ctx.state.draw_list_sorted = true;
}
