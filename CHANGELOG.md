# Changelog

## 0.1.0

Initial release targeting Open CASCADE Technology 7.9.3.

- Direct C++17 NIF with immutable, garbage-collected shape resources.
- Curated primitives, curves, faces, booleans, transforms, finishing, extrusion, revolve, and ruled loft.
- Topology queries, measurements, analytic geometry metadata, and mesh generation.
- BREP, STEP, and binary STL exchange.
- Serialized dirty-scheduler execution and tagged native failures.
- Checksummed OCCT source installer and actionable build diagnostics.
- Keep OCCT range checks enabled and apply a minimal allocator-alignment correction in the pinned source installer. Verify the installed allocator before reporting success.
- Documented native preconditions, query return maps, selection ownership, and exchange behavior; API examples run as doctests.
