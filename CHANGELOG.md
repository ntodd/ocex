# Changelog

## Unreleased

- Add XY planar filling with nonzero/even-odd rules, including intersecting
  contours, holes and multiple regions while retaining native curves.
- Add stroke expansion with butt/round/square caps and miter/round/bevel joins,
  bounded curve sampling, XY affine transformations and ordered wire sampling.
- Preserve immutable ownership throughout splitting, meshing and conversion.
- Build exact disks for circular strokes that close the inner hole.
- Use adaptive area and Gauss–Kronrod volume integration for reliable
  measurements of curved profiles and their extrusions.

## 0.3.0

- Shape text from explicit TrueType/OpenType font bytes using FreeType and
  HarfBuzz. Kerning, ligatures, accents, counters and disconnected glyph regions
  become native planar faces with exact line and Bézier boundaries.
- Inspect font metadata, shaped glyph clusters/positions, font metrics and
  measured ink bounds. Missing glyphs and invalid/empty outlines fail explicitly;
  no installed-font fallback changes the design.
- Add native FreeType and HarfBuzz build/runtime prerequisites, a licensed
  Graduate sample font, and font geometry, ownership and archive checks.

## 0.2.0

- Add closest-point distance witnesses and circular edge centers/axes for measured inspection.
- Preserve planar support for filled sections at tightly spaced smooth-loft stations.

- Add polynomial Bézier edges with explicit control points, degrees 1–25, and validated native construction.

- Recreate stale CMake caches when the dependency source or consumer build directory moves.

## 0.1.0

- Add immutable parallel and conical projection of boundary curves onto surfaces.

- Add symmetric/tapered planar-face extrusion and straight extrusion up to an infinite plane.

- Add plane splits, filled sections, and extrusion of disconnected planar faces.
- Add draft, face sewing, signed 3D offsets, and open-surface thickening.
- Accept single-solid Boolean wrappers in draft and shell operations.

- Add ring torus construction and planar reflection for shapes.
- Correct planar-face normal metadata after a reflection.
- Add smooth lofts, open-path sweeps, and shelling with signed thickness.
- Validate shell face ownership, sweep profile placement, and inward-shell containment.

Initial release targeting Open CASCADE Technology 7.9.3.

- Direct C++17 NIF with immutable, garbage-collected shape resources.
- Curated primitives, curves, faces, booleans, transforms, finishing, extrusion, revolve, and ruled loft.
- Topology queries, measurements, analytic geometry metadata, and mesh generation.
- BREP, STEP, and binary STL exchange.
- Serialized dirty-scheduler execution and tagged native failures.
- Checksummed OCCT source installer and actionable build diagnostics.
- Keep OCCT range checks enabled and apply a minimal allocator-alignment correction in the pinned source installer. Verify the installed allocator before reporting success.
- Documented native preconditions, query return maps, selection ownership, and exchange behavior; API examples run as doctests.

- Added exact BREP hidden-line drawings with `drawing/5` and curve discretization with `polylines/3`; native builds now link OCCT TKHLR.
