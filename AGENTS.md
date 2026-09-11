# Project conventions

- Keep public operations immutable and use documented tagged errors for modeling failures.
- Add behavioral tests before changing an exposed operation. Use analytic geometry and meaningful invariants.
- Run `make check docs` after changes. Do not weaken geometric checks to make a model pass.
- This repository is intended for public release. Keep private consumer projects and their assets, examples, and documentation outside the checkout and Git history.
- Keep OCEx independent of Smith. Native geometry and ownership belong here; CAD recipes and selectors do not.
- No Python dependency or runtime. Use the C++ NIF directly.
- Run `make sanitize stress` when changing native ownership or execution.
