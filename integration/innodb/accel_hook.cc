// Licensed under the MIT license.
//
// Stage D-1b-2b: wire the validated bounded MPMC ring (accel_ring.h) into the InnoDB hook.
// The hook (under the page latch) only ENQUEUES a scalar record -- noexcept, no allocation, no
// lock, full -> drop (never blocks a latch holder). A single off-latch drainer thread pops and
// (for now) just counts + tracks pk_hash breadth; D-1b-3 will make it do the real insert into
// the AccelerateMVCC index. Explicit init/shutdown lifecycle (no static destructor) + a ready
// gate so the hook is a no-op outside the live window. accel is a LEAF lock domain: nothing here
// includes an InnoDB header or calls back into InnoDB.

#include "accel_hook.h"
#include "accel_ring.h"
#include "accelerateMVCC.h"  // D-1b-3a: pull the real accelerator into the mysqld/innobase build

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

namespace {
constexpr unsigned long TRX_UNDO_MODIFY = 2;  // mirrors InnoDB TRX_UNDO_MODIFY_OP

accel::Ring<(1u << 16)> g_ring;          // 65536 slots
std::atomic<bool> g_started{false};      // accel_init ran
std::atomic<bool> g_ready{false};        // hook may enqueue
std::atomic<bool> g_stop{false};         // drainer should exit
std::atomic<uint64_t> g_enq{0};
std::atomic<uint64_t> g_dropped{0};
std::atomic<uint64_t> g_drained{0};
std::atomic<uint32_t> g_pk_seen[1024];   // pk breadth proxy (drainer-only writer)
std::thread g_drainer;

// D-4 4b-3b SHADOW consult counters (read by many InnoDB reader threads -> atomic). The headline
// gate is g_c_hit_mismatch == 0: every time the cache claims a HIT, its image equals what InnoDB's
// consistent read actually rebuilt. The MISS buckets are expected (drainer lag, no-visible, etc.);
// they just mean "fall back to the full walk" and never a wrong result.
std::atomic<uint64_t> g_c_calls{0};
std::atomic<uint64_t> g_c_hit_match{0};
std::atomic<uint64_t> g_c_hit_mismatch{0};
std::atomic<uint64_t> g_c_miss_absent{0};
std::atomic<uint64_t> g_c_miss_novisible{0};
std::atomic<uint64_t> g_c_miss_noncontig{0};
std::atomic<uint64_t> g_c_miss_ineligible{0};
std::atomic<uint64_t> g_c_vanilla_null{0};

// D-4 4b-3c TEST-ONLY toggles, read once from the environment at accel_init (set before g_ready is
// released, so the live hook/consult see them after their acquire of g_ready). Default off = prod.
//   ACCEL_PK_MASK_BITS=N : mask pk_hash to N low bits at BOTH populate and consult -> forces hash
//     collisions so the full-PK identity check is actually exercised.
//   ACCEL_NO_FULL_PK=1   : consult skips the full-PK check (negative control: a forced collision
//     then serves a cross-row image -> the shadow MUST report mismatches).
uint64_t g_pk_mask = 0;     // 0 = off; else (1<<bits)-1
bool g_no_full_pk = false;
bool g_no_schema_check = false;  // D-4 4c-2 negative control: consult ignores the schema_epoch tag

// D-1b-3a: the real AccelerateMVCC index lives inside mysqld now. record_count=0 -> no ctor
// pre-creation (keys are created dynamically). BG GC is intentionally NOT started (populate-only;
// the deadzone GC must be re-driven from InnoDB's read views before it can run -- D-3). The
// drainer (single consumer) will be the only writer to it. D-1b-3a only constructs it (proving
// the build/link/boot); D-1b-3b makes consume() call the low-level insert.
mvcc::Accelerate_mvcc *g_accel = nullptr;

int pk_buckets() {
  int nz = 0;
  for (int i = 0; i < 1024; ++i)
    if (g_pk_seen[i].load(std::memory_order_relaxed)) ++nz;
  return nz;
}

void consume(const accel::UndoRec &r) {
  g_pk_seen[r.pk_hash & 1023u].fetch_or(1u, std::memory_order_relaxed);
  // D-1b-3b: real single-consumer insert into the AccelerateMVCC index. Only the drainer touches
  // g_accel, so the index has exactly one mutator (no contention). Low-level insert() bypasses
  // Trx_manager/get_mutex. BG GC is OFF -> memory grows by design for this populate-only stage.
  // D-4 (4b-0): the VISIBILITY key is the version's creator = old DB_TRX_ID (r.old_trx_id), NOT the
  // writer. The writer (r.trx_id = the overwriting trx->id) is passed separately as the last arg so
  // the node carries both: changes_visible judges on version_trx_id; the contiguity/purge gates use
  // writer_trx_id. (Pre-4b this passed r.trx_id as the key -> every version judged by its overwriter,
  // off by exactly one version.)
  // D-4 4b-1: also carry the full-PK identity bytes (collision authority) and the delete-mark.
  if (g_accel) g_accel->insert(r.table_id, r.pk_hash, r.old_trx_id, r.space_id, r.page_no, r.offset,
                               r.img_len ? r.img : nullptr, r.img_len, r.trx_id,
                               r.pk_len ? r.pk : nullptr, r.pk_len, static_cast<uint8_t>(r.delete_mark));
  const uint64_t n = g_drained.fetch_add(1, std::memory_order_relaxed) + 1;
  if (n % 500000 == 0) {
    // chain_length is non-guarded, but the drainer is the SOLE mutator of g_accel and we call it
    // from that same thread -> no concurrent mutation -> safe. Shows this (hot) key's chain depth
    // is actually growing (GC off), i.e. the index is being populated for real.
    size_t cl = g_accel ? g_accel->chain_length(r.table_id, r.pk_hash) : 0;
    std::fprintf(stderr, "[accel] drained=%llu enq=%llu dropped=%llu pk_buckets=%d/1024 cur_key_chain_len=%zu last_pk_len=%u last_del=%u\n",
                 (unsigned long long)n, (unsigned long long)g_enq.load(),
                 (unsigned long long)g_dropped.load(), pk_buckets(), cl,
                 (unsigned)r.pk_len, (unsigned)r.delete_mark);
  }
}

void drain_loop() {
  accel::UndoRec r;
  while (!g_stop.load(std::memory_order_acquire)) {
    bool any = false;
    while (g_ring.dequeue(r)) { consume(r); any = true; }
    if (!any) std::this_thread::sleep_for(std::chrono::microseconds(100));
  }
  while (g_ring.dequeue(r)) consume(r);  // final drain after stop
}
}  // namespace

void accel_init() noexcept {
  bool expected = false;
  if (!g_started.compare_exchange_strong(expected, true)) return;  // already inited
  g_stop.store(false, std::memory_order_relaxed);
  // D-4 4b-3c test toggles (read before g_ready is released below).
  if (const char *mb = std::getenv("ACCEL_PK_MASK_BITS")) {
    unsigned long bits = std::strtoul(mb, nullptr, 10);
    if (bits >= 1 && bits <= 30) g_pk_mask = (uint64_t(1) << bits) - 1;
  }
  if (const char *nf = std::getenv("ACCEL_NO_FULL_PK")) {
    if (nf[0] == '1') g_no_full_pk = true;
  }
  if (const char *ns = std::getenv("ACCEL_NO_SCHEMA_CHECK")) {
    if (ns[0] == '1') g_no_schema_check = true;
  }
  try {
    g_accel = new mvcc::Accelerate_mvcc(0, 16);  // dynamic keys, 64k-bin cuckoo, BG GC NOT started
    g_drainer = std::thread(drain_loop);
  } catch (...) {
    delete g_accel;
    g_accel = nullptr;
    g_started.store(false, std::memory_order_relaxed);
    return;
  }
  g_ready.store(true, std::memory_order_release);
  std::fprintf(stderr, "[accel] init: drainer started, accelerator constructed\n");
}

void accel_shutdown() noexcept {
  if (!g_started.load(std::memory_order_acquire)) return;
  g_ready.store(false, std::memory_order_release);  // hook stops enqueuing
  g_stop.store(true, std::memory_order_release);
  if (g_drainer.joinable()) g_drainer.join();
  std::fprintf(stderr,
               "[accel] shutdown: enq=%llu drained=%llu dropped=%llu pk_buckets=%d/1024 live_epoch_buckets=%zu\n",
               (unsigned long long)g_enq.load(), (unsigned long long)g_drained.load(),
               (unsigned long long)g_dropped.load(), pk_buckets(),
               g_accel ? g_accel->long_live_size() : 0);
  // D-4 4b-3b SHADOW result. The gate is hit_MISMATCH=0 with hit_match>0 (cache verified against
  // vanilla on real consistent reads). MISS buckets = safe full-walk fallbacks.
  std::fprintf(stderr,
               "[accel] consult(shadow): calls=%llu hit_match=%llu hit_MISMATCH=%llu "
               "miss{absent=%llu novisible=%llu noncontig=%llu ineligible=%llu} vanilla_null=%llu\n",
               (unsigned long long)g_c_calls.load(), (unsigned long long)g_c_hit_match.load(),
               (unsigned long long)g_c_hit_mismatch.load(), (unsigned long long)g_c_miss_absent.load(),
               (unsigned long long)g_c_miss_novisible.load(), (unsigned long long)g_c_miss_noncontig.load(),
               (unsigned long long)g_c_miss_ineligible.load(), (unsigned long long)g_c_vanilla_null.load());
  delete g_accel;  // drainer joined -> sole owner; dtor is a no-op for BG GC (never started)
  g_accel = nullptr;
}

void accel_on_undo(uint64_t table_id, uint64_t pk_hash, uint64_t trx_id, uint64_t old_trx_id,
                   uint64_t space_id, uint64_t page_no, uint64_t offset, uint64_t op_type,
                   const unsigned char *img, uint64_t img_len,
                   const unsigned char *pk, uint64_t pk_len, uint64_t delete_mark) noexcept {
  // D-1b-4 hardening invariants (this runs UNDER the InnoDB clustered leaf-page X-latch):
  //   * noexcept: cannot unwind into InnoDB (enforced by the keyword).
  //   * no allocation: only atomics + a trivially-copyable UndoRec into a preallocated ring slot
  //     (the static_asserts in accel_ring.h guarantee the copy is alloc-free).
  //   * no lock / never blocks: the ring is lock-free; full -> drop.
  //   * no InnoDB call: accel is a LEAF lock domain (this TU includes no InnoDB header), so the
  //     InnoDB->accel edge stays one-way and cannot form a cross-domain latch cycle.
  if (op_type != TRX_UNDO_MODIFY) return;           // versions only (defensive; call site filters)
  if (!g_ready.load(std::memory_order_acquire)) return;  // outside live window
  if (g_pk_mask) pk_hash &= g_pk_mask;               // test-only: force hash collisions
  accel::UndoRec r{table_id, pk_hash, trx_id, old_trx_id, space_id, page_no, offset, op_type};
  // D-4 4b-1: carry the delete-mark explicitly (the data-payload image excludes the record header
  // where REC_INFO_DELETED_FLAG lives) and copy the full-PK identity bytes (alloc-free prefix
  // memcpy under the latch). Over-cap/absent PK -> pk_len stays 0 -> consult cannot prove identity
  // -> MISS (never a wrong row).
  r.delete_mark = (delete_mark != 0) ? 1u : 0u;
  if (pk != nullptr && pk_len > 0 && pk_len <= accel::ACCEL_PK_MAX) {
    r.pk_len = static_cast<uint32_t>(pk_len);
    std::memcpy(r.pk, pk, pk_len);
  }
  // D-4: copy the captured row-image DATA payload into the slot (alloc-free prefix memcpy, still
  // under the latch). Over-cap or absent -> img_len stays 0 -> drainer stores locator-only and
  // consult will full-walk this version. Bytes are immutable once published (set-once payload).
  if (img != nullptr && img_len > 0 && img_len <= accel::ACCEL_IMG_MAX) {
    r.img_len = static_cast<uint32_t>(img_len);
    std::memcpy(r.img, img, img_len);
  }
  if (g_ring.enqueue(r))
    g_enq.fetch_add(1, std::memory_order_relaxed);
  else
    g_dropped.fetch_add(1, std::memory_order_relaxed);  // full -> drop, never block the latch
}

void accel_consult_shadow(uint64_t table_id, uint64_t pk_hash,
                          const unsigned char *pk, uint64_t pk_len,
                          uint64_t up_limit_id, uint64_t low_limit_id, uint64_t creator_trx_id,
                          const uint64_t *m_ids, uint64_t m_ids_n,
                          uint64_t live_top_writer, uint64_t live_schema_epoch,
                          const unsigned char *vanilla, uint64_t vanilla_len) noexcept {
  // D-4 4b-3b: SHADOW. Runs on InnoDB reader threads at the consistent-read version-build site,
  // AFTER vanilla rebuilt the visible version. We ask our cache what it would serve and byte-compare
  // it against vanilla's bytes -- but never use our answer (InnoDB returns its own). The consult is
  // read-only and copies the image into our stack buffer UNDER its EBR Guard (M2), so nothing escapes.
  if (!g_ready.load(std::memory_order_acquire) || g_accel == nullptr) return;
  g_c_calls.fetch_add(1, std::memory_order_relaxed);
  if (g_pk_mask) pk_hash &= g_pk_mask;   // test-only: same mask as populate so collisions line up
  const uint64_t sch = g_no_schema_check ? ~uint64_t(0) : live_schema_epoch;  // ~0 = skip schema gate
  using CO = mvcc::Accelerate_mvcc::ConsultOutcome;
  unsigned char buf[accel::ACCEL_IMG_MAX];
  uint32_t outlen = 0;
  CO o;
  try {
    o = g_accel->consult(table_id, pk_hash, pk, static_cast<uint32_t>(pk_len),
                         up_limit_id, low_limit_id, creator_trx_id,
                         m_ids, static_cast<std::size_t>(m_ids_n), live_top_writer,
                         (vanilla != nullptr) ? buf : nullptr, sizeof(buf), &outlen,
                         /*require_full_pk=*/!g_no_full_pk, sch);
  } catch (...) { return; }  // defensive: consult does not allocate/throw, but the facade is noexcept

  if (vanilla == nullptr) {
    // vanilla found NO visible version (fresh insert / no history). The cache must not claim a HIT.
    if (o == CO::HIT) g_c_hit_mismatch.fetch_add(1, std::memory_order_relaxed);
    else              g_c_vanilla_null.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  switch (o) {
    case CO::HIT: {
      bool eq = (static_cast<uint64_t>(outlen) == vanilla_len);
      if (eq) {
        for (uint32_t i = 0; i < outlen; ++i)
          if (buf[i] != vanilla[i]) { eq = false; break; }
      }
      (eq ? g_c_hit_match : g_c_hit_mismatch).fetch_add(1, std::memory_order_relaxed);
      break;
    }
    case CO::MISS_ABSENT:     g_c_miss_absent.fetch_add(1, std::memory_order_relaxed); break;
    case CO::MISS_NOVISIBLE:  g_c_miss_novisible.fetch_add(1, std::memory_order_relaxed); break;
    case CO::MISS_NONCONTIG:  g_c_miss_noncontig.fetch_add(1, std::memory_order_relaxed); break;
    case CO::MISS_INELIGIBLE: g_c_miss_ineligible.fetch_add(1, std::memory_order_relaxed); break;
  }
}
