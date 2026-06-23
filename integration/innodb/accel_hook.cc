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
#include "active_view_registry.h"  // D-5 5-1b: leaf-domain mirror of InnoDB's active read-views

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
std::atomic<uint64_t> g_c_hit{0};            // consult outcome HIT
std::atomic<uint64_t> g_c_miss_absent{0};
std::atomic<uint64_t> g_c_miss_novisible{0};
std::atomic<uint64_t> g_c_miss_noncontig{0};
std::atomic<uint64_t> g_c_miss_ineligible{0};
// D-4 4d-prep: of the HITs, did the rec_t the caller built from the fetched image match vanilla's
// rebuilt *old_vers (data + delete flag + valid offsets)? Gate: construct_bad==0, construct_ok==hit.
std::atomic<uint64_t> g_c_construct_ok{0};
std::atomic<uint64_t> g_c_construct_bad{0};
// D-4 4d-2: cache-built records actually SERVED (returned to InnoDB in place of the walked version).
std::atomic<uint64_t> g_c_serve{0};
// D-5 diag: of the construct_BAD cases, did the cache rec's DB_TRX_ID equal vanilla's *old_vers
// (right version selected, bytes differ) or differ (consult picked the WRONG version)? Classifies the
// near-head/short-read construct_BAD found under oltp_read_write.
std::atomic<uint64_t> g_c_bad_trxsame{0};
std::atomic<uint64_t> g_c_bad_trxdiff{0};

// D-4 4b-3c TEST-ONLY toggles, read once from the environment at accel_init (set before g_ready is
// released, so the live hook/consult see them after their acquire of g_ready). Default off = prod.
//   ACCEL_PK_MASK_BITS=N : mask pk_hash to N low bits at BOTH populate and consult -> forces hash
//     collisions so the full-PK identity check is actually exercised.
//   ACCEL_NO_FULL_PK=1   : consult skips the full-PK check (negative control: a forced collision
//     then serves a cross-row image -> the shadow MUST report mismatches).
uint64_t g_pk_mask = 0;     // 0 = off; else (1<<bits)-1
bool g_no_full_pk = false;
bool g_no_schema_check = false;  // D-4 4c-2 negative control: consult ignores the schema_epoch tag
// D-4 4d-2 authoritative SERVE mode (0=off/shadow, 1=serve-only/skip-walk, 2=verify-serve). Read once
// at accel_init before g_ready is released; the live consult path acquires g_ready first, so a reader
// thread sees this write before it ever acts on the mode. Default 0 = shadow (safe).
int g_authoritative_mode = 0;

// D-5 5-1b: leaf-domain ACTIVE READ-VIEW REGISTRY (collection signal B). InnoDB pushes each view's
// {low_limit_id, up_limit_id} here on view_open (piggybacking the trx_sys mutex it already holds) and
// clears it on view_close; the BG GC (D-5, still OFF) will read a wait-free snapshot to build the dead
// zone. ACCEL_PUBLISH=0 disables the push so 5-1b can measure its OLTP cost against a baseline.
mvcc::ActiveViewRegistry<> g_view_reg;
bool g_publish_views = true;
std::atomic<uint64_t> g_view_published{0};
std::atomic<uint64_t> g_view_unpublished{0};
// D-5 5-1c: every MVCC::view_open entry is counted (g_view_open_calls, before the reuse/mutex branch)
// so we can confirm EVERY open path publishes (no view path is missed = the superset's ADD-reliability:
// g_view_open_calls ~= g_view_published). g_clock is a monotonic InnoDB clock (max view begin id) that
// the BG GC (5-2) will drive its boundary off (M4: the standalone clock never advances in-integration).
std::atomic<uint64_t> g_view_open_calls{0};
std::atomic<uint64_t> g_clock{0};

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
                               r.pk_len ? r.pk : nullptr, r.pk_len, static_cast<uint8_t>(r.delete_mark),
                               r.extra_len);
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
  if (const char *au = std::getenv("ACCEL_AUTHORITATIVE")) {
    if (au[0] == '1') g_authoritative_mode = 1;        // serve-only (skip the walk)
    else if (au[0] == '2') g_authoritative_mode = 2;   // verify-serve (walk + compare, then serve)
  }
  if (const char *pv = std::getenv("ACCEL_PUBLISH")) {
    if (pv[0] == '0') g_publish_views = false;         // baseline: OLTP without the view-registry push
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
  // D-4 4d-prep result. consult outcome buckets + the CONSTRUCT proof: of the HITs, the rec_t the
  // caller built from the fetched cache image matched vanilla's rebuilt *old_vers. Gate:
  // construct_bad=0 and construct_ok==hit (a cache-built record is a valid servable substitute).
  std::fprintf(stderr,
               "[accel] consult: calls=%llu hit=%llu miss{absent=%llu novisible=%llu noncontig=%llu "
               "ineligible=%llu} | construct_ok=%llu construct_BAD=%llu | auth_mode=%d served=%llu\n",
               (unsigned long long)g_c_calls.load(), (unsigned long long)g_c_hit.load(),
               (unsigned long long)g_c_miss_absent.load(), (unsigned long long)g_c_miss_novisible.load(),
               (unsigned long long)g_c_miss_noncontig.load(), (unsigned long long)g_c_miss_ineligible.load(),
               (unsigned long long)g_c_construct_ok.load(), (unsigned long long)g_c_construct_bad.load(),
               g_authoritative_mode, (unsigned long long)g_c_serve.load());
  // D-5 5-1b: view-registry push evidence. published/unpublished are the per-view_open/close push
  // counts (not per row); live_snapshot is what the GC would see now (~0 at shutdown, all closed).
  std::vector<mvcc::ViewCut> vcut; uint64_t vfloor;
  g_view_reg.snapshot(vcut, vfloor);
  std::fprintf(stderr, "[accel] view-registry: open_calls=%llu published=%llu unpublished=%llu publish_on=%d "
               "live_snapshot=%zu floor=%s clock=%llu\n",
               (unsigned long long)g_view_open_calls.load(),
               (unsigned long long)g_view_published.load(), (unsigned long long)g_view_unpublished.load(),
               g_publish_views ? 1 : 0, vcut.size(),
               vfloor == mvcc::ActiveViewRegistry<>::NO_FLOOR ? "none" : "set",
               (unsigned long long)g_clock.load());
  std::fprintf(stderr, "[accel] construct_BAD detail: trx_same=%llu (right version, bytes differ) "
               "trx_diff=%llu (WRONG version picked)\n",
               (unsigned long long)g_c_bad_trxsame.load(), (unsigned long long)g_c_bad_trxdiff.load());
  delete g_accel;  // drainer joined -> sole owner; dtor is a no-op for BG GC (never started)
  g_accel = nullptr;
}

void accel_on_undo(uint64_t table_id, uint64_t pk_hash, uint64_t trx_id, uint64_t old_trx_id,
                   uint64_t space_id, uint64_t page_no, uint64_t offset, uint64_t op_type,
                   const unsigned char *img, uint64_t img_len,
                   const unsigned char *pk, uint64_t pk_len, uint64_t delete_mark,
                   uint64_t extra_len) noexcept {
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
  r.extra_len = static_cast<uint32_t>(extra_len);   // D-4 4d: record header size within img
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

int accel_consult_fetch(uint64_t table_id, uint64_t pk_hash,
                        const unsigned char *pk, uint64_t pk_len,
                        uint64_t up_limit_id, uint64_t low_limit_id, uint64_t creator_trx_id,
                        const uint64_t *m_ids, uint64_t m_ids_n,
                        uint64_t live_top_writer, uint64_t live_schema_epoch,
                        unsigned char *out_buf, unsigned int out_cap,
                        unsigned int *out_len, unsigned int *out_extra) noexcept {
  // D-4 4d-prep: runs on InnoDB reader threads at the consistent-read version-build site. Read-only
  // consult; on HIT copies the cached FULL physical record into out_buf UNDER the EBR Guard (M2) so
  // nothing escapes the guard. Returns the outcome code (0=HIT, 1..4 = miss reasons) and bumps the
  // outcome counters. The caller (InnoDB domain) builds a rec_t from out_buf and compares to vanilla.
  if (!g_ready.load(std::memory_order_acquire) || g_accel == nullptr) return 1;
  g_c_calls.fetch_add(1, std::memory_order_relaxed);
  if (g_pk_mask) pk_hash &= g_pk_mask;   // test-only: same mask as populate so collisions line up
  const uint64_t sch = g_no_schema_check ? ~uint64_t(0) : live_schema_epoch;  // ~0 = skip schema gate
  using CO = mvcc::Accelerate_mvcc::ConsultOutcome;
  uint32_t outlen = 0, outextra = 0;
  CO o;
  try {
    o = g_accel->consult(table_id, pk_hash, pk, static_cast<uint32_t>(pk_len),
                         up_limit_id, low_limit_id, creator_trx_id,
                         m_ids, static_cast<std::size_t>(m_ids_n), live_top_writer,
                         out_buf, out_cap, &outlen,
                         /*require_full_pk=*/!g_no_full_pk, sch, &outextra);
  } catch (...) { return 1; }  // defensive: consult does not allocate/throw, but the facade is noexcept
  switch (o) {
    case CO::HIT:
      g_c_hit.fetch_add(1, std::memory_order_relaxed);
      if (out_len) *out_len = outlen;
      if (out_extra) *out_extra = outextra;
      return 0;
    case CO::MISS_ABSENT:     g_c_miss_absent.fetch_add(1, std::memory_order_relaxed);     return 1;
    case CO::MISS_NOVISIBLE:  g_c_miss_novisible.fetch_add(1, std::memory_order_relaxed);  return 2;
    case CO::MISS_NONCONTIG:  g_c_miss_noncontig.fetch_add(1, std::memory_order_relaxed);  return 3;
    case CO::MISS_INELIGIBLE: g_c_miss_ineligible.fetch_add(1, std::memory_order_relaxed); return 4;
  }
  return 1;
}

void accel_note_construct(int matched) noexcept {
  (matched ? g_c_construct_ok : g_c_construct_bad).fetch_add(1, std::memory_order_relaxed);
}

// D-4 4d-2: authoritative serve mode + serve counter (see accel_hook.h). g_authoritative_mode is
// published before g_ready's release-store in accel_init; the consult path's g_ready acquire-load
// happens-before this read on the same reader thread, so no separate atomic is needed.
int accel_authoritative_mode() noexcept { return g_authoritative_mode; }
void accel_note_serve() noexcept { g_c_serve.fetch_add(1, std::memory_order_relaxed); }

// D-5 5-1b: push facade for InnoDB's read-view lifecycle (collection signal B). Called from
// MVCC::view_open (both the reuse fast-path and the mutex path) and MVCC::view_close. begin =
// view->low_limit_id() (the view's begin / high-water = dead-zone sort key), up = view->up_limit_id()
// (its low-water = the conservative right edge for the next hole). Leaf-domain: a lock-free publish
// into g_view_reg, no InnoDB call-back. Gated on g_ready (the live window) and the ACCEL_PUBLISH
// toggle. begin==0 is skipped (the registry treats 0 as an empty slot).
void accel_publish_view_open(uint64_t begin, uint64_t up) noexcept {
  if (!g_ready.load(std::memory_order_acquire) || !g_publish_views || begin == 0) return;
  g_view_reg.publish(begin, up);
  g_view_published.fetch_add(1, std::memory_order_relaxed);
  // monotonic clock = max view begin id (next-trx-id proxy); drives the BG GC boundary in 5-2.
  uint64_t c = g_clock.load(std::memory_order_relaxed);
  while (begin > c && !g_clock.compare_exchange_weak(c, begin, std::memory_order_relaxed)) {
  }
}

// D-5 5-1c: counted at the very top of MVCC::view_open (before the reuse/mutex branch), so every open
// path is tallied -- comparing this to g_view_published proves no open path is missed (no live view
// silently omitted from the registry). Leaf-domain, no toggle gate (cheap counter).
void accel_note_view_open() noexcept {
  if (!g_ready.load(std::memory_order_acquire)) return;
  g_view_open_calls.fetch_add(1, std::memory_order_relaxed);
}

// D-5 diag: classify a construct_BAD by whether the served version's trx_id matched vanilla's.
void accel_note_bad_trx(int same) noexcept {
  (same ? g_c_bad_trxsame : g_c_bad_trxdiff).fetch_add(1, std::memory_order_relaxed);
}
void accel_publish_view_close() noexcept {
  if (!g_ready.load(std::memory_order_acquire) || !g_publish_views) return;
  g_view_reg.unpublish();
  g_view_unpublished.fetch_add(1, std::memory_order_relaxed);
}
