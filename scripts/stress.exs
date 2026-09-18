# A separate BEAM invocation makes native crashes observable as command failure.
# Run via `make stress`.
defmodule Stress do
  def ok({:ok, value}), do: value
  def count, do: ok(OCEx.Native.call(:resource_count, []))
end
baseline = Stress.count()
for batch <- 1..20 do
  task = Task.async(fn ->
    for i <- 1..50 do
      body = Stress.ok(OCEx.box(10, 20, 30))
      shifted = Stress.ok(OCEx.translate(body, {i, 0, 0}))
      {:ok, true} = OCEx.valid?(shifted)
      {:ok, volume} = OCEx.volume(shifted)
      if abs(volume - 6000) > 1.0e-6, do: raise("invalid stress geometry")
      {:ok, edges} = OCEx.edges(shifted)
      for edge <- edges, do: Stress.ok(OCEx.edge_info(edge))
      if rem(i, 10) == 0 do
        font = File.read!(Path.join(:code.priv_dir(:ocex), "fonts/Graduate-Regular.ttf"))
        text = Stress.ok(OCEx.text("BO TEAM", font, 5 + rem(i, 3)))
        glyph_body = Stress.ok(OCEx.extrude(text.shape, {0, 0, 1}))
        {:ok, true} = OCEx.valid?(glyph_body)
        Stress.ok(OCEx.mesh(glyph_body))
        {:error, :invalid_font} = OCEx.font_info("malformed font")
        {:error, :missing_glyph} = OCEx.text("\u{10FFFF}", font, 10)
        Stress.ok(OCEx.mesh(shifted))
        {:ok, faces} = OCEx.faces(body)
        openings = Enum.filter(faces, fn face ->
          match?({:ok, %{normal: {_, _, z}}} when z > 0.99, OCEx.face_info(face))
        end)
        Stress.ok(OCEx.shell(body, openings, -1))
        cut = Stress.ok(OCEx.split(body, {0, 0, 15}, {0, 0, 1}, keep: :negative))
        {:ok, measured_volume} = OCEx.volume(cut)
        true = abs(measured_volume - 3000) < 1.0e-6
        plane = Stress.ok(OCEx.section(body, {0, 0, 15}, {0, 0, 1}))
        Stress.ok(OCEx.extrude(plane, {0, 0, 2}))
        Stress.ok(OCEx.project(plane, body, direction: {0, 0, 1}))
        drawing = Stress.ok(OCEx.drawing(body, {0, 0, 0}, {1, 1, 1}, {1, 0, 0}))
        for curves <- [drawing.visible, drawing.hidden] do
          Stress.ok(OCEx.polylines(curves))
          Stress.ok(OCEx.to_brep(curves))
        end
        Stress.ok(OCEx.extrude(plane, {0, 0, 2}, both: true, taper: 3))
        Stress.ok(OCEx.extrude_until(plane, {0, 0, 1}, {0, 0, 20}, {0, 0, 1}))
        sides = Enum.filter(faces, fn face ->
          {:ok, info} = OCEx.face_info(face)
          abs(elem(info.normal, 2)) < 0.01
        end)
        Stress.ok(OCEx.draft(body, sides, {0, 0, 1}, 2, {0, 0, 0}, {0, 0, 1}))
        surface = Stress.ok(OCEx.sew(openings))
        shifted_surface = Stress.ok(OCEx.offset(surface, 1))
        Stress.ok(OCEx.thicken(shifted_surface, 1))
        section = Stress.ok(OCEx.wire([Stress.ok(OCEx.circle(1))]))
        filled = Stress.ok(OCEx.planar_fill([section], :evenodd))
        stroke = Stress.ok(OCEx.stroke(section, 0.3, join: :round, tolerance: 0.01))
        Stress.ok(OCEx.affine_transform(stroke, {2, 0.1, 0.2, 1, 4, 5}))
        Stress.ok(OCEx.wire_points(section))
        Stress.ok(OCEx.extrude(filled, {0, 0, 1}))
        last = Stress.ok(OCEx.translate(section, {0, 0, 10}))
        Stress.ok(OCEx.loft([section, last], ruled: false))
        path = Stress.ok(OCEx.wire([Stress.ok(OCEx.edge({0, 0, 0}, {0, 0, 10}))]))
        Stress.ok(OCEx.sweep(section, path))
        torus = Stress.ok(OCEx.torus(10, 2))
        mirrored = Stress.ok(OCEx.mirror(torus, {5, 0, 0}, {1, 1, 0}))
        {:ok, true} = OCEx.valid?(mirrored)
      end
      for malformed <- [nil, [], %{}, make_ref(), [1 | 2], <<0, 255>>] do
        {:error, _} = OCEx.Native.call(:box, malformed)
        {:error, _} = OCEx.Native.call(:volume, [malformed])
      end
    end
    :done
  end)
  :done = Task.await(task, 30_000)
  :erlang.garbage_collect()
  # Resource destruction can finish just after the process exit signal.
  Enum.reduce_while(1..100, nil, fn _, _ ->
    if Stress.count() <= baseline, do: {:halt, nil}, else: (Process.sleep(10); {:cont, nil})
  end)
  if Stress.count() > baseline, do: raise("native resources leaked in batch #{batch}")
end
IO.puts("Stress passed: 1,000 shape workloads, 100 meshes, 100 shells, 100 lofts, 100 sweeps, 100 tori and mirrors, 100 drawing/sampling and split/section/draft/offset/thickening workloads, 12,000 malformed calls; native resources returned to baseline.")
