# Errors and native lifetimes

All public functions return tagged results. Invalid arguments fail with an error atom; C++ exceptions are caught at the boundary. A successful shape passes OCCT validation, but callers should also check measurements and topology against their design intent.

```elixir
{:error, :invalid_argument} = OCEx.box(-1, 2, 3)
{:ok, shape} = OCEx.box(1, 2, 3)
{:ok, true} = OCEx.valid?(shape)
```

Shapes own garbage-collected native resources. Retaining a subshape keeps it usable after the parent Elixir term is collected. Transformations and modeling operations preserve their inputs. Garbage collection determines reclamation; there is no manual free function.

Re-query edges after each operation. A fillet or chamfer accepts edges from the exact body passed to it, and rejects stale, foreign, or duplicate selections. Native topology identity (`OCEx.same?/2`) differs from geometric equivalence.

Persist a shape through BREP or STEP. Resource handles cannot be moved to another VM or meaningfully serialized with `term_to_binary/1`. OCCT BREP encodings and Smith revisions are not promised stable across toolkit versions or platforms.

## Error reasons

| Reason | Meaning |
| --- | --- |
| `:invalid_argument` | Wrong argument form, nonfinite/out-of-range number, or failed scalar precondition |
| `:wrong_shape_type` | A valid native shape has the wrong topology kind for the operation |
| `:foreign_subshape` | An edge does not belong to the supplied body's selection identity |
| `:duplicate_subshape` | A fillet/chamfer selection repeats an edge |
| `:disconnected_wire`, `:open_wire` | Edges cannot be joined, or a required boundary is open |
| `:non_planar_profile`, `:degenerate_extrusion` | Extrusion needs a planar face and displacement out of its plane |
| `:empty_shape` | Bounds are empty or volume centroid has zero volume |
| `:undefined_tangent` | The sampled edge derivative has no usable direction |
| `:operation_failed` | A kernel builder or transfer did not complete |
| `:invalid_shape` | Returned or imported topology failed OCCT validation |
| `:invalid_brep` | BREP data is malformed or incomplete |
| `:io_error` | File exchange or serialization failed |
| `:kernel_error` | OCCT raised a native exception |
| `:out_of_memory`, `:native_error` | Native allocation failure or another C++ exception |

An error atom identifies a category, not a detailed kernel diagnostic. Related
bad inputs can fail at different stages. Check the operation's contract and
measure intermediate shapes when narrowing down a failure.

## Native execution

Every NIF call is scheduled as CPU-bound dirty work and serialized by a mutex. This keeps ordinary BEAM schedulers available and avoids assuming arbitrary OCCT operations are safe on shared native data. Mutating algorithms receive copied geometry. This favors predictable ownership over parallel geometry throughput.

C++ exceptions are caught at the boundary. Native memory faults can still crash the VM; this is inherent to an in-process NIF. A process timeout or termination does not forcibly cancel a kernel call. Use trusted modeling inputs, and run experimental or untrusted workloads in a separate OS process. Kernel hot upgrades and hard cancellation are not supported.

The repository provides sanitizer and stress targets. The sanitizer instruments the wrapper, not an independently built OCCT installation.

OCEx source is MIT licensed. Open Cascade is a separate dependency with its own license and exception; no OCCT sources or binaries are vendored in this package.
