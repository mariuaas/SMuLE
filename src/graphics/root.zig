const std = @import("std");
const shared = @import("compositor");
pub const sdl = shared.sdl;
pub const types = shared.types;
pub const RenderError = shared.compositor.RenderError;
pub const Payload = shared.draw_storage.Payload;
pub const fonts = @import("fonts.zig");
pub const Fonts = fonts.Fonts;
const t = types;
pub const Config = struct {
    width: c_int,
    height: c_int,
    scale: c_int = 1,
    high_pixel_density: bool = false,
    vsync: bool = true,
    debug: bool = false,
    clear: [4]u8 = .{ 0, 0, 0, 255 },
    geometry: bool = true,
    capacity: shared.draw_storage.Config = .{
        .ceiling = types.default_draw_capacity,
        .reserved = types.default_draw_capacity,
        .payloads = types.default_draw_capacity,
    },
};

/// Address-stable graphics facade. Borrows the window and owns the renderer and
/// compositor resources. Deinitialize Fonts before Graphics, then the window.
pub const Graphics = struct {
    compositor: shared.Instance = .{},
    window: ?*sdl.SDL_Window = null,
    initialized: bool = false,

    pub fn init(self: *Graphics, allocator: std.mem.Allocator, window: *sdl.SDL_Window, config: Config) !void {
        if (self.initialized) return error.AlreadyInitialized;
        if (config.width <= 0 or config.height <= 0 or config.scale <= 0) return error.InvalidDimensions;
        _ = std.math.mul(c_int, config.width, config.scale) catch return error.InvalidDimensions;
        _ = std.math.mul(c_int, config.height, config.scale) catch return error.InvalidDimensions;
        const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererCreationFailed;
        errdefer sdl.SDL_DestroyRenderer(renderer);
        const density = sdl.SDL_GetWindowPixelDensity(window);
        const pixel_density = if (config.high_pixel_density and density > 0) density else 1;
        const output_scale = @as(f32, @floatFromInt(config.scale)) * pixel_density;
        if (!sdl.SDL_SetRenderVSync(renderer, if (config.vsync) 1 else 0)) return error.VSyncFailed;
        if (!sdl.SDL_SetRenderScale(renderer, output_scale, output_scale)) return error.ScaleFailed;
        self.compositor.initWithDrawCapacity(allocator, .{
            .renderer = renderer,
            .logical_width = config.width,
            .logical_height = config.height,
            .output_scale = output_scale,
            .debug_mode = config.debug,
            .scale = config.scale,
            .pixel_density = pixel_density,
            .high_pixel_density = config.high_pixel_density,
            .vsync = config.vsync,
            .clear_r = config.clear[0],
            .clear_g = config.clear[1],
            .clear_b = config.clear[2],
            .clear_a = config.clear[3],
            .opaque_presentation = config.clear[3] == 255,
        }, config.capacity) catch |err| {
            self.compositor.deinit();
            self.compositor.context.renderer = null;
            return err;
        };
        errdefer {
            self.compositor.deinit();
            self.compositor.context.renderer = null;
        }
        if (self.compositor.state.white_texture_id == 0) return error.WhiteTextureUnavailable;
        self.compositor.state.use_geometry_backend = config.geometry;
        self.window = window;
        self.initialized = true;
        self.compositor.changes.present_needed = true;
    }

    pub fn deinit(self: *Graphics) void {
        if (!self.initialized) return;
        const renderer = self.compositor.context.renderer;
        self.compositor.deinit();
        sdl.SDL_DestroyRenderer(renderer);
        self.compositor.context.renderer = null;
        self.window = null;
        self.initialized = false;
    }

    pub fn hasPendingWork(self: *const Graphics) bool {
        const changes = self.compositor.changes;
        return changes.scene_changed or changes.present_needed or changes.immediate_submitted;
    }

    pub fn isFrameReady(self: *const Graphics) bool {
        return self.compositor.frame_ready;
    }

    pub fn hasActiveRenderTarget(self: *const Graphics) bool {
        return self.compositor.state.active_render_target != -1;
    }

    pub fn requestPresentation(self: *Graphics) void {
        self.compositor.changes.present_needed = true;
    }

    pub fn configuration(self: *const Graphics) shared.Context {
        return self.compositor.context;
    }

    pub fn rendererHandle(self: *const Graphics) ?*sdl.SDL_Renderer {
        return self.compositor.context.renderer;
    }

    pub fn windowScale(self: *const Graphics) c_int {
        return self.compositor.context.scale;
    }

    pub fn physicalScale(self: *const Graphics) f32 {
        return @as(f32, @floatFromInt(self.windowScale())) * self.compositor.context.pixel_density;
    }

    pub fn setGeometryBackend(self: *Graphics, enabled: bool) void {
        if (self.compositor.state.use_geometry_backend == enabled) return;
        self.compositor.state.use_geometry_backend = enabled;
        self.invalidatePresentation();
    }

    pub fn setDebug(self: *Graphics, enabled: bool) void {
        self.compositor.context.debug_mode = enabled;
    }

    pub fn setClearColor(self: *Graphics, r: u8, g: u8, b: u8, a: u8) void {
        const context = &self.compositor.context;
        context.clear_r = r;
        context.clear_g = g;
        context.clear_b = b;
        context.clear_a = a;
        if (context.composition_target == null) context.opaque_presentation = a == 255;
        self.invalidatePresentation();
    }

    pub fn setVsync(self: *Graphics, enabled: bool) bool {
        if (self.compositor.context.renderer == null) return false;
        if (!sdl.SDL_SetRenderVSync(self.compositor.context.renderer, if (enabled) 1 else 0)) return false;
        self.compositor.context.vsync = enabled;
        return true;
    }

    pub fn refreshOutputScale(self: *Graphics) bool {
        const context = &self.compositor.context;
        const window = self.window orelse return false;
        const density = sdl.SDL_GetWindowPixelDensity(window);
        const pixel_density = if (context.high_pixel_density and density > 0) density else 1;
        const output_scale = if (context.composition_target != null)
            1
        else
            @as(f32, @floatFromInt(context.scale)) * pixel_density;
        if (self.compositor.faults.check(.render_scale) or !sdl.SDL_SetRenderScale(context.renderer, output_scale, output_scale)) {
            self.requestPresentation();
            return false;
        }
        context.pixel_density = pixel_density;
        context.output_scale = output_scale;
        self.invalidatePresentation();
        return true;
    }

    pub fn setLogicalSizeAndScale(self: *Graphics, width: c_int, height: c_int, scale: c_int) bool {
        const window = self.window orelse return false;
        const context = &self.compositor.context;
        if (context.renderer == null or width <= 0 or height <= 0 or scale <= 0) return false;
        const physical_width = std.math.mul(c_int, width, scale) catch return false;
        const physical_height = std.math.mul(c_int, height, scale) catch return false;
        const old = context.*;
        if (!sdl.SDL_SetWindowSize(window, physical_width, physical_height)) return false;
        context.scale = scale;
        if (!self.refreshOutputScale()) {
            _ = sdl.SDL_SetWindowSize(window, old.logical_width * old.scale, old.logical_height * old.scale);
            context.* = old;
            _ = sdl.SDL_SetRenderScale(context.renderer, old.output_scale, old.output_scale);
            self.requestPresentation();
            return false;
        }
        context.logical_width = width;
        context.logical_height = height;
        if (width != old.logical_width or height != old.logical_height)
            shared.textures.destroyLogicalLayerTargets(&self.compositor);
        return true;
    }

    /// Enter update state and clear the output. Submit draws and layer changes
    /// before executeCompositeFrame; present remains a host scheduling decision.
    pub fn beginFrame(self: *Graphics) shared.compositor.RenderError!void {
        const instance = &self.compositor;
        errdefer {
            instance.state.frame_state = .idle;
            self.requestPresentation();
        }
        instance.state.frame_state = .updating;
        instance.frame_ready = false;
        instance.state.frame_stats.frame_number += 1;
        const context = instance.context;
        try shared.compositor.restoreMainRenderTarget(instance);
        if (!sdl.SDL_SetRenderDrawColor(
            context.renderer,
            context.clear_r,
            context.clear_g,
            context.clear_b,
            context.clear_a,
        )) return error.DrawColorFailed;
        if (!sdl.SDL_RenderClear(context.renderer)) return error.ClearFailed;
        instance.state.frame_stats.bulk_api_calls = 0;
        instance.state.frame_stats.bulk_items_submitted = 0;
    }

    pub fn setCompositionTarget(self: *Graphics, texture: ?*sdl.SDL_Texture, opaque_background: bool) void {
        self.compositor.context.composition_target = texture;
        self.compositor.context.opaque_presentation = opaque_background;
        self.compositor.context.output_scale = if (texture != null) 1 else self.physicalScale();
        self.invalidatePresentation();
    }

    pub fn abortLayerReplacement(self: *Graphics) void {
        self.compositor.draw_storage.abortReplacement();
    }

    pub fn stageDraw(
        self: *Graphics,
        layer: u8,
        priority: c_int,
        texture: u16,
        source: sdl.SDL_Rect,
        destination: sdl.SDL_Rect,
        tint: [4]u8,
        primitive: Payload,
    ) !void {
        var instruction = std.mem.zeroes(types.DrawInstruction);
        instruction.sort_key = shared.geometry.packKey(priority, texture, 0, primitive == .none);
        instruction.layer_id = layer;
        instruction.x_loc = @floatFromInt(source.x);
        instruction.y_loc = @floatFromInt(source.y);
        instruction.width = @floatFromInt(source.w);
        instruction.height = @floatFromInt(source.h);
        instruction.x_dest = @floatFromInt(destination.x);
        instruction.y_dest = @floatFromInt(destination.y);
        instruction.w_dest = @floatFromInt(destination.w);
        instruction.h_dest = @floatFromInt(destination.h);
        instruction.tint_r = tint[0];
        instruction.tint_g = tint[1];
        instruction.tint_b = tint[2];
        instruction.tint_a = tint[3];
        try self.stageLayerInstruction(instruction, primitive);
    }

    pub fn reserveDrawStorage(self: *Graphics, config: shared.draw_storage.Config) !void {
        try self.compositor.reserveDrawStorage(config);
    }

    pub fn layerDrawCount(self: *const Graphics, layer: u8) !u32 {
        if (layer >= types.max_layers) return error.InvalidLayerId;
        return self.compositor.draw_storage.owners[layer].count;
    }

    pub fn whiteTexture(self: *const Graphics) u16 {
        return self.compositor.state.white_texture_id;
    }

    pub fn registerTexture(self: *Graphics, texture: *sdl.SDL_Texture, width: u32, height: u32) ?u16 {
        return shared.textures.assignTextureId(&self.compositor, texture, width, height);
    }

    pub fn unregisterTexture(self: *Graphics, texture_id: u16) void {
        shared.textures.releaseTextureId(&self.compositor, texture_id);
    }

    pub fn releaseLayerCanvas(self: *Graphics, layer_id: u8) !void {
        if (layer_id >= types.max_layers) return error.InvalidLayerId;
        const layer = &self.compositor.state.layers[layer_id];
        if (layer.target_texture_id != 0) {
            if (self.compositor.state.texture_table[layer.target_texture_id]) |texture|
                shared.textures.destroyLayerBacking(&self.compositor, texture, layer.backing);
            shared.textures.releaseTextureId(&self.compositor, layer.target_texture_id);
            layer.target_texture_id = 0;
            layer.backing = .{};
            layer.target_dirty = true;
            self.invalidatePresentation();
        }
    }

    pub fn beginUpdate(self: *Graphics) void {
        self.compositor.state.frame_state = .updating;
        self.compositor.frame_ready = false;
    }

    pub fn endUpdate(self: *Graphics) void {
        self.compositor.state.frame_state = .idle;
    }

    pub fn setLayerProperty(self: *Graphics, layer: u8, field: types.LayerPropField, value: i32) !void {
        self.compositor.state.layer_prop_buffer[0] = .{ .layer_id = layer, .field = @intFromEnum(field), .value = value };
        _ = try shared.layers.submitLayerPropCommands(&self.compositor, 1);
    }

    pub fn addAffineSprite(self: *Graphics, sprite: t.AffineSprite) shared.draw.DrawError!void {
        return shared.draw.addAffineSprite(&self.compositor, sprite);
    }

    pub fn addTexturedTriangle(self: *Graphics, triangle: t.TexturedTriangle) shared.draw.DrawError!void {
        return shared.draw.addTexturedTriangle(&self.compositor, triangle);
    }

    pub fn addLine(self: *Graphics, line: t.Line) shared.draw.DrawError!void {
        return shared.draw.addLine(&self.compositor, line);
    }

    pub fn addOperationQuadUV(
        self: *Graphics,
        texture_id: u16,
        layer_id: u8,
        priority: c_int,
        source: sdl.SDL_FRect,
        destination: sdl.SDL_Rect,
        tint: [4]u8,
    ) shared.draw.DrawError!void {
        return shared.draw.addOperationQuadUV(
            &self.compositor,
            texture_id,
            layer_id,
            priority,
            source,
            destination,
            tint,
        );
    }

    pub fn addTexturedQuad(
        self: *Graphics,
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
    ) shared.draw.DrawError!void {
        return shared.draw.addTexturedQuad(
            &self.compositor,
            texture_id,
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
        );
    }

    pub fn addTexturedQuadTinted(
        self: *Graphics,
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
    ) shared.draw.DrawError!void {
        return shared.draw.addTexturedQuadTinted(
            &self.compositor,
            texture_id,
            layer_id,
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
            tint_r,
            tint_g,
            tint_b,
            tint_a,
        );
    }

    pub fn addSolidRect(
        self: *Graphics,
        priority: c_int,
        x_dst: c_int,
        y_dst: c_int,
        w_dst: c_int,
        h_dst: c_int,
        tint_r: u8,
        tint_g: u8,
        tint_b: u8,
        tint_a: u8,
    ) shared.draw.DrawError!void {
        return shared.draw.addSolidRect(
            &self.compositor,
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
        self: *Graphics,
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
    ) shared.draw.DrawError!void {
        return shared.draw.addSolidRectToLayer(
            &self.compositor,
            layer_id,
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

    pub fn submitDrawInstructionsBulk(
        self: *Graphics,
        ext_instructions: [*]const t.ExternalDrawInstruction,
        count: usize,
    ) shared.draw.DrawError!usize {
        return shared.draw.submitDrawInstructionsBulk(
            &self.compositor,
            ext_instructions,
            count,
        );
    }

    pub fn setCanvasExtent(
        self: *Graphics,
        layer_id: u8,
        width: u16,
        height: u16,
    ) shared.layers.LayerError!void {
        return shared.layers.setCanvasExtent(
            &self.compositor,
            layer_id,
            width,
            height,
        );
    }

    pub fn setContentScroll(
        self: *Graphics,
        layer_id: u8,
        horizontal: i32,
        vertical: i32,
    ) shared.layers.LayerError!void {
        return shared.layers.setContentScroll(
            &self.compositor,
            layer_id,
            horizontal,
            vertical,
        );
    }

    pub fn setSurfaceClip(
        self: *Graphics,
        layer_id: u8,
        clip: t.SurfaceClip,
    ) shared.layers.LayerError!void {
        return shared.layers.setSurfaceClip(
            &self.compositor,
            layer_id,
            clip,
        );
    }

    pub fn setAffine(
        self: *Graphics,
        layer_id: u8,
        affine: t.Affine,
    ) shared.layers.LayerError!void {
        return shared.layers.setAffine(
            &self.compositor,
            layer_id,
            affine,
        );
    }

    pub fn setCanvasSampling(
        self: *Graphics,
        layer_id: u8,
        mode: t.Sampling,
    ) shared.layers.LayerError!void {
        return shared.layers.setCanvasSampling(
            &self.compositor,
            layer_id,
            mode,
        );
    }

    pub fn setCanvasMode(
        self: *Graphics,
        layer_id: u8,
        mode: t.CanvasMode,
    ) shared.layers.LayerError!void {
        return shared.layers.setCanvasMode(
            &self.compositor,
            layer_id,
            mode,
        );
    }

    pub fn getLayerStateSnapshot(
        self: *Graphics,
        layer_id: u8,
    ) ?t.LayerStateSnapshot {
        return shared.layers.getLayerStateSnapshot(
            &self.compositor,
            layer_id,
        );
    }

    pub fn beginLayerReplacement(
        self: *Graphics,
        layer_id: u8,
    ) shared.layers.LayerError!void {
        return shared.layers.beginLayerReplacement(
            &self.compositor,
            layer_id,
        );
    }

    pub fn stageLayerDraws(
        self: *Graphics,
        instructions: []const t.ExternalDrawInstruction,
    ) shared.layers.LayerError!usize {
        return shared.layers.stageLayerDraws(
            &self.compositor,
            instructions,
        );
    }

    pub fn stageLayerInstruction(
        self: *Graphics,
        instruction: t.DrawInstruction,
        primitive: shared.draw_storage.Payload,
    ) shared.layers.LayerError!void {
        return shared.layers.stageLayerInstruction(
            &self.compositor,
            instruction,
            primitive,
        );
    }

    pub fn commitLayerReplacement(self: *Graphics) shared.layers.LayerError!void {
        return shared.layers.commitLayerReplacement(&self.compositor);
    }

    pub fn clearLayerContents(
        self: *Graphics,
        layer_id: u8,
    ) shared.layers.LayerError!void {
        return shared.layers.clearLayerContents(
            &self.compositor,
            layer_id,
        );
    }

    pub fn resetLayer(
        self: *Graphics,
        layer_id: u8,
    ) shared.layers.LayerError!void {
        return shared.layers.resetLayer(
            &self.compositor,
            layer_id,
        );
    }

    pub fn compileDirtyRetainedLayers(self: *Graphics) shared.layers.LayerError!void {
        return shared.layers.compileDirtyRetainedLayers(&self.compositor);
    }

    pub fn createDynamicTexture(
        self: *Graphics,
        width: c_int,
        height: c_int,
    ) shared.textures.TextureError!u16 {
        return shared.textures.createDynamicTexture(
            &self.compositor,
            width,
            height,
        );
    }

    pub fn createOperationDynamicTexture(
        self: *Graphics,
        width: c_int,
        height: c_int,
        mode: shared.textures.OperationTextureMode,
    ) shared.textures.TextureError!u16 {
        return shared.textures.createOperationDynamicTexture(
            &self.compositor,
            width,
            height,
            mode,
        );
    }

    pub fn destroyDynamicTexture(
        self: *Graphics,
        texture_id: u16,
    ) shared.textures.TextureError!void {
        return shared.textures.destroyDynamicTexture(
            &self.compositor,
            texture_id,
        );
    }

    pub fn updateDynamicTexture(
        self: *Graphics,
        texture_id: u16,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        pixels: []const u8,
        pitch: c_int,
    ) shared.textures.TextureError!void {
        return shared.textures.updateDynamicTexture(
            &self.compositor,
            texture_id,
            x,
            y,
            width,
            height,
            pixels,
            pitch,
        );
    }

    pub fn addGraphics8Bit(
        self: *Graphics,
        graphic_index: usize,
        data: []const u8,
        transparent_key: c_int,
        rgba: []const u8,
        w: c_int,
        h: c_int,
        ncolors: c_int,
    ) shared.textures.TextureError!void {
        return shared.textures.addGraphics8Bit(
            &self.compositor,
            graphic_index,
            data,
            transparent_key,
            rgba,
            w,
            h,
            ncolors,
        );
    }

    pub fn addPalette(
        self: *Graphics,
        graphic_index: usize,
        palette_index: usize,
        transparent_key: c_int,
        rgba: []const u8,
        ncolors: c_int,
    ) shared.textures.TextureError!void {
        return shared.textures.addPalette(
            &self.compositor,
            graphic_index,
            palette_index,
            transparent_key,
            rgba,
            ncolors,
        );
    }

    pub fn updateGraphics8BitPixels(
        self: *Graphics,
        graphic_index: usize,
        data: []const u8,
        w: c_int,
        h: c_int,
    ) shared.textures.TextureError!void {
        return shared.textures.updateGraphics8BitPixels(
            &self.compositor,
            graphic_index,
            data,
            w,
            h,
        );
    }

    pub fn provideOperationPixels(
        self: *Graphics,
        texture_id: u16,
        pixels: []const u8,
        pitch: usize,
    ) shared.textures.TextureError!void {
        return shared.textures.provideOperationPixels(
            &self.compositor,
            texture_id,
            pixels,
            pitch,
        );
    }

    pub fn createRenderTarget(
        self: *Graphics,
        width: c_int,
        height: c_int,
    ) shared.render_targets.Error!u8 {
        return shared.render_targets.create(
            &self.compositor,
            width,
            height,
        );
    }

    pub fn destroyRenderTarget(
        self: *Graphics,
        handle: i64,
    ) shared.render_targets.Error!void {
        return shared.render_targets.destroy(
            &self.compositor,
            handle,
        );
    }

    pub fn beginRenderTarget(
        self: *Graphics,
        handle: i64,
        opts: shared.render_targets.BeginOptions,
    ) shared.render_targets.Error!void {
        return shared.render_targets.begin(
            &self.compositor,
            handle,
            opts,
        );
    }

    pub fn endRenderTarget(self: *Graphics) shared.render_targets.Error!void {
        return shared.render_targets.end(&self.compositor);
    }

    pub fn drawRenderTarget(
        self: *Graphics,
        handle: i64,
        x: c_int,
        y: c_int,
        opts: shared.render_targets.DrawOptions,
    ) shared.render_targets.Error!void {
        return shared.render_targets.drawTarget(
            &self.compositor,
            handle,
            x,
            y,
            opts,
        );
    }

    pub fn executeCompositeFrame(self: *Graphics) shared.compositor.RenderError!void {
        defer self.compositor.state.frame_state = .idle;
        return shared.compositor.executeCompositeFrame(&self.compositor);
    }

    pub fn renderImmediateToCurrentTarget(self: *Graphics) shared.compositor.RenderError!void {
        return shared.compositor.renderImmediateToCurrentTarget(&self.compositor);
    }

    pub fn invalidatePresentation(self: *Graphics) void {
        return shared.compositor.invalidatePresentation(&self.compositor);
    }

    pub fn present(self: *Graphics) shared.compositor.RenderError!void {
        defer self.compositor.state.frame_state = .idle;
        try shared.compositor.present(&self.compositor);
        self.compositor.changes = .{};
    }

    pub fn setSourceSampling(
        self: *Graphics,
        texture_id: u16,
        filter: types.Sampling,
        address: types.Addressing,
    ) shared.textures.TextureError!void {
        return shared.sampling.setSource(
            &self.compositor,
            texture_id,
            filter,
            address,
        );
    }
};
