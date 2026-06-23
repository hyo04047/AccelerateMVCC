// Licensed under the MIT license.
#pragma once
//
// D-5 5-1a: leaf-domain lock-free ACTIVE READ-VIEW REGISTRY (collection signal B).
//
// InnoDB pushes each read-view's begin id here on view_open -- piggybacking the trx_sys
// mutex it already holds to splice the view into its own list -- and clears it lazily on
// view_close. The background GC reads a wait-free snapshot to build the dead zone.
//
// The registry is a conservative SUPERSET of the truly-active read-views:
//   * ADD-on-open is RELIABLE and ordered: the publish store happens-before the view is
//     usable (the caller holds the InnoDB mutex while publishing), so no live view is ever
//     omitted from a subsequent snapshot.
//   * DROP-on-close is BEST-EFFORT / lazy: a missed or late clear just leaves a stale entry,
//     which only over-protects (harmless extra).
//   * SLOT-POOL EXHAUSTION (> MAX_VIEWS concurrently-live publishing threads) does NOT drop a
//     view -- that would UNDER-approximate the active set, the one unsafe direction (it would
//     let the GC over-prune a strictly-interior version -> wrong authoritative serve). Instead
//     an unslotted view lowers a conservative FLOOR: while any overflow view is live the GC
//     must treat everything from the floor up as active (no holes above it).
// Adding/keeping extra views only costs UNDER-reclaim (a looser memory bound), never a wrong
// result. See docs/design-D5-gc.md §2.1 (superset theorem) and §3 (signal B).
//
// Leaf domain: includes no InnoDB header and never calls back into InnoDB.

#include <atomic>
#include <array>
#include <vector>
#include <algorithm>
#include <cstdint>

namespace mvcc {

template <unsigned MAX_VIEWS = 256>
class ActiveViewRegistry {
public:
    static constexpr uint64_t EMPTY = 0;            // empty slot sentinel (view begin ids are nonzero)
    static constexpr uint64_t NO_FLOOR = ~uint64_t(0);
    static constexpr unsigned SLOT_NONE = ~0u;

    ActiveViewRegistry() {
        for (auto &s : slots_) s.store(EMPTY, std::memory_order_relaxed);
    }
    ActiveViewRegistry(const ActiveViewRegistry &) = delete;
    ActiveViewRegistry &operator=(const ActiveViewRegistry &) = delete;

    // Publish this thread's active read-view begin id. Called on view_open under the InnoDB
    // mutex, so the store is ordered before the view becomes usable. begin_id MUST be nonzero.
    void publish(uint64_t begin_id) {
        unsigned slot = my_slot();
        if (slot != SLOT_NONE) {
            slots_[slot].store(begin_id, std::memory_order_release);
        } else {
            overflow_enter(begin_id);   // conservative: protect everything >= begin_id
        }
    }

    // Clear this thread's published view. Called on view_close. Best-effort (lazy): a missed
    // clear leaves a stale entry = harmless over-protection.
    void unpublish() {
        unsigned slot = my_slot();
        if (slot != SLOT_NONE) {
            slots_[slot].store(EMPTY, std::memory_order_release);
        } else {
            overflow_exit();
        }
    }

    // Wait-free snapshot for the GC: collect all currently-published begin ids (sorted
    // ascending) into out, and return the conservative overflow floor (NO_FLOOR if none). The
    // returned set together with the floor is a SUPERSET of the truly-active read-views: while
    // floor < NO_FLOOR the GC must keep everything >= floor (no holes above it).
    void snapshot(std::vector<uint64_t> &out, uint64_t &overflow_floor_out) const {
        out.clear();
        for (auto &s : slots_) {
            uint64_t v = s.load(std::memory_order_acquire);
            if (v != EMPTY) out.push_back(v);
        }
        std::sort(out.begin(), out.end());
        overflow_floor_out = (overflow_count_.load(std::memory_order_acquire) > 0)
                             ? overflow_floor_.load(std::memory_order_acquire) : NO_FLOOR;
    }

private:
    // An unslotted (overflow) view lowers the floor to its begin id and bumps the count; the
    // GC over-protects [floor, inf) while count>0. Floor is monotone-down and not reset here
    // (mirrors the EBR overflow pin: always safe, only loosens the bound under SUSTAINED
    // >MAX_VIEWS load -- a per-live-overflow-view min-reset is a deferred memory optimization,
    // tracked in design-D5-gc.md §6). snapshot() ignores the floor once count returns to 0.
    void overflow_enter(uint64_t begin_id) {
        uint64_t cur = overflow_floor_.load(std::memory_order_acquire);
        while ((cur == NO_FLOOR || begin_id < cur) &&
               !overflow_floor_.compare_exchange_weak(cur, begin_id,
                                                      std::memory_order_acq_rel,
                                                      std::memory_order_acquire)) {
            // cur reloaded by the failed CAS; retry until floor <= begin_id.
        }
        overflow_count_.fetch_add(1, std::memory_order_acq_rel);
    }
    void overflow_exit() { overflow_count_.fetch_sub(1, std::memory_order_acq_rel); }

    // --- per-thread slot LEASE (mirrors EpochReclaimer): a publishing thread leases one slot
    // on first publish and frees it at thread exit, so slots are bounded by concurrently-live
    // publishing threads. Pool is per-instantiation (the template arg), shared across instances
    // of the same MAX_VIEWS. A thread holds at most one active read-view at a time, so one slot
    // per thread suffices; between transactions the slot holds EMPTY (skipped by snapshot).
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

    std::array<std::atomic<uint64_t>, MAX_VIEWS> slots_;
    std::atomic<uint64_t> overflow_floor_{NO_FLOOR};
    std::atomic<unsigned> overflow_count_{0};
};

} // namespace mvcc
