const std = @import("std");
const api = @import("graphics");
const sdl = api.sdl;
const t = api.types;

fn window() !*sdl.SDL_Window {
    return sdl.SDL_CreateWindow("Graphics ownership", 64, 48, sdl.SDL_WINDOW_HIDDEN) orelse error.WindowUnavailable;
}

fn config() api.Config {
    return .{ .width = 64, .height = 48, .vsync = false, .capacity = .{ .ceiling = 128, .reserved = 128, .payloads = 128 } };
}

test "renderer lifetime and independent configuration, resize rollback and recovery" {
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const first_window = try window();
    defer sdl.SDL_DestroyWindow(first_window);
    const second_window = try window();
    defer sdl.SDL_DestroyWindow(second_window);
    var first = try std.testing.allocator.create(api.Graphics);
    defer std.testing.allocator.destroy(first);
    first.* = .{};
    var second = try std.testing.allocator.create(api.Graphics);
    defer std.testing.allocator.destroy(second);
    second.* = .{};
    try first.init(std.testing.allocator, first_window, config());
    defer first.deinit();
    var occupied: api.Graphics = .{};
    try std.testing.expectError(error.RendererCreationFailed, occupied.init(std.testing.allocator, first_window, config()));
    occupied.deinit();
    try second.init(std.testing.allocator, second_window, config());
    defer second.deinit();
    try std.testing.expect(first.compositor.context.renderer != second.compositor.context.renderer);
    try std.testing.expectError(error.AlreadyInitialized, first.init(std.testing.allocator, first_window, config()));
    try first.beginFrame();
    try std.testing.expect(!first.isFrameReady());
    try first.addSolidRectToLayer(0, 0, 0, 0, 8, 8, 255, 0, 0, 255);
    try first.compileDirtyRetainedLayers();
    try first.executeCompositeFrame();
    try std.testing.expect(first.isFrameReady());
    try first.present();
    try std.testing.expect(!first.isFrameReady());
    try std.testing.expect(!first.hasPendingWork());
    const before = first.compositor.context;
    const target = first.compositor.state.layers[0].target_texture_id;
    first.compositor.faults.inject(.render_scale, 0);
    try std.testing.expect(!first.setLogicalSizeAndScale(32, 24, 2));
    try std.testing.expectEqual(before, first.compositor.context);
    try std.testing.expectEqual(target, first.compositor.state.layers[0].target_texture_id);
    var width: c_int = 0;
    var height: c_int = 0;
    try std.testing.expect(sdl.SDL_GetWindowSize(first_window, &width, &height));
    try std.testing.expectEqual(@as(c_int, 64), width);
    try std.testing.expectEqual(@as(c_int, 48), height);
    try std.testing.expect(first.hasPendingWork());
    try std.testing.expect(!first.setLogicalSizeAndScale(std.math.maxInt(c_int), 1, 2));
    try std.testing.expect(first.setLogicalSizeAndScale(32, 24, 2));
    try std.testing.expectEqual(@as(u16, 0), first.compositor.state.layers[0].target_texture_id);
    try std.testing.expectEqual(@as(c_int, 64), second.compositor.context.logical_width);
    first.deinit();
    try std.testing.expect(first.compositor.context.renderer == null);
    try std.testing.expect(sdl.SDL_GetWindowSize(first_window, &width, &height));
    try first.init(std.testing.allocator, first_window, config());
}

test "allocation failures release owned renderer and preserve borrowed window" {
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const borrowed = try window();
    defer sdl.SDL_DestroyWindow(borrowed);
    var graphics = try std.testing.allocator.create(api.Graphics);
    defer std.testing.allocator.destroy(graphics);
    graphics.* = .{};
    var invalid = config();
    invalid.width = 0;
    try std.testing.expectError(error.InvalidDimensions, graphics.init(std.testing.allocator, borrowed, invalid));
    invalid.width = std.math.maxInt(c_int);
    invalid.scale = 2;
    try std.testing.expectError(error.InvalidDimensions, graphics.init(std.testing.allocator, borrowed, invalid));
    var index: usize = 0;
    while (index < 20) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        const result = graphics.init(failing.allocator(), borrowed, config());
        if (result) |_| {
            graphics.deinit();
            break;
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory or err == error.WhiteTextureUnavailable);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expect(!graphics.initialized);
            try std.testing.expect(graphics.compositor.context.renderer == null);
            graphics.deinit();
        }
    }
    try std.testing.expect(index > 0 and index < 20);
    try graphics.init(std.testing.allocator, borrowed, config());
    defer graphics.deinit();
}

test "reusable API covers mixed draws, transactions, targets and presentation retry" {
    std.testing.refAllDecls(api.Graphics);
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const borrowed = try window();
    defer sdl.SDL_DestroyWindow(borrowed);
    var graphics = try std.testing.allocator.create(api.Graphics);
    defer std.testing.allocator.destroy(graphics);
    graphics.* = .{};
    try graphics.init(std.testing.allocator, borrowed, config());
    defer graphics.deinit();
    const texture = try graphics.createOperationDynamicTexture(1, 1, .shared);
    try graphics.updateDynamicTexture(texture, 0, 0, 1, 1, &.{ 255, 255, 255, 255 }, 4);
    try graphics.setSourceSampling(texture, .nearest, .clamp);
    try graphics.beginFrame();
    const name = std.mem.span(sdl.SDL_GetRendererName(graphics.compositor.context.renderer));
    const software = std.mem.eql(u8, name, "software");
    std.debug.print("graphics API: SDL {d}, renderer {s}; operation pixels {s}\n", .{ sdl.SDL_GetVersion(), name, if (software) "unsupported (rejection only)" else "native SDL geometry" });
    if (software) {
        try graphics.setCanvasMode(0, .normal);
        try graphics.addAffineSprite(.{ .texture_id = texture, .layer_id = 0, .sw = 1, .sh = 1 });
        try graphics.compileDirtyRetainedLayers();
        try std.testing.expectError(error.UnsupportedCanvasBackend, graphics.executeCompositeFrame());
        return;
    }
    try graphics.setCanvasMode(0, .normal);
    try graphics.setCanvasExtent(0, 32, 24);
    try graphics.setContentScroll(0, 1, 2);
    try graphics.setSurfaceClip(0, .{ .w = 32, .h = 24 });
    try graphics.setAffine(0, .{});
    try graphics.setCanvasSampling(0, .bilinear);
    try graphics.setLayerProperty(0, .opacity, 200);
    try graphics.addAffineSprite(.{ .texture_id = texture, .layer_id = 0, .sw = 1, .sh = 1 });
    try graphics.addTexturedTriangle(.{ .texture_id = texture, .layer_id = 0, .vertices = .{ .{ .x = 256, .y = 256 }, .{ .x = 2048, .y = 256 }, .{ .x = 256, .y = 2048 } } });
    try graphics.addLine(.{ .layer_id = 0, .x0 = 4, .y0 = 4, .x1 = 8, .y1 = 8 });
    try graphics.beginLayerReplacement(1);
    _ = try graphics.stageLayerDraws(&.{});
    graphics.abortLayerReplacement();
    try graphics.beginLayerReplacement(1);
    try graphics.stageDraw(1, 0, texture, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ 255, 255, 255, 255 }, .none);
    try graphics.commitLayerReplacement();
    try std.testing.expectEqual(@as(u32, 1), try graphics.layerDrawCount(1));
    try std.testing.expectEqual(@as(u32, 3), try graphics.layerDrawCount(0));
    const target = try graphics.createRenderTarget(8, 8);
    try std.testing.expect(!graphics.hasActiveRenderTarget());
    try graphics.beginRenderTarget(target, .{});
    try std.testing.expect(graphics.hasActiveRenderTarget());
    try graphics.addSolidRect(0, 0, 0, 8, 8, 0, 255, 0, 255);
    try graphics.endRenderTarget();
    try std.testing.expect(!graphics.hasActiveRenderTarget());
    try graphics.drawRenderTarget(target, 0, 0, .{});
    try graphics.compileDirtyRetainedLayers();
    try graphics.executeCompositeFrame();
    graphics.compositor.faults.inject(.present, 0);
    try std.testing.expectError(error.PresentFailed, graphics.present());
    try std.testing.expect(graphics.hasPendingWork());
    try std.testing.expect(graphics.compositor.state.instruction_count != 0);
    try graphics.executeCompositeFrame();
    try graphics.present();
    try std.testing.expect(!graphics.hasPendingWork());
    try std.testing.expectEqual(@as(usize, 0), graphics.compositor.state.instruction_count);
    try graphics.releaseLayerCanvas(0);
    try graphics.destroyRenderTarget(target);
    try graphics.destroyDynamicTexture(texture);
}

test "borrowed logical target uses unit scale while input stays in window coordinates" {
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const borrowed = try window();
    defer sdl.SDL_DestroyWindow(borrowed);
    const graphics = try std.testing.allocator.create(api.Graphics);
    defer std.testing.allocator.destroy(graphics);
    graphics.* = .{};
    var settings = config();
    settings.scale = 2;
    settings.width = 32;
    settings.height = 24;
    settings.clear = .{ 11, 22, 33, 255 };
    try graphics.init(std.testing.allocator, borrowed, settings);
    defer graphics.deinit();
    const target = sdl.SDL_CreateTexture(graphics.rendererHandle(), sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_TARGET, 32, 24) orelse return error.TargetUnavailable;
    defer sdl.SDL_DestroyTexture(target);
    graphics.setCompositionTarget(target, true);
    try std.testing.expectEqual(@as(c_int, 2), graphics.windowScale());
    try std.testing.expectEqual(@as(f32, 2), graphics.physicalScale());
    try std.testing.expectEqual(@as(f32, 1), graphics.configuration().output_scale);
    try graphics.beginFrame();
    try graphics.addSolidRect(0, 1, 1, 2, 2, 255, 0, 0, 255);
    try graphics.executeCompositeFrame();
    const pixels = sdl.SDL_RenderReadPixels(graphics.rendererHandle(), null) orelse return error.ReadbackFailed;
    defer sdl.SDL_DestroySurface(pixels);
    try std.testing.expectEqual(@as(c_int, 32), pixels.*.w);
    try std.testing.expectEqual(@as(c_int, 24), pixels.*.h);
    var color: [4]u8 = undefined;
    try std.testing.expect(sdl.SDL_ReadSurfacePixel(pixels, 1, 1, &color[0], &color[1], &color[2], &color[3]));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, color);
    try std.testing.expect(sdl.SDL_ReadSurfacePixel(pixels, 3, 3, &color[0], &color[1], &color[2], &color[3]));
    try std.testing.expectEqual(settings.clear, color);
    graphics.setClearColor(11, 22, 33, 0);
    try std.testing.expect(graphics.configuration().opaque_presentation);
    graphics.setCompositionTarget(target, false);
    graphics.setClearColor(11, 22, 33, 255);
    try std.testing.expect(!graphics.configuration().opaque_presentation);
    graphics.beginUpdate();
    try graphics.setCanvasMode(0, .normal);
    try graphics.addSolidRectToLayer(0, 0, 0, 0, 1, 1, 255, 0, 0, 255);
    try graphics.compileDirtyRetainedLayers();
    try std.testing.expectError(error.OpaqueBackgroundRequired, graphics.executeCompositeFrame());
    graphics.setCompositionTarget(target, true);
    graphics.setClearColor(11, 22, 33, 0);
    try std.testing.expect(graphics.configuration().opaque_presentation);
    try std.testing.expect(sdl.SDL_SetRenderDrawColor(graphics.rendererHandle(), 11, 22, 33, 255));
    try std.testing.expect(sdl.SDL_RenderClear(graphics.rendererHandle()));
    const software = std.mem.eql(u8, std.mem.span(sdl.SDL_GetRendererName(graphics.rendererHandle())), "software");
    if (software) {
        try std.testing.expectError(error.UnsupportedCanvasBackend, graphics.executeCompositeFrame());
    } else {
        try graphics.executeCompositeFrame();
    }
    graphics.setCompositionTarget(null, false);
    try std.testing.expect(!graphics.configuration().opaque_presentation);
    graphics.setClearColor(11, 22, 33, 255);
    try std.testing.expect(graphics.configuration().opaque_presentation);
    try std.testing.expectEqual(@as(f32, 2), graphics.configuration().output_scale);
    try std.testing.expectError(error.FrameNotReady, graphics.present());
}
