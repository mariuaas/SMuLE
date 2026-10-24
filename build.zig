const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_font = b.option([]const u8, "test-font", "Explicit font fixture path; no application fonts are bundled");
    const audio = b.addModule("audio", .{
        .root_source_file = b.path("src/audio/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const audio_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/audio_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    audio_tests.root_module.addImport("audio", audio);
    const run_audio_tests = b.addRunArtifact(audio_tests);
    b.step("audio-check", "Run SDL-independent synthesis checks").dependOn(&run_audio_tests.step);
    const compositor = b.addModule("compositor", .{
        .root_source_file = b.path("src/compositor/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const graphics = b.addModule("graphics", .{
        .root_source_file = b.path("src/graphics/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics.addImport("compositor", compositor);
    const graphics_fonts = b.addModule("graphics_fonts", .{
        .root_source_file = b.path("src/graphics/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics_fonts.addImport("compositor", compositor);
    for ([_][]const u8{ "operation", "failure" }) |name| {
        const support = b.addModule(b.fmt("{s}_test_support", .{name}), .{
            .root_source_file = b.path(b.fmt("tests/{s}_support.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        support.addImport("compositor", compositor);
    }
    if (b.option(bool, "test-dependencies", "Use pinned SDL and optional FreeType for standalone qualification") orelse false) {
        const sdl_dep = b.lazyDependency("sdl", .{ .target = target, .optimize = optimize }) orelse return;
        const sdl_library = sdl_dep.artifact("SDL3");
        const translated = b.addTranslateC(.{
            .root_source_file = b.path("src/compositor/sdl.h"),
            .target = target,
            .optimize = optimize,
        });
        translated.addIncludePath(sdl_library.getEmittedIncludeTree());
        const binding = b.createModule(.{
            .root_source_file = b.path("src/compositor/sdl.zig"),
            .target = target,
            .optimize = optimize,
        });
        binding.addImport("sdl_c", translated.createModule());
        binding.linkLibrary(sdl_library);
        binding.link_libc = true;
        compositor.addImport("sdl", binding);
        if (b.option(bool, "test-fonts", "Enable optional FreeType qualification") orelse false) {
            const ft = b.lazyDependency("freetype", .{ .target = target, .optimize = optimize }) orelse return;
            graphics_fonts.addImport("freetype", ft.module("freetype"));
            graphics_fonts.linkLibrary(ft.artifact("freetype"));
        }
    }
    const all = b.step("test", "Run shared CPU and SDL rendering checks (consumer supplies SDL or use -Dtest-dependencies=true)");
    all.dependOn(&run_audio_tests.step);
    for ([_][]const u8{
        "compositor_storage_unit",       "compositor_capacity_check", "compositor_check",
        "compositor_ordering_unit",      "compositor_ordering_check", "compositor_invalidation_unit",
        "compositor_invalidation_check", "compositor_failure_unit",   "compositor_operation_unit",
        "compositor_sampling_check",     "compositor_sprite_check",   "compositor_triangle_check",
        "compositor_line_check",         "operation_check",           "failure_check",
        "graphics_check",                "graphics_glyph_check",
    }) |name| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("compositor", compositor);
        module.addImport("graphics", if (std.mem.eql(u8, name, "graphics_glyph_check")) graphics_fonts else graphics);
        const check = b.addTest(.{ .root_module = module });
        const run = b.addRunArtifact(check);
        if (test_font) |font| run.setEnvironmentVariable("SMULE_TEST_FONT", font);
        const step_name = std.mem.replaceOwned(u8, b.allocator, name, "_", "-") catch @panic("out of memory");
        b.step(step_name, b.fmt("Run {s}", .{name})).dependOn(&run.step);
        if (!std.mem.eql(u8, name, "graphics_glyph_check")) all.dependOn(&run.step);
    }
    const sweep = b.addExecutable(.{
        .name = "compositor-affine-sweep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compositor_affine_sweep.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sweep.root_module.addImport("compositor", compositor);
    b.step("compositor-affine-sweep", "Characterize affine boundaries").dependOn(&b.addRunArtifact(sweep).step);
    const precision = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compositor_affine_precision_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_precision = b.addRunArtifact(precision);
    all.dependOn(&run_precision.step);
    b.step("compositor-affine-precision-check", "Check independent fixed precision guards and recorded cases").dependOn(&run_precision.step);
}
