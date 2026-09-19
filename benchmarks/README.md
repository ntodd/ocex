# Native CAD modeling experiments

The standalone harness compares copying vs OCCT non-destructive input sharing,
sequential vs batched booleans, and serial vs parallel execution on 1, 8, and 32
tools. It also breaks down a box fillet. Every measured result is validated;
boolean cases check analytical volume and byte-identical source BREP after each
sample. Copying, kernel execution, result validation, same-domain cleanup, and
serialization are timed separately. End-to-end timing includes operation setup
and destruction. Correctness checks outside those stages are not timed.

```sh
cmake -S benchmarks -B /tmp/ocex-modeling-bench -DCMAKE_BUILD_TYPE=Release -DOpenCASCADE_DIR="$HOME/.local/occt-7.9.3/lib/cmake/opencascade"
cmake --build /tmp/ocex-modeling-bench --parallel 4
/tmp/ocex-modeling-bench/modeling 9 > benchmarks/results/modeling-1.csv
```

Run without competing builds or benchmarks. There are two warmups per case and
nine measured samples by default. CSVs retain every sample. The standalone
experiment does not establish the concurrency safety of shared input geometry;
production operations retain input copies, non-destructive mode, serial execution,
and shape validation. A parallel flag is not a guarantee of a speedup.

The production additions `OCEx.cut_many/2` and `OCEx.fuse_many/2` submit separate
tools in one Boolean operation. They do not construct an overlapping compound
as a shortcut, nor remove intermediate checks from existing pairwise operations.
Existing two-shape operations retain their behavior.

## Findings — 2026-09-19

OCCT 7.9.3, macOS arm64, two runs of nine measured samples per case after two
warmups. The standalone harness uses CMake Release; the application measurements
in Smith use its normal RelWithDebInfo native build. Use the application results
for end-to-end claims. The following are run-2 stage medians in milliseconds:

| Case | Copy | Kernel | Validate | Cleanup | Serialize | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| cut/32/chain/copy/serial | 3.84 | 62.54 | 38.69 | 49.45 | 0.48 | 156.12 |
| cut/32/batch/copy/serial | 0.26 | 25.16 | 2.39 | 3.02 | 0.48 | 31.47 |
| fuse/32/chain/copy/serial | 12.49 | 130.18 | 97.39 | 150.35 | 1.63 | 395.86 |
| fuse/32/batch/copy/serial | 0.69 | 33.03 | 11.14 | 10.86 | 1.70 | 58.34 |
| fillet/box/all_edges | 0.02 | 1.93 | 0.74 | 1.16 | 0.30 | 4.15 |

Stage medians need not sum exactly to the total median. The total also includes
setup and destruction. Batching reduces kernel work and avoids constructing,
validating, and cleaning pairwise intermediate results. Final validation remains.

Removing copies reduced the 32-cut chain from 156 to 151 ms, but increased the
32-fusion chain from 396 to 455 ms. Parallel batches took 33.2 vs 31.5 ms for cuts
and 56.9 vs 58.3 ms for fusions. Neither input sharing nor parallelism was adopted.
Both raw result files include smaller workloads and every sample.

Actual model profiling in Smith found another bottleneck: repeated precise
volume queries during hole validation. Production Shape resources now memoize
their first successful volume result under the existing State mutex. Integration
precision is unchanged, transformed/new resources start cold, and resource death
discards the cache. No new global cache or retained geometry is introduced.
Smith's modeling report contains cold/warm measurements and full-model rebuilds.

The existing global NIF mutex still serializes calls. Removing it or sharing
native inputs requires a separate native concurrency audit; these changes do
neither. Geometry checks are preserved, and existing pairwise APIs are unchanged.
