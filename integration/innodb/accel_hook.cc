// Licensed under the MIT license.
//
// Stage D-1b-1: count-only body, but now validates KEY PLUMBING. The call site (trx0rec.cc)
// extracts the clustered PK -> pk_hash and the prior DB_TRX_ID -> old_trx_id and filters to
// MODIFY-op. Here we only count and track pk_hash BREADTH (a 1024-bucket set) so the log proves
// the keys are row-unique: if PK extraction were broken (all rows -> one key), pk_buckets_seen
// would stay 1; a healthy run lights up many buckets. Still zero allocation / locks / InnoDB
// calls -> no hot-path risk. D-1b-2/3 replace this body with a lock-free enqueue + off-latch
// drainer that performs the real insert.

#include "accel_hook.h"

#include <atomic>
#include <cstdio>

namespace {
std::atomic<uint64_t> g_undo_count{0};
std::atomic<uint32_t> g_pk_seen[1024];  // pk_hash breadth proxy (bit per low-10-bits bucket)
}

void accel_on_undo(uint64_t table_id, uint64_t pk_hash, uint64_t trx_id, uint64_t old_trx_id,
                   uint64_t space_id, uint64_t page_no, uint64_t offset, uint64_t op_type) noexcept {
  g_pk_seen[pk_hash & 1023u].fetch_or(1u, std::memory_order_relaxed);
  const uint64_t n = g_undo_count.fetch_add(1, std::memory_order_relaxed) + 1;
  if (n % 200000 == 0) {
    int nz = 0;
    for (int i = 0; i < 1024; ++i)
      if (g_pk_seen[i].load(std::memory_order_relaxed)) ++nz;
    std::fprintf(stderr,
                 "[accel] undo=%llu pk_buckets_seen=%d/1024 (last table=%llu pk=%016llx trx=%llu old=%llu loc=%llu:%llu:%llu op=%llu)\n",
                 (unsigned long long)n, nz, (unsigned long long)table_id,
                 (unsigned long long)pk_hash, (unsigned long long)trx_id,
                 (unsigned long long)old_trx_id, (unsigned long long)space_id,
                 (unsigned long long)page_no, (unsigned long long)offset,
                 (unsigned long long)op_type);
  }
}
