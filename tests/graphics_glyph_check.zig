const std = @import("std");
const api = @import("graphics");
const sdl = api.sdl;

test "font loading before initialization returns false without a graphics instance" {
    var fonts: api.Fonts = .{};
    try std.testing.expect(!fonts.loadFontSlot(0, "unused.ttf", 14, 128, 128, false));
    try std.testing.expect(!fonts.loadFont("unused.ttf", 14, 128, 128, false));
    fonts.deinit();
}

test "font instances own separate caches and atlas lifetimes" {
    try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();
    const first_window = sdl.SDL_CreateWindow("Glyphs first", 64, 48, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(first_window);
    const second_window = sdl.SDL_CreateWindow("Glyphs second", 64, 48, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
    defer sdl.SDL_DestroyWindow(second_window);
    const first = try std.testing.allocator.create(api.Graphics);
    defer std.testing.allocator.destroy(first);
    first.* = .{};
    const second = try std.testing.allocator.create(api.Graphics);
    defer std.testing.allocator.destroy(second);
    second.* = .{};
    const config: api.Config = .{ .width = 64, .height = 48, .vsync = false, .capacity = .{ .ceiling = 64, .reserved = 64 } };
    try first.init(std.testing.allocator, first_window, config);
    defer first.deinit();
    try second.init(std.testing.allocator, second_window, config);
    defer second.deinit();
    var first_fonts: api.Fonts = .{};
    var second_fonts: api.Fonts = .{};
    first_fonts.deinit();
    try first_fonts.init(std.testing.allocator, first);
    defer first_fonts.deinit();
    try second_fonts.init(std.testing.allocator, second);
    defer second_fonts.deinit();
    const font = sdl.SDL_getenv("SMULE_TEST_FONT") orelse return error.TestFontRequired;
    try std.testing.expect(first_fonts.loadFont(std.mem.span(font), 14, 128, 128, false));
    try std.testing.expect(!second_fonts.hasFace());
    try first.beginFrame();
    try std.testing.expect(first_fonts.drawText("Ab", 2, 2, 0, 255, 255, 255, 255, 0xff));
    try std.testing.expectEqual(@as(u32, 2), first_fonts.state.slots[0].glyph_cache.count());
    try std.testing.expectEqual(@as(u32, 0), second_fonts.state.slots[0].glyph_cache.count());
    try first.executeCompositeFrame();
    try first.present();
    first_fonts.deinit();
    try std.testing.expect(second_fonts.loadFont(std.mem.span(font), 14, 128, 128, true));
    try std.testing.expect(second_fonts.measureText("Ab") > 0);
}
