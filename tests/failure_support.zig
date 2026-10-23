pub const std = @import("std");
pub const rendering = @import("compositor");
pub const sdl = rendering.sdl;
pub const red = [4]u8{ 230, 30, 50, 255 };
pub const green = [4]u8{ 20, 210, 70, 255 };
pub const palette = [_]u8{ 230, 30, 50, 20, 210, 70 };
pub const swapped = [_]u8{ 20, 210, 70, 230, 30, 50 };

pub const Fixture = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    instance: *rendering.Instance,

    pub fn init() !Fixture {
        try std.testing.expect(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
        errdefer sdl.SDL_Quit();
        const window = sdl.SDL_CreateWindow("Compositor failures", 64, 64, sdl.SDL_WINDOW_HIDDEN) orelse return error.WindowUnavailable;
        errdefer sdl.SDL_DestroyWindow(window);
        const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.RendererUnavailable;
        errdefer sdl.SDL_DestroyRenderer(renderer);
        const instance = try std.testing.allocator.create(rendering.Instance);
        try instance.init(std.testing.allocator, .{ .renderer = renderer, .logical_width = 64, .logical_height = 64 });
        std.debug.print("failure-check: renderer {s}\n", .{sdl.SDL_GetRendererName(renderer)});
        return .{ .window = window, .renderer = renderer, .instance = instance };
    }

    pub fn deinit(self: *Fixture) void {
        self.instance.deinit();
        std.testing.allocator.destroy(self.instance);
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }

    pub fn begin(self: *Fixture) !void {
        self.instance.state.frame_state = .updating;
        self.instance.changes = .{};
        try self.clear();
    }

    pub fn clear(self: *Fixture) !void {
        try std.testing.expect(sdl.SDL_SetRenderTarget(self.renderer, null));
        try std.testing.expect(sdl.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255));
        try std.testing.expect(sdl.SDL_RenderClear(self.renderer));
    }

    pub fn draw(self: *Fixture, texture_id: u16, layer: u8, horizontal: c_int) !void {
        try rendering.draw.addTexturedQuadTinted(self.instance, texture_id, layer, 0, 0, 0, 1, 1, horizontal, 8, 16, 16, false, false, 0, 0, 0, 255, 255, 255, 255);
    }

    pub fn execute(self: *Fixture) !void {
        try rendering.layers.compileDirtyRetainedLayers(self.instance);
        try rendering.compositor.executeCompositeFrame(self.instance);
    }

    pub fn present(self: *Fixture) !void {
        try rendering.compositor.present(self.instance);
        self.instance.state.frame_state = .idle;
    }

    pub fn expect(self: *Fixture, horizontal: c_int, expected: [4]u8) !void {
        const surface = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadbackFailed;
        defer sdl.SDL_DestroySurface(surface);
        var actual: [4]u8 = undefined;
        try std.testing.expect(sdl.SDL_ReadSurfacePixel(surface, horizontal, 16, &actual[0], &actual[1], &actual[2], &actual[3]));
        try std.testing.expectEqual(expected, actual);
    }

    pub fn graphic(self: *Fixture) !void {
        try rendering.textures.addGraphics8Bit(self.instance, 0, &.{0}, 2, &palette, 1, 1, 2);
    }
};
