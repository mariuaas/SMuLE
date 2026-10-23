const std = @import("std");
const log = std.log.scoped(.smule);
const Graphics = @import("root.zig").Graphics;
const freetype = @import("freetype");

const max_glyph_cache_entries = 2048;
const glyph_padding = 1;

pub const default_font_slot: u8 = 0;
pub const max_fonts: usize = 8;

pub const GlyphEntry = struct {
    atlas_x: u32 = 0,
    atlas_y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    bearing_x: i32 = 0,
    bearing_y: i32 = 0,
    advance_x: i32 = 0,
};

pub const FontMetrics = struct {
    cell_width: u32 = 0,
    cell_height: u32 = 0,
    ascender: i32 = 0,
    descender: i32 = 0,
    line_height: u32 = 0,
};

pub const FontSlotState = struct {
    face: ?freetype.Face = null,
    metrics: FontMetrics = .{},
    glyph_cache: std.AutoHashMap(u32, GlyphEntry) = undefined,
    cache_initialized: bool = false,
    atlas_texture_id: u16 = 0,
    atlas_width: u32 = 0,
    atlas_height: u32 = 0,
    atlas_next_x: u32 = 0,
    atlas_next_y: u32 = 0,
    atlas_row_height: u32 = 0,
    loaded: bool = false,
};

pub const TextState = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    library: ?freetype.Library = null,
    slots: [max_fonts]FontSlotState = undefined,
    initialized: bool = false,
};

pub const TextError = error{
    NotInitialized,
    InvalidFontSlot,
};

/// Optional FreeType service borrowing an initialized, address-stable Graphics.
/// Owns its font faces, glyph caches and atlas textures; deinit before Graphics.
pub const Fonts = struct {
    state: TextState = .{},
    graphics: *Graphics = undefined,
    pub fn init(
        self: *Fonts,
        app_allocator: std.mem.Allocator,
        graphics: *Graphics,
    ) !void {
        if (self.state.initialized) return;
        if (!graphics.initialized) return error.GraphicsNotInitialized;
        self.graphics = graphics;

        self.state.allocator = app_allocator;
        self.state.library = try freetype.Library.init();
        for (&self.state.slots) |*slot| {
            slot.* = .{};
            slot.glyph_cache = std.AutoHashMap(u32, GlyphEntry).init(self.state.allocator);
            slot.cache_initialized = true;
        }
        self.state.initialized = true;

        if (self.graphics.configuration().debug_mode) {
            const version = self.state.library.?.version();
            log.debug(
                "Text subsystem initialized (FreeType {d}.{d}.{d}, {d} font slots)",
                .{ version.major, version.minor, version.patch, max_fonts },
            );
        }
    }

    pub fn deinit(self: *Fonts) void {
        if (!self.state.initialized) return;
        for (&self.state.slots) |*slot| {
            self.destroyAtlas(slot);
            self.clearGlyphCache(slot);
            unloadFace(slot);
            if (slot.cache_initialized) {
                slot.glyph_cache.deinit();
                slot.cache_initialized = false;
            }
            slot.metrics = .{};
            slot.loaded = false;
        }

        if (self.state.library) |library| {
            library.deinit();
            self.state.library = null;
        }

        self.state.initialized = false;

        if (self.graphics.configuration().debug_mode) {
            log.debug("Text subsystem dismantled", .{});
        }
    }

    pub fn loadMonospaceFaceSlot(
        self: *Fonts,
        slot_index: u8,
        path: [:0]const u8,
        pixel_height: u32,
    ) !void {
        if (!self.state.initialized or self.state.library == null) return TextError.NotInitialized;
        const slot = try self.getSlotMut(slot_index);

        unloadFace(slot);

        var face = try self.state.library.?.initFace(path, 0);
        errdefer face.deinit();

        try face.selectCharmap(.unicode);
        try face.setCharSize(0, @as(i32, @intCast(pixel_height)) * 64, 72, 72);

        slot.metrics = measureFace(face);
        slot.face = face;
        slot.loaded = true;

        if (self.graphics.configuration().debug_mode) {
            log.debug(
                "Loaded font slot {d}: {s} ({d}px, {d}x{d} cell)",
                .{ slot_index, path, pixel_height, slot.metrics.cell_width, slot.metrics.cell_height },
            );
        }
    }

    pub fn loadFontSlot(
        self: *Fonts,
        slot_index: u8,
        path: [:0]const u8,
        pixel_height: u32,
        atlas_width: u32,
        atlas_height: u32,
        preload_ascii: bool,
    ) bool {
        if (!self.state.initialized) {
            return false;
        }

        const slot = self.getSlotMut(slot_index) catch {
            if (self.graphics.configuration().debug_mode) {
                log.debug("Text loadFontSlot failed: invalid slot {d}", .{slot_index});
            }
            return false;
        };

        self.destroyAtlas(slot);
        self.clearGlyphCache(slot);

        self.loadMonospaceFaceSlot(slot_index, path, pixel_height) catch |err| {
            if (self.graphics.configuration().debug_mode) {
                log.debug("Text loadFontSlot failed for slot {d}: {s}", .{ slot_index, @errorName(err) });
            }
            return false;
        };

        if (!self.initAtlas(slot, atlas_width, atlas_height)) {
            return false;
        }

        if (preload_ascii) {
            self.preloadAsciiSlot(slot_index);
        }

        return true;
    }

    pub fn loadFont(
        self: *Fonts,
        path: [:0]const u8,
        pixel_height: u32,
        atlas_width: u32,
        atlas_height: u32,
        preload_ascii: bool,
    ) bool {
        return self.loadFontSlot(default_font_slot, path, pixel_height, atlas_width, atlas_height, preload_ascii);
    }

    pub fn drawGlyphSlot(
        self: *Fonts,
        slot_index: u8,
        codepoint: u32,
        x: i32,
        y: i32,
        priority: i32,
        r: u8,
        g: u8,
        b: u8,
        a: u8,
        layer_id: u8,
    ) bool {
        const slot = self.getSlot(slot_index) orelse return false;
        if (slot.face == null or slot.atlas_texture_id == 0) return false;

        const glyph = self.ensureGlyph(slot_index, codepoint) orelse return false;
        return self.submitGlyph(slot, glyph, x, y, priority, r, g, b, a, layer_id);
    }

    pub fn drawGlyph(
        self: *Fonts,
        codepoint: u32,
        x: i32,
        y: i32,
        priority: i32,
        r: u8,
        g: u8,
        b: u8,
        a: u8,
        layer_id: u8,
    ) bool {
        return self.drawGlyphSlot(default_font_slot, codepoint, x, y, priority, r, g, b, a, layer_id);
    }

    pub fn drawTextSlot(
        self: *Fonts,
        slot_index: u8,
        text_bytes: []const u8,
        x: i32,
        y: i32,
        priority: i32,
        r: u8,
        g: u8,
        b: u8,
        a: u8,
        layer_id: u8,
    ) bool {
        const slot = self.getSlot(slot_index) orelse return false;
        if (slot.face == null or slot.atlas_texture_id == 0) return false;

        var current_x = x;
        var current_y = y;
        var index: usize = 0;
        var all_succeeded = true;

        while (decodeNextCodepoint(text_bytes, &index)) |codepoint| {
            switch (codepoint) {
                '\n' => {
                    current_x = x;
                    current_y += @intCast(slot.metrics.line_height);
                    continue;
                },
                '\r' => continue,
                '\t' => {
                    current_x += @as(i32, @intCast(slot.metrics.cell_width)) * 4;
                    continue;
                },
                else => {},
            }

            const glyph = self.ensureGlyph(slot_index, codepoint) orelse {
                all_succeeded = false;
                continue;
            };

            if (!self.submitGlyph(slot, glyph, current_x, current_y, priority, r, g, b, a, layer_id)) {
                all_succeeded = false;
            }

            current_x += glyph.advance_x;
        }

        return all_succeeded;
    }

    pub fn drawText(
        self: *Fonts,
        text_bytes: []const u8,
        x: i32,
        y: i32,
        priority: i32,
        r: u8,
        g: u8,
        b: u8,
        a: u8,
        layer_id: u8,
    ) bool {
        return self.drawTextSlot(default_font_slot, text_bytes, x, y, priority, r, g, b, a, layer_id);
    }

    fn submitGlyph(
        self: *Fonts,
        slot: *const FontSlotState,
        glyph: *const GlyphEntry,
        x: i32,
        y: i32,
        priority: i32,
        r: u8,
        g: u8,
        b: u8,
        a: u8,
        layer_id: u8,
    ) bool {
        if (glyph.width == 0 or glyph.height == 0) return true;

        const dst_x = x + glyph.bearing_x;
        const dst_y = y + slot.metrics.ascender - glyph.bearing_y;

        self.graphics.addTexturedQuadTinted(
            slot.atlas_texture_id,
            layer_id,
            @intCast(priority),
            @intCast(glyph.atlas_x),
            @intCast(glyph.atlas_y),
            @intCast(glyph.width),
            @intCast(glyph.height),
            dst_x,
            dst_y,
            @intCast(glyph.width),
            @intCast(glyph.height),
            false,
            false,
            0,
            0,
            0.0,
            r,
            g,
            b,
            a,
        ) catch |err| {
            if (self.graphics.configuration().debug_mode) {
                log.debug("Failed to submit glyph draw: {s}", .{@errorName(err)});
            }
            return false;
        };
        return true;
    }

    pub fn hasFace(self: *Fonts) bool {
        return self.hasFaceSlot(default_font_slot);
    }

    pub fn hasFaceSlot(
        self: *Fonts,
        slot_index: u8,
    ) bool {
        const slot = self.getSlot(slot_index) orelse return false;
        return slot.face != null;
    }

    pub fn getMetrics(self: *Fonts) ?FontMetrics {
        return self.getMetricsSlot(default_font_slot);
    }

    pub fn getMetricsSlot(
        self: *Fonts,
        slot_index: u8,
    ) ?FontMetrics {
        const slot = self.getSlot(slot_index) orelse return null;
        if (slot.face == null) return null;
        return slot.metrics;
    }

    pub fn measureText(
        self: *Fonts,
        text_bytes: []const u8,
    ) i32 {
        return self.measureTextSlot(default_font_slot, text_bytes);
    }

    pub fn measureTextSlot(
        self: *Fonts,
        slot_index: u8,
        text_bytes: []const u8,
    ) i32 {
        const slot = self.getSlot(slot_index) orelse return 0;
        if (slot.face == null or slot.atlas_texture_id == 0) return 0;

        var width: i32 = 0;
        var index: usize = 0;

        while (decodeNextCodepoint(text_bytes, &index)) |codepoint| {
            switch (codepoint) {
                '\n', '\r' => break,
                '\t' => {
                    width += @as(i32, @intCast(slot.metrics.cell_width)) * 4;
                    continue;
                },
                else => {},
            }

            const glyph = self.ensureGlyph(slot_index, codepoint) orelse continue;
            width += glyph.advance_x;
        }

        return width;
    }

    pub fn preloadAscii(self: *Fonts) void {
        self.preloadAsciiSlot(default_font_slot);
    }

    pub fn preloadAsciiSlot(
        self: *Fonts,
        slot_index: u8,
    ) void {
        var codepoint: u32 = 32;
        while (codepoint <= 126) : (codepoint += 1) {
            _ = self.ensureGlyph(slot_index, codepoint);
        }
    }

    fn initAtlas(
        self: *Fonts,
        slot: *FontSlotState,
        width: u32,
        height: u32,
    ) bool {
        if (width == 0 or height == 0) return false;

        self.destroyAtlas(slot);

        const atlas_texture_id = self.graphics.createDynamicTexture(
            @intCast(width),
            @intCast(height),
        ) catch |err| {
            if (self.graphics.configuration().debug_mode) {
                log.debug("Failed to create text atlas: {s}", .{@errorName(err)});
            }
            return false;
        };

        slot.atlas_texture_id = atlas_texture_id;
        slot.atlas_width = width;
        slot.atlas_height = height;
        slot.atlas_next_x = 0;
        slot.atlas_next_y = 0;
        slot.atlas_row_height = 0;
        return true;
    }

    fn destroyAtlas(
        self: *Fonts,
        slot: *FontSlotState,
    ) void {
        if (slot.atlas_texture_id != 0) {
            self.graphics.destroyDynamicTexture(slot.atlas_texture_id) catch {};
        }

        slot.atlas_texture_id = 0;
        slot.atlas_width = 0;
        slot.atlas_height = 0;
        slot.atlas_next_x = 0;
        slot.atlas_next_y = 0;
        slot.atlas_row_height = 0;
    }

    fn clearGlyphCache(
        self: *Fonts,
        slot: *FontSlotState,
    ) void {
        _ = self;
        if (slot.cache_initialized) {
            slot.glyph_cache.clearRetainingCapacity();
        }
    }

    fn ensureGlyph(
        self: *Fonts,
        slot_index: u8,
        codepoint: u32,
    ) ?*const GlyphEntry {
        const slot = self.getSlotMut(slot_index) catch return null;
        if (!self.state.initialized or slot.face == null or slot.atlas_texture_id == 0 or !slot.cache_initialized) {
            return null;
        }

        if (slot.glyph_cache.getPtr(codepoint)) |entry| {
            return entry;
        }

        if (slot.glyph_cache.count() >= max_glyph_cache_entries) {
            if (self.graphics.configuration().debug_mode) {
                log.debug("Glyph cache full in slot {d}; cannot cache codepoint {d}", .{ slot_index, codepoint });
            }
            return null;
        }

        const face = slot.face.?;
        const glyph_index = face.getCharIndex(codepoint) orelse {
            if (self.graphics.configuration().debug_mode) {
                log.debug("Glyph missing for codepoint {d} in slot {d}", .{ codepoint, slot_index });
            }
            return null;
        };

        face.loadGlyph(glyph_index, .{ .render = true }) catch |err| {
            if (self.graphics.configuration().debug_mode) {
                log.debug(
                    "Failed to load glyph {d} in slot {d}: {s}",
                    .{ codepoint, slot_index, @errorName(err) },
                );
            }
            return null;
        };

        const glyph_slot = face.handle.*.glyph;
        const bitmap = glyph_slot.*.bitmap;
        const glyph_width: u32 = @intCast(bitmap.width);
        const glyph_height: u32 = @intCast(bitmap.rows);

        var atlas_x: u32 = slot.atlas_next_x;
        var atlas_y: u32 = slot.atlas_next_y;

        if (glyph_width > 0 and glyph_height > 0) {
            if (atlas_x + glyph_width > slot.atlas_width) {
                atlas_x = 0;
                atlas_y = slot.atlas_next_y + slot.atlas_row_height;
                slot.atlas_next_x = 0;
                slot.atlas_next_y = atlas_y;
                slot.atlas_row_height = 0;
            }

            if (glyph_width > slot.atlas_width or atlas_y + glyph_height > slot.atlas_height) {
                if (self.graphics.configuration().debug_mode) {
                    log.debug("Text atlas full in slot {d}; cannot place codepoint {d}", .{ slot_index, codepoint });
                }
                return null;
            }

            const rgba = convertGlyphBitmapToRgba(self.state.allocator, bitmap) orelse return null;
            defer self.state.allocator.free(rgba);

            self.graphics.updateDynamicTexture(
                slot.atlas_texture_id,
                @intCast(atlas_x),
                @intCast(atlas_y),
                @intCast(glyph_width),
                @intCast(glyph_height),
                rgba,
                @intCast(glyph_width * 4),
            ) catch |err| {
                if (self.graphics.configuration().debug_mode) {
                    log.debug("Failed to upload glyph {d} to text atlas in slot {d}: {s}", .{ codepoint, slot_index, @errorName(err) });
                }
                return null;
            };

            slot.atlas_next_x = atlas_x + glyph_width + glyph_padding;
            slot.atlas_row_height = @max(slot.atlas_row_height, glyph_height + glyph_padding);
        }

        const entry = GlyphEntry{
            .atlas_x = atlas_x,
            .atlas_y = atlas_y,
            .width = glyph_width,
            .height = glyph_height,
            .bearing_x = glyph_slot.*.bitmap_left,
            .bearing_y = glyph_slot.*.bitmap_top,
            .advance_x = from26Dot6(glyph_slot.*.advance.x),
        };

        slot.glyph_cache.put(codepoint, entry) catch {
            if (self.graphics.configuration().debug_mode) {
                log.debug("Failed to store glyph {d} in cache for slot {d}", .{ codepoint, slot_index });
            }
            return null;
        };

        if (self.graphics.configuration().debug_mode) {
            log.debug("Cached glyph {d} in slot {d} at atlas ({d}, {d})", .{ codepoint, slot_index, atlas_x, atlas_y });
        }

        return slot.glyph_cache.getPtr(codepoint);
    }

    fn convertGlyphBitmapToRgba(
        alloc: std.mem.Allocator,
        bitmap: anytype,
    ) ?[]u8 {
        const glyph_width: usize = @intCast(bitmap.width);
        const glyph_height: usize = @intCast(bitmap.rows);
        if (glyph_width == 0 or glyph_height == 0) {
            return alloc.alloc(u8, 0) catch null;
        }

        const buffer = bitmap.buffer orelse return null;
        const pitch_abs_i32: i32 = if (bitmap.pitch < 0) -bitmap.pitch else bitmap.pitch;
        const pitch_abs: usize = @intCast(pitch_abs_i32);
        const source = @as([*]const u8, @ptrCast(buffer))[0 .. pitch_abs * glyph_height];

        const rgba = alloc.alloc(u8, glyph_width * glyph_height * 4) catch return null;

        for (0..glyph_height) |row| {
            const src_row_index = if (bitmap.pitch >= 0)
                row * pitch_abs
            else
                (glyph_height - 1 - row) * pitch_abs;
            for (0..glyph_width) |column| {
                const alpha = source[src_row_index + column];
                const dst_index = (row * glyph_width + column) * 4;
                rgba[dst_index + 0] = 255;
                rgba[dst_index + 1] = 255;
                rgba[dst_index + 2] = 255;
                rgba[dst_index + 3] = alpha;
            }
        }

        return rgba;
    }

    fn decodeNextCodepoint(
        bytes: []const u8,
        index: *usize,
    ) ?u32 {
        if (index.* >= bytes.len) return null;

        const first = bytes[index.*];
        if (first < 0x80) {
            index.* += 1;
            return first;
        }

        const replacement: u32 = '?';
        const expected_len: usize = blk: {
            if ((first & 0xE0) == 0xC0) break :blk 2;
            if ((first & 0xF0) == 0xE0) break :blk 3;
            if ((first & 0xF8) == 0xF0) break :blk 4;
            index.* += 1;
            return replacement;
        };

        if (index.* + expected_len > bytes.len) {
            index.* = bytes.len;
            return replacement;
        }

        var codepoint: u32 = switch (expected_len) {
            2 => first & 0x1F,
            3 => first & 0x0F,
            4 => first & 0x07,
            else => unreachable,
        };

        var offset: usize = 1;
        while (offset < expected_len) : (offset += 1) {
            const continuation = bytes[index.* + offset];
            if ((continuation & 0xC0) != 0x80) {
                index.* += offset;
                return replacement;
            }
            codepoint = (codepoint << 6) | (continuation & 0x3F);
        }

        const min_codepoint: u32 = switch (expected_len) {
            2 => 0x80,
            3 => 0x800,
            4 => 0x10000,
            else => unreachable,
        };

        index.* += expected_len;

        if (codepoint < min_codepoint or codepoint > 0x10FFFF) return replacement;
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return replacement;
        return codepoint;
    }

    fn unloadFace(
        slot: *FontSlotState,
    ) void {
        if (slot.face) |face| {
            face.deinit();
            slot.face = null;
        }
    }

    fn from26Dot6(value: anytype) i32 {
        return @intCast(@divTrunc(value, 64));
    }

    fn measureFace(face: freetype.Face) FontMetrics {
        const size_metrics = face.handle.*.size.*.metrics;

        const cell_width = @max(from26Dot6(size_metrics.max_advance), 0);
        const ascender = from26Dot6(size_metrics.ascender);
        const descender = from26Dot6(size_metrics.descender);
        const line_height = @max(from26Dot6(size_metrics.height), 0);

        return .{
            .cell_width = @intCast(cell_width),
            .cell_height = @intCast(line_height),
            .ascender = ascender,
            .descender = descender,
            .line_height = @intCast(line_height),
        };
    }

    fn getSlot(
        self: *Fonts,
        slot_index: u8,
    ) ?*const FontSlotState {
        if (!self.state.initialized) return null;
        if (slot_index >= max_fonts) return null;
        return &self.state.slots[slot_index];
    }

    fn getSlotMut(
        self: *Fonts,
        slot_index: u8,
    ) TextError!*FontSlotState {
        if (!self.state.initialized) return error.NotInitialized;
        if (slot_index >= max_fonts) return error.InvalidFontSlot;
        return &self.state.slots[slot_index];
    }
};
