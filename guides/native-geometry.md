# Native geometry

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
| Modeling   | `extrude/2`, `revolve/4`, `loft/1`, `compound/1`, `cut/2`, `fuse/2`, `common/2`                                                                               |
| Transforms | `translate/2`, `rotate/4`, `scale/2`                                                                                                                          |
| Finishing  | `fillet/3`, `chamfer/3`, `clean/1`                                                                                                                            |
| Topology   | `vertices/1`, `edges/1`, `wires/1`, `faces/1`, `shells/1`, `solids/1`, `shape_type/1`, `same?/2`                                                              |
| Inspection | `valid?/1`, `volume/1`, `area/1`, `length/1`, `center_of_mass/1`, `bounds/1`, `point/1`, `edge_info/1`, `face_info/1`, `edge_sample/2`, `distance_to_point/2` |
| Exchange   | `to_brep/1`, `from_brep/1`, `read_step/1`, `write_step/2`, `write_stl/2,3,4`, `mesh/1,2,3`, `version/0`                                                       |

`wire/1` joins ordered connected edges, including open wires. `face/1` requires a closed planar wire. `extrude/2` takes a planar face and a vector with nonzero normal displacement. `revolve/4` takes a face, axis origin, nonzero axis vector, and angle in `(0, 360]`. `loft/1` creates a ruled solid through at least two closed wires. `scale/2` scales uniformly about the world origin. `rotate/4` uses an explicit axis origin and vector. Fillets and chamfers take a body, a nonempty list of selected edges, and radius/distance.

`edge_info/1` returns type (`:line`, `:circle`, or `:other`), endpoints, length, parameter bounds, and optional line direction/circle radius. `face_info/1` returns type (`:plane`, `:cylinder`, `:sphere`, or `:other`), area centroid, UV bounds, optional radius, an orientation-adjusted normal for planar faces (outward when bounding a correctly oriented solid), and cylinder axis origin/direction. A missing field value is `nil`. `point/1` reads a vertex.

`mesh/3` accepts absolute linear deflection in model units (default 0.1) and angular deflection in radians (default 0.5). Both must exceed 1e-7. Its map contains tuple-valued `vertices`, zero-based `triangles`, `triangles_per_face`, and numeric OCCT `face_types`. Triangle winding is outward for oriented solids. Vertices are indexed per face and may repeat at face boundaries; the mesh is not welded. Mesh creation operates on a copy. `write_stl/4` accepts the same two deflections. STL output is binary. BREP output is OCCT's text format without a persistent construction history.

Writes return `{:ok, :ok}` and overwrite the requested file. They do not create parent directories. STEP exchange uses plain geometry rather than XCAF assembly/material metadata.

## Curves and cleanup

`arc(center, normal, x_direction, radius, start_degrees, sweep_degrees)` constructs a directed circular arc in an arbitrary plane. A negative sweep runs clockwise; its magnitude must be at most 360 degrees. The x direction is projected onto the plane by OCCT.

`spline(points, {start_tangent, end_tangent})` interpolates all supplied points using `GeomAPI_Interpolate`, with tolerance 1e-6, automatic chord-length parameters, and automatically scaled endpoint tangents. Omitting tangents leaves endpoints unconstrained. This API supports nonperiodic interpolation.

`clean(shape)` unifies same-domain faces and edges, including concatenation of compatible B-splines. It copies the input and assigns a new native selection identity. This is separate from Smith's BREP content hash, which might not change when the geometry is unchanged. Native Booleans leave cleanup explicit; Smith cleans `fuse`, `cut`, `common`, `fillet`, and `chamfer` results automatically. Its `hole` operation does not add that cleanup step.

`edge_sample(edge, fraction)` returns a point and directed unit tangent at a fraction of the curve parameter interval, not a fraction of arc length. `distance_to_point` measures distance to a shape; use its shells to measure boundary distance rather than distance to the solid interior.
