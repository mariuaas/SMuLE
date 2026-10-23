# SMuLE: Shared Multimedia Layer Engine

SMuLE is a small multimedia backend built on SDL3 and Zig, shared by MuM and Substrate: two private projects I've been working on for a while. They use much of the same rendering machinery, and maintaining it twice has little appeal.

For now, SMuLE handles graphics and compositing, with optional font loading and glyph rasterization via FreeType. Audio synthesis and mixing, scheduling, and input handling planned for later. Still experimental, and currently no standalone app. Graphics module was extracted from Substrate, after alignment with MuM.

## Using it

The package targets **Zig 0.16.0** and exports three modules:

| Module | Function |
| --- | --- |
| `graphics` | Graphics API and an instance-owned renderer. No FreeType dependency. |
| `graphics_fonts` | Graphics API plus FreeType font service. |
| `compositor` | Underlying storage and rendering code, including diagnostics. |

Consumer app supplies SDL module exporting `pub const sdl` (SDL3 C bindings), along with SDL library, headers and link configuration. Attach it with:

```zig
dependency.module("compositor").addImport("sdl", binding);
```

Graphics modules already import that compositor. Use one SDL binding module throughout.
SMuLE doesn't initialize SDL or manage global lifetime.

For font support, attach `freetype` module and library to `graphics_fonts`. Font support is available as `graphics.fonts` / `graphics.Fonts`. You can also supply glyph atlases yourself and leave FreeType out entirely.

### Ownership and drawing

Consumer app is responsible for the SDL window. `Graphics.init` borrows it and creates a renderer. Keep initialized graphics and font instances at stable addresses, and tear them down in this order: fonts, graphics, window.

A typical frame starts with `Graphics.beginFrame`, which clears the current output. Submit draws, layer properties and retained replacements. If you use retained layers, call `compileDirtyRetainedLayers()` before `executeCompositeFrame()`. Then call `present()` when the app needs it. To bracket an update without clearing the output, use `beginUpdate` and `endUpdate`.

Retained replacements are transactional: begin, stage, then commit, or abort if something fails. `configuration()` returns a snapshot. Editing won't change the running instance.

Main loop, scheduling, presentation, assets, scripting, protocol state, replay and hot reload stay with your application.

See [API contracts](docs/api-contracts.md) for details, including ownership, scratch aliasing and submission semantics.

## Tests

Standalone checks fetch and compile pinned SDL3 sources. Font checks also fetch and compile FreeType. Prebuilt SDL3 / FreeType libraries are not required. Enable those source dependencies explicitly:

```sh
# Metal is macOS-only.
SDL_RENDER_DRIVER=metal zig build -Dtest-dependencies=true test
SDL_RENDER_DRIVER=software zig build -Dtest-dependencies=true test
zig build -Dtest-dependencies=true -Dtest-fonts=true \
  -Dtest-font=/absolute/path/to/font.ttf graphics-glyph-check
zig build compositor-affine-precision-check
```

Run with `-Doptimize=ReleaseFast` as well. Affine precision check also needs Python 3. Software checks verify that unsupported operation blending is rejected; they don't validate rendered pixels for those operations.

No font is bundled. Glyph check needs an explicit font fixture and fails without one. Applications can also run dependency test steps with their own SDL and FreeType modules.

Compositor tests live here, keep external tests for app seperate. `operation_test_support` and `failure_test_support` support those external tests and aren't stable rendering APIs.

**NOTE**: `tests/fixtures` includes targets for tests, extracted programatically. Excessive for what it does, might cut back later...

### SDL bindings for standalone tests

Standalone build uses `addTranslateC` in `build.zig` to translate `src/compositor/sdl.h` against pinned SDL headers. The `sdl.zig` bridge exports the result as `pub const sdl`, matching the binding your application supplies. SMuLE's source no longer uses `@cImport`.

This follows the [Zig 0.16 C translation migration guidance](https://ziglang.org/download/0.16.0/release-notes.html). SMuLE and both applications are tested with Zig 0.16.0; 0.17 hasn't been validated.

## Working on SMuLE

Both MuM and Substrate use lower-level compositor modules, including exposed mutable state and scratch views. Changes to their names, signatures or layouts need to be checked against both projects. [API contracts](docs/api-contracts.md) cover compatibility paths.

Before submitting changes, run:

```sh
zig fmt --check build.zig build.zig.zon src tests
```

Use trailing commas in multiline calls and initializers, keep imports at module scope, and break up long conditions yourself—the formatter won't do that part. Small private helpers are useful when they make ownership, rendering phases or repeated state changes easier to follow.

Keep arithmetic, casts and geometry fast paths easy to inspect. Changes to floating-point evaluation order or runtime checks need correctness and performance evidence.

### Debug logging

Set `debug = true` in `Config`, or call `setDebug(true)` on your graphics instance. Diagnostics use `std.log.scoped(.smule)` at debug level. To enable the scope, including in optimized builds, add this to your root module:

```zig
const std = @import("std");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .smule, .level = .debug }},
};
```
