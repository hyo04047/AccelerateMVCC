// Licensed under the MIT license.
#pragma once
//
// D-5 5-1a/5-1b: leaf-domain lock-free ACTIVE READ-VIEW REGISTRY (collection signal B).
//
// InnoDB pushes each read-view here on view_open -- piggybacking the trx_sys mutex it already
// holds to splice the view into its own list -- and clears it lazily on view_close. The
// background GC reads a wait-free snapshot to build the dead zone.
//
// Each view contributes a PAIR {begin, up}, NOT just a begin-cut (design-D5-gc.md §3.1):
//   begin = the view's low_limit_id  (high-water / begin ordering; the dead-zone sort key)
//   up    = the view's up_limit_id   (low-water / smallest active id)
// The dead zone uses the NEXT view's `up` as a hole's right edge -- always <= the exact
// active-id-set edge, so the hole is a subset of the standalone hole => conservative
// (under-reclaim) => safe, and equal in the common case. Pushing the two scalars instead of the
// full active id-set keeps publish constant-size. A single begin-cut alone would over-prune (a
// version whose superseding txn is still active in the next view is one that view must see).
//
// The registry is a conservative SUPERSET of the truly-active read-views:
//   * ADD-on-open is RELIABLE and ordered (the publish happens-before the view is usable, under
//     the InnoDB mutex), so no live view is ever omitted from a later snapshot.
//   * DROP-on-close is BEST-EFFORT/lazy -- a missed clear just over-protects (harmless extra).
//   * SLOT-POOL EXHAUSTION (> MAX_VIEWS concurrently-live publishing threads) does NOT drop a
//     view (that would UNDER-approximate the active set -> interior over-prune -> wrong
//     authoritative serve); instead it lowers a conservative FLOOR: while any overflow view is
//     live the GC keeps everything >= floor (no holes above it).
// Adding/keeping extra views only costs UNDER-reclaim (a looser memory bound), never a wrong
// result. See docs/design-D5-gc.md §2.1 (superset theorem) and §3 (signal B).
//
// The {begin, up} pair must be read as a CONSISTENT pair (a torn {new begin, stale larger up}
// would widen a hole -> over-prune), so each slot publishes the pair under a tiny per-slot
// seqlock: a single writer (the slot's leasing thread) and the GC as the sole reader.
//
// Leaf domain: includes no InnoDB header and never calls back into InnoDB.

#include <atomic>
#include <array>
#include <vector>
#include <algorithm>
#include <cstdint>

namespace mvcc {

// One active read-view's contribution to the dead zone: begin (low_limit_id) + up (up_limit_id).
struct ViewCut {
    uint64_t begin;
    uint64_t up;
};

template <unsigned MAX_VIEWS = 256>
class ActiveViewRegistry {
public:
    static constexpr uint64_t EMPTY = 0;            // empty slot sentinel (view begin ids are nonzero)
    static constexpr uint64_t NO_FLOOR = ~uint64_t(0);
    static constexpr unsigned SLOT_NONE = ~0u;

    ActiveViewRegistry() = default;
    ActiveViewRegistry(const ActiveViewRegistry &) = delete;
    ActiveViewRegistry &operator=(const ActiveViewRegistry &) = delete;

    // Publish this thread's active read-view (begin = low_limit_id, up = up_limit_id). Called on
    // view_open under the InnoDB mutex, so it is ordered before the view becomes usable. begin
    // MUST be nonzero (it identifies a live view; begin==0 would read as an empty slot).
    void publish(uint64_t begin, uint64_t up) {
        unsigned slot = my_slot();
        if (slot != SLOT_NONE) {
            write_slot(slots_[slot], begin, up);
        } else {
            overflow_enter(begin);   // conservative: protect everything >= begin
        }
    }

    // Clear this thread's published view. Called on view_close. Best-effort (lazy).
    void unpublish() {
        unsigned slot = my_slot();
        if (slot != SLOT_NONE) {
            write_slot(slots_[slot], EMPTY, 0);
        } else {
            overflow_exit();
        }
    }

    // Wait-free snapshot for the GC: collect all currently-published {begin, up} pairs (sorted
    // ascending by begin) into out, and return the conservative overflow floor (NO_FLOOR if
    // none). The returned set together with the floor is a SUPERSET of the truly-active views:
    // while floor < NO_FLOOR the GC must keep everything >= floor (no holes above it).
    void snapshot(std::vector<ViewCut> &out, uint64_t &overflow_floor_out) const {
        out.clear();
        for (auto &s : slots_) {
            uint64_t begin, up;
            read_slot(s, begin, up);
            if (begin != EMPTY) out.push_back(ViewCut{begin, up});
        }
        std::sort(out.begin(), out.end(),
                  [](const ViewCut &a, const ViewCut &b) { return a.begin < b.begin; });
        overflow_floor_out = (overflow_count_.load(std::memory_order_acquire) > 0)
                             ? overflow_floor_.load(std::memory_order_acquire) : NO_FLOOR;
    }

private:
    // Per-slot seqlock-protected {begin, up}. seq even = stable, odd = a write in progress.
    struct Slot {
        std::atomic<uint64_t> seq{0};
        std::atomic<uint64_t> begin{EMPTY};
        std::atomic<uint64_t> up{0};
    };

    // Single writer per slot (the leasing thread): bump to odd, store the pair, bump to even.
    static void write_slot(Slot &s, uint64_t begin, uint64_t up) {
        uint64_t s0 = s.seq.load(std::memory_order_relaxed);
        s.seq.store(s0 + 1, std::memory_order_release);     // odd: write in progress
        s.begin.store(begin, std::memory_order_release);
        s.up.store(up, std::memory_order_release);
        s.seq.store(s0 + 2, std::memory_order_release);     // even: stable
    }

    // Reader (GC): retry until it observes a stable, untorn pair. Terminates because each slot
    // has a single writer whose critical section is three stores. All data is atomic -> no race.
    static void read_slot(const Slot &s, uint64_t &begin, uint64_t &up) {
        for (;;) {
            uint64_t s1 = s.seq.load(std::memory_order_acquire);
            if (s1 & 1) continue;                            // writer mid-update -> retry
            begin = s.begin.load(std::memory_order_acquire);
            up = s.up.load(std::memory_order_acquire);
            if (s.seq.load(std::memory_order_acquire) == s1) return;  // no write straddled the read
        }
    }

    // An unslotted (overflow) view lowers the floor to its begin and bumps the count; the GC
    // over-protects [floor, inf) while count>0. Floor monotone-down, not reset here (mirrors the
    // EBR overflow pin: always safe, only loosens the bound under SUSTAINED >MAX_VIEWS load -- a
    // per-live-overflow reset is a deferred memory optimization, design-D5-gc.md §6).
    // snapshot() ignores the floor once count returns to 0.
    void overflow_enter(uint64_t begin) {
        uint64_t cur = overflow_floor_.load(std::memory_order_acquire);
        while ((cur == NO_FLOOR || begin < cur) &&
               !overflow_floor_.compare_exchange_weak(cur, begin,
                                                      std::memory_order_acq_rel,
                                                      std::memory_order_acquire)) {
            // cur reloaded by the failed CAS; retry until floor <= begin.
        }
        overflow_count_.fetch_add(1, std::memory_order_acq_rel);
    }
    void overflow_exit() { overflow_count_.fetch_sub(1, std::memory_order_acq_rel); }

    // --- per-thread slot LEASE (mirrors EpochReclaimer): a publishing thread leases one slot on
    // first publish and frees it at thread exit, so slots are bounded by concurrently-live
    // publishing threads. Pool is per-instantiation (the template arg). A thread holds at most
    // one active read-view at a time, so one slot per thread suffices; between transactions the
    // slot's begin is EMPTY (skipped by snapshot).
    static std::array<std::atomic<bool>, MAX_VIEWS> &slot_taken() {
        static std::array<std::atomic<bool>, MAX_VIEWS> taken{};
        return taken;
    }
    static unsigned acquire_slot() {
        auto &taken = slot_taken();
        for (unsigned i = 0; i < MAX_VIEWS; ++i) {
            bool expected = false;
            if (taken[i].compare_exchange_strong(expected, true,
                                                 std::memory_order_acquire,
                                                 std::memory_order_relaxed))
                return i;
        }
        return SLOT_NONE;   // pool exhausted -> caller falls back to the overflow floor
    }
    static void release_slot(unsigned i) {
        if (i == SLOT_NONE) return;
        std::atomic_thread_fence(std::memory_order_seq_cst);
        slot_taken()[i].store(false, std::memory_order_release);
    }
    struct SlotLease {
        unsigned slot;
        SlotLease() : slot(acquire_slot()) {}
        ~SlotLease() { release_slot(slot); }
        SlotLease(const SlotLease &) = delete;
        SlotLease &operator=(const SlotLease &) = delete;
    };
    static unsigned my_slot() {
        thread_local SlotLease lease;   // leased on first publish, freed at thread exit
        return lease.slot;
    }

    std::array<Slot, MAX_VIEWS> slots_{};
    std::atomic<uint64_t> overflow_floor_{NO_FLOOR};
    std::atomic<unsigned> overflow_count_{0};
};

} // namespace mvcc
