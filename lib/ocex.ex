defmodule OCEx do
  @moduledoc """
  Native geometry operations backed by Open CASCADE Technology (OCCT).

  Calls run immediately and return `{:ok, value}` or `{:error, reason}`.
  Modeling operations return an opaque `OCEx.Shape`; query functions return
  measurements, topology, or mesh data. Inputs remain usable after an operation.

  ## Coordinates and numbers

  Points and vectors are `{x, y, z}` tuples. Use millimeters when working with
  Smith or STEP exchange. Pure geometry operations use the numbers supplied;
  shapes do not carry a unit tag. Modeling angles are degrees, while mesh
  angular deflection is in radians.

  The native boundary accepts finite floats and signed 64-bit integers.
  Most positive dimensions and direction magnitudes must exceed 1.0e-7.
  Each operation documents further restrictions.

  ## Shape ownership

  Shapes are garbage-collected native resources. Extract edges with `edges/1`
  from the body you intend to fillet or chamfer. Every modeling operation
  creates a new selection identity, even if the resulting geometry looks
  unchanged. A BREP round trip also creates a new identity.

  For pipeline-based recipes, sketches, assemblies, and print bundles, use
  [Smith](https://hexdocs.pm/smith). For native setup and execution limits, read
  [installation](installation.html) and [errors and lifetimes](errors-and-lifetimes.html).
  """
  @moduledoc groups: [
               "Primitives",
               "Profiles",
               "Modeling",
               "Transforms",
               "Topology",
               "Measurements",
               "Exchange",
               "Toolkit"
             ]
  alias OCEx.Shape
  @type point3 :: {number(), number(), number()}
  @typedoc "A point or vector returned by the native kernel."
  @type vector3 :: {float(), float(), float()}
  @type bounds3 :: {vector3(), vector3()}
  @type edge_info :: %{
          type: :line | :circle | :other,
          start: vector3(),
          end: vector3(),
          length: float(),
          direction: vector3() | nil,
          radius: float() | nil,
          parameter_bounds: {float(), float()}
        }
  @type face_info :: %{
          type: :plane | :cylinder | :sphere | :other,
          area: float(),
          center: vector3(),
          normal: vector3() | nil,
          radius: float() | nil,
          axis_origin: vector3() | nil,
          axis_direction: vector3() | nil,
          uv_bounds: {float(), float(), float(), float()}
        }
  @type mesh :: %{
          vertices: [vector3()],
          triangles: [{non_neg_integer(), non_neg_integer(), non_neg_integer()}],
          triangles_per_face: [non_neg_integer()],
          face_types: [non_neg_integer()]
        }
  @type result(value) :: {:ok, value} | {:error, atom()}

  @doc """
  Creates a box with its minimum corner at the origin.

  The dimensions are its X, Y, and Z extents. Each must exceed 1.0e-7 model
  units. The result is a solid; negative dimensions do not reverse its direction.
  Use `translate/2` to move it.

  ## Examples

      iex> {:ok, box} = OCEx.box(10, 20, 3)
      iex> {:ok, volume} = OCEx.volume(box)
      iex> Float.round(volume, 6)
      600.0
      iex> OCEx.box(10, 20, 0)
      {:error, :invalid_argument}
  """
  @doc group: "Primitives"
  @spec box(number(), number(), number()) :: result(Shape.t())
  def box(x, y, z), do: shape(:box, [x, y, z])

  @doc """
  Creates a solid cylinder centered on world Z, from Z=0 to `height`.

  `radius` and `height` must each exceed 1.0e-7 model units. Its X and Y bounds
  are `-radius..radius`. Use `rotate/4` for another axis.
  """
  @doc group: "Primitives"
  @spec cylinder(number(), number()) :: result(Shape.t())
  def cylinder(radius, height), do: shape(:cylinder, [radius, height])

  @doc """
  Creates a solid sphere centered at the origin.

  `radius` must exceed 1.0e-7 model units.
  """
  @doc group: "Primitives"
  @spec sphere(number()) :: result(Shape.t())
  def sphere(radius), do: shape(:sphere, [radius])

  @doc """
  Creates a cone or frustum centered on world Z.

  `bottom` is the radius at Z=0; `top` is the radius at Z=`height`.
  Both radii must be nonnegative and differ by more than 1.0e-7 model units.
  One radius may be zero. `height` must exceed 1.0e-7. Use `cylinder/2`
  when the radii are equal.
  """
  @doc group: "Primitives"
  @spec cone(number(), number(), number()) :: result(Shape.t())
  def cone(bottom, top, height), do: shape(:cone, [bottom, top, height])

  @doc """
  Creates a straight edge from `from` to `to`, in world coordinates.

  The points must be separated by more than 1.0e-7 model units. The edge is
  directed from the first point to the second; `edge_info/1` and
  `edge_sample/2` respect that direction.
  """
  @doc group: "Profiles"
  @spec edge(point3(), point3()) :: result(Shape.t())
  def edge(from, to), do: shape(:edge, [from, to])

  @doc """
  Creates a full circular edge in XY, centered at the origin.

  `radius` must exceed 1.0e-7 model units. To make a disk, wrap the edge in
  a wire and then a face:

      iex> {:ok, circle} = OCEx.circle(3)
      iex> {:ok, wire} = OCEx.wire([circle])
      iex> {:ok, disk} = OCEx.face(wire)
      iex> OCEx.shape_type(disk)
      {:ok, :face}
  """
  @doc group: "Profiles"
  @spec circle(number()) :: result(Shape.t())
  def circle(radius), do: shape(:circle, [radius])

  @doc """
  Creates a directed circular arc in a world-coordinate plane.

  `center` is the circle center. `normal` and `x_direction` define its
  frame: they must be nonzero and nonparallel. OCCT projects `x_direction`
  onto the plane. The start angle is measured from that projected direction.

  `start` and `sweep` are degrees. Positive sweep follows the right-hand
  rule around `normal`; negative sweep reverses it. The absolute sweep must
  be greater than 1.0e-9 and at most 360. The radius must exceed 1.0e-7 model
  units. Returns an edge, including for a full turn.
  """
  @doc group: "Profiles"
  @spec arc(point3(), point3(), point3(), number(), number(), number()) :: result(Shape.t())
  def arc(center, normal, x_direction, radius, start, sweep),
    do: shape(:arc, [center, normal, x_direction, radius, start, sweep])

  @doc """
  Interpolates a nonperiodic B-spline through ordered world points.

  Supply 2 to 100,000 points. Consecutive points must be more than 1.0e-6
  model units apart. OCCT uses chord-length parameters and an interpolation
  tolerance of 1.0e-6.

  `tangents` is either `nil` (unconstrained endpoints) or
  `{start_tangent, end_tangent}`. Each tangent is a nonzero world vector;
  OCCT scales its magnitude. Returns an edge, not a control-point polygon.
  """
  @doc group: "Profiles"
  @spec spline([point3()], {point3(), point3()} | nil) :: result(Shape.t())
  def spline(points, tangents \\ nil), do: shape(:spline, [points, tangents])

  @doc """
  Merges adjacent faces and edges that share underlying geometry.

  This includes concatenating compatible B-splines. Returns a new native
  resource even when no simplification is possible. It can change edge and
  face counts, so query selections from the returned shape.

  Boolean operations in OCEx do not call this automatically.
  """
  @doc group: "Modeling"
  @spec clean(Shape.t()) :: result(Shape.t())
  def clean(body), do: shape(:clean, [ref(body)])

  @doc """
  Samples a directed edge at a fraction of its parameter interval.

  `fraction` must be between 0 and 1 inclusive. Returns
  `{:ok, %{point: {x, y, z}, tangent: {dx, dy, dz}}}`, with a unit tangent
  following the edge orientation. Fractions 0 and 1 correspond to the
  `:start` and `:end` in `edge_info/1`.

  Parameter spacing need not be uniform in distance: 0.5 is not necessarily
  halfway along a spline's length. A degenerate derivative returns
  `{:error, :undefined_tangent}`.

      iex> {:ok, edge} = OCEx.edge({0, 0, 0}, {10, 0, 0})
      iex> OCEx.edge_sample(edge, 0.25)
      {:ok, %{point: {2.5, 0.0, 0.0}, tangent: {1.0, 0.0, 0.0}}}
  """
  @doc group: "Measurements"
  @spec edge_sample(Shape.t(), number()) :: result(%{point: vector3(), tangent: vector3()})
  def edge_sample(edge, fraction), do: call(:edge_sample, [ref(edge), fraction])

  @doc """
  Measures the minimum distance between a shape and a world point.

  A point inside a solid has distance zero. To measure distance to its
  boundary, query `shells/1` and measure against the shells instead.
  The returned distance uses the shape's length unit.

      iex> {:ok, box} = OCEx.box(2, 2, 2)
      iex> OCEx.distance_to_point(box, {1, 1, 1})
      {:ok, 0.0}
      iex> OCEx.distance_to_point(box, {5, 1, 1})
      {:ok, 3.0}
  """
  @doc group: "Measurements"
  @spec distance_to_point(Shape.t(), point3()) :: result(float())
  def distance_to_point(body, point), do: call(:distance_to_point, [ref(body), point])

  @doc """
  Joins a nonempty list of edges into a wire.

  Supply edges in connected order. Each added edge must connect to the
  wire built so far; otherwise the call returns `{:error, :disconnected_wire}`.
  Open wires are allowed. The result need not be planar, but `face/1`
  requires a closed planar boundary.
  """
  @doc group: "Profiles"
  @spec wire([Shape.t()]) :: result(Shape.t())
  def wire(edges), do: shape(:wire, [refs(edges)])

  @doc """
  Builds one planar face bounded by a closed wire.

  An open wire returns `{:error, :open_wire}`. A nonplanar or invalid
  boundary fails during construction or shape validation. This constructor
  accepts one outer wire; use Boolean subtraction to add holes.
  """
  @doc group: "Profiles"
  @spec face(Shape.t()) :: result(Shape.t())
  def face(wire), do: shape(:face, [ref(wire)])

  @doc """
  Extrudes a planar face along a world vector.

  The vector may be oblique to the face, but its normal component must
  exceed 1.0e-7 model units in magnitude. A vector lying in the face's plane
  returns `{:error, :degenerate_extrusion}`; a nonplanar face returns
  `{:error, :non_planar_profile}`. Face holes pass through the extrusion.
  The result is a solid.
  """
  @doc group: "Modeling"
  @spec extrude(Shape.t(), point3()) :: result(Shape.t())
  def extrude(face, vector), do: shape(:extrude, [ref(face), vector])

  @doc """
  Revolves a face around a world axis.

  `origin` is a point on the axis; `axis` is its nonzero direction vector.
  `degrees` must be greater than 1.0e-7 and at most 360. Rotation follows
  the right-hand rule; reverse the axis for the opposite turn.

  The profile and sweep must form valid geometry. This binding validates
  the returned shape but does not separately assert a single positive-volume
  solid. Inspect `solids/1` and `volume/1` when that is required.
  """
  @doc group: "Modeling"
  @spec revolve(Shape.t(), point3(), point3(), number()) :: result(Shape.t())
  def revolve(face, origin, axis, degrees),
    do: shape(:revolve, [ref(face), origin, axis, degrees])

  @doc """
  Builds a capped, ruled loft through at least two closed wires.

  List sections in loft order. Each wire supplies one boundary; holes,
  guide rails, seam controls, and smooth interpolation are not supported.
  OCCT determines correspondence between section edges. An open section
  returns `{:error, :open_wire}`. Degenerate section arrangements may fail
  kernel construction or validation.
  """
  @doc group: "Modeling"
  @spec loft([Shape.t()]) :: result(Shape.t())
  def loft(wires), do: shape(:loft, [refs(wires)])

  @doc """
  Copies shapes into a compound without joining their boundaries.

  The list may mix topology kinds or be empty. Overlapping solids retain
  their individual volumes and faces; use `fuse/2` to combine material.

      iex> {:ok, empty} = OCEx.compound([])
      iex> OCEx.solids(empty)
      {:ok, []}
      iex> OCEx.bounds(empty)
      {:error, :empty_shape}
  """
  @doc group: "Modeling"
  @spec compound([Shape.t()]) :: result(Shape.t())
  def compound(shapes), do: shape(:compound, [refs(shapes)])

  @doc """
  Subtracts `tool` from `body`, preserving both inputs.

  A missed tool can leave the geometry unchanged; removing the entire
  body can return an empty compound. The result is not guaranteed to be
  a single solid. Call `clean/1` to merge same-domain faces afterward.
  """
  @doc group: "Modeling"
  @spec cut(Shape.t(), Shape.t()) :: result(Shape.t())
  def cut(body, tool), do: shape(:cut, [ref(body), ref(tool)])

  @doc """
  Unites two shapes, preserving both inputs.

  Disjoint solids remain separate solids in the result. Touching or
  overlapping solids are combined where the Boolean algorithm permits.
  Call `clean/1` explicitly to merge same-domain faces and edges.
  """
  @doc group: "Modeling"
  @spec fuse(Shape.t(), Shape.t()) :: result(Shape.t())
  def fuse(body, tool), do: shape(:fuse, [ref(body), ref(tool)])

  @doc """
  Returns the geometric intersection of two shapes.

  Disjoint inputs produce an empty compound. A successful result can have
  zero volume; query its topology before using it as a solid. Neither input
  is changed, and same-domain cleanup is left to `clean/1`.
  """
  @doc group: "Modeling"
  @spec common(Shape.t(), Shape.t()) :: result(Shape.t())
  def common(body, tool), do: shape(:common, [ref(body), ref(tool)])

  @doc """
  Returns a copy translated by a world-coordinate vector.

  A zero vector is allowed. Selections from the input cannot be used to
  fillet or chamfer the copy.
  """
  @doc group: "Transforms"
  @spec translate(Shape.t(), point3()) :: result(Shape.t())
  def translate(body, vector), do: shape(:translate, [ref(body), vector])

  @doc """
  Returns a copy rotated about a world axis, in degrees.

  `origin` is a point on the axis and `axis` is a nonzero vector.
  Positive angles follow the right-hand rule; negative and zero angles are
  allowed. Rotation moves the whole shape, including its position relative
  to `origin`.
  """
  @doc group: "Transforms"
  @spec rotate(Shape.t(), point3(), point3(), number()) :: result(Shape.t())
  def rotate(body, origin, axis, degrees), do: shape(:rotate, [ref(body), origin, axis, degrees])

  @doc """
  Returns a copy uniformly scaled about the world origin.

  `factor` must exceed 1.0e-7. Positions and lengths scale by this factor,
  areas by its square, and volumes by its cube. Negative factors and
  nonuniform scaling are not supported.
  """
  @doc group: "Transforms"
  @spec scale(Shape.t(), number()) :: result(Shape.t())
  def scale(body, factor), do: shape(:scale, [ref(body), factor])

  @doc """
  Rounds a nonempty selection of edges with a common radius.

  `radius` must exceed 1.0e-7 model units. Obtain the edges from this exact
  `body` using `edges/1`. Stale or foreign edges return
  `:foreign_subshape`; repeated selections return `:duplicate_subshape`.
  An empty selection returns `:invalid_argument`.

  The kernel may reject a radius that cannot fit the surrounding geometry.
  Inputs remain unchanged. Call `clean/1` if further topology simplification
  is needed.
  """
  @doc group: "Modeling"
  @spec fillet(Shape.t(), [Shape.t()], number()) :: result(Shape.t())
  def fillet(body, edges, radius), do: shape(:fillet, [ref(body), refs(edges), radius])

  @doc """
  Bevels a nonempty selection of edges with a common distance.

  `distance` must exceed 1.0e-7 model units. This is an equal-distance
  chamfer; angle/distance and two-distance variants are not exposed.
  Selections have the same ownership and duplicate checks as `fillet/3`.
  The kernel may reject a distance that does not fit the adjoining faces.
  """
  @doc group: "Modeling"
  @spec chamfer(Shape.t(), [Shape.t()], number()) :: result(Shape.t())
  def chamfer(body, edges, distance), do: shape(:chamfer, [ref(body), refs(edges), distance])

  @doc """
  Returns the top-level topology kind.

  Possible kinds are `:compound`, `:compsolid`, `:solid`, `:shell`,
  `:face`, `:wire`, `:edge`, `:vertex`, and `:shape`. A compound may
  contain one or many solids; use `solids/1` to count them.
  """
  @doc group: "Topology"
  @spec shape_type(Shape.t()) :: result(atom())
  def shape_type(body), do: call(:shape_type, [ref(body)])

  @doc """
  Compares native topology identity and location, ignoring orientation.

  This uses OCCT's `IsSame` comparison. It does not compare dimensions or
  boundary geometry. Independently constructed equal boxes are different;
  two queries for the same subshape can be the same despite having distinct
  Elixir resource handles.

      iex> {:ok, a} = OCEx.box(1, 2, 3)
      iex> {:ok, b} = OCEx.box(1, 2, 3)
      iex> OCEx.same?(a, a)
      {:ok, true}
      iex> OCEx.same?(a, b)
      {:ok, false}
  """
  @doc group: "Topology"
  @spec same?(Shape.t(), Shape.t()) :: result(boolean())
  def same?(a, b), do: call(:same, [ref(a), ref(b)])

  @doc """
  Runs OCCT's shape analyzer and returns a boolean result.

  New shapes exposed by OCEx already pass this check. Validity describes
  kernel topology and geometry consistency; an empty compound or an edge
  can be valid. It does not establish solid count, dimensions, clearance,
  mesh quality, or printability.
  """
  @doc group: "Topology"
  @spec valid?(Shape.t()) :: result(boolean())
  def valid?(body), do: call(:valid, [ref(body)])

  @doc """
  Measures signed volume from closed shells, in cubic model units.

  Shared topology is counted once. Independent overlapping solids in a
  compound are not Boolean-unioned before measurement. Edges, open faces,
  and empty compounds can return zero; use `solids/1` as well when checking
  for a solid model.
  """
  @doc group: "Measurements"
  @spec volume(Shape.t()) :: result(float())
  def volume(body), do: call(:volume, [ref(body)])

  @doc """
  Measures the sum of face areas, in square model units.

  Shared faces are counted once by topology identity. Independently created
  coincident faces still contribute separately. For a solid, this includes
  both outer faces and faces bounding cavities.
  """
  @doc group: "Measurements"
  @spec area(Shape.t()) :: result(float())
  def area(body), do: call(:area, [ref(body)])

  @doc """
  Measures the sum of edge lengths, in model units.

  Shared edges are counted once by topology identity. This is the total
  topological edge length, not a body's perimeter in a chosen projection.
  """
  @doc group: "Measurements"
  @spec length(Shape.t()) :: result(float())
  def length(body), do: call(:length, [ref(body)])

  @doc """
  Returns the volume centroid in world coordinates.

  Uses closed-shell volume properties with uniform density. Zero-volume
  inputs, including a standalone face or empty compound, return
  `{:error, :empty_shape}`. For a face's area centroid use `face_info/1`.
  The centroid need not lie inside the material.
  """
  @doc group: "Measurements"
  @spec center_of_mass(Shape.t()) :: result(vector3())
  def center_of_mass(body), do: call(:center_of_mass, [ref(body)])

  @doc """
  Returns world-axis-aligned bounds as `{:ok, {minimum, maximum}}`.

  Each corner is a world point. OCCT calculates these bounds from geometry,
  without using a display mesh or adding shape tolerances. Curved geometry
  is still subject to numerical approximation; compare bounds with a
  tolerance rather than treating them as exact symbolic values.

  Empty shapes return `{:error, :empty_shape}`.
  """
  @doc group: "Measurements"
  @spec bounds(Shape.t()) :: result(bounds3())
  def bounds(body), do: call(:bounds, [ref(body)])

  @doc """
  Describes an edge's curve and directed endpoints.

  The returned map always contains these keys:

  | Key | Value |
  | --- | --- |
  | `:type` | `:line`, `:circle`, or `:other` (including splines) |
  | `:start`, `:end` | World points in edge traversal order |
  | `:length` | Curve length in model units |
  | `:direction` | Directed unit vector for a line; otherwise `nil` |
  | `:radius` | Radius for a circle or circular arc; otherwise `nil` |
  | `:parameter_bounds` | Underlying curve's `{first, last}` parameters |

  Reversed edges swap endpoints and reverse line direction; parameter bounds
  remain in underlying curve order. Non-edge inputs return `:wrong_shape_type`.
  """
  @doc group: "Measurements"
  @spec edge_info(Shape.t()) :: result(edge_info())
  def edge_info(edge), do: call(:edge_info, [ref(edge)])

  @doc """
  Describes a face's surface and area properties.

  The returned map always contains these keys:

  | Key | Value |
  | --- | --- |
  | `:type` | `:plane`, `:cylinder`, `:sphere`, or `:other` |
  | `:area` | Trimmed face area in square model units |
  | `:center` | Area centroid in world coordinates |
  | `:uv_bounds` | `{u_min, u_max, v_min, v_max}` in surface parameters |
  | `:normal` | Orientation-adjusted unit plane normal; otherwise `nil` |
  | `:radius` | Cylinder or sphere radius; otherwise `nil` |
  | `:axis_origin`, `:axis_direction` | Cylinder axis point and unit direction; otherwise `nil` |

  A correctly oriented solid's planar normal points out of the material.
  A standalone face has its own orientation, with no solid interior to define
  "outward". A curved face's centroid need not lie on its surface.
  Non-face inputs return `:wrong_shape_type`.
  """
  @doc group: "Measurements"
  @spec face_info(Shape.t()) :: result(face_info())
  def face_info(face), do: call(:face_info, [ref(face)])

  @doc """
  Returns the world coordinates of a vertex.

  Use `vertices/1` to extract vertices from a body. Other topology kinds
  return `{:error, :wrong_shape_type}`.
  """
  @doc group: "Measurements"
  @spec point(Shape.t()) :: result(vector3())
  def point(vertex), do: call(:point, [ref(vertex)])

  @doc """
  Tessellates a copy of a shape into indexed triangles.

  `tolerance` is absolute linear deflection in model units (default 0.1).
  `angular_tolerance` is angular deflection in radians (default 0.5).
  Both must exceed 1.0e-7. Lower values generally produce more triangles;
  they do not offset or change the original boundary geometry.

  Returns a map with:

    * `:vertices` — a list of world `{x, y, z}` points.
    * `:triangles` — a list of zero-based `{a, b, c}` vertex indices.
    * `:triangles_per_face` — triangle counts in face traversal order.
    * `:face_types` — OCCT surface-type integers in the same face order.

  Vertices are separate per face and may coincide at boundaries. Winding
  follows face orientation. The mesh is not welded or checked for closed
  topology, and a shape without faces can produce empty lists.

      iex> {:ok, box} = OCEx.box(2, 3, 4)
      iex> {:ok, mesh} = OCEx.mesh(box)
      iex> length(mesh.triangles)
      12
      iex> Enum.sum(mesh.triangles_per_face)
      12
  """
  @doc group: "Exchange"
  @spec mesh(Shape.t(), number(), number()) :: result(mesh())
  def mesh(body, tolerance \\ 0.1, angular_tolerance \\ 0.5),
    do: call(:mesh, [ref(body), tolerance, angular_tolerance])

  @doc """
  Serializes a shape to OCCT text BREP in a binary.

  BREP stores geometry and topology, not the Elixir construction recipe.
  No file is written. Retain the recipe for editing, and use this function
  or STEP for persistence instead of serializing resource handles.

      iex> {:ok, box} = OCEx.box(2, 3, 4)
      iex> {:ok, bytes} = OCEx.to_brep(box)
      iex> {:ok, restored} = OCEx.from_brep(bytes)
      iex> {:ok, volume} = OCEx.volume(restored)
      iex> Float.round(volume, 6)
      24.0
  """
  @doc group: "Exchange"
  @spec to_brep(Shape.t()) :: result(binary())
  def to_brep(body), do: call(:to_brep, [ref(body)])

  @doc """
  Reads OCCT text BREP from a binary into a new native resource.

  Malformed or truncated input can return `:invalid_brep`; decoded
  invalid topology returns `:invalid_shape`. Kernel exceptions use the
  errors described in the [error guide](errors-and-lifetimes.html).
  This is an in-process parser, not an isolation boundary for untrusted files.
  """
  @doc group: "Exchange"
  @spec from_brep(binary()) :: result(Shape.t())
  def from_brep(binary), do: shape(:from_brep, [binary])

  @doc """
  Imports geometry from a STEP file.

  `path` is a nonempty string without NUL bytes. Transferred roots are
  combined into one shape. File-read failures return `:io_error` and
  invalid transferred geometry returns `:invalid_shape`.

  Product names, assembly instances, colors, and materials are not exposed.
  The reader uses OCCT's default exchange units; use millimeters for models
  that will be exchanged through this API.
  """
  @doc group: "Exchange"
  @spec read_step(String.t()) :: result(Shape.t())
  def read_step(path), do: shape(:read_step, [path])

  @doc """
  Writes geometry-only STEP to a path, returning `{:ok, :ok}`.

  The parent directory must exist; an existing file is overwritten. `path`
  must be a nonempty string without NUL bytes. The writer uses OCCT's default
  exchange configuration. It does not preserve a named assembly product tree
  or reimport the file to check its contents.

  Transfer failures return `:operation_failed`; write failures return
  `:io_error`. For verified bundles use Smith's export API.
  """
  @doc group: "Exchange"
  @spec write_step(Shape.t(), String.t()) :: result(:ok)
  def write_step(body, path), do: call(:write_step, [ref(body), path])

  @doc """
  Writes binary STL from a tessellated copy, returning `{:ok, :ok}`.

  Deflections have the same meaning and defaults as `mesh/3`: 0.1 model
  units and 0.5 radians. Both must exceed 1.0e-7. Parent directories must
  exist, and an existing file is overwritten. Write failures return
  `:io_error`.

  STL does not record a unit. This function does not weld or verify the
  serialized mesh; Smith provides verified STL and 3MF export.
  """
  @doc group: "Exchange"
  @spec write_stl(Shape.t(), String.t(), number(), number()) :: result(:ok)
  def write_stl(body, path, tolerance \\ 0.1, angular_tolerance \\ 0.5),
    do: call(:write_stl, [ref(body), path, tolerance, angular_tolerance])

  @doc """
  Returns the version string of the linked Open CASCADE toolkit.

      iex> OCEx.version()
      {:ok, "7.9.3"}
  """
  @doc group: "Toolkit"
  @spec version() :: result(String.t())
  def version, do: call(:version, [])

  for kind <- [:vertices, :edges, :wires, :faces, :shells, :solids] do
    @doc """
    Returns unique #{kind} contained in the shape, including the shape itself if applicable.

    Returns `{:ok, shapes}`; no matches gives `{:ok, []}`. Uniqueness is
    by native topology identity and location, not geometric equivalence.
    List order is not a persistent naming scheme. Query again after each
    modeling operation, especially before selecting edges for finishing.
    """
    @doc group: "Topology"
    @spec unquote(kind)(Shape.t()) :: result([Shape.t()])
    def unquote(kind)(body) do
      case call(unquote(kind), [ref(body)]) do
        {:ok, refs} -> {:ok, Enum.map(refs, &%Shape{ref: &1})}
        error -> error
      end
    end
  end

  defp ref(%Shape{ref: ref}), do: ref
  defp ref(_), do: :invalid_shape
  defp refs([]), do: []

  defp refs([head | tail]) do
    case refs(tail) do
      :invalid_shapes -> :invalid_shapes
      rest -> [ref(head) | rest]
    end
  end

  defp refs(_), do: :invalid_shapes

  defp shape(op, args) do
    case call(op, args) do
      {:ok, ref} -> {:ok, %Shape{ref: ref}}
      error -> error
    end
  end

  defp call(op, args), do: OCEx.Native.call(op, args)
end
