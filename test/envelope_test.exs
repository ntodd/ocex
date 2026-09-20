defmodule OCEx.EnvelopeTest do
  use ExUnit.Case, async: true

  test "internal envelopes contain precise curved bounds without changing source geometry" do
    {:ok, curve} = OCEx.bezier([{0, 0, 0}, {3, 12, 2}, {8, -4, 5}, {10, 0, 1}])
    {:ok, sphere} = OCEx.sphere(4)
    {:ok, sphere} = OCEx.translate(sphere, {7, -5, 3})
    {:ok, box} = OCEx.box(2, 3, 4)
    {:ok, compound} = OCEx.compound([curve, sphere, box])

    for shape <- [curve, sphere, box, compound] do
      {:ok, before} = OCEx.to_brep(shape)
      {:ok, {low, high}} = OCEx.bounds(shape)
      assert {:ok, {outer_low, outer_high}} = apply(OCEx.Internal, :envelope, [shape])

      for i <- 0..2 do
        assert elem(outer_low, i) <= elem(low, i) + 1.0e-7
        assert elem(outer_high, i) >= elem(high, i) - 1.0e-7
      end

      assert {:ok, ^before} = OCEx.to_brep(shape)
    end
  end

  test "empty and invalid envelopes return tagged failures" do
    {:ok, box} = OCEx.box(1, 1, 1)
    {:ok, empty} = OCEx.cut(box, box)
    assert {:error, :empty_shape} = apply(OCEx.Internal, :envelope, [empty])
    assert {:error, :invalid_shape} = apply(OCEx.Internal, :envelope, [:invalid])
  end
end
