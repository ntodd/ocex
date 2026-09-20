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
          center: vector3() | nil,
          axis: vector3() | nil,
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
  Creates a complete ring torus centered at the origin, around world Z.

  `major_radius` is the distance from the Z axis to the tube center;
  `minor_radius` is the tube radius, both in mm. Both radii and their
  difference must exceed 1.0e-7 mm. Horn and self-intersecting spindle
  tori return `:invalid_argument`. The torus extends from -minor_radius
  to +minor_radius in Z. Use transforms for other orientations.
  """
  @spec torus(number(), number()) :: result(Shape.t())
  def torus(major_radius, minor_radius), do: shape(:torus, [major_radius, minor_radius])

  @doc """
  Reflects a shape across the plane through `origin` with the given normal.

  Coordinates are world coordinates in mm. The normal is normalized and
  must be nonzero. Supports edges, faces, solids, and compounds. Returns
  an independent shape revision, preserving the input and outward solid
  orientation. It returns only the reflection; use `compound/1` or
  `fuse/2` to retain both copies. Malformed points or zero normals return
  `:invalid_argument`.
  """
  @spec mirror(Shape.t(), point3(), point3()) :: result(Shape.t())
  def mirror(body, origin, normal), do: shape(:mirror, [ref(body), origin, normal])

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
  Builds a polynomial Bézier edge from ordered world-space control points.

  Supply 2–26 finite `{x, y, z}` points (degree 1–25 in OCCT 7.9.3).
  The curve starts at the first point and ends at the last. Interior points
  control its shape; the curve generally does not pass through them. Its
  parameter interval is 0–1 and its geometry stays in their convex hull.
  Four points define a cubic. Weights and periodic curves are not supported.

  Repeated control points and coincident endpoints are allowed. All points
  within 1.0e-7 mm of the first, malformed points, and unsupported counts
  return `:invalid_argument`. Kernel construction can return `:operation_failed`.
  Repeated endpoint poles may yield a zero derivative, in which case
  `edge_sample/2` cannot return a unit tangent at that endpoint.

      iex> {:ok, edge} = OCEx.bezier([{0, 0, 0}, {1, 2, 0}, {2, 0, 0}])
      iex> {:ok, %{point: point}} = OCEx.edge_sample(edge, 0.5)
      iex> point
      {1.0, 1.0, 0.0}
  """
  @doc group: "Curves and topology"
  @spec bezier([point3()]) :: result(Shape.t())
  def bezier(points), do: shape(:bezier, [points])

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
  Measures minimum material distance between two shapes, with world-space witnesses.

  Returns `{:ok, %{distance: mm, point_a: point, point_b: point}}`.
  Intersecting or contained solids have zero distance. This is not a signed
  penetration depth; use a common-volume check to distinguish contact from
  interference. If several closest pairs exist, one is returned without a
  stable ordering guarantee. Empty inputs return `:empty_shape`.
  """
  @doc group: "Measurements"
  @spec closest_points(Shape.t(), Shape.t()) ::
          result(%{distance: float(), point_a: point3(), point_b: point3()})
  def closest_points(a, b), do: call(:closest_points, [ref(a), ref(b)])

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
  Splits solids with an infinite plane through `origin` along `normal`.

  The plane normal is normalized. `keep:` accepts `:both` (default),
  `:positive`, or `:negative`; positive means the side toward the normal.
  Accepts a solid or a nonempty compound/compsolid containing only solids.
  Free faces and edges are rejected with `:wrong_shape_type`.

  Returns a solid for one remaining piece or a compound for zero/multiple
  pieces. Both sides retain separate solids at the cut. A plane outside the
  body preserves the whole body on its side and leaves the opposite side
  empty. Boundary-only contact does not produce zero-volume solids.
  Inputs remain unchanged; output topology belongs to a new revision.

  Invalid planes return `:invalid_argument`; unknown, duplicate, or invalid
  options return `:invalid_options`. Kernel failures are tagged errors.
  """
  @doc group: "Modeling"
  @spec split(Shape.t(), point3(), point3(), keyword()) :: result(Shape.t())
  def split(body, origin, normal, opts \\ []) do
    with :ok <- options(opts, keep: [:both, :positive, :negative]),
         do: shape(:split, [ref(body), origin, normal, Keyword.get(opts, :keep, :both)])
  end

  @doc """
  Intersects solid material with an infinite plane, returning filled planar faces.

  `origin` and `normal` define a world plane; the nonzero normal is
  normalized. Accepts the same solid collections as `split/4`. Holes and
  disconnected material regions are preserved. Returns one face or a
  compound of zero/multiple faces. An outside plane or contact only at
  points/edges gives an empty compound; a coincident boundary face remains.

  Face normals follow the supplied plane normal. Coordinates remain in
  world space. Use `area/1`, `wires/1`, or `extrude/2` on the result.
  Inputs remain unchanged. Invalid plane arguments return
  `:invalid_argument`; unsupported input topology returns
  `:wrong_shape_type`. This operation does not project geometry.
  """
  @doc group: "Modeling"
  @spec section(Shape.t(), point3(), point3()) :: result(Shape.t())
  def section(body, origin, normal), do: shape(:section, [ref(body), origin, normal])

  @doc """
  Projects edges or wire boundaries onto target surfaces, returning wires.

  Supply exactly one option: `direction: {x, y, z}` for parallel projection,
  or `from: {x, y, z}` for conical projection through a world point.
  Parallel directions are nonzero and normalized. Input coordinates and
  resulting curves remain in world space.

  Sources may be edges, wires, faces, or compounds of those types. A face
  contributes every boundary wire, including holes; it does not contribute
  filled material. Targets may be faces, shells, solids, or collections of
  those types. Free edges in a target collection are rejected.

  Returns one wire or a compound of wires. Curves are clipped to target
  face boundaries. Multiple target intersections are retained; this is not
  a nearest-hit selection. Parallel projection is bidirectional, so
  reversing its direction does not select the opposite side of a solid.
  Select target faces before projection when only one surface is wanted.
  Conical projection follows half-rays from the point through the source;
  it can hit before or beyond the source, but not behind the point.

  A failed or missed source boundary returns `:projection_failed`; source
  collections are not partially accepted after a failed boundary. Successful
  partial intersections may yield open wires. No faces, shells, or solids
  are filled from the projected curves. Coincident target/sweep surfaces may
  return their boundary edges rather than isolated intersection curves.
  Degenerate geometry can fail.
  Unknown, duplicate, or missing options return `:invalid_options`.
  Bad vectors/points return `:invalid_argument`; unsupported topology
  returns `:wrong_shape_type`. Both inputs remain unchanged.
  """
  @doc group: "Modeling"
  @spec project(Shape.t(), Shape.t(), keyword()) :: result(Shape.t())
  def project(source, target, direction: direction),
    do: shape(:project, [ref(source), ref(target), :parallel, direction])

  def project(source, target, from: origin),
    do: shape(:project, [ref(source), ref(target), :conical, origin])

  def project(_, _, _), do: {:error, :invalid_options}

  @doc """
  Extrudes a planar face or a nonempty compound of planar faces along a world vector.

  The vector may be oblique to the face, but its normal component must
  exceed 1.0e-7 model units in magnitude. A vector lying in the face's plane
  returns `{:error, :degenerate_extrusion}`; a nonplanar face returns
  `{:error, :non_planar_profile}`. Face holes pass through the extrusion.
  Each face produces a solid. Compounds retain separate results; they are
  not fused. Collections containing edges, solids, or nonplanar faces fail.
  """
  @doc group: "Modeling"
  @spec extrude(Shape.t(), point3()) :: result(Shape.t())
  def extrude(face, vector), do: shape(:extrude, [ref(face), vector])

  @doc """
  Extrudes planar faces with symmetric extent and tapered walls.

  Options are `both: false` and `taper: 0`. With `both: true`, the
  full vector applies in each direction, doubling the extent. Each profile
  still produces one solid; disconnected faces remain separate solids.

  Taper is in degrees, strictly between −90 and 90. Positive taper removes
  material away from the starting plane: outer walls narrow and holes widen.
  Negative taper adds material. Symmetric taper applies the same angle to
  both halves with the original profile as their shared neutral section.

  Nonzero taper requires travel perpendicular to the profile plane and
  planar or cylindrical prism walls. Unsupported curves return
  `:unsupported_draft_surface`; oblique taper returns
  `:invalid_taper_direction`. Collapsing walls or topology changes may
  return `:draft_failed` or `:invalid_solid`. This is not a loft through
  scaled sections. Zero taper retains the prism behavior of `extrude/2`.
  Invalid option lists return `:invalid_options`; out-of-range angles
  return `:invalid_argument`. Inputs remain unchanged.
  """
  @doc group: "Modeling"
  @spec extrude(Shape.t(), point3(), keyword()) :: result(Shape.t())
  def extrude(face, vector, opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Kernel.length(Keyword.keys(opts)) == Kernel.length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(opts, fn
           {:both, value} -> is_boolean(value)
           {:taper, value} -> is_number(value)
           _ -> false
         end) do
      shape(:extrude, [
        ref(face),
        vector,
        Keyword.get(opts, :both, false),
        Keyword.get(opts, :taper, 0)
      ])
    else
      {:error, :invalid_options}
    end
  end

  @doc """
  Extrudes planar faces along a direction until they meet an infinite plane.

  `origin` and `normal` define the target plane in world coordinates.
  Direction and normal are nonzero vectors and are normalized. The entire
  profile must reach the target in the positive travel direction, at a
  distance greater than 1.0e-7 model units. The target may be tilted, but
  may not cross or touch the starting profile. Reversing the target normal
  does not change the result; reverse the travel direction to extrude backwards.

  Holes and disconnected faces are preserved. Each face produces a separate
  solid. Travel may be oblique to the profile; walls remain straight and
  untapered. This operation targets a plane, not the nearest face of a body.

  A parallel target returns `:invalid_direction`; a target not strictly
  ahead returns `:target_not_ahead`. Input topology and profile errors
  follow `extrude/2`. Invalid vectors return `:invalid_argument`.
  Inputs remain unchanged.
  """
  @doc group: "Modeling"
  @spec extrude_until(Shape.t(), point3(), point3(), point3()) :: result(Shape.t())
  def extrude_until(face, direction, origin, normal),
    do: shape(:extrude_until, [ref(face), direction, origin, normal])

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
  Builds a capped loft through at least two closed wires.

  The only option is `ruled: true` (default), which joins sections with
  straight generators. `ruled: false` fits a smooth surface through them;
  it can overshoot between sections and does not guarantee a particular
  continuity at caps or seams. Unknown, duplicate, or invalid options return
  `:invalid_options`.

  List sections in loft order. Each wire supplies one boundary; holes,
  guide rails, and seam controls are not supported.
  OCCT determines correspondence between section edges. An open section
  returns `{:error, :open_wire}`. Degenerate section arrangements may fail
  kernel construction or validation.
  """
  @doc group: "Modeling"
  @spec loft([Shape.t()], keyword()) :: result(Shape.t())
  def loft(wires, opts \\ []) do
    with :ok <- options(opts, ruled: [true, false]),
         do: shape(:loft, [refs(wires), Keyword.get(opts, :ruled, true)])
  end

  @doc """
  Sweeps one closed planar wire along an open wire, returning a capped solid.

  Place the profile in the plane through the path's starting vertex,
  perpendicular to its starting tangent. Its in-plane offset is retained;
  OCEx does not center or rotate the profile automatically. Misplacement
  returns `:misaligned_profile`. The spine must be a connected, nonbranching
  wire. Closed paths and profiles with holes are not supported by this binding.

  Options:

    * `:frame` — `:corrected` (default, corrected Frenet) or `:frenet`.
      Controls how the section turns along a curved path.
    * `:transition` — `:transformed` (default), `:right` (intersect
      adjoining swept segments), or `:round` (rotate around the corner).
      Sharp corners may fail or self-intersect; use tangent-continuous paths
      for predictable results.

  Both inputs are copied before construction. Invalid geometry returns a
  tagged kernel error. Successful BREP validation does not prove that an
  arbitrary sweep is free of geometric self-intersections.
  """
  @doc group: "Modeling"
  @spec sweep(Shape.t(), Shape.t(), keyword()) :: result(Shape.t())
  def sweep(profile, path, opts \\ []) do
    with :ok <-
           options(opts, frame: [:corrected, :frenet], transition: [:transformed, :right, :round]),
         do:
           shape(:sweep, [
             ref(profile),
             ref(path),
             Keyword.get(opts, :frame, :corrected),
             Keyword.get(opts, :transition, :transformed)
           ])
  end

  @doc """
  Sews a nonempty list of faces into surfaces at 1.0e-7 mm tolerance.

  Shared boundary edges are joined. Returns a face, a shell, or a compound
  of disconnected surfaces; it does not fill closed shells into solids.
  Faces may come from different shape revisions and remain unchanged.
  Supply coherently oriented faces when the surface's normal matters.

  Empty input returns `:empty_selection`, repeated topology returns
  `:duplicate_subshape`, non-face members return `:wrong_shape_type`,
  and non-manifold joins return `:non_manifold_surface`. Native sewing
  or validation failures are tagged errors.
  """
  @doc group: "Profiles"
  @spec sew([Shape.t()]) :: result(Shape.t())
  def sew(faces), do: shape(:sew, [refs(faces)])

  @doc """
  Builds a parallel surface or expands/contracts a solid by a signed distance.

  Accepts faces, shells, solids, or compounds of those shapes. Positive
  distance follows surface normals, outward for an oriented solid;
  negative distance goes inward. Its magnitude must exceed 1.0e-7 mm.
  This is a 3D surface offset, not a planar outline offset.

  `join: :arc` (default) fills convex gaps with rounded transitions;
  `:intersection` extends adjacent offset surfaces until they meet.
  Compound members are offset independently and are not fused. Sew faces
  first with `sew/1` when adjacent faces must offset as one shell.

  For solid inputs, the result must have positive volume and preserve
  directional containment: outward results contain the original; inward
  results stay inside it. Volume changes and containment use a tolerance
  of max(1.0e-9 mm³, original volume * 1.0e-9). Violations return
  `:invalid_offset`. A complete collapse is an error, not an empty result.

  OCCT requires sufficiently smooth surfaces and offsets small enough to
  avoid inversion or self-intersection. C0 spline surfaces and complex
  intersections may fail. Global self-intersection repair is not enabled;
  successful BREP validation does not prove absence of every geometric
  self-intersection. Inputs remain unchanged. Unknown/duplicate options
  return `:invalid_options`; invalid distances return `:invalid_argument`.
  """
  @doc group: "Modeling"
  @spec offset(Shape.t(), number(), keyword()) :: result(Shape.t())
  def offset(body, distance, opts \\ []) do
    with :ok <- options(opts, join: [:arc, :intersection]),
         do: shape(:offset, [ref(body), distance, Keyword.get(opts, :join, :arc)])
  end

  @doc """
  Builds solid material between an open surface and its signed offset.

  Accepts a face, an open shell, or a compound of these. Thickness magnitude
  must exceed 1.0e-7 mm; positive follows oriented surface normals and
  negative goes against them. The original surface forms one boundary,
  and free edges receive connecting walls. Holes in faces remain holes.

  `join: :intersection` (default) extends adjacent offset surfaces;
  `:arc` uses rounded transitions where applicable. Sew connected faces
  with `sew/1` first. Disconnected compound members produce separate
  solids without fusing. Solid inputs return `:wrong_shape_type`; closed
  shells return `:closed_shell`.

  Results must contain positive-volume solids and pass native validation.
  Surface smoothness and self-intersection limits follow `offset/3`.
  Excessive thickness may collapse or invert curved features and fail with
  `:thicken_failed`, `:invalid_solid`, or another native geometry error.
  No global self-intersection repair or variable wall thickness is provided.
  Input geometry remains unchanged.
  """
  @doc group: "Modeling"
  @spec thicken(Shape.t(), number(), keyword()) :: result(Shape.t())
  def thicken(surface, thickness, opts \\ []) do
    with :ok <- options(opts, join: [:arc, :intersection]),
         do: shape(:thicken, [ref(surface), thickness, Keyword.get(opts, :join, :intersection)])
  end

  @doc """
  Tapers selected faces of one solid around a neutral plane.

  A compound wrapping exactly one solid is also accepted. Collections with
  multiple solids or free faces/edges return `:wrong_shape_type`.

  `pull` is a nonzero direction vector; `angle` is in degrees, strictly
  between -90 and 90. `neutral_origin` and `neutral_normal` define the
  world plane where the selected surfaces retain their intersection.
  The pull vector must not lie in that plane. Positive angles remove
  material on the pull side of the neutral plane; negative angles add it.
  Zero returns an independent copy after validating the inputs.

  Faces must be planar, cylindrical, or conical and belong to this exact
  solid revision. Empty, foreign, and duplicate selections return
  `:empty_selection`, `:foreign_subshape`, or `:duplicate_subshape`.
  Unsupported surfaces return `:unsupported_draft_surface`.

  OCCT propagates draft through tangent-connected faces; those faces must
  also support drafting. The operation cannot handle a taper that requires
  a topology change, such as collapsing an edge or deleting a face.
  Build failures return `:draft_failed` or a native geometry error.
  Invalid angles/vectors return `:invalid_argument`; a pull direction
  parallel to the neutral plane returns `:invalid_direction`.
  The input solid and selected faces remain unchanged.
  """
  @doc group: "Modeling"
  @spec draft(Shape.t(), [Shape.t()], point3(), number(), point3(), point3()) :: result(Shape.t())
  def draft(body, faces, pull, angle, neutral_origin, neutral_normal),
    do: shape(:draft, [ref(body), refs(faces), pull, angle, neutral_origin, neutral_normal])

  @doc """
  Hollows a solid by removing selected faces and offsetting the remaining walls.

  A compound wrapping exactly one solid is also accepted. Free faces/edges
  or multiple solids return `:wrong_shape_type`.

  `thickness` is signed: negative builds inward, positive outward. Its
  magnitude must exceed 1.0e-7 model units. At least one opening is required.
  Faces must come from this exact body revision; foreign and duplicate faces
  return `:foreign_subshape` and `:duplicate_subshape`. The input is copied,
  including the correspondence of selected faces, before native construction.

  `join: :arc` (default) rounds gaps between offset surfaces;
  `join: :intersection` extends adjacent surfaces to their intersection.
  Concave details, small radii, and excessive thickness can make the operation
  fail. Only valid, positive-volume solid results are returned. Inward
  results must remove material and stay inside the source solid within a
  volume tolerance of max(1.0e-9, source volume * 1.0e-9); failures return
  `:invalid_thickness`. General
  self-intersection repair, closed cavities, and face thickening are not
  exposed by this operation.
  """
  @doc group: "Modeling"
  @spec shell(Shape.t(), [Shape.t()], number(), keyword()) :: result(Shape.t())
  def shell(body, openings, thickness, opts \\ []) do
    with :ok <- options(opts, join: [:arc, :intersection]),
         do: shape(:shell, [ref(body), refs(openings), thickness, Keyword.get(opts, :join, :arc)])
  end

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
  Subtracts a nonempty list of tools in one Boolean operation.

  Overlapping tools are subtracted once. All inputs are preserved, and the
  result is validated. Unlike repeated `cut/2` calls, intermediate shapes
  are not produced. The result may contain multiple solids or be empty.
  Use `clean/1` to merge same-domain faces afterward. Empty or malformed
  tool lists return `{:error, :invalid_argument}`.
  """
  @doc group: "Modeling"
  @spec cut_many(Shape.t(), [Shape.t()]) :: result(Shape.t())
  def cut_many(body, tools), do: shape(:cut_many, [ref(body), refs(tools)])

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
  Unites a body and a nonempty list of tools in one Boolean operation.

  Tools may overlap each other or the body. Disjoint solids remain separate.
  All inputs are preserved and the result is validated; intermediate pairwise
  results are not produced. Use `clean/1` to merge same-domain faces afterward.
  Empty or malformed tool lists return `{:error, :invalid_argument}`.
  """
  @doc group: "Modeling"
  @spec fuse_many(Shape.t(), [Shape.t()]) :: result(Shape.t())
  def fuse_many(body, tools), do: shape(:fuse_many, [ref(body), refs(tools)])

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

  Repeated measurements of the same immutable shape resource reuse its first
  successful measurement, without changing integration precision.

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
  | `:center`, `:axis` | Circle center and axis direction (also for arcs); otherwise `nil` |
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

  @doc """
  Creates an orthographic drawing with separate visible and hidden curves.

  The view looks along the negative normal. The origin becomes drawing
  coordinate `{0, 0}`; its depth has no effect on orthographic coordinates.
  The normal and X direction must be nonzero and nonparallel. X is projected
  into the view plane and normalized; local Y is normal cross X.

  Returns `{:ok, %{visible: shape, hidden: shape}}`, containing native curves in
  local XY at Z=0. Both values support edge queries and BREP serialization;
  they are edge collections, not filled faces or joined wires. No edges in
  a category gives an empty compound. End-on edges with projected length
  at most 1.0e-7 are omitted. Coincident edges are not geometrically merged.

  Accepts solids, shells, faces, wires, edges, and collections of them.
  Free vertices return `:wrong_shape_type`. Sharp boundaries and silhouettes
  are included. The only option is `tangents: true` to include smooth G1
  boundaries between faces (default false). Surface seams and isoparametric
  lines are excluded. Unknown, duplicate, or malformed options return
  `:invalid_options`; malformed frames return `:invalid_argument`.

  OCCT computes visibility from a copy of the BREP, independently of any
  triangle mesh. The source is unchanged. Kernel failures return tagged
  errors; a drawing is not a solid and cannot be used as a printable mesh.
  """
  @doc group: "Exchange"
  @spec drawing(Shape.t(), point3(), point3(), point3(), keyword()) ::
          result(%{visible: Shape.t(), hidden: Shape.t()})
  def drawing(body, origin, normal, x_direction, opts \\ []) do
    with :ok <- options(opts, tangents: [true, false]),
         {:ok, layers} <-
           call(:drawing, [
             ref(body),
             origin,
             normal,
             x_direction,
             Keyword.get(opts, :tangents, false)
           ]) do
      {:ok, Map.new(layers, fn {key, value} -> {key, %Shape{ref: value}} end)}
    end
  end

  @doc """
  Samples each nondegenerate edge into an ordered list of 3D points.

  Returns `{:ok, polylines}`, one point list per unique topological edge.
  Lines contain their endpoints; curves are sampled with OCCT's tangential
  deflection algorithm. Linear deflection defaults to 0.03 model units and
  angular deflection to 0.1 radians; both must exceed 1.0e-7. These control
  sampling, not exact analytic curve representation or a certified global
  distance bound for arbitrary splines.

  Points follow each edge's orientation and include both endpoints, including
  the repeated endpoint of a closed edge. Closed circular edges retain at
  least three distinct points even at coarse tolerances. Edges are not joined or sorted into
  wires. Empty geometry and shapes without edges return an empty list.
  Sampling leaves the input unchanged. Invalid deflections return
  `:invalid_argument`; a failed sampler returns `:sampling_failed`.
  """
  @doc group: "Exchange"
  @spec polylines(Shape.t(), number(), number()) :: result([[point3()]])
  def polylines(body, tolerance \\ 0.03, angular_tolerance \\ 0.1),
    do: call(:polylines, [ref(body), tolerance, angular_tolerance])

  @doc """
  Validates scalable Unicode font bytes and returns family, style, units per em,
  face count and glyph count. `face_index` selects a collection face, default 0.
  Does not create geometry or consult system fonts. Uses the font errors and
  64 MiB input limit documented by `text/4`.
  """
  @doc group: "Geometry"
  @spec font_info(binary(), non_neg_integer()) :: result(map())
  def font_info(bytes, face_index \\ 0), do: call(:font_info, [bytes, face_index])

  @doc """
  Shapes UTF-8 text from supplied TTF/OTF font **bytes** into planar XY faces.

  `size` is the em size in model units, not the visible capital height. Load
  bytes with `File.read/1`; no system font lookup or fallback occurs. HarfBuzz
  shapes one horizontal script/direction run, including kerning and ligatures.
  Mixed-direction paragraphs, line breaking, variable-font axes, bitmap/color
  glyphs, and font discovery are not supported. Outline curves remain exact
  lines and quadratic/cubic Béziers; counters and separate dots are retained.
  Overlapping glyphs are unioned before returning the filled shape.

  Options: `tracking: 0` (extra model units between shaped clusters; nonzero
  tracking disables optional ligatures), `face_index: 0` (font collection face),
  `direction: :auto | :ltr | :rtl`, and `language: ""` (BCP-47 shaping language).
  Baseline starts at the origin; glyph bearings can extend left or below it.

  Returns a map with `shape`, geometry-derived `ink_bounds`, horizontal `advance`,
  `ascender`, `descender`, `line_height`, `units_per_em`, `family`, `style`,
  `direction`, and `glyphs`. Glyph entries have `glyph_id`, UTF-8 byte `cluster`,
  `origin`, `advance`, and `bounds` (`nil` for spaces). Font metrics and glyph
  bounds precede union; ink bounds describe the returned geometry.

  Errors include `:invalid_text` (empty, malformed, multiline/control text or
  >65,536 bytes / 4,096 shaped glyphs), `:empty_text` (no ink), `:invalid_font`
  (unreadable bytes/face index or >64 MiB), `:unsupported_font`, `:missing_glyph`,
  and `:invalid_glyph` (outlines cannot form valid faces). Size must exceed
  1.0e-7. Font parsing is in-process, like other native geometry operations.
  """
  @doc group: "Geometry"
  @spec text(String.t(), binary(), number(), keyword()) :: result(map())
  def text(text, font, size, opts \\ []) do
    valid_options =
      is_list(opts) and Keyword.keyword?(opts) and
        Kernel.length(opts) == Kernel.length(Enum.uniq_by(opts, &elem(&1, 0))) and
        Enum.all?(Keyword.keys(opts), &(&1 in [:tracking, :face_index, :direction, :language]))

    cond do
      not valid_options ->
        {:error, :invalid_options}

      not (is_binary(text) and String.valid?(text) and byte_size(text) in 1..65_536) ->
        {:error, :invalid_text}

      Enum.any?(String.to_charlist(text), &(&1 < 32 or &1 in 127..159 or &1 in [0x2028, 0x2029])) ->
        {:error, :invalid_text}

      Keyword.get(opts, :direction, :auto) not in [:auto, :ltr, :rtl] ->
        {:error, :invalid_options}

      not is_binary(Keyword.get(opts, :language, "")) ->
        {:error, :invalid_options}

      true ->
        with {:ok, layout} <-
               call(:text, [
                 text,
                 font,
                 size,
                 Keyword.get(opts, :tracking, 0),
                 Keyword.get(opts, :face_index, 0),
                 Atom.to_string(Keyword.get(opts, :direction, :auto)),
                 Keyword.get(opts, :language, "")
               ]) do
          {:ok, %{layout | shape: %Shape{ref: layout.shape}}}
        end
    end
  end

  @doc """
  Samples a wire in traversal order, honoring reversed edges. Closed wires
  repeat their first point at the end. `tolerance` is linear deflection in
  model units; angular deflection is 0.1 radians. At most 20,000 points are
  returned; larger results fail with `:profile_too_complex`.
  """
  @spec wire_points(Shape.t(), number()) :: result([vector3()])
  def wire_points(wire, tolerance \\ 0.01), do: call(:wire_points, [ref(wire), tolerance])

  @doc """
  Fills closed XY wires using `:nonzero` or `:evenodd` winding. Intersections,
  holes and disconnected regions are retained; curves remain curves. Empty
  fill returns an empty compound. Open wires fail with `:open_wire`, non-XY
  geometry with `:nonplanar_profile`. At most 4096 wires are accepted.
  """
  @spec planar_fill([Shape.t()], :nonzero | :evenodd) :: result(Shape.t())
  def planar_fill(wires, rule \\ :nonzero)

  def planar_fill(wires, rule) when rule in [:nonzero, :evenodd],
    do: shape(:planar_fill, [refs(wires), Atom.to_string(rule)])

  def planar_fill(_, _), do: {:error, :invalid_argument}

  @doc """
  Expands an XY wire into planar stroke regions. Width is in model units.
  Options: `cap: :butt | :round | :square`, `join: :miter | :round | :bevel`,
  `miter_limit: 4` (ratio to half-width), `tolerance: 0.01` (curve sampling
  deflection). Defaults are butt caps and miter joins. Straight strokes and
  round caps are exact; curved centerlines are sampled. Closed wires have
  joins and no caps. Inputs are copied before native operations.
  """
  @spec stroke(Shape.t(), number(), keyword()) :: result(Shape.t())
  def stroke(wire, width, opts \\ []) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:cap, :join, :miter_limit, :tolerance])),
         true <- Kernel.length(opts) == Kernel.length(Enum.uniq_by(opts, &elem(&1, 0))),
         cap when cap in [:butt, :round, :square] <- Keyword.get(opts, :cap, :butt),
         join when join in [:miter, :round, :bevel] <- Keyword.get(opts, :join, :miter) do
      shape(:stroke, [
        ref(wire),
        width,
        Atom.to_string(cap),
        Atom.to_string(join),
        Keyword.get(opts, :miter_limit, 4),
        Keyword.get(opts, :tolerance, 0.01)
      ])
    else
      _ -> {:error, :invalid_options}
    end
  end

  @doc """
  Applies an invertible XY affine matrix `{a,b,c,d,e,f}`: x'=ax+cy+e,
  y'=bx+dy+f, z'=z. Supports nonuniform scale and shear, copying the input.
  Singular matrices fail with `:invalid_argument`.
  """
  @spec affine_transform(Shape.t(), {number(), number(), number(), number(), number(), number()}) ::
          result(Shape.t())
  def affine_transform(shape, matrix), do: shape(:affine_transform, [ref(shape), matrix])

  defp options(opts, allowed) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Kernel.length(Keyword.keys(opts)) == Kernel.length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(opts, fn {key, value} -> value in Keyword.get(allowed, key, []) end),
       do: :ok,
       else: {:error, :invalid_options}
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
