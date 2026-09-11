# Releasing OCEx

This repository publishes only `ocex`. Its source repository is
[ntodd/ocex](https://github.com/ntodd/ocex), and the first release tag is `v0.1.0`.
OCEx is released independently of Smith. It has no runtime Hex dependencies.

## Prepare

1. Review source, examples, package metadata, and the changelog. Exclude private
   projects and local notebook dependency experiments.
2. Update the version, ExDoc source tag, smoke-test version, and dependency ranges
   together for subsequent releases.
3. Run `make check docs package package-smoke`. See
   [development](development.md) for unpublished-dependency checks.
4. Inspect `doc/index.html` and the archive's file list. Push reviewed source
   and wait for this repository's CI matrix to pass.
5. Create and push the annotated tag at the verified commit:

```sh
git tag -a v0.1.0 -m "ocex 0.1.0"
git push origin v0.1.0
```

## Owner authentication and publication

Run from this repository after its source and tag are public:

```sh
mix deps.get
mix hex.user auth
mix hex.publish --dry-run
mix hex.publish
```

Review the package summary before confirming. Publication includes ExDoc.
Hex requires authentication even for a publication dry run; local archive
checks need no publication credentials. Do not move a tag after publication.

After publishing, copy `scripts/package-smoke.exs` into a temporary directory
and run it there with fresh `HEX_HOME` and `MIX_INSTALL_DIR` against public
Hex. Keep the native toolkit installed. Check the published HexDocs guides
and source links. Confirm the package can be built without a Smith checkout.

## Supported native installation

This release uses OCCT 7.9.3 with the documented allocator correction and
kernel exception checks enabled. OCCT shared libraries must remain available
at runtime. Precompiled NIFs, Windows, hot upgrades, and hard cancellation
are outside this release.
