const std = @import("std");
const sdl = @import("sdl").sdl;

pub const max_graphics = 64;
pub const max_palettes = 32;
pub const max_immediate = 16384;
pub const max_sprite_batch_commands = 2048;
pub const max_layers = 32;
pub const max_layer_batch_commands = 512;
pub const max_texture_runs_per_layer = max_slab_size;
pub const max_slab_size = 256;
pub const immediate_layer_id: u8 = 0xFF;
pub const max_retained_draw_instructions = max_layers * max_slab_size;
pub const default_draw_capacity = max_immediate + max_retained_draw_instructions;
pub const max_cached_vertices = max_retained_draw_instructions * 4;
pub const max_cached_indices = max_retained_draw_instructions * 6;
pub const max_user_dynamic_textures = 64;
pub const max_dynamic_textures = max_user_dynamic_textures + 1;
pub const max_render_targets = 8;
pub const max_texture_ids = max_graphics * max_palettes + max_dynamic_textures + max_layers + max_render_targets + 1;
pub const max_geometry_vertices = max_immediate * 4;
pub const max_geometry_indices = max_immediate * 6;
pub const geometry_buffer_alignment = 64;
pub const geometry_compiler_lanes = 4;

pub const FlipMode = enum(c_int) {
    none = 0,
    horizontal = 1,
    vertical = 2,
    both = 3,
};

pub const FrameState = enum {
    idle,
    updating,
    compiling,
    executing,
};

pub const FrameStats = struct {
    frame_number: u64 = 0,
    /// Attempts through the legacy bulk entry point, after frame-state validation.
    /// Scalar and rich-primitive entry points do not contribute to this counter.
    bulk_api_calls: usize = 0,
    bulk_items_submitted: usize = 0,
    /// Host-supplied update duration in microseconds.
    time_host_update: u64 = 0,
    time_compile: u64 = 0,
    time_execute: u64 = 0,
};

pub const RenderStats = struct {
    draw_calls: usize = 0,
    simple_draws: usize = 0,
    complex_draws: usize = 0,
    texture_swaps: usize = 0,
    quads_batched: usize = 0,
    vertices_submitted: usize = 0,
    indices_submitted: usize = 0,
};

pub const TextureDims = struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub const TextureRun = struct {
    texture_id: u16 = 0,
    raw_uv: bool = false,
    isolate_nearest: bool = false,
    vertex_start: u32 = 0,
    vertex_count: u32 = 0,
    index_start: u32 = 0,
    index_count: u32 = 0,
    composite_priority: i16 = 0,
};

/// legacy_rgba preserves Substrate's straight-alpha behavior. Normal operation
/// canvases store premultiplied RGB/coverage, additive canvases store energy with
/// zero alpha, and multiply canvases store factors with alpha one.
pub const CanvasMode = enum { legacy_rgba, normal, additive, multiply };
pub const Sampling = enum(u8) { nearest, bilinear };
pub const Addressing = enum(u8) { clamp, repeat };

/// Signed 16.16 matrix coefficients and signed 24.8 pixel translations.
pub const Affine = struct {
    a: i32 = 65536,
    b: i32 = 0,
    c: i32 = 0,
    d: i32 = 65536,
    tx: i32 = 0,
    ty: i32 = 0,
};

pub const AffineSprite = struct {
    texture_id: u16,
    layer_id: u8,
    priority: c_int = 0,
    sx: u16 = 0,
    sy: u16 = 0,
    sw: u16,
    sh: u16,
    affine: Affine = .{},
    tint: [4]u8 = .{ 255, 255, 255, 255 },
};

pub const SpriteSlab = struct {
    transforms: [max_slab_size]?Affine = @splat(null),
    compiled_slots: [max_slab_size]u16 = undefined,
    compiled_count: u16 = 0,
};

/// Signed 24.8 canvas coordinates and texel UVs, with straight RGBA8 input color.
/// Color is premultiplied before interpolation by the operation rendering path.
pub const TriangleVertex = struct {
    x: i32,
    y: i32,
    u: i32 = 0,
    v: i32 = 0,
    color: [4]u8 = .{ 255, 255, 255, 255 },
};

pub const TexturedTriangle = struct {
    texture_id: u16 = 0xffff,
    layer_id: u8,
    priority: c_int = 0,
    vertices: [3]TriangleVertex,
};

pub const TriangleSlab = struct {
    vertices: [max_slab_size]?[3]TriangleVertex = @splat(null),
    compiled_slots: [max_slab_size]u16 = undefined,
    compiled_count: u16 = 0,
};

pub const Line = struct {
    layer_id: u8,
    priority: c_int = 0,
    x0: i16,
    y0: i16,
    x1: i16,
    y1: i16,
    width: u8 = 1,
    color: [4]u8 = .{ 255, 255, 255, 255 },
};

/// Command encoding policy. The separate Payload union identifies rich primitives.
/// Values and byte width are transport-compatible; unknown values are validated
/// at staged submission instead of becoming an invalid enum representation.
pub const DrawKind = enum(u8) {
    clamped_quad = 0,
    raw_uv_quad = 1,
    line = 2,
    _,
};

pub const LineSlab = struct {
    lines: [max_slab_size]?Line = @splat(null),
    compiled: [max_slab_size]struct { slot: u16, vertex: u16 } = undefined,
    compiled_count: u16 = 0,
};

pub const SurfaceClip = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
};

pub const CanvasStats = struct {
    line_metadata_allocations: usize = 0,
    target_allocations: usize = 0,
    compiled_layers: usize = 0,
    rasterized_canvases: usize = 0,
    lowered_vertices: usize = 0,
    cache_store_bytes: usize = 0,
    cache_gather_bytes: usize = 0,
};

pub const CanvasBacking = struct {
    width: c_int = 0,
    height: c_int = 0,
    border: u8 = 0,
};

pub const LayerState = struct {
    canvas_mode: CanvasMode = .legacy_rgba,
    affine: Affine = .{},
    sampling: Sampling = .nearest,
    backing: CanvasBacking = .{},
    canvas_width: u16 = 0,
    canvas_height: u16 = 0,
    content_scroll_x: i32 = 0,
    content_scroll_y: i32 = 0,
    surface_clip: SurfaceClip = .{},
    z: i16 = 0,
    visible: bool = true,
    opacity: u8 = 255,
    tint_r: u8 = 255,
    tint_g: u8 = 255,
    tint_b: u8 = 255,
    clear_r: u8 = 0,
    clear_g: u8 = 0,
    clear_b: u8 = 0,
    clear_a: u8 = 0,
    geometry_dirty: bool = false,
    order_dirty: bool = false,
    target_dirty: bool = false,
    present_dirty: bool = false,
    slab_count: u32 = 0,
    target_texture_id: u16 = 0,
    cached_vertex_start: u32 = 0,
    cached_vertex_count: u32 = 0,
    cached_index_start: u32 = 0,
    cached_index_count: u32 = 0,
    simple_draw_count: u32 = 0,
    complex_draw_count: u32 = 0,
    run_count: u32 = 0,
    runs: []TextureRun = &.{},
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    clip_x: i16 = 0,
    clip_y: i16 = 0,
    clip_w: u16 = 0,
    clip_h: u16 = 0,
    blend_mode: u8 = 0,
};

pub const LayerPropWake = enum {
    none,
    scene_changed,
    present_needed,
};

pub const LayerPropField = enum(u8) {
    visible = 0,
    z = 1,
    scroll_x = 2,
    scroll_y = 3,
    clip_x = 4,
    clip_y = 5,
    clip_w = 6,
    clip_h = 7,
    blend_mode = 8,
    opacity = 9,
    tint_r = 10,
    tint_g = 11,
    tint_b = 12,
    clear_r = 13,
    clear_g = 14,
    clear_b = 15,
    clear_a = 16,
    _,
};

pub const LayerBlendMode = enum(u8) {
    normal = 0,
    additive = 1,
    multiply = 2,
    none = 3,
};

pub const LayerStateSnapshot = struct {
    visible: bool,
    z: i16,
    opacity: u8,
    tint_r: u8,
    tint_g: u8,
    tint_b: u8,
    clear_r: u8,
    clear_g: u8,
    clear_b: u8,
    clear_a: u8,
    geometry_dirty: bool,
    order_dirty: bool,
    present_dirty: bool,
    slab_count: u32,
    scroll_x: i32,
    scroll_y: i32,
    clip_x: i16,
    clip_y: i16,
    clip_w: u16,
    clip_h: u16,
    blend_mode: u8,
};

pub const GeometryLaneVec = @Vector(geometry_compiler_lanes, f32);

pub const GeometryCompilerBlock = struct {
    count: usize = 0,
    x_loc: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    y_loc: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    width: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    height: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    x_dest: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    y_dest: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    w_dest: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    h_dest: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    center_x: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    center_y: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    angle: [geometry_compiler_lanes]f64 align(geometry_buffer_alignment) = [_]f64{0} ** geometry_compiler_lanes,
    flip_mode: [geometry_compiler_lanes]u16 align(geometry_buffer_alignment) = [_]u16{0} ** geometry_compiler_lanes,
    tint_r: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    tint_g: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    tint_b: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
    tint_a: [geometry_compiler_lanes]f32 align(geometry_buffer_alignment) = [_]f32{0} ** geometry_compiler_lanes,
};

pub const SortedDrawRef = struct {
    key: u64 = 0,
    index: u32 = 0,
};

pub const ImmediateTextureRun = TextureRun;

pub const CompositeDomain = enum(u8) {
    retained = 0,
    immediate = 1,
};

pub const CompositeEntry = struct {
    composite_priority: i16 = 0,
    domain: CompositeDomain = .retained,
    index: u32 = 0,
};

pub const Graphic = struct {
    surface: ?*sdl.SDL_Surface,
    textures: [max_palettes]?*sdl.SDL_Texture,
    texture_ids: [max_palettes]u16,
    colors: [max_palettes]?[*]sdl.SDL_Color,
    flags: [max_palettes]bool,
    ncolors: [max_palettes]u32,
    palette_count: u8,
    is_indexed: bool,
    is_initialized: bool,
};

pub const DynamicTexture = struct {
    texture: ?*sdl.SDL_Texture = null,
    texture_id: u16 = 0,
    width: u32 = 0,
    height: u32 = 0,
    is_initialized: bool = false,
};

pub const RenderTarget = struct {
    texture: ?*sdl.SDL_Texture = null,
    texture_id: u16 = 0,
    width: u32 = 0,
    height: u32 = 0,
    is_initialized: bool = false,
};

pub const ExternalDrawInstruction = extern struct {
    x_loc: c_int,
    y_loc: c_int,
    width: c_int,
    height: c_int,
    x_dest: c_int,
    y_dest: c_int,
    w_dest: c_int,
    h_dest: c_int,
    graphic_index: c_int,
    palette_index: c_int,
    layer_id: c_int,
    priority: c_int,
    center_x: c_int,
    center_y: c_int,
    angle: f64,
    flip_h: u8,
    flip_v: u8,
};

pub const LayerPropCommand = extern struct {
    layer_id: u16,
    field: u8,
    _pad: u8 = 0,
    value: i32,
};

pub const DrawInstruction = extern struct {
    x_loc: f32,
    y_loc: f32,
    width: f32,
    height: f32,
    x_dest: f32,
    y_dest: f32,
    w_dest: f32,
    h_dest: f32,
    center_x: f32,
    center_y: f32,
    angle: f64,
    sort_key: u64,
    flip_mode: u16,
    tint_r: u8,
    tint_g: u8,
    tint_b: u8,
    tint_a: u8,
    layer_id: u8,
    kind: DrawKind,
};

comptime {
    if (@sizeOf(DrawInstruction) != 64)
        @compileError("DrawInstruction must be 64 bytes for cache-line optimization");
    if (@sizeOf(LayerPropCommand) != 8)
        @compileError("LayerPropCommand must be exactly 8 bytes for FFI");
    if (max_texture_runs_per_layer == 0)
        @compileError("MAX_TEXTURE_RUNS_PER_LAYER must be > 0");
    if (max_texture_runs_per_layer != max_slab_size)
        @compileError("Retained run capacity must represent every accepted draw");
    if (max_slab_size > std.math.maxInt(u16))
        @compileError("Retained draw and run counts must fit u16");
    if (default_draw_capacity * 4 > @as(u64, std.math.maxInt(u32)) + 1)
        @compileError("Default quad vertex indices must fit u32");
    if (max_retained_draw_instructions * 4 > max_cached_vertices)
        @compileError("CACHED_VERTEX_BUFFER too small for retained slabs");
    if (max_retained_draw_instructions * 6 > max_cached_indices)
        @compileError("CACHED_INDEX_BUFFER too small for retained slabs");
}
