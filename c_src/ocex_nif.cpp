#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GProp_GProps.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_TrimmedCurve.hxx>
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
#include <mutex>
#include <new>
#include <sstream>
#include <string>
#include <vector>

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
    BRepGProp::SurfaceProperties(value, props, true, false);
  else
    BRepGProp::VolumeProperties(value, props, true, true, false);
  return props;
}
Term edge_info(ErlNifEnv *env, const TopoDS_Edge &edge) {
  BRepAdaptor_Curve curve(edge);
  auto props = properties(edge, "length");
  const char *type = "other";
  Term radius = atom(env, "nil"), dir = atom(env, "nil");
  if (curve.GetType() == GeomAbs_Line) {
    type = "line";
    auto d = curve.Line().Direction();
    if (edge.Orientation() == TopAbs_REVERSED)
      d.Reverse();
    dir = direction(env, d);
  } else if (curve.GetType() == GeomAbs_Circle) {
    type = "circle";
    radius = number(env, curve.Circle().Radius());
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
    auto d = surface.Plane().Axis().Direction();
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
template <class Operation> TopoDS_Shape boolean(const TopoDS_Shape &a, const TopoDS_Shape &b) {
  Operation operation;
  TopTools_ListOfShape arguments, tools;
  arguments.Append(copy(a));
  tools.Append(copy(b));
  operation.SetArguments(arguments);
  operation.SetTools(tools);
  operation.SetNonDestructive(true);
  operation.SetRunParallel(false);
  operation.Build();
  require(operation.IsDone() && !operation.HasErrors(), "operation_failed");
  return operation.Shape();
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

Term execute(ErlNifEnv *env, const std::string &op, const std::vector<Term> &a) {
  auto arity = [&](size_t n) { require(a.size() == n); };
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
  if (op == "extrude") {
    arity(2);
    auto face = copy(shape(env, a[0], TopAbs_FACE).value);
    auto v = vector(env, a[1], true);
    BRepAdaptor_Surface surface(TopoDS::Face(face));
    require(surface.GetType() == GeomAbs_Plane, "non_planar_profile");
    require(std::abs(v.Dot(gp_Vec(surface.Plane().Axis().Direction()))) > Precision::Confusion(),
            "degenerate_extrusion");
    return resource(env, BRepPrimAPI_MakePrism(face, v, true).Shape());
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
    arity(1);
    auto wires = terms(env, a[0]);
    require(wires.size() >= 2);
    BRepOffsetAPI_ThruSections builder(true, true);
    for (auto wire : wires) {
      auto w = TopoDS::Wire(copy(shape(env, wire, TopAbs_WIRE).value));
      require(w.Closed(), "open_wire");
      builder.AddWire(w);
    }
    builder.Build();
    require(builder.IsDone(), "operation_failed");
    return resource(env, builder.Shape());
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
  if (op == "translate" || op == "rotate" || op == "scale") {
    arity(op == "rotate" ? 4 : 2);
    auto body = copy(shape(env, a[0]).value);
    gp_Trsf transform;
    if (op == "translate")
      transform.SetTranslation(vector(env, a[1]));
    else if (op == "scale")
      transform.SetScale(gp_Pnt(0, 0, 0), positive(env, a[1]));
    else
      transform.SetRotation(gp_Ax1(xyz(env, a[1]), gp_Dir(vector(env, a[2], true))),
                            scalar(env, a[3]) * std::acos(-1) / 180);
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
    auto props = properties(shape(env, a[0]).value, op);
    if (op == "center_of_mass") {
      require(std::abs(props.Mass()) > 0, "empty_shape");
      return point(env, props.CentreOfMass());
    }
    return number(env, props.Mass());
  }
  if (op == "bounds") {
    arity(1);
    Bnd_Box box;
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
