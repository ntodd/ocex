defmodule OCEx.BuildCacheTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  test "compiler reuses its cache and recovers when the dependency source moves", %{tmp_dir: root} do
    first = fixture(root, "checkout")
    second = fixture(root, "hex-dependency")
    build = Path.join(root, "shared-build")
    sentinel = Path.join(root, "consumer-file")
    File.write!(sentinel, "keep")

    assert_compile(first, build)
    marker = Path.join(build, "native/incremental-marker")
    File.write!(marker, "reused")
    assert_compile(first, build)
    assert File.read!(marker) == "reused"

    assert_compile(second, build)
    assert File.read!(Path.join(build, "native/configured-source")) == Path.join(second, "c_src")
    assert File.read!(sentinel) == "keep"
  end

  test "compiler recovers when the consumer build directory moves", %{tmp_dir: root} do
    source = fixture(root, "dependency")
    first = Path.join(root, "original-build")
    second = Path.join(root, "moved-build")
    assert_compile(source, first)
    File.rename!(first, second)

    assert_compile(source, second)
    assert File.read!(Path.join(second, "native/configured-source")) == Path.join(source, "c_src")
  end

  defp fixture(root, name) do
    fixture = Path.join(root, name)
    File.mkdir_p!(Path.join(fixture, "c_src"))
    File.cp!(Path.expand("../mix.exs", __DIR__), Path.join(fixture, "mix.exs"))

    # Real CMake owns the cache. No OCCT recompilation is needed to exercise
    # its source/build directory checks through the actual OCEx compiler task.
    File.write!(Path.join(fixture, "c_src/CMakeLists.txt"), """
    cmake_minimum_required(VERSION 3.20)
    project(OCExCacheFixture NONE)
    file(WRITE "${CMAKE_BINARY_DIR}/configured-source" "${CMAKE_CURRENT_SOURCE_DIR}")
    """)

    fixture
  end

  defp assert_compile(source, build) do
    code = """
    Mix.start()
    Code.compile_file("mix.exs")
    {:ok, []} = Mix.Tasks.Compile.Ocex.run([])
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["--erl", "+S 2:2", "-e", code],
        cd: source,
        env: [
          {"MIX_BUILD_PATH", build},
          {"MIX_ENV", "test"},
          {"OpenCASCADE_DIR", nil},
          {"OCEX_SANITIZE", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
