// Licensed under the MIT license.
#pragma once

#include <atomic>
#include <array>
#include <vector>
#include <cstdint>
#include <functional>
#include <utility>

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

    EpochReclaimer() {
        for (auto &r : reservations_) r.store(NOT_READING, std::memory_order_relaxed);
    }
    EpochReclaimer(const EpochReclaimer &) = delete;
    EpochReclaimer &operator=(const EpochReclaimer &) = delete;

    // RAII reservation covering the span of one traversal.
    class Guard {
    public:
        explicit Guard(EpochReclaimer &r) : r_(r), slot_(r.my_slot()) {
            // publish "I may hold pointers as of this epoch" before dereferencing.
            r_.reservations_[slot_].store(r_.global_epoch_.load(std::memory_order_acquire),
                                          std::memory_order_seq_cst);
        }
        ~Guard() { r_.reservations_[slot_].store(NOT_READING, std::memory_order_release); }
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
        uint64_t m = global_epoch_.load(std::memory_order_acquire) + 1;
        for (auto &r : reservations_) {
            uint64_t v = r.load(std::memory_order_acquire);
            if (v < m) m = v;  // NOT_READING is max -> never lowers m
        }
        return m;
    }

    unsigned my_slot() const {
        thread_local unsigned slot =
            next_slot_.fetch_add(1, std::memory_order_relaxed) % MAX_THREADS;
        return slot;
    }

    std::atomic<uint64_t> global_epoch_{1};
    std::array<std::atomic<uint64_t>, MAX_THREADS> reservations_;
    std::atomic<RetiredNode *> retired_head_{nullptr};  // multi-producer Treiber stack of incoming retires
    RetiredNode *survivors_ = nullptr;                  // consumer-local: only touched under reclaiming_
    std::atomic<bool> reclaiming_{false};               // try-lock enforcing single-consumer reclaim()
    static inline std::atomic<unsigned> next_slot_{0};
};

} // namespace mvcc
