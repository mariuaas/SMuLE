const std = @import("std");

const Integer = i256;
const Point = [2]Integer;
const coordinate_scale = 65536;
const cap_squared = 65536;
const records = @embedFile("fixtures/compositor-affine-sampling-mismatches.csv");
const header = "profile,width,height,raw_delta,parameter,pixel_x,pixel_y,classification,a,b,c,d,tx,ty,inverse_u,inverse_v,expected_x,expected_y,selected_x,selected_y,crossed_x,crossed_y,distance_u,distance_v,actual_rgba,reference_rgba";

const Matrix = struct {
    a: i32,
    b: i32 = 0,
    c: i32 = 0,
    d: i32,
    tx: i32 = 0,
    ty: i32 = 0,
};

const Inverse = struct {
    horizontal: Integer,
    vertical: Integer,
    denominator: Integer,
};

const Classification = enum { adjacent_sampling, coverage_excess, coverage_missing };

fn inverse(matrix: Matrix, horizontal: i32, vertical: i32) !Inverse {
    var denominator = @as(Integer, matrix.a) * matrix.d - @as(Integer, matrix.b) * matrix.c;
    if (denominator == 0) return error.SingularMatrix;
    const relative_x = @as(Integer, horizontal) * 256 + 128 - matrix.tx;
    const relative_y = @as(Integer, vertical) * 256 + 128 - matrix.ty;
    var source_x = 256 * (relative_x * matrix.d - relative_y * matrix.b);
    var source_y = 256 * (relative_y * matrix.a - relative_x * matrix.c);
    if (denominator < 0) {
        denominator = -denominator;
        source_x = -source_x;
        source_y = -source_y;
    }
    return .{ .horizontal = source_x, .vertical = source_y, .denominator = denominator };
}

fn corners(matrix: Matrix, width: u16, height: u16) [4]Point {
    const inputs = [_][2]Integer{ .{ 0, 0 }, .{ width, 0 }, .{ width, height }, .{ 0, height } };
    var result: [4]Point = undefined;
    for (inputs, &result) |input, *output| {
        output.* = .{
            @as(Integer, matrix.a) * input[0] + @as(Integer, matrix.b) * input[1] + @as(Integer, matrix.tx) * 256,
            @as(Integer, matrix.c) * input[0] + @as(Integer, matrix.d) * input[1] + @as(Integer, matrix.ty) * 256,
        };
    }
    return result;
}

fn subtract(first: Point, second: Point) Point {
    return .{ first[0] - second[0], first[1] - second[1] };
}

fn dot(first: Point, second: Point) Integer {
    return first[0] * second[0] + first[1] * second[1];
}

/// Coordinates are scaled by 65536. A 1/256-pixel cap has squared distance
/// 65536 in these units. Cross multiplication keeps segment distances exact.
/// Parsed i32 matrices/pixels and u16 extents keep squared cross products in i256.
fn coveragePermission(point: Point, vertices: [4]Point) bool {
    for (vertices, 0..) |start, index| {
        const end = vertices[(index + 1) % vertices.len];
        const direction = subtract(end, start);
        const relative = subtract(point, start);
        const length_squared = dot(direction, direction);
        const projection = dot(relative, direction);
        if (projection <= 0 or length_squared == 0) {
            if (dot(relative, relative) <= cap_squared) return true;
        } else if (projection >= length_squared) {
            const distance = subtract(point, end);
            if (dot(distance, distance) <= cap_squared) return true;
        } else {
            const cross = relative[0] * direction[1] - relative[1] * direction[0];
            if (cross * cross <= cap_squared * length_squared) return true;
        }
    }
    return false;
}

fn samplingPermission(numerator: Integer, denominator: Integer, selected: Integer) bool {
    const reference = @divFloor(numerator, denominator);
    if (selected == reference) return true;
    if (@abs(selected - reference) != 1) return false;
    const boundary = @max(selected, reference) * denominator;
    return @abs(numerator - boundary) * 256 <= denominator;
}

fn expectFraction(numerator: Integer, denominator: Integer, encoded: []const u8) !void {
    var parts = std.mem.splitScalar(u8, encoded, '/');
    const expected_numerator = try std.fmt.parseInt(i128, parts.next().?, 10);
    const expected_denominator = if (parts.next()) |part| try std.fmt.parseInt(i128, part, 10) else 1;
    try std.testing.expect(expected_denominator > 0);
    try std.testing.expect(parts.next() == null);
    try std.testing.expectEqual(@as(Integer, expected_numerator) * denominator, numerator * expected_denominator);
}

fn checkRecord(line: []const u8) !Classification {
    var columns = std.mem.splitScalar(u8, line, ',');
    var fields: [26][]const u8 = undefined;
    for (&fields) |*field| field.* = columns.next() orelse return error.MissingColumn;
    if (columns.next() != null) return error.ExtraColumn;
    const width = try std.fmt.parseInt(u16, fields[1], 10);
    const height = try std.fmt.parseInt(u16, fields[2], 10);
    try std.testing.expect(width > 0 and height > 0);
    const pixel_x = try std.fmt.parseInt(i32, fields[5], 10);
    const pixel_y = try std.fmt.parseInt(i32, fields[6], 10);
    const classification = std.meta.stringToEnum(Classification, fields[7]) orelse return error.UnknownClassification;
    const matrix: Matrix = .{
        .a = try std.fmt.parseInt(i32, fields[8], 10),
        .b = try std.fmt.parseInt(i32, fields[9], 10),
        .c = try std.fmt.parseInt(i32, fields[10], 10),
        .d = try std.fmt.parseInt(i32, fields[11], 10),
        .tx = try std.fmt.parseInt(i32, fields[12], 10),
        .ty = try std.fmt.parseInt(i32, fields[13], 10),
    };
    const source = try inverse(matrix, pixel_x, pixel_y);
    try expectFraction(source.horizontal, source.denominator, fields[14]);
    try expectFraction(source.vertical, source.denominator, fields[15]);
    try std.testing.expectEqual(@as(Integer, try std.fmt.parseInt(i32, fields[16], 10)), @divFloor(source.horizontal, source.denominator));
    try std.testing.expectEqual(@as(Integer, try std.fmt.parseInt(i32, fields[17], 10)), @divFloor(source.vertical, source.denominator));
    const selected_x = try std.fmt.parseInt(i32, fields[18], 10);
    const selected_y = try std.fmt.parseInt(i32, fields[19], 10);
    const point = Point{
        (@as(Integer, pixel_x) * 2 + 1) * (coordinate_scale / 2),
        (@as(Integer, pixel_y) * 2 + 1) * (coordinate_scale / 2),
    };
    if (classification != .adjacent_sampling)
        try std.testing.expect(coveragePermission(point, corners(matrix, width, height)));
    if (classification != .coverage_missing) {
        try std.testing.expect(samplingPermission(source.horizontal, source.denominator, selected_x));
        try std.testing.expect(samplingPermission(source.vertical, source.denominator, selected_y));
    }
    const inside = source.horizontal >= 0 and source.vertical >= 0 and
        source.horizontal < @as(Integer, width) * source.denominator and
        source.vertical < @as(Integer, height) * source.denominator;
    const seam = inside and source.horizontal * height == source.vertical * width and
        (source.horizontal != 0 or source.vertical != 0);
    try std.testing.expect(!(seam and classification == .coverage_missing));
    if (classification == .coverage_missing) {
        try std.testing.expectEqualStrings("3:5:7:255", fields[24]);
    } else {
        try std.testing.expect(selected_x >= 0 and selected_x < width and selected_y >= 0 and selected_y < height);
        var colors = std.mem.splitScalar(u8, fields[24], ':');
        const expected = [4]Integer{
            16 + @as(Integer, selected_x) * 16,
            24 + @as(Integer, selected_y) * 20,
            32 + @mod(@as(Integer, selected_x) * 7 + @as(Integer, selected_y) * 11, 13) * 16,
            255,
        };
        for (expected) |channel| {
            const actual = try std.fmt.parseInt(u8, colors.next() orelse return error.MissingChannel, 10);
            try std.testing.expectEqual(channel, @as(Integer, actual));
        }
        try std.testing.expect(colors.next() == null);
    }
    return classification;
}

test "sampling caps are inclusive and reject either axis escaping or nonadjacent samples" {
    const denominator = 65536;
    inline for (.{ -1, 1 }) |sign| {
        const at_cap = denominator + sign * 256;
        const beyond = at_cap + sign;
        const adjacent = if (sign > 0) 0 else 1;
        try std.testing.expect(samplingPermission(at_cap, denominator, adjacent));
        try std.testing.expect(!samplingPermission(beyond, denominator, adjacent));
    }
    try std.testing.expect(!(samplingPermission(65792, denominator, 0) and samplingPermission(65793, denominator, 0)));
    try std.testing.expect(samplingPermission(65792, denominator, 0) and samplingPermission(5, 4, 1));
    try std.testing.expect(!samplingPermission(65792, denominator, 2));
    try std.testing.expect(!samplingPermission(65792, denominator, -1));
}

test "finite coverage caps reject corner escapes and source-space magnification allowances" {
    const point = Point{ coordinate_scale / 2, coordinate_scale / 2 };
    inline for (.{ 1, 64 }) |scale| {
        inline for (.{ 256, 257 }) |offset| {
            const left = point[0] + offset;
            const right = left + scale * coordinate_scale;
            const vertices = [4]Point{ .{ left, 0 }, .{ right, 0 }, .{ right, coordinate_scale }, .{ left, coordinate_scale } };
            try std.testing.expectEqual(offset == 256, coveragePermission(point, vertices));
        }
    }
    const unit = corners(.{ .a = 65536, .d = 65536 }, 1, 1);
    try std.testing.expect(!coveragePermission(.{ -256, -256 }, unit));
    try std.testing.expect(!coveragePermission(point, unit));
    const magnified = Matrix{ .a = 64 * 65536 + 257, .d = 65536, .tx = 128 };
    const source = try inverse(magnified, 64, 0);
    try std.testing.expect(@abs(source.horizontal - source.denominator) * 256 < source.denominator);
    try std.testing.expect(!coveragePermission(.{ 129 * (coordinate_scale / 2), point[1] }, corners(magnified, 1, 1)));
}

test "recorded affine cases satisfy exact fixed sampling coverage and seam limits" {
    var lines = std.mem.splitScalar(u8, records, '\n');
    try std.testing.expectEqualStrings(header, std.mem.trimEnd(u8, lines.next().?, "\r"));
    var counts = [_]usize{0} ** 3;
    var row: usize = 1;
    while (lines.next()) |raw| {
        row += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const classification = checkRecord(line) catch |err| {
            std.debug.print("Affine precision fixture row {d}: {s}\n", .{ row, @errorName(err) });
            return err;
        };
        counts[@intFromEnum(classification)] += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ 11317, 711, 2123 }, &counts);
}
