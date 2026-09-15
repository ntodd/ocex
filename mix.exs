defmodule Mix.Tasks.Compile.Ocex do
  use Mix.Task.Compiler
  @recursive true

  def run(_) do
    source = Path.expand("c_src", __DIR__)
    build = Path.join(Mix.Project.build_path(), "native")
    output = Path.expand(Path.join(Mix.Project.app_path(), "priv"))
    include = Path.join(to_string(:code.root_dir()), "usr/include")

    cmake =
      System.find_executable("cmake") ||
        Enum.find(["/opt/homebrew/bin/cmake", "/usr/local/bin/cmake"], &File.regular?/1) ||
        Mix.raise(
          "OCEx cannot find CMake. Install CMake 3.20+ and a C++17 compiler (macOS: brew install cmake and xcode-select --install). Restart your Livebook runtime after installation. See https://hexdocs.pm/ocex/installation.html."
        )

    unless File.regular?(Path.join(include, "erl_nif.h")),
      do:
        Mix.raise(
          "OCEx cannot find erl_nif.h in #{include}. Install Erlang/OTP development headers."
        )

    if System.get_env("OpenCASCADE_DIR") &&
         not File.regular?(
           Path.join(System.fetch_env!("OpenCASCADE_DIR"), "OpenCASCADEConfig.cmake")
         ),
       do:
         Mix.raise(
           "OpenCASCADE_DIR must point to a directory containing OpenCASCADEConfig.cmake. " <>
             "Install OCCT 7.9.3 with scripts/install-occt.sh; see guides/installation.md."
         )

    prefix =
      System.get_env("OpenCASCADE_DIR") ||
        Enum.find(
          [
            Path.join(System.user_home!(), ".local/occt-7.9.3/lib/cmake/opencascade"),
            "/opt/homebrew/opt/opencascade/lib/cmake/opencascade",
            "/usr/local/opt/opencascade/lib/cmake/opencascade"
          ],
          &File.dir?/1
        )

    prepare_build(build, source)

    configure = [
      "-S",
      source,
      "-B",
      build,
      "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
      "-DERL_INCLUDE_DIR=#{include}",
      "-DNIF_OUTPUT_DIR=#{output}"
    ]

    configure =
      if prefix && File.dir?(prefix),
        do: configure ++ ["-DOpenCASCADE_DIR=#{prefix}"],
        else: configure

    configure =
      configure ++
        ["-DOCEX_SANITIZE=#{if System.get_env("OCEX_SANITIZE") == "1", do: "ON", else: "OFF"}"]

    for args <- [configure, ["--build", build, "--parallel", "4"]] do
      case System.cmd(cmake, args, stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {message, _} ->
          Mix.raise(
            "OCEx native build failed. This release requires OCCT 7.9.3, CMake 3.20+, " <>
              "a C++17 compiler, and OTP development headers. Set OpenCASCADE_DIR to the " <>
              "installed lib/cmake/opencascade directory. See guides/installation.md.\n\n" <>
              message
          )
      end
    end

    {:ok, []}
  end

  defp prepare_build(build, source) do
    cache_path = Path.join(build, "CMakeCache.txt")

    if File.regular?(cache_path) do
      cache = File.read!(cache_path)
      locations = [{"CMAKE_HOME_DIRECTORY", source}, {"CMAKE_CACHEFILE_DIR", build}]

      stale? =
        Enum.any?(locations, fn {key, path} ->
          case Regex.run(~r/^#{key}:INTERNAL=(.*)$/m, cache, capture: :all_but_first) do
            [cached] -> Path.expand(String.trim_trailing(cached, "\r")) != Path.expand(path)
            nil -> false
          end
        end)

      if stale? do
        Mix.shell().info("OCEx: rebuilding native cache after a source or build directory change")
        File.rm_rf!(build)
      end
    end
  end
end

defmodule OCEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :ocex,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:ocex] ++ Mix.compilers(),
      description: "Native Elixir bindings for Open CASCADE Technology",
      name: "OCEx",
      source_url: "https://github.com/ntodd/ocex",
      homepage_url: "https://hexdocs.pm/ocex",
      deps: [{:ex_doc, "~> 0.40", only: :dev, runtime: false}],
      docs: [
        main: "readme",
        source_ref: "v0.2.0",
        source_url_pattern: "https://github.com/ntodd/ocex/blob/v0.2.0/%{path}#L%{line}",
        extras: [
          "README.md",
          "guides/installation.md",
          "guides/native-geometry.md",
          "guides/errors-and-lifetimes.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        groups_for_modules: [Geometry: [OCEx, OCEx.Shape]]
      ],
      package: [
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/ntodd/ocex",
          "Open Cascade" => "https://dev.opencascade.org/"
        },
        files:
          ~w(lib c_src scripts/install-occt.sh scripts/check-allocator.cpp scripts/patches guides mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
