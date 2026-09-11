# OCEx

**Native Elixir geometry, powered by Open CASCADE Technology.**

OCEx provides immutable, immediate geometry operations through a C++ NIF linked to
OCCT 7.9.3. Create solids, build profiles, combine and finish bodies, inspect their
topology, and exchange STEP, BREP, or STL. No Python runtime or runtime Hex
dependencies are required.

For deferred pipelines, workplanes, named assemblies, Livebook previews, and
verified STL/3MF bundles, use [Smith](https://hexdocs.pm/smith). OCEx is the lower
layer and can be used independently.

## A first solid

Install the native prerequisites using the [installation guide](guides/installation.md),
then save this as `plate.exs`:

```elixir
Mix.install([{:ocex, "~> 0.1.0"}])

{:ok, blank} = OCEx.box(60, 40, 5)
{:ok, bore} = OCEx.cylinder(4, 7)
{:ok, bore} = OCEx.translate(bore, {30, 20, -1})
{:ok, plate} = OCEx.cut(blank, bore)
{:ok, true} = OCEx.valid?(plate)
{:ok, volume} = OCEx.volume(plate)
{:ok, :ok} = OCEx.write_step(plate, "plate.step")
{:ok, :ok} = OCEx.write_stl(plate, "plate.stl", 0.03, 0.5)
IO.puts("Plate volume: #{volume} mm³")
```

Run `elixir plate.exs`. For a Mix application, add `{:ocex, "~> 0.1.0"}` to its
dependencies. Mix builds the NIF automatically. The exact OCCT toolkit must remain
installed at runtime because the NIF dynamically links its libraries.

## What is included

| Area | Operations |
| --- | --- |
| Solids | Box, cylinder, sphere, cone |
| Profiles | Lines, circles, directed arcs, interpolated splines, wires, planar faces |
| Modeling | Extrusion, revolution, ruled loft, compound, union, subtraction, intersection |
| Finishing | Fillet, chamfer, same-domain cleanup |
| Placement | Translation, axis-angle rotation, uniform scale |
| Inspection | Topology, validity, bounds, volume, area, length, centroids, curve/surface information |
| Exchange | BREP snapshots, STEP import/export, binary STL export, indexed surface mesh |

See the `OCEx` module for each function's contract and the
[native geometry guide](guides/native-geometry.md) for units, orientation,
profile requirements, selectors, meshing, and exchange behavior.

## A small, explicit contract

Every public operation returns `{:ok, value}` or `{:error, reason}`. Shapes are
opaque, garbage-collected native resources. Modeling operations preserve their
inputs; edge selections belong to one exact shape revision. Coordinates are
`{x, y, z}` tuples, examples use millimeters, and modeling angles use degrees.
Mesh angular deflection uses radians.

OCEx covers the operations needed by Smith, not the full OCCT API. Calls run on
BEAM dirty schedulers and are serialized for predictable native ownership.
In-process native faults can crash the VM, and kernel operations cannot be
forcibly cancelled by terminating an Elixir process. Read
[errors and lifetimes](guides/errors-and-lifetimes.md) before integrating a service.

## Documentation and development

- [Installation and deployment](guides/installation.md)
- [Geometry and exchange](guides/native-geometry.md)
- [Errors, ownership, and execution](guides/errors-and-lifetimes.md)
- [Changelog](CHANGELOG.md)
- [Repository and test workflow](https://github.com/ntodd/ocex)

The suite exercises the real kernel with analytic measurements, topology checks,
file round trips, invalid inputs, resource lifetimes, and concurrency. The source
installer pins and checksums OCCT; release checks build isolated consumers from
package archives.

OCEx is MIT licensed. Open CASCADE Technology has its own license and exception.
The installer applies a documented allocator-alignment patch to OCCT 7.9.3 and
keeps kernel exception checks enabled. Full OCCT sources and binaries are not
bundled in this package.

## Working on OCEx

This is a standalone repository. See [development](https://github.com/ntodd/ocex/blob/main/docs/development.md) for
local checks and [releasing](https://github.com/ntodd/ocex/blob/main/docs/releasing.md) for this package's release steps.
