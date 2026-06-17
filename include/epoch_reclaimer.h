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
// NOTE (stage 1a): retire()/reclaim() assume a SINGLE producer/reclaimer (the GC
// actor). Multi-producer support (cooperative FG unlink from many threads) is a
// later step and will need a lock-free retire queue.
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

    // Retire an object (single producer). Stamped with a fresh epoch.
    void retire(std::function<void()> deleter) {
        uint64_t stamp = global_epoch_.fetch_add(1, std::memory_order_acq_rel) + 1;
        retired_.push_back(Retired{stamp, std::move(deleter)});
    }

    // Free everything that no currently-active reader could still reach.
    // Returns the number of objects freed.
    size_t reclaim() {
        const uint64_t safe = min_reservation();
        size_t freed = 0;
        for (size_t i = 0; i < retired_.size();) {
            if (retired_[i].epoch < safe) {
                retired_[i].deleter();
                retired_[i] = std::move(retired_.back());
                retired_.pop_back();
                ++freed;
            } else {
                ++i;
            }
        }
        return freed;
    }

    size_t pending() const { return retired_.size(); }

private:
    struct Retired { uint64_t epoch; std::function<void()> deleter; };

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
    std::vector<Retired> retired_;                 // single-producer/reclaimer only
    static inline std::atomic<unsigned> next_slot_{0};
};

} // namespace mvcc
