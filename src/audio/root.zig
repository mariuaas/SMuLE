const std = @import("std");

/// Compatibility bundles, not interchangeable interpolation quality settings.
pub const CompatibilityProfile = enum {
    /// Integral MIDI pitch, metadata rate, nearest lookup, reset-and-skip loops.
    substrate_legacy,
    /// Q8.8 MIDI pitch, one-cycle tables, linear lookup, live bend and loop overshoot.
    mum_legacy,
};

pub const Config = struct {
    channel_count: usize,
    voice_count: usize,
    sample_count: usize,
    max_filter_taps: usize = 0,
    compatibility: CompatibilityProfile,
};

const phase_frac_bits = 32;
const phase_one: u64 = @as(u64, 1) << phase_frac_bits;
const chromatic_ratio = 1.059463094359295264562;

/// Borrowed immutable mono PCM. No method copies or frees this buffer.
/// Nonempty data must have at most maxInt(u32) frames. For substrate_legacy,
/// freq must be finite and positive and freq / fs must remain positive; fs != 0.
/// Loop head must be within data. Substrate ignores tail; MuM uses data.len when
/// tail <= head, otherwise requires head < tail <= data.len. Empty data clears a slot.
pub const Sample = struct {
    data: []const f32 = &.{},
    freq: f32 = 440,
    fs: u32 = 44100,
    loop: bool = false,
    head: u32 = 0,
    tail: u32 = 0,
};

pub const SampleError = error{ InvalidSampleIndex, InvalidSampleFrequency, InvalidSampleRate, InvalidLoopRange, SampleTooLong };

/// Caller owns synchronization: serialize every mutation, render and buffer disposal
/// for an instance. Rendering allocates and locks nothing. Do not alias output with
/// PCM or instance storage. Publish descriptors through replaceSample; direct edits
/// must uphold the same metadata and lifetime requirements.
pub fn Synth(comptime config: Config) type {
    std.debug.assert(config.voice_count > 0);
    return struct {
        const Self = @This();
        const VoiceMask = std.meta.Int(.unsigned, config.voice_count);
        pub const VoiceState = enum(u2) { idle, active, releasing };
        pub const Voice = struct {
            phase: u64 = 0,
            phase_inc: u64 = 0,
            sample: usize = 0,
            velocity: f32 = 0,
            env_level: f32 = 0,
            env_step: f32 = 0,
            env_target: f32 = 0,
            delta: i64 = 0,
            release: i64 = 0,
            note: i32 = 0,
            state: VoiceState = .idle,
        };

        pub const Channel = struct {
            voices: [config.voice_count]Voice = @splat(.{}),
            active_mask: VoiceMask = 0,
            next_cursor: usize = 0,
            sample: usize = 0,
            pan: f32 = 0.5,
            vol: f32 = 1,
            A: f32 = 0.01,
            D: f32 = 0.01,
            S: f32 = 0.95,
            R: f32 = 0.1,
            attack_samples: i64 = 0,
            decay_samples: i64 = 0,
            attack_step: f32 = 0,
            decay_step: f32 = 0,
            release_samples: i64 = 0,
            left_gain: f32 = 0.5,
            right_gain: f32 = 0.5,
            pbval: f32 = 0,
            filter_tap_count: usize = 0,
            filter_coefficients: [config.max_filter_taps]f32 = @splat(0),
            filter_history: [config.max_filter_taps]f32 = @splat(0),
            filter_position: usize = 0,
            filter_remaining: usize = 0,
        };

        sample_rate: u32 = 0,
        channels: [config.channel_count]Channel = @splat(.{}),
        samples: [config.sample_count]Sample = @splat(.{}),

        /// Reset voices, filters and borrowed descriptors without freeing buffers.
        /// sample_rate must be nonzero. Previously borrowed buffers may then be freed.
        pub fn init(self: *Self, sample_rate: u32) void {
            std.debug.assert(sample_rate > 0);
            self.sample_rate = sample_rate;
            for (&self.channels) |*channel| {
                channel.* = .{};
                self.refreshChannel(channel);
            }
            self.samples = @splat(.{});
        }

        /// Validate and publish a borrowed descriptor, returning the previous one.
        /// Failure changes nothing and transfers no ownership. Voices retain slot,
        /// phase and envelope; Substrate also retains its onset pitch increment.
        /// Keep new PCM alive and immutable until replacement or init. After this
        /// serialized call, the old buffer can be freed unless another slot or
        /// instance still borrows it (including an aliased replacement slice).
        pub fn replaceSample(self: *Self, slot: usize, sample: Sample) SampleError!Sample {
            if (slot >= self.samples.len) return error.InvalidSampleIndex;
            if (sample.data.len > std.math.maxInt(u32)) return error.SampleTooLong;
            if (sample.data.len != 0) {
                if (config.compatibility == .substrate_legacy) {
                    if (sample.fs == 0) return error.InvalidSampleRate;
                    const pitch = sample.freq / @as(f32, @floatFromInt(sample.fs));
                    if (!std.math.isFinite(sample.freq) or sample.freq <= 0 or pitch <= 0) return error.InvalidSampleFrequency;
                }
                if (sample.loop) {
                    if (sample.head >= sample.data.len) return error.InvalidLoopRange;
                    if (config.compatibility == .mum_legacy and sample.tail > sample.data.len) return error.InvalidLoopRange;
                }
            }
            const previous = self.samples[slot];
            self.samples[slot] = sample;
            return previous;
        }

        /// channel_id must be in range. Values must be finite; nonnegative A/D/R
        /// times sample_rate (computed as f32) must be < 2^63. Negative durations
        /// clamp to zero; sustain clamps to [0, 1]. Derived steps update immediately.
        pub fn setADSR(
            self: *Self,
            channel_id: usize,
            attack: f32,
            decay: f32,
            sustain: f32,
            release: f32,
        ) void {
            const channel = &self.channels[channel_id];
            channel.A = attack;
            channel.D = decay;
            channel.S = sustain;
            channel.R = release;
            self.refreshChannel(channel);
        }

        /// In-range channel and at most max_filter_taps finite coefficients required.
        /// Copies coefficients; changed values/count reset history, identical values
        /// preserve tails. An empty slice disables filtering. No borrowed lifetime.
        pub fn setFilter(self: *Self, channel_id: usize, coefficients: []const f32) void {
            std.debug.assert(coefficients.len <= config.max_filter_taps);
            const channel = &self.channels[channel_id];
            var changed = channel.filter_tap_count != coefficients.len;
            for (coefficients, 0..) |coefficient, index| {
                changed = changed or channel.filter_coefficients[index] != coefficient;
                channel.filter_coefficients[index] = coefficient;
            }
            channel.filter_tap_count = coefficients.len;
            if (changed) resetFilterHistory(channel);
        }

        /// Stop all voices and discard FIR tails; channel_id must be in range.
        pub fn stop(self: *Self, channel_id: usize) void {
            const channel = &self.channels[channel_id];
            for (0..config.voice_count) |index| resetVoice(channel, index);
            resetFilterHistory(channel);
        }

        /// Velocity must be finite (normally [0, 1]); note units follow the profile.
        /// MuM pbval is a finite live semitone offset; Substrate ignores it.
        /// Unrepresentable pitch increments silence the selected voice. Invalid
        /// channel IDs are ignored; empty slots preserve profile-specific stealing.
        pub fn noteOn(
            self: *Self,
            channel_id: usize,
            sample_id: usize,
            note: i32,
            velocity: f32,
        ) void {
            if (channel_id >= self.channels.len) return;
            if (config.compatibility == .mum_legacy and (sample_id >= self.samples.len or self.samples[sample_id].data.len == 0)) return;
            const channel = &self.channels[channel_id];
            const index = findVoice(channel);
            const voice = &channel.voices[index];
            voice.phase = 0;
            voice.delta = 0;
            voice.release = 0;
            voice.note = note;
            voice.state = .active;
            voice.velocity = velocity;
            voice.sample = sample_id;
            initEnvelope(channel, voice);
            channel.active_mask |= voiceBit(index);
            channel.next_cursor = (index + 1) % config.voice_count;
            if (sample_id >= self.samples.len or self.samples[sample_id].data.len == 0) {
                resetVoice(channel, index);
                return;
            }
            voice.phase_inc = self.getPitch(note, channel.pbval, &self.samples[sample_id]) orelse {
                resetVoice(channel, index);
                return;
            };
        }

        /// Release the first active matching note; invalid channels are ignored.
        pub fn noteOff(self: *Self, channel_id: usize, note: i32) void {
            if (channel_id >= self.channels.len) return;
            const channel = &self.channels[channel_id];
            for (&channel.voices, 0..) |*voice, index| {
                if (voice.state == .active and voice.note == note) {
                    voice.release = voice.delta;
                    if (channel.release_samples <= 0 or voice.env_level <= 0) {
                        resetVoice(channel, index);
                    } else {
                        voice.state = .releasing;
                        voice.env_target = 0;
                        voice.env_step = -voice.env_level / @as(f32, @floatFromInt(channel.release_samples));
                    }
                    return;
                }
            }
        }

        fn getPitch(self: *const Self, note: i32, bend: f32, sample: *const Sample) ?u64 {
            if (config.compatibility == .substrate_legacy) {
                const note_freq = std.math.pow(
                    f32,
                    chromatic_ratio,
                    @as(f32, @floatFromInt(@as(i64, note) - 69)),
                ) * 440.0;
                const sample_pitch = sample.freq / @as(f32, @floatFromInt(sample.fs));
                const output_rate: f32 = @floatFromInt(self.sample_rate);
                const phase_step = note_freq / output_rate / sample_pitch;
                return phaseIncrement(phase_step * @as(f32, @floatFromInt(phase_one)));
            }
            const semitone = @as(f32, @floatFromInt(note)) / 256.0 + bend;
            const note_freq = std.math.pow(f32, chromatic_ratio, semitone - 69.0) * 440.0;
            const output_rate: f64 = @floatFromInt(self.sample_rate);
            const table_length: f64 = @floatFromInt(sample.data.len);
            const phase_step = (@as(f64, note_freq) / output_rate) * table_length;
            return phaseIncrement(phase_step * @as(f64, @floatFromInt(phase_one)));
        }

        fn phaseIncrement(value: f64) ?u64 {
            if (!std.math.isFinite(value) or value < 0 or value >= 18446744073709551616.0) return null;
            return @intFromFloat(value);
        }

        /// Clear and fill an even-length interleaved stereo buffer of any frame count.
        /// PCM, gains and controls must be finite for finite output; callers own
        /// amplitude/headroom policy. Serialize with controls and sample disposal.
        pub fn render(self: *Self, output: []f32) void {
            std.debug.assert(output.len % 2 == 0);
            @memset(output, 0);
            const frames = output.len / 2;
            for (&self.channels) |*channel| {
                if (comptime config.max_filter_taps != 0) {
                    if (channel.filter_tap_count != 0) {
                        self.mixFilteredChannel(channel, output, frames);
                        continue;
                    }
                }
                var mask = channel.active_mask;
                while (mask != 0) {
                    const voice_index: usize = @ctz(mask);
                    mask &= mask - 1;
                    self.synthesizeVoice(channel, voice_index, output, frames, false);
                }
            }
        }

        fn mixFilteredChannel(self: *Self, channel: *Channel, output: []f32, frames: usize) void {
            var mono: [256]f32 = undefined;
            var offset: usize = 0;
            while (offset < frames) {
                if (channel.active_mask == 0 and channel.filter_remaining == 0) break;
                const count = @min(frames - offset, mono.len);
                @memset(mono[0..count], 0);
                var mask = channel.active_mask;
                while (mask != 0) {
                    const voice_index: usize = @ctz(mask);
                    mask &= mask - 1;
                    self.synthesizeVoice(channel, voice_index, mono[0..count], count, true);
                }
                for (mono[0..count], 0..) |sample, frame| {
                    const filtered = filterSample(channel, sample);
                    const output_index = (offset + frame) * 2;
                    output[output_index] += filtered * channel.left_gain;
                    output[output_index + 1] += filtered * channel.right_gain;
                }
                offset += count;
            }
        }

        fn sampleAt(sample: *const Sample, phase: u64) ?f32 {
            const index: usize = @intCast(phase >> phase_frac_bits);
            if (config.compatibility == .substrate_legacy) {
                if (index >= sample.data.len) return null;
                return sample.data[index];
            }
            const fraction = @as(f32, @floatFromInt(phase & (phase_one - 1))) / @as(f32, @floatFromInt(phase_one));
            const data = sample.data;
            if (sample.loop) {
                const head = sample.head;
                const tail = if (sample.tail > head) sample.tail else data.len;
                if (head >= data.len or tail > data.len or tail <= head) return 0;
                var position = index;
                const span = tail - head;
                if (position >= tail) position = head + (position - head) % span;
                const next = if (position + 1 >= tail) head else position + 1;
                return data[position] + (data[next] - data[position]) * fraction;
            }
            if (index >= data.len) return null;
            const next = @min(index + 1, data.len - 1);
            return data[index] + (data[next] - data[index]) * fraction;
        }

        fn synthesizeVoice(
            self: *Self,
            channel: *Channel,
            voice_index: usize,
            output: []f32,
            frames: usize,
            comptime mono: bool,
        ) void {
            const voice = &channel.voices[voice_index];
            if (voice.sample >= self.samples.len or self.samples[voice.sample].data.len == 0) {
                resetVoice(channel, voice_index);
                return;
            }
            const sample = &self.samples[voice.sample];
            if (config.compatibility == .mum_legacy) {
                voice.phase_inc = self.getPitch(voice.note, channel.pbval, sample) orelse {
                    resetVoice(channel, voice_index);
                    return;
                };
            }
            const left_scale = voice.velocity * channel.left_gain;
            const right_scale = voice.velocity * channel.right_gain;
            for (0..frames) |frame| {
                if (sample.loop) {
                    const head = @as(u64, sample.head) * phase_one;
                    const loop_end = if (config.compatibility == .substrate_legacy or sample.tail <= sample.head)
                        sample.data.len
                    else
                        sample.tail;
                    const tail = @as(u64, loop_end) * phase_one;
                    if (voice.phase >= tail) {
                        if (config.compatibility == .substrate_legacy) {
                            voice.phase = head;
                            continue;
                        }
                        if (tail > head) voice.phase = head + (voice.phase - head) % (tail - head);
                    }
                }
                const value = sampleAt(sample, voice.phase) orelse {
                    resetVoice(channel, voice_index);
                    return;
                };
                const mixed = value * voice.env_level;
                if (mono) {
                    output[frame] += mixed * voice.velocity;
                } else {
                    const output_index = frame * 2;
                    output[output_index] += mixed * left_scale;
                    output[output_index + 1] += mixed * right_scale;
                }
                const next_phase = @addWithOverflow(voice.phase, voice.phase_inc);
                if (next_phase[1] != 0) {
                    resetVoice(channel, voice_index);
                    return;
                }
                voice.phase = next_phase[0];
                voice.delta += 1;
                if (voice.env_step != 0) {
                    voice.env_level += voice.env_step;
                    if (voice.env_step > 0 and voice.env_level >= voice.env_target) {
                        voice.env_level = voice.env_target;
                        if (channel.decay_samples > 0 and channel.S < 1.0) {
                            voice.env_step = -channel.decay_step;
                            voice.env_target = channel.S;
                        } else {
                            voice.env_step = 0;
                        }
                    } else if (voice.env_step < 0 and voice.env_level <= voice.env_target) {
                        voice.env_level = voice.env_target;
                        voice.env_step = 0;
                        if (voice.state == .releasing and voice.env_target <= 0) {
                            resetVoice(channel, voice_index);
                            return;
                        }
                    }
                }
            }
        }

        fn clamp01(value: f32) f32 {
            return std.math.clamp(value, 0.0, 1.0);
        }

        /// Recompute gains/envelopes after direct pan, vol, A/D/S/R changes on this
        /// instance's channel. All must be finite; duration products must be < 2^63
        /// as in setADSR. Pan, volume and sustain clamp to [0, 1]. Do not directly
        /// mutate voices, masks or FIR bookkeeping; use note/stop/setFilter instead.
        pub fn refreshChannel(self: *Self, channel: *Channel) void {
            channel.pan = clamp01(channel.pan);
            channel.vol = clamp01(channel.vol);
            channel.S = clamp01(channel.S);
            channel.A = @max(channel.A, 0);
            channel.D = @max(channel.D, 0);
            channel.R = @max(channel.R, 0);
            const rate: f32 = @floatFromInt(self.sample_rate);
            channel.attack_samples = @intFromFloat(@max(channel.A, 0) * rate);
            channel.decay_samples = @intFromFloat(@max(channel.D, 0) * rate);
            channel.release_samples = @intFromFloat(@max(channel.R, 0) * rate);
            channel.attack_step = if (channel.attack_samples > 0)
                1.0 / @as(f32, @floatFromInt(channel.attack_samples))
            else
                0;
            channel.decay_step = if (channel.decay_samples > 0 and channel.S < 1.0)
                (1.0 - channel.S) / @as(f32, @floatFromInt(channel.decay_samples))
            else
                0;
            channel.left_gain = (1.0 - channel.pan) * channel.vol;
            channel.right_gain = channel.pan * channel.vol;
        }

        fn resetFilterHistory(channel: *Channel) void {
            @memset(&channel.filter_history, 0);
            channel.filter_position = 0;
            channel.filter_remaining = 0;
        }

        fn filterSample(channel: *Channel, sample: f32) f32 {
            channel.filter_history[channel.filter_position] = sample;
            var result: f32 = 0;
            var history_index = channel.filter_position;
            for (channel.filter_coefficients[0..channel.filter_tap_count]) |coefficient| {
                result += coefficient * channel.filter_history[history_index];
                history_index = if (history_index == 0) channel.filter_history.len - 1 else history_index - 1;
            }
            channel.filter_position = (channel.filter_position + 1) % channel.filter_history.len;
            if (sample != 0) {
                channel.filter_remaining = channel.filter_tap_count - 1;
            } else if (channel.filter_remaining != 0) {
                channel.filter_remaining -= 1;
            }
            return result;
        }

        fn voiceBit(index: usize) VoiceMask {
            return @as(VoiceMask, 1) << @intCast(index);
        }

        fn resetVoice(channel: *Channel, index: usize) void {
            channel.voices[index] = .{};
            channel.active_mask &= ~voiceBit(index);
        }

        fn findVoice(channel: *Channel) usize {
            const start = channel.next_cursor % config.voice_count;
            var best_releasing: ?usize = null;
            var best_releasing_age: i64 = -1;
            var best_active = start;
            var best_active_delta: i64 = -1;
            var offset: usize = 0;
            while (offset < config.voice_count) : (offset += 1) {
                const index = (start + offset) % config.voice_count;
                const voice = &channel.voices[index];
                switch (voice.state) {
                    .idle => return index,
                    .releasing => {
                        const age = voice.delta - voice.release;
                        if (best_releasing == null or age > best_releasing_age) {
                            best_releasing = index;
                            best_releasing_age = age;
                        }
                    },
                    .active => {
                        if (voice.delta > best_active_delta) {
                            best_active = index;
                            best_active_delta = voice.delta;
                        }
                    },
                }
            }
            return best_releasing orelse best_active;
        }

        fn initEnvelope(channel: *const Channel, voice: *Voice) void {
            if (channel.attack_samples > 0) {
                voice.env_level = 0;
                voice.env_step = channel.attack_step;
                voice.env_target = 1;
                return;
            }
            if (channel.decay_samples > 0 and channel.S < 1.0) {
                voice.env_level = 1;
                voice.env_step = -channel.decay_step;
                voice.env_target = channel.S;
                return;
            }
            voice.env_level = channel.S;
            voice.env_step = 0;
            voice.env_target = channel.S;
        }
    };
}
