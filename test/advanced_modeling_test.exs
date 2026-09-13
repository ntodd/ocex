defmodule OCEx.AdvancedModelingTest do
  use ExUnit.Case, async: true
  import OCEx.TestHelpers

  defp circle(radius, z) do
    edge = OCEx.circle(radius) |> ok() |> OCEx.translate({0, 0, z}) |> ok()
    ok(OCEx.wire([edge]))
  end

  defp top(body) do
    OCEx.faces(body)
    |> ok()
    |> Enum.filter(fn face ->
      match?({:ok, %{normal: {_, _, z}}} when z > 0.99, OCEx.face_info(face))
    end)
  end

  test "smooth loft interpolates a quadratic radius and differs from a ruled loft" do
    wires = [circle(2, 0), circle(4, 3), circle(2, 6)]
    snapshots = Enum.map(wires, &ok(OCEx.to_brep(&1)))
    smooth = ok(OCEx.loft(wires, ruled: false))
    ruled = ok(OCEx.loft(wires))
    assert_valid(smooth)
    # Integral of pi * (4 - 2/9 * (z - 3)^2)^2 over z=0..6.
    assert_in_delta volume(smooth), 344 / 5 * :math.pi(), 1.0e-4
    assert_in_delta volume(ruled), 56 * :math.pi(), 1.0e-6
    assert Enum.map(wires, &ok(OCEx.to_brep(&1))) == snapshots
    assert {:ok, [_]} = OCEx.solids(smooth)
  end

  test "loft validates options without changing the default" do
    wires = [circle(2, 0), circle(2, 5)]
    assert_in_delta volume(ok(OCEx.loft(wires, ruled: false))), 20 * :math.pi(), 1.0e-6

    for opts <- [[ruled: nil], [unknown: 1], [ruled: true, ruled: false], nil] do
      assert {:error, :invalid_options} = OCEx.loft(wires, opts)
    end
  end

  test "straight sweep is a cylinder and preserves both input wires" do
    profile = circle(2, 0)
    path = ok(OCEx.wire([ok(OCEx.edge({0, 0, 0}, {0, 0, 10}))]))
    before = Enum.map([profile, path], &ok(OCEx.to_brep(&1)))

    for frame <- [:corrected, :frenet] do
      body = ok(OCEx.sweep(profile, path, frame: frame))
      assert_valid(body)
      assert_in_delta volume(body), 40 * :math.pi(), 1.0e-6
      assert {:ok, [_]} = OCEx.solids(body)
    end

    assert Enum.map([profile, path], &ok(OCEx.to_brep(&1))) == before
  end

  test "curved sweep has quarter-torus volume" do
    path = OCEx.arc({0, 0, 0}, {0, 0, 1}, {1, 0, 0}, 10, 0, 90) |> ok()
    path = ok(OCEx.wire([path]))
    profile = circle(1, 0) |> OCEx.rotate({0, 0, 0}, {1, 0, 0}, 90) |> ok()
    profile = ok(OCEx.translate(profile, {10, 0, 0}))
    body = ok(OCEx.sweep(profile, path))
    assert_valid(body)
    assert_in_delta volume(body), 5 * :math.pi() * :math.pi(), 1.0e-5
  end

  test "sweep rejects wrong topology, open profiles, closed paths and invalid options" do
    edge = ok(OCEx.edge({0, 0, 0}, {0, 0, 10}))
    path = ok(OCEx.wire([edge]))
    profile = circle(1, 0)
    assert {:error, :wrong_shape_type} = OCEx.sweep(profile, edge)
    assert {:error, :open_wire} = OCEx.sweep(path, path)
    assert {:error, :closed_path} = OCEx.sweep(profile, profile)

    for opts <- [[frame: :bad], [transition: :bad], [frame: :frenet, frame: :corrected], nil] do
      assert {:error, :invalid_options} = OCEx.sweep(profile, path, opts)
    end
  end

  test "shell removes a top face, retains a floor, and preserves the source revision" do
    body = ok(OCEx.box(20, 16, 10))
    before = ok(OCEx.to_brep(body))
    shell = ok(OCEx.shell(body, top(body), -2))
    assert_valid(shell)
    assert_in_delta volume(shell), 3200 - 16 * 12 * 8, 1.0e-6
    assert_in_delta ok(OCEx.distance_to_point(shell, {10, 8, 8})), 6, 1.0e-6
    assert_in_delta ok(OCEx.distance_to_point(shell, {10, 8, 1})), 0, 1.0e-7
    assert ok(OCEx.to_brep(body)) == before
    assert {:ok, [_]} = OCEx.solids(shell)
  end

  test "outward intersection shell and multiple openings have analytic volumes" do
    body = ok(OCEx.box(20, 16, 10))
    outward = ok(OCEx.shell(body, top(body), 2, join: :intersection))
    assert_in_delta volume(outward), 24 * 20 * 12 - 3200, 1.0e-5

    openings =
      OCEx.faces(body)
      |> ok()
      |> Enum.filter(fn face ->
        match?({:ok, %{normal: {_, _, z}}} when abs(z) > 0.99, OCEx.face_info(face))
      end)

    tube = ok(OCEx.shell(body, openings, -2))
    assert_in_delta volume(tube), (320 - 16 * 12) * 10, 1.0e-6
  end

  test "shell enforces selection ownership and rejects degenerate thickness" do
    body = ok(OCEx.box(20, 16, 10))
    [face] = top(body)
    copied = ok(OCEx.translate(body, {0, 0, 0}))
    assert {:error, :foreign_subshape} = OCEx.shell(copied, [face], -1)
    assert {:error, :duplicate_subshape} = OCEx.shell(body, [face, face], -1)
    assert {:error, :empty_selection} = OCEx.shell(body, [], -1)
    assert {:error, :wrong_shape_type} = OCEx.shell(face, [face], -1)

    for thickness <- [0, 1.0e-8, nil] do
      assert {:error, :invalid_argument} = OCEx.shell(body, [face], thickness)
    end

    assert {:error, _} = OCEx.shell(body, [face], -20)
    assert {:error, :invalid_options} = OCEx.shell(body, [face], -1, join: :bad)
  end

  test "sweep requires explicit profile alignment and accepts reversed path direction" do
    path = ok(OCEx.wire([ok(OCEx.edge({0, 0, 0}, {0, 0, -10}))]))
    assert_in_delta volume(ok(OCEx.sweep(circle(1, 0), path))), 10 * :math.pi(), 1.0e-6
    assert {:error, :misaligned_profile} = OCEx.sweep(circle(1, 2), path)
    tilted = circle(1, 0) |> OCEx.rotate({0, 0, 0}, {1, 0, 0}, 45) |> ok()
    assert {:error, :misaligned_profile} = OCEx.sweep(tilted, path)
  end

  test "right and round transitions build connected solids at a sharp corner" do
    edges = [ok(OCEx.edge({0, 0, 0}, {0, 0, 10})), ok(OCEx.edge({0, 0, 10}, {10, 0, 10}))]
    path = ok(OCEx.wire(edges))

    for transition <- [:right, :round] do
      swept = ok(OCEx.sweep(circle(1, 0), path, transition: transition))
      assert_valid(swept)
      assert {:ok, [_]} = OCEx.solids(swept)
      assert volume(swept) > 0
      # Both cap centers remain in the solid.
      for point <- [{0, 0, 0}, {10, 0, 10}] do
        assert_in_delta ok(OCEx.distance_to_point(swept, point)), 0, 1.0e-6
      end
    end

    right = ok(OCEx.sweep(circle(1, 0), path, transition: :right))
    assert_in_delta volume(right), 20 * :math.pi(), 1.0e-5
  end

  test "smooth spline spine retains a valid solid with both frame choices" do
    edge = ok(OCEx.spline([{0, 0, 0}, {2, 0, 8}, {0, 2, 16}], {{0, 0, 1}, {0, 0, 1}}))
    path = ok(OCEx.wire([edge]))
    length = ok(OCEx.length(path))

    for frame <- [:corrected, :frenet] do
      body = ok(OCEx.sweep(circle(0.5, 0), path, frame: frame))
      assert_valid(body)
      assert_in_delta volume(body), :math.pi() * 0.25 * length, 1.0e-3
    end
  end

  test "inward cylindrical shell retains analytic wall and base thickness" do
    body = ok(OCEx.cylinder(10, 12))

    for thickness <- [0.5, 1, 2] do
      shell = ok(OCEx.shell(body, top(body), -thickness))
      expected = :math.pi() * (100 * 12 - :math.pow(10 - thickness, 2) * (12 - thickness))
      assert_in_delta volume(shell), expected, 1.0e-5
    end

    assert_in_delta volume(body), 1200 * :math.pi(), 1.0e-6
  end

  test "new solid resources and their topology survive the producing process" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        base = ok(OCEx.box(20, 16, 10))
        hollow = ok(OCEx.shell(base, top(base), -2))
        smooth = ok(OCEx.loft([circle(2, 0), circle(4, 3), circle(2, 6)], ruled: false))
        path = ok(OCEx.wire([ok(OCEx.edge({0, 0, 0}, {0, 0, 10}))]))
        swept = ok(OCEx.sweep(circle(1, 0), path))
        send(parent, {:models, Enum.map([hollow, smooth, swept], &{&1, ok(OCEx.faces(&1))})})
      end)

    assert_receive {:models, models}, 5000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    :erlang.garbage_collect()

    for {body, faces} <- models do
      assert_valid(body)
      assert volume(body) > 0
      for face <- faces, do: assert(match?({:ok, _}, OCEx.face_info(face)))
    end
  end
end
