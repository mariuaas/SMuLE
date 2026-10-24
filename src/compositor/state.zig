const std = @import("std");
const sdl = @import("sdl").sdl;
const t = @import("types.zig");

// Clear the existing backing in place instead of constructing a large aggregate value.
fn zeroBytes(ptr: anytype) void {
    @memset(std.mem.asBytes(ptr), 0);
}

/// Mutable instance-owned state. Initialize through Instance.init before use.
/// Cached and geometry buffer views alias the same scratch backing and are
/// reused between retained-layer compilation and immediate rendering.
pub const State = struct {
    frame_stats: t.FrameStats = .{},
    render_stats: t.RenderStats = .{},
    frame_state: t.FrameState = .idle,
    draw_list_sorted: bool = false,
    use_geometry_backend: bool = true,
    next_texture_id: u16 = 1,
    free_texture_ids: [t.max_texture_ids]u16 = undefined,
    free_texture_id_count: usize = 0,
    graphics: [t.max_graphics]t.Graphic = undefined,
    dynamic_textures: [t.max_dynamic_textures]t.DynamicTexture = undefined,
    render_targets: [t.max_render_targets]t.RenderTarget = [_]t.RenderTarget{.{}} ** t.max_render_targets,
    active_render_target: i16 = -1,
    sorted_draw_indices: []t.SortedDrawRef = &.{},
    layers: [t.max_layers]t.LayerState = [_]t.LayerState{.{}} ** t.max_layers,
    layer_masks: t.LayerMasks = .{},
    instruction_count: usize = 0,
    immediate_run_count: usize = 0,
    composite_entry_count: usize = 0,
    white_texture_id: u16 = 0,
    texture_table: [t.max_texture_ids]?*sdl.SDL_Texture = undefined,
    premultiplied_textures: [t.max_texture_ids]?*sdl.SDL_Texture = undefined,
    operation_sources: [t.max_texture_ids]@import("operation.zig").Source = undefined,
    texture_dims: [t.max_texture_ids]t.TextureDims = undefined,
    cached_vertex_buffer: []align(t.geometry_buffer_alignment) sdl.SDL_Vertex = &.{},
    cached_index_buffer: []align(t.geometry_buffer_alignment) u32 = &.{},
    immediate_texture_runs: []t.ImmediateTextureRun = &.{},
    composite_entries: []t.CompositeEntry = &.{},
    layer_sorted_refs: []t.SortedDrawRef = &.{},
    retained_composite_entries: [t.max_layers]t.CompositeEntry = undefined,
    retained_composite_entry_count: usize = 0,
    layer_present_vertex_buffer: [4]sdl.SDL_Vertex = undefined,
    geometry_vertex_buffer: []align(t.geometry_buffer_alignment) sdl.SDL_Vertex = &.{},
    geometry_index_buffer: []align(t.geometry_buffer_alignment) u32 = &.{},
    geometry_compiler_block: t.GeometryCompilerBlock align(t.geometry_buffer_alignment) = .{},
    geometry_vertex_count: usize = 0,
    geometry_index_count: usize = 0,
    external_batch_buffer: [t.max_sprite_batch_commands]t.ExternalDrawInstruction = undefined,
    layer_staging_buffers: [t.max_layers][t.max_slab_size]t.ExternalDrawInstruction = undefined,
    layer_prop_buffer: [t.max_layer_batch_commands]t.LayerPropCommand = undefined,
    pub fn resetAll(self: *State) void {
        self.frame_stats = .{};
        self.render_stats = .{};
        self.frame_state = .idle;
        self.draw_list_sorted = false;
        self.use_geometry_backend = true;

        self.next_texture_id = 1;
        self.free_texture_ids = undefined;
        self.free_texture_id_count = 0;

        zeroBytes(&self.graphics);
        zeroBytes(&self.dynamic_textures);
        self.render_targets = [_]t.RenderTarget{.{}} ** t.max_render_targets;
        self.active_render_target = -1;
        self.sorted_draw_indices = &.{};
        self.layer_masks = .{};
        for (&self.layers) |*layer| {
            layer.* = .{};
        }
        self.instruction_count = 0;
        self.immediate_run_count = 0;
        self.composite_entry_count = 0;
        self.white_texture_id = 0;

        zeroBytes(&self.texture_table);
        zeroBytes(&self.premultiplied_textures);
        self.operation_sources = @splat(.{});
        zeroBytes(&self.texture_dims);

        self.cached_vertex_buffer = &.{};
        self.cached_index_buffer = &.{};
        self.immediate_texture_runs = &.{};
        self.composite_entries = &.{};
        self.layer_sorted_refs = &.{};
        zeroBytes(&self.retained_composite_entries);
        self.retained_composite_entry_count = 0;
        zeroBytes(&self.layer_present_vertex_buffer);

        self.geometry_vertex_buffer = &.{};
        self.geometry_index_buffer = &.{};
        zeroBytes(&self.geometry_compiler_block);
        self.geometry_vertex_count = 0;
        self.geometry_index_count = 0;

        zeroBytes(&self.external_batch_buffer);
        zeroBytes(&self.layer_staging_buffers);
        zeroBytes(&self.layer_prop_buffer);
    }
};
