// Licensed under the MIT license.
#pragma once

#include <atomic>
#include <array>
#include <vector>
#include <cstdint>
#include <functional>
#include <utility>
#include <cassert>

namespace mvcc {

// Per-traversal Epoch-Based Reclamation (EBR).
//
// Readers wrap each list traversal (e.g. one search) in a Guard. An unlinked
// node is retired (not freed). A retired node is physically freed only once no
// reader that could still hold a pointer to it is active -- i.e. every active
// reader entered AFTER the node was retired.
//
// LLT-tolerant by design: a long-lived (OLAP) transaction only "reserves" for
// the span of each short traversal, so it does NOT pin reclamation the way an
// oldest-active-transaction watermark would. This is the physical-safety twin of
// the deadzone (which decides logical reclaimability); both must be LLT-tolerant.
//
// NOTE (stage 1b): retire() is MULTI-PRODUCER (lock-free Treiber stack), because
// GC is already reachable concurrently from several lock-free call sites. reclaim()
// is enforced SINGLE-CONSUMER via a try-lock: if a second thread enters while one
// is reclaiming it simply skips this cycle (its retires stay queued for next time).
// Survivors (not yet safe to free) are carried in a consumer-local list touched
// only under that try-lock. Guard/reservation grace semantics are unchanged.
//
// CALLER CONTRACT: call retire(node) only AFTER the node is unreachable to NEW
// traversals (i.e. after the physical unlink), so its stamp exceeds the reservation
// of any reader that could still reach it.
class EpochReclaimer {
public:
    static constexpr unsigned MAX_THREADS = 256;
    static constexpr uint64_t NOT_READING = ~uint64_t(0);  // sentinel: not in a traversal
    static constexpr unsigned SLOT_NONE = ~0u;             // my_slot(): lease pool exhausted

    EpochReclaimer() {
        for (auto &r : reservations_) r.store(NOT_READING, std::memory_order_relaxed);
    }
    EpochReclaimer(const EpochReclaimer &) = delete;
    EpochReclaimer &operator=(const EpochReclaimer &) = delete;

    // RAII reservation covering the span of one traversal.
    class Guard {
    public:
        explicit Guard(EpochReclaimer &r) : r_(r), slot_(EpochReclaimer::my_slot()) {
            if (slot_ != SLOT_NONE) {
                // publish "I may hold pointers as of this epoch" before dereferencing.
                r_.reservations_[slot_].store(r_.global_epoch_.load(std::memory_order_acquire),
                                              std::memory_order_seq_cst);
            } else {
                // Lease pool exhausted (>MAX_THREADS concurrently-live threads): fall back
                // to a conservative shared pin so reclaim never frees a node this slotless
                // reader could still reach. Never aliases a live slot (safety net).
                r_.overflow_enter();
            }
        }
        ~Guard() {
            if (slot_ != SLOT_NONE)
                r_.reservations_[slot_].store(NOT_READING, std::memory_order_release);
            else
                r_.overflow_exit();
        }
        Guard(const Guard &) = delete;
        Guard &operator=(const Guard &) = delete;
    private:
        EpochReclaimer &r_;
        unsigned slot_;
    };

    // Retire an object (multi-producer). Stamped with a fresh epoch and pushed
    // onto a lock-free Treiber stack.
    void retire(std::function<void()> deleter) {
        uint64_t stamp = global_epoch_.fetch_add(1, std::memory_order_acq_rel) + 1;
        RetiredNode *n = new RetiredNode{stamp, std::move(deleter), nullptr};
        n->next = retired_head_.load(std::memory_order_relaxed);
        // release: publish the node (and whatever its deleter will free) to the consumer.
        while (!retired_head_.compare_exchange_weak(n->next, n,
                                                    std::memory_order_release,
                                                    std::memory_order_relaxed)) {
            // n->next was refreshed to the current head by the failed CAS; retry.
        }
    }

    // Free everything that no currently-active reader could still reach.
    // Single-consumer: if another thread is already reclaiming, skip (return 0);
    // the retired entries stay queued and are handled by a later reclaim().
    // Returns the number of objects freed.
    size_t reclaim() {
        bool expected = false;
        if (!reclaiming_.compare_exchange_strong(expected, true,
                                                 std::memory_order_acquire,
                                                 std::memory_order_relaxed)) {
            return 0;  // another consumer is active
        }
        // --- sole consumer from here until the release store below ---
        // Detach the whole incoming stack and merge it into the consumer-local
        // survivors list (entries not yet safe to free from previous cycles).
        RetiredNode *incoming = retired_head_.exchange(nullptr, std::memory_order_acq_rel);
        while (incoming) {
            RetiredNode *n = incoming;
            incoming = incoming->next;
            n->next = survivors_;
            survivors_ = n;
        }

        const uint64_t safe = min_reservation();
        size_t freed = 0;
        RetiredNode *keep = nullptr;
        for (RetiredNode *cur = survivors_; cur;) {
            RetiredNode *next = cur->next;
            if (cur->epoch < safe) {
                cur->deleter();
                delete cur;
                ++freed;
            } else {
                cur->next = keep;
                keep = cur;
            }
            cur = next;
        }
        survivors_ = keep;

        reclaiming_.store(false, std::memory_order_release);
        return freed;
    }

    // Approximate count of not-yet-freed objects. Meaningful only when quiescent
    // (no concurrent retire/reclaim) -- intended for tests / single-threaded use.
    size_t pending() const {
        size_t n = 0;
        for (RetiredNode *p = retired_head_.load(std::memory_order_acquire); p; p = p->next) ++n;
        for (RetiredNode *p = survivors_; p; p = p->next) ++n;
        return n;
    }

private:
    struct RetiredNode { uint64_t epoch; std::function<void()> deleter; RetiredNode *next; };

    // Smallest epoch any active reader is reserving; if none, "everything".
    uint64_t min_reservation() const {
        // seq_cst loads pair with the Guard's seq_cst reservation publish (same total
        // order), so a just-published reservation is always observed by this scan.
        // (Acquire alone is not formally paired with the seq_cst store; seq_cst loads
        // are the clean fix -- and TSan models them, unlike a standalone fence.)
        uint64_t m = global_epoch_.load(std::memory_order_seq_cst) + 1;
        for (auto &r : reservations_) {
            uint64_t v = r.load(std::memory_order_seq_cst);
            if (v < m) m = v;  // NOT_READING is max -> never lowers m
        }
        // Fold in the conservative overflow pin (slotless readers). seq_cst throughout:
        // a slotless reader lowers overflow_floor_ to <= its entry epoch BEFORE it bumps
        // overflow_count_, so any scan that observes count>0 also observes floor<=that epoch.
        if (overflow_count_.load(std::memory_order_seq_cst) > 0) {
            uint64_t f = overflow_floor_.load(std::memory_order_seq_cst);
            if (f < m) m = f;
        }
        return m;
    }

    // --- per-thread reservation slot LEASE (stage 1c; replaces creation-order
    // round-robin). A thread leases one slot on its first Guard and frees it at thread
    // exit, so slots are bounded by CONCURRENTLY-LIVE threads, not LIFETIME threads
    // (spawn/join churn no longer exhausts the pool). The pool is global so a live
    // thread owns one slot index used in every instance's reservations_ array (a globally
    // unique index -> no aliasing in any instance). If exhausted (>MAX_THREADS concurrent),
    // my_slot() returns SLOT_NONE and the Guard uses the conservative overflow pin.
    static unsigned acquire_global_slot() {
        for (unsigned i = 0; i < MAX_THREADS; ++i) {
            bool expected = false;
            if (g_slot_taken_[i].compare_exchange_strong(expected, true,
                                                         std::memory_order_acquire,
                                                         std::memory_order_relaxed))
                return i;
        }
        return SLOT_NONE;   // pool exhausted -> caller falls back to overflow pin
    }
    static void release_global_slot(unsigned i) {
        if (i == SLOT_NONE) return;
        // Order the Guard's NOT_READING reservation stores (release) before the slot is
        // freed, so a thread that later leases this slot cannot observe it free while a
        // stale reservation is still visible to a concurrent min_reservation scan.
        std::atomic_thread_fence(std::memory_order_seq_cst);
        g_slot_taken_[i].store(false, std::memory_order_release);
    }
    struct SlotLease {
        unsigned slot;
        SlotLease() : slot(acquire_global_slot()) {}
        ~SlotLease() { release_global_slot(slot); }
        SlotLease(const SlotLease &) = delete;
        SlotLease &operator=(const SlotLease &) = delete;
    };
    static unsigned my_slot() {
        thread_local SlotLease lease;   // acquired on first use, released at thread exit
        return lease.slot;
    }

    // Conservative shared pin for slotless (overflow) readers. A slotless reader pins
    // reclamation to <= its entry epoch: it CAS-lowers overflow_floor_ to cover its epoch
    // BEFORE bumping overflow_count_, and the floor is never raised (no-reset). While any
    // overflow reader is active, reclaim stays conservative; when none are, the floor is
    // ignored. Always safe; the cure for SUSTAINED >MAX_THREADS concurrency is a bigger
    // pool (not expected on our workloads, where threads << MAX_THREADS).
    void overflow_enter() {
        uint64_t e = global_epoch_.load(std::memory_order_seq_cst);
        uint64_t cur = overflow_floor_.load(std::memory_order_seq_cst);
        while (cur > e &&
               !overflow_floor_.compare_exchange_weak(cur, e, std::memory_order_seq_cst)) {
            // cur reloaded by the failed CAS; retry until floor <= e.
        }
        overflow_count_.fetch_add(1, std::memory_order_seq_cst);
    }
    void overflow_exit() { overflow_count_.fetch_sub(1, std::memory_order_seq_cst); }

    std::atomic<uint64_t> global_epoch_{1};
    std::array<std::atomic<uint64_t>, MAX_THREADS> reservations_;
    std::atomic<RetiredNode *> retired_head_{nullptr};  // multi-producer Treiber stack of incoming retires
    RetiredNode *survivors_ = nullptr;                  // consumer-local: only touched under reclaiming_
    std::atomic<bool> reclaiming_{false};               // try-lock enforcing single-consumer reclaim()
    // Per-instance conservative overflow pin (slotless readers); see overflow_enter().
    std::atomic<uint64_t> overflow_floor_{NOT_READING};
    std::atomic<unsigned> overflow_count_{0};
    // Global slot-lease pool, shared across all reclaimer instances: a live thread owns
    // one slot index used in every instance's reservations_ array. Zero-init -> all free.
    static inline std::array<std::atomic<bool>, MAX_THREADS> g_slot_taken_{};
};

} // namespace mvcc
