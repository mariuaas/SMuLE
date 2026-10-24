const support = @import("failure_support.zig");
const std = support.std;
const rendering = support.rendering;
const sdl = support.sdl;
const red = support.red;
const green = support.green;
const palette = support.palette;
const swapped = support.swapped;
const Fixture = support.Fixture;

test "palette replacement failures preserve owned resource and reserved ID then retry" {
    const cases = .{
        .{ rendering.faults.Point.palette_allocation, error.PaletteAllocationFailed },
        .{ rendering.faults.Point.palette_creation, error.PaletteCreationFailed },
        .{ rendering.faults.Point.palette_colors, error.PaletteUpdateFailed },
        .{ rendering.faults.Point.surface_palette, error.SurfacePaletteFailed },
        .{ rendering.faults.Point.texture_creation, error.TextureCreationFailed },
        .{ rendering.faults.Point.texture_scale, error.TextureUpdateFailed },
    };
    inline for (cases) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.graphic();
        const graphic = &fixture.instance.state.graphics[0];
        const texture_id = graphic.texture_ids[0];
        const old_texture = graphic.textures[0];
        const old_colors = graphic.colors[0];
        const old_surface = graphic.surface;
        try fixture.begin();
        try fixture.draw(texture_id, 0, 8);
        try fixture.execute();
        try fixture.expect(16, red);
        try fixture.present();
        const next_id = fixture.instance.state.next_texture_id;
        const free_ids = fixture.instance.state.free_texture_id_count;
        fixture.instance.faults.inject(case[0], 0);
        try std.testing.expectError(case[1], rendering.textures.addPalette(fixture.instance, 0, 0, 1, &swapped, 2));
        try std.testing.expectEqual(texture_id, graphic.texture_ids[0]);
        try std.testing.expectEqual(old_texture, graphic.textures[0]);
        try std.testing.expectEqual(old_colors, graphic.colors[0]);
        try std.testing.expectEqual(old_surface, graphic.surface);
        try std.testing.expectEqual(old_texture, fixture.instance.state.texture_table[texture_id]);
        try std.testing.expect(graphic.flags[0]);
        try std.testing.expectEqual(@as(u32, 2), graphic.ncolors[0]);
        try std.testing.expectEqual(next_id, fixture.instance.state.next_texture_id);
        try std.testing.expectEqual(free_ids, fixture.instance.state.free_texture_id_count);
        var key: u32 = 0;
        try std.testing.expect(!sdl.SDL_GetSurfaceColorKey(graphic.surface, &key));
        rendering.layers.invalidateTexture(fixture.instance, texture_id, false);
        try fixture.begin();
        try fixture.execute();
        try fixture.expect(16, red);
        try fixture.present();
        try rendering.textures.addPalette(fixture.instance, 0, 0, 2, &swapped, 2);
        try std.testing.expectEqual(texture_id, graphic.texture_ids[0]);
        try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
        try fixture.begin();
        try fixture.execute();
        try fixture.expect(16, green);
        try fixture.present();
    }
}

test "indexed update failures at each palette leave surface and every texture coherent" {
    const cases = .{
        .{ rendering.faults.Point.surface_creation, error.SurfaceCreationFailed },
        .{ rendering.faults.Point.palette_creation, error.PaletteCreationFailed },
        .{ rendering.faults.Point.palette_colors, error.PaletteUpdateFailed },
        .{ rendering.faults.Point.surface_palette, error.SurfacePaletteFailed },
        .{ rendering.faults.Point.texture_creation, error.TextureCreationFailed },
        .{ rendering.faults.Point.texture_scale, error.TextureUpdateFailed },
    };
    inline for (cases) |case| {
        const occurrences = if (case[0] == .surface_creation) 1 else 3;
        for (0..occurrences) |occurrence| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.graphic();
            try rendering.textures.addPalette(fixture.instance, 0, 1, 2, &palette, 2);
            try rendering.textures.addPalette(fixture.instance, 0, 2, 2, &palette, 2);
            const graphic = &fixture.instance.state.graphics[0];
            const old_textures = graphic.textures;
            const old_colors = graphic.colors;
            const old_ids = graphic.texture_ids;
            const old_surface = graphic.surface;
            const free_ids = fixture.instance.state.free_texture_id_count;
            try fixture.begin();
            for (0..3) |slot| try fixture.draw(old_ids[slot], @intCast(slot), @intCast(8 + slot * 16));
            try fixture.execute();
            try fixture.present();
            fixture.instance.faults.inject(case[0], occurrence);
            try std.testing.expectError(case[1], rendering.textures.updateGraphics8BitPixels(fixture.instance, 0, &.{1}, 1, 1));
            try std.testing.expectEqual(old_surface, graphic.surface);
            const bytes: [*]u8 = @ptrCast(graphic.surface.?.pixels);
            try std.testing.expectEqual(@as(u8, 0), bytes[0]);
            try std.testing.expectEqual(old_textures, graphic.textures);
            try std.testing.expectEqual(old_colors, graphic.colors);
            try std.testing.expectEqual(old_ids, graphic.texture_ids);
            try std.testing.expectEqual(free_ids, fixture.instance.state.free_texture_id_count);
            for (0..3) |slot| try std.testing.expectEqual(old_textures[slot], fixture.instance.state.texture_table[old_ids[slot]]);
            for (0..3) |slot| rendering.layers.invalidateTexture(fixture.instance, old_ids[slot], false);
            try fixture.begin();
            try fixture.execute();
            for (0..3) |slot| try fixture.expect(@intCast(16 + slot * 16), red);
            try fixture.present();
            try rendering.textures.updateGraphics8BitPixels(fixture.instance, 0, &.{1}, 1, 1);
            try std.testing.expectEqual(old_ids, graphic.texture_ids);
            try fixture.begin();
            try fixture.execute();
            for (0..3) |slot| try fixture.expect(@intCast(16 + slot * 16), green);
            try fixture.present();
        }
    }
}

test "failed accumulation stays dirty while failed presentation preserves completed canvases for retry" {
    const cases = .{
        .{ rendering.faults.Point.target_creation, error.TargetCreationFailed },
        .{ rendering.faults.Point.target_select, error.TargetSelectionFailed },
        .{ rendering.faults.Point.render_scale, error.RenderScaleFailed },
        .{ rendering.faults.Point.draw_color, error.DrawColorFailed },
        .{ rendering.faults.Point.clear, error.ClearFailed },
        .{ rendering.faults.Point.texture_blend, error.TextureStateFailed },
        .{ rendering.faults.Point.texture_color, error.TextureStateFailed },
        .{ rendering.faults.Point.texture_alpha, error.TextureStateFailed },
        .{ rendering.faults.Point.geometry, error.GeometryFailed },
        .{ rendering.faults.Point.target_restore, error.TargetRestoreFailed },
        .{ rendering.faults.Point.blit, error.BlitFailed },
        .{ rendering.faults.Point.clip, error.ClipFailed },
    };
    inline for (cases) |case| {
        const occurrences = if (case[0] == .texture_blend or case[0] == .texture_color or case[0] == .texture_alpha or case[0] == .render_scale or case[0] == .clip) 2 else 1;
        for (0..occurrences) |occurrence| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.graphic();
            try fixture.begin();
            try fixture.draw(fixture.instance.state.graphics[0].texture_ids[0], 0, 8);
            fixture.instance.state.layer_masks.set(.visible, 31, false);
            fixture.instance.state.layer_masks.set(.present_dirty, 31, true);
            fixture.instance.state.layer_masks.set(.target_dirty, 31, true);
            if (case[0] != .target_creation) try std.testing.expect(rendering.textures.ensureLayerTarget(fixture.instance, 0));
            try rendering.layers.compileDirtyRetainedLayers(fixture.instance);
            fixture.instance.faults.inject(case[0], occurrence);
            try std.testing.expectError(case[1], rendering.compositor.executeCompositeFrame(fixture.instance));
            const output_failure = case[0] == .blit or case[0] == .clip or ((case[0] == .texture_blend or case[0] == .texture_color or case[0] == .texture_alpha) and occurrence == 1);
            try std.testing.expectEqual(!output_failure, fixture.instance.state.layer_masks.has(.target_dirty, 0));
            try std.testing.expect(fixture.instance.state.layer_masks.has(.present_dirty, 0));
            try std.testing.expect(fixture.instance.changes.present_needed);
            try std.testing.expect(sdl.SDL_GetRenderTarget(fixture.renderer) == null);
            try std.testing.expect(!fixture.instance.state.layer_masks.has(.geometry_dirty, 0));
            try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
            try fixture.clear();
            try fixture.execute();
            try fixture.expect(16, red);
            try std.testing.expect(!fixture.instance.state.layer_masks.has(.target_dirty, 0));
            try std.testing.expect(fixture.instance.state.layer_masks.has(.present_dirty, 0));
            const completed_rasters = fixture.instance.canvas_stats.rasterized_canvases;
            fixture.instance.faults.inject(.present, 0);
            try std.testing.expectError(error.PresentFailed, rendering.compositor.present(fixture.instance));
            try std.testing.expect(!fixture.instance.state.layer_masks.has(.target_dirty, 0));
            try std.testing.expect(fixture.instance.state.layer_masks.has(.present_dirty, 0));
            try fixture.clear();
            try fixture.execute();
            try fixture.expect(16, red);
            try std.testing.expectEqual(completed_rasters, fixture.instance.canvas_stats.rasterized_canvases);
            try fixture.present();
            try std.testing.expect(!fixture.instance.state.layer_masks.has(.target_dirty, 0));
            try std.testing.expect(!fixture.instance.state.layer_masks.has(.present_dirty, 0));
            try std.testing.expect(fixture.instance.state.layer_masks.has(.present_dirty, 31));
            try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 31));
        }
    }
}

test "failed immediate geometry blit and present preserve submissions for retry" {
    for ([_]bool{ true, false }) |geometry_backend| {
        for ([_]f64{ 0, 27 }) |angle| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            fixture.instance.state.use_geometry_backend = geometry_backend;
            try fixture.graphic();
            try fixture.begin();
            try rendering.draw.addTexturedQuadTinted(fixture.instance, fixture.instance.state.graphics[0].texture_ids[0], rendering.types.immediate_layer_id, 0, 0, 0, 1, 1, 8, 8, 16, 16, false, false, 0, 0, angle, 255, 255, 255, 255);
            fixture.instance.faults.inject(if (geometry_backend) .geometry else .blit, 0);
            try std.testing.expectError(if (geometry_backend) error.GeometryFailed else error.BlitFailed, rendering.compositor.executeCompositeFrame(fixture.instance));
            try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
            try fixture.clear();
            try fixture.execute();
            try fixture.expect(16, red);
            fixture.instance.faults.inject(.present, 0);
            try std.testing.expectError(error.PresentFailed, rendering.compositor.present(fixture.instance));
            try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
            try fixture.clear();
            try fixture.execute();
            try fixture.expect(16, red);
            try fixture.present();
            try std.testing.expectEqual(@as(usize, 0), fixture.instance.state.instruction_count);
        }
    }
}

test "immediate resource edits reject stale presentation and preserve submissions for recomposition" {
    const Edit = enum { upload, release, unrelated };
    for ([_]bool{ true, false }) |geometry_backend| {
        for ([_]Edit{ .upload, .release, .unrelated }) |edit| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            fixture.instance.state.use_geometry_backend = geometry_backend;
            const referenced = try rendering.textures.createDynamicTexture(fixture.instance, 1, 1);
            const unrelated = try rendering.textures.createDynamicTexture(fixture.instance, 1, 1);
            try rendering.textures.updateDynamicTexture(fixture.instance, referenced, 0, 0, 1, 1, &red, 4);
            try rendering.textures.updateDynamicTexture(fixture.instance, unrelated, 0, 0, 1, 1, &red, 4);
            try fixture.begin();
            try fixture.draw(referenced, rendering.types.immediate_layer_id, 8);
            try fixture.execute();
            try fixture.expect(16, red);
            try std.testing.expect(fixture.instance.frame_ready);
            fixture.instance.changes = .{};
            try rendering.textures.updateDynamicTexture(fixture.instance, unrelated, 0, 0, 1, 1, &green, 4);
            try std.testing.expect(fixture.instance.frame_ready);
            try std.testing.expect(!fixture.instance.changes.present_needed);
            if (edit == .unrelated) {
                try fixture.present();
                try std.testing.expectEqual(@as(usize, 0), fixture.instance.state.instruction_count);
                continue;
            }
            if (edit == .upload) {
                try rendering.textures.updateDynamicTexture(fixture.instance, referenced, 0, 0, 1, 1, &green, 4);
            } else {
                fixture.instance.state.frame_state = .idle;
                try rendering.textures.destroyDynamicTexture(fixture.instance, referenced);
                fixture.instance.state.frame_state = .updating;
            }
            try std.testing.expect(!fixture.instance.frame_ready);
            try std.testing.expect(fixture.instance.changes.present_needed);
            try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
            try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
            try fixture.clear();
            try fixture.execute();
            try fixture.expect(16, if (edit == .upload) green else .{ 0, 0, 0, 255 });
            if (edit == .release) {
                fixture.instance.state.frame_state = .idle;
                const reused = try rendering.textures.createDynamicTexture(fixture.instance, 1, 1);
                try std.testing.expectEqual(referenced, reused);
                try rendering.textures.updateDynamicTexture(fixture.instance, reused, 0, 0, 1, 1, &green, 4);
                fixture.instance.state.frame_state = .updating;
                try std.testing.expectError(error.FrameNotReady, rendering.compositor.present(fixture.instance));
                try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
                try fixture.clear();
                try fixture.execute();
                try fixture.expect(16, green);
            }
            try fixture.present();
            try std.testing.expectEqual(@as(usize, 0), fixture.instance.state.instruction_count);
        }
    }
}

test "palette ID exhaustion does not publish partial ownership and reserved replacement still works" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.graphic();
    const graphic = &fixture.instance.state.graphics[0];
    const old_id = graphic.texture_ids[0];
    const next_id = fixture.instance.state.next_texture_id;
    fixture.instance.state.next_texture_id = rendering.types.max_texture_ids;
    try std.testing.expectError(error.TextureIdPoolExhausted, rendering.textures.addPalette(fixture.instance, 0, 1, 2, &palette, 2));
    try std.testing.expect(graphic.textures[1] == null);
    try std.testing.expect(graphic.colors[1] == null);
    try std.testing.expect(!graphic.flags[1]);
    try std.testing.expectEqual(@as(u16, 0), graphic.texture_ids[1]);
    try rendering.textures.addPalette(fixture.instance, 0, 0, 2, &swapped, 2);
    try std.testing.expectEqual(old_id, graphic.texture_ids[0]);
    fixture.instance.state.next_texture_id = next_id;
    try rendering.textures.addPalette(fixture.instance, 0, 1, 2, &palette, 2);
    try std.testing.expect(graphic.flags[1]);
    try fixture.begin();
    try fixture.draw(old_id, 0, 8);
    try fixture.execute();
    try fixture.expect(16, green);
    try fixture.present();
}

test "failure after an earlier retained run never validates the partial canvas" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.graphic();
    try rendering.textures.addPalette(fixture.instance, 0, 1, 2, &swapped, 2);
    try fixture.begin();
    try fixture.draw(fixture.instance.state.graphics[0].texture_ids[0], 0, 8);
    try fixture.draw(fixture.instance.state.graphics[0].texture_ids[1], 0, 32);
    try rendering.layers.compileDirtyRetainedLayers(fixture.instance);
    fixture.instance.faults.inject(.geometry, 1);
    try std.testing.expectError(error.GeometryFailed, rendering.compositor.executeCompositeFrame(fixture.instance));
    try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.render_stats.draw_calls);
    try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
    try fixture.clear();
    try fixture.execute();
    try fixture.expect(16, red);
    try fixture.expect(40, green);
    try fixture.present();
}

test "explicit target begin and end failures remain observable and retryable" {
    const cases = .{
        .{ rendering.faults.Point.target_select, error.TextureRegistrationFailed },
        .{ rendering.faults.Point.render_scale, error.RenderScaleFailed },
        .{ rendering.faults.Point.draw_color, error.DrawColorFailed },
        .{ rendering.faults.Point.clear, error.ClearFailed },
    };
    inline for (cases) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const handle = try rendering.render_targets.create(fixture.instance, 1, 1);
        try fixture.begin();
        fixture.instance.faults.inject(case[0], 0);
        try std.testing.expectError(case[1], rendering.render_targets.begin(fixture.instance, handle, .{}));
        try std.testing.expectEqual(@as(i16, -1), fixture.instance.state.active_render_target);
        try std.testing.expect(sdl.SDL_GetRenderTarget(fixture.renderer) == null);
        try rendering.render_targets.begin(fixture.instance, handle, .{ .r = red[0], .g = red[1], .b = red[2], .a = 255 });
        try rendering.render_targets.end(fixture.instance);
        try fixture.draw(fixture.instance.state.render_targets[handle].texture_id, 0, 8);
        try fixture.execute();
        try fixture.expect(16, red);
        try fixture.present();
        try fixture.begin();
        try rendering.render_targets.begin(fixture.instance, handle, .{ .clear = false });
        try rendering.draw.addSolidRect(fixture.instance, 0, 0, 0, 1, 1, green[0], green[1], green[2], 255);
        fixture.instance.faults.inject(.blit, 0);
        try std.testing.expectError(error.BlitFailed, rendering.render_targets.end(fixture.instance));
        try std.testing.expect(fixture.instance.state.layer_masks.has(.target_dirty, 0));
        try std.testing.expectEqual(@as(usize, 1), fixture.instance.state.instruction_count);
        try std.testing.expectEqual(@as(i16, handle), fixture.instance.state.active_render_target);
        try rendering.render_targets.end(fixture.instance);
        try fixture.execute();
        try fixture.expect(16, green);
        try fixture.present();
        try fixture.begin();
        try rendering.render_targets.begin(fixture.instance, handle, .{ .clear = false });
        fixture.instance.faults.inject(.target_restore, 0);
        try std.testing.expectError(error.TargetRestoreFailed, rendering.render_targets.end(fixture.instance));
        try std.testing.expectEqual(@as(i16, handle), fixture.instance.state.active_render_target);
        try std.testing.expect(sdl.SDL_GetRenderTarget(fixture.renderer) == null);
        try std.testing.expectError(error.TargetActive, rendering.compositor.executeCompositeFrame(fixture.instance));
        try rendering.render_targets.end(fixture.instance);
        try fixture.execute();
        try fixture.expect(16, green);
        try fixture.present();
    }
}
