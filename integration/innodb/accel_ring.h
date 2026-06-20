// Licensed under the MIT license.
//
// Bounded lock-free MPMC ring for the Stage D populate hook (design-D §9 safe design):
// many producers = InnoDB worker threads enqueue under the page latch (noexcept, no alloc,
// no blocking); a single consumer = the accel drainer pops off-latch and does the real insert.
// Dmitry Vyukov's bounded MPMC queue (per-slot sequence numbers). enqueue() returns false when
// full so the hook can DROP (count it) and never block a latch holder. Capacity = power of two.
//
// Header-only and InnoDB-free so it can be unit-tested standalone under TSan/ASan (accel_ring_test)
// before being wired into mysqld -- the same isolate-then-integrate pattern used for EBR / marked
// pointer. accel is a LEAF lock domain: this file never includes an InnoDB header.

#ifndef ACCEL_RING_H
#define ACCEL_RING_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace accel {

// One captured undo event (all scalar, POD -> copied whole into a slot under seq protection).
struct UndoRec {
  uint64_t table_id;
  uint64_t pk_hash;
  uint64_t trx_id;
  uint64_t old_trx_id;
  uint64_t space_id;
  uint64_t page_no;
  uint64_t offset;
  uint64_t op_type;
};

// D-1b-4 hardening tripwires: the under-latch enqueue does `slot.rec = r`, which must be an
// allocation-free trivial copy (no constructor/heap work while InnoDB holds the page latch).
// The fixed size guards against a future field addition silently bloating the latched copy.
static_assert(std::is_trivially_copyable<UndoRec>::value,
              "UndoRec must be trivially copyable (alloc-free copy into the ring slot)");
static_assert(sizeof(UndoRec) == 8 * sizeof(uint64_t),
              "UndoRec grew -- keep the under-latch enqueue payload small/POD");

template <size_t N>
class Ring {
  static_assert(N >= 2 && (N & (N - 1)) == 0, "N must be a power of two >= 2");

 public:
  Ring() {
    for (size_t i = 0; i < N; ++i) slots_[i].seq.store(i, std::memory_order_relaxed);
    enq_.store(0, std::memory_order_relaxed);
    deq_.store(0, std::memory_order_relaxed);
  }

  // Multi-producer. Returns false (caller drops) when the ring is full. Never blocks.
  bool enqueue(const UndoRec &r) noexcept {
    size_t pos = enq_.load(std::memory_order_relaxed);
    Slot *slot;
    for (;;) {
      slot = &slots_[pos & (N - 1)];
      size_t seq = slot->seq.load(std::memory_order_acquire);
      intptr_t diff = (intptr_t)seq - (intptr_t)pos;
      if (diff == 0) {
        if (enq_.compare_exchange_weak(pos, pos + 1, std::memory_order_relaxed)) break;
      } else if (diff < 0) {
        return false;  // full
      } else {
        pos = enq_.load(std::memory_order_relaxed);
      }
    }
    slot->rec = r;
    slot->seq.store(pos + 1, std::memory_order_release);  // publish
    return true;
  }

  // Single-consumer (the drainer). Returns false when empty.
  bool dequeue(UndoRec &out) noexcept {
    size_t pos = deq_.load(std::memory_order_relaxed);
    Slot *slot;
    for (;;) {
      slot = &slots_[pos & (N - 1)];
      size_t seq = slot->seq.load(std::memory_order_acquire);
      intptr_t diff = (intptr_t)seq - (intptr_t)(pos + 1);
      if (diff == 0) {
        if (deq_.compare_exchange_weak(pos, pos + 1, std::memory_order_relaxed)) break;
      } else if (diff < 0) {
        return false;  // empty
      } else {
        pos = deq_.load(std::memory_order_relaxed);
      }
    }
    out = slot->rec;
    slot->seq.store(pos + N, std::memory_order_release);  // free slot for a future lap
    return true;
  }

 private:
  struct Slot {
    std::atomic<size_t> seq;
    UndoRec rec;
  };
  alignas(64) std::atomic<size_t> enq_;
  alignas(64) std::atomic<size_t> deq_;
  alignas(64) Slot slots_[N];
};

}  // namespace accel

#endif  // ACCEL_RING_H
