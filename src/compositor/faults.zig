const builtin = @import("builtin");

pub const Point = enum {
    sprite_metadata_allocation,
    triangle_metadata_allocation,
    line_metadata_allocation,
    untextured_blend_restore,
    sampling_cpu_allocation,
    sampling_target_creation,
    sampling_copy,
    sampling_state,
    sampling_address_state,
    sampling_setup,
    sampling_restore,
    palette_allocation,
    palette_creation,
    palette_colors,
    surface_palette,
    surface_creation,
    texture_creation,
    texture_scale,
    texture_upload,
    target_creation,
    target_select,
    target_restore,
    render_scale,
    draw_color,
    clear,
    texture_blend,
    texture_color,
    texture_alpha,
    clip,
    viewport,
    geometry,
    blit,
    present,
    operation_allocation,
    operation_cpu_allocation,
    operation_surface_conversion,
    operation_upload,
};

pub const Faults = struct {
    point: ?Point = null,
    remaining: usize = 0,

    pub fn inject(
        self: *Faults,
        point: Point,
        occurrence: usize,
    ) void {
        self.point = point;
        self.remaining = occurrence;
    }

    pub fn check(
        self: *Faults,
        point: Point,
    ) bool {
        if (!builtin.is_test or self.point != point) return false;
        if (self.remaining > 0) {
            self.remaining -= 1;
            return false;
        }
        self.point = null;
        return true;
    }
};
