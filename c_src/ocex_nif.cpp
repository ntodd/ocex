#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BOPAlgo_PaveFiller.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepAlgo_FaceRestrictor.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <gp_GTrsf.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepOffset_MakeOffset.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeHalfSpace.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRepProj_Projection.hxx>
#include <BRepTools.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GProp_GProps.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_BezierCurve.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <HLRAlgo_Projector.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Version.hxx>
#include <StlAPI_Writer.hxx>
#include <TColgp_HArray1OfPnt.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Iterator.hxx>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <erl_nif.h>
#include <gp_Circ.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Pln.hxx>
#include <gp_Sphere.hxx>
#include <memory>
#include <limits>
#include <mutex>
#include <new>
#include <sstream>
#include <string>
#include <vector>
#include <exception>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include <hb.h>
#include <hb-ot.h>

namespace {
using Term = ERL_NIF_TERM;
struct Error {
  const char *reason;
};
void require(bool condition, const char *reason = "invalid_argument") {
  if (!condition)
    throw Error{reason};
}

// A shared token binds selected subshapes to precisely one output revision.
// TopoDS_Shape owns its native topology even after its parent resource dies.
struct Shape {
  TopoDS_Shape value;
  std::shared_ptr<const int> revision;
  std::atomic<size_t> *live_resources;
  // Shapes are immutable. This bounded cache dies with its resource and is
  // accessed only while call() holds State::mutex. New resources start cold.
  bool has_volume = false;
  double volume = 0;
};
struct State {
  ErlNifResourceType *shape_type = nullptr;
  std::mutex mutex;
  std::atomic<size_t> live_resources{0};
};
State *state(ErlNifEnv *env) {
  return static_cast<State *>(enif_priv_data(env));
}
Term atom(ErlNifEnv *env, const char *text) {
  return enif_make_atom(env, text);
}
Term binary(ErlNifEnv *env, const std::string &text) {
  Term term;
  auto *bytes = enif_make_new_binary(env, text.size(), &term);
  require(bytes || text.empty(), "out_of_memory");
  if (!text.empty())
    std::memcpy(bytes, text.data(), text.size());
  return term;
}
Term number(ErlNifEnv *env, double value) {
  require(std::isfinite(value), "non_finite_result");
  return enif_make_double(env, value);
}
Term point(ErlNifEnv *env, const gp_Pnt &p) {
  return enif_make_tuple3(env, number(env, p.X()), number(env, p.Y()), number(env, p.Z()));
}
Term direction(ErlNifEnv *env, const gp_Dir &d) {
  return point(env, gp_Pnt(d.X(), d.Y(), d.Z()));
}
Term list(ErlNifEnv *env, const std::vector<Term> &values) {
  return enif_make_list_from_array(env, values.data(), static_cast<unsigned>(values.size()));
}
Term map(ErlNifEnv *env, std::initializer_list<std::pair<const char *, Term>> fields) {
  Term result = enif_make_new_map(env);
  for (const auto &field : fields)
    enif_make_map_put(env, result, atom(env, field.first), field.second, &result);
  return result;
}
std::string string(ErlNifEnv *env, Term term, bool path = false) {
  ErlNifBinary bytes;
  require(enif_inspect_binary(env, term, &bytes));
  std::string result(reinterpret_cast<char *>(bytes.data), bytes.size);
  if (path)
    require(!result.empty() && result.find('\0') == std::string::npos);
  return result;
}
std::vector<Term> terms(ErlNifEnv *env, Term input) {
  std::vector<Term> values;
  Term head, tail = input;
  while (enif_get_list_cell(env, tail, &head, &tail))
    values.push_back(head);
  require(enif_is_empty_list(env, tail));
  return values;
}
double scalar(ErlNifEnv *env, Term term) {
  double value;
  ErlNifSInt64 integer;
  if (!enif_get_double(env, term, &value)) {
    require(enif_get_int64(env, term, &integer));
    value = static_cast<double>(integer);
  }
  require(std::isfinite(value));
  return value;
}
double positive(ErlNifEnv *env, Term term) {
  double value = scalar(env, term);
  require(value > Precision::Confusion());
  return value;
}
gp_Pnt xyz(ErlNifEnv *env, Term term) {
  int arity;
  const Term *elements;
  require(enif_get_tuple(env, term, &arity, &elements) && arity == 3);
  return gp_Pnt(scalar(env, elements[0]), scalar(env, elements[1]), scalar(env, elements[2]));
}
gp_Vec vector(ErlNifEnv *env, Term term, bool nonzero = false) {
  auto p = xyz(env, term);
  gp_Vec v(p.X(), p.Y(), p.Z());
  if (nonzero)
    require(v.Magnitude() > Precision::Confusion());
  return v;
}
Shape &shape(ErlNifEnv *env, Term term, TopAbs_ShapeEnum type = TopAbs_SHAPE) {
  void *resource;
  require(enif_get_resource(env, term, state(env)->shape_type, &resource));
  auto &result = *static_cast<Shape *>(resource);
  require(!result.value.IsNull());
  require(type == TopAbs_SHAPE || result.value.ShapeType() == type, "wrong_shape_type");
  return result;
}
Term resource(ErlNifEnv *env, const TopoDS_Shape &value, std::shared_ptr<const int> revision = {}) {
  require(!value.IsNull(), "operation_failed");
  require(BRepCheck_Analyzer(value).IsValid(), "invalid_shape");
  if (!revision)
    revision = std::make_shared<const int>(0);
  void *storage = enif_alloc_resource(state(env)->shape_type, sizeof(Shape));
  require(storage != nullptr, "out_of_memory");
  new (storage) Shape{value, std::move(revision), &state(env)->live_resources};
  state(env)->live_resources.fetch_add(1, std::memory_order_relaxed);
  Term result = enif_make_resource(env, storage);
  enif_release_resource(storage);
  return result;
}
TopoDS_Shape copy(const TopoDS_Shape &value) {
  return BRepBuilderAPI_Copy(value, true, false).Shape();
}
const char *type_name(TopAbs_ShapeEnum type) {
  switch (type) {
  case TopAbs_COMPOUND:
    return "compound";
  case TopAbs_COMPSOLID:
    return "compsolid";
  case TopAbs_SOLID:
    return "solid";
  case TopAbs_SHELL:
    return "shell";
  case TopAbs_FACE:
    return "face";
  case TopAbs_WIRE:
    return "wire";
  case TopAbs_EDGE:
    return "edge";
  case TopAbs_VERTEX:
    return "vertex";
  default:
    return "shape";
  }
}
GProp_GProps properties(const TopoDS_Shape &value, const std::string &kind) {
  GProp_GProps props;
  if (kind == "length")
    BRepGProp::LinearProperties(value, props, true, false);
  else if (kind == "area")
    BRepGProp::SurfaceProperties(value, props, 1.0e-9, true);
  else
    BRepGProp::VolumePropertiesGK(value, props, 1.0e-9, true, true,
                                 kind == "center_of_mass", false, true);
  return props;
}
Term edge_info(ErlNifEnv *env, const TopoDS_Edge &edge) {
  BRepAdaptor_Curve curve(edge);
  auto props = properties(edge, "length");
  const char *type = "other";
  Term radius = atom(env, "nil"), dir = atom(env, "nil");
  Term center = atom(env, "nil"), axis = atom(env, "nil");
  if (curve.GetType() == GeomAbs_Line) {
    type = "line";
    auto d = curve.Line().Direction();
    if (edge.Orientation() == TopAbs_REVERSED)
      d.Reverse();
    dir = direction(env, d);
  } else if (curve.GetType() == GeomAbs_Circle) {
    type = "circle";
    radius = number(env, curve.Circle().Radius());
    center = point(env, curve.Circle().Location());
    axis = direction(env, curve.Circle().Axis().Direction());
  }
  double first = curve.FirstParameter(), last = curve.LastParameter();
  auto start = curve.Value(first), end = curve.Value(last);
  if (edge.Orientation() == TopAbs_REVERSED)
    std::swap(start, end);
  return map(env,
             {{"type", atom(env, type)},
              {"length", number(env, props.Mass())},
              {"start", point(env, start)},
              {"end", point(env, end)},
              {"direction", dir},
              {"radius", radius},
              {"center", center},
              {"axis", axis},
              {"parameter_bounds", enif_make_tuple2(env, number(env, first), number(env, last))}});
}
Term face_info(ErlNifEnv *env, const TopoDS_Face &face) {
  BRepAdaptor_Surface surface(face);
  auto props = properties(face, "area");
  const char *type = "other";
  Term normal = atom(env, "nil"), radius = atom(env, "nil");
  Term axis_origin = atom(env, "nil"), axis_direction = atom(env, "nil");
  if (surface.GetType() == GeomAbs_Plane) {
    type = "plane";
    const auto axes = surface.Plane().Position();
    gp_Dir d(gp_Vec(axes.XDirection()).Crossed(gp_Vec(axes.YDirection())));
    if (face.Orientation() == TopAbs_REVERSED)
      d.Reverse();
    normal = direction(env, d);
  } else if (surface.GetType() == GeomAbs_Sphere) {
    type = "sphere";
    radius = number(env, surface.Sphere().Radius());
  } else if (surface.GetType() == GeomAbs_Cylinder) {
    type = "cylinder";
    radius = number(env, surface.Cylinder().Radius());
    axis_origin = point(env, surface.Cylinder().Location());
    axis_direction = direction(env, surface.Cylinder().Axis().Direction());
  }
  double u0, u1, v0, v1;
  BRepTools::UVBounds(face, u0, u1, v0, v1);
  return map(env, {{"type", atom(env, type)},
                   {"area", number(env, props.Mass())},
                   {"center", point(env, props.CentreOfMass())},
                   {"normal", normal},
                   {"axis_origin", axis_origin},
                   {"axis_direction", axis_direction},
                   {"radius", radius},
                   {"uv_bounds", enif_make_tuple4(env, number(env, u0), number(env, u1),
                                                  number(env, v0), number(env, v1))}});
}
template <class Operation>
TopoDS_Shape boolean_many(const TopoDS_Shape &a, const std::vector<TopoDS_Shape> &values) {
  Operation operation;
  TopTools_ListOfShape arguments, tools;
  arguments.Append(copy(a));
  for (const auto &value : values)
    tools.Append(copy(value));
  operation.SetArguments(arguments);
  operation.SetTools(tools);
  operation.SetNonDestructive(true);
  // Small booleans lose more to scheduling than they gain. Parallelize only
  // batches against substantial topology; use OCCT's pool without changing
  // its process-wide size or releasing our resource/state lock.
  int faces = 0;
  if (values.size() >= 3)
    for (TopExp_Explorer e(a, TopAbs_FACE); e.More() && faces < 128; e.Next())
      ++faces;
  operation.SetRunParallel(faces >= 128);
  operation.Build();
  require(operation.IsDone() && !operation.HasErrors(), "operation_failed");
  return operation.Shape();
}
template <class Operation> TopoDS_Shape boolean(const TopoDS_Shape &a, const TopoDS_Shape &b) {
  return boolean_many<Operation>(a, {b});
}
// Accept collections of the requested topology without silently dropping free
// edges/faces from an otherwise valid compound.
void leaves(const TopoDS_Shape &value, TopAbs_ShapeEnum kind, std::vector<TopoDS_Shape> &out) {
  if (value.ShapeType() == kind) {
    out.push_back(value);
    return;
  }
  require(value.ShapeType() == TopAbs_COMPOUND ||
              (kind == TopAbs_SOLID && value.ShapeType() == TopAbs_COMPSOLID),
          "wrong_shape_type");
  for (TopoDS_Iterator it(value); it.More(); it.Next())
    leaves(it.Value(), kind, out);
}
TopoDS_Shape collection(const std::vector<TopoDS_Shape> &values) {
  if (values.size() == 1)
    return values.front();
  BRep_Builder builder;
  TopoDS_Compound result;
  builder.MakeCompound(result);
  for (const auto &value : values)
    builder.Add(result, value);
  return result;
}
std::vector<TopoDS_Shape> subshapes(const TopoDS_Shape &value, TopAbs_ShapeEnum kind) {
  TopTools_IndexedMapOfShape found;
  TopExp::MapShapes(value, kind, found);
  std::vector<TopoDS_Shape> result;
  for (int i = 1; i <= found.Extent(); ++i)
    result.push_back(found(i));
  return result;
}

void drawing_source(const TopoDS_Shape &value) {
  if (value.ShapeType() == TopAbs_COMPOUND || value.ShapeType() == TopAbs_COMPSOLID) {
    for (TopoDS_Iterator it(value); it.More(); it.Next())
      drawing_source(it.Value());
  } else {
    require(value.ShapeType() == TopAbs_SOLID || value.ShapeType() == TopAbs_SHELL ||
                value.ShapeType() == TopAbs_FACE || value.ShapeType() == TopAbs_WIRE ||
                value.ShapeType() == TopAbs_EDGE,
            "wrong_shape_type");
  }
}

TopoDS_Shape drawing_edges(const std::vector<TopoDS_Shape> &groups) {
  std::vector<TopoDS_Shape> edges;
  for (const auto &group : groups) {
    if (group.IsNull())
      continue;
    require(BRepLib::BuildCurves3d(group), "drawing_failed");
    for (const auto &value : subshapes(group, TopAbs_EDGE)) {
      auto edge = TopoDS::Edge(value);
      if (!BRep_Tool::Degenerated(edge) &&
          properties(edge, "length").Mass() > Precision::Confusion())
        edges.push_back(edge);
    }
  }
  return collection(edges);
}

Term drawing(ErlNifEnv *env, const TopoDS_Shape &source, const gp_Ax2 &frame, bool tangents) {
  drawing_source(source);
  if (subshapes(source, TopAbs_EDGE).empty())
    return map(env, {{"visible", resource(env, collection({}))},
                     {"hidden", resource(env, collection({}))}});
  Handle(HLRBRep_Algo) algo = new HLRBRep_Algo();
  algo->Add(copy(source), 0);
  algo->Projector(HLRAlgo_Projector(frame));
  algo->Update();
  algo->Hide();
  HLRBRep_HLRToShape extracted(algo);
  std::vector<TopoDS_Shape> visible{extracted.VCompound(), extracted.OutLineVCompound()};
  std::vector<TopoDS_Shape> hidden{extracted.HCompound(), extracted.OutLineHCompound()};
  if (tangents) {
    visible.push_back(extracted.Rg1LineVCompound());
    hidden.push_back(extracted.Rg1LineHCompound());
  }
  return map(env, {{"visible", resource(env, drawing_edges(visible))},
                   {"hidden", resource(env, drawing_edges(hidden))}});
}

Term polylines(ErlNifEnv *env, const TopoDS_Shape &source, double tolerance, double angular) {
  std::vector<Term> lines;
  for (const auto &value : subshapes(source, TopAbs_EDGE)) {
    auto edge = TopoDS::Edge(value);
    if (BRep_Tool::Degenerated(edge))
      continue;
    BRepAdaptor_Curve curve(edge);
    const bool closed =
        curve.Value(curve.FirstParameter()).Distance(curve.Value(curve.LastParameter())) <=
        Precision::Confusion();
    GCPnts_TangentialDeflection sampled(curve, angular, tolerance, closed ? 4 : 2);
    require(sampled.NbPoints() >= 2, "sampling_failed");
    std::vector<Term> points;
    for (int i = 1; i <= sampled.NbPoints(); ++i)
      points.push_back(point(env, sampled.Value(i)));
    if (edge.Orientation() == TopAbs_REVERSED)
      std::reverse(points.begin(), points.end());
    lines.push_back(list(env, points));
  }
  return list(env, lines);
}

void projection_sources(const TopoDS_Shape &shape, std::vector<TopoDS_Shape> &out) {
  if (shape.ShapeType() == TopAbs_EDGE || shape.ShapeType() == TopAbs_WIRE) {
    out.push_back(shape);
    return;
  }
  if (shape.ShapeType() == TopAbs_FACE) {
    auto wires = subshapes(shape, TopAbs_WIRE);
    require(!wires.empty(), "wrong_shape_type");
    out.insert(out.end(), wires.begin(), wires.end());
    return;
  }
  require(shape.ShapeType() == TopAbs_COMPOUND, "wrong_shape_type");
  for (TopoDS_Iterator it(shape); it.More(); it.Next())
    projection_sources(it.Value(), out);
}

void projection_target(const TopoDS_Shape &shape) {
  if (shape.ShapeType() == TopAbs_COMPOUND || shape.ShapeType() == TopAbs_COMPSOLID) {
    require(TopoDS_Iterator(shape).More(), "wrong_shape_type");
    for (TopoDS_Iterator it(shape); it.More(); it.Next())
      projection_target(it.Value());
    return;
  }
  require(shape.ShapeType() == TopAbs_FACE || shape.ShapeType() == TopAbs_SHELL ||
              shape.ShapeType() == TopAbs_SOLID,
          "wrong_shape_type");
}

template <class Projection>
TopoDS_Shape project_curves(const TopoDS_Shape &source, const TopoDS_Shape &target,
                            const Projection &projection) {
  std::vector<TopoDS_Shape> sources, results;
  projection_sources(copy(source), sources);
  require(!sources.empty(), "wrong_shape_type");
  projection_target(target);
  for (const auto &curve : sources) {
    BRepProj_Projection builder(curve, copy(target), projection);
    require(builder.IsDone(), "projection_failed");
    builder.Init();
    require(builder.More(), "projection_failed");
    for (; builder.More(); builder.Next())
      results.push_back(builder.Current());
  }
  require(!results.empty(), "projection_failed");
  return collection(results);
}

gp_Pln extrusion_plane(const TopoDS_Shape &face, const gp_Vec &vector) {
  BRepAdaptor_Surface surface(TopoDS::Face(face));
  require(surface.GetType() == GeomAbs_Plane, "non_planar_profile");
  auto plane = surface.Plane();
  require(std::abs(vector.Dot(gp_Vec(plane.Axis().Direction()))) > Precision::Confusion(),
          "degenerate_extrusion");
  return plane;
}

TopoDS_Shape extrude_face(const TopoDS_Shape &face, const gp_Vec &vector, double taper) {
  auto plane = extrusion_plane(face, vector);
  BRepPrimAPI_MakePrism prism(face, vector, true);
  require(prism.IsDone(), "operation_failed");
  auto result = prism.Shape();
  if (taper == 0)
    return result;
  gp_Dir direction(vector);
  require(direction.IsParallel(plane.Axis().Direction(), Precision::Angular()),
          "invalid_taper_direction");
  BRepOffsetAPI_DraftAngle draft(result);
  TopTools_IndexedMapOfShape selected;
  for (const auto &edge : subshapes(face, TopAbs_EDGE)) {
    for (const auto &generated : prism.Generated(edge)) {
      if (generated.ShapeType() != TopAbs_FACE || selected.Contains(generated))
        continue;
      auto side = TopoDS::Face(generated);
      auto type = BRepAdaptor_Surface(side).GetType();
      require(type == GeomAbs_Plane || type == GeomAbs_Cylinder || type == GeomAbs_Cone,
              "unsupported_draft_surface");
      draft.Add(side, direction, taper * std::acos(-1) / 180, plane);
      require(draft.AddDone(), "draft_failed");
      for (const auto &modified : draft.ModifiedFaces())
        selected.Add(modified);
    }
  }
  require(!selected.IsEmpty(), "draft_failed");
  draft.Build();
  require(draft.IsDone(), "draft_failed");
  result = draft.Shape();
  require(result.ShapeType() == TopAbs_SOLID && BRepCheck_Analyzer(result).IsValid() &&
              properties(result, "volume").Mass() > 1e-9,
          "invalid_solid");
  return result;
}

TopoDS_Shape extrude_profile(const TopoDS_Shape &profile, const gp_Vec &vector, bool both,
                             double taper) {
  std::vector<TopoDS_Shape> faces;
  leaves(profile, TopAbs_FACE, faces);
  require(!faces.empty(), "wrong_shape_type");
  for (const auto &face : faces)
    extrusion_plane(face, vector);
  if (!both && taper == 0)
    return BRepPrimAPI_MakePrism(profile, vector, true).Shape();
  if (taper == 0) {
    gp_Trsf shift;
    shift.SetTranslation(-vector);
    auto start = BRepBuilderAPI_Transform(profile, shift, true).Shape();
    return BRepPrimAPI_MakePrism(start, vector * 2, true).Shape();
  }
  std::vector<TopoDS_Shape> results;
  for (const auto &face : faces) {
    auto result = extrude_face(face, vector, taper);
    if (both) {
      auto other = extrude_face(face, -vector, taper);
      result = boolean<BRepAlgoAPI_Fuse>(result, other);
      auto solids = subshapes(result, TopAbs_SOLID);
      require(solids.size() == 1, "invalid_solid");
      result = solids.front();
    }
    results.push_back(result);
  }
  return collection(results);
}

TopoDS_Shape extrude_until(const TopoDS_Shape &profile, const gp_Dir &direction,
                           const gp_Pln &target) {
  std::vector<TopoDS_Shape> faces;
  leaves(profile, TopAbs_FACE, faces);
  require(!faces.empty(), "wrong_shape_type");
  for (const auto &face : faces)
    extrusion_plane(face, gp_Vec(direction));
  double alignment = direction.Dot(target.Axis().Direction());
  require(std::abs(alignment) > Precision::Angular(), "invalid_direction");
  // Measure signed plane distances in the target's own frame, so rotated
  // world bounding boxes cannot incorrectly reject an otherwise valid target.
  gp_Trsf local;
  local.SetTransformation(target.Position());
  auto transformed = BRepBuilderAPI_Transform(profile, local, true).Shape();
  Bnd_Box bounds;
  BRepBndLib::AddOptimal(transformed, bounds, false, false);
  double first = -bounds.CornerMin().Z() / alignment;
  double last = -bounds.CornerMax().Z() / alignment;
  double nearest = std::min(first, last), farthest = std::max(first, last);
  require(std::isfinite(nearest) && std::isfinite(farthest), "invalid_argument");
  require(nearest > Precision::Confusion(), "target_not_ahead");
  double length = farthest + std::max(1e-5, farthest * 1e-7);
  require(std::isfinite(length), "invalid_argument");
  auto plane = BRepBuilderAPI_MakeFace(target).Face();
  auto half =
      BRepPrimAPI_MakeHalfSpace(plane, target.Location().Translated(-gp_Vec(direction))).Solid();
  std::vector<TopoDS_Shape> results;
  for (const auto &face : faces) {
    auto prism = extrude_face(face, gp_Vec(direction) * length, 0);
    auto trimmed = boolean<BRepAlgoAPI_Common>(prism, half);
    auto solids = subshapes(trimmed, TopAbs_SOLID);
    require(solids.size() == 1 && properties(solids.front(), "volume").Mass() > 1e-9,
            "invalid_solid");
    results.push_back(solids.front());
  }
  return collection(results);
}

TopoDS_Shape offset_shape(const TopoDS_Shape &source, double distance, GeomAbs_JoinType join,
                          bool thicken) {
  if (source.ShapeType() == TopAbs_COMPOUND || source.ShapeType() == TopAbs_COMPSOLID) {
    std::vector<TopoDS_Shape> results;
    for (TopoDS_Iterator it(source); it.More(); it.Next())
      results.push_back(offset_shape(it.Value(), distance, join, thicken));
    require(!results.empty(), "wrong_shape_type");
    return collection(results);
  }
  require(source.ShapeType() == TopAbs_FACE || source.ShapeType() == TopAbs_SHELL ||
              (!thicken && source.ShapeType() == TopAbs_SOLID),
          "wrong_shape_type");
  auto surface = copy(source);
  TopoDS_Shape result;
  if (thicken) {
    require(!BRep_Tool::IsClosed(surface), "closed_shell");
    BRepOffset_MakeOffset builder;
    builder.Initialize(surface, distance, Precision::Confusion(), BRepOffset_Skin, false, false,
                       join, true, true);
    builder.MakeOffsetShape();
    require(builder.IsDone(), "thicken_failed");
    result = builder.Shape();
    require(!subshapes(result, TopAbs_SOLID).empty() && properties(result, "volume").Mass() > 1e-9,
            "invalid_solid");
  } else {
    BRepOffsetAPI_MakeOffsetShape builder;
    builder.PerformByJoin(surface, distance, Precision::Confusion(), BRepOffset_Skin, false, false,
                          join, true);
    require(builder.IsDone(), "offset_failed");
    result = builder.Shape();
    require(!subshapes(result, TopAbs_FACE).empty(), "offset_failed");
    if (source.ShapeType() == TopAbs_SOLID) {
      double original = properties(source, "volume").Mass();
      double amount = properties(result, "volume").Mass();
      double tolerance = std::max(1e-9, original * 1e-9);
      require(!subshapes(result, TopAbs_SOLID).empty() && amount > 1e-9, "invalid_offset");
      require(distance > 0 ? amount > original + tolerance : amount < original - tolerance,
              "invalid_offset");
      auto outside = distance > 0 ? boolean<BRepAlgoAPI_Cut>(source, result)
                                  : boolean<BRepAlgoAPI_Cut>(result, source);
      require(std::abs(properties(outside, "volume").Mass()) <= tolerance, "invalid_offset");
    }
  }
  require(BRepCheck_Analyzer(result).IsValid(), "invalid_shape");
  return result;
}

TopoDS_Shape triangulate(const TopoDS_Shape &original, double tolerance, double angular_tolerance) {
  auto result = copy(original);
  BRepMesh_IncrementalMesh mesher(result, tolerance, false, angular_tolerance, false);
  require(mesher.IsDone(), "operation_failed");
  return result;
}
Term mesh(ErlNifEnv *env, const TopoDS_Shape &original, double tolerance,
          double angular_tolerance) {
  auto body = triangulate(original, tolerance, angular_tolerance);
  std::vector<Term> vertices, triangles, triangles_per_face, face_types;
  for (TopExp_Explorer explorer(body, TopAbs_FACE); explorer.More(); explorer.Next()) {
    const auto &face = TopoDS::Face(explorer.Current());
    TopLoc_Location location;
    auto mesh = BRep_Tool::Triangulation(face, location);
    require(!mesh.IsNull(), "operation_failed");
    triangles_per_face.push_back(enif_make_int(env, mesh->NbTriangles()));
    face_types.push_back(enif_make_int(env, BRepAdaptor_Surface(face).GetType()));
    unsigned offset = static_cast<unsigned>(vertices.size());
    for (int i = 1; i <= mesh->NbNodes(); ++i)
      vertices.push_back(point(env, mesh->Node(i).Transformed(location.Transformation())));
    for (int i = 1; i <= mesh->NbTriangles(); ++i) {
      int a, b, c;
      mesh->Triangle(i).Get(a, b, c);
      if (face.Orientation() == TopAbs_REVERSED)
        std::swap(b, c);
      triangles.push_back(enif_make_tuple3(env, enif_make_uint(env, offset + a - 1),
                                           enif_make_uint(env, offset + b - 1),
                                           enif_make_uint(env, offset + c - 1)));
    }
  }
  return map(env, {{"vertices", list(env, vertices)},
                   {"triangles", list(env, triangles)},
                   {"triangles_per_face", list(env, triangles_per_face)},
                   {"face_types", list(env, face_types)}});
}

#include "text_geometry.hpp"
#include "planar_geometry.hpp"

Term execute(ErlNifEnv *env, const std::string &op, const std::vector<Term> &a) {
  auto arity = [&](size_t n) { require(a.size() == n); };
  if (op == "wire_points") {
    arity(2);
    auto wire = TopoDS::Wire(copy(shape(env,a[0],TopAbs_WIRE).value));
    std::vector<Term> points;
    for (auto &p : wire_samples(wire,positive(env,a[1]),false)) points.push_back(point(env,p));
    return list(env,points);
  }
  if (op == "planar_fill") {
    arity(2);
    auto values = terms(env, a[0]);
    require(values.size() <= 4096, "profile_too_complex");
    auto rule = string(env, a[1]);
    require(rule == "nonzero" || rule == "evenodd");
    std::vector<TopoDS_Wire> wires;
    for (auto value : values) wires.push_back(TopoDS::Wire(copy(shape(env, value, TopAbs_WIRE).value)));
    return resource(env, planar_fill(wires, rule == "evenodd"));
  }
  if (op == "stroke") {
    arity(6);
    auto wire = TopoDS::Wire(copy(shape(env, a[0], TopAbs_WIRE).value));
    return resource(env, planar_stroke(wire, positive(env,a[1]), string(env,a[2]),
      string(env,a[3]), positive(env,a[4]), positive(env,a[5])));
  }
  if (op == "affine_transform") {
    arity(2);
    int count; const Term *values;
    require(enif_get_tuple(env,a[1],&count,&values) && count==6);
    double m[6]; for (int i=0;i<6;++i) m[i]=scalar(env,values[i]);
    require(std::abs(m[0]*m[3]-m[1]*m[2])>1e-15);
    auto source = copy(shape(env,a[0]).value);
    // Preserve analytic curves for XY similarities. General affine transforms
    // require GTransform's exact rational B-splines. Scaling Z is immaterial
    // only when the entire source is on Z=0.
    double sx2=m[0]*m[0]+m[1]*m[1], sy2=m[2]*m[2]+m[3]*m[3];
    Bnd_Box box; BRepBndLib::AddOptimal(source,box,false,false);
    if (!box.IsVoid() && box.CornerMin().Z()==0.0 &&
        box.CornerMax().Z()==0.0 &&
        std::abs(sx2-sy2)<1e-12*std::max(sx2,sy2) &&
        std::abs(m[0]*m[2]+m[1]*m[3])<1e-12*std::max(sx2,sy2)) {
      gp_Trsf similarity;
      similarity.SetValues(m[0],m[2],0,m[4],m[1],m[3],0,m[5],0,0,std::sqrt(sx2),0);
      return resource(env,BRepBuilderAPI_Transform(source,similarity,true).Shape());
    }
    gp_GTrsf transform;
    transform.SetVectorialPart(gp_Mat(m[0],m[2],0,m[1],m[3],0,0,0,1));
    transform.SetTranslationPart(gp_XYZ(m[4],m[5],0));
    BRepBuilderAPI_GTransform placed(source,transform,true);
    require(placed.IsDone(),"operation_failed");
    return resource(env,placed.Shape());
  }
  if (op == "font_info") {
    arity(2);
    return font_info(env, a);
  }
  if (op == "text") {
    arity(7);
    return text_geometry(env, a);
  }
  if (op == "resource_count") {
    arity(0);
    return enif_make_uint64(env, state(env)->live_resources.load(std::memory_order_relaxed));
  }
  if (op == "version") {
    arity(0);
    return binary(env, OCC_VERSION_COMPLETE);
  }
  if (op == "box") {
    arity(3);
    double x = positive(env, a[0]), y = positive(env, a[1]), z = positive(env, a[2]);
    return resource(env, BRepPrimAPI_MakeBox(x, y, z).Shape());
  }
  if (op == "cylinder") {
    arity(2);
    double r = positive(env, a[0]), h = positive(env, a[1]);
    return resource(env, BRepPrimAPI_MakeCylinder(r, h).Shape());
  }
  if (op == "torus") {
    arity(2);
    double major = positive(env, a[0]), minor = positive(env, a[1]);
    require(major - minor > Precision::Confusion());
    return resource(env, BRepPrimAPI_MakeTorus(major, minor).Shape());
  }
  if (op == "mirror") {
    arity(3);
    auto body = copy(shape(env, a[0]).value);
    gp_Trsf transform;
    transform.SetMirror(gp_Ax2(xyz(env, a[1]), gp_Dir(vector(env, a[2], true))));
    return resource(env, BRepBuilderAPI_Transform(body, transform, true).Shape());
  }
  if (op == "sphere") {
    arity(1);
    return resource(env, BRepPrimAPI_MakeSphere(positive(env, a[0])).Shape());
  }
  if (op == "cone") {
    arity(3);
    double r1 = scalar(env, a[0]), r2 = scalar(env, a[1]), h = positive(env, a[2]);
    require(r1 >= 0 && r2 >= 0 && std::abs(r1 - r2) > Precision::Confusion());
    return resource(env, BRepPrimAPI_MakeCone(r1, r2, h).Shape());
  }
  if (op == "edge") {
    arity(2);
    auto from = xyz(env, a[0]), to = xyz(env, a[1]);
    require(from.Distance(to) > Precision::Confusion());
    BRepBuilderAPI_MakeEdge builder(from, to);
    require(builder.IsDone(), "operation_failed");
    return resource(env, builder.Edge());
  }
  if (op == "circle") {
    arity(1);
    gp_Circ circle(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), positive(env, a[0]));
    return resource(env, BRepBuilderAPI_MakeEdge(circle).Edge());
  }
  if (op == "arc") {
    arity(6);
    auto center = xyz(env, a[0]);
    auto normal = vector(env, a[1], true), x = vector(env, a[2], true);
    require(normal.Crossed(x).Magnitude() > Precision::Confusion());
    double radius = positive(env, a[3]), start = scalar(env, a[4]), sweep = scalar(env, a[5]);
    require(std::abs(sweep) > 1e-9 && std::abs(sweep) <= 360);
    gp_Circ circle(gp_Ax2(center, gp_Dir(normal), gp_Dir(x)), radius);
    double rad = std::acos(-1) / 180;
    auto curve =
        sweep > 0 ? GC_MakeArcOfCircle(circle, start * rad, (start + sweep) * rad, true).Value()
                  : GC_MakeArcOfCircle(circle, (start + sweep) * rad, start * rad, false).Value();
    return resource(env, BRepBuilderAPI_MakeEdge(curve).Edge());
  }
  if (op == "bezier") {
    arity(1);
    auto points = terms(env, a[0]);
    require(points.size() >= 2 && points.size() <= size_t(Geom_BezierCurve::MaxDegree() + 1));
    TColgp_Array1OfPnt poles(1, points.size());
    bool distinct = false;
    for (size_t i = 0; i < points.size(); ++i) {
      auto p = xyz(env, points[i]);
      if (i && p.Distance(poles.Value(1)) > Precision::Confusion())
        distinct = true;
      poles.SetValue(i + 1, p);
    }
    require(distinct);
    Handle(Geom_BezierCurve) curve = new Geom_BezierCurve(poles);
    BRepBuilderAPI_MakeEdge builder(curve);
    require(builder.IsDone(), "operation_failed");
    return resource(env, builder.Edge());
  }
  if (op == "spline") {
    arity(2);
    auto points = terms(env, a[0]);
    require(points.size() >= 2 && points.size() <= 100000);
    Handle(TColgp_HArray1OfPnt) values = new TColgp_HArray1OfPnt(1, points.size());
    for (size_t i = 0; i < points.size(); ++i) {
      auto p = xyz(env, points[i]);
      if (i)
        require(p.Distance(values->Value(i)) > 1e-6);
      values->SetValue(i + 1, p);
    }
    GeomAPI_Interpolate builder(values, false, 1e-6);
    if (!enif_is_identical(a[1], atom(env, "nil"))) {
      int count;
      const Term *tangents;
      require(enif_get_tuple(env, a[1], &count, &tangents) && count == 2);
      builder.Load(vector(env, tangents[0], true), vector(env, tangents[1], true), true);
    }
    builder.Perform();
    require(builder.IsDone(), "operation_failed");
    return resource(env, BRepBuilderAPI_MakeEdge(builder.Curve()).Edge());
  }
  if (op == "clean") {
    arity(1);
    ShapeUpgrade_UnifySameDomain builder(copy(shape(env, a[0]).value), true, true, true);
    builder.AllowInternalEdges(false);
    builder.Build();
    return resource(env, builder.Shape());
  }
  if (op == "edge_sample") {
    arity(2);
    auto edge = TopoDS::Edge(shape(env, a[0], TopAbs_EDGE).value);
    double fraction = scalar(env, a[1]);
    require(fraction >= 0 && fraction <= 1);
    bool reversed = edge.Orientation() == TopAbs_REVERSED;
    if (reversed)
      fraction = 1 - fraction;
    BRepAdaptor_Curve curve(edge);
    gp_Pnt p;
    gp_Vec tangent;
    curve.D1(curve.FirstParameter() + fraction * (curve.LastParameter() - curve.FirstParameter()),
             p, tangent);
    require(tangent.Magnitude() > Precision::Confusion(), "undefined_tangent");
    if (reversed)
      tangent.Reverse();
    return map(env, {{"point", point(env, p)}, {"tangent", direction(env, gp_Dir(tangent))}});
  }
  if (op == "closest_points") {
    arity(2);
    const auto &a_shape = shape(env, a[0]).value;
    const auto &b_shape = shape(env, a[1]).value;
    require(!subshapes(a_shape, TopAbs_VERTEX).empty() &&
            !subshapes(b_shape, TopAbs_VERTEX).empty(), "empty_shape");
    BRepExtrema_DistShapeShape distance(a_shape, b_shape);
    require(distance.IsDone() && distance.NbSolution() > 0, "operation_failed");
    return map(env, {{"distance", number(env, distance.Value())},
                     {"point_a", point(env, distance.PointOnShape1(1))},
                     {"point_b", point(env, distance.PointOnShape2(1))}});
  }
  if (op == "distance_to_point") {
    arity(2);
    BRepExtrema_DistShapeShape distance(shape(env, a[0]).value,
                                        BRepBuilderAPI_MakeVertex(xyz(env, a[1])).Shape());
    require(distance.IsDone(), "operation_failed");
    return number(env, distance.Value());
  }
  if (op == "wire") {
    arity(1);
    auto edges = terms(env, a[0]);
    require(!edges.empty());
    BRepBuilderAPI_MakeWire builder;
    for (auto edge : edges) {
      builder.Add(TopoDS::Edge(copy(shape(env, edge, TopAbs_EDGE).value)));
      require(builder.IsDone(), "disconnected_wire");
    }
    return resource(env, builder.Wire());
  }
  if (op == "face") {
    arity(1);
    auto wire = TopoDS::Wire(copy(shape(env, a[0], TopAbs_WIRE).value));
    require(wire.Closed(), "open_wire");
    BRepBuilderAPI_MakeFace builder(wire, true);
    require(builder.IsDone(), "operation_failed");
    require(BRepCheck_Analyzer(builder.Face()).IsValid(), "invalid_shape");
    return resource(env, builder.Face());
  }
  if (op == "split" || op == "section") {
    arity(op == "split" ? 4 : 3);
    auto body = copy(shape(env, a[0]).value);
    std::vector<TopoDS_Shape> solids;
    leaves(body, TopAbs_SOLID, solids);
    require(!solids.empty(), "wrong_shape_type");
    const auto origin = xyz(env, a[1]);
    const gp_Dir normal(vector(env, a[2], true));
    auto plane = BRepBuilderAPI_MakeFace(gp_Pln(origin, normal)).Face();
    if (op == "section") {
      // Keep the planar tool as the result support, including at loft stations.
      auto result = boolean<BRepAlgoAPI_Common>(plane, body);
      auto faces = subshapes(result, TopAbs_FACE);
      for (auto &value : faces) {
        BRepAdaptor_Surface surface(TopoDS::Face(value));
        require(surface.GetType() == GeomAbs_Plane, "non_planar_profile");
        auto axes = surface.Plane().Position();
        gp_Vec direction = gp_Vec(axes.XDirection()).Crossed(gp_Vec(axes.YDirection()));
        if (value.Orientation() == TopAbs_REVERSED)
          direction.Reverse();
        if (direction.Dot(gp_Vec(normal)) < 0)
          value.Reverse();
      }
      return resource(env, collection(faces));
    }
    if (enif_is_identical(a[3], atom(env, "both"))) {
      auto result = boolean<BRepAlgoAPI_Splitter>(body, plane);
      return resource(env, collection(subshapes(result, TopAbs_SOLID)));
    }
    bool positive = enif_is_identical(a[3], atom(env, "positive"));
    require(positive || enif_is_identical(a[3], atom(env, "negative")));
    auto reference = origin.Translated(gp_Vec(normal) * (positive ? 1.0 : -1.0));
    auto half = BRepPrimAPI_MakeHalfSpace(plane, reference).Solid();
    auto result = boolean<BRepAlgoAPI_Common>(body, half);
    return resource(env, collection(subshapes(result, TopAbs_SOLID)));
  }
  if (op == "drawing") {
    arity(5);
    auto source = shape(env, a[0]).value;
    auto origin = xyz(env, a[1]);
    gp_Dir normal(vector(env, a[2], true)), x(vector(env, a[3], true));
    require(gp_Vec(normal).Crossed(gp_Vec(x)).Magnitude() > Precision::Confusion());
    require(enif_is_identical(a[4], atom(env, "true")) ||
            enif_is_identical(a[4], atom(env, "false")));
    return drawing(env, source, gp_Ax2(origin, normal, x),
                   enif_is_identical(a[4], atom(env, "true")));
  }
  if (op == "polylines") {
    arity(3);
    return polylines(env, shape(env, a[0]).value, positive(env, a[1]), positive(env, a[2]));
  }
  if (op == "project") {
    arity(4);
    const auto &source = shape(env, a[0]).value;
    const auto &target = shape(env, a[1]).value;
    if (enif_is_identical(a[2], atom(env, "parallel")))
      return resource(env, project_curves(source, target, gp_Dir(vector(env, a[3], true))));
    require(enif_is_identical(a[2], atom(env, "conical")));
    return resource(env, project_curves(source, target, xyz(env, a[3])));
  }
  if (op == "extrude") {
    if (a.size() != 2)
      arity(4);
    auto profile = copy(shape(env, a[0]).value);
    auto v = vector(env, a[1], true);
    bool both = false;
    double taper = 0;
    if (a.size() == 4) {
      both = enif_is_identical(a[2], atom(env, "true"));
      require(both || enif_is_identical(a[2], atom(env, "false")));
      taper = scalar(env, a[3]);
      require(std::abs(taper) < 90);
    }
    return resource(env, extrude_profile(profile, v, both, taper));
  }
  if (op == "extrude_until") {
    arity(4);
    auto profile = copy(shape(env, a[0]).value);
    gp_Dir direction(vector(env, a[1], true));
    gp_Pln target(xyz(env, a[2]), gp_Dir(vector(env, a[3], true)));
    return resource(env, extrude_until(profile, direction, target));
  }
  if (op == "revolve") {
    arity(4);
    auto face = copy(shape(env, a[0], TopAbs_FACE).value);
    gp_Ax1 axis(xyz(env, a[1]), gp_Dir(vector(env, a[2], true)));
    double angle = positive(env, a[3]);
    require(angle <= 360);
    return resource(env,
                    BRepPrimAPI_MakeRevol(face, axis, angle * std::acos(-1) / 180, true).Shape());
  }
  if (op == "loft") {
    arity(2);
    require(enif_is_identical(a[1], atom(env, "true")) ||
            enif_is_identical(a[1], atom(env, "false")));
    auto wires = terms(env, a[0]);
    require(wires.size() >= 2);
    BRepOffsetAPI_ThruSections builder(true, enif_is_identical(a[1], atom(env, "true")));
    for (auto wire : wires) {
      auto w = TopoDS::Wire(copy(shape(env, wire, TopAbs_WIRE).value));
      require(w.Closed(), "open_wire");
      builder.AddWire(w);
    }
    builder.Build();
    require(builder.IsDone(), "operation_failed");
    return resource(env, builder.Shape());
  }
  if (op == "sweep") {
    arity(4);
    auto profile = TopoDS::Wire(copy(shape(env, a[0], TopAbs_WIRE).value));
    auto path = TopoDS::Wire(copy(shape(env, a[1], TopAbs_WIRE).value));
    require(profile.Closed(), "open_wire");
    require(!path.Closed(), "closed_path");
    bool frenet = enif_is_identical(a[2], atom(env, "frenet"));
    require(frenet || enif_is_identical(a[2], atom(env, "corrected")));
    BRepBuilderAPI_MakeFace face(profile, true);
    require(face.IsDone(), "non_planar_profile");
    require(BRepCheck_Analyzer(face.Face()).IsValid(), "invalid_shape");
    BRepTools_WireExplorer explorer(path);
    require(explorer.More(), "empty_path");
    auto start = explorer.CurrentVertex();
    BRepAdaptor_Curve curve(explorer.Current());
    gp_Pnt p;
    gp_Vec tangent;
    curve.D1(explorer.Current().Orientation() == TopAbs_REVERSED ? curve.LastParameter()
                                                                 : curve.FirstParameter(),
             p, tangent);
    require(tangent.Magnitude() > Precision::Confusion(), "undefined_tangent");
    auto plane = BRepAdaptor_Surface(face.Face()).Plane();
    require(plane.Distance(BRep_Tool::Pnt(start)) <= Precision::Confusion() &&
                std::abs(plane.Axis().Direction().Dot(gp_Dir(tangent))) > 1 - 1e-7,
            "misaligned_profile");
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(path, TopAbs_EDGE, edges);
    int traversed = 0;
    for (; explorer.More(); explorer.Next())
      ++traversed;
    require(traversed == edges.Extent(), "invalid_path");
    BRepOffsetAPI_MakePipeShell builder(path);
    builder.SetMode(frenet);
    if (enif_is_identical(a[3], atom(env, "round")))
      builder.SetTransitionMode(BRepBuilderAPI_RoundCorner);
    else if (enif_is_identical(a[3], atom(env, "right")))
      builder.SetTransitionMode(BRepBuilderAPI_RightCorner);
    else {
      require(enif_is_identical(a[3], atom(env, "transformed")));
      builder.SetTransitionMode(BRepBuilderAPI_Transformed);
    }
    builder.Add(profile, start, false, false);
    builder.Build();
    require(builder.IsDone(), "operation_failed");
    require(builder.MakeSolid(), "invalid_solid");
    require(properties(builder.Shape(), "volume").Mass() > 1e-9, "invalid_solid");
    return resource(env, builder.Shape());
  }
  if (op == "sew") {
    arity(1);
    auto faces = terms(env, a[0]);
    require(!faces.empty(), "empty_selection");
    TopTools_IndexedMapOfShape selected;
    BRepBuilderAPI_Sewing builder(Precision::Confusion());
    for (auto face : faces) {
      const auto &value = shape(env, face, TopAbs_FACE).value;
      require(!selected.Contains(value), "duplicate_subshape");
      selected.Add(value);
      builder.Add(copy(value));
    }
    builder.Perform();
    require(builder.NbMultipleEdges() == 0, "non_manifold_surface");
    require(!builder.SewedShape().IsNull(), "sewing_failed");
    return resource(env, builder.SewedShape());
  }
  if (op == "offset" || op == "thicken") {
    arity(3);
    auto &source = shape(env, a[0]).value;
    double distance = scalar(env, a[1]);
    require(std::abs(distance) > Precision::Confusion());
    bool intersection = enif_is_identical(a[2], atom(env, "intersection"));
    require(intersection || enif_is_identical(a[2], atom(env, "arc")));
    return resource(env, offset_shape(source, distance,
                                      intersection ? GeomAbs_Intersection : GeomAbs_Arc,
                                      op == "thicken"));
  }
  if (op == "draft") {
    arity(6);
    auto &body = shape(env, a[0]);
    std::vector<TopoDS_Shape> solids;
    leaves(body.value, TopAbs_SOLID, solids);
    require(solids.size() == 1, "wrong_shape_type");
    auto faces = terms(env, a[1]);
    require(!faces.empty(), "empty_selection");
    gp_Dir pull(vector(env, a[2], true));
    double degrees = scalar(env, a[3]);
    require(std::abs(degrees) < 90);
    gp_Pln neutral(xyz(env, a[4]), gp_Dir(vector(env, a[5], true)));
    require(std::abs(pull.Dot(neutral.Axis().Direction())) > 1e-7, "invalid_direction");
    TopTools_IndexedMapOfShape members, selected;
    TopExp::MapShapes(body.value, TopAbs_FACE, members);
    for (auto face : faces) {
      auto &f = shape(env, face, TopAbs_FACE);
      require(f.revision == body.revision && members.Contains(f.value), "foreign_subshape");
      require(!selected.Contains(f.value), "duplicate_subshape");
      const auto type = BRepAdaptor_Surface(TopoDS::Face(f.value)).GetType();
      require(type == GeomAbs_Plane || type == GeomAbs_Cylinder || type == GeomAbs_Cone,
              "unsupported_draft_surface");
      selected.Add(f.value);
    }
    BRepBuilderAPI_Copy copier(solids.front(), true, false);
    if (degrees == 0)
      return resource(env, copier.Shape());
    BRepOffsetAPI_DraftAngle builder(copier.Shape());
    for (int i = 1; i <= selected.Extent(); ++i) {
      builder.Add(TopoDS::Face(copier.ModifiedShape(selected(i))), pull,
                  degrees * std::acos(-1) / 180, neutral);
      require(builder.AddDone(), "draft_failed");
    }
    builder.Build();
    require(builder.IsDone(), "draft_failed");
    auto result = builder.Shape();
    require(result.ShapeType() == TopAbs_SOLID && properties(result, "volume").Mass() > 1e-9,
            "invalid_solid");
    return resource(env, result);
  }
  if (op == "shell") {
    arity(4);
    auto &body = shape(env, a[0]);
    std::vector<TopoDS_Shape> solids;
    leaves(body.value, TopAbs_SOLID, solids);
    require(solids.size() == 1, "wrong_shape_type");
    auto faces = terms(env, a[1]);
    require(!faces.empty(), "empty_selection");
    double thickness = scalar(env, a[2]);
    require(std::abs(thickness) > Precision::Confusion());
    GeomAbs_JoinType join = GeomAbs_Arc;
    if (enif_is_identical(a[3], atom(env, "intersection")))
      join = GeomAbs_Intersection;
    else
      require(enif_is_identical(a[3], atom(env, "arc")));
    TopTools_IndexedMapOfShape members, selected;
    TopExp::MapShapes(body.value, TopAbs_FACE, members);
    for (auto face : faces) {
      auto &f = shape(env, face, TopAbs_FACE);
      require(f.revision == body.revision && members.Contains(f.value), "foreign_subshape");
      require(!selected.Contains(f.value), "duplicate_subshape");
      selected.Add(f.value);
    }
    BRepBuilderAPI_Copy copier(solids.front(), true, false);
    TopTools_ListOfShape openings;
    for (int i = 1; i <= selected.Extent(); ++i)
      openings.Append(copier.ModifiedShape(selected(i)));
    BRepOffsetAPI_MakeThickSolid builder;
    builder.MakeThickSolidByJoin(copier.Shape(), openings, thickness, Precision::Confusion(),
                                 BRepOffset_Skin, false, false, join);
    require(builder.IsDone(), "operation_failed");
    auto result = builder.Shape();
    require(result.ShapeType() == TopAbs_SOLID && properties(result, "volume").Mass() > 1e-9,
            "invalid_solid");
    if (thickness < 0) {
      double original_volume = properties(body.value, "volume").Mass();
      double tolerance = std::max(1e-9, original_volume * 1e-9);
      require(properties(result, "volume").Mass() < original_volume - tolerance,
              "invalid_thickness");
      auto outside = boolean<BRepAlgoAPI_Cut>(result, body.value);
      require(std::abs(properties(outside, "volume").Mass()) <= tolerance, "invalid_thickness");
    }
    return resource(env, result);
  }
  if (op == "compound") {
    arity(1);
    BRep_Builder builder;
    TopoDS_Compound result;
    builder.MakeCompound(result);
    for (auto item : terms(env, a[0]))
      builder.Add(result, copy(shape(env, item).value));
    return resource(env, result);
  }
  if (op == "cut_removed") {
    arity(2);
    TopTools_ListOfShape arguments, tools, all;
    arguments.Append(copy(shape(env, a[0]).value));
    tools.Append(copy(shape(env, a[1]).value));
    all.Append(arguments.First());
    all.Append(tools.First());
    // Cut and common use the same intersections. Share the expensive
    // interference calculation rather than running two complete booleans.
    BOPAlgo_PaveFiller filler;
    filler.SetArguments(all);
    filler.SetNonDestructive(true);
    filler.SetRunParallel(false);
    filler.Perform();
    require(!filler.HasErrors(), "operation_failed");
    BRepAlgoAPI_Cut cut(filler);
    cut.SetArguments(arguments);
    cut.SetTools(tools);
    cut.SetNonDestructive(true);
    cut.Build();
    require(cut.IsDone() && !cut.HasErrors(), "operation_failed");
    Term result = resource(env, cut.Shape());
    BRepAlgoAPI_Common common(filler);
    common.SetArguments(arguments);
    common.SetTools(tools);
    common.SetNonDestructive(true);
    common.Build();
    require(common.IsDone() && !common.HasErrors(), "operation_failed");
    require(BRepCheck_Analyzer(common.Shape()).IsValid(), "invalid_shape");
    return enif_make_tuple2(env, result, number(env, properties(common.Shape(), "volume").Mass()));
  }
  if (op == "cut_many" || op == "fuse_many") {
    arity(2);
    auto &body = shape(env, a[0]).value;
    std::vector<TopoDS_Shape> tools;
    for (auto item : terms(env, a[1]))
      tools.push_back(shape(env, item).value);
    require(!tools.empty());
    if (op == "cut_many")
      return resource(env, boolean_many<BRepAlgoAPI_Cut>(body, tools));
    return resource(env, boolean_many<BRepAlgoAPI_Fuse>(body, tools));
  }
  if (op == "cut" || op == "fuse" || op == "common") {
    arity(2);
    auto &left = shape(env, a[0]).value;
    auto &right = shape(env, a[1]).value;
    if (op == "cut")
      return resource(env, boolean<BRepAlgoAPI_Cut>(left, right));
    if (op == "fuse")
      return resource(env, boolean<BRepAlgoAPI_Fuse>(left, right));
    return resource(env, boolean<BRepAlgoAPI_Common>(left, right));
  }
  if (op == "transform_chain") {
    arity(2);
    const auto &body = shape(env, a[0]).value;
    auto steps = terms(env, a[1]);
    require(!steps.empty());
    // Be conservative outside ordinary modeling coordinates. Cancellation at
    // extreme magnitudes can hide an invalid intermediate shape; the evaluator
    // must replay those operations with their original validation boundaries.
    Bnd_Box bounds;
    BRepBndLib::Add(body, bounds, false);
    require(!bounds.IsVoid() && !bounds.IsOpen());
    double x0, y0, z0, x1, y1, z1;
    bounds.Get(x0, y0, z0, x1, y1, z1);
    for (double value : {x0, y0, z0, x1, y1, z1})
      require(std::isfinite(value) && std::abs(value) <= 1.0e6);
    gp_Trsf combined;
    for (Term step : steps) {
      int count;
      const Term *pair;
      require(enif_get_tuple(env, step, &count, &pair) && count == 2);
      auto args = terms(env, pair[1]);
      gp_Trsf next;
      if (enif_is_identical(pair[0], atom(env, "translate"))) {
        require(args.size() == 1);
        next.SetTranslation(vector(env, args[0]));
      } else if (enif_is_identical(pair[0], atom(env, "rotate"))) {
        require(args.size() == 3);
        next.SetRotation(gp_Ax1(xyz(env, args[0]), gp_Dir(vector(env, args[1], true))),
                         scalar(env, args[2]) * std::acos(-1) / 180);
      } else if (enif_is_identical(pair[0], atom(env, "mirror"))) {
        require(args.size() == 2);
        next.SetMirror(gp_Ax2(xyz(env, args[0]), gp_Dir(vector(env, args[1], true))));
      } else {
        throw Error{"invalid_argument"};
      }
      // Each following operation acts in world space: next * combined.
      combined.PreMultiply(next);
      for (int row = 1; row <= 3; ++row)
        for (int col = 1; col <= 4; ++col)
          require(std::isfinite(combined.Value(row, col)) &&
                  std::abs(combined.Value(row, col)) <= 1.0e6);
    }
    return resource(env, BRepBuilderAPI_Transform(body, combined, true).Shape());
  }
  if (op == "translate" || op == "rotate" || op == "scale") {
    arity(op == "rotate" ? 4 : 2);
    const auto &body = shape(env, a[0]).value;
    gp_Trsf transform;
    if (op == "translate")
      transform.SetTranslation(vector(env, a[1]));
    else if (op == "scale")
      transform.SetScale(gp_Pnt(0, 0, 0), positive(env, a[1]));
    else
      transform.SetRotation(gp_Ax1(xyz(env, a[1]), gp_Dir(vector(env, a[2], true))),
                            scalar(env, a[3]) * std::acos(-1) / 180);
    // Copy=true already duplicates the topology and geometry. An explicit
    // BRepBuilderAPI_Copy before it duplicated the whole shape a second time.
    return resource(env, BRepBuilderAPI_Transform(body, transform, true).Shape());
  }
  if (op == "fillet" || op == "chamfer") {
    arity(3);
    auto &body = shape(env, a[0]);
    auto edges = terms(env, a[1]);
    require(!edges.empty());
    double radius = positive(env, a[2]);
    TopTools_IndexedMapOfShape members, selected;
    TopExp::MapShapes(body.value, TopAbs_EDGE, members);
    for (auto edge : edges) {
      auto &e = shape(env, edge, TopAbs_EDGE);
      require(e.revision == body.revision && members.Contains(e.value), "foreign_subshape");
      require(!selected.Contains(e.value), "duplicate_subshape");
      selected.Add(e.value);
    }
    BRepBuilderAPI_Copy copier(body.value, true, false);
    auto copied = copier.Shape();
    if (op == "fillet") {
      BRepFilletAPI_MakeFillet builder(copied);
      for (int i = 1; i <= selected.Extent(); ++i)
        builder.Add(radius, TopoDS::Edge(copier.ModifiedShape(selected(i))));
      builder.Build();
      require(builder.IsDone(), "operation_failed");
      require(BRepCheck_Analyzer(builder.Shape()).IsValid(), "invalid_shape");
      return resource(env, builder.Shape());
    }
    BRepFilletAPI_MakeChamfer builder(copied);
    for (int i = 1; i <= selected.Extent(); ++i)
      builder.Add(radius, TopoDS::Edge(copier.ModifiedShape(selected(i))));
    builder.Build();
    require(builder.IsDone(), "operation_failed");
    require(BRepCheck_Analyzer(builder.Shape()).IsValid(), "invalid_shape");
    return resource(env, builder.Shape());
  }
  for (auto kind :
       {TopAbs_VERTEX, TopAbs_EDGE, TopAbs_WIRE, TopAbs_FACE, TopAbs_SHELL, TopAbs_SOLID}) {
    std::string plural = kind == TopAbs_VERTEX ? "vertices" : std::string(type_name(kind)) + "s";
    if (op == plural) {
      arity(1);
      auto &body = shape(env, a[0]);
      TopTools_IndexedMapOfShape items;
      TopExp::MapShapes(body.value, kind, items);
      std::vector<Term> result;
      for (int i = 1; i <= items.Extent(); ++i)
        result.push_back(resource(env, items(i), body.revision));
      return list(env, result);
    }
  }
  if (op == "same") {
    arity(2);
    return atom(env, shape(env, a[0]).value.IsSame(shape(env, a[1]).value) ? "true" : "false");
  }
  if (op == "shape_type") {
    arity(1);
    return atom(env, type_name(shape(env, a[0]).value.ShapeType()));
  }
  if (op == "valid") {
    arity(1);
    return atom(env, BRepCheck_Analyzer(shape(env, a[0]).value).IsValid() ? "true" : "false");
  }
  if (op == "volume" || op == "area" || op == "length" || op == "center_of_mass") {
    arity(1);
    auto &body = shape(env, a[0]);
    if (op == "volume" && body.has_volume)
      return number(env, body.volume);
    auto props = properties(body.value, op);
    if (op == "center_of_mass") {
      require(std::abs(props.Mass()) > 0, "empty_shape");
      return point(env, props.CentreOfMass());
    }
    auto result = number(env, props.Mass());
    if (op == "volume") {
      body.volume = props.Mass();
      body.has_volume = true;
    }
    return result;
  }
  if (op == "bounds" || op == "bounds_envelope") {
    arity(1);
    Bnd_Box box;
    if (op == "bounds_envelope")
      BRepBndLib::Add(shape(env, a[0]).value, box, false);
    else
      BRepBndLib::AddOptimal(shape(env, a[0]).value, box, false, false);
    require(!box.IsVoid(), "empty_shape");
    double x0, y0, z0, x1, y1, z1;
    box.Get(x0, y0, z0, x1, y1, z1);
    return enif_make_tuple2(env, point(env, gp_Pnt(x0, y0, z0)), point(env, gp_Pnt(x1, y1, z1)));
  }
  if (op == "edge_info") {
    arity(1);
    return edge_info(env, TopoDS::Edge(shape(env, a[0], TopAbs_EDGE).value));
  }
  if (op == "face_info") {
    arity(1);
    return face_info(env, TopoDS::Face(shape(env, a[0], TopAbs_FACE).value));
  }
  if (op == "point") {
    arity(1);
    return point(env, BRep_Tool::Pnt(TopoDS::Vertex(shape(env, a[0], TopAbs_VERTEX).value)));
  }
  if (op == "mesh") {
    arity(3);
    return mesh(env, shape(env, a[0]).value, positive(env, a[1]), positive(env, a[2]));
  }
  if (op == "to_brep") {
    arity(1);
    std::ostringstream stream;
    BRepTools::Write(shape(env, a[0]).value, stream);
    require(stream.good(), "io_error");
    return binary(env, stream.str());
  }
  if (op == "from_brep") {
    arity(1);
    auto data = string(env, a[0]);
    require(data.find("CASCADE Topology") != std::string::npos, "invalid_brep");
    std::istringstream stream(data);
    // OCCT's reader assumes successful numeric extraction. Stop immediately on
    // truncated input rather than letting it consume uninitialized values.
    stream.exceptions(std::ios::failbit | std::ios::badbit);
    TopoDS_Shape result;
    BRep_Builder builder;
    try {
      BRepTools::Read(result, stream, builder);
    } catch (const std::ios_base::failure &) {
      throw Error{"invalid_brep"};
    }
    require(!result.IsNull() && !stream.fail(), "invalid_brep");
    require(BRepCheck_Analyzer(result).IsValid(), "invalid_shape");
    return resource(env, result);
  }
  if (op == "write_step") {
    arity(2);
    auto body = copy(shape(env, a[0]).value);
    auto path = string(env, a[1], true);
    STEPControl_Writer writer;
    require(writer.Transfer(body, STEPControl_AsIs) == IFSelect_RetDone, "operation_failed");
    require(writer.Write(path.c_str()) == IFSelect_RetDone, "io_error");
    return atom(env, "ok");
  }
  if (op == "read_step") {
    arity(1);
    auto path = string(env, a[0], true);
    STEPControl_Reader reader;
    require(reader.ReadFile(path.c_str()) == IFSelect_RetDone, "io_error");
    require(reader.TransferRoots() > 0, "invalid_shape");
    auto result = reader.OneShape();
    require(!result.IsNull() && BRepCheck_Analyzer(result).IsValid(), "invalid_shape");
    return resource(env, result);
  }
  if (op == "write_stl") {
    arity(4);
    auto body = triangulate(shape(env, a[0]).value, positive(env, a[2]), positive(env, a[3]));
    auto path = string(env, a[1], true);
    StlAPI_Writer writer;
    writer.ASCIIMode() = false;
    require(writer.Write(body, path.c_str()), "io_error");
    return atom(env, "ok");
  }
  throw Error{"invalid_argument"};
}

Term call(ErlNifEnv *env, int argc, const Term argv[]) {
  try {
    require(argc == 2);
    char operation[64];
    require(enif_get_atom(env, argv[0], operation, sizeof(operation), ERL_NIF_LATIN1));
    auto args = terms(env, argv[1]);
    std::lock_guard<std::mutex> lock(state(env)->mutex);
    Term value = execute(env, operation, args);
    return enif_make_tuple2(env, atom(env, "ok"), value);
  } catch (const Error &error) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, error.reason));
  } catch (const Standard_Failure &) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, "kernel_error"));
  } catch (const std::bad_alloc &) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, "out_of_memory"));
  } catch (...) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, "native_error"));
  }
}
void destroy(ErlNifEnv *, void *object) {
  auto *shape = static_cast<Shape *>(object);
  auto *live = shape->live_resources;
  shape->~Shape();
  live->fetch_sub(1, std::memory_order_relaxed);
}
int load(ErlNifEnv *env, void **data, Term) {
  auto *s = new (std::nothrow) State;
  if (!s)
    return -1;
  s->shape_type =
      enif_open_resource_type(env, nullptr, "ocex_shape", destroy, ERL_NIF_RT_CREATE, nullptr);
  if (!s->shape_type) {
    delete s;
    return -1;
  }
  *data = s;
  return 0;
}
void unload(ErlNifEnv *, void *data) {
  delete static_cast<State *>(data);
}
ErlNifFunc functions[] = {{"call", 2, call, ERL_NIF_DIRTY_JOB_CPU_BOUND}};
} // namespace
ERL_NIF_INIT(Elixir.OCEx.Native, functions, load, nullptr, nullptr, unload)
