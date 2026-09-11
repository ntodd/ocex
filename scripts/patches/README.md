# OCCT 7.9.3 allocator alignment

`occt-7.9.3-alignment.patch` is a local correction to the pinned OCCT source, not
an upstream release. The original incremental allocator advances its cursor by
the requested byte count, so a small allocation can leave the next pointer
misaligned for a pointer-bearing C++ object. GCC's undefined-behavior sanitizer
reports this during meshing (`NCollection_TListNode<int>::delNode`).

The patch rounds allocations up to `alignof(std::max_align_t)` and checks for size
overflow. It changes neither the public API nor geometry algorithms. The source
installer applies it after verifying the upstream tarball, and runs
`check-allocator.cpp` against the installed library. Native sanitizer, model, and
file-export tests provide additional verification.

Original source and license:
https://github.com/Open-Cascade-SAS/OCCT/blob/V7_9_3/src/NCollection/NCollection_IncAllocator.cxx

The modified OCCT dependency retains its LGPL 2.1 license with the OCCT exception;
it is not relicensed as OCEx's MIT code. The Hex archive includes this small patch,
not OCCT sources or binaries. When upgrading OCCT, remove the patch only after the
allocator regression check and native tests pass against the new version.
