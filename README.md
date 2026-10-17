# SMuLE

**Shared Multimedia Layer Engine** — a small multimedia backend above SDL3, intended for use by MuM and Substrate: two seperate small projects I've been working on for a while.

Status: experimental. This repository is being prepared for extraction; no implementation has been imported yet.

## First milestone

Extract the existing graphics and compositor implementation from Substrate into an independent Zig package, preserving its behaviour, and make both Substrate and MuM consume it.

- Move compositor tests with the implementation.
- Keep protocol and adapter tests in MuM, and scripting and application integration tests in Substrate.
- Keep font loading and glyph rasterization optional, so consumers can use graphics and supplied glyph atlases without a FreeType dependency.
- Keep PieceTable and document editing outside SMuLE.

The extraction should preserve working rendering, blending, sampling, ordering and resource-lifetime semantics. Batching improvements and other renderer changes are separate work.

## Intended scope

Graphics and compositing come first. Shared audio synthesis/mixing, scheduling and input handling are subsequent milestones.

SMuLE supplies multimedia mechanisms; consumers retain their application loops, protocol or scripting interfaces, replay coordination and hot-reload policy.
