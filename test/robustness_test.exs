defmodule OCEx.RobustnessTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  test "measurements count shared edges once and exclude open faces from volume" do
    box = ok(OCEx.box(10, 20, 30))
    assert_in_delta ok(OCEx.length(box)), 4 * (10 + 20 + 30), 1.0e-7
    face = rectangle() |> OCEx.face() |> ok() |> OCEx.translate({0, 0, 10}) |> ok()
    assert_in_delta volume(face), 0, 1.0e-8
    assert OCEx.center_of_mass(face) == {:error, :empty_shape}
  end

  test "circular profile extrudes into an analytic cylinder" do
    face = OCEx.circle(3) |> ok() |> then(&ok(OCEx.wire([&1]))) |> OCEx.face() |> ok()
    cylinder = ok(OCEx.extrude(face, {0, 0, 7}))
    assert_valid(cylinder)
    assert_in_delta volume(cylinder), :math.pi() * 9 * 7, 1.0e-6
  end

  test "negative extrusion and partial revolution retain outward solid orientation" do
    face = ok(OCEx.face(rectangle(2, 3)))
    down = ok(OCEx.extrude(face, {0, 0, -5}))
    assert_valid(down)
    assert_in_delta volume(down), 30, 1.0e-7
    offset = ok(OCEx.translate(face, {4, 0, 0}))
    half = ok(OCEx.revolve(offset, {0, 0, 0}, {0, 1, 0}, 180))
    assert_valid(half)
    assert_in_delta volume(half), :math.pi() * 30, 1.0e-6

    for angle <- [0, -1, 361] do
      assert {:error, :invalid_argument} = OCEx.revolve(offset, {0, 0, 0}, {0, 1, 0}, angle)
    end
  end

  test "in-plane extrusion is rejected as invalid geometry" do
    face = ok(OCEx.face(rectangle()))
    assert {:error, _} = OCEx.extrude(face, {1, 0, 0})
  end

  test "subshapes from a deserialized revision cannot select edges on the original" do
    body = ok(OCEx.box(10, 10, 10))
    restored = body |> OCEx.to_brep() |> ok() |> OCEx.from_brep() |> ok()
    assert {:error, :foreign_subshape} = OCEx.fillet(body, vertical_edges(restored), 1)
  end

  test "Boolean results and meshing leave source serialization unchanged" do
    body = ok(OCEx.box(10, 20, 30))
    before = ok(OCEx.to_brep(body))
    tool = ok(OCEx.sphere(3))
    for operation <- [:cut, :fuse, :common], do: ok(apply(OCEx, operation, [body, tool]))
    ok(OCEx.mesh(body))
    ok(OCEx.fillet(body, vertical_edges(body), 1))
    assert ok(OCEx.to_brep(body)) == before
  end

  test "transformed mesh winding and bounds agree with exact geometry" do
    body =
      OCEx.box(10, 20, 30)
      |> ok()
      |> OCEx.rotate({0, 0, 0}, {1, 1, 1}, 70)
      |> ok()
      |> OCEx.translate({10, -5, 7})
      |> ok()

    mesh = ok(OCEx.mesh(body))
    {low, high} = ok(OCEx.bounds(body))

    for axis <- 0..2 do
      coords = Enum.map(mesh.vertices, &elem(&1, axis))
      assert_in_delta Enum.min(coords), elem(low, axis), 1.0e-6
      assert_in_delta Enum.max(coords), elem(high, axis), 1.0e-6
    end
  end

  test "native boundary rejects malformed argument types for every operation" do
    arities = [
      box: 3,
      cylinder: 2,
      sphere: 1,
      cone: 3,
      edge: 2,
      circle: 1,
      wire: 1,
      face: 1,
      extrude: 2,
      extrude: 4,
      extrude_until: 4,
      project: 4,
      drawing: 5,
      polylines: 3,
      revolve: 4,
      loft: 2,
      sweep: 4,
      shell: 4,
      torus: 2,
      mirror: 3,
      split: 4,
      section: 3,
      draft: 6,
      sew: 1,
      offset: 3,
      thicken: 3,
      compound: 1,
      cut: 2,
      cut_many: 2,
      fuse: 2,
      fuse_many: 2,
      common: 2,
      translate: 2,
      rotate: 4,
      scale: 2,
      fillet: 3,
      chamfer: 3,
      volume: 1,
      area: 1,
      length: 1,
      center_of_mass: 1,
      bounds: 1,
      edge_info: 1,
      face_info: 1,
      point: 1,
      mesh: 3,
      to_brep: 1,
      from_brep: 1,
      read_step: 1,
      write_step: 2,
      write_stl: 4,
      same: 2,
      valid: 1,
      shape_type: 1,
      edges: 1,
      faces: 1,
      vertices: 1,
      wires: 1,
      shells: 1,
      solids: 1
    ]

    for {operation, arity} <- arities do
      assert {:error, _} = OCEx.Native.call(operation, List.duplicate(:invalid, arity))
      assert {:error, :invalid_argument} = OCEx.Native.call(operation, [])

      assert {:error, :invalid_argument} =
               OCEx.Native.call(operation, List.duplicate(nil, arity + 1))
    end
  end

  test "concurrent fillets share selections without altering source or each other" do
    body = ok(OCEx.box(60, 40, 5))
    edges = vertical_edges(body)

    values =
      [0.5, 1.0, 1.5, 2.0]
      |> Task.async_stream(fn r ->
        rounded = ok(OCEx.fillet(body, edges, r))
        assert_in_delta volume(rounded), (2400 - (4 - :math.pi()) * r * r) * 5, 1.0e-5
      end)
      |> Enum.to_list()

    assert Enum.all?(values, &match?({:ok, _}, &1))
    assert_in_delta volume(body), 12000, 1.0e-7
  end

  test "all dependent resources survive producer exit" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        body = ok(OCEx.box(10, 20, 30))
        send(parent, {:shapes, body, ok(OCEx.faces(body)), ok(OCEx.edges(body))})
      end)

    assert_receive {:shapes, body, faces, edges}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    :erlang.garbage_collect()
    assert_valid(body)
    for face <- faces, do: assert(match?({:ok, %{type: :plane}}, OCEx.face_info(face)))
    for edge <- edges, do: assert(match?({:ok, %{type: :line}}, OCEx.edge_info(edge)))
  end

  test "truncated and corrupted BREP is rejected" do
    binary = OCEx.box(10, 20, 30) |> ok() |> OCEx.to_brep() |> ok()

    for length <-
          Enum.uniq(
            [1, 10, div(byte_size(binary), 2)] ++ Enum.take_every(1..(byte_size(binary) - 8), 37)
          ) do
      assert {:error, _} = OCEx.from_brep(binary_part(binary, 0, length))
    end
  end

  test "BREP accepts trailing-whitespace removal and rejects invalid topology references" do
    body = OCEx.box(10, 20, 30) |> ok()
    binary = OCEx.to_brep(body) |> ok()
    restored = binary |> String.trim_trailing() |> OCEx.from_brep() |> ok()
    assert_in_delta volume(restored), 6000, 1.0e-7
    corrupted = Regex.replace(~r/\+1 0\s*$/, binary, "+999999 0 ")
    assert {:error, _} = OCEx.from_brep(corrupted)
  end

  @tag :tmp_dir
  test "invalid STEP input returns an error", %{tmp_dir: dir} do
    path = Path.join(dir, "invalid.step")
    File.write!(path, "this is not STEP")
    assert {:error, _} = OCEx.read_step(path)
  end
end
