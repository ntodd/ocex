# Copied into an isolated consumer and installed from the built Hex archive.
Mix.install([{:ocex, "~> 0.1.0"}])

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
