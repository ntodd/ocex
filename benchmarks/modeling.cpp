// Standalone experiments: no benchmark switches are exposed in the NIF.
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepTools.hxx>
#include <GProp_GProps.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>
using Clock = std::chrono::steady_clock;
using Shape = TopoDS_Shape;
struct Times {
  double copy = 0, build = 0, validate = 0, clean = 0, serialize = 0, total = 0;
};
template <class F> double time(F f) {
  auto t = Clock::now();
  f();
  return std::chrono::duration<double, std::micro>(Clock::now() - t).count();
}
void require(bool b) {
  if (!b)
    throw std::runtime_error("geometry check failed");
}
Shape copy(const Shape &s) {
  return BRepBuilderAPI_Copy(s, true, false).Shape();
}
void valid(const Shape &s) {
  require(!s.IsNull() && BRepCheck_Analyzer(s).IsValid());
}
std::string brep(const Shape &s) {
  std::ostringstream out;
  BRepTools::Write(s, out);
  return out.str();
}
double volume(const Shape &s) {
  GProp_GProps p;
  BRepGProp::VolumeProperties(s, p);
  return p.Mass();
}
Shape clean(const Shape &s) {
  ShapeUpgrade_UnifySameDomain c(copy(s), true, true, true);
  c.Build();
  valid(c.Shape());
  return c.Shape();
}
template <class Op>
Shape operation(const Shape &body, const std::vector<Shape> &tools, bool copies, bool parallel,
                Times &t) {
  TopTools_ListOfShape a, b;
  t.copy += time([&] {
    a.Append(copies ? copy(body) : body);
    for (const auto &s : tools)
      b.Append(copies ? copy(s) : s);
  });
  Op op;
  op.SetArguments(a);
  op.SetTools(b);
  op.SetNonDestructive(true);
  op.SetRunParallel(parallel);
  t.build += time([&] {
    op.Build();
    require(op.IsDone() && !op.HasErrors());
  });
  Shape result = op.Shape();
  t.validate += time([&] { valid(result); });
  return result;
}
void report(const std::string &name, int samples, const std::function<Times()> &run) {
  for (int i = 0; i < 2; ++i)
    run();
  for (int i = 0; i < samples; ++i) {
    Times t = run();
    std::cout << name << "," << i << "," << t.copy << "," << t.build << "," << t.validate << ","
              << t.clean << "," << t.serialize << "," << t.total << std::endl;
  }
}
int main(int argc, char **argv) {
  try {
    int samples = argc > 1 ? std::stoi(argv[1]) : 9;
    require(samples > 0);
    std::cout << "case,sample,copy_us,kernel_us,validate_us,clean_us,serialize_us,total_us\n";
    for (int n : {1, 8, 32}) {
      Shape plate = BRepPrimAPI_MakeBox(80, 80, 4).Shape();
      std::vector<Shape> cutters, ribs;
      for (int i = 0; i < n; ++i) {
        cutters.push_back(
            BRepPrimAPI_MakeCylinder(
                gp_Ax2(gp_Pnt(5 + 10 * (i % 8), 5 + 18 * (i / 8), -1), gp_Dir(0, 0, 1)), 2, 6)
                .Shape());
        ribs.push_back(BRepPrimAPI_MakeBox(gp_Pnt(0, 2 + i * 2.3, 2), 80, 1, 4).Shape());
      }
      std::string original = brep(plate);
      for (bool fuse : {false, true})
        for (bool batch : {false, true})
          for (bool copies : {true, false})
            for (bool parallel : {false, true}) {
              // Parallel tests on batched work only; serial chains duplicate that overhead.
              if (parallel && !batch)
                continue;
              std::string name = std::string(fuse ? "fuse" : "cut") + "/" + std::to_string(n) +
                                 (batch ? "/batch" : "/chain") + (copies ? "/copy" : "/share") +
                                 (parallel ? "/parallel" : "/serial");
              const auto &tools = fuse ? ribs : cutters;
              std::vector<std::string> originals;
              for (const auto &s : tools)
                originals.push_back(brep(s));
              report(name, samples, [&] {
                Times t;
                Shape result;
                t.total = time([&] {
                  result = plate;
                  auto step = [&](const std::vector<Shape> &ts) {
                    result = fuse ? operation<BRepAlgoAPI_Fuse>(result, ts, copies, parallel, t)
                                  : operation<BRepAlgoAPI_Cut>(result, ts, copies, parallel, t);
                    t.clean += time([&] { result = clean(result); });
                  };
                  if (batch)
                    step(tools);
                  else
                    for (const auto &s : tools)
                      step({s});
                  t.serialize = time([&] { require(!brep(result).empty()); });
                });
                double expected = fuse ? 25600 + n * 160 : 25600 - n * 16 * std::acos(-1.0);
                require(std::abs(volume(result) - expected) < 1e-5);
                require(brep(plate) == original);
                for (size_t i = 0; i < tools.size(); ++i)
                  require(brep(tools[i]) == originals[i]);
                return t;
              });
            }
    }
    Shape box = BRepPrimAPI_MakeBox(80, 60, 10).Shape();
    report("fillet/box/all_edges", samples, [&] {
      Times t;
      Shape body, result;
      t.total = time([&] {
        t.copy = time([&] { body = copy(box); });
        t.build = time([&] {
          BRepFilletAPI_MakeFillet f(body);
          for (TopExp_Explorer e(body, TopAbs_EDGE); e.More(); e.Next())
            f.Add(1.0, TopoDS::Edge(e.Current()));
          f.Build();
          require(f.IsDone());
          result = f.Shape();
        });
        t.validate = time([&] { valid(result); });
        t.clean = time([&] { result = clean(result); });
        t.serialize = time([&] { require(!brep(result).empty()); });
      });
      require(volume(result) > 0 && volume(result) < 48000);
      return t;
    });
  } catch (const Standard_Failure &e) {
    std::cerr << e.GetMessageString() << std::endl;
    return 1;
  } catch (const std::exception &e) {
    std::cerr << e.what() << std::endl;
    return 1;
  }
}
