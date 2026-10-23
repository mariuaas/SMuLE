# SMuLE API contracts

## Ownership and lifecycle

The consumer owns SDL initialization, its window, scheduling and final presentation.
`Graphics` borrows the window, owns its renderer and embeds a compositor `Instance`.
The lower-level `Instance` borrows its renderer. Composition targets supplied by
the host remain borrowed. Deinitialize fonts before graphics, then destroy the
window and quit SDL. Initialized instances must retain their addresses.

`Instance` contains large compatibility staging arrays. Allocate it with
`allocator.create(Instance)` on constrained stacks. Initialization takes an
explicit allocator; the field defaults support uninitialized/empty state and
do not replace initialization. Failed low-level initialization must be followed
by `deinit` before freeing or retrying. `Graphics.init` cleans up its own failure.

## Update and presentation

`beginFrame` enters the update state and clears the output. `beginUpdate` and
`endUpdate` bracket changes without clearing. Draw submission, retained-layer
replacement and layer properties require update state. Retained replacement is
transactional: begin, stage, commit, or abort on failure.

Composition produces a ready frame; presentation remains a separate host choice.
Resource or presentation changes revoke readiness. Dirty flags distinguish
geometry compilation, target rasterization and presentation work. An unchanged
property must not request any of those operations.

## Scratch backing

Sorted immediate/layer references are two views of one reserved scratch slice.
Cached/geometry vertices and indices likewise alias their respective backing.
They describe different phases, not independent allocations. Finish consuming
one phase before reusing that backing. Retained cache pages store persistent
geometry; scratch slices do not. Growing a reservation may invalidate previously
borrowed slices, and `bindDrawStorage` refreshes the views.

## Submission and counters

Bulk submission inspects only the first `min(input_count, available_slots)`
inputs. Invalid entries in that prefix are skipped. It does not scan later
inputs to fill holes. Its result counts accepted draws, not consumed inputs;
using it as a retry offset can duplicate a valid draw.

Operation CPU allocation statistics count successful surface conversions and
owned pixel-buffer allocations, not every malloc inside SDL. `prepareSurface`
therefore contributes two events on success. Failure paths count only completed
events. Operation sources must originate from CPU bytes without GPU copies or
readbacks.

`FrameStats.bulk_api_calls` counts attempts through the compatibility bulk entry
point after frame-state validation. Scalar/rich-primitive entry points do not
increment it. `time_host_update` is a host-supplied duration in microseconds.

`DrawInstruction.kind` is a one-byte encoding policy: `clamped_quad` is 0,
`raw_uv_quad` is 1, and `line` is 2. The separate payload union identifies rich
primitives, so a triangle does not need its own kind byte. Unknown bytes remain
representable and are rejected for payload-free staged submissions. The command
remains 64 bytes, with the kind at byte offset 63.

## Pixels and compatibility paths

Operation sources are premultiplied RGBA. Operation canvases implement normal,
additive and multiply accumulation; sampling, address modes and integer rounding
are part of the rendering contract. Public source colors and tint values must
be interpreted according to the specific submission API.

Normal targets store premultiplied RGB and coverage alpha, additive targets store
clamped energy with zero alpha, and multiply targets store factors with alpha one.
Triangle positions and texel UVs use signed 24.8 coordinates; vertex colors enter
as straight RGBA8 and are premultiplied before interpolation. Affine coefficients
use signed 16.16, with signed 24.8 pixel translations.

`legacy_rgba` and the non-geometry blit path preserve Substrate behavior. They
remain supported compatibility paths, with their existing tests. Software
qualification checks explicit unsupported-operation rejection; it does not add
software operation-canvas support.

## Diagnostics and the public boundary

The `Graphics` facade is the ordinary entry point. Compositor modules, state
fields and transport structs remain exposed because Substrate and MuM use them.
Source migrations must update those consumers together and preserve layout and
rendering semantics. C-compatible structs/types are retained at these existing
SDL and transport boundaries; replacing them is a separate API decision.

Debug diagnostics remain opt-in through `debug_mode`; scoped logging lets the
application additionally filter the library's messages. Diagnostics do not
replace returned errors. Test-only support modules are not production APIs.
