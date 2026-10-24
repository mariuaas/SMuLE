const std = @import("std");
const audio = @import("audio");

const SampleSynth = audio.Synth(.{
    .channel_count = 2,
    .voice_count = 2,
    .sample_count = 2,
    .note_encoding = .midi,
    .sample_tuning = .metadata,
    .interpolation = .nearest,
    .pitch_bend = .ignored,
    .pitch_updates = .note_on,
    .loop_endpoint = .buffer_end,
    .loop_wrapping = .reset_and_skip,
    .empty_sample = .consume_voice,
});
const TableSynth = audio.Synth(.{
    .channel_count = 2,
    .voice_count = 2,
    .sample_count = 2,
    .max_filter_taps = 64,
    .note_encoding = .q8_8,
    .sample_tuning = .one_cycle,
    .interpolation = .linear,
    .pitch_bend = .applied,
    .pitch_updates = .render,
    .loop_endpoint = .tail,
    .loop_wrapping = .preserve_overshoot,
    .empty_sample = .ignore,
});

fn pcmHash(samples: []const f32) u64 {
    var hash: u64 = 14695981039346656037;
    for (samples) |sample| {
        hash ^= @as(u32, @bitCast(sample));
        hash *%= 1099511628211;
    }
    return hash;
}

fn capture(synth: anytype, output: []f32) u64 {
    synth.render(output);
    return pcmHash(output);
}

fn filterFrame(synth: *TableSynth, input: f32) f32 {
    if (input != 0) {
        synth.setADSR(0, 0, 0, 1, 0);
        _ = synth.replaceSample(0, .{ .data = &.{1} }) catch unreachable;
        synth.noteOn(0, 0, 69 * 256, input);
    }
    var output: [2]f32 = undefined;
    synth.render(&output);
    synth.noteOff(0, 69 * 256);
    return output[0] + output[1];
}

test "invalid metadata rejects publication without changing live playback" {
    var synth: SampleSynth = .{};
    synth.init(44100);
    _ = try synth.replaceSample(0, .{ .data = &.{ 1, 0.5, -1 }, .loop = true });
    synth.setADSR(0, 0, 0, 1, 0);
    synth.noteOn(0, 0, 69, 1);
    var before: [2]f32 = undefined;
    synth.render(&before);
    var control = synth;
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), @bitCast(@as(u32, 1)) }) |frequency| {
        try std.testing.expectError(error.InvalidSampleFrequency, synth.replaceSample(0, .{
            .data = &.{0},
            .freq = frequency,
            .fs = std.math.maxInt(u32),
        }));
    }
    try std.testing.expectError(error.InvalidSampleRate, synth.replaceSample(0, .{ .data = &.{0}, .fs = 0 }));
    try std.testing.expectError(error.InvalidLoopRange, synth.replaceSample(0, .{ .data = &.{0}, .loop = true, .head = 1 }));
    try std.testing.expectError(error.InvalidSampleIndex, synth.replaceSample(2, .{}));
    var actual: [16]f32 = undefined;
    var expected: [16]f32 = undefined;
    synth.render(&actual);
    control.render(&expected);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), std.mem.sliceAsBytes(&actual));
    const previous = try synth.replaceSample(0, .{});
    try std.testing.expectEqual(@as(usize, 3), previous.data.len);
    synth.render(&actual);
    try std.testing.expectEqual(@as(usize, 0), synth.channels[0].active_mask);
}

test "tail endpoints validate effective loop bounds but ignore unused tuning metadata" {
    var synth: TableSynth = .{};
    synth.init(48000);
    try std.testing.expectError(error.InvalidLoopRange, synth.replaceSample(0, .{ .data = &.{ 1, 2 }, .loop = true, .tail = 3 }));
    try std.testing.expectError(error.InvalidLoopRange, synth.replaceSample(0, .{ .data = &.{ 1, 2 }, .loop = true, .head = 2 }));
    _ = try synth.replaceSample(0, .{ .data = &.{ 1, 2 }, .loop = true, .head = 1, .tail = 0, .fs = 0, .freq = std.math.nan(f32) });
    synth.setADSR(0, 0, 0, 1, 0);
    synth.noteOn(0, 0, 69 * 256, 1);
    var output: [2]f32 = undefined;
    synth.render(&output);
    try std.testing.expectEqual(@as(f32, 0.5), output[0]);
}

test "unrepresentable sample pitch and live bend silence safely" {
    var synth: SampleSynth = .{};
    synth.init(44100);
    _ = try synth.replaceSample(0, .{ .data = &.{1}, .freq = 1e-30 });
    synth.noteOn(0, 0, 69, 1);
    try std.testing.expectEqual(@as(usize, 0), synth.channels[0].active_mask);
    _ = try synth.replaceSample(0, .{ .data = &.{1} });
    synth.noteOn(0, 0, std.math.maxInt(i32), 1);
    try std.testing.expectEqual(@as(usize, 0), synth.channels[0].active_mask);
    synth.noteOn(0, 0, std.math.minInt(i32), 1);
    var output: [2]f32 = undefined;
    synth.render(&output);
    var table: TableSynth = .{};
    table.init(48000);
    _ = try table.replaceSample(0, .{ .data = &.{1}, .loop = true });
    table.noteOn(0, 0, 69 * 256, 1);
    table.channels[0].pbval = std.math.inf(f32);
    table.render(&output);
    try std.testing.expectEqual(@as(usize, 0), table.channels[0].active_mask);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0 }, &output);
}

test "nearest interpolation independently preserves loop overshoot and descriptor tail" {
    const Synth = audio.Synth(.{
        .channel_count = 1,
        .voice_count = 1,
        .sample_count = 1,
        .interpolation = .nearest,
        .pitch_bend = .ignored,
    });
    var synth: Synth = .{};
    synth.init(1);
    _ = try synth.replaceSample(0, .{ .data = &.{ 1, 2, 4, 8 }, .freq = 880, .fs = 3, .loop = true, .head = 1, .tail = 3 });
    synth.setADSR(0, 0, 0, 1, 0);
    synth.noteOn(0, 0, 69, 1);
    var output: [12]f32 = undefined;
    synth.render(&output);
    for ([_]f32{ 0.5, 1, 1, 2, 2, 1 }, 0..) |expected, frame| {
        try std.testing.expectEqual(expected, output[frame * 2]);
        try std.testing.expectEqual(expected, output[frame * 2 + 1]);
    }
    try std.testing.expectEqual(@as(i64, 6), synth.channels[0].voices[0].delta);
}

test "linear metadata playback uses the selected endpoint for interpolation" {
    inline for (.{ audio.LoopEndpoint.buffer_end, .tail }) |endpoint| {
        const Synth = audio.Synth(.{
            .channel_count = 1,
            .voice_count = 1,
            .sample_count = 1,
            .loop_endpoint = endpoint,
        });
        var synth: Synth = .{};
        synth.init(1);
        _ = try synth.replaceSample(0, .{ .data = &.{ 1, 3, 7 }, .freq = 880, .fs = 1, .loop = true, .head = 1, .tail = 2 });
        synth.setADSR(0, 0, 0, 1, 0);
        synth.noteOn(0, 0, 69, 1);
        var output: [12]f32 = undefined;
        synth.render(&output);
        const expected = if (endpoint == .buffer_end)
            [_]f32{ 0.5, 1, 1.5, 2.5, 3.5, 2.5 }
        else
            [_]f32{ 0.5, 1, 1.5, 1.5, 1.5, 1.5 };
        for (expected, 0..) |value, frame| try std.testing.expectEqual(value, output[frame * 2]);
    }
}

test "linear metadata playback can reset and skip at a descriptor tail" {
    const Synth = audio.Synth(.{
        .channel_count = 1,
        .voice_count = 1,
        .sample_count = 1,
        .loop_wrapping = .reset_and_skip,
    });
    var synth: Synth = .{};
    synth.init(1);
    _ = try synth.replaceSample(0, .{ .data = &.{ 1, 2, 4, 8 }, .freq = 880, .fs = 3, .loop = true, .head = 1, .tail = 3 });
    synth.setADSR(0, 0, 0, 1, 0);
    synth.noteOn(0, 0, 69, 1);
    var output: [12]f32 = undefined;
    synth.render(&output);
    for ([_]f32{ 0.5, 1.5, 0, 1, 1.5, 0 }, 0..) |expected, frame| {
        try std.testing.expectEqual(expected, output[frame * 2]);
    }
    try std.testing.expectEqual(@as(i64, 4), synth.channels[0].voices[0].delta);
}

test "loop validation depends on endpoint not interpolation or wrapping" {
    inline for (.{ audio.Interpolation.nearest, .linear }) |interpolation| {
        inline for (.{ audio.LoopWrapping.preserve_overshoot, .reset_and_skip }) |wrapping| {
            inline for (.{ audio.LoopEndpoint.buffer_end, .tail }) |endpoint| {
                const Synth = audio.Synth(.{
                    .channel_count = 1,
                    .voice_count = 1,
                    .sample_count = 1,
                    .interpolation = interpolation,
                    .loop_wrapping = wrapping,
                    .loop_endpoint = endpoint,
                });
                var synth: Synth = .{};
                synth.init(44100);
                const outside = audio.Sample{ .data = &.{ 1, 2, 4 }, .loop = true, .head = 1, .tail = 4 };
                if (endpoint == .tail) {
                    try std.testing.expectError(error.InvalidLoopRange, synth.replaceSample(0, outside));
                } else {
                    _ = try synth.replaceSample(0, outside);
                }
                for ([_]u32{ 0, 1 }) |tail| {
                    _ = try synth.replaceSample(0, .{ .data = &.{ 1, 2, 4 }, .loop = true, .head = 1, .tail = tail });
                }
                try std.testing.expectError(error.InvalidLoopRange, synth.replaceSample(0, .{ .data = &.{1}, .loop = true, .head = 1 }));
                _ = try synth.replaceSample(0, .{ .data = &.{1}, .head = 99, .tail = 99 });
            }
        }
    }
}

test "held pitch timing and bend are independent of note encoding and tuning" {
    inline for (.{ audio.SampleTuning.metadata, .one_cycle }) |tuning| {
        inline for (.{ audio.NoteEncoding.midi, .q8_8 }) |encoding| {
            inline for (.{ audio.PitchBend.ignored, .applied }) |bend| {
                inline for (.{ audio.PitchUpdates.note_on, .render }) |updates| {
                    const Synth = audio.Synth(.{
                        .channel_count = 2,
                        .voice_count = 1,
                        .sample_count = 1,
                        .note_encoding = encoding,
                        .sample_tuning = tuning,
                        .pitch_bend = bend,
                        .pitch_updates = updates,
                        .interpolation = .nearest,
                    });
                    var synth: Synth = .{};
                    synth.init(44100);
                    _ = try synth.replaceSample(0, .{ .data = &.{ 1, 2, 3, 4 }, .loop = true });
                    synth.setADSR(0, 0, 0, 1, 0);
                    const note = if (encoding == .midi) 69 else 69 * 256;
                    synth.noteOn(0, 0, note, 1);
                    const onset = synth.channels[0].voices[0].phase_inc;
                    synth.channels[0].pbval = 12;
                    synth.channels[1].pbval = 12;
                    var output: [2]f32 = undefined;
                    synth.render(&output);
                    synth.noteOn(1, 0, note, 1);
                    const bent = synth.channels[1].voices[0].phase_inc;
                    try std.testing.expectEqual(if (updates == .render) bent else onset, synth.channels[0].voices[0].phase_inc);
                    if (bend == .applied) try std.testing.expect(bent > onset) else try std.testing.expectEqual(onset, bent);
                    _ = try synth.replaceSample(0, .{ .data = &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, .freq = 220, .loop = true });
                    synth.render(&output);
                    synth.noteOn(1, 0, note, 1);
                    const replaced = synth.channels[1].voices[0].phase_inc;
                    try std.testing.expect(replaced > bent);
                    try std.testing.expectEqual(if (updates == .render) replaced else onset, synth.channels[0].voices[0].phase_inc);
                }
            }
        }
    }
}

test "invalid and empty slots independently ignore or consume the selected voice" {
    inline for (.{ audio.EmptySample.ignore, .consume_voice }) |policy| {
        for ([_]usize{ 1, 2 }) |invalid_slot| {
            const Synth = audio.Synth(.{
                .channel_count = 1,
                .voice_count = 2,
                .sample_count = 2,
                .empty_sample = policy,
            });
            var synth: Synth = .{};
            synth.init(44100);
            _ = try synth.replaceSample(0, .{ .data = &.{1}, .loop = true });
            synth.noteOn(0, 0, 69, 1);
            synth.noteOn(0, 0, 70, 1);
            synth.noteOn(0, invalid_slot, 71, 1);
            const channel = &synth.channels[0];
            try std.testing.expectEqual(@as(i32, 70), channel.voices[1].note);
            if (policy == .ignore) {
                try std.testing.expectEqual(@as(u2, 3), channel.active_mask);
                try std.testing.expectEqual(@as(i32, 69), channel.voices[0].note);
                try std.testing.expectEqual(@as(usize, 0), channel.next_cursor);
            } else {
                try std.testing.expectEqual(@as(u2, 2), channel.active_mask);
                try std.testing.expectEqual(Synth.VoiceState.idle, channel.voices[0].state);
                try std.testing.expectEqual(@as(usize, 1), channel.next_cursor);
            }
        }
    }
}

test "nearest loop keeps the reset gap while linear wavetable keeps overshoot" {
    const pcm = [_]f32{ 1, 2, 4 };
    var nearest: SampleSynth = .{};
    nearest.init(44100);
    _ = try nearest.replaceSample(0, .{ .data = &pcm, .loop = true, .head = 1 });
    nearest.setADSR(0, 0, 0, 1, 0);
    nearest.noteOn(0, 0, 69, 1);
    var output: [14]f32 = undefined;
    nearest.render(&output);
    const expected = [_]f32{ 0.5, 1, 2, 0, 1, 2, 0 };
    for (expected, 0..) |sample, index| {
        try std.testing.expectEqual(sample, output[index * 2]);
        try std.testing.expectEqual(sample, output[index * 2 + 1]);
    }
    try std.testing.expectEqual(@as(i64, 5), nearest.channels[0].voices[0].delta);
    var linear: TableSynth = .{};
    linear.init(880);
    _ = try linear.replaceSample(0, .{ .data = &pcm, .loop = true, .head = 1, .tail = 3 });
    linear.setADSR(0, 0, 0, 1, 0);
    linear.noteOn(0, 0, 69 * 256, 1);
    linear.render(output[0..10]);
    const interpolated = [_]f32{ 0.5, 1.5, 1, 1.5, 2 };
    for (interpolated, 0..) |sample, index| try std.testing.expectEqual(sample, output[index * 2]);
    try std.testing.expectEqual(@as(i64, 5), linear.channels[0].voices[0].delta);
}

test "one shot completion and replacement keep resolved per-note sample slots" {
    var synth: SampleSynth = .{};
    synth.init(44100);
    _ = try synth.replaceSample(0, .{ .data = &.{1} });
    _ = try synth.replaceSample(1, .{ .data = &.{ -1, -1, -1 } });
    synth.setADSR(0, 0, 0, 1, 0);
    synth.noteOn(0, 1, 69, 1);
    synth.channels[0].sample = 0;
    var output: [2]f32 = undefined;
    synth.render(&output);
    try std.testing.expectEqual(@as(f32, -0.5), output[0]);
    const old = try synth.replaceSample(1, .{ .data = &.{ 1, 0.5 } });
    try std.testing.expectEqual(@as(usize, 3), old.data.len);
    synth.render(&output);
    try std.testing.expectEqual(@as(f32, 0.25), output[0]);
    synth.render(&output);
    try std.testing.expectEqual(@as(f32, 0), output[0]);
    try std.testing.expectEqual(@as(u2, 0), synth.channels[0].active_mask);
}

test "ADSR clamping sample-rate conversion and releasing voice preference" {
    var synth: SampleSynth = .{};
    synth.init(22050);
    synth.setADSR(0, 1, 1, 0.5, 1);
    const channel = &synth.channels[0];
    try std.testing.expectEqual(@as(i64, 22050), channel.attack_samples);
    try std.testing.expectEqual(@as(f32, 1.0 / 22050.0), channel.attack_step);
    try std.testing.expectEqual(@as(f32, 0.5 / 22050.0), channel.decay_step);
    channel.pan = -1;
    channel.vol = 2;
    synth.refreshChannel(channel);
    try std.testing.expectEqual(@as(f32, 1), channel.left_gain);
    try std.testing.expectEqual(@as(f32, 0), channel.right_gain);
    synth.setADSR(0, -1, -1, 2, 0.01);
    try std.testing.expectEqual(@as(f32, 0), channel.A);
    try std.testing.expectEqual(@as(f32, 1), channel.S);
    _ = try synth.replaceSample(0, .{ .data = &.{1}, .loop = true });
    synth.noteOn(0, 0, 69, 1);
    synth.noteOn(0, 0, 70, 1);
    synth.noteOff(0, 70);
    synth.noteOn(0, 0, 71, 1);
    try std.testing.expectEqual(@as(i32, 69), channel.voices[0].note);
    try std.testing.expectEqual(@as(i32, 71), channel.voices[1].note);
}

test "FIR impulse taps history coefficient changes tails stop and reset" {
    var synth: TableSynth = .{};
    synth.init(48000);
    var coefficients: [64]f32 = @splat(0);
    coefficients[0] = 0.5;
    coefficients[1] = -0.25;
    coefficients[63] = -1;
    synth.setFilter(0, &coefficients);
    const channel = &synth.channels[0];
    try std.testing.expectEqual(@as(f32, 0.5), filterFrame(&synth, 1));
    for (1..66) |frame| {
        const expected: f32 = if (frame == 1) -0.25 else if (frame == 63) -1 else 0;
        try std.testing.expectEqual(expected, filterFrame(&synth, 0));
    }
    try std.testing.expectEqual(@as(usize, 0), channel.filter_remaining);
    synth.setFilter(0, &.{ 0, 0.5, 0.25 });
    _ = filterFrame(&synth, 1);
    synth.setFilter(0, &.{ 0, 0.5, 0.25 });
    var output: [6]f32 = undefined;
    synth.render(&output);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25, 0.125, 0.125, 0, 0 }, &output);
    _ = filterFrame(&synth, 1);
    synth.setFilter(0, &.{ 0, -0.5, 0.25 });
    try std.testing.expectEqual(@as(f32, 0), filterFrame(&synth, 0));
    _ = filterFrame(&synth, 1);
    synth.stop(0);
    synth.render(&output);
    try std.testing.expectEqualSlices(f32, &(@as([6]f32, @splat(0))), &output);
    _ = filterFrame(&synth, 1);
    synth.init(48000);
    try std.testing.expectEqual(@as(usize, 0), channel.filter_tap_count);
    try std.testing.expectEqualSlices(f32, &(@as([64]f32, @splat(0))), &channel.filter_history);
}

test "independent instances and arbitrary render blocks preserve every PCM bit" {
    inline for (.{ SampleSynth, TableSynth }) |Synth| {
        var whole: Synth = .{};
        var pieces: Synth = .{};
        var other: Synth = .{};
        whole.init(44100);
        pieces.init(44100);
        other.init(48000);
        const pcm = [_]f32{ 0.25, -0.5, 1, 0.125, -0.25 };
        for ([_]*Synth{ &whole, &pieces }) |synth| {
            _ = try synth.replaceSample(0, .{ .data = &pcm, .freq = 330, .loop = true, .head = 1, .tail = 5 });
            synth.setADSR(0, 0.001, 0.002, 0.75, 0.003);
            synth.noteOn(0, 0, if (Synth == TableSynth) 69 * 256 else 69, 0.7);
            if (Synth == TableSynth) synth.setFilter(0, &.{ 0.5, -0.25, 0.125 });
        }
        var expected: [2048]f32 = undefined;
        var actual: [2048]f32 = undefined;
        whole.render(&expected);
        var offset: usize = 0;
        for ([_]usize{ 0, 1, 7, 257, 3, 511, 245 }) |frames| {
            pieces.render(actual[offset * 2 ..][0 .. frames * 2]);
            var silence: [2]f32 = undefined;
            other.render(&silence);
            offset += frames;
        }
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), std.mem.sliceAsBytes(&actual));
        try std.testing.expectEqual(@as(u32, 48000), other.sample_rate);
        try std.testing.expectEqual(@as(usize, 0), other.channels[0].active_mask);
    }
}

test "capacities are selected by the caller rather than inherited from MuM" {
    const Synth = audio.Synth(.{
        .channel_count = 40,
        .voice_count = 16,
        .sample_count = 80,
        .max_filter_taps = 96,
        .note_encoding = .q8_8,
        .sample_tuning = .one_cycle,
        .interpolation = .linear,
        .pitch_bend = .applied,
        .pitch_updates = .render,
        .loop_endpoint = .tail,
        .loop_wrapping = .preserve_overshoot,
        .empty_sample = .ignore,
    });
    var synth: Synth = .{};
    synth.init(48000);
    _ = try synth.replaceSample(79, .{ .data = &.{1}, .loop = true, .tail = 1 });
    synth.setADSR(39, 0, 0, 1, 0);
    for (0..16) |index| synth.noteOn(39, 79, @intCast(69 * 256 + index), 1);
    try std.testing.expectEqual(@as(u16, 65535), synth.channels[39].active_mask);
    var coefficients: [96]f32 = @splat(0);
    coefficients[95] = 0.5;
    synth.setFilter(39, &coefficients);
    var output: [200]f32 = undefined;
    synth.render(&output);
    try std.testing.expect(output[190] > 0);
}

test "sample-metadata PCM matches the original Substrate control sequence bit for bit" {
    const Synth = audio.Synth(.{
        .channel_count = 16,
        .voice_count = 8,
        .sample_count = 64,
        .note_encoding = .midi,
        .sample_tuning = .metadata,
        .interpolation = .nearest,
        .pitch_bend = .ignored,
        .pitch_updates = .note_on,
        .loop_endpoint = .buffer_end,
        .loop_wrapping = .reset_and_skip,
        .empty_sample = .consume_voice,
    });
    var synth: Synth = .{};
    synth.init(44100);
    const first = [_]i16{ 12000, -8000, 3000, 16000, -12000, 4000, -1000 };
    const second = [_]i16{ -20000, 5000, 10000, -3000, 7000, 22000, -16000, 1000, 4000, -9000, 2000 };
    var first_pcm: [first.len]f32 = undefined;
    var second_pcm: [second.len]f32 = undefined;
    for (first, &first_pcm) |sample, *value| value.* = @as(f32, @floatFromInt(sample)) / 32768.0;
    for (second, &second_pcm) |sample, *value| value.* = @as(f32, @floatFromInt(sample)) / 32768.0;
    _ = try synth.replaceSample(0, .{ .data = &first_pcm, .freq = 330, .fs = 44100, .loop = true, .head = 2 });
    _ = try synth.replaceSample(1, .{ .data = &second_pcm, .freq = 440, .fs = 44100 });
    synth.setADSR(0, 0.0002, 0.0003, 0.65, 0.0004);
    synth.setADSR(1, 0, 0, 1, 0);
    synth.noteOn(0, 0, 69, 0.8);
    synth.noteOn(1, 1, 69, 0.6);
    var output: [1024]f32 = undefined;
    var hashes: [7]u64 = undefined;
    hashes[0] = capture(&synth, output[0..2]);
    hashes[1] = capture(&synth, output[0..34]);
    for (0..11) |index| synth.noteOn(0, 0, @intCast(60 + index), 0.7);
    hashes[2] = capture(&synth, output[0..514]);
    for (60..71) |note| synth.noteOff(0, @intCast(note));
    hashes[3] = capture(&synth, output[0..66]);
    synth.noteOn(0, 0, 67, 0.9);
    hashes[4] = capture(&synth, output[0..26]);
    _ = try synth.replaceSample(0, .{ .data = &second_pcm, .freq = 466.16, .fs = 44100, .loop = true, .head = 3 });
    hashes[5] = capture(&synth, output[0..130]);
    synth.channels[0].pbval = 1;
    hashes[6] = capture(&synth, output[0..514]);
    try std.testing.expectEqualSlices(u64, &.{
        4661701801794957293,  4849196072886362333, 2221273829297424873,
        17386500873353889761, 864417243066625811,  14767867191924493437,
        12258967693477821155,
    }, &hashes);
}

test "wavetable PCM matches the original MuM control sequence bit for bit" {
    const Synth = audio.Synth(.{
        .channel_count = 32,
        .voice_count = 8,
        .sample_count = 64,
        .max_filter_taps = 64,
        .note_encoding = .q8_8,
        .sample_tuning = .one_cycle,
        .interpolation = .linear,
        .pitch_bend = .applied,
        .pitch_updates = .render,
        .loop_endpoint = .tail,
        .loop_wrapping = .preserve_overshoot,
        .empty_sample = .ignore,
    });
    var synth: Synth = .{};
    synth.init(48000);
    var pcm: [32]f32 = undefined;
    for (&pcm, 0..) |*value, index| value.* = @as(f32, @floatFromInt(@as(i16, if (index < 16) 16000 else -16000))) / 32768.0;
    _ = try synth.replaceSample(0, .{ .data = &pcm, .loop = true, .tail = 32 });
    synth.setADSR(0, 0, 0, 1, 0);
    synth.channels[0].pan = 0;
    synth.refreshChannel(&synth.channels[0]);
    synth.noteOn(0, 0, 69 * 256, 1);
    synth.noteOn(0, 0, 60 * 256, 80.0 / 127.0);
    var output: [2048]f32 = undefined;
    var hashes: [8]u64 = undefined;
    hashes[0] = capture(&synth, output[0..2]);
    hashes[1] = capture(&synth, output[0..34]);
    synth.setADSR(0, 3.0 / 1000.0, 5.0 / 1000.0, 160.0 / 255.0, 7.0 / 1000.0);
    for (0..9) |index| synth.noteOn(0, 0, @intCast(60 * 256 + index * 64), 90.0 / 127.0);
    hashes[2] = capture(&synth, output[0..666]);
    synth.channels[0].pbval = 317.0 / 256.0;
    synth.setFilter(0, &.{ 0.5, -0.25, 0.125, 0.0625 });
    hashes[3] = capture(&synth, output[0..514]);
    synth.noteOff(0, 60 * 256 + 8 * 64);
    hashes[4] = capture(&synth, output[0..1600]);
    synth.setFilter(0, &.{ 0.5, 0.25, 0.125, 0.0625 });
    pcm[0] = 15881.0 / 32768.0;
    _ = try synth.replaceSample(0, .{ .data = &pcm });
    hashes[5] = capture(&synth, output[0..514]);
    synth.stop(0);
    hashes[6] = capture(&synth, output[0..34]);
    synth.init(48000);
    hashes[7] = capture(&synth, output[0..514]);
    try std.testing.expectEqualSlices(u64, &.{
        17651539485568251662, 17682043807891095374, 7584071705075492080,
        167063285568159631,   14686546794744299043, 7925641182124067940,
        13055558309906261613, 11932062479859111917,
    }, &hashes);
}
