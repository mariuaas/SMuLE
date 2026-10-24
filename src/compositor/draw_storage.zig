const std = @import("std");
const t = @import("types.zig");
const sdl = @import("sdl").sdl;

pub const page_size = 64;
pub const owner_count = t.max_layers + 1;
pub const immediate_owner = t.max_layers;
pub const texture_words = (t.max_texture_ids + 63) / 64;
pub const none = std.math.maxInt(u32);

/// ceiling limits admitted draws; reserved supplies backing without hot-path
/// allocation; payloads reserves rich primitive metadata within that backing.
pub const Config = struct {
    ceiling: u32,
    reserved: u32,
    payloads: u32 = 0,
};

pub const Payload = union(enum) {
    none,
    sprite: t.Affine,
    triangle: [3]t.TriangleVertex,
    line: t.Line,
};

pub const Handle = struct {
    generation: u64,
    index: u32,
};

pub const Page = struct {
    generation: u64 = 0,
    next: u32 = none,
    owner: u8 = 255,
    used: u8 = 0,
};

pub const CommandPage = struct { commands: [page_size]t.DrawInstruction };
pub const Run = t.TextureRun;
pub const CachePage = struct {
    vertices: [page_size * 4]sdl.SDL_Vertex align(t.geometry_buffer_alignment),
    indices: [page_size * 6]u32 align(t.geometry_buffer_alignment),
    runs: [page_size]Run,
};
pub const SortRef = t.SortedDrawRef;
pub const Composition = t.CompositeEntry;

pub const Backing = struct {
    commands: []CommandPage = &.{},
    command_pages: []Page = &.{},
    cache: []CachePage = &.{},
    cache_pages: []Page = &.{},
    payload_handles: []u32 = &.{},
    source_handles: []u32 = &.{},
    payloads: []Payload = &.{},
    payload_free: []u32 = &.{},
    staged_commands: []t.DrawInstruction = &.{},
    staged_payloads: []Payload = &.{},
    vertices: []align(t.geometry_buffer_alignment) sdl.SDL_Vertex = &.{},
    indices: []align(t.geometry_buffer_alignment) u32 = &.{},
    sort_refs: []SortRef = &.{},
    runs: []Run = &.{},
    composition: []Composition = &.{},

    fn deinit(
        self: *Backing,
        allocator: std.mem.Allocator,
    ) void {
        inline for (@typeInfo(Backing).@"struct".fields) |field| allocator.free(@field(self, field.name));
        self.* = .{};
    }

    pub fn bytes(self: Backing) usize {
        var total: usize = 0;
        inline for (@typeInfo(Backing).@"struct".fields) |field| {
            total += @field(self, field.name).len * @sizeOf(std.meta.Elem(field.type));
        }
        return total;
    }
};

pub const Owner = struct {
    first: u32 = none,
    last: u32 = none,
    count: u32 = 0,
    payloads: u32 = 0,
    cache_first: u32 = none,
    cache_last: u32 = none,
    cache_count: u32 = 0,
};

/// Allocator-owned paged backing. Growth preserves live commands; handles are
/// generation-checked. A replacement transaction stages before committing.
pub const Storage = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    config: Config = .{ .ceiling = 0, .reserved = 0 },
    backing: Backing = .{},
    owners: [owner_count]Owner = @splat(.{}),
    texture_owners: [t.max_texture_ids]t.OwnerMask = @splat(0),
    owner_textures: [owner_count][texture_words]u64 = @splat(@splat(0)),
    count: u32 = 0,
    payload_count: u32 = 0,
    command_free: u32 = none,
    cache_free: u32 = none,
    payload_free: u32 = none,
    generation: u64 = 0,
    transaction: ?u8 = null,
    staged_count: u32 = 0,
    staged_payload_count: u32 = 0,
    validated: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
    ) !Storage {
        var result: Storage = .{ .allocator = allocator };
        try result.reserve(config);
        return result;
    }

    pub fn deinit(self: *Storage) void {
        self.backing.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator, .generation = self.generation };
    }

    pub fn reservationBytes(config: Config) !usize {
        const sizes = try lengths(config);
        var total: usize = 0;
        inline for (@typeInfo(Backing).@"struct".fields) |field| {
            total = try std.math.add(
                usize,
                total,
                try std.math.mul(
                    usize,
                    @field(sizes, field.name),
                    @sizeOf(std.meta.Elem(field.type)),
                ),
            );
        }
        return total;
    }

    const Lengths = blk: {
        const fields = @typeInfo(Backing).@"struct".fields;
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        for (fields, 0..) |field, index| {
            names[index] = field.name;
            types[index] = usize;
        }
        break :blk @Struct(.auto, null, &names, &types, &@splat(.{}));
    };

    fn lengths(config: Config) !Lengths {
        if (config.reserved > config.ceiling or config.payloads > config.reserved)
            return error.InvalidCapacity;
        const reserved: usize = config.reserved;
        const pages = if (reserved == 0)
            0
        else
            try std.math.add(
                usize,
                (try std.math.add(
                    usize,
                    reserved,
                    page_size - 1,
                )) / page_size,
                owner_count - 1,
            );
        const slots = try std.math.mul(usize, pages, page_size);
        if (slots > none)
            return error.InvalidCapacity;
        const rich = config.payloads != 0;
        return .{
            .commands = pages,
            .command_pages = pages,
            .cache = pages,
            .cache_pages = pages,
            .payload_handles = if (rich) slots else 0,
            .source_handles = if (rich) slots else 0,
            .payloads = config.payloads,
            .payload_free = config.payloads,
            .staged_commands = reserved,
            .staged_payloads = if (rich) reserved else 0,
            .vertices = try std.math.mul(usize, reserved, 4),
            .indices = try std.math.mul(usize, reserved, 6),
            .sort_refs = reserved,
            .runs = reserved,
            .composition = try std.math.add(
                usize,
                reserved,
                if (reserved == 0) 0 else t.max_layers,
            ),
        };
    }

    pub fn reserve(
        self: *Storage,
        config: Config,
    ) !void {
        if (self.transaction != null)
            return error.TransactionActive;
        if (config.ceiling < self.config.ceiling or
            config.reserved < self.config.reserved or
            config.payloads < self.config.payloads)
            return error.InvalidCapacity;
        const sizes = try lengths(config);
        _ = try reservationBytes(config);
        if (config.reserved == self.config.reserved and config.payloads == self.config.payloads) {
            self.config = config;
            return;
        }
        var replacement: Backing = .{};
        errdefer replacement.deinit(self.allocator);
        inline for (@typeInfo(Backing).@"struct".fields) |field| {
            const Element = std.meta.Elem(field.type);
            const alignment = @typeInfo(field.type).pointer.alignment orelse @alignOf(Element);
            const destination = try self.allocator.alignedAlloc(
                Element,
                .fromByteUnits(alignment),
                @field(sizes, field.name),
            );
            @field(replacement, field.name) = destination;
            const source = @field(self.backing, field.name);
            @memcpy(destination[0..source.len], source);
        }
        const old_pages = self.backing.command_pages.len;
        for (old_pages..replacement.command_pages.len) |index| {
            const next: u32 = if (index + 1 < replacement.command_pages.len)
                @intCast(index + 1)
            else
                self.command_free;
            replacement.command_pages[index] = .{ .next = next };
            replacement.cache_pages[index] = .{
                .next = if (index + 1 < replacement.cache_pages.len)
                    @intCast(index + 1)
                else
                    self.cache_free,
            };
        }
        if (self.backing.payload_handles.len == 0) @memset(
            replacement.payload_handles,
            none,
        ) else @memset(
            replacement.payload_handles[self.backing.payload_handles.len..],
            none,
        );
        @memset(
            replacement.source_handles[self.backing.source_handles.len..],
            none,
        );
        const old_payloads = self.backing.payloads.len;
        for (old_payloads..replacement.payloads.len) |index| {
            replacement.payload_free[index] = if (index + 1 < replacement.payloads.len)
                @intCast(index + 1)
            else
                self.payload_free;
        }
        self.backing.deinit(self.allocator);
        self.backing = replacement;
        if (old_pages < replacement.command_pages.len) {
            self.command_free = @intCast(old_pages);
            self.cache_free = @intCast(old_pages);
        }
        if (old_payloads < replacement.payloads.len) self.payload_free = @intCast(old_payloads);
        self.config = config;
    }

    fn checkOwner(owner: u8) !void {
        if (owner >= owner_count) return error.InvalidOwner;
    }

    fn checkGeneration(
        self: *Storage,
        pages: usize,
    ) !void {
        if (pages > std.math.maxInt(u64) - self.generation)
            return error.GenerationExhausted;
    }

    fn acquire(
        self: *Storage,
        descriptors: []Page,
        free: *u32,
        owner: u8,
    ) u32 {
        const index = free.*;
        std.debug.assert(index != none);
        free.* = descriptors[index].next;
        self.generation += 1;
        descriptors[index] = .{
            .owner = owner,
            .generation = self.generation,
        };
        return index;
    }

    pub fn append(
        self: *Storage,
        owner: u8,
        command: t.DrawInstruction,
        payload: Payload,
    ) !Handle {
        try checkOwner(owner);
        if (self.transaction != null)
            return error.TransactionActive;
        if (self.count == self.config.ceiling)
            return error.CapacityExceeded;
        if (self.count == self.config.reserved)
            return error.ReservationExceeded;
        if (payload != .none and self.payload_count == self.config.payloads)
            return error.PayloadCapacityExceeded;
        try self.checkGeneration(1);
        return self.appendAssumeCapacity(owner, command, payload);
    }

    fn appendAssumeCapacity(
        self: *Storage,
        owner: u8,
        command: t.DrawInstruction,
        payload: Payload,
    ) Handle {
        const stream = &self.owners[owner];
        if (stream.last == none or self.backing.command_pages[stream.last].used == page_size) {
            const page = self.acquire(self.backing.command_pages, &self.command_free, owner);
            if (stream.last == none) stream.first = page else self.backing.command_pages[stream.last].next = page;
            stream.last = page;
        }
        const page = &self.backing.command_pages[stream.last];
        const slot = stream.last * page_size + page.used;
        self.backing.commands[stream.last].commands[page.used] = command;
        if (self.backing.payload_handles.len != 0) self.backing.payload_handles[slot] = none;
        if (payload != .none) {
            const index = self.payload_free;
            self.payload_free = self.backing.payload_free[index];
            self.backing.payloads[index] = payload;
            self.backing.payload_handles[slot] = index;
            self.payload_count += 1;
            stream.payloads += 1;
        }
        page.used += 1;
        stream.count += 1;
        self.count += 1;
        const texture_id: u16 = @truncate(command.sort_key >> 32);
        if (texture_id != 0 and texture_id < t.max_texture_ids) {
            const word = &self.owner_textures[owner][texture_id / 64];
            const bit = @as(u64, 1) << @as(u6, @truncate(texture_id));
            if (word.* & bit == 0) {
                word.* |= bit;
                self.texture_owners[texture_id] |= t.ownerBit(owner);
            }
        }
        return .{ .index = slot, .generation = page.generation };
    }

    pub const Entry = struct {
        command: *const t.DrawInstruction,
        payload: ?*const Payload,
        handle: Handle,
        owner: u8,
    };

    pub fn get(
        self: *const Storage,
        handle: Handle,
    ) ?Entry {
        const index = handle.index / page_size;
        const offset = handle.index % page_size;
        if (index >= self.backing.command_pages.len)
            return null;
        const page = self.backing.command_pages[index];
        if (page.generation != handle.generation or page.owner == 255 or offset >= page.used) return null;
        const payload = if (self.backing.payload_handles.len != 0) self.backing.payload_handles[handle.index] else none;
        return .{
            .command = &self.backing.commands[index].commands[offset],
            .payload = if (payload == none) null else &self.backing.payloads[payload],
            .handle = handle,
            .owner = page.owner,
        };
    }

    pub const Iterator = struct {
        storage: *const Storage,
        page: u32,
        offset: u32 = 0,

        pub fn nextRef(self: *Iterator) ?SortRef {
            if (self.page == none) return null;
            const descriptor = self.storage.backing.command_pages[self.page];
            if (self.offset >= descriptor.used) return null;
            const reference: SortRef = .{
                .key = self.storage.backing.commands[self.page].commands[self.offset].sort_key,
                .index = self.page * page_size + self.offset,
            };
            self.offset += 1;
            if (self.offset == descriptor.used) {
                self.page = descriptor.next;
                self.offset = 0;
            }
            return reference;
        }

        pub fn next(self: *Iterator) ?Entry {
            if (self.page == none) return null;
            const page = self.storage.backing.command_pages[self.page];
            const handle: Handle = .{
                .index = self.page * page_size + self.offset,
                .generation = page.generation,
            };
            self.offset += 1;
            if (self.offset == page.used) {
                self.page = page.next;
                self.offset = 0;
            }
            return self.storage.get(handle);
        }
    };

    pub fn iterator(
        self: *const Storage,
        owner: u8,
    ) !Iterator {
        try checkOwner(owner);
        return .{ .storage = self, .page = self.owners[owner].first };
    }

    pub fn ensureCache(
        self: *Storage,
        owner: u8,
    ) !void {
        try checkOwner(owner);
        if (self.transaction != null) return error.TransactionActive;
        const stream = &self.owners[owner];
        const needed = (stream.count + page_size - 1) / page_size;
        try self.checkGeneration(needed - stream.cache_count);
        while (stream.cache_count < needed) {
            const page = self.acquire(self.backing.cache_pages, &self.cache_free, owner);
            if (stream.cache_last == none)
                stream.cache_first = page
            else
                self.backing.cache_pages[stream.cache_last].next = page;
            stream.cache_last = page;
            stream.cache_count += 1;
        }
    }

    pub fn clear(
        self: *Storage,
        owner: u8,
    ) !void {
        try checkOwner(owner);
        if (self.transaction != null) return error.TransactionActive;
        self.clearOwner(owner);
    }

    fn clearOwner(
        self: *Storage,
        owner: u8,
    ) void {
        const stream = self.owners[owner];
        if (stream.count != 0) {
            const owner_bit = t.ownerBit(owner);
            for (&self.owner_textures[owner], 0..) |*word, word_index| {
                var remaining = word.*;
                while (remaining != 0) {
                    const texture_id = word_index * 64 + @ctz(remaining);
                    self.texture_owners[texture_id] &= ~owner_bit;
                    remaining &= remaining - 1;
                }
                word.* = 0;
            }
        }
        var page = stream.first;
        while (page != none) {
            const descriptor = &self.backing.command_pages[page];
            const next = descriptor.next;
            for (0..descriptor.used) |offset| {
                if (self.backing.payload_handles.len != 0) {
                    const index = self.backing.payload_handles[page * page_size + offset];
                    if (index != none) {
                        self.backing.payload_free[index] = self.payload_free;
                        self.payload_free = index;
                    }
                }
            }
            descriptor.* = .{ .next = self.command_free };
            self.command_free = page;
            page = next;
        }
        page = stream.cache_first;
        while (page != none) {
            const next = self.backing.cache_pages[page].next;
            self.backing.cache_pages[page] = .{ .next = self.cache_free };
            self.cache_free = page;
            page = next;
        }
        self.count -= stream.count;
        self.payload_count -= stream.payloads;
        self.owners[owner] = .{};
    }

    pub fn beginReplacement(
        self: *Storage,
        owner: u8,
    ) !void {
        try checkOwner(owner);
        if (self.transaction != null)
            return error.TransactionActive;
        self.transaction = owner;
        self.staged_count = 0;
        self.staged_payload_count = 0;
        self.validated = false;
    }

    pub fn stage(
        self: *Storage,
        command: t.DrawInstruction,
        payload: Payload,
    ) !void {
        if (self.transaction == null)
            return error.NoTransaction;
        self.validated = false;
        if (self.staged_count == self.config.reserved)
            return error.ReservationExceeded;
        if (payload != .none and self.staged_payload_count == self.config.payloads)
            return error.PayloadCapacityExceeded;
        self.backing.staged_commands[self.staged_count] = command;
        if (self.backing.staged_payloads.len != 0)
            self.backing.staged_payloads[self.staged_count] = payload;
        self.staged_count += 1;
        self.staged_payload_count += @intFromBool(payload != .none);
    }

    pub fn validateReplacement(self: *Storage) !void {
        self.validated = false;
        const owner = self.transaction orelse return error.NoTransaction;
        const remaining = self.count - self.owners[owner].count;
        if (self.staged_count > self.config.ceiling - remaining)
            return error.CapacityExceeded;
        if (self.staged_count > self.config.reserved - remaining)
            return error.ReservationExceeded;
        if (self.staged_payload_count > self.config.payloads - (self.payload_count - self.owners[owner].payloads))
            return error.PayloadCapacityExceeded;
        try self.checkGeneration((@as(usize, self.staged_count) + page_size - 1) / page_size);
        self.validated = true;
    }

    pub fn commitReplacement(self: *Storage) void {
        std.debug.assert(self.validated);
        const owner = self.transaction.?;
        self.clearOwner(owner);
        for (0..self.staged_count) |index| {
            _ = self.appendAssumeCapacity(
                owner,
                self.backing.staged_commands[index],
                if (self.backing.staged_payloads.len != 0)
                    self.backing.staged_payloads[index]
                else
                    .none,
            );
        }
        self.abortReplacement();
    }

    pub fn abortReplacement(self: *Storage) void {
        self.transaction = null;
        self.staged_count = 0;
        self.staged_payload_count = 0;
        self.validated = false;
    }
};
