const support = @import("operation_support.zig");
const std = support.std;
const rendering = support.rendering;
const sdl = support.sdl;
const Mode = support.Mode;
const families = support.families;
const background = support.background;
const copySourcePixel = support.copySourcePixel;
const Fixture = support.Fixture;
const near = support.near;
const affinePattern = support.affinePattern;
const affineExpected = support.affineExpected;
const AffinePresentation = support.AffinePresentation;
const AffineOutcomes = support.AffineOutcomes;
const affineSample = support.affineSample;
const affineCoveragePermitted = support.affineCoveragePermitted;
const affineAxisChoices = support.affineAxisChoices;
const affineOutcomes = support.affineOutcomes;
const byte = support.byte;
const reference = support.reference;
const mumTriangleQuad = support.mumTriangleQuad;

test "lazy indexed preparation failures restore surface state and retry without eager legacy snapshots" {
    const cases = .{
        .{ rendering.faults.Point.palette_creation, error.ResourceConversionFailed },
        .{ rendering.faults.Point.palette_colors, error.ResourceConversionFailed },
        .{ rendering.faults.Point.surface_palette, error.ResourceConversionFailed },
        .{ rendering.faults.Point.operation_surface_conversion, error.ResourceConversionFailed },
        .{ rendering.faults.Point.operation_cpu_allocation, error.ResourceConversionFailed },
        .{ rendering.faults.Point.operation_allocation, error.ResourceConversionFailed },
        .{ rendering.faults.Point.operation_upload, error.ResourceConversionFailed },
        .{ rendering.faults.Point.texture_scale, error.TextureStateFailed },
    };
    inline for (cases) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try rendering.textures.addGraphics8Bit(fixture.instance, 0, &.{ 0, 1 }, 0, &.{ 240, 80, 40, 80, 240, 160 }, 2, 1, 2);
        try rendering.textures.addPalette(fixture.instance, 0, 1, 1, &.{ 20, 40, 80, 160, 120, 80 }, 2);
        const id = fixture.instance.state.graphics[0].texture_ids[0];
        const original = fixture.instance.state.texture_table[id];
        const surface = fixture.instance.state.graphics[0].surface;
        fixture.instance.faults.inject(case[0], 0);
        try std.testing.expectError(case[1], rendering.operation.source(fixture.instance, id));
        try std.testing.expectEqual(original, fixture.instance.state.texture_table[id]);
        try std.testing.expectEqual(surface, fixture.instance.state.graphics[0].surface);
        var key: u32 = 0;
        try std.testing.expect(sdl.SDL_GetSurfaceColorKey(surface, &key));
        try std.testing.expectEqual(@as(u32, 1), key);
        try std.testing.expect(sdl.SDL_GetSurfacePalette(surface) == null);
        try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try copySourcePixel(&fixture, id, 1, 1));
        try std.testing.expectEqual([4]u8{ 80, 240, 160, 255 }, try copySourcePixel(&fixture, id, 6, 1));
    }
}

test "legacy dynamic images require supplied pixels for adoption and then track updates" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const id = try rendering.textures.createDynamicTexture(fixture.instance, 1, 1);
    fixture.instance.source_stats = .{};
    try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 1, 1, &.{ 240, 80, 40, 128 }, 4);
    try std.testing.expect(fixture.instance.state.operation_sources[id].pixels == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.converted_pixels);
    try std.testing.expectError(error.OperationPixelsRequired, rendering.operation.source(fixture.instance, id));
    try std.testing.expectError(error.InvalidPixelData, rendering.textures.provideOperationPixels(fixture.instance, id, &.{}, 4));
    if (fixture.supported) {
        try fixture.begin();
        try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
        try fixture.textured(id, .{ 255, 255, 255, 255 }, 0, 0, 8, 8);
        try std.testing.expectError(error.OperationPixelsRequired, fixture.execute());
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
        try std.testing.expectEqual(@as(u16, 1), fixture.instance.state.layers[0].slab_count);
    }
    fixture.instance.faults.inject(.operation_cpu_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, rendering.textures.provideOperationPixels(fixture.instance, id, &.{ 240, 80, 40, 128 }, 4));
    try std.testing.expect(fixture.instance.state.operation_sources[id].pixels == null);
    try rendering.textures.provideOperationPixels(fixture.instance, id, &.{ 240, 80, 40, 128 }, 4);
    if (fixture.supported) {
        try fixture.begin();
        try fixture.execute();
        try near(reference(.normal, &.{.{ 240, 80, 40, 128 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
    }
    try std.testing.expectEqual([4]u8{ 120, 40, 20, 128 }, try copySourcePixel(&fixture, id, 2, 2));
    const cached = fixture.instance.state.premultiplied_textures[id];
    try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 1, 1, &.{ 80, 240, 160, 192 }, 4);
    try std.testing.expectEqual([4]u8{ 60, 181, 120, 192 }, try copySourcePixel(&fixture, id, 2, 2));
    try std.testing.expectEqual(cached, fixture.instance.state.premultiplied_textures[id]);
    try std.testing.expect(!fixture.instance.state.operation_sources[id].external);
}

test "legacy indexed edits allocate no snapshots and lazy palettes preserve individual colour keys" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.instance.faults.inject(.operation_cpu_allocation, 0);
    try rendering.textures.addGraphics8Bit(fixture.instance, 0, &.{ 0, 1 }, 0, &.{ 240, 80, 40, 80, 240, 160 }, 2, 1, 2);
    try rendering.textures.addPalette(fixture.instance, 0, 1, 1, &.{ 20, 40, 80, 160, 120, 80 }, 2);
    const ids = fixture.instance.state.graphics[0].texture_ids;
    try std.testing.expect(fixture.instance.state.operation_sources[ids[0]].pixels == null);
    try std.testing.expect(fixture.instance.state.operation_sources[ids[1]].pixels == null);
    try std.testing.expectError(error.ResourceConversionFailed, rendering.operation.source(fixture.instance, ids[0]));
    try std.testing.expect(fixture.instance.state.operation_sources[ids[0]].pixels == null);
    var key: u32 = 0;
    try std.testing.expect(sdl.SDL_GetSurfaceColorKey(fixture.instance.state.graphics[0].surface, &key));
    try std.testing.expectEqual(@as(u32, 1), key);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try copySourcePixel(&fixture, ids[0], 1, 1));
    try std.testing.expectEqual([4]u8{ 80, 240, 160, 255 }, try copySourcePixel(&fixture, ids[0], 6, 1));
    try std.testing.expect(fixture.instance.state.operation_sources[ids[1]].pixels == null);
    fixture.instance.source_stats = .{};
    try rendering.textures.updateGraphics8BitPixels(fixture.instance, 0, &.{ 1, 0 }, 2, 1);
    try std.testing.expectEqual(@as(usize, 2), fixture.instance.source_stats.cpu_allocations);
    try std.testing.expect(fixture.instance.state.operation_sources[ids[1]].pixels == null);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try copySourcePixel(&fixture, ids[0], 1, 1));
    try std.testing.expectEqual([4]u8{ 240, 80, 40, 255 }, try copySourcePixel(&fixture, ids[0], 6, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try copySourcePixel(&fixture, ids[1], 1, 1));
    try std.testing.expectEqual([4]u8{ 20, 40, 80, 255 }, try copySourcePixel(&fixture, ids[1], 6, 1));
}

test "operation-only dynamic sources upload once and cannot enter legacy rendering" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.instance.source_stats = .{};
    const id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 1, 1, .operation_only);
    const original = fixture.instance.state.texture_table[id];
    try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 1, 1, &.{ 240, 80, 40, 128 }, 4);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.legacy_uploaded_bytes);
    fixture.instance.faults.inject(.operation_upload, 0);
    try std.testing.expectError(error.ResourceConversionFailed, rendering.operation.source(fixture.instance, id));
    try std.testing.expect(fixture.instance.state.operation_sources[id].dirty != null);
    try std.testing.expectEqual(original, try rendering.operation.source(fixture.instance, id));
    try std.testing.expectEqual(@as(usize, 4), fixture.instance.source_stats.uploaded_bytes);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.texture_allocations);
    try std.testing.expect(fixture.instance.state.premultiplied_textures[id] == null);
    fixture.instance.state.frame_state = .updating;
    try std.testing.expectError(error.UnsupportedOperationResource, fixture.textured(id, .{ 255, 255, 255, 255 }, 0, 0, 8, 8));
    try std.testing.expectError(error.UnsupportedOperationResource, rendering.draw.addTexturedQuadTinted(fixture.instance, id, rendering.types.immediate_layer_id, 0, 0, 0, 1, 1, 0, 0, 8, 8, false, false, 0, 0, 0, 255, 255, 255, 255));
    if (!fixture.supported) return;
    for (families) |family| {
        try fixture.begin();
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try fixture.textured(id, .{ 255, 255, 255, 255 }, 0, 0, 8, 8);
        try fixture.execute();
        try near(reference(family, &.{.{ 240, 80, 40, 128 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
    }
    try rendering.layers.setCanvasMode(fixture.instance, 0, .legacy_rgba);
    try std.testing.expectError(error.UnsupportedOperationResource, fixture.execute());
    try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
    try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
    try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 1, 1, &.{ 80, 240, 160, 192 }, 4);
    fixture.instance.faults.inject(.operation_upload, 0);
    try std.testing.expectError(error.ResourceConversionFailed, fixture.execute());
    try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
    try fixture.begin();
    try fixture.execute();
    try near(reference(.normal, &.{.{ 80, 240, 160, 192 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.legacy_uploaded_bytes);
    try std.testing.expectEqual(@as(usize, 8), fixture.instance.source_stats.uploaded_bytes);
}

test "failed dynamic upload blocks source use until a covering legacy retry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.instance.faults.inject(.operation_cpu_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, rendering.textures.createOperationDynamicTexture(fixture.instance, 8, 8, .shared));
    const texture_id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 8, 8, .shared);
    const derived = try rendering.operation.source(fixture.instance, texture_id);
    const pixels = [_]u8{ 240, 80, 40, 128 } ** 4;
    fixture.instance.faults.inject(.texture_upload, 0);
    try std.testing.expectError(error.TextureUpdateFailed, rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 2, 3, 2, 2, &pixels, 8));
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 6, 6, 1, 1, &.{ 80, 240, 160, 192 }, 4);
    try std.testing.expectError(error.ResourceConversionFailed, rendering.operation.source(fixture.instance, texture_id));
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 2, 3, 2, 2, &pixels, 8);
    try std.testing.expectEqual([4]u8{ 120, 40, 20, 128 }, try copySourcePixel(&fixture, texture_id, 2, 3));
    try std.testing.expectEqual([4]u8{ 60, 181, 120, 192 }, try copySourcePixel(&fixture, texture_id, 6, 6));
    try std.testing.expectEqual(derived, try rendering.operation.source(fixture.instance, texture_id));
}

test "padded region updates preserve unaffected texels and merge dirty uploads without allocation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const texture_id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 8, 8, .shared);
    const derived = try rendering.operation.source(fixture.instance, texture_id);
    fixture.instance.source_stats = .{};
    var pixels = [_]u8{ 240, 80, 40, 128, 240, 80, 40, 128, 99, 99, 99, 99, 240, 80, 40, 128, 240, 80, 40, 128, 99, 99, 99, 99 };
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 2, 3, 2, 2, &pixels, 12);
    @memset(&pixels, 0);
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 6, 6, 1, 1, &.{ 80, 240, 160, 192 }, 4);
    fixture.instance.faults.inject(.operation_upload, 0);
    try std.testing.expectError(error.ResourceConversionFailed, rendering.operation.source(fixture.instance, texture_id));
    try std.testing.expect(fixture.instance.state.operation_sources[texture_id].dirty != null);
    try std.testing.expectEqual([4]u8{ 120, 40, 20, 128 }, try copySourcePixel(&fixture, texture_id, 2, 3));
    try std.testing.expectEqual([4]u8{ 120, 40, 20, 128 }, try copySourcePixel(&fixture, texture_id, 3, 4));
    try std.testing.expectEqual([4]u8{ 60, 181, 120, 192 }, try copySourcePixel(&fixture, texture_id, 6, 6));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try copySourcePixel(&fixture, texture_id, 1, 3));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try copySourcePixel(&fixture, texture_id, 4, 4));
    try std.testing.expectEqual(derived, try rendering.operation.source(fixture.instance, texture_id));
    try std.testing.expectEqual(@as(usize, 5), fixture.instance.source_stats.converted_pixels);
    try std.testing.expectEqual(@as(usize, 80), fixture.instance.source_stats.uploaded_bytes);
    try std.testing.expectEqual(@as(usize, 20), fixture.instance.source_stats.legacy_uploaded_bytes);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.texture_allocations);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.cpu_allocations);
}

test "source costs cold unchanged full and small region updates are bounded on the actual backend" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 256 * 256 * 4);
    defer std.testing.allocator.free(pixels);
    for (0..256 * 256) |pixel_index| @memcpy(pixels[pixel_index * 4 ..][0..4], &[_]u8{ 240, 80, 40, 128 });
    const samples = 100;
    std.debug.print("source-metadata bytes={d} entry_bytes={d}\n", .{ @sizeOf(rendering.operation.Source) * rendering.types.max_texture_ids, @sizeOf(rendering.operation.Source) });
    const frequency: f64 = @floatFromInt(sdl.SDL_GetPerformanceFrequency());
    fixture.instance.source_stats = .{};
    var start = sdl.SDL_GetPerformanceCounter();
    for (0..samples) |_| {
        const texture_id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 256, 256, .shared);
        try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 256, 256, pixels, 1024);
        _ = try rendering.operation.source(fixture.instance, texture_id);
        try rendering.textures.destroyDynamicTexture(fixture.instance, texture_id);
    }
    var elapsed: f64 = @as(f64, @floatFromInt(sdl.SDL_GetPerformanceCounter() - start)) / frequency * 1e6 / samples;
    var stats = fixture.instance.source_stats;
    try std.testing.expectEqual(samples, stats.cpu_allocations);
    try std.testing.expectEqual(samples, stats.texture_allocations);
    try std.testing.expectEqual(samples * 256 * 256, stats.converted_pixels);
    try std.testing.expectEqual(samples * 256 * 256 * 4, stats.uploaded_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.readbacks);
    std.debug.print("source-cost renderer={s} case=cold mean_us={d:.3} samples={d} totals={any}\n", .{ sdl.SDL_GetRendererName(fixture.renderer), elapsed, samples, stats });
    const texture_id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 256, 256, .shared);
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 256, 256, pixels, 1024);
    const original = try rendering.operation.source(fixture.instance, texture_id);
    for ([_]usize{ 0, 256, 16 }) |extent| {
        fixture.instance.source_stats = .{};
        start = sdl.SDL_GetPerformanceCounter();
        for (0..samples) |_| {
            if (extent != 0) try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, if (extent == 256) 0 else 7, if (extent == 256) 0 else 9, @intCast(extent), @intCast(extent), pixels, 1024);
            try std.testing.expectEqual(original, try rendering.operation.source(fixture.instance, texture_id));
        }
        elapsed = @as(f64, @floatFromInt(sdl.SDL_GetPerformanceCounter() - start)) / frequency * 1e6 / samples;
        stats = fixture.instance.source_stats;
        const updated_pixels: usize = extent * extent;
        try std.testing.expectEqual(@as(usize, 0), stats.cpu_allocations);
        try std.testing.expectEqual(@as(usize, 0), stats.texture_allocations);
        try std.testing.expectEqual(@as(usize, 0), stats.legacy_texture_allocations);
        try std.testing.expectEqual(samples * updated_pixels, stats.converted_pixels);
        try std.testing.expectEqual(samples * updated_pixels * 4, stats.uploaded_bytes);
        try std.testing.expectEqual(stats.uploaded_bytes, stats.legacy_uploaded_bytes);
        try std.testing.expectEqual(@as(usize, 0), stats.readbacks);
        std.debug.print("source-cost renderer={s} case={s} mean_us={d:.3} samples={d} totals={any}\n", .{ sdl.SDL_GetRendererName(fixture.renderer), if (extent == 0) "unchanged-source" else if (extent == 256) "full-update" else "16x16-update", elapsed, samples, stats });
    }
    try std.testing.expectEqual([4]u8{ 120, 40, 20, 128 }, try copySourcePixel(&fixture, texture_id, 2, 2));
}

test "external textures require explicitly supplied straight RGBA pixels and preserve ownership" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const texture = sdl.SDL_CreateTexture(fixture.renderer, sdl.SDL_PIXELFORMAT_RGBA32, sdl.SDL_TEXTUREACCESS_STATIC, 1, 1) orelse return error.TextureUnavailable;
    defer sdl.SDL_DestroyTexture(texture);
    try std.testing.expect(sdl.SDL_UpdateTexture(texture, null, &[_]u8{ 240, 80, 40, 128 }, 4));
    const texture_id = rendering.textures.assignTextureId(fixture.instance, texture, 1, 1).?;
    defer rendering.textures.releaseTextureId(fixture.instance, texture_id);
    try std.testing.expectError(error.UnsupportedOperationResource, rendering.operation.source(fixture.instance, texture_id));
    try rendering.textures.provideOperationPixels(fixture.instance, texture_id, &.{ 240, 80, 40, 128 }, 4);
    try std.testing.expectEqual([4]u8{ 120, 40, 20, 128 }, try copySourcePixel(&fixture, texture_id, 2, 2));
    const derived = fixture.instance.state.premultiplied_textures[texture_id];
    fixture.instance.faults.inject(.operation_cpu_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, rendering.textures.provideOperationPixels(fixture.instance, texture_id, &.{ 80, 240, 160, 192 }, 4));
    try std.testing.expectEqual(derived, fixture.instance.state.premultiplied_textures[texture_id]);
    try std.testing.expectEqual([4]u8{ 120, 40, 20, 128 }, try copySourcePixel(&fixture, texture_id, 2, 2));
    try std.testing.expect(sdl.SDL_UpdateTexture(texture, null, &[_]u8{ 80, 240, 160, 192 }, 4));
    rendering.layers.invalidateTexture(fixture.instance, texture_id, false);
    try std.testing.expectError(error.UnsupportedOperationResource, rendering.operation.source(fixture.instance, texture_id));
    fixture.instance.faults.inject(.operation_cpu_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, rendering.textures.provideOperationPixels(fixture.instance, texture_id, &.{ 80, 240, 160, 192 }, 4));
    try std.testing.expectError(error.UnsupportedOperationResource, rendering.operation.source(fixture.instance, texture_id));
    try rendering.textures.provideOperationPixels(fixture.instance, texture_id, &.{ 80, 240, 160, 192 }, 4);
    try std.testing.expectEqual([4]u8{ 60, 181, 120, 192 }, try copySourcePixel(&fixture, texture_id, 2, 2));
    try std.testing.expectEqual(derived, fixture.instance.state.premultiplied_textures[texture_id]);
    try std.testing.expectEqual(texture, fixture.instance.state.texture_table[texture_id].?);
}

test "indexed snapshots commit all palettes transactionally and reuse derived textures" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try rendering.textures.addGraphics8Bit(fixture.instance, 0, &.{ 0, 1 }, 0, &.{ 240, 80, 40, 80, 240, 160 }, 2, 1, 2);
    try rendering.textures.addPalette(fixture.instance, 0, 1, 0, &.{ 20, 40, 80, 160, 120, 80 }, 2);
    const ids = fixture.instance.state.graphics[0].texture_ids;
    const first = try rendering.operation.source(fixture.instance, ids[0]);
    const second = try rendering.operation.source(fixture.instance, ids[1]);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try copySourcePixel(&fixture, ids[0], 1, 1));
    try std.testing.expectEqual([4]u8{ 80, 240, 160, 255 }, try copySourcePixel(&fixture, ids[0], 6, 1));
    const old_surface = fixture.instance.state.graphics[0].surface;
    const old_pixels = fixture.instance.state.operation_sources[ids[0]].pixels.?;
    fixture.instance.faults.inject(.operation_surface_conversion, 1);
    try std.testing.expectError(error.ResourceConversionFailed, rendering.textures.updateGraphics8BitPixels(fixture.instance, 0, &.{ 1, 0 }, 2, 1));
    try std.testing.expectEqual(old_surface, fixture.instance.state.graphics[0].surface);
    fixture.instance.faults.inject(.operation_cpu_allocation, 1);
    try std.testing.expectError(error.OutOfMemory, rendering.textures.updateGraphics8BitPixels(fixture.instance, 0, &.{ 1, 0 }, 2, 1));
    try std.testing.expectEqual(old_surface, fixture.instance.state.graphics[0].surface);
    try std.testing.expectEqual(old_pixels.ptr, fixture.instance.state.operation_sources[ids[0]].pixels.?.ptr);
    try std.testing.expectEqual([4]u8{ 80, 240, 160, 255 }, try copySourcePixel(&fixture, ids[0], 6, 1));
    fixture.instance.faults.inject(.operation_cpu_allocation, 0);
    try std.testing.expectError(error.OutOfMemory, rendering.textures.addPalette(fixture.instance, 0, 0, -1, &.{ 255, 0, 0, 0, 255, 0 }, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try copySourcePixel(&fixture, ids[0], 1, 1));
    try rendering.textures.updateGraphics8BitPixels(fixture.instance, 0, &.{ 1, 0 }, 2, 1);
    fixture.instance.faults.inject(.operation_upload, 0);
    try std.testing.expectError(error.ResourceConversionFailed, rendering.operation.source(fixture.instance, ids[0]));
    try std.testing.expect(fixture.instance.state.operation_sources[ids[0]].dirty != null);
    try std.testing.expectEqual([4]u8{ 80, 240, 160, 255 }, try copySourcePixel(&fixture, ids[0], 1, 1));
    try std.testing.expectEqual([4]u8{ 160, 120, 80, 255 }, try copySourcePixel(&fixture, ids[1], 1, 1));
    try std.testing.expectEqual(first, try rendering.operation.source(fixture.instance, ids[0]));
    try std.testing.expectEqual(second, try rendering.operation.source(fixture.instance, ids[1]));
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.readbacks);
}

test "dirty region upload failure preserves submissions and retries without source allocations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    try fixture.begin();
    const texture_id = try fixture.texture(.{ 240, 80, 40, 128 });
    try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
    try fixture.textured(texture_id, .{ 255, 255, 255, 255 }, 0, 0, 8, 8);
    try fixture.execute();
    const derived = fixture.instance.state.premultiplied_textures[texture_id];
    fixture.instance.source_stats = .{};
    const start = sdl.SDL_GetPerformanceCounter();
    for (0..100) |_| {
        try fixture.begin();
        try fixture.execute();
    }
    const elapsed = @as(f64, @floatFromInt(sdl.SDL_GetPerformanceCounter() - start)) / @as(f64, @floatFromInt(sdl.SDL_GetPerformanceFrequency())) * 1e6 / 100;
    std.debug.print("source-cost renderer={s} case=unchanged-frame-compose mean_us={d:.3} samples=100 totals={any}\n", .{ sdl.SDL_GetRendererName(fixture.renderer), elapsed, fixture.instance.source_stats });
    try std.testing.expectEqual(rendering.operation.Stats{}, fixture.instance.source_stats);
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 1, 1, &.{ 80, 240, 160, 192 }, 4);
    fixture.instance.faults.inject(.operation_upload, 0);
    try std.testing.expectError(error.ResourceConversionFailed, fixture.execute());
    try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
    try std.testing.expectEqual(@as(u16, 1), fixture.instance.state.layers[0].slab_count);
    try std.testing.expect(fixture.instance.state.operation_sources[texture_id].dirty != null);
    try fixture.begin();
    try fixture.execute();
    try near(reference(.normal, &.{.{ 80, 240, 160, 192 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
    try std.testing.expectEqual(derived, fixture.instance.state.premultiplied_textures[texture_id]);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.texture_allocations);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.cpu_allocations);
    fixture.instance.faults.inject(.texture_upload, 0);
    try std.testing.expectError(error.TextureUpdateFailed, rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 1, 1, &.{ 240, 80, 40, 128 }, 4));
    try std.testing.expectError(error.ResourceConversionFailed, fixture.execute());
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 1, 1, &.{ 240, 80, 40, 128 }, 4);
    try fixture.begin();
    try fixture.execute();
    try near(reference(.normal, &.{.{ 240, 80, 40, 128 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
}

test "sized operation targets preserve identity extent and transactional ownership" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    for (families) |family| {
        try fixture.begin();
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
        try fixture.property(.opacity, 128);
        try fixture.property(.tint_r, 128);
        try fixture.property(.tint_g, 64);
        try fixture.property(.tint_b, 200);
        try fixture.execute();
        try near(reference(family, &.{}, 128, .{ 128, 64, 200 }), try fixture.pixel(3, 2));
        try near(background, try fixture.pixel(4, 2));
        try near(background, try fixture.pixel(3, 3));
        const layer = &fixture.instance.state.layers[0];
        const id = layer.target_texture_id;
        const target = fixture.instance.state.texture_table[id];
        const allocations = fixture.instance.canvas_stats.target_allocations;
        fixture.instance.frame_ready = true;
        try std.testing.expectError(error.InvalidDimensions, rendering.layers.setCanvasExtent(fixture.instance, 0, 0, 3));
        try std.testing.expect(fixture.instance.frame_ready);
        for ([_]rendering.faults.Point{ .target_creation, .texture_scale, .texture_blend }) |point| {
            fixture.instance.faults.inject(point, 0);
            try std.testing.expectError(error.TextureCreationFailed, rendering.layers.setCanvasExtent(fixture.instance, 0, 5, 3));
            try std.testing.expectEqual(@as(u16, 4), layer.canvas_width);
            try std.testing.expectEqual(target, fixture.instance.state.texture_table[id]);
            try std.testing.expect(fixture.instance.frame_ready);
        }
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
        try std.testing.expectEqual(allocations, fixture.instance.canvas_stats.target_allocations);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 5, 3);
        try std.testing.expectEqual(id, layer.target_texture_id);
        try std.testing.expect(target != fixture.instance.state.texture_table[id]);
        try std.testing.expectEqual(allocations + 1, fixture.instance.canvas_stats.target_allocations);
        try std.testing.expect(!fixture.instance.frame_ready);
        try fixture.begin();
        try fixture.execute();
        try near(reference(family, &.{}, 128, .{ 128, 64, 200 }), try fixture.pixel(4, 2));
        try near(background, try fixture.pixel(5, 2));
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 0, 0);
        try std.testing.expectEqual(@as(u16, 8), layer.canvas_width);
        fixture.instance.context.logical_width = 7;
        rendering.textures.destroyLogicalLayerTargets(fixture.instance);
        try std.testing.expectEqual(id, layer.target_texture_id);
        try std.testing.expectEqual(@as(u16, 8), layer.canvas_width);
        fixture.instance.context.logical_width = 8;
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 12, 10);
        try fixture.begin();
        try fixture.execute();
        try near(reference(family, &.{}, 128, .{ 128, 64, 200 }), try fixture.pixel(7, 7));
    }
    try rendering.layers.resetLayer(fixture.instance, 0);
    const layer = fixture.instance.state.layers[0];
    try std.testing.expectEqual(Mode.legacy_rgba, layer.canvas_mode);
    try std.testing.expectEqual(@as(u16, 0), layer.canvas_width);
    try std.testing.expectEqual(@as(f32, 8), fixture.instance.state.texture_dims[layer.target_texture_id].width);
}

test "off-canvas draws survive admission and scroll without compilation or target allocation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const color = [4]u8{ 240, 80, 40, 128 };
    for (families) |family| {
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
        try rendering.layers.setContentScroll(fixture.instance, 0, 0, 0);
        try fixture.rect(color, 6, 5, 2, 2);
        try fixture.execute();
        try near(background, try fixture.pixel(2, 1));
        const before = fixture.instance.canvas_stats;
        const original = rendering.geometry.cachedVertex(fixture.instance, 0, 0);
        const target = fixture.instance.state.texture_table[fixture.instance.state.layers[0].target_texture_id];
        for ([_][2]i32{ .{ 5, 4 }, .{ -2, -3 }, .{ 6, 5 }, .{ std.math.maxInt(i32), std.math.minInt(i32) } }) |scroll| {
            try rendering.layers.setContentScroll(fixture.instance, 0, scroll[0], scroll[1]);
            try std.testing.expect(!fixture.instance.frame_ready);
            try std.testing.expect(!fixture.instance.state.layer_masks.has(.geometry_dirty, 0));
            try fixture.begin();
            try fixture.execute();
            const visible = scroll[0] == 5 or scroll[0] == 6;
            const horizontal: c_int = if (scroll[0] == 5) 1 else 0;
            try near(if (visible) reference(family, &.{color}, 255, .{ 255, 255, 255 }) else background, try fixture.pixel(horizontal, 1));
            try std.testing.expectEqual(@as(u16, 1), fixture.instance.state.layers[0].slab_count);
            try std.testing.expectEqual(before.compiled_layers, fixture.instance.canvas_stats.compiled_layers);
            try std.testing.expectEqual(before.target_allocations, fixture.instance.canvas_stats.target_allocations);
            try std.testing.expectEqual(target, fixture.instance.state.texture_table[fixture.instance.state.layers[0].target_texture_id]);
            try std.testing.expectEqualDeep(original, rendering.geometry.cachedVertex(fixture.instance, 0, 0));
        }
        try fixture.begin();
        const cached = fixture.instance.canvas_stats;
        try fixture.execute();
        try std.testing.expectEqualDeep(cached, fixture.instance.canvas_stats);
    }
}

test "large integer scroll cancellation preserves pixel edges on both axes without recompilation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const distant: i32 = 16_777_216;
    const offset: i32 = 16_777_217;
    const color = [4]u8{ 240, 80, 40, 128 };
    for (families) |family| for ([_][2]bool{ .{ true, false }, .{ false, true }, .{ true, true } }) |axes| {
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 8, 8);
        try rendering.layers.setContentScroll(fixture.instance, 0, 0, 0);
        try fixture.rect(color, if (axes[0]) distant else 0, if (axes[1]) distant else 0, 8, 8);
        try fixture.execute();
        try near(background, try fixture.pixel(0, 0));
        const layer = fixture.instance.state.layers[0];
        const original = rendering.geometry.cachedQuad(fixture.instance, 0);
        const target = fixture.instance.state.texture_table[layer.target_texture_id];
        const before = fixture.instance.canvas_stats;
        try rendering.layers.setContentScroll(fixture.instance, 0, if (axes[0]) offset else 0, if (axes[1]) offset else 0);
        try fixture.begin();
        try fixture.execute();
        for (0..8) |vertical| for (0..8) |horizontal| {
            const covered = (!axes[0] or horizontal < 7) and (!axes[1] or vertical < 7);
            try near(if (covered) reference(family, &.{color}, 255, .{ 255, 255, 255 }) else background, try fixture.pixel(@intCast(horizontal), @intCast(vertical)));
        };
        try std.testing.expectEqualDeep(original, rendering.geometry.cachedQuad(fixture.instance, 0));
        try std.testing.expectEqual(before.compiled_layers, fixture.instance.canvas_stats.compiled_layers);
        try std.testing.expectEqual(before.target_allocations, fixture.instance.canvas_stats.target_allocations);
        try std.testing.expectEqual(target, fixture.instance.state.texture_table[layer.target_texture_id]);
        try std.testing.expectEqual(before.rasterized_canvases + 1, fixture.instance.canvas_stats.rasterized_canvases);
        try std.testing.expectEqual(before.lowered_vertices + 4, fixture.instance.canvas_stats.lowered_vertices);
    };
}

test "surface clips intersect extent after scroll and clear stale pixels including empty intersections" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const color = [4]u8{ 240, 80, 40, 128 };
    const clips = [_]rendering.types.SurfaceClip{ .{}, .{ .x = 1, .y = 1, .w = 2, .h = 1 }, .{ .x = 3, .y = 2, .w = 65535, .h = 65535 }, .{ .x = 4, .y = 1, .w = 1, .h = 1 }, .{ .x = 65535, .y = 65535, .w = 65535, .h = 65535 }, .{ .x = 65535, .y = 65535, .w = 0, .h = 1 }, .{ .x = 65535, .y = 65535, .w = 1, .h = 0 } };
    for (families) |family| {
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
        try rendering.layers.setContentScroll(fixture.instance, 0, 2, 1);
        try fixture.property(.opacity, 128);
        const texture_id = try fixture.texture(color);
        try fixture.textured(texture_id, .{ 255, 255, 255, 255 }, 2, 1, 6, 5);
        try fixture.execute();
        const before = fixture.instance.canvas_stats;
        for (clips) |clip| {
            try rendering.layers.setSurfaceClip(fixture.instance, 0, clip);
            try fixture.begin();
            try fixture.execute();
            for (0..8) |vertical| for (0..8) |horizontal| {
                const in_extent = horizontal < 4 and vertical < 3;
                const in_clip = clip.w == 0 or clip.h == 0 or (horizontal >= clip.x and vertical >= clip.y and horizontal < @as(u32, clip.x) + clip.w and vertical < @as(u32, clip.y) + clip.h);
                try near(if (in_extent and in_clip) reference(family, &.{color}, 128, .{ 255, 255, 255 }) else background, try fixture.pixel(@intCast(horizontal), @intCast(vertical)));
            };
            try std.testing.expectEqual(before.compiled_layers, fixture.instance.canvas_stats.compiled_layers);
            try std.testing.expectEqual(before.target_allocations, fixture.instance.canvas_stats.target_allocations);
            if (family == .multiply) try std.testing.expectEqual(@as(u8, 255), (try fixture.canvas())[3]);
        }
    }
}

test "content state failures restore renderer state preserve submissions and retry on sized targets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const cases = .{
        .{ rendering.faults.Point.viewport, 0, error.ViewportFailed },
        .{ rendering.faults.Point.clip, 0, error.ClipFailed },
        .{ rendering.faults.Point.clip, 1, error.ClipFailed },
        .{ rendering.faults.Point.clip, 2, error.ClipFailed },
        .{ rendering.faults.Point.geometry, 0, error.GeometryFailed },
        .{ rendering.faults.Point.geometry, 1, error.GeometryFailed },
        .{ rendering.faults.Point.target_restore, 0, error.TargetRestoreFailed },
    };
    for (families) |family| inline for (cases) |case| {
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
        try rendering.layers.setContentScroll(fixture.instance, 0, 2, 1);
        try rendering.layers.setSurfaceClip(fixture.instance, 0, .{ .x = 1, .y = 0, .w = 2, .h = 3 });
        try fixture.rect(.{ 240, 80, 40, 128 }, 2, 1, 4, 3);
        try rendering.draw.addSolidRectToLayer(fixture.instance, rendering.types.immediate_layer_id, 5, 6, 6, 2, 2, 0, 255, 0, 255);
        fixture.instance.faults.inject(case[0], case[1]);
        try std.testing.expectError(case[2], fixture.execute());
        try std.testing.expect(!fixture.instance.frame_ready);
        try std.testing.expect(sdl.SDL_GetRenderTarget(fixture.renderer) == null);
        try std.testing.expect(!sdl.SDL_RenderClipEnabled(fixture.renderer));
        try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
        try fixture.begin();
        try fixture.execute();
        try near(reference(family, &.{.{ 240, 80, 40, 128 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(1, 1));
        try near(background, try fixture.pixel(0, 1));
        try near(.{ 0, 255, 0, 255 }, try fixture.pixel(6, 6));
        try rendering.compositor.present(fixture.instance);
        try std.testing.expectEqual(@as(usize, 0), fixture.instance.state.instruction_count);
    };
}

test "negative content scroll rotated textured draws and hidden edits reuse geometry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const color = [4]u8{ 240, 80, 40, 128 };
    try fixture.begin();
    try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
    try rendering.layers.setCanvasExtent(fixture.instance, 0, 5, 4);
    const id = try fixture.texture(color);
    try rendering.draw.addTexturedQuadTinted(fixture.instance, id, 0, 0, 0, 0, 1, 1, -3, -2, 2, 2, false, false, 1, 1, 90, 255, 255, 255, 255);
    try fixture.execute();
    try near(background, try fixture.pixel(1, 1));
    const before = fixture.instance.canvas_stats;
    try rendering.layers.setContentScroll(fixture.instance, 0, -4, -3);
    try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
    try std.testing.expectEqual(@as(u16, 1), fixture.instance.state.layers[0].slab_count);
    try fixture.begin();
    try fixture.execute();
    try near(reference(.normal, &.{color}, 255, .{ 255, 255, 255 }), try fixture.pixel(1, 1));
    try std.testing.expectEqual(before.compiled_layers, fixture.instance.canvas_stats.compiled_layers);
    try std.testing.expectEqual(before.target_allocations, fixture.instance.canvas_stats.target_allocations);
    try fixture.property(.visible, 0);
    try rendering.layers.setContentScroll(fixture.instance, 0, -5, -4);
    try rendering.layers.setSurfaceClip(fixture.instance, 0, .{ .x = 2, .y = 2, .w = 1, .h = 1 });
    try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 1, 1, &.{ 80, 240, 160, 192 }, 4);
    try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
    try fixture.begin();
    try fixture.execute();
    try near(background, try fixture.pixel(2, 2));
    try fixture.property(.visible, 1);
    fixture.instance.faults.inject(.geometry, 0);
    try std.testing.expectError(error.GeometryFailed, fixture.execute());
    try fixture.begin();
    try fixture.execute();
    try near(reference(.normal, &.{.{ 80, 240, 160, 192 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
    try near(background, try fixture.pixel(3, 2));
    try std.testing.expectEqual(before.compiled_layers, fixture.instance.canvas_stats.compiled_layers);
    try std.testing.expectEqual(before.target_allocations, fixture.instance.canvas_stats.target_allocations);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.source_stats.readbacks);
}

test "target resize invalidates dimension dependent references while preserving its reserved id" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    try fixture.begin();
    try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
    try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
    try fixture.rect(.{ 255, 0, 0, 255 }, 0, 0, 2, 2);
    try fixture.execute();
    const id = fixture.instance.state.layers[0].target_texture_id;
    try rendering.draw.addTexturedQuadTinted(fixture.instance, id, 1, 1, 0, 0, 2, 2, 5, 0, 2, 2, false, false, 0, 0, 0, 255, 255, 255, 255);
    try fixture.begin();
    try fixture.execute();
    try near(.{ 255, 0, 0, 255 }, try fixture.pixel(5, 0));
    try rendering.layers.setCanvasExtent(fixture.instance, 0, 6, 4);
    try std.testing.expectEqual(id, fixture.instance.state.layers[0].target_texture_id);
    try std.testing.expect(fixture.instance.state.layer_masks.has(.geometry_dirty, 1));
    try fixture.begin();
    try fixture.execute();
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 6.0), rendering.geometry.cachedVertex(fixture.instance, 1, 1).tex_coord.x, 0.0001);
    try near(.{ 255, 0, 0, 255 }, try fixture.pixel(5, 0));
}

test "affine fixed precision permissions preserve blending and reject beyond fixed caps" {
    const tie = rendering.types.Affine{ .tx = 128, .ty = 128 };
    for (families) |family| {
        const presentation = AffinePresentation{ .family = family, .opacity = 128, .tint = .{ 128, 64, 200 } };
        const choices = affineOutcomes(tie, presentation, 1, 1);
        try std.testing.expect(!choices.coverage_boundary);
        try std.testing.expect(choices.texel_boundary);
        try std.testing.expectEqual(@as(usize, 4), choices.count);
        for (0..2) |vertical| for (0..2) |horizontal| {
            const color = affinePattern(horizontal, vertical);
            try std.testing.expect(choices.matches(reference(family, &.{color}, 128, .{ 128, 64, 200 })));
        };
        try std.testing.expect(choices.matches(choices.reference_pixel));
    }
    const normal = affineOutcomes(tie, .{}, 1, 1);
    try std.testing.expect(!normal.matches(.{ 50, 60, 100, 255 }));
    try std.testing.expect(!normal.matches(background));
    try std.testing.expect(!normal.matches(reference(.additive, &.{affinePattern(1, 1)}, 255, .{ 255, 255, 255 })));
    for ([_]i32{ 126, 130 }) |translation| {
        const near_tie = affineOutcomes(.{ .tx = translation }, .{}, 1, 1);
        try std.testing.expect(!near_tie.coverage_boundary);
        try std.testing.expect(!near_tie.texel_boundary);
        try std.testing.expectEqual(@as(usize, 1), near_tie.count);
        try std.testing.expect(!near_tie.matches(affinePattern(if (translation == 126) 0 else 1, 1)));
    }
    const below = affineOutcomes(.{ .a = 2147483647, .tx = -25165694 }, .{}, 0, 0);
    try std.testing.expect(below.texel_boundary);
    try std.testing.expectEqual(@as(usize, 2), below.count);
    try std.testing.expect(below.matches(affinePattern(2, 0)));
    try std.testing.expect(below.matches(affinePattern(3, 0)));
    const reflected = rendering.types.Affine{ .a = -65536, .tx = 1152 };
    const edge = affineOutcomes(reflected, .{}, 0, 0);
    try std.testing.expect(edge.coverage_boundary);
    try std.testing.expect(edge.matches(background));
    try std.testing.expect(edge.matches(affinePattern(3, 0)));
    const outside = affineOutcomes(.{ .a = -65536, .tx = 1150 }, .{}, 4, 0);
    try std.testing.expect(!outside.coverage_boundary);
    try std.testing.expectEqual(@as(usize, 1), outside.count);
    try std.testing.expect(!outside.matches(affinePattern(0, 0)));
    const at_sampling_cap = affineAxisChoices(65536 + 256, 65536);
    const beyond_sampling_cap = affineAxisChoices(65536 + 257, 65536);
    try std.testing.expectEqual(@as(usize, 2), at_sampling_cap.count);
    try std.testing.expectEqual(@as(usize, 1), beyond_sampling_cap.count);
    const one_axis = affineOutcomes(.{ .tx = 127, .ty = 64 }, .{}, 1, 1);
    try std.testing.expect(one_axis.matches(affinePattern(0, 1)));
    try std.testing.expect(!one_axis.matches(affinePattern(0, 0)));
    try std.testing.expect(!one_axis.matches(affinePattern(1, 0)));
    try std.testing.expect(affineCoveragePermitted(.{ .a = 64 * 65536 + 256, .tx = 128 }, 1, 1, 64, 0));
    try std.testing.expect(!affineCoveragePermitted(.{ .a = 64 * 65536 + 257, .tx = 128 }, 1, 1, 64, 0));
    try std.testing.expect(!affineCoveragePermitted(.{ .tx = 129, .ty = 129 }, 4, 3, 0, 0));
    const magnified = affineOutcomes(.{ .a = 64 * 65536 + 257, .tx = 128 }, .{ .family = .multiply, .width = 1, .height = 1, .tint = .{ 128, 64, 200 } }, 64, 0);
    try std.testing.expect(!magnified.coverage_boundary);
    try std.testing.expect(!magnified.matches(background));
    const seam = affineOutcomes(.{ .a = 49152 }, .{ .uniform = .{ 240, 80, 40, 128 } }, 1, 1);
    try std.testing.expect(!seam.coverage_boundary);
    try std.testing.expect(!seam.matches(background));
    const doubled = reference(.normal, &.{ .{ 240, 80, 40, 128 }, .{ 240, 80, 40, 128 } }, 255, .{ 255, 255, 255 });
    try std.testing.expect(!seam.matches(doubled));
    const tiny_seam_matrix = rendering.types.Affine{ .a = 256, .d = 256, .tx = 127, .ty = 127 };
    try std.testing.expect(affineCoveragePermitted(tiny_seam_matrix, 4, 4, 0, 0));
    const tiny_seam = affineOutcomes(tiny_seam_matrix, .{ .family = .multiply, .width = 4, .height = 4, .tint = .{ 128, 64, 200 } }, 0, 0);
    try std.testing.expect(!tiny_seam.coverage_boundary);
    try std.testing.expect(!tiny_seam.matches(background));
}

test "affine coverage sampling and winding diagnostic without production changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const matrices = [_]rendering.types.Affine{
        .{ .b = 32768, .c = -16384, .d = 98304, .tx = 512, .ty = 256 },
        .{ .a = -65536, .tx = 1152 },
        .{ .tx = 128, .ty = 128 },
        .{ .a = 98304, .d = 98304, .tx = 128, .ty = 128 },
        .{ .a = -65536, .d = -65536, .tx = 1152, .ty = 896 },
    };
    const arrangements = [_][6]u16{
        .{ 0, 1, 2, 2, 3, 0 },
        .{ 0, 2, 1, 2, 0, 3 },
        .{ 2, 3, 0, 0, 1, 2 },
        .{ 1, 2, 0, 3, 0, 2 },
        .{ 0, 1, 3, 1, 2, 3 },
        .{ 3, 1, 0, 3, 2, 1 },
        .{ 1, 2, 3, 0, 1, 3 },
        .{ 1, 3, 0, 2, 3, 1 },
    };
    const uniform_opaque = [4]u8{ 240, 80, 40, 255 };
    const translucent = [4]u8{ 240, 80, 40, 128 };
    const id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 4, 3, .operation_only);
    try fixture.begin();
    try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
    try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
    try rendering.draw.addTexturedQuadTinted(fixture.instance, id, 0, 0, 0, 0, 4, 3, 0, 0, 4, 3, false, false, 0, 0, 0, 255, 255, 255, 255);
    for (0..3) |input| {
        var pixels: [4 * 3 * 4]u8 = undefined;
        for (0..3) |vertical| for (0..4) |horizontal| {
            const color = if (input == 0) uniform_opaque else if (input == 1) translucent else affinePattern(horizontal, vertical);
            @memcpy(pixels[(vertical * 4 + horizontal) * 4 ..][0..4], &color);
        };
        try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 4, 3, &pixels, 16);
        try fixture.begin();
        try fixture.execute();
        const target = fixture.instance.state.texture_table[fixture.instance.state.layers[0].target_texture_id].?;
        var scale_mode: sdl.SDL_ScaleMode = undefined;
        try std.testing.expect(sdl.SDL_GetTextureScaleMode(target, &scale_mode));
        try std.testing.expectEqual(sdl.SDL_SCALEMODE_NEAREST, scale_mode);
        try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, target));
        for (0..3) |vertical| for (0..4) |horizontal| {
            var expected: [4]u8 = pixels[(vertical * 4 + horizontal) * 4 ..][0..4].*;
            for (expected[0..3]) |*channel| channel.* = @intCast((@as(u16, channel.*) * expected[3] + 127) / 255);
            try near(expected, try fixture.pixel(@intCast(horizontal), @intCast(vertical)));
        };
        try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, null));
        for (matrices, 0..) |matrix, matrix_index| {
            var vertices: [4]sdl.SDL_Vertex = undefined;
            const local = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 3 }, .{ 0, 3 } };
            for (&vertices, local) |*vertex, point| vertex.* = .{
                .position = .{
                    .x = @floatCast((@as(f64, @floatFromInt(matrix.a)) * point[0] + @as(f64, @floatFromInt(matrix.b)) * point[1]) / 65536 + @as(f64, @floatFromInt(matrix.tx)) / 256),
                    .y = @floatCast((@as(f64, @floatFromInt(matrix.c)) * point[0] + @as(f64, @floatFromInt(matrix.d)) * point[1]) / 65536 + @as(f64, @floatFromInt(matrix.ty)) / 256),
                },
                .tex_coord = .{ .x = @floatCast(point[0] / 4), .y = @floatCast(point[1] / 3) },
                .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            };
            for (arrangements, 0..) |indices, arrangement| {
                try fixture.begin();
                try std.testing.expect(sdl.SDL_SetRenderScale(fixture.renderer, 1, 1));
                try std.testing.expect(sdl.SDL_SetRenderViewport(fixture.renderer, null));
                try std.testing.expect(sdl.SDL_SetRenderClipRect(fixture.renderer, null));
                try std.testing.expect(sdl.SDL_SetTextureBlendMode(target, rendering.operation.blend(.normal)));
                try std.testing.expect(sdl.SDL_RenderGeometryRaw(fixture.renderer, target, @ptrCast(&vertices[0].position), @sizeOf(sdl.SDL_Vertex), @ptrCast(&vertices[0].color), @sizeOf(sdl.SDL_Vertex), @ptrCast(&vertices[0].tex_coord), @sizeOf(sdl.SDL_Vertex), 4, &indices, 6, @sizeOf(u16)));
                var missing: usize = 0;
                var excess: usize = 0;
                var sampling: usize = 0;
                var away: usize = 0;
                var permitted: usize = 0;
                for (0..8) |vertical| for (0..8) |horizontal| {
                    var denominator = @as(i128, matrix.a) * matrix.d - @as(i128, matrix.b) * matrix.c;
                    const relative_x = @as(i128, @intCast(horizontal)) * 256 + 128 - matrix.tx;
                    const relative_y = @as(i128, @intCast(vertical)) * 256 + 128 - matrix.ty;
                    var numerator_x = (relative_x * matrix.d - relative_y * matrix.b) * 256;
                    var numerator_y = (relative_y * matrix.a - relative_x * matrix.c) * 256;
                    if (denominator < 0) {
                        denominator = -denominator;
                        numerator_x = -numerator_x;
                        numerator_y = -numerator_y;
                    }
                    const inside = numerator_x >= 0 and numerator_x < denominator * 4 and numerator_y >= 0 and numerator_y < denominator * 3;
                    const coverage_edge = numerator_x == 0 or numerator_x == denominator * 4 or numerator_y == 0 or numerator_y == denominator * 3;
                    const texel_edge = @mod(numerator_x, denominator) == 0 or @mod(numerator_y, denominator) == 0;
                    const expected = if (!inside) background else if (input == 2) affineExpected(matrix, .normal, horizontal, vertical) else reference(.normal, &.{if (input == 0) uniform_opaque else translucent}, 255, .{ 255, 255, 255 });
                    const actual = try fixture.pixel(@intCast(horizontal), @intCast(vertical));
                    const presentation = AffinePresentation{ .uniform = if (input == 2) null else if (input == 0) uniform_opaque else translucent };
                    const outcomes = affineOutcomes(matrix, presentation, horizontal, vertical);
                    try std.testing.expectEqual(expected, outcomes.reference_pixel);
                    try std.testing.expect(outcomes.matches(actual));
                    var matches = true;
                    for (expected, actual, 0..) |want, got, channel| {
                        if (@abs(@as(i16, want) - got) > (if (channel == 3) @as(i16, 0) else 3)) matches = false;
                    }
                    if (!matches) {
                        permitted += 1;
                        const is_missing = inside and std.mem.eql(u8, &actual, &background);
                        const is_excess = !inside and !std.mem.eql(u8, &actual, &background);
                        if (is_missing) missing += 1 else if (is_excess) excess += 1 else sampling += 1;
                        if (!coverage_edge and !texel_edge) away += 1;
                        std.debug.print("AFFINE_DIAG_PIXEL input={d} matrix={d} arrangement={d} pixel={d},{d} inverse={d}/{d},{d}/{d} coverage_edge={} texel_edge={} missing={} excess={} expected={any} actual={any}\n", .{ input, matrix_index, arrangement, horizontal, vertical, numerator_x, denominator, numerator_y, denominator, coverage_edge, texel_edge, is_missing, is_excess, expected, actual });
                    }
                    if (matrix_index == 0 and horizontal == 2 and vertical == 2) std.debug.print("AFFINE_DIAG_ORIGINAL input={d} arrangement={d} expected={any} actual={any} inverse={d}/{d},{d}/{d}\n", .{ input, arrangement, expected, actual, numerator_x, denominator, numerator_y, denominator });
                };
                std.debug.print("AFFINE_DIAG_SUMMARY renderer={s} input={d} matrix={d} arrangement={d} missing={d} excess={d} wrong_sample_or_blend={d} away={d}\n", .{ sdl.SDL_GetRendererName(fixture.renderer), input, matrix_index, arrangement, missing, excess, sampling, away });
                std.debug.print("AFFINE_BOUNDARY_PERMITTED input={d} matrix={d} arrangement={d} deviations={d} sampling_cap=1/256 coverage_cap=1/256_destination\n", .{ input, matrix_index, arrangement, permitted });
            }
        }
    }
}

test "legal fixed point neighbours retain strict expectations outside fixed precision caps" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const matrices = [_]rendering.types.Affine{
        .{ .b = 32767, .c = -16384, .d = 98304, .tx = 512, .ty = 256 },
        .{ .b = 32769, .c = -16384, .d = 98304, .tx = 512, .ty = 256 },
        .{ .a = -65536, .tx = 1151 },
        .{ .a = -65536, .tx = 1153 },
        .{ .tx = 127, .ty = 127 },
        .{ .tx = 129, .ty = 129 },
        .{ .a = 2147483647, .tx = -25165694 },
    };
    const uniform_opaque = [4]u8{ 240, 80, 40, 255 };
    const id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 4, 3, .operation_only);
    try fixture.begin();
    try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
    try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
    try rendering.draw.addTexturedQuadTinted(fixture.instance, id, 0, 0, 0, 0, 4, 3, 0, 0, 4, 3, false, false, 0, 0, 0, 255, 255, 255, 255);
    for (matrices, 0..) |matrix, index| {
        var mismatch_count: usize = 0;
        for (0..2) |input| {
            var pixels: [4 * 3 * 4]u8 = undefined;
            for (0..3) |vertical| for (0..4) |horizontal| {
                const color = if (input == 0) affinePattern(horizontal, vertical) else uniform_opaque;
                @memcpy(pixels[(vertical * 4 + horizontal) * 4 ..][0..4], &color);
            };
            try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 4, 3, &pixels, 16);
            try rendering.layers.setAffine(fixture.instance, 0, matrix);
            try fixture.begin();
            try fixture.execute();
            const presentation = AffinePresentation{ .uniform = if (input == 0) null else uniform_opaque };
            for (0..8) |vertical| for (0..8) |horizontal| {
                const outcomes = affineOutcomes(matrix, presentation, horizontal, vertical);
                const actual = try fixture.pixel(@intCast(horizontal), @intCast(vertical));
                if (index == 0 and horizontal == 2 and vertical == 2) std.debug.print("AFFINE_NEAR_CONTROL input={d} reference={any} actual={any} permitted_count={d} coverage_boundary={} texel_boundary={}\n", .{ input, outcomes.reference_pixel, actual, outcomes.count, outcomes.coverage_boundary, outcomes.texel_boundary });
                if (!outcomes.matches(actual)) {
                    mismatch_count += 1;
                    var denominator = @as(i128, matrix.a) * matrix.d - @as(i128, matrix.b) * matrix.c;
                    const relative_x = @as(i128, @intCast(horizontal)) * 256 + 128 - matrix.tx;
                    const relative_y = @as(i128, @intCast(vertical)) * 256 + 128 - matrix.ty;
                    var numerator_x = (relative_x * matrix.d - relative_y * matrix.b) * 256;
                    var numerator_y = (relative_y * matrix.a - relative_x * matrix.c) * 256;
                    if (denominator < 0) {
                        denominator = -denominator;
                        numerator_x = -numerator_x;
                        numerator_y = -numerator_y;
                    }
                    std.debug.print("AFFINE_NEAR_FAILURE renderer={s} case={d} input={d} matrix={any} pixel={d},{d} inverse={d}/{d},{d}/{d} coverage_boundary={} texel_boundary={} reference={any} actual={any}\n", .{ sdl.SDL_GetRendererName(fixture.renderer), index, input, matrix, horizontal, vertical, numerator_x, denominator, numerator_y, denominator, outcomes.coverage_boundary, outcomes.texel_boundary, outcomes.reference_pixel, actual });
                }
            };
            if (index == 0) {
                const target = fixture.instance.state.texture_table[fixture.instance.state.layers[0].target_texture_id].?;
                try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, target));
                const canvas_pixel = try fixture.pixel(0, 1);
                try near(if (input == 0) affinePattern(0, 1) else uniform_opaque, canvas_pixel);
                std.debug.print("AFFINE_NEAR_CANVAS input={d} pixel=0,1 actual={any}\n", .{ input, canvas_pixel });
                try std.testing.expect(sdl.SDL_SetRenderTarget(fixture.renderer, null));
            }
        }
        std.debug.print("AFFINE_NEAR_CASE case={d} mismatches={d}\n", .{ index, mismatch_count });
        try std.testing.expectEqual(@as(usize, 0), mismatch_count);
    }
}

test "broader affine precision qualification for patterned translucent content and large coordinates" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const matrices = [_]rendering.types.Affine{
        .{ .tx = -768, .ty = -256 },
        .{ .tx = 4096, .ty = 4096 },
        .{ .a = 32768, .d = 49152, .tx = 128, .ty = 256 },
        .{ .a = 131072, .d = 98304, .tx = 128, .ty = 128 },
        .{ .a = 46341, .b = -46341, .c = 46341, .d = 46341, .tx = 768, .ty = 128 },
        .{ .a = -46341, .b = 46341, .c = 46341, .d = 46341, .tx = 768, .ty = 128 },
        .{ .a = -65536, .b = 32767, .c = -16384, .d = 98304, .tx = 1152, .ty = 256 },
        .{ .a = 65536, .b = -65536, .c = -65536, .d = 65536, .tx = 512, .ty = 256 },
        .{ .a = 65536, .b = -65536, .c = -65536, .d = 65537, .tx = 512, .ty = 256 },
        .{ .a = 65536, .b = -65536, .c = -65536, .d = 65535, .tx = 512, .ty = 256 },
        .{ .a = std.math.maxInt(i32), .b = -std.math.maxInt(i32), .tx = 128, .ty = 128 },
        .{ .a = std.math.maxInt(i32), .b = -std.math.maxInt(i32), .d = 98304, .tx = 128, .ty = 128 },
        .{ .d = std.math.maxInt(i32), .c = -std.math.maxInt(i32), .tx = 128, .ty = 128 },
        .{ .a = std.math.maxInt(i32), .b = -std.math.maxInt(i32), .c = std.math.maxInt(i32), .d = -std.math.maxInt(i32) + 1 },
        .{ .a = std.math.minInt(i32), .b = std.math.maxInt(i32), .d = 98304, .tx = 128, .ty = 128 },
        .{ .a = 1073741824, .tx = -16776959, .ty = 128 },
        .{ .d = 1073741824, .ty = -16776959, .tx = 128 },
        .{ .a = 4194304, .d = 4194304, .tx = -32640, .ty = -32640 },
    };
    const id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 4, 3, .operation_only);
    for (families) |family| for ([_]u8{ 128, 255 }) |alpha| {
        var pixels: [4 * 3 * 4]u8 = undefined;
        for (0..3) |vertical| for (0..4) |horizontal| {
            var color = affinePattern(horizontal, vertical);
            color[3] = alpha;
            @memcpy(pixels[(vertical * 4 + horizontal) * 4 ..][0..4], &color);
        };
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
        try fixture.property(.opacity, 128);
        try fixture.property(.tint_r, 128);
        try fixture.property(.tint_g, 64);
        try fixture.property(.tint_b, 200);
        try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 4, 3, &pixels, 16);
        try rendering.draw.addTexturedQuadTinted(fixture.instance, id, 0, 0, 0, 0, 4, 3, 0, 0, 4, 3, false, false, 0, 0, 0, 255, 255, 255, 255);
        for (matrices, 0..) |matrix, index| {
            try fixture.begin();
            try rendering.layers.setAffine(fixture.instance, 0, matrix);
            try fixture.execute();
            var mismatches: usize = 0;
            if (index > 0) {
                const determinant = @as(i128, matrix.a) * matrix.d - @as(i128, matrix.b) * matrix.c;
                try std.testing.expectEqual(@as(usize, if (determinant == 0) 0 else 1), fixture.instance.state.render_stats.draw_calls);
            }
            for (0..8) |vertical| for (0..8) |horizontal| {
                const outcomes = affineOutcomes(matrix, .{ .family = family, .alpha = alpha, .opacity = 128, .tint = .{ 128, 64, 200 } }, horizontal, vertical);
                const actual = try fixture.pixel(@intCast(horizontal), @intCast(vertical));
                if (!outcomes.matches(actual)) {
                    mismatches += 1;
                    std.debug.print("AFFINE_PRECISION_EXCEPTION renderer={s} case={d} family={s} alpha={d} matrix={any} pixel={d},{d} reference={any} actual={any} permitted={any}\n", .{ sdl.SDL_GetRendererName(fixture.renderer), index, @tagName(family), alpha, matrix, horizontal, vertical, outcomes.reference_pixel, actual, outcomes.allowed[0..outcomes.count] });
                }
            };
            std.debug.print("AFFINE_BROAD case={d} family={s} alpha={d} path=SDL_geometry mismatches={d} sampling_cap=1/256 coverage_cap=1/256_destination\n", .{ index, @tagName(family), alpha, mismatches });
            try std.testing.expectEqual(@as(usize, 0), mismatches);
        }
    };
}

test "large sized affine quads retain a small visible patterned portion" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const scenes = [_]struct { width: u16, height: u16, matrix: rendering.types.Affine }{
        .{ .width = 16384, .height = 3, .matrix = .{ .a = std.math.maxInt(i32), .b = -std.math.maxInt(i32), .tx = 128, .ty = 128 } },
        .{ .width = 4, .height = 16384, .matrix = .{ .c = -std.math.maxInt(i32), .d = std.math.maxInt(i32), .tx = 128, .ty = 128 } },
    };
    const id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 4, 3, .operation_only);
    var pixels: [4 * 3 * 4]u8 = undefined;
    for (0..3) |vertical| for (0..4) |horizontal| @memcpy(pixels[(vertical * 4 + horizontal) * 4 ..][0..4], &affinePattern(horizontal, vertical));
    try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 4, 3, &pixels, 16);
    for (families) |family| for (scenes, 0..) |scene, index| {
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, scene.width, scene.height);
        try fixture.property(.opacity, 128);
        try fixture.property(.tint_r, 128);
        try fixture.property(.tint_g, 64);
        try fixture.property(.tint_b, 200);
        try rendering.layers.setAffine(fixture.instance, 0, scene.matrix);
        try rendering.draw.addTexturedQuadTinted(fixture.instance, id, 0, 0, 0, 0, 4, 3, 0, 0, 4, 3, false, false, 0, 0, 0, 255, 255, 255, 255);
        try fixture.execute();
        var mismatches: usize = 0;
        for (0..8) |vertical| for (0..8) |horizontal| {
            const outcomes = affineOutcomes(scene.matrix, .{ .family = family, .width = scene.width, .height = scene.height, .opacity = 128, .tint = .{ 128, 64, 200 } }, horizontal, vertical);
            const actual = try fixture.pixel(@intCast(horizontal), @intCast(vertical));
            if (!outcomes.matches(actual)) {
                mismatches += 1;
                std.debug.print("AFFINE_LARGE_EXCEPTION case={d} family={s} extent={d},{d} matrix={any} pixel={d},{d} reference={any} actual={any} permitted={any}\n", .{ index, @tagName(family), scene.width, scene.height, scene.matrix, horizontal, vertical, outcomes.reference_pixel, actual, outcomes.allowed[0..outcomes.count] });
            }
        };
        std.debug.print("AFFINE_LARGE case={d} family={s} mismatches={d} path=SDL_geometry\n", .{ index, @tagName(family), mismatches });
        try std.testing.expectEqual(@as(usize, 0), mismatches);
    };
}

test "direct affine quads match independent inverse nearest sampling before polygon clipping" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const matrices = [_]rendering.types.Affine{
        .{},
        .{ .tx = 512, .ty = 256 },
        .{ .tx = 128, .ty = 64 },
        .{ .a = 98304, .d = 131072 },
        .{ .a = 0, .b = -65536, .c = 65536, .d = 0, .tx = 768 },
        .{ .a = -65536, .tx = 1024 },
        .{ .b = 32768 },
        .{ .b = 32768, .c = -16384, .d = 98304, .tx = 512, .ty = 256 },
        .{ .a = 0, .d = 0 },
        .{ .b = 65536, .c = 65536 },
        .{ .b = 65535, .c = 65537 },
        .{ .a = 1073741824, .tx = -16776960 },
        .{ .d = 1073741824, .ty = -16776960 },
        .{ .a = std.math.maxInt(i32), .d = std.math.maxInt(i32), .tx = std.math.minInt(i32), .ty = std.math.minInt(i32) },
        .{ .a = -65536, .tx = 1152 },
    };
    var pixels: [4 * 3 * 4]u8 = undefined;
    for (0..3) |vertical| for (0..4) |horizontal| @memcpy(pixels[(vertical * 4 + horizontal) * 4 ..][0..4], &affinePattern(horizontal, vertical));
    const id = try rendering.textures.createOperationDynamicTexture(fixture.instance, 4, 3, .operation_only);
    try rendering.textures.updateDynamicTexture(fixture.instance, id, 0, 0, 4, 3, &pixels, 16);
    var total_mismatches: usize = 0;
    for ([_]bool{ false, true }) |promoted| for (families) |family| {
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
        try rendering.layers.setAffine(fixture.instance, 0, .{});
        try rendering.draw.addTexturedQuadTinted(fixture.instance, id, 0, 0, 0, 0, 4, 3, 0, 0, 4, 3, false, false, 0, 0, 0, 255, 255, 255, 255);
        try fixture.execute();
        if (promoted) {
            try rendering.layers.setCanvasSampling(fixture.instance, 0, .bilinear);
            try fixture.begin();
            try fixture.execute();
            try rendering.layers.setCanvasSampling(fixture.instance, 0, .nearest);
            try fixture.begin();
            try fixture.execute();
        }
        const before = fixture.instance.canvas_stats;
        const target = fixture.instance.state.texture_table[fixture.instance.state.layers[0].target_texture_id];
        for (matrices, 0..) |matrix, index| {
            try rendering.layers.setAffine(fixture.instance, 0, matrix);
            try fixture.begin();
            try fixture.execute();
            var mismatches: usize = 0;
            var boundary_deviations: usize = 0;
            for (0..8) |vertical| for (0..8) |horizontal| {
                const expected = affineExpected(matrix, family, horizontal, vertical);
                const actual = try fixture.pixel(@intCast(horizontal), @intCast(vertical));
                var matches = true;
                for (expected, actual, 0..) |want, got, channel| {
                    if (@abs(@as(i16, want) - got) > (if (channel == 3) @as(i16, 0) else 3)) matches = false;
                }
                const outcomes = affineOutcomes(matrix, .{ .family = family }, horizontal, vertical);
                try std.testing.expectEqual(expected, outcomes.reference_pixel);
                if (!matches and !outcomes.matches(actual)) {
                    mismatches += 1;
                    std.debug.print("AFFINE_MISMATCH renderer={s} case={d} family={s} matrix={any} pixel={d},{d} expected={any} actual={any}\n", .{ sdl.SDL_GetRendererName(fixture.renderer), index, @tagName(family), matrix, horizontal, vertical, expected, actual });
                } else if (!matches) {
                    boundary_deviations += 1;
                    std.debug.print("AFFINE_ALLOWED_BOUNDARY case={d} family={s} pixel={d},{d} reference={any} actual={any} coverage_boundary={} texel_boundary={}\n", .{ index, @tagName(family), horizontal, vertical, expected, actual, outcomes.coverage_boundary, outcomes.texel_boundary });
                }
            };
            std.debug.print("AFFINE_CASE case={d} family={s} mismatches={d} path=direct-four-corner-SDL-geometry\n", .{ index, @tagName(family), mismatches });
            std.debug.print("AFFINE_CASE_BOUNDARIES case={d} family={s} permitted_deviations={d} sampling_cap=1/256 coverage_cap=1/256_destination\n", .{ index, @tagName(family), boundary_deviations });
            try std.testing.expectEqual(before.compiled_layers, fixture.instance.canvas_stats.compiled_layers);
            try std.testing.expectEqual(before.rasterized_canvases, fixture.instance.canvas_stats.rasterized_canvases);
            try std.testing.expectEqual(before.target_allocations, fixture.instance.canvas_stats.target_allocations);
            try std.testing.expectEqual(target, fixture.instance.state.texture_table[fixture.instance.state.layers[0].target_texture_id]);
            total_mismatches += mismatches;
        }
    };
    try std.testing.expectEqual(@as(usize, 0), total_mismatches);
}

test "operation identity opacity and tint include empty multiply filter extent" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    for (families) |family| for ([_]u8{ 0, 128, 255 }) |opacity| for ([_][3]u8{ .{ 255, 255, 255 }, .{ 128, 64, 200 } }) |tint| {
        try fixture.begin();
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try fixture.property(.clear_r, 255);
        try fixture.property(.clear_a, 255);
        try fixture.property(.opacity, opacity);
        try fixture.property(.tint_r, tint[0]);
        try fixture.property(.tint_g, tint[1]);
        try fixture.property(.tint_b, tint[2]);
        try fixture.execute();
        try near(reference(family, &.{}, opacity, tint), try fixture.pixel(7, 7));
        try std.testing.expectEqual(if (family == .multiply) [4]u8{ 255, 255, 255, 255 } else [4]u8{ 0, 0, 0, 0 }, try fixture.canvas());
    };
}

test "overlap accumulation coverage saturation and opacity obey independent equations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const scenes = [_][2][4]u8{ .{ .{ 240, 80, 40, 128 }, .{ 80, 240, 160, 192 } }, .{ .{ 240, 240, 240, 192 }, .{ 240, 240, 240, 192 } } };
    for (families) |family| for (scenes) |colors| for ([_]u8{ 0, 128, 255 }) |opacity| {
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try fixture.property(.opacity, opacity);
        try fixture.rect(colors[0], 0, 0, 4, 4);
        try fixture.rect(colors[1], 2, 1, 3, 3);
        try fixture.execute();
        try near(reference(family, &colors, opacity, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
        try near(reference(family, colors[0..1], opacity, .{ 255, 255, 255 }), try fixture.pixel(0, 0));
        const canvas = try fixture.canvas();
        if (family == .multiply) try std.testing.expectEqual(@as(u8, 255), canvas[3]);
        if (family == .additive) {
            try std.testing.expectEqual(@as(u8, 0), canvas[3]);
            if (colors[0][0] == 240 and colors[0][1] == 240) try std.testing.expectEqual(@as(u8, 255), canvas[0]);
        }
        if (family == .normal) {
            const first_alpha = @as(f64, @floatFromInt(colors[0][3])) / 255;
            const second_alpha = @as(f64, @floatFromInt(colors[1][3])) / 255;
            try std.testing.expect(@abs(@as(i16, canvas[3]) - byte(second_alpha + (1 - second_alpha) * first_alpha)) <= 1);
        }
    };
}

test "affine presentation reuses caches preserves pending submissions and retries failures" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    try fixture.begin();
    try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
    try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
    const texture_id = try fixture.texture(.{ 240, 80, 40, 128 });
    try fixture.textured(texture_id, .{ 255, 255, 255, 255 }, 0, 0, 4, 3);
    try fixture.execute();
    const target = fixture.instance.state.texture_table[fixture.instance.state.layers[0].target_texture_id];
    const source = fixture.instance.state.premultiplied_textures[texture_id];
    const canvas = fixture.instance.canvas_stats;
    const sources = fixture.instance.source_stats;
    const geometry = rendering.geometry.cachedVertex(fixture.instance, 0, 0);
    for ([_]rendering.types.Affine{ .{ .tx = 256 }, .{ .a = -65536, .tx = 1024 }, .{ .a = 0 }, .{} }) |matrix| {
        try fixture.begin();
        try rendering.layers.setAffine(fixture.instance, 0, matrix);
        try std.testing.expect(!fixture.instance.frame_ready);
        try fixture.execute();
        try std.testing.expectEqualDeep(canvas, fixture.instance.canvas_stats);
        try std.testing.expectEqualDeep(sources, fixture.instance.source_stats);
        try std.testing.expectEqualDeep(geometry, rendering.geometry.cachedVertex(fixture.instance, 0, 0));
        try std.testing.expectEqual(target, fixture.instance.state.texture_table[fixture.instance.state.layers[0].target_texture_id]);
        try std.testing.expectEqual(source, fixture.instance.state.premultiplied_textures[texture_id]);
        fixture.instance.changes = .{};
        try rendering.layers.setAffine(fixture.instance, 0, matrix);
        try std.testing.expect(fixture.instance.frame_ready);
        try std.testing.expect(!fixture.instance.changes.present_needed);
    }
    try rendering.draw.addSolidRectToLayer(fixture.instance, rendering.types.immediate_layer_id, 10, 7, 7, 1, 1, 255, 0, 0, 255);
    try fixture.execute();
    try rendering.layers.setAffine(fixture.instance, 0, .{ .tx = 256 });
    try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
    try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
    try fixture.begin();
    try fixture.execute();
    const failures = [_]struct { point: rendering.faults.Point, expected: rendering.compositor.RenderError }{
        .{ .point = .texture_blend, .expected = error.TextureStateFailed },
        .{ .point = .texture_color, .expected = error.TextureStateFailed },
        .{ .point = .texture_alpha, .expected = error.TextureStateFailed },
        .{ .point = .clip, .expected = error.ClipFailed },
        .{ .point = .geometry, .expected = error.GeometryFailed },
    };
    try fixture.property(.clip_w, 4);
    try fixture.property(.clip_h, 3);
    for (failures, 0..) |failure, index| {
        try fixture.begin();
        try rendering.layers.setAffine(fixture.instance, 0, .{ .tx = @intCast((index + 1) * 64) });
        fixture.instance.faults.inject(failure.point, 0);
        try std.testing.expectError(failure.expected, fixture.execute());
        try std.testing.expect(!fixture.instance.frame_ready);
        try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
        try std.testing.expect(!sdl.SDL_RenderClipEnabled(fixture.renderer));
        try fixture.begin();
        try fixture.execute();
        try std.testing.expect(fixture.instance.frame_ready);
    }
    fixture.instance.faults.inject(.present, 0);
    try std.testing.expectError(error.PresentFailed, rendering.compositor.present(fixture.instance));
    try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
    try fixture.begin();
    try fixture.execute();
    try rendering.compositor.present(fixture.instance);
    try std.testing.expectEqual(@as(usize, 0), fixture.instance.state.instruction_count);
    try fixture.begin();
    try fixture.property(.visible, 0);
    try fixture.execute();
    try rendering.layers.setAffine(fixture.instance, 0, .{ .ty = 256 });
    try std.testing.expect(!fixture.instance.frame_ready);
    try std.testing.expect(fixture.instance.changes.present_needed);
    const hidden_canvas = fixture.instance.canvas_stats;
    try fixture.property(.visible, 1);
    try fixture.execute();
    try std.testing.expectEqualDeep(hidden_canvas, fixture.instance.canvas_stats);
    try rendering.layers.resetLayer(fixture.instance, 0);
    try std.testing.expectEqualDeep(rendering.types.Affine{}, fixture.instance.state.layers[0].affine);
}

test "affine compatibility pan precedes mapping while scissor stays stationary and content clipping stays local" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const color = [4]u8{ 240, 80, 40, 128 };
    for (families) |family| {
        try fixture.begin();
        try rendering.layers.clearLayerContents(fixture.instance, 0);
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try rendering.layers.setCanvasExtent(fixture.instance, 0, 4, 3);
        try rendering.layers.setContentScroll(fixture.instance, 0, 1, 0);
        try rendering.layers.setSurfaceClip(fixture.instance, 0, .{ .x = 1, .y = 1, .w = 1, .h = 1 });
        try rendering.layers.setAffine(fixture.instance, 0, .{ .a = 0, .b = -65536, .c = 65536, .d = 0, .tx = 768, .ty = 256 });
        try fixture.property(.scroll_x, 1);
        try fixture.property(.opacity, 128);
        try fixture.property(.tint_r, 128);
        try fixture.property(.tint_g, 64);
        try fixture.property(.tint_b, 200);
        try fixture.rect(color, 2, 1, 1, 1);
        for ([_]bool{ false, true }) |scissored| {
            try fixture.begin();
            try fixture.property(.clip_x, 1);
            try fixture.property(.clip_y, 1);
            try fixture.property(.clip_w, if (scissored) 1 else 0);
            try fixture.property(.clip_h, if (scissored) 1 else 0);
            const cached = fixture.instance.canvas_stats;
            try fixture.execute();
            if (scissored) try std.testing.expectEqualDeep(cached, fixture.instance.canvas_stats);
            for (0..8) |vertical| for (0..8) |horizontal| {
                const covered = horizontal < 3 and vertical >= 1 and vertical < 4 and (!scissored or (horizontal == 1 and vertical == 1));
                const colors: []const [4]u8 = if (horizontal == 1 and vertical == 1) &.{color} else &.{};
                try near(if (covered) reference(family, colors, 128, .{ 128, 64, 200 }) else background, try fixture.pixel(@intCast(horizontal), @intCast(vertical)));
            };
        }
        try fixture.property(.clip_w, 0);
        try fixture.property(.clip_h, 0);
    }
}

test "mode changes rerasterize while presentation properties reuse geometry content and source variants" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    try fixture.begin();
    try fixture.rect(.{ 240, 80, 40, 128 }, 0, 0, 8, 8);
    for (families) |family| {
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        if (fixture.instance.state.layers[0].cached_vertex_count > 0) try std.testing.expect(!fixture.instance.state.layer_masks.has(.geometry_dirty, 0));
        try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
        try fixture.begin();
        try fixture.execute();
        const vertex_count = fixture.instance.state.layers[0].cached_vertex_count;
        const variant = fixture.instance.state.premultiplied_textures[fixture.instance.state.white_texture_id];
        try near(reference(family, &.{.{ 240, 80, 40, 128 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
        try fixture.begin();
        try fixture.property(.opacity, 128);
        try fixture.property(.tint_r, 128);
        try std.testing.expect(!fixture.instance.state.layer_masks.has(.target_dirty, 0));
        try std.testing.expect(!fixture.instance.state.layer_masks.has(.geometry_dirty, 0));
        try fixture.execute();
        try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.render_stats.draw_calls);
        try std.testing.expectEqual(variant, fixture.instance.state.premultiplied_textures[fixture.instance.state.white_texture_id]);
        try std.testing.expectEqual(vertex_count, fixture.instance.state.layers[0].cached_vertex_count);
        try near(reference(family, &.{.{ 240, 80, 40, 128 }}, 128, .{ 128, 255, 255 }), try fixture.pixel(2, 2));
        try fixture.property(.opacity, 255);
        try fixture.property(.tint_r, 255);
    }
}

test "texture and per-draw alpha premultiply once while legacy resources and rendering remain unchanged" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const pixels = [4]u8{ 240, 80, 40, 128 };
    const tint = [4]u8{ 80, 240, 160, 192 };
    try fixture.begin();
    const texture_id = try fixture.texture(pixels);
    const original = fixture.instance.state.texture_table[texture_id];
    try fixture.textured(texture_id, tint, 0, 0, 8, 8);
    try fixture.execute();
    const legacy = try fixture.pixel(2, 2);
    var original_blend: sdl.SDL_BlendMode = 0;
    try std.testing.expect(sdl.SDL_GetTextureBlendMode(original, &original_blend));
    for (families) |family| {
        try fixture.begin();
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        try fixture.property(.opacity, 128);
        try fixture.execute();
        const alpha: f64 = 128.0 / 255.0 * (192.0 / 255.0);
        var expected: [4]u8 = .{ 0, 0, 0, 255 };
        for (0..3) |channel| {
            const source = @as(f64, @floatFromInt(pixels[channel])) / 255 * @as(f64, @floatFromInt(tint[channel])) / 255 * alpha;
            const destination = @as(f64, @floatFromInt(background[channel])) / 255;
            expected[channel] = byte(switch (family) {
                .normal => 128.0 / 255.0 * source + (1 - 128.0 / 255.0 * alpha) * destination,
                .additive => destination + 128.0 / 255.0 * source,
                .multiply => destination * (1 - 128.0 / 255.0 * alpha + 128.0 / 255.0 * source),
                .legacy_rgba => unreachable,
            });
        }
        try near(expected, try fixture.pixel(2, 2));
        try std.testing.expectEqual(original, fixture.instance.state.texture_table[texture_id]);
        var restored_blend: sdl.SDL_BlendMode = 0;
        try std.testing.expect(sdl.SDL_GetTextureBlendMode(original, &restored_blend));
        try std.testing.expectEqual(original_blend, restored_blend);
    }
    try fixture.begin();
    try rendering.layers.setCanvasMode(fixture.instance, 0, .legacy_rgba);
    try fixture.property(.opacity, 255);
    try fixture.execute();
    try std.testing.expectEqual(legacy, try fixture.pixel(2, 2));
}

test "resource edits invalidate converted textures and hidden operation canvases then revive and retry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    try fixture.begin();
    const texture_id = try fixture.texture(.{ 240, 80, 40, 128 });
    try rendering.layers.setCanvasMode(fixture.instance, 0, .multiply);
    try fixture.textured(texture_id, .{ 255, 255, 255, 255 }, 0, 0, 8, 8);
    try fixture.execute();
    try std.testing.expect(fixture.instance.state.premultiplied_textures[texture_id] != null);
    try fixture.property(.visible, 0);
    try rendering.textures.updateDynamicTexture(fixture.instance, texture_id, 0, 0, 1, 1, &.{ 80, 240, 160, 192 }, 4);
    try std.testing.expect(fixture.instance.state.premultiplied_textures[texture_id] != null);
    try std.testing.expect(fixture.instance.state.operation_sources[texture_id].dirty != null);
    try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expect(!fixture.instance.state.layer_masks.has(.geometry_dirty, 0));
    try fixture.begin();
    try fixture.execute();
    try std.testing.expectEqual(background, try fixture.pixel(2, 2));
    try fixture.property(.visible, 1);
    fixture.instance.faults.inject(.geometry, 0);
    try std.testing.expectError(error.GeometryFailed, fixture.execute());
    try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
    try fixture.begin();
    try fixture.execute();
    try near(reference(.multiply, &.{.{ 80, 240, 160, 192 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
    try std.testing.expectEqual(@as(u8, 255), (try fixture.canvas())[3]);
}

test "source allocation upload state accumulation and presentation failures remain retryable" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const cases = .{
        .{ rendering.faults.Point.operation_allocation, error.ResourceConversionFailed, 0 },
        .{ rendering.faults.Point.operation_upload, error.ResourceConversionFailed, 0 },
        .{ rendering.faults.Point.target_creation, error.TargetCreationFailed, 0 },
        .{ rendering.faults.Point.target_select, error.TargetSelectionFailed, 0 },
        .{ rendering.faults.Point.clear, error.ClearFailed, 0 },
        .{ rendering.faults.Point.draw_color, error.DrawColorFailed, 0 },
        .{ rendering.faults.Point.render_scale, error.RenderScaleFailed, 0 },
        .{ rendering.faults.Point.clip, error.ClipFailed, 0 },
        .{ rendering.faults.Point.texture_blend, error.TextureStateFailed, 0 },
        .{ rendering.faults.Point.texture_color, error.TextureStateFailed, 0 },
        .{ rendering.faults.Point.texture_alpha, error.TextureStateFailed, 0 },
        .{ rendering.faults.Point.texture_scale, error.TextureStateFailed, 0 },
        .{ rendering.faults.Point.target_restore, error.TargetRestoreFailed, 0 },
        .{ rendering.faults.Point.geometry, error.GeometryFailed, 0 },
        .{ rendering.faults.Point.geometry, error.GeometryFailed, 1 },
    };
    for (families) |family| inline for (cases) |case| {
        fixture.instance.deinit();
        try fixture.instance.init(std.testing.allocator, .{ .renderer = fixture.renderer, .logical_width = 8, .logical_height = 8, .opaque_presentation = true });
        try fixture.begin();
        try rendering.layers.setCanvasMode(fixture.instance, 0, family);
        const source_id = try fixture.texture(.{ 255, 255, 255, 255 });
        try fixture.textured(source_id, .{ 240, 80, 40, 128 }, 0, 0, 8, 8);
        if (case[0] != .target_creation) try std.testing.expect(rendering.textures.ensureLayerTarget(fixture.instance, 0));
        fixture.instance.faults.inject(case[0], case[2]);
        try std.testing.expectError(case[1], fixture.execute());
        try std.testing.expectEqual(!(case[0] == .geometry and case[2] == 1), fixture.instance.state.layer_masks.has(.target_dirty, 0));
        try std.testing.expect(!fixture.instance.state.layer_masks.has(.geometry_dirty, 0));
        try std.testing.expect(sdl.SDL_GetRenderTarget(fixture.renderer) == null);
        try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
        try fixture.begin();
        try fixture.execute();
        try near(reference(family, &.{.{ 240, 80, 40, 128 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
        const completed_rasters = fixture.instance.canvas_stats.rasterized_canvases;
        fixture.instance.faults.inject(.present, 0);
        try std.testing.expectError(error.PresentFailed, rendering.compositor.present(fixture.instance));
        try std.testing.expect(!fixture.instance.state.layer_masks.has(.target_dirty, 0));
        try fixture.begin();
        try fixture.execute();
        try near(reference(family, &.{.{ 240, 80, 40, 128 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(2, 2));
        try std.testing.expectEqual(completed_rasters, fixture.instance.canvas_stats.rasterized_canvases);
        try rendering.compositor.present(fixture.instance);
        try std.testing.expect(!fixture.instance.state.layer_masks.has(.present_dirty, 0));
    };
}

test "operation resource release and differently sized reuse recompile UVs and rebuild source representation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    try fixture.begin();
    const texture_id = try fixture.texture(.{ 240, 80, 40, 128 });
    try rendering.layers.setCanvasMode(fixture.instance, 0, .multiply);
    try fixture.textured(texture_id, .{ 255, 255, 255, 255 }, 0, 0, 8, 8);
    try fixture.execute();
    fixture.instance.state.frame_state = .idle;
    try rendering.textures.destroyDynamicTexture(fixture.instance, texture_id);
    try std.testing.expect(fixture.instance.state.premultiplied_textures[texture_id] == null);
    try std.testing.expect(fixture.instance.state.layer_masks.has(.geometry_dirty, 0));
    const reused = try rendering.textures.createOperationDynamicTexture(fixture.instance, 2, 1, .shared);
    try std.testing.expectEqual(texture_id, reused);
    try rendering.textures.updateDynamicTexture(fixture.instance, reused, 0, 0, 2, 1, &.{ 80, 240, 160, 192, 240, 80, 40, 128 }, 8);
    try fixture.begin();
    try fixture.execute();
    try std.testing.expectEqual(@as(f32, 0.5), rendering.geometry.cachedVertex(fixture.instance, 0, 1).tex_coord.x);
    try near(reference(.multiply, &.{.{ 80, 240, 160, 192 }}, 255, .{ 255, 255, 255 }), try fixture.pixel(7, 2));
    try std.testing.expect(fixture.instance.state.premultiplied_textures[texture_id] != null);
}

test "operation contract explicitly rejects undeclared opaque destination without changing legacy mode" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.instance.context.opaque_presentation = false;
    try fixture.begin();
    try rendering.layers.setCanvasMode(fixture.instance, 0, .multiply);
    try std.testing.expectError(error.OpaqueBackgroundRequired, fixture.execute());
    try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
    try rendering.layers.setCanvasMode(fixture.instance, 0, .legacy_rgba);
    try fixture.property(.clear_r, 240);
    try fixture.property(.clear_a, 255);
    try fixture.execute();
    try std.testing.expectEqual([4]u8{ 240, 0, 0, 255 }, try fixture.pixel(2, 2));
}

test "operation resources reject render-target input representations without changing legacy resources" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (try fixture.unsupported()) return;
    const handle = try rendering.render_targets.create(fixture.instance, 1, 1);
    try fixture.begin();
    try rendering.render_targets.begin(fixture.instance, handle, .{ .r = 240, .g = 80, .b = 40, .a = 128 });
    try rendering.render_targets.end(fixture.instance);
    const texture_id = fixture.instance.state.render_targets[handle].texture_id;
    const original = fixture.instance.state.texture_table[texture_id];
    try rendering.layers.setCanvasMode(fixture.instance, 0, .normal);
    try fixture.textured(texture_id, .{ 255, 255, 255, 255 }, 0, 0, 8, 8);
    try std.testing.expectError(error.UnsupportedOperationResource, fixture.execute());
    try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
    try std.testing.expect(fixture.instance.state.premultiplied_textures[texture_id] == null);
    try std.testing.expectEqual(original, fixture.instance.state.texture_table[texture_id]);
    try rendering.layers.setCanvasMode(fixture.instance, 0, .legacy_rgba);
    try fixture.begin();
    try fixture.execute();
    try std.testing.expect(fixture.instance.frame_ready);
}
