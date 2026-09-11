# Native installation

OCEx 0.1 requires **Open CASCADE Technology 7.9.3**, CMake 3.20+, a C++17 compiler,
and Elixir 1.18+ with Erlang/OTP development headers. The NIF compiles from source
when Mix compiles the dependency. There are no precompiled NIF downloads.

## Install the prerequisites

On macOS, install the Xcode command-line tools and CMake:

```sh
xcode-select --install
brew install cmake
```

On Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install build-essential cmake curl ca-certificates patch
```

Install Elixir and Erlang using your preferred version manager. If installing OTP
through distribution packages, also install the corresponding development package
(such as `erlang-dev`) so `erl_nif.h` is present. The CI workflow targets Elixir 1.18 / OTP 27
and Elixir 1.20 / OTP 29 on macOS and Linux. Windows is not currently supported.

## Build the pinned toolkit

The package includes a source installer. From an OCEx checkout, or after
`mix deps.get` in a consumer (use `deps/ocex/scripts/install-occt.sh` there):

```sh
sh scripts/install-occt.sh "$HOME/.local/occt-7.9.3"
export OpenCASCADE_DIR="$HOME/.local/occt-7.9.3/lib/cmake/opencascade"
```

The script downloads tag `V7_9_3` from the official OCCT repository and verifies
SHA-256 `5ecf094ec6b12d5413dfb851d8c3590c354058aee556e32e408bdfbf8c357d57`
before compiling. It applies the bundled allocator-alignment correction described
in [the patch notes](https://github.com/ntodd/ocex/blob/main/scripts/patches/README.md)
and checks allocation alignment against the installed library. It builds the required toolkits and their dependencies as shared
libraries with OCCT range/exception checks enabled (`BUILD_RELEASE_DISABLE_EXCEPTIONS=OFF`), with drawing tools and external graphics integrations disabled. No
root access is needed for a prefix you own. The default build uses four jobs;
set `OCEX_BUILD_JOBS=2` on a memory-constrained machine. Allow several minutes.

For a custom prefix, keep `OpenCASCADE_DIR` set when compiling. The default source install prefix is
`$HOME/.local/occt-7.9.3`. An unversioned `brew install opencascade` is not the
reproducible installation path: a future Homebrew release can supply an
incompatible toolkit version. An existing 7.9.3 development installation must retain OCCT exception checks and
include the allocator-alignment correction. Builds with `No_Exception` disable range guards in parsers and are unsupported.

For a standalone script or Livebook, you can fetch the installer without creating
a Mix project:

```sh
mix local.hex --force
mix hex.package fetch ocex 0.1.0 --unpack --output ocex-toolkit
sh ocex-toolkit/scripts/install-occt.sh
```

The last command installs into the default source prefix, which OCEx discovers
automatically. The versioned fetch becomes available after the first publication.

## Use OCEx

In a Mix project:

```elixir
{:ocex, "~> 0.1.0"}
```

Or in a standalone script, once the toolkit is installed:

```elixir
Mix.install([{:ocex, "~> 0.1.0"}])
{:ok, box} = OCEx.box(10, 20, 30)
{:ok, volume} = OCEx.volume(box)
true = abs(volume - 6000.0) < 1.0e-6
IO.inspect(OCEx.version())
```

Desktop-launched Livebook may not inherit your shell's `PATH`. OCEx also checks
`/opt/homebrew/bin/cmake` and `/usr/local/bin/cmake`. If using another installation,
set `PATH` in the notebook setup before `Mix.install`, or launch Livebook from a
terminal that can run `cmake --version`. Restart the notebook runtime after a
failed native compilation.

The compiler first respects explicit `OpenCASCADE_DIR`, then the default source
installation under `$HOME/.local/occt-7.9.3`, then Homebrew locations, then normal
CMake discovery. A compiled allocator probe rejects uncorrected toolkit builds
before a NIF can load into the VM. Point the
variable to the directory containing `OpenCASCADEConfig.cmake`, not the install
prefix or include directory. CMake enforces the exact toolkit version.

## Deployment and troubleshooting

The generated NIF lives in the application's build `priv` directory and dynamically
links OCCT. Deploy the OCCT shared libraries as well as the Elixir application;
keep the library installation accessible at runtime. A Mix release does not
bundle those external libraries. Build and run on compatible operating systems,
architectures, OTP installations, and C++ runtimes. Do not copy a macOS NIF to Linux.

- **CMake not found:** install CMake and make it available on `PATH`.
- **`erl_nif.h` missing:** install development headers for the actual OTP used by Mix.
- **OCCT configuration not found or wrong version:** run the pinned installer and
  set `OpenCASCADE_DIR` to its configuration directory.
- **A shared library cannot be loaded:** restore the toolkit's runtime libraries
  at their installed location and check architecture compatibility.
- **Changed toolkit/compiler/OTP:** clean the consumer's OCEx build with
  `mix deps.clean ocex --build`, then compile again. Standalone `Mix.install`
  users can use `force: true` for that rebuild.

OCEx source is MIT licensed. OCCT is a separate dependency under its own license
and exception; the Hex archive includes the small documented patch, not a full toolkit source tree or binaries.
