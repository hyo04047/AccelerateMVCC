// Licensed under the MIT license.
//
// Stage D-1a: count-only populate hook. Proves the InnoDB->accelerator call site fires from
// real undo creation, with zero risk to InnoDB's hot path (one relaxed atomic add + a throttled
// stderr line every 1M calls -> shows up in the mysqld error log). No allocation, no locks.
// D-1b will replace the body with a real insert into the AccelerateMVCC index.

#include "accel_hook.h"

#include <atomic>
#include <cstdio>

namespace {
std::atomic<uint64_t> g_undo_count{0};
}

void accel_on_undo(uint64_t table_id, uint64_t trx_id, uint64_t space_id, uint64_t page_no,
                   uint64_t offset, uint64_t op_type) {
  const uint64_t n = g_undo_count.fetch_add(1, std::memory_order_relaxed) + 1;
  if (n % 200000 == 0) {
    std::fprintf(stderr,
                 "[accel] undo records seen: %llu (last table=%llu trx=%llu loc=%llu:%llu:%llu op=%llu)\n",
                 (unsigned long long)n, (unsigned long long)table_id, (unsigned long long)trx_id,
                 (unsigned long long)space_id, (unsigned long long)page_no,
                 (unsigned long long)offset, (unsigned long long)op_type);
  }
}
