# Releasing OCEx

For both packages, follow the [coordinated release checklist](https://github.com/ntodd/smith/blob/main/docs/releasing.md).
OCEx 0.4.0 is already published; do not move its tag. The commands below are a
template for future releases: substitute the new version.

This repository publishes `ocex` version `0.4.0` from tag `v0.4.0`.
Publish OCEx before Smith. OCEx has no runtime Hex dependencies.

## Prepare the source

1. Review the changelog and package file list. Keep private projects, build output,
   and local notebook dependency experiments out of the package.
2. Run `make check docs package package-smoke`. The smoke test installs the built
   archive through a signed local registry into an isolated consumer.
3. Inspect `doc/index.html`. Push the release commit and wait for the macOS/Linux
   CI matrix to pass.
4. Create the annotated tag at that verified commit, unless it already exists:

```sh
git tag -a v0.4.0 -m "OCEx 0.4.0"
git push origin v0.4.0
```

The version in `mix.exs`, ExDoc source links, and changelog must agree. The archive smoke script reads the version from
`mix.exs` automatically. Do not move a published release tag.

## Publish to Hex

Run from the tagged checkout. Authenticate with `mix hex.user auth` if needed.
The dry run builds the package and documentation without publishing:

```sh
mix deps.get
mix hex.publish --dry-run
mix hex.publish
```

Review the package summary before confirming. The final command publishes both
the package and ExDoc. Keep the native toolkit available while building the docs.

## Verify the public package

Run this from the repository after publication. The consumer has fresh caches,
uses the public Hex registry, and writes its exports outside the checkout:

```sh
release_check=$(mktemp -d)
cp scripts/package-smoke.exs "$release_check/model.exs"
(
  cd "$release_check"
  env -u OCEX_PATH OCEX_VERSION=0.4.0 HEX_HOME="$release_check/hex" \
    MIX_INSTALL_DIR="$release_check/install" elixir model.exs
)
```

Check [OCEx 0.4.0 HexDocs](https://hexdocs.pm/ocex/0.4.0/), including guide and source
links. Once the public installation passes, Smith can resolve OCEx 0.4.0 from Hex.

## Native support

This release uses OCCT 7.9.3 with the documented allocator correction and kernel
exception checks enabled. OCCT shared libraries must remain available at runtime.
See [installation](../guides/installation.md) for CMake, compiler, and OTP header
requirements. Precompiled NIFs, Windows, hot upgrades, and hard cancellation are
outside this release.

## Update published documentation

Documentation can be republished for the current version without changing the
package version or replacing its archive:

```sh
mix hex.publish docs --dry-run
mix hex.publish docs
```

Review the generated pages before publishing. This updates HexDocs only; changes
to installed Elixir code or Livebook assets require a new package release.
