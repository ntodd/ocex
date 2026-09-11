# Developing OCEx

OCEx is an independent repository at [ntodd/ocex](https://github.com/ntodd/ocex).
It has no dependency on Smith or a sibling checkout.

Install the [native toolkit](../guides/installation.md), then run from this repository:

```sh
mix deps.get
make check docs
make package package-smoke
```

`make check` runs formatting, warnings-as-errors compilation, 79 behavioral tests,
and 9 doctests. The API and guide checks run real geometry and file exchange.
The archive check installs OCEx through an isolated signed local Hex registry,
with no Smith dependency or checkout access.

Native ownership or execution changes also require `make sanitize stress`.
The sanitizer instruments the wrapper; the separately built OCCT is uninstrumented.
Tests cover analytic dimensions, topology, stale selections, malformed arguments,
BREP/STEP/STL exchange, native lifetimes, and scheduler behavior.

For a Linux build environment, run `docker build -f scripts/release.Dockerfile -t ocex-build .`.
The CI matrix targets macOS/Linux with Elixir 1.18/OTP 27 and Elixir 1.20/OTP 29.
Hosted CI must pass before release; local checks do not substitute for that matrix.

## Binding test references

The original coverage review used [OCP's binding tests](https://github.com/CadQuery/OCP/blob/b0495a71d10168b96cef8043ac39020a3fa45372/tests/test_ocp.py).
OCEx tests use independent analytic measurements and invalid-input checks rather
than copying Python test implementation or depending on a Python runtime.
