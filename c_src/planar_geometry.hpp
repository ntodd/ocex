// General XY artwork geometry. All operations run under the NIF execution lock.
std::vector<gp_Pnt> wire_samples(const TopoDS_Wire &wire, double tolerance, bool planar, double angular=0.1) {
  std::vector<gp_Pnt> points;
  for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
    BRepAdaptor_Curve curve(it.Current());
    GCPnts_TangentialDeflection sampled(curve, angular, tolerance, 2);
    require(sampled.NbPoints() <= 20000, "profile_too_complex");
    bool reverse = it.Current().Orientation() == TopAbs_REVERSED;
    for (int j = 1; j <= sampled.NbPoints(); ++j) {
      auto p = sampled.Value(reverse ? sampled.NbPoints() + 1 - j : j);
      if (planar) require(std::abs(p.Z()) < Precision::Confusion(), "nonplanar_profile");
      if (points.empty() || points.back().Distance(p) > Precision::Confusion())
        points.push_back(p);
    }
    require(points.size() <= 20000, "profile_too_complex");
  }
  require(points.size() >= 2, "invalid_profile");
  return points;
}
std::vector<gp_Pnt> planar_samples(const TopoDS_Wire &wire, double tolerance) {
  return wire_samples(wire, tolerance, true);
}
int planar_winding(const std::vector<gp_Pnt> &points, const gp_Pnt &p) {
  int winding = 0;
  for (size_t i = 1; i < points.size(); ++i) {
    const auto &a = points[i-1], &b = points[i];
    double cross = (b.X()-a.X())*(p.Y()-a.Y()) - (b.Y()-a.Y())*(p.X()-a.X());
    if (a.Y() <= p.Y() && b.Y() > p.Y() && cross > 0) ++winding;
    if (a.Y() > p.Y() && b.Y() <= p.Y() && cross < 0) --winding;
  }
  return winding;
}
double contour_distance(const std::vector<gp_Pnt> &points, const gp_Pnt &p) {
  double nearest=std::numeric_limits<double>::max();
  for (size_t i=1;i<points.size();++i) {
    gp_Vec line(points[i-1],points[i]), delta(points[i-1],p);
    double t=std::clamp(delta.Dot(line)/line.SquareMagnitude(),0.0,1.0);
    nearest=std::min(nearest,p.Distance(points[i-1].Translated(line*t)));
  }
  return nearest;
}
TopoDS_Shape planar_union(const std::vector<TopoDS_Shape> &faces) {
  if (faces.size() < 2) return collection(faces);
  // Bound the intersection graph for sampled strokes, cleaning internal
  // edges at each level before combining neighboring batches.
  if (faces.size() > 16) {
    std::vector<TopoDS_Shape> batches;
    for (size_t i=0; i<faces.size(); i+=16) {
      auto end=faces.begin()+std::min(i+16,faces.size());
      batches.push_back(planar_union(std::vector<TopoDS_Shape>(faces.begin()+i,end)));
    }
    return planar_union(batches);
  }
  BRepAlgoAPI_Fuse fuse;
  TopTools_ListOfShape args, tools;
  args.Append(faces.front());
  for (size_t i=1; i<faces.size(); ++i) tools.Append(faces[i]);
  fuse.SetArguments(args); fuse.SetTools(tools);
  fuse.SetNonDestructive(true); fuse.SetRunParallel(false); fuse.Build();
  require(fuse.IsDone() && !fuse.HasErrors(), "operation_failed");
  ShapeUpgrade_UnifySameDomain clean(fuse.Shape(), true, true, false);
  clean.Build();
  return clean.Shape();
}
TopoDS_Shape planar_fill(const std::vector<TopoDS_Wire> &wires, bool evenodd) {
  if (wires.empty()) return collection({});
  Bnd_Box bounds;
  TopTools_ListOfShape tools;
  std::vector<std::vector<gp_Pnt>> contours;
  size_t total_points=0, total_edges=0;
  for (auto &w : wires) {
    auto points = planar_samples(w, 0.00001);
    total_points+=points.size();
    require(total_points<=100000,"profile_too_complex");
    require(points.front().Distance(points.back()) < Precision::Confusion(), "open_wire");
    contours.push_back(points);
    BRepBndLib::AddOptimal(w, bounds, false, false);
    for (TopExp_Explorer edge(w, TopAbs_EDGE); edge.More(); edge.Next()) {
      require(++total_edges<=10000,"profile_too_complex");
      tools.Append(edge.Current());
    }
  }
  auto lo = bounds.CornerMin(), hi = bounds.CornerMax();
  double margin = std::max(1.0, lo.Distance(hi));
  auto plane = BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(0,0,0), gp_Dir(0,0,1)),
      lo.X()-margin, hi.X()+margin, lo.Y()-margin, hi.Y()+margin).Face();
  BRepAlgoAPI_Splitter split;
  TopTools_ListOfShape args; args.Append(plane);
  split.SetArguments(args); split.SetTools(tools); split.SetNonDestructive(true);
  split.SetRunParallel(false); split.Build();
  require(split.IsDone() && !split.HasErrors(), "invalid_profile");
  std::vector<TopoDS_Shape> faces;
  for (TopExp_Explorer it(split.Shape(), TopAbs_FACE); it.More(); it.Next()) {
    auto face = TopoDS::Face(it.Current());
    BRepMesh_IncrementalMesh mesh(face, 0.001, false, 0.1, false);
    TopLoc_Location loc;
    auto triangulation = BRep_Tool::Triangulation(face, loc);
    require(!triangulation.IsNull() && triangulation->NbTriangles() > 0, "invalid_profile");
    // Choose the largest triangle, keeping the sample well inside the region.
    gp_Pnt sample; double largest = -1;
    for (int i=1; i<=triangulation->NbTriangles(); ++i) {
      int a,b,c; triangulation->Triangle(i).Get(a,b,c);
      auto p=triangulation->Node(a), q=triangulation->Node(b), r=triangulation->Node(c);
      double area = gp_Vec(p,q).Crossed(gp_Vec(p,r)).SquareMagnitude();
      if (area>largest) { largest=area; sample=gp_Pnt((p.XYZ()+q.XYZ()+r.XYZ())/3); }
    }
    sample.Transform(loc.Transformation());
    int winding=0;
    for (size_t i=0;i<contours.size();++i) {
      double tolerance=0.00001;
      auto contour=contours[i];
      while (contour_distance(contour,sample)<=2*tolerance && tolerance>1e-8) {
        tolerance/=10;
        contour=planar_samples(wires[i],tolerance);
      }
      require(contour_distance(contour,sample)>2*tolerance,"ambiguous_profile");
      winding += planar_winding(contour,sample);
    }
    if (evenodd ? (std::abs(winding)%2 == 1) : winding != 0) faces.push_back(face);
  }
  return planar_union(faces);
}
TopoDS_Face planar_polygon(const std::vector<gp_Pnt> &points) {
  BRepBuilderAPI_MakeWire wire;
  for (size_t i=0; i<points.size(); ++i) {
    const auto &a=points[i], &b=points[(i+1)%points.size()];
    if (a.Distance(b)>Precision::Confusion()) wire.Add(BRepBuilderAPI_MakeEdge(a,b).Edge());
  }
  require(wire.IsDone(), "invalid_profile");
  BRepBuilderAPI_MakeFace face(wire.Wire(), true);
  require(face.IsDone(), "invalid_profile");
  auto result=face.Face();
  if (properties(result,"area").Mass()<0) result.Reverse();
  return result;
}
TopoDS_Shape planar_stroke(const TopoDS_Wire &wire, double width, const std::string &cap,
                          const std::string &join, double limit, double tolerance) {
  require(cap=="butt" || cap=="round" || cap=="square");
  require(join=="miter" || join=="round" || join=="bevel");
  require(limit>=1);
  // A circular centerline has exact circular offsets. In particular, when
  // the inner radius vanishes, sampled round joins create a numerically
  // singular intersection at the center; the correct result is a disk.
  bool circular=true, first=true;
  gp_Circ circle;
  double sweep=0;
  for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
    BRepAdaptor_Curve curve(it.Current());
    if (curve.GetType()!=GeomAbs_Circle) {circular=false;break;}
    auto current=curve.Circle();
    if (first) {circle=current;first=false;}
    if (std::abs(current.Location().Z())>Precision::Confusion() ||
        std::abs(current.Axis().Direction().Z())<1-1e-12 ||
        current.Location().Distance(circle.Location())>Precision::Confusion() ||
        std::abs(current.Radius()-circle.Radius())>Precision::Confusion()) {
      circular=false;break;
    }
    sweep+=curve.LastParameter()-curve.FirstParameter();
  }
  if (circular && !first && BRep_Tool::IsClosed(wire) && std::abs(sweep-2*M_PI)<1e-10 &&
      circle.Radius()-width/2<=Precision::Confusion()) {
    auto ring=[&](double radius) {
      auto edge=BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(circle.Location(),gp_Dir(0,0,1)),radius)).Edge();
      return BRepBuilderAPI_MakeWire(edge).Wire();
    };
    BRepBuilderAPI_MakeFace face(ring(circle.Radius()+width/2));
    require(face.IsDone(),"invalid_profile");
    return face.Face();
  }
  auto p=wire_samples(wire,tolerance,true,std::min(0.1,std::sqrt(tolerance/width)));
  bool closed=p.front().Distance(p.back())<Precision::Confusion();
  if (closed) p.pop_back();
  size_t n=p.size(), count=closed?n:n-1;
  require(count<=2000,"profile_too_complex");
  double r=width/2;
  std::vector<gp_Vec> directions, normals;
  std::vector<TopoDS_Shape> faces;
  auto disk=[&](const gp_Pnt &center) {
    auto edge=BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(center,gp_Dir(0,0,1)),r)).Edge();
    faces.push_back(BRepBuilderAPI_MakeFace(BRepBuilderAPI_MakeWire(edge).Wire()).Face());
  };
  for (size_t i=0;i<count;++i) {
    gp_Vec d(p[i],p[(i+1)%n]); d.Normalize();
    gp_Vec normal(-d.Y()*r,d.X()*r,0);
    directions.push_back(d); normals.push_back(normal);
    auto a=p[i], b=p[(i+1)%n];
    if (!closed && cap=="square") {
      if (i==0) a.Translate(-d*r);
      if (i+1==count) b.Translate(d*r);
    }
    faces.push_back(planar_polygon({a.Translated(normal),a.Translated(-normal),b.Translated(-normal),b.Translated(normal)}));
  }
  for (size_t i=closed?0:1;i<(closed?n:n-1);++i) {
    size_t before=(i+count-1)%count, after=i%count;
    const auto &a=directions[before], &b=directions[after];
    double cross=a.X()*b.Y()-a.Y()*b.X();
    if (join=="round") {disk(p[i]);continue;}
    if (std::abs(cross)<1e-10) continue;
    double sign=cross>0?-1:1;
    auto u=p[i].Translated(normals[before]*sign), v=p[i].Translated(normals[after]*sign);
    gp_Vec uv(u,v);
    double t=(uv.X()*b.Y()-uv.Y()*b.X())/cross;
    auto tip=u.Translated(a*t);
    if (join=="miter" && tip.Distance(p[i])<=limit*r)
      faces.push_back(planar_polygon({p[i],u,tip,v}));
    else faces.push_back(planar_polygon({p[i],u,v}));
  }
  if (!closed && cap=="round") {disk(p.front());disk(p.back());}
  return planar_union(faces);
}
