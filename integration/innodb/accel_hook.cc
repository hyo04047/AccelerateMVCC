// Licensed under the MIT license.
//
// Stage D-1b-2b: wire the validated bounded MPMC ring (accel_ring.h) into the InnoDB hook.
// The hook (under the page latch) only ENQUEUES a scalar record -- noexcept, no allocation, no
// lock, full -> drop (never blocks a latch holder). A single off-latch drainer thread pops and
// does the real single-consumer insert into the AccelerateMVCC index; the same off-latch domain also
// drives the cuts-driven deadzone GC and answers shadow/serve consults. Explicit init/shutdown lifecycle
// (no static destructor) + a ready
// gate so the hook is a no-op outside the live window. accel is a LEAF lock domain: nothing here
// includes an InnoDB header or calls back into InnoDB.

#include "accel_hook.h"
#include "accel_ring.h"
#include "accelerateMVCC.h"  // D-1b-3a: pull the real accelerator into the mysqld/innobase build
#include "active_view_registry.h"  // D-5 5-1b: leaf-domain mirror of InnoDB's active read-views
#include "common.h"          // EPOCH_SIZE / EPOCH_TABLE_SIZE -- the GC PERIOD is derived from them

#include <algorithm>
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
std::atomic<bool> g_drop_warned{false};                  // ⓣ13: one-shot ring-overflow WARNING latch (drainer emits, off-latch)
std::atomic<uint64_t> g_first_drop_table{~uint64_t(0)};  // ⓣ13: table_id of the first overflow (attribution)
std::atomic<uint64_t> g_drained{0};
std::atomic<uint32_t> g_pk_seen[1024];   // pk breadth proxy (drainer-only writer)
std::thread g_drainer;
// ⓠ3 (Phase 2): retention reporter. A held-LLT run must be sampled AT ITS PEAK -- the shutdown dump is
// post-LLT-release, after GC has reclaimed everything the LLT was pinning, so it reads ~empty. This
// read-only periodic reporter logs the cache-vs-InnoDB retention while the LLT still holds: the O(1)
// aggregate "live cache versions" (drained - retired, compared against InnoDB's History List Length read
// separately via SQL) plus the freshest drained key's Guard-safe chain length (the hot key under a skewed
// churn = the integration analog of the Stage-C "hot-chain max"; one key, so cheap even when a tail-only
// chain is huge). Gated by ACCEL_RETENTION_MS (0/unset = reporter not started = behavior-neutral). A
// SEPARATE leaf-domain thread, never on the hot path.
// Per-bucket representative key (table_id, pk_hash), written by the drainer the first time it touches a
// pk-breadth bucket. Gives the reporter an UNBIASED key set to sample (~one per occupied bucket, covering
// hot AND cold keys). The earlier recent-drained ring was biased toward hot keys -- which the deadzone
// reclaims BEST (dense trx-ids -> narrow intervals that fit the dead zones) -- so it missed the long chains
// that accumulate on cold/medium keys (sparse updates -> wide intervals that straddle active cuts).
std::atomic<uint64_t> g_key_rep_table[1024];
std::atomic<uint64_t> g_key_rep_pk[1024];
unsigned g_retention_cap = 512;          // ACCEL_RETENTION_CAP: bound the per-key chain walk (0 = unbounded)
std::thread g_reporter;
std::atomic<bool> g_rep_stop{false};
unsigned g_retention_ms = 0;             // ACCEL_RETENTION_MS; 0 = reporter off
std::chrono::steady_clock::time_point g_t0;  // set once at accel_init (before the reporter starts) for t_ms
// D-5 ⑤a-2: the integration deadzone-GC driver. It is a SEPARATE leaf-domain thread, NOT the
// object-owned standalone BG GC (Accelerate_mvcc::start_background_gc) -- that one drives off the
// standalone trx manager, which the drainer's low-level insert never advances (M4). This driver
// will instead read the pushed InnoDB clock (g_clock) + the active-view registry (g_view_reg) and
// run a cuts-driven GC cycle. Because it is NOT owned by g_accel's dtor, accel_shutdown must stop
// and join it BEFORE delete g_accel (review must-fix 1). Step 1 wires the lifecycle with an EMPTY
// body (no sweeping) to prove start/stop ordering before any real reclamation is added (step 2).
std::thread g_gc;
std::atomic<bool> g_gc_stop{false};      // GC driver should exit
bool g_gc_enabled = false;               // ACCEL_GC=1 drives the deadzone GC ON (default OFF: GC dormant,
                                         // existing GC-off runs unchanged); read once at accel_init.

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
std::atomic<uint64_t> g_c_miss_gcrace{0};   // D-5 C3: gen-gate race MISS (distinct from a real contiguity break)
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
// D-5 diag: of the trx_diff (wrong version) cases, did consult serve an OLDER version than vanilla
// (cache behind = drainer-lag / contiguity-gate leak) or a NEWER one (visibility-mirror disagreement)?
std::atomic<uint64_t> g_c_bad_older{0};
std::atomic<uint64_t> g_c_bad_newer{0};
// D-5 diag6: of the NEWER cases, did the LIVE view itself consider consult's chosen version visible?
// vsees = vanilla agrees ct is visible (=> ct is just not on vanilla's chain = cross-generation cache);
// vhides = vanilla says ct is NOT visible (=> consult was fed different view inputs = extraction bug).
std::atomic<uint64_t> g_c_newer_vsees{0};
std::atomic<uint64_t> g_c_newer_vhides{0};
std::atomic<int> g_c_newer_printed{0};   // bound the per-case stderr dump

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
// D-5 C3-b: 1-in-N walk-audit knobs for mode-1 serve-only. g_audit_n = ACCEL_AUDIT_N (default 1024; an
// explicit 0 / unparsable refuses mode-1 at init). g_audit_hit_ctr is the per-HIT sample clock (mode-1
// HITs); g_audited counts the HITs actually audited (~ hit / N). Touched by many reader threads -> atomic.
int g_audit_n = 1024;
std::atomic<uint64_t> g_audit_hit_ctr{0};
std::atomic<uint64_t> g_audited{0};
// D-5 C3 (diagnostic / operational toggle): the mode-1 gc_generation 2nd firewall is ON by default. Set
// ACCEL_GEN_GATE=0 to disable it even in mode-1 (consult does not enforce the gen-recheck) -- used to isolate
// whether a held-reader HIT collapse comes from the gen-gate (race) vs a real contiguity break / chain sever.
bool g_gen_gate_on = true;
// D-5 FG-α: ACCEL_CONSULT_FG=1 turns on consult cooperative reclaim (consult helps prune dead non-head epochs
// it scans, retire stays BG-only) so the integration read path keeps chains short. Needs ACCEL_GC=1 (the GC
// must publish a deadzone for consult to act). Default off; a measurement/ablation knob.
bool g_consult_fg = false;
// D-5 GC-tuning: ACCEL_DRAIN_CAP = max orphan epochs the dummy drain reclaims per GC cycle (0 = unlimited).
// Spreads the small-BP reclaim storm over many cycles so a held reader's chain is severed gradually -> the ⑥
// payoff is stabilized at the cost of a transiently larger working set. Read once at init.
uint64_t g_drain_cap = 0;
// ⓠ3 (Phase 2): ACCEL_TAIL_ONLY=1 forces the GC to prune ONLY the below-floor tail (zone 0), skipping the
// in-middle holes between active-view cuts -- faithfully modeling InnoDB-style tail purge, which an LLT
// stalls by pinning the floor. This is the apples-to-apples baseline for the deadzone (default off): the
// SAME real-InnoDB run, cache in tail-only mode, should track InnoDB's History List Length, while deadzone
// mode reclaims the in-middle gaps. Default off = full deadzone (in-middle reclaim).
bool g_tail_only = false;

// D-5 5-1b: leaf-domain ACTIVE READ-VIEW REGISTRY (collection signal B). InnoDB pushes each view's
// {low_limit_id, up_limit_id} here on view_open (piggybacking the trx_sys mutex it already holds) and
// clears it on view_close; the BG GC (D-5, still OFF) will read a wait-free snapshot to build the dead
// zone. ACCEL_PUBLISH=0 disables the push so 5-1b can measure its OLTP cost against a baseline.
// D-5 ⑤a-2 step 5 (review must-fix 3): size the registry pool well above realistic server concurrency so
// the overflow path is essentially never taken. The overflow floor is monotone-down and (by design)
// never raised while any overflow view is live -- over-protect is memory-safe, under-protect is the only
// danger and monotone-down never does it -- but a fully-drained burst leaves a stale-low floor that a
// later burst would inherit (memory-loose, not wrong). design-D5-gc §6 sanctions sizing the pool as the
// fix (vs a racy single-scalar reset). Slots are leased per thread and released at thread exit, so live
// slots track CONCURRENT leasing threads (connections + bg workers), not distinct-threads-ever; 4096
// covers typical max_connections + headroom. (If a deployment sets max_connections > 4096, overflow
// safely engages = over-protect.) Pool cost is ~256KB (64B/slot), negligible.
using ViewReg = mvcc::ActiveViewRegistry<4096>;
ViewReg g_view_reg;
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
  // ⓣ13: one-shot ring-overflow WARNING, emitted OFF-LATCH by the drainer (NEVER fprintf under the page
  // latch). A drop means the affected key consult-MISSes to the vanilla walk until the drainer catches up
  // (correct, just unaccelerated); this makes the otherwise-silent degrade observable + attributable. The
  // double-check (load then exchange) keeps the steady state to a single relaxed load once warned.
  if (g_dropped.load(std::memory_order_relaxed) != 0 &&
      !g_drop_warned.load(std::memory_order_relaxed) &&
      g_drop_warned.exchange(true, std::memory_order_relaxed) == false) {
    std::fprintf(stderr,
                 "[accel] WARNING: ring overflowed (drop-on-full) -- first table_id=%llu; affected keys "
                 "consult-MISS to the vanilla walk until the drainer catches up (increase the ring size or "
                 "reduce the write burst). dropped so far=%llu\n",
                 (unsigned long long)g_first_drop_table.load(std::memory_order_relaxed),
                 (unsigned long long)g_dropped.load(std::memory_order_relaxed));
  }
  // pk-breadth bucket + ⓠ3 first-touch representative-key capture. The drainer is the SOLE writer, so the
  // plain load/store is race-free between drainers; the rep is written BEFORE the bit is published (release)
  // so a reader that sees the bit set also sees the rep.
  {
    unsigned b = r.pk_hash & 1023u;
    if (g_pk_seen[b].load(std::memory_order_relaxed) == 0u) {
      g_key_rep_table[b].store(r.table_id, std::memory_order_relaxed);
      g_key_rep_pk[b].store(r.pk_hash, std::memory_order_relaxed);
      g_pk_seen[b].store(1u, std::memory_order_release);
    }
  }
  // D-5 ⑤a-2 step 3: capture the epoch base from the first version's trx id (idempotent set-once; the
  // drainer is the only caller). Numbers epochs relative to the InnoDB id space so versions land in the
  // bucket ring and the amortized windowed sweep engages instead of everything overflowing to the drain.
  if (g_accel) g_accel->set_epoch_base(r.old_trx_id);
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

// D-5 ⑤a-2 step 3: integration deadzone-GC driver loop. Drives the GC off the pushed InnoDB clock
// (g_clock = max view begin id) + the active-view registry (g_view_reg) -- NOT the standalone trx
// manager, which the off-latch drainer never advances (M4). The clock is NORMALIZED to the first
// inserted version's trx id (g_accel->epoch_base()): subtracting the base gives "ids since we started",
// so the catch-up from 0 is bounded by run length, NOT by InnoDB's absolute id history -- that kills
// the boot allocation storm (must-fix 2) WITHOUT a seed-skip, so epochs start near 0, land in the
// bucket ring, and the amortized windowed sweep actually engages (step 3). PERIOD mirrors the standalone
// cadence (advance the epoch window by EPOCH_TABLE_SIZE/4 per cycle) = EPOCH_SIZE*EPOCH_TABLE_SIZE/4.
// We pass the ABSOLUTE boundary (nb + base) to the cycle; run_gc_cycle_from_cuts re-normalizes via the
// same epoch_of that insert uses, so GC's swap window and the inserts' buckets line up. This thread is
// the SINGLE GC actor (the standalone BG GC stays off). Gated on ACCEL_GC (g_gc_enabled): off = no-op
// sleeper (step-1 behavior). It re-checks g_gc_stop inside the catch-up loop so the join never hangs.
void gc_loop() {
  // DERIVED from the common.h sizing constants (not hardcoded 2500) so a change to EPOCH_SIZE /
  // EPOCH_TABLE_SIZE cannot silently diverge from this GC driver's window-advance cadence.
  constexpr uint64_t PERIOD = (uint64_t)EPOCH_SIZE * EPOCH_TABLE_SIZE / 4;
  uint64_t last_norm_boundary = 0;
  uint64_t cycles = 0;
  std::vector<mvcc::ViewCut> cuts;
  uint64_t floor = ViewReg::NO_FLOOR;
  while (!g_gc_stop.load(std::memory_order_acquire)) {
    if (!g_gc_enabled || g_accel == nullptr) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      continue;
    }
    uint64_t base = g_accel->epoch_base();                   // 0 until the drainer's first insert
    uint64_t clk = g_clock.load(std::memory_order_relaxed);  // absolute pushed InnoDB clock
    if (base == 0 || clk <= base + PERIOD) {                 // no insert yet, or < one period past base
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      continue;
    }
    uint64_t norm = clk - base;                              // ids since we started (bounded by run length)
    uint64_t norm_boundary = (norm / PERIOD) * PERIOD;
    if (norm_boundary > last_norm_boundary) {
      for (uint64_t nb = last_norm_boundary + PERIOD; nb <= norm_boundary; nb += PERIOD) {
        if (g_gc_stop.load(std::memory_order_acquire)) break;   // prompt stop -> join never hangs
        g_view_reg.snapshot(cuts, floor);                       // fresh superset snapshot per cycle
        g_accel->run_gc_cycle_from_cuts(nb + base, cuts, floor);  // absolute boundary; epoch_of re-normalizes
        ++cycles;
      }
      last_norm_boundary = norm_boundary;
      if (cycles && (cycles % 5 == 0)) {
        std::fprintf(stderr,
            "[accel] gc: cycles=%llu retired{windowed=%llu dummy=%llu} live_buckets=%zu views=%zu norm_clock=%llu\n",
            (unsigned long long)cycles,
            (unsigned long long)g_accel->epochs_retired_windowed(),
            (unsigned long long)g_accel->epochs_retired_dummy(),
            g_accel->long_live_size(), cuts.size(), (unsigned long long)norm);
      }
    } else {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }
}

// ⓠ3 (Phase 2): retention reporter loop. Periodically (ACCEL_RETENTION_MS) logs the cache's retained
// version volume and a hot key's chain depth WHILE a held LLT is still pinning them -- the only point
// the deadzone's in-middle reclaim can be compared against InnoDB's tail-blocked retention. Read-only:
// chain_length_guarded holds a per-traversal EBR Guard (safe to walk a live chain under concurrent GC),
// and the aggregates are plain counter reads. Started only when ACCEL_RETENTION_MS > 0; stopped+joined
// in accel_shutdown BEFORE delete g_accel (it dereferences g_accel).
void retention_loop() {
  using clock = std::chrono::steady_clock;
  const unsigned period = g_retention_ms ? g_retention_ms : 1000;
  while (!g_rep_stop.load(std::memory_order_acquire)) {
    std::this_thread::sleep_for(std::chrono::milliseconds(period));
    if (g_accel == nullptr || !g_ready.load(std::memory_order_acquire)) continue;
    // Sample EVERY occupied pk bucket's representative key (unbiased over hot+cold), each chain walk
    // bounded to g_retention_cap so a tail-only run's huge chains cannot steal enough CPU to throttle the
    // workload. max = worst-case chain a reader might walk; capped = how many keys saturated (the long-chain
    // population); sampled_sum = lower-bound retained over the rep keys (the true total is live).
    const size_t cap = g_retention_cap;
    size_t lens[1024];
    unsigned m = 0;
    size_t mx = 0, n_capped = 0, ssum = 0;
    for (unsigned b = 0; b < 1024; ++b) {
      if (g_pk_seen[b].load(std::memory_order_acquire) == 0u) continue;
      uint64_t kt = g_key_rep_table[b].load(std::memory_order_relaxed);
      uint64_t kpk = g_key_rep_pk[b].load(std::memory_order_relaxed);
      if (kt == 0 && kpk == 0) continue;
      size_t cl = g_accel->chain_length_guarded_capped(kt, kpk, cap);
      lens[m++] = cl;
      if (cl > mx) mx = cl;
      if (cap != 0 && cl >= cap) ++n_capped;
      ssum += cl;
    }
    size_t p50 = 0;
    if (m > 0) { std::sort(lens, lens + m); p50 = lens[m / 2]; }
    uint64_t drained = g_drained.load(std::memory_order_relaxed);
    uint64_t ent_ret = g_accel->entries_retired();   // VERSIONS freed via GC retire
    uint64_t dropped = g_accel->versions_dropped();   // ⓝ9: versions NOT cached (table full) -> freed immediately
    long tms = (long)std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - g_t0).count();
    // live_versions = drained - entries_retired - versions_dropped: the cache's retained version count,
    // comparable to InnoDB's History List Length. Subtracting dropped keeps it honest when the table is full
    // (uncached fallback traffic is in `drained` but its node was freed immediately). (max/p50 = EPOCH depth.)
    std::fprintf(stderr,
                 "[accel] retention: t_ms=%ld max=%zu p50=%zu capped=%zu keys=%u sampled_sum=%zu "
                 "drained=%llu entries_retired=%llu dropped=%llu live_versions=%lld headers=%llu long_live=%zu\n",
                 tms, mx, p50, n_capped, m, ssum, (unsigned long long)drained,
                 (unsigned long long)ent_ret, (unsigned long long)dropped,
                 (long long)((long long)drained - (long long)ent_ret - (long long)dropped),
                 (unsigned long long)g_accel->headers_created(), g_accel->long_live_size());
  }
}
}  // namespace

void accel_init() noexcept {
  bool expected = false;
  if (!g_started.compare_exchange_strong(expected, true)) return;  // already inited
  g_stop.store(false, std::memory_order_relaxed);
  g_gc_stop.store(false, std::memory_order_relaxed);
  g_rep_stop.store(false, std::memory_order_relaxed);
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
  // D-5 C3-b: mode-1 (serve-only) MUST ship with the walk-audit tripwire (its only in-run self-check).
  // Read ACCEL_AUDIT_N (default 1024); if it is explicitly set to 0 or an unparsable value, REFUSE mode-1
  // -- downgrade to shadow -- rather than run the perf path with the tripwire silently disabled.
  if (g_authoritative_mode == 1) {
    if (const char *an = std::getenv("ACCEL_AUDIT_N")) {
      long v = std::strtol(an, nullptr, 10);
      g_audit_n = (v > 0) ? (int)v : 0;
    }
    if (g_audit_n <= 0) {
      std::fprintf(stderr, "[accel] REFUSING mode-1: ACCEL_AUDIT_N must be > 0 (walk-audit is mandatory); "
                           "downgrading to shadow (mode 0)\n");
      g_authoritative_mode = 0;
    }
  }
  if (const char *gg = std::getenv("ACCEL_GEN_GATE")) {
    if (gg[0] == '0') g_gen_gate_on = false;   // D-5 C3 diagnostic: disable the gen-gate even in mode-1
  }
  if (const char *cf = std::getenv("ACCEL_CONSULT_FG")) {
    if (cf[0] == '1') g_consult_fg = true;     // D-5 FG-α: consult cooperative reclaim (needs ACCEL_GC=1)
  }
  if (const char *dc = std::getenv("ACCEL_DRAIN_CAP")) {
    g_drain_cap = std::strtoull(dc, nullptr, 10);  // D-5 GC-tuning: dummy-drain per-cycle reclaim cap (0=off)
  }
  if (const char *pv = std::getenv("ACCEL_PUBLISH")) {
    if (pv[0] == '0') g_publish_views = false;         // baseline: OLTP without the view-registry push
  }
  if (const char *gc = std::getenv("ACCEL_GC")) {
    if (gc[0] == '1') g_gc_enabled = true;             // D-5 ⑤a-2: drive the deadzone GC (pushed clock + registry)
  }
  if (const char *rm = std::getenv("ACCEL_RETENTION_MS")) {
    long v = std::strtol(rm, nullptr, 10);
    if (v > 0) g_retention_ms = (unsigned)v;           // ⓠ3: held-LLT retention reporter cadence (0 = off)
  }
  if (const char *rc = std::getenv("ACCEL_RETENTION_CAP")) {
    long v = std::strtol(rc, nullptr, 10);
    if (v >= 0) g_retention_cap = (unsigned)v;          // ⓠ3: per-key chain-walk cap (0 = unbounded)
  }
  if (const char *to = std::getenv("ACCEL_TAIL_ONLY")) {
    if (to[0] == '1') g_tail_only = true;              // ⓠ3: tail-only GC baseline (models InnoDB purge)
  }
  try {
    g_accel = new mvcc::Accelerate_mvcc(0, 16);  // dynamic keys, 64k-bin cuckoo, BG GC NOT started
    g_accel->set_consult_fg_reclaim(g_consult_fg);  // D-5 FG-α (default off)
    g_accel->set_dummy_drain_cap(g_drain_cap);      // D-5 GC-tuning (0 = unlimited)
    g_accel->set_gc_tail_only(g_tail_only);         // ⓠ3: tail-only baseline (default off = deadzone)
    if (g_no_full_pk) g_accel->set_allow_no_full_pk(true);  // test negative control opt-in (ACCEL_NO_FULL_PK)
    g_drainer = std::thread(drain_loop);
    g_gc = std::thread(gc_loop);  // D-5 ⑤a-2: integration GC driver (cuts-driven deadzone sweep when ACCEL_GC=1)
    g_t0 = std::chrono::steady_clock::now();           // ⓠ3: reporter t_ms origin (set before it starts)
    if (g_retention_ms) g_reporter = std::thread(retention_loop);  // ⓠ3: read-only retention reporter
  } catch (...) {
    // unwind in the same order accel_shutdown uses: stop+join reporter, GC, then the drainer, then drop accel.
    g_rep_stop.store(true, std::memory_order_release);
    if (g_reporter.joinable()) g_reporter.join();
    g_gc_stop.store(true, std::memory_order_release);
    if (g_gc.joinable()) g_gc.join();
    g_stop.store(true, std::memory_order_release);
    if (g_drainer.joinable()) g_drainer.join();
    delete g_accel;
    g_accel = nullptr;
    g_started.store(false, std::memory_order_relaxed);
    return;
  }
  g_ready.store(true, std::memory_order_release);
  std::fprintf(stderr, "[accel] init: drainer started, accelerator constructed (gc=%d tail_only=%d retention_ms=%u)\n",
               g_gc_enabled ? 1 : 0, g_tail_only ? 1 : 0, g_retention_ms);
}

void accel_shutdown() noexcept {
  if (!g_started.load(std::memory_order_acquire)) return;
  g_ready.store(false, std::memory_order_release);  // hook + consult stop entering the live window
  // ⓠ3: quiesce the read-only retention reporter FIRST -- it dereferences g_accel, so it must stop
  // before the GC/drainer teardown and the delete below. No-op if it was never started.
  g_rep_stop.store(true, std::memory_order_release);
  if (g_reporter.joinable()) g_reporter.join();
  // D-5 ⑤a-2 (review must-fix 1): stop the GC driver FIRST and join it, BEFORE the drainer and BEFORE
  // delete g_accel. The GC actor mutates g_accel's epoch_table (reclaim/sweep) and is NOT reaped by
  // g_accel's dtor (it is the integration driver, not the object-owned standalone BG GC), so it must
  // be quiesced here or it would run on a partially-freed accelerator.
  g_gc_stop.store(true, std::memory_order_release);
  if (g_gc.joinable()) g_gc.join();
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
               "ineligible=%llu gcrace=%llu} | construct_ok=%llu construct_BAD=%llu | auth_mode=%d served=%llu gen_gate=%d\n",
               (unsigned long long)g_c_calls.load(), (unsigned long long)g_c_hit.load(),
               (unsigned long long)g_c_miss_absent.load(), (unsigned long long)g_c_miss_novisible.load(),
               (unsigned long long)g_c_miss_noncontig.load(), (unsigned long long)g_c_miss_ineligible.load(),
               (unsigned long long)g_c_miss_gcrace.load(),
               (unsigned long long)g_c_construct_ok.load(), (unsigned long long)g_c_construct_bad.load(),
               g_authoritative_mode, (unsigned long long)g_c_serve.load(), g_gen_gate_on ? 1 : 0);
  // D-5 C3-b: walk-audit evidence. In mode-1, construct_ok+construct_bad == audited (only audited HITs
  // run the compare); construct_bad is an AUDIT FAILURE (a served-equivalent cache HIT that did not match
  // vanilla). The gate: audited > 0 (sampling actually ran) AND audited ~= mode1_hits / audit_n AND
  // construct_bad == 0. mode1_hits is the sample clock (every mode-1 HIT); served counts non-audited HITs.
  std::fprintf(stderr, "[accel] audit: mode=%d audit_n=%d mode1_hits=%llu audited=%llu (mode-1: ok+bad==audited, bad==0)\n",
               g_authoritative_mode, g_audit_n,
               (unsigned long long)g_audit_hit_ctr.load(), (unsigned long long)g_audited.load());
  // D-5 C3-c diag: split noncontig into head-writer-gate (drainer lag) vs chase-break (GC reclaimed an
  // intermediate version the lineage walk needs = GC chain-sever). Attributes the ⑥ collapse.
  std::fprintf(stderr, "[accel] noncontig split: head_writer_gate=%llu (cache head behind live row) "
               "chase_break=%llu (GC severed a mid-chain link)\n",
               (unsigned long long)(g_accel ? g_accel->nc_headwriter() : 0),
               (unsigned long long)(g_accel ? g_accel->nc_chasebreak() : 0));
  // D-5 5-1b: view-registry push evidence. published/unpublished are the per-view_open/close push
  // counts (not per row); live_snapshot is what the GC would see now (~0 at shutdown, all closed).
  std::vector<mvcc::ViewCut> vcut; uint64_t vfloor;
  g_view_reg.snapshot(vcut, vfloor);
  std::fprintf(stderr, "[accel] view-registry: open_calls=%llu published=%llu unpublished=%llu publish_on=%d "
               "live_snapshot=%zu floor=%s clock=%llu\n",
               (unsigned long long)g_view_open_calls.load(),
               (unsigned long long)g_view_published.load(), (unsigned long long)g_view_unpublished.load(),
               g_publish_views ? 1 : 0, vcut.size(),
               vfloor == ViewReg::NO_FLOOR ? "none" : "set",
               (unsigned long long)g_clock.load());
  std::fprintf(stderr, "[accel] construct_BAD detail: trx_same=%llu (right version, bytes differ) "
               "trx_diff=%llu (WRONG version: older=%llu [cache behind] newer=%llu [visibility])\n",
               (unsigned long long)g_c_bad_trxsame.load(), (unsigned long long)g_c_bad_trxdiff.load(),
               (unsigned long long)g_c_bad_older.load(), (unsigned long long)g_c_bad_newer.load());
  // D-5 diag6: NEWER root-cause split. vsees>0 dominant => cross-generation cache (ct visible but not on
  // vanilla's chain); vhides>0 dominant => view-input extraction mismatch (consult fed different limits).
  std::fprintf(stderr, "[accel] newer split: vanilla_sees=%llu (cross-generation: ct visible, off vanilla's chain) "
               "vanilla_hides=%llu (input mismatch: consult got different view limits)\n",
               (unsigned long long)g_c_newer_vsees.load(), (unsigned long long)g_c_newer_vhides.load());
  // D-5 ⑤a-2: GC driver evidence -- did it actually sweep, and via which path? A green construct_BAD=0
  // with retired{total=0} would mean GC never ran (gate hollow); all-dummy means the windowed/unlink
  // path was unexercised (review critic M-D-ii). live_buckets is the GC's long-lived-bucket vector.
  std::fprintf(stderr, "[accel] gc: enabled=%d retired{total=%llu windowed=%llu dummy=%llu} live_buckets=%zu clock=%llu\n",
               g_gc_enabled ? 1 : 0,
               (unsigned long long)(g_accel ? g_accel->epochs_retired() : 0),
               (unsigned long long)(g_accel ? g_accel->epochs_retired_windowed() : 0),
               (unsigned long long)(g_accel ? g_accel->epochs_retired_dummy() : 0),
               g_accel ? g_accel->long_live_size() : 0, (unsigned long long)g_clock.load());
  // D-5 FG-α: consult cooperative-reclaim evidence. consult_fg=1 means consult helped prune; coop_dead_seen is
  // the count of dead epochs consult marked/spliced (the FG-alpha work). 0 with consult_fg=1 => never engaged.
  std::fprintf(stderr, "[accel] fg-alpha: consult_fg=%d coop_dead_seen=%llu | drain_cap=%llu dummy_pending=%zu\n",
               g_consult_fg ? 1 : 0, (unsigned long long)(g_accel ? g_accel->coop_dead_seen() : 0),
               (unsigned long long)g_drain_cap, g_accel ? g_accel->dummy_pending() : 0);
  delete g_accel;  // GC driver + drainer already stopped+joined above -> sole owner; the object-owned
                   // standalone BG GC was never started, so the dtor's stop_background_gc is a no-op.
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
  if (g_ring.enqueue(r)) {
    g_enq.fetch_add(1, std::memory_order_relaxed);
  } else {
    g_dropped.fetch_add(1, std::memory_order_relaxed);  // full -> drop, never block the latch
    // ⓣ13: record the first overflowing table (one cheap CAS under the latch -- no alloc/lock/InnoDB call).
    // The drainer emits the one-shot WARNING off-latch (consume()); under the latch we only stash attribution.
    uint64_t exp = ~uint64_t(0);
    g_first_drop_table.compare_exchange_strong(exp, table_id, std::memory_order_relaxed);
  }
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
                         /*require_full_pk=*/!g_no_full_pk, sch, &outextra,
                         // D-5 C3: enforce the gc_generation 2nd firewall ONLY in mode-1 (serve-only),
                         // which has no per-row walk-compare; shadow/mode-2 leave it off (their compare is
                         // the 2nd firewall, and forcing the gate there would only convert hot-key HITs to
                         // MISSes on keys GC is actively retiring -- perf loss for zero safety gain). The
                         // ACCEL_GEN_GATE=0 toggle disables it even in mode-1 (diagnostic / isolation).
                         /*enforce_gc_gen=*/(g_authoritative_mode == 1 && g_gen_gate_on));
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
    case CO::MISS_GCRACE:     g_c_miss_gcrace.fetch_add(1, std::memory_order_relaxed);     return 5;
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

// D-5 C3-b: 1-in-N walk-audit decision for a mode-1 consult HIT. Advances the per-HIT sample clock and
// returns 1 for every N-th mode-1 HIT (= audit this one: don't skip the walk, run the byte-compare, serve
// vanilla). 0 otherwise. Cheap relaxed atomics: the sample is statistical, not a correctness ordering.
int accel_audit_should() noexcept {
  if (g_authoritative_mode != 1 || g_audit_n <= 0) return 0;
  uint64_t n = g_audit_hit_ctr.fetch_add(1, std::memory_order_relaxed) + 1;
  if ((n % (uint64_t)g_audit_n) == 0) {
    g_audited.fetch_add(1, std::memory_order_relaxed);
    return 1;
  }
  return 0;
}

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
// D-5 diag: for a wrong-version case, was the served version OLDER (older=1) or NEWER (older=0)?
void accel_note_bad_dir(int older) noexcept {
  (older ? g_c_bad_older : g_c_bad_newer).fetch_add(1, std::memory_order_relaxed);
}
// D-5 diag6: split the NEWER set by whether the LIVE view sees ct, and dump the first cases.
void accel_note_newer_detail(uint64_t ct, uint64_t vt, uint64_t up, uint64_t low,
                             uint64_t creator, int ct_in_mids, int vanilla_sees) noexcept {
  (vanilla_sees ? g_c_newer_vsees : g_c_newer_vhides).fetch_add(1, std::memory_order_relaxed);
  int n = g_c_newer_printed.fetch_add(1, std::memory_order_relaxed);
  if (n < 40) {
    std::fprintf(stderr,
                 "[accel] newer#%d ct=%llu vt=%llu up=%llu low=%llu creator=%llu ct_in_mids=%d vanilla_sees=%d\n",
                 n, (unsigned long long)ct, (unsigned long long)vt, (unsigned long long)up,
                 (unsigned long long)low, (unsigned long long)creator, ct_in_mids, vanilla_sees);
  }
}
void accel_publish_view_close() noexcept {
  if (!g_ready.load(std::memory_order_acquire) || !g_publish_views) return;
  g_view_reg.unpublish();
  g_view_unpublished.fetch_add(1, std::memory_order_relaxed);
}
