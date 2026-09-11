defmodule OCEx.IOLifetimeTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  @tag :tmp_dir
  test "BREP and STEP round trips preserve geometry", %{tmp_dir: dir} do
    a = ok(OCEx.box(8.189314010683498, 46.85954928498498, 14.39317846913498))
    b = ok(OCEx.sphere(18.12601828498498))
    body = ok(OCEx.fuse(a, b))
    data = ok(OCEx.to_brep(body))
    assert is_binary(data) and byte_size(data) > 100
    brep = ok(OCEx.from_brep(data))
    path = Path.join(dir, "round trip.step")
    assert {:ok, :ok} = OCEx.write_step(body, path)
    step = ok(OCEx.read_step(path))

    for result <- [brep, step] do
      assert_valid(result)
      assert_in_delta volume(result), volume(body), 1.0e-5
      close_point(ok(OCEx.center_of_mass(result)), ok(OCEx.center_of_mass(body)))
      assert Enum.count(ok(OCEx.solids(result))) == Enum.count(ok(OCEx.solids(body)))
    end
  end

  @tag :tmp_dir
  test "STL contains the generated mesh", %{tmp_dir: dir} do
    body = ok(OCEx.box(1, 2, 3))
    path = Path.join(dir, "box.stl")
    assert {:ok, :ok} = OCEx.write_stl(body, path)
    <<_header::binary-size(80), count::little-unsigned-32, triangles::binary>> = File.read!(path)
    assert count == 12
    assert byte_size(triangles) == count * 50
  end

  @tag :tmp_dir
  test "STEP export preserves a curved source for repeated exports", %{tmp_dir: dir} do
    body = ok(OCEx.cylinder(10, 5))
    before = ok(OCEx.to_brep(body))
    assert {:ok, :ok} = OCEx.write_step(body, Path.join(dir, "cylinder.step"))
    assert ok(OCEx.to_brep(body)) == before
  end

  test "mesh has valid indices, outward winding and independent signed volume" do
    body = ok(OCEx.box(10, 20, 30))
    mesh = ok(OCEx.mesh(body))
    assert Enum.count(mesh.triangles) == 12
    assert mesh.triangles_per_face == [2, 2, 2, 2, 2, 2]
    assert mesh.face_types == [0, 0, 0, 0, 0, 0]
    vertices = List.to_tuple(mesh.vertices)
    count = tuple_size(vertices)

    signed_volume =
      Enum.reduce(mesh.triangles, 0.0, fn {i, j, k}, sum ->
        assert Enum.all?([i, j, k], &(&1 >= 0 and &1 < count))
        {ax, ay, az} = elem(vertices, i)
        {bx, by, bz} = elem(vertices, j)
        {cx, cy, cz} = elem(vertices, k)
        sum + (ax * (by * cz - bz * cy) + ay * (bz * cx - bx * cz) + az * (bx * cy - by * cx)) / 6
      end)

    assert_in_delta signed_volume, 6000, 1.0e-6
    assert_in_delta volume(body), 6000, 1.0e-7
  end

  test "finer meshing improves a curved model and does not alter its geometry" do
    sphere = ok(OCEx.sphere(10))
    coarse = ok(OCEx.mesh(sphere, 1))
    fine = ok(OCEx.mesh(sphere, 0.05))
    assert Enum.count(fine.triangles) > Enum.count(coarse.triangles)
    assert_in_delta volume(sphere), 4 / 3 * :math.pi() * 1000, 1.0e-6
  end

  @tag :tmp_dir
  test "angular deflection controls mesh and STL refinement without changing the source", %{
    tmp_dir: dir
  } do
    body = ok(OCEx.cylinder(10, 5))
    before = ok(OCEx.to_brep(body))
    coarse = ok(OCEx.mesh(body, 1, 0.5))
    fine = ok(OCEx.mesh(body, 1, 0.05))
    assert length(fine.triangles) > 5 * length(coarse.triangles)
    path = Path.join(dir, "fine.stl")
    assert {:ok, :ok} = OCEx.write_stl(body, path, 1, 0.05)
    <<_::binary-size(80), count::little-unsigned-32, _::binary>> = File.read!(path)
    assert count == length(fine.triangles)
    assert ok(OCEx.to_brep(body)) == before

    for angle <- [0, -0.1, :bad] do
      assert {:error, _} = OCEx.mesh(body, 1, angle)
      assert {:error, _} = OCEx.write_stl(body, path, 1, angle)
    end
  end

  test "subshapes survive creator exit and parent garbage collection" do
    edge =
      Task.async(fn ->
        body = ok(OCEx.box(10, 20, 30))
        hd(ok(OCEx.edges(body)))
      end)
      |> Task.await()

    :erlang.garbage_collect()
    assert {:ok, %{type: :line, length: length}} = OCEx.edge_info(edge)
    assert length > 0
    assert {:ok, :edge} = OCEx.shape_type(edge)
  end

  test "shared source supports concurrent operations and resource churn" do
    body = ok(OCEx.box(10, 20, 30))

    results =
      1..40
      |> Task.async_stream(
        fn i ->
          shifted = ok(OCEx.translate(body, {i, 0, 0}))
          mesh = ok(OCEx.mesh(shifted))
          assert Enum.count(mesh.triangles) == 12
          :erlang.garbage_collect()
          volume(shifted)
        end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn {:ok, v} -> abs(v - 6000) < 1.0e-6 end)
    assert_in_delta volume(body), 6000, 1.0e-7
  end
end
