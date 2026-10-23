// TODO: Drop this wrapper when Substrate and MuM inject the translated SDL
// module directly; migrate SMuLE imports from @import("sdl").sdl to @import("sdl").
pub const sdl = @import("sdl_c");
