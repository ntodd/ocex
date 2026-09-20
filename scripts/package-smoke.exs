# Copied into an isolated consumer and installed from the built Hex archive.
ocex_version = System.fetch_env!("OCEX_VERSION")
Mix.install([{:ocex, ocex_version}])
^ocex_version = Application.spec(:ocex, :vsn) |> to_string()

false = Code.ensure_loaded?(Smith)
{:ok, "7.9.3"} = OCEx.version()
{:ok, box} = OCEx.box(2, 3, 4)
{:ok, true} = OCEx.valid?(box)
{:ok, volume} = OCEx.volume(box)
true = abs(volume - 24) < 1.0e-6
{:ok, brep} = OCEx.to_brep(box)
{:ok, restored} = OCEx.from_brep(brep)
{:ok, :ok} = OCEx.write_step(restored, "box.step")
{:ok, step} = OCEx.read_step("box.step")
{:ok, step_volume} = OCEx.volume(step)
true = abs(step_volume - volume) < 1.0e-6
{:ok, :ok} = OCEx.write_stl(box, "box.stl")
<<_::binary-size(80), 12::little-32, triangles::binary-size(600)>> = File.read!("box.stl")
true = byte_size(triangles) == 600
IO.puts("Verified isolated OCEx archive: native geometry, BREP/STEP round trips, binary STL")

{:ok, edge} = OCEx.circle(1)
{:ok, section} = OCEx.wire([edge])
{:ok, line} = OCEx.edge({0, 0, 0}, {0, 0, 10})
{:ok, path} = OCEx.wire([line])
{:ok, swept} = OCEx.sweep(section, path)
{:ok, last} = OCEx.translate(section, {0, 0, 10})
{:ok, lofted} = OCEx.loft([section, last], ruled: false)
for shape <- [swept, lofted] do
  {:ok, volume} = OCEx.volume(shape)
  true = abs(volume - 10 * :math.pi()) < 1.0e-6
end
{:ok, faces} = OCEx.faces(box)
openings = Enum.filter(faces, fn face ->
  match?({:ok, %{normal: {_, _, z}}} when z > 0.99, OCEx.face_info(face))
end)
{:ok, hollow} = OCEx.shell(box, openings, -0.25)
{:ok, volume} = OCEx.volume(hollow)
true = abs(volume - (24 - 1.5 * 2.5 * 3.75)) < 1.0e-6
IO.puts("Verified archive-installed sweep, smooth loft, and shell geometry")

{:ok, torus} = OCEx.torus(10, 2)
{:ok, reflected} = OCEx.mirror(torus, {5, 0, 0}, {1, 1, 0})
{:ok, true} = OCEx.valid?(reflected)
{:ok, volume} = OCEx.volume(reflected)
true = abs(volume - 80 * :math.pi() * :math.pi()) < 1.0e-6
IO.puts("Verified archive-installed torus and mirror")

{:ok, clipped} = OCEx.split(box, {0, 0, 2}, {0, 0, 1}, keep: :negative)
{:ok, measured_volume} = OCEx.volume(clipped)
true = abs(measured_volume - 12) < 1.0e-6
{:ok, profile} = OCEx.section(box, {0, 0, 2}, {0, 0, 1})
{:ok, surface} = OCEx.sew([profile])
{:ok, shifted} = OCEx.offset(surface, 1)
{:ok, thick} = OCEx.thicken(shifted, 2)
{:ok, measured_volume} = OCEx.volume(thick)
true = abs(measured_volume - 12) < 1.0e-6
IO.puts("Verified archive-installed split, section, sewing, offset, and thickening")

{:ok, tapered} = OCEx.extrude(profile, {0, 0, 0.5}, taper: 3, both: true)
{:ok, [_]} = OCEx.solids(tapered)
{:ok, until} = OCEx.extrude_until(profile, {0, 0, 1}, {0, 0, 5}, {0, 0, 1})
{:ok, measured_volume} = OCEx.volume(until)
true = abs(measured_volume - 18) < 1.0e-6
IO.puts("Verified archive-installed symmetric, tapered, and up-to-plane extrusion")
{:ok, projection_source} = OCEx.circle(0.25)
{:ok, projection_source} = OCEx.translate(projection_source, {1,1.5,2})
{:ok, projected} = OCEx.project(projection_source, box, direction: {0,0,1})
{:ok, projected_wires} = OCEx.wires(projected)
2 = length(projected_wires)
{:ok, projected_length} = OCEx.length(projected)
true = abs(projected_length - :math.pi()) < 1.0e-6
IO.puts("Verified archive-installed multi-hit curve projection")


{:ok, drawing_body} = OCEx.sphere(3)
{:ok, drawing} = OCEx.drawing(drawing_body, {0, 0, 0}, {0, 0, 1}, {1, 0, 0})
{:ok, silhouette_length} = OCEx.length(drawing.visible)
true = abs(silhouette_length - 6 * :math.pi()) < 1.0e-6
{:ok, [_points]} = OCEx.polylines(drawing.visible)
{:ok, []} = OCEx.edges(drawing.hidden)
IO.puts("Verified archive-installed orthographic silhouettes and curve sampling")

{:ok, bezier} = OCEx.bezier([{0, 0, 0}, {1, 2, 0}, {2, 0, 0}])
{:ok, %{point: {x, y, z}}} = OCEx.edge_sample(bezier, 0.5)
true = abs(x - 1) < 1.0e-9 and abs(y - 1) < 1.0e-9 and abs(z) < 1.0e-9
IO.puts("Verified archive-installed Bezier control-point geometry")

{:ok, shifted} = OCEx.translate(box, {10, 0, 0})
{:ok, %{distance: distance}} = OCEx.closest_points(box, shifted)
true = abs(distance - 8) < 1.0e-7
{:ok, circle} = OCEx.circle(2)
{:ok, %{center: {x, y, z}, axis: _}} = OCEx.edge_info(circle)
true = abs(x) + abs(y) + abs(z) < 1.0e-7
IO.puts("Verified archive-installed inspection witnesses and circle datums")

font = File.read!(Path.join(:code.priv_dir(:ocex), "fonts/Graduate-Regular.ttf"))
{:ok, %{family: "Graduate"}} = OCEx.font_info(font)
{:ok, text} = OCEx.text("BO TEAM", font, 8)
{:ok, letters} = OCEx.extrude(text.shape, {0, 0, 1})
{:ok, true} = OCEx.valid?(letters)
{:ok, area} = OCEx.area(text.shape)
{:ok, volume} = OCEx.volume(letters)
true = abs(area - volume) < 1.0e-5
{:error, :missing_glyph} = OCEx.text("\u{10FFFF}", font, 8)
IO.puts("Verified archive-installed FreeType/HarfBuzz text geometry and packaged font")
