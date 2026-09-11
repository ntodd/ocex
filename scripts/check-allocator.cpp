#include <NCollection_IncAllocator.hxx>
#include <cstdint>
#include <cstddef>
#include <cstdio>
int main() {
  NCollection_IncAllocator allocator;
  for (std::size_t size = 1; size <= 128; ++size) {
    auto pointer = allocator.Allocate(size);
    if (reinterpret_cast<std::uintptr_t>(pointer) % alignof(std::max_align_t)) {
      std::fprintf(stderr, "OCCT allocator returned an unaligned pointer after size %zu\n", size);
      return 1;
    }
  }
}
