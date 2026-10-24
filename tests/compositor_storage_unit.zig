const std = @import("std");
const rendering = @import("compositor");
const storage = rendering.draw_storage;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn command(sequence: u64) rendering.types.DrawInstruction {
    var result = std.mem.zeroes(rendering.types.DrawInstruction);
    result.sort_key = sequence;
    return result;
}

fn checkDependencies(pool: *const storage.Storage) !void {
    var expected: [rendering.types.max_texture_ids]rendering.types.OwnerMask = @splat(0);
    for (0..storage.owner_count) |owner| {
        var textures: [storage.texture_words]u64 = @splat(0);
        var iterator = try pool.iterator(@intCast(owner));
        while (iterator.nextRef()) |reference| {
            const texture_id = rendering.geometry.unpackTextureId(reference.key);
            if (texture_id == 0 or texture_id >= expected.len) continue;
            expected[texture_id] |= rendering.types.ownerBit(owner);
            textures[texture_id / 64] |= @as(u64, 1) << @as(u6, @truncate(texture_id));
        }
        try std.testing.expectEqualSlices(u64, &textures, &pool.owner_textures[owner]);
    }
    try std.testing.expectEqualSlices(rendering.types.OwnerMask, &expected, &pool.texture_owners);
}

test "duplicate dependencies survive rejected admission staging and replacement validation" {
    var pool = try storage.Storage.init(std.testing.allocator, .{ .ceiling = 3, .reserved = 3 });
    defer pool.deinit();
    var draw = command(0);
    draw.sort_key = rendering.geometry.packKey(0, 7, 0, true);
    _ = try pool.append(31, draw, .none);
    _ = try pool.append(31, draw, .none);
    _ = try pool.append(storage.immediate_owner, draw, .none);
    try checkDependencies(&pool);
    try equal(rendering.types.ownerBit(31) | rendering.types.immediate_owner_bit, pool.texture_owners[7]);
    draw.sort_key = rendering.geometry.packKey(0, 9, 0, true);
    try std.testing.expectError(error.CapacityExceeded, pool.append(0, draw, .none));
    try pool.beginReplacement(31);
    try std.testing.expectError(error.PayloadCapacityExceeded, pool.stage(draw, .{ .sprite = .{} }));
    for (0..3) |_| try pool.stage(draw, .none);
    try std.testing.expectError(error.ReservationExceeded, pool.stage(draw, .none));
    try std.testing.expectError(error.CapacityExceeded, pool.validateReplacement());
    try checkDependencies(&pool);
    pool.abortReplacement();
    try checkDependencies(&pool);
    try pool.clear(31);
    try equal(rendering.types.immediate_owner_bit, pool.texture_owners[7]);
    try equal(@as(rendering.types.OwnerMask, 0), pool.texture_owners[9]);
    try pool.clear(storage.immediate_owner);
    try checkDependencies(&pool);
}

test "dependency indexes match admitted command scans through failures transactions and growth" {
    var pool = try storage.Storage.init(std.testing.allocator, .{ .ceiling = 256, .reserved = 256 });
    defer pool.deinit();
    var random = std.Random.DefaultPrng.init(0x5a17);
    const generator = random.random();
    for (0..1000) |_| {
        const owner = generator.uintLessThan(u8, storage.owner_count);
        switch (generator.uintLessThan(u8, 4)) {
            0, 1 => {
                const texture_id = generator.uintLessThan(u16, 70);
                var draw = command(0);
                draw.sort_key = rendering.geometry.packKey(0, texture_id, pool.owners[owner].count, true);
                _ = pool.append(owner, draw, .none) catch |err| switch (err) {
                    error.CapacityExceeded => {
                        try checkDependencies(&pool);
                        continue;
                    },
                    else => return err,
                };
            },
            2 => try pool.clear(owner),
            3 => {
                try pool.beginReplacement(owner);
                const staged = generator.uintLessThan(u8, 20);
                for (0..staged) |index| {
                    var draw = command(0);
                    draw.sort_key = rendering.geometry.packKey(0, 1 + @as(u16, @intCast(index % 3)), index, true);
                    try pool.stage(draw, .none);
                }
                try checkDependencies(&pool);
                if (generator.boolean()) {
                    pool.validateReplacement() catch |err| switch (err) {
                        error.CapacityExceeded => {
                            pool.abortReplacement();
                            try checkDependencies(&pool);
                            continue;
                        },
                        else => return err,
                    };
                    pool.commitReplacement();
                } else pool.abortReplacement();
            },
            else => unreachable,
        }
        try checkDependencies(&pool);
    }
    try pool.reserve(.{ .ceiling = 512, .reserved = 512 });
    try checkDependencies(&pool);
    for (0..storage.owner_count) |owner| try pool.clear(@intCast(owner));
    try checkDependencies(&pool);
}

fn payload(index: usize) storage.Payload {
    return switch (index % 4) {
        0 => .none,
        1 => .{ .sprite = .{ .tx = @intCast(index) } },
        2 => .{ .triangle = @splat(.{ .x = @intCast(index), .y = -19 }) },
        else => .{ .line = .{ .layer_id = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 } },
    };
}

fn checkList(pool: *const storage.Storage, owner: u8, count: usize, first: u64) !void {
    var iterator = try pool.iterator(owner);
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) try equal(first + index, entry.command.sort_key);
    try equal(count, index);
}

fn checkGrowthContent(pool: *const storage.Storage, rich: bool) !void {
    var seen: [65]bool = @splat(false);
    for (0..33) |owner| {
        var iterator = try pool.iterator(@intCast(owner));
        while (iterator.next()) |entry| {
            const index = if (entry.command.sort_key == 123) 0 else entry.command.sort_key;
            try expect(index < seen.len);
            try expect(!seen[index]);
            seen[index] = true;
            try equal(@as(u8, @intCast(index % 33)), entry.owner);
            const expected = if (rich) payload(if (index == 0) 1 else index) else .none;
            if (entry.payload) |actual| try equal(expected, actual.*) else try expect(expected == .none);
        }
    }
    for (seen) |present| try expect(present);
}

test "concentrated, distributed and worst sparse owners use exact N with no allocation" {
    for ([_]u32{ 4096, 16384, 65536 }) |capacity| {
        for (0..3) |distribution| {
            var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var pool = try storage.Storage.init(allocator.allocator(), .{ .ceiling = capacity, .reserved = capacity, .payloads = capacity });
            defer pool.deinit();
            const calls = allocator.alloc_index;
            allocator.fail_index = calls;
            var first: ?storage.Handle = null;
            for (0..capacity) |index| {
                const owner: u8 = switch (distribution) {
                    0 => 0,
                    1 => @intCast(index % storage.owner_count),
                    else => if (index < storage.owner_count - 1) @intCast(index) else storage.immediate_owner,
                };
                const handle = try pool.append(owner, command(index), payload(index));
                if (first == null) first = handle;
            }
            for (0..storage.owner_count) |owner| try pool.ensureCache(@intCast(owner));
            try std.testing.expectError(error.CapacityExceeded, pool.append(0, command(0), .none));
            try equal(capacity, pool.count);
            try equal(@as(u64, 0), pool.get(first.?).?.command.sort_key);
            var seen: usize = 0;
            for (0..storage.owner_count) |owner| {
                var iterator = try pool.iterator(@intCast(owner));
                var references = try pool.iterator(@intCast(owner));
                while (iterator.next()) |entry| {
                    const reference = references.nextRef().?;
                    try equal(entry.handle.index, reference.index);
                    try equal(entry.command.sort_key, reference.key);
                    const index = entry.command.sort_key;
                    try equal(std.meta.activeTag(payload(index)), if (entry.payload) |raw| std.meta.activeTag(raw.*) else .none);
                    seen += 1;
                }
                try expect(references.nextRef() == null);
            }
            try equal(@as(usize, capacity), seen);
            for (0..storage.owner_count) |owner| try pool.clear(@intCast(owner));
            try equal(@as(u32, 0), pool.count);
            try expect(pool.get(first.?) == null);
            for (0..capacity) |index| _ = try pool.append(31, command(index), payload(index));
            try pool.ensureCache(31);
            try equal(calls, allocator.alloc_index);
            try equal(@as(usize, 0), allocator.deallocations);
            try expect(!allocator.has_induced_failure);
        }
    }
}

test "full replacement is staged, validated and committed without allocator calls" {
    for ([_]u32{ 4096, 16384, 65536 }) |capacity| {
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var pool = try storage.Storage.init(allocator.allocator(), .{ .ceiling = capacity, .reserved = capacity, .payloads = capacity });
        defer pool.deinit();
        const unrelated = try pool.append(32, command(900000), .{ .sprite = .{} });
        const old = try pool.append(0, command(0), payload(1));
        for (1..capacity - 1) |index| _ = try pool.append(0, command(index), payload(index));
        try pool.ensureCache(0);
        try pool.ensureCache(32);
        const unrelated_pointer = pool.get(unrelated).?.command;
        const calls = allocator.alloc_index;
        allocator.fail_index = calls;
        try pool.beginReplacement(0);
        try std.testing.expectError(error.TransactionActive, pool.beginReplacement(1));
        try std.testing.expectError(error.TransactionActive, pool.clear(32));
        try std.testing.expectError(error.TransactionActive, pool.append(2, command(0), .none));
        try std.testing.expectError(error.TransactionActive, pool.reserve(pool.config));
        for (0..capacity) |index| try pool.stage(command(100000 + index), payload(index));
        try std.testing.expectError(error.ReservationExceeded, pool.stage(command(0), .none));
        try std.testing.expectError(error.CapacityExceeded, pool.validateReplacement());
        try checkList(&pool, 0, capacity - 1, 0);
        try expect(pool.get(old) != null);
        pool.abortReplacement();
        try pool.beginReplacement(0);
        for (0..capacity - 1) |index| try pool.stage(command(100000 + index), payload(index));
        try pool.validateReplacement();
        pool.commitReplacement();
        try checkList(&pool, 0, capacity - 1, 100000);
        try expect(pool.get(old) == null);
        try equal(unrelated_pointer, pool.get(unrelated).?.command);
        try equal(@as(u64, 900000), pool.get(unrelated).?.command.sort_key);
        try equal(@as(u32, 0), pool.owners[0].cache_count);
        try equal(@as(u32, 1), pool.owners[32].cache_count);
        try pool.ensureCache(0);
        try equal(capacity, pool.count);
        try equal(calls, allocator.alloc_index);
        try expect(!allocator.has_induced_failure);
        try pool.beginReplacement(0);
        try pool.validateReplacement();
        pool.commitReplacement();
        try equal(@as(u32, 1), pool.count);
    }
}

test "ceiling, backing, payload exhaustion and invalid operations are distinct" {
    var pool = try storage.Storage.init(std.testing.allocator, .{ .ceiling = 10, .reserved = 2 });
    defer pool.deinit();
    try std.testing.expectError(error.InvalidOwner, pool.append(33, command(0), .none));
    try std.testing.expectError(error.PayloadCapacityExceeded, pool.append(0, command(0), payload(1)));
    const handle = try pool.append(0, command(1), .none);
    _ = try pool.append(1, command(2), .none);
    try std.testing.expectError(error.ReservationExceeded, pool.append(0, command(3), .none));
    try pool.reserve(.{ .ceiling = 10, .reserved = 4, .payloads = 1 });
    try equal(@as(u64, 1), pool.get(handle).?.command.sort_key);
    _ = try pool.append(2, command(3), payload(1));
    try std.testing.expectError(error.PayloadCapacityExceeded, pool.append(2, command(4), payload(2)));
    try pool.beginReplacement(1);
    try pool.stage(command(9), payload(1));
    try std.testing.expectError(error.PayloadCapacityExceeded, pool.validateReplacement());
    try checkList(&pool, 1, 1, 2);
    pool.abortReplacement();
    try pool.beginReplacement(2);
    try pool.stage(command(9), payload(2));
    try pool.validateReplacement();
    pool.commitReplacement();
    try pool.clear(0);
    _ = try pool.append(0, command(4), .none);
    try expect(pool.get(handle) == null);
    try std.testing.expectError(error.NoTransaction, pool.stage(command(0), .none));
    try std.testing.expectError(error.NoTransaction, pool.validateReplacement());
    try expect(pool.get(.{ .index = std.math.maxInt(u32), .generation = 1 }) == null);
    try expect(pool.get(.{ .index = handle.index, .generation = std.math.maxInt(u64) }) == null);
    try std.testing.expectError(error.InvalidCapacity, pool.reserve(.{ .ceiling = 3, .reserved = 4 }));
    try std.testing.expectError(error.InvalidCapacity, pool.reserve(.{ .ceiling = 10, .reserved = 4, .payloads = 5 }));
    try std.testing.expectError(error.InvalidCapacity, storage.Storage.reservationBytes(.{ .ceiling = std.math.maxInt(u32), .reserved = std.math.maxInt(u32) }));
}

test "reservation allocation failures clean up every point and growth preserves exact live backing" {
    for ([_]bool{ false, true }) |mixed| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            var pool = storage.Storage.init(allocator.allocator(), .{ .ceiling = 128, .reserved = 128, .payloads = if (mixed) 128 else 0 }) catch |err| {
                try equal(error.OutOfMemory, err);
                try equal(allocator.allocated_bytes, allocator.freed_bytes);
                continue;
            };
            pool.deinit();
            try equal(allocator.allocated_bytes, allocator.freed_bytes);
            try equal(@as(usize, if (mixed) 15 else 10), fail_index);
            break;
        }
    }
    for ([_]bool{ false, true }) |rich_start| {
        for (0..16) |failure| {
            var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var pool = try storage.Storage.init(allocator.allocator(), .{ .ceiling = 4096, .reserved = 65, .payloads = if (rich_start) 65 else 0 });
            const first = try pool.append(0, command(123), if (rich_start) payload(1) else .none);
            for (1..65) |index| _ = try pool.append(@intCast(index % 33), command(index), if (rich_start) payload(index) else .none);
            for (0..33) |owner| try pool.ensureCache(@intCast(owner));
            const old = pool.backing;
            const old_bytes = allocator.allocated_bytes - allocator.freed_bytes;
            allocator.fail_index = allocator.alloc_index + failure;
            pool.reserve(.{ .ceiling = 65536, .reserved = 4096, .payloads = 4096 }) catch |err| {
                try equal(error.OutOfMemory, err);
                try equal(@as(u32, 65), pool.config.reserved);
                try equal(@as(u32, 4096), pool.config.ceiling);
                inline for (@typeInfo(storage.Backing).@"struct".fields) |field| try equal(@field(old, field.name).ptr, @field(pool.backing, field.name).ptr);
                try equal(old_bytes, allocator.allocated_bytes - allocator.freed_bytes);
                try equal(@as(u32, 65), pool.count);
                try equal(@as(u64, 123), pool.get(first).?.command.sort_key);
                try checkGrowthContent(&pool, rich_start);
                for (0..33) |owner| try pool.clear(@intCast(owner));
                pool.deinit();
                try equal(allocator.allocated_bytes, allocator.freed_bytes);
                continue;
            };
            try equal(@as(u32, 4096), pool.config.reserved);
            try equal(@as(u64, 123), pool.get(first).?.command.sort_key);
            try checkGrowthContent(&pool, rich_start);
            for (65..4096) |index| _ = try pool.append(32, command(index), payload(index));
            for (0..33) |owner| try pool.ensureCache(@intCast(owner));
            pool.deinit();
            try equal(allocator.allocated_bytes, allocator.freed_bytes);
        }
    }
}

test "full payload pool replacement and generation exhaustion preserve ownership" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var pool = try storage.Storage.init(allocator.allocator(), .{ .ceiling = 4096, .reserved = 4096, .payloads = 4096 });
    defer pool.deinit();
    allocator.fail_index = allocator.alloc_index;
    for (0..4096) |index| _ = try pool.append(0, command(index), payload(1));
    try equal(@as(u32, 4096), pool.payload_count);
    try pool.beginReplacement(0);
    for (0..4096) |index| try pool.stage(command(index), payload(2));
    try pool.validateReplacement();
    pool.commitReplacement();
    try equal(@as(u32, 4096), pool.payload_count);
    var iterator = try pool.iterator(0);
    while (iterator.next()) |entry| try equal(payload(2), entry.payload.?.*);
    try pool.clear(0);
    const handle = try pool.append(1, command(8), .none);
    pool.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, pool.append(2, command(9), .none));
    try std.testing.expectError(error.GenerationExhausted, pool.ensureCache(1));
    try pool.beginReplacement(1);
    try pool.stage(command(10), .none);
    try std.testing.expectError(error.GenerationExhausted, pool.validateReplacement());
    pool.abortReplacement();
    try equal(@as(u64, 8), pool.get(handle).?.command.sort_key);
    try expect(!allocator.has_induced_failure);
}

test "actual allocator bytes match the model with no hidden eager payload backing" {
    try equal(@as(usize, 16), @sizeOf(storage.Page));
    try equal(@as(usize, 64), @sizeOf(storage.Payload));
    try equal(@as(usize, 24), @sizeOf(storage.Run));
    try equal(@as(usize, 16), @sizeOf(storage.SortRef));
    try equal(@as(usize, 8), @sizeOf(storage.Composition));
    try equal(@as(usize, 64), @alignOf(storage.CachePage));
    std.debug.print("STORAGE fixed={d} instance={d} cache_page={d} geometry_alignment={d}\n", .{ @sizeOf(storage.Storage), @sizeOf(rendering.Instance), @sizeOf(storage.CachePage), @alignOf(storage.CachePage) });
    for ([_]u32{ 4096, 16384, 65536 }) |capacity| {
        for ([_]bool{ false, true }) |mixed| {
            var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const config: storage.Config = .{ .ceiling = capacity, .reserved = capacity, .payloads = if (mixed) capacity else 0 };
            var pool = try storage.Storage.init(allocator.allocator(), config);
            defer pool.deinit();
            const pages: usize = capacity / 64 + 32;
            const model: usize = if (mixed) 248 * pages * 64 + 396 * capacity + 32 * pages else 240 * pages * 64 + 264 * capacity + 32 * pages;
            try equal(model + 256, pool.backing.bytes());
            try equal(model + 256, allocator.allocated_bytes);
            try equal(model + 256, try storage.Storage.reservationBytes(config));
            try equal(@as(usize, 0), @intFromPtr(pool.backing.vertices.ptr) % 64);
            try equal(@as(usize, 0), @intFromPtr(pool.backing.indices.ptr) % 64);
            if (!mixed) {
                try equal(@as(usize, 0), pool.backing.payloads.len);
                try equal(@as(usize, 0), pool.backing.payload_handles.len);
                try equal(@as(usize, 0), pool.backing.source_handles.len);
                try equal(@as(usize, 0), pool.backing.staged_payloads.len);
            }
            std.debug.print("STORAGE N={d} mixed={} backing={d} fixed={d} pages={d} slots={d} allocations={d}\n", .{ capacity, mixed, pool.backing.bytes(), @sizeOf(storage.Storage), pages, pages * 64, allocator.allocations });
        }
    }
}

test "instance ownership is opt-in and cleanup releases only its own reservation" {
    const first = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(first);
    try first.initWithDrawCapacity(std.testing.allocator, .{}, .{ .ceiling = 4096, .reserved = 0 });
    defer first.deinit();
    const second = try std.testing.allocator.create(rendering.Instance);
    defer std.testing.allocator.destroy(second);
    try second.initWithDrawCapacity(std.testing.allocator, .{}, .{ .ceiling = 4096, .reserved = 0 });
    defer second.deinit();
    const staging = &first.state.external_batch_buffer;
    try equal(@as(usize, 0), first.draw_storage.backing.bytes());
    try first.draw_storage.reserve(.{ .ceiling = 4096, .reserved = 128 });
    const handle = try first.draw_storage.append(0, command(7), .none);
    try first.draw_storage.reserve(.{ .ceiling = 4096, .reserved = 4096 });
    try equal(@as(u64, 7), first.draw_storage.get(handle).?.command.sort_key);
    try equal(staging, &first.state.external_batch_buffer);
    try equal(@as(usize, 0), second.draw_storage.backing.bytes());
    try equal(@as(usize, 0), first.state.instruction_count);
    first.draw_storage.deinit();
    try expect(first.draw_storage.get(handle) == null);
    try first.draw_storage.reserve(.{ .ceiling = 128, .reserved = 128 });
    _ = try first.draw_storage.append(0, command(9), .none);
    try expect(first.draw_storage.get(handle) == null);
}
