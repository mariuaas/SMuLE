const std = @import("std");
pub const sdl = @import("sdl").sdl;
pub const types = @import("types.zig");
pub const State = @import("state.zig").State;
pub const geometry = @import("geometry.zig");
pub const draw = @import("draw.zig");
pub const layers = @import("layers.zig");
pub const textures = @import("textures.zig");
pub const render_targets = @import("render_targets.zig");
pub const compositor = @import("compositor.zig");
pub const faults = @import("faults.zig");
pub const operation = @import("operation.zig");
pub const sampling = @import("sampling.zig");
pub const draw_storage = @import("draw_storage.zig");

/// Borrowed renderer/output configuration. The host owns SDL and output targets.
pub const Context = struct {
    renderer: ?*sdl.SDL_Renderer = null,
    composition_target: ?*sdl.SDL_Texture = null,
    logical_width: c_int = 0,
    logical_height: c_int = 0,
    output_scale: f32 = 1,
    debug_mode: bool = false,
    opaque_presentation: bool = false,
    scale: c_int = 1,
    pixel_density: f32 = 1,
    high_pixel_density: bool = false,
    vsync: bool = true,
    clear_r: u8 = 0,
    clear_g: u8 = 0,
    clear_b: u8 = 0,
    clear_a: u8 = 255,
};

pub const Changes = struct {
    scene_changed: bool = false,
    present_needed: bool = false,
    immediate_submitted: bool = false,
};

/// Large, address-stable compositor state. Prefer allocator.create over a small
/// thread stack, initialize with an explicit allocator, and deinit before freeing.
/// The renderer and composition target remain caller-owned.
pub const Instance = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    context: Context = .{},
    changes: Changes = .{},
    state: State = .{},
    faults: faults.Faults = .{},
    frame_ready: bool = false,
    source_stats: operation.Stats = .{},
    canvas_stats: types.CanvasStats = .{},
    sampling_cache: sampling.Cache = .{},
    sampling_stats: sampling.Stats = .{},
    draw_storage: draw_storage.Storage = .{},

    /// Initialize default draw backing. On failure, call deinit to release any
    /// partially initialized resources before retrying or freeing the instance.
    pub fn init(
        self: *Instance,
        allocator: std.mem.Allocator,
        context: Context,
    ) !void {
        try self.initWithDrawCapacity(
            allocator,
            context,
            .{
                .ceiling = types.default_draw_capacity,
                .reserved = types.default_draw_capacity,
                .payloads = types.default_draw_capacity,
            },
        );
    }

    pub fn initWithDrawCapacity(
        self: *Instance,
        allocator: std.mem.Allocator,
        context: Context,
        config: draw_storage.Config,
    ) !void {
        self.allocator = allocator;
        self.context = context;
        self.changes = .{};
        self.faults = .{};
        self.frame_ready = false;
        self.source_stats = .{};
        self.canvas_stats = .{};
        self.sampling_cache = .{};
        self.sampling_stats = .{};
        self.draw_storage = .{ .allocator = allocator };
        self.state.resetAll();
        try self.reserveDrawStorage(config);
        self.changes = .{};
        textures.createWhiteTexture(self);
    }

    pub fn reserveDrawStorage(
        self: *Instance,
        config: draw_storage.Config,
    ) !void {
        if (self.state.frame_state == .compiling or self.state.frame_state == .executing)
            return error.WrongFrameState;
        if (config.ceiling > @as(u32, std.math.maxInt(c_int)) / 6)
            return error.InvalidCapacity;
        try self.draw_storage.reserve(config);
        self.bindDrawStorage();
        self.state.draw_list_sorted = false;
        self.frame_ready = false;
        self.changes.present_needed = true;
    }

    /// Rebind scratch views after reservation. Sorted/cached and layer/geometry
    /// names are aliases, not independent buffers; previous slices may be invalid.
    pub fn bindDrawStorage(self: *Instance) void {
        const backing = &self.draw_storage.backing;
        self.state.sorted_draw_indices = backing.sort_refs;
        self.state.layer_sorted_refs = backing.sort_refs;
        self.state.cached_vertex_buffer = backing.vertices;
        self.state.geometry_vertex_buffer = backing.vertices;
        self.state.cached_index_buffer = backing.indices;
        self.state.geometry_index_buffer = backing.indices;
        self.state.immediate_texture_runs = backing.runs;
        self.state.composite_entries = if (backing.composition.len == 0)
            self.state.retained_composite_entries[0..]
        else
            backing.composition;
        for (&self.state.layers) |*layer| layer.runs = &.{};
    }

    pub fn deinit(self: *Instance) void {
        self.draw_storage.deinit();
        for (0..types.max_texture_ids) |texture_id| operation.invalidateResource(self, @intCast(texture_id));
        for (&self.state.graphics) |*graphic| textures.destroyGraphicSlot(self, graphic);
        for (&self.state.dynamic_textures) |*texture| {
            if (texture.texture) |handle| sdl.SDL_DestroyTexture(handle);
            texture.* = .{};
        }
        textures.destroyLayerTargets(self);
        sampling.deinit(self);
        render_targets.destroyAll(self);
        self.state.resetAll();
        self.changes = .{};
        self.frame_ready = false;
    }
};
