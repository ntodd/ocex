# Native geometry

## Curve projection

`OCEx.project(source, target, direction: {0,0,-1})` projects edges, wires,
or face boundaries onto target faces, shells, or solids. Parallel projection is
bidirectional and keeps all hits. Use `from: {x,y,z}` instead for conical
half-rays from that point through the source. Exactly one mode is required.

Results are world-coordinate wires clipped to target boundaries, including holes.
They are not filled faces or printable solids. A missed/failed source boundary
returns `:projection_failed`, including within source collections. Unsupported
topology and invalid options fail explicitly. Both inputs are copied before
kernel operations. To fill one closed planar wire, call `OCEx.face/1`.


## Extrusion extent

`OCEx.extrude(face, vector, both: true, taper: 5)` extrudes the full vector in
each direction. Positive taper removes material away from the starting profile:
outer walls narrow and holes widen. Angles are degrees, strictly between −90
and 90. Nonzero taper requires normal travel and planar/cylindrical prism walls;
unsupported surfaces or topology transitions fail. Faces in a compound stay
separate, and each symmetric pair joins into one solid.

`OCEx.extrude_until(face, direction, origin, normal)` normalizes the travel vector
and stops at the infinite plane defined by origin/normal. It supports oblique
travel and tilted caps, with straight untapered walls. The whole profile must
reach the target ahead. Touching/crossing targets return `:target_not_ahead`,
and parallel target/travel returns `:invalid_direction`. It does not search for
the next face of a target body. Both operations copy the source before construction.

## Values and units

All public geometry functions return `{:ok, value}` or `{:error, reason}`. Native failures produce a finite set of error atoms. Outputs are checked with OCCT's shape analyzer before being exposed. This check is supplemented by operation preconditions and analytic tests; it is not a proof that arbitrary geometry meets the caller's intent.

- Coordinates and vectors are `{x, y, z}` tuples of finite floats or signed 64-bit integers. Use one consistent length unit; examples and STEP defaults use millimeters. Angles are degrees.
- Boxes occupy `[0, x] × [0, y] × [0, z]`. Cylinders start at Z=0 along +Z. Spheres are centered at the origin. Circles lie in XY and return an edge.
- Most primitive lengths/radii must exceed 1e-7 model units. Cone radii may be nonnegative, with a difference greater than 1e-7; one may be zero. Spline consecutive points must be more than 1e-6 apart. See each function for its preconditions.
- `OCEx.Shape` contains an opaque garbage-collected native resource. Operations preserve their inputs. Persist through BREP/STEP, not Erlang term serialization of resource handles.
- Selected edges must come from the exact body revision supplied to a fillet/chamfer. Foreign, stale, and duplicate selections fail. Re-query edges after a modeling operation.
- `same?/2` compares native topology identity and placement, ignoring orientation. It does not compare geometric equality. Repeated extraction creates different resource handles for the same native subshape; use `same?/2` rather than struct equality to compare them.
- Boolean operations may return a compound or an empty compound. Inspect `solids/1` instead of assuming a single solid. Empty shape bounds and volume centroid return `:empty_shape`.
- `volume/1` and `center_of_mass/1` consider closed volumes. `area/1` and `length/1` count shared faces/edges once. Coincident but independently created topology is not deduplicated geometrically.

## API

| Area       | Functions                                                                                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primitives | `box/3`, `cylinder/2`, `sphere/1`, `cone/3`                                                                                                                   |
| Profiles   | `edge/2`, `circle/1`, `arc/6`, `spline/1,2`, `wire/1`, `face/1`                                                                                               |
| Modeling   | `extrude/2`, `revolve/4`, `loft/2`, `sweep/3`, `shell/4`, `split/4`, `section/3`, `draft/6`, `sew/1`, `offset/3`, `thicken/3`, `compound/1`, `cut/2`, `fuse/2`, `common/2`                                                                               |
| Transforms | `translate/2`, `rotate/4`, `scale/2`                                                                                                                          |
| Finishing  | `fillet/3`, `chamfer/3`, `clean/1`                                                                                                                            |
| Topology   | `vertices/1`, `edges/1`, `wires/1`, `faces/1`, `shells/1`, `solids/1`, `shape_type/1`, `same?/2`                                                              |
| Inspection | `valid?/1`, `volume/1`, `area/1`, `length/1`, `center_of_mass/1`, `bounds/1`, `point/1`, `edge_info/1`, `face_info/1`, `edge_sample/2`, `distance_to_point/2` |
| Exchange   | `to_brep/1`, `from_brep/1`, `read_step/1`, `write_step/2`, `write_stl/2,3,4`, `mesh/1,2,3`, `version/0`                                                       |

`wire/1` joins ordered connected edges, including open wires. `face/1` requires a closed planar wire. `extrude/2` takes a planar face and a vector with nonzero normal displacement. `revolve/4` takes a face, axis origin, nonzero axis vector, and angle in `(0, 360]`. `loft/2` creates a solid through at least two closed wires; `ruled: true` is the default, while `ruled: false` enables smooth interpolation. `scale/2` scales uniformly about the world origin. `rotate/4` uses an explicit axis origin and vector. Fillets and chamfers take a body, a nonempty list of selected edges, and radius/distance.

`edge_info/1` returns type (`:line`, `:circle`, or `:other`), endpoints, length, parameter bounds, and optional line direction/circle radius. `face_info/1` returns type (`:plane`, `:cylinder`, `:sphere`, or `:other`), area centroid, UV bounds, optional radius, an orientation-adjusted normal for planar faces (outward when bounding a correctly oriented solid), and cylinder axis origin/direction. A missing field value is `nil`. `point/1` reads a vertex.

`mesh/3` accepts absolute linear deflection in model units (default 0.1) and angular deflection in radians (default 0.5). Both must exceed 1e-7. Its map contains tuple-valued `vertices`, zero-based `triangles`, `triangles_per_face`, and numeric OCCT `face_types`. Triangle winding is outward for oriented solids. Vertices are indexed per face and may repeat at face boundaries; the mesh is not welded. Mesh creation operates on a copy. `write_stl/4` accepts the same two deflections. STL output is binary. BREP output is OCCT's text format without a persistent construction history.

Writes return `{:ok, :ok}` and overwrite the requested file. They do not create parent directories. STEP exchange uses plain geometry rather than XCAF assembly/material metadata.

## Curves and cleanup

`arc(center, normal, x_direction, radius, start_degrees, sweep_degrees)` constructs a directed circular arc in an arbitrary plane. A negative sweep runs clockwise; its magnitude must be at most 360 degrees. The x direction is projected onto the plane by OCCT.

`spline(points, {start_tangent, end_tangent})` interpolates all supplied points using `GeomAPI_Interpolate`, with tolerance 1e-6, automatic chord-length parameters, and automatically scaled endpoint tangents. Omitting tangents leaves endpoints unconstrained. This API supports nonperiodic interpolation.

`clean(shape)` unifies same-domain faces and edges, including concatenation of compatible B-splines. It copies the input and assigns a new native selection identity. This is separate from Smith's BREP content hash, which might not change when the geometry is unchanged. Native Booleans leave cleanup explicit; Smith cleans `fuse`, `cut`, `common`, `fillet`, and `chamfer` results automatically. Its `hole` operation does not add that cleanup step.

`edge_sample(edge, fraction)` returns a point and directed unit tangent at a fraction of the curve parameter interval, not a fraction of arc length. `distance_to_point` measures distance to a shape; use its shells to measure boundary distance rather than distance to the solid interior.

## Smooth loft, sweep, and shell

All three operations copy their inputs before construction. They return valid native solids or tagged errors; successful BREP validation is not a general self-intersection proof.

```elixir
{:ok, edge} = OCEx.circle(2)
{:ok, section} = OCEx.wire([edge])
{:ok, line} = OCEx.edge({0, 0, 0}, {0, 0, 10})
{:ok, path} = OCEx.wire([line])
{:ok, rod} = OCEx.sweep(section, path)
{:ok, volume} = OCEx.volume(rod)
true = abs(volume - 40 * :math.pi()) < 1.0e-6
{:ok, end_section} = OCEx.translate(section, {0, 0, 10})
{:ok, loft} = OCEx.loft([section, end_section], ruled: false)
```

A sweep takes a closed planar section wire and an open, nonbranching path wire. The section plane must pass through the path's starting vertex and be perpendicular to its starting tangent. Its in-plane offset is retained. `frame:` selects `:corrected` or `:frenet`; `transition:` selects `:transformed`, `:right`, or `:round`. See `OCEx.sweep/3` for corner behavior and limits.

```elixir
{:ok, blank} = OCEx.box(20, 16, 10)
{:ok, faces} = OCEx.faces(blank)
openings = Enum.filter(faces, fn face ->
  match?({:ok, %{normal: {_, _, z}}} when z > 0.99, OCEx.face_info(face))
end)
{:ok, tray} = OCEx.shell(blank, openings, -2)
{:ok, volume} = OCEx.volume(tray)
true = abs(volume - 1664) < 1.0e-6
```

Shell openings must belong to the supplied solid revision. Duplicates and foreign faces are rejected before construction. Negative thickness builds inward; positive builds outward. `join: :arc` is the default; `:intersection` extends neighboring surfaces. Inward results must remove material and remain inside the source within the volume tolerance documented in `OCEx.shell/4`. Shelling requires openings; sealed cavities are not supported by this operation. Use `offset/3` for normal offsets and `thicken/3` for open surfaces.

## Torus and reflection

A ring torus is centered at world zero around Z. Its major radius reaches the tube center; its minor radius is the tube radius. Both radii and their difference must exceed 1.0e-7 mm. A mirror plane is defined by a world point and a nonzero normal, which OCEx normalizes. Reflection supports edges, faces, solids, and compounds, and returns an independent revision.

```elixir
{:ok, ring} = OCEx.torus(10, 2)
{:ok, mirrored} = OCEx.mirror(ring, {5, 0, 0}, {1, 0, 0})
{:ok, volume} = OCEx.volume(mirrored)
true = abs(volume - 80 * :math.pi() * :math.pi()) < 1.0e-6
```

The reflected solid retains outward orientation. Planar face normals are derived from the transformed surface's X/Y directions and face orientation; this also handles reflected surfaces whose coordinate frame is indirect. Re-query topology on the reflected body before using it in a finishing operation.


## Plane cuts and surface operations

Split a solid at a plane, retaining either signed side or both solids. Section
returns filled planar faces with holes; disconnected regions remain separate.
Positive means toward the normalized plane normal. A missed section returns an
empty compound, while point and edge tangencies produce no faces.

```elixir
{:ok, blank} = OCEx.box(20, 16, 10)
{:ok, lower} = OCEx.split(blank, {0, 0, 6}, {0, 0, 1}, keep: :negative)
{:ok, section} = OCEx.section(blank, {0, 0, 6}, {0, 0, 1})
{:ok, cap} = OCEx.extrude(section, {0, 0, 2})
{:ok, measured_volume} = OCEx.volume(lower)
true = abs(measured_volume - 1920) < 1.0e-6
{:ok, measured_volume} = OCEx.volume(cap)
true = abs(measured_volume - 640) < 1.0e-6
```

Draft selected planar, cylindrical, or conical faces using a pull direction,
angle in degrees, and neutral plane. Selections must belong to the supplied
revision. Tangent-connected faces may also change. A positive angle removes
material on the pull side. Collapsing faces can fail.

```elixir
{:ok, faces} = OCEx.faces(blank)
sides = Enum.filter(faces, fn face ->
  {:ok, info} = OCEx.face_info(face)
  abs(elem(info.normal, 2)) < 0.01
end)
{:ok, drafted} = OCEx.draft(blank, sides, {0, 0, 1}, 5, {0, 0, 0}, {0, 0, 1})
{:ok, true} = OCEx.valid?(drafted)

{:ok, surface} = OCEx.sew([hd(sides)])
{:ok, shifted} = OCEx.offset(surface, 2)
{:ok, wall} = OCEx.thicken(shifted, 1)
{:ok, true} = OCEx.valid?(wall)
```

Sewing copies faces and joins coincident boundaries at the kernel's 1.0e-7 mm
tolerance. Supply coherent orientations. Disconnected regions remain separate;
non-manifold edges are rejected. Sewing does not fill a shell into a solid.

Offset moves faces along their normals; on a solid it expands or contracts its
boundary. It does not offset a planar outline within its plane. Thickening closes
a face or open shell into a solid and rejects existing solids or closed shells.
Both accept signed distances greater than 1.0e-7 mm in magnitude. Offset defaults
to `join: :arc`, thickening to `:intersection`; either accepts both joins.
Compound members are processed independently without fusion. Surface regularity,
narrow gaps, and large distances can prevent construction. Self-intersection
repair is disabled, and a successful validity check does not rule out every
self-intersection. See each function's API reference for input types and errors.


## Orthographic drawings and sampled curves

`OCEx.drawing/5` returns visible and hidden edge collections in view-local XY at
Z=0. The normal points toward the viewer. X is projected into the plane; Y is
normal cross X. HLR runs on a copy of the BREP and includes sharp boundaries
and silhouettes. `tangents: true` adds G1 boundaries; seams and isoparametric
lines are excluded. An empty layer is an empty compound.

```elixir
{:ok, sphere} = OCEx.sphere(5)
{:ok, drawing} = OCEx.drawing(sphere, {0, 0, 0}, {0, 0, 1}, {1, 0, 0})
{:ok, length} = OCEx.length(drawing.visible)
true = abs(length - 10 * :math.pi()) < 1.0e-6
{:ok, points} = OCEx.polylines(drawing.visible, 0.01, 0.1)
true = points != []
```

`polylines/3` samples each topological edge independently with OCCT tangential
deflection. Its arguments are linear deflection in model units and angular
deflection in radians. It preserves endpoint order and closed-edge repetition;
it does not stitch wires or merge coincident projections. Arbitrary spline
sampling is not a certified global distance bound. Smith handles SVG/DXF units,
line styles, and file serialization.
