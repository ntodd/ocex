defmodule OCEx.GeometryTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "reports the native toolkit version" do
    assert {:ok, version} = OCEx.version()
    assert version =~ ~r/^7\./
  end

  test "box dimensions, volume, area and centroid" do
    body = ok(OCEx.box(10, 20, 30))
    assert_valid(body)
    assert OCEx.shape_type(body) == {:ok, :solid}
    assert_in_delta volume(body), 6000, 1.0e-7
    assert_in_delta ok(OCEx.area(body)), 2200, 1.0e-7
    close_point(ok(OCEx.center_of_mass(body)), {5, 10, 15})
    {low, high} = ok(OCEx.bounds(body))
    close_point(low, {0, 0, 0})
    close_point(high, {10, 20, 30})
  end

  for {name, args, expected} <- [
        {:cylinder, [3, 7], :math.pi() * 9 * 7},
        {:sphere, [3], 4 / 3 * :math.pi() * 27},
        {:cone, [3, 0, 7], :math.pi() * 9 * 7 / 3},
        {:cone, [3, 1, 7], :math.pi() * 7 * 13 / 3}
      ] do
    test "#{name} #{inspect(args)} has its analytic volume" do
      body = ok(apply(OCEx, unquote(name), unquote(args)))
      assert_valid(body)
      assert_in_delta volume(body), unquote(expected), 1.0e-6
    end
  end

  test "topology is unique and retains OCEx types" do
    body = ok(OCEx.box(1, 2, 3))

    for {op, count, type} <- [
          {:vertices, 8, :vertex},
          {:edges, 12, :edge},
          {:wires, 6, :wire},
          {:faces, 6, :face},
          {:shells, 1, :shell},
          {:solids, 1, :solid}
        ] do
      items = ok(apply(OCEx, op, [body]))
      assert Enum.count(items) == count
      assert Enum.all?(items, &(OCEx.shape_type(&1) == {:ok, type}))
    end

    points = body |> OCEx.vertices() |> ok() |> Enum.map(&ok(OCEx.point(&1)))

    assert Enum.sort(points) ==
             Enum.sort(for x <- [0.0, 1.0], y <- [0.0, 2.0], z <- [0.0, 3.0], do: {x, y, z})
  end

  test "native identity differs from geometric equality" do
    a = ok(OCEx.box(1, 2, 3))
    b = ok(OCEx.box(1, 2, 3))
    assert OCEx.same?(a, a) == {:ok, true}
    assert OCEx.same?(a, b) == {:ok, false}
    assert MapSet.size(MapSet.new([a, a, b])) == 2
    [face | _] = ok(OCEx.faces(a))
    [again | _] = ok(OCEx.faces(a))
    assert OCEx.same?(face, again) == {:ok, true}
  end

  test "compound preserves independently enumerable solids" do
    a = ok(OCEx.box(1, 2, 3))
    b = ok(OCEx.translate(a, {10, 0, 0}))
    body = ok(OCEx.compound([a, b]))
    assert OCEx.shape_type(body) == {:ok, :compound}
    assert Enum.count(ok(OCEx.solids(body))) == 2
    assert_in_delta volume(body), 12, 1.0e-8
    empty = ok(OCEx.compound([]))
    assert OCEx.solids(empty) == {:ok, []}
    assert OCEx.bounds(empty) == {:error, :empty_shape}
  end

  test "line geometry exposes endpoints, length and direction" do
    edge = ok(OCEx.edge({1, 2, 3}, {1, 2, 8}))
    info = ok(OCEx.edge_info(edge))
    assert info.type == :line
    close_point(info.start, {1, 2, 3})
    close_point(info.end, {1, 2, 8})
    close_point(info.direction, {0, 0, 1})
    assert_in_delta info.length, 5, 1.0e-9
    assert_in_delta ok(OCEx.length(edge)), 5, 1.0e-9
  end

  test "circle and sphere expose correct curved geometry and parameter bounds" do
    circle = ok(OCEx.circle(4))
    info = ok(OCEx.edge_info(circle))
    assert info.type == :circle
    assert_in_delta info.radius, 4, 1.0e-9
    assert_in_delta info.length, 8 * :math.pi(), 1.0e-7
    sphere = ok(OCEx.sphere(3))
    [face] = ok(OCEx.faces(sphere))
    surface = ok(OCEx.face_info(face))
    assert surface.type == :sphere
    assert_in_delta surface.radius, 3, 1.0e-9
    {u0, u1, v0, v1} = surface.uv_bounds
    assert_in_delta u0, 0, 1.0e-9
    assert_in_delta u1, 2 * :math.pi(), 1.0e-9
    assert_in_delta v0, -:math.pi() / 2, 1.0e-9
    assert_in_delta v1, :math.pi() / 2, 1.0e-9
  end

  test "planar faces report outward normals and centroids" do
    body = ok(OCEx.box(10, 20, 30))
    infos = body |> OCEx.faces() |> ok() |> Enum.map(&ok(OCEx.face_info(&1)))
    top = Enum.max_by(infos, &elem(&1.center, 2))
    bottom = Enum.min_by(infos, &elem(&1.center, 2))
    assert top.type == :plane
    close_point(top.normal, {0, 0, 1})
    close_point(bottom.normal, {0, 0, -1})
    close_point(top.center, {5, 10, 30})
    assert_in_delta top.area, 200, 1.0e-8
  end

  test "connected edges form an open wire; a closed planar wire forms a face" do
    a = ok(OCEx.edge({0, 0, 0}, {1, 0, 0}))
    b = ok(OCEx.edge({1, 0, 0}, {1, 1, 0}))
    wire = ok(OCEx.wire([a, b]))
    assert OCEx.shape_type(wire) == {:ok, :wire}
    assert_in_delta ok(OCEx.length(wire)), 2, 1.0e-8
    face = ok(OCEx.face(rectangle()))
    assert_valid(face)
    assert_in_delta ok(OCEx.area(face)), 200, 1.0e-8
  end

  test "extrusion and revolution produce expected solids" do
    face = ok(OCEx.face(rectangle()))
    body = ok(OCEx.extrude(face, {0, 0, 3}))
    assert_valid(body)
    assert_in_delta volume(body), 600, 1.0e-7
    ring_profile = rectangle(2, 3) |> OCEx.face() |> ok() |> OCEx.translate({4, 0, 0}) |> ok()
    ring = ok(OCEx.revolve(ring_profile, {0, 0, 0}, {0, 1, 0}, 360))
    assert_valid(ring)
    assert_in_delta volume(ring), :math.pi() * (36 - 16) * 3, 1.0e-5
  end

  test "loft between translated profiles forms a solid" do
    base = rectangle(10, 20)
    top = ok(OCEx.translate(base, {0, 0, 5}))
    body = ok(OCEx.loft([base, top]))
    assert_valid(body)
    assert_in_delta volume(body), 1000, 1.0e-6
  end
end
