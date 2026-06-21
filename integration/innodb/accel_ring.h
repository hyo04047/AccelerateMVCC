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
#include <cstring>
#include <type_traits>

namespace accel {

// D-4: cap on the cached full-row image carried per slot. A row larger than this is enqueued
// WITHOUT an image (img_len=0) -> consult falls back to a full walk for it (off-page LOB rows
// are excluded from caching anyway, so this matches the correctness gate, design-D §13).
constexpr uint32_t ACCEL_IMG_MAX = 512;

// D-4 4b-1: cap on the full clustered-PK identity bytes carried per slot. pk_hash (above) is only
// a bucket hint for the cuckoo table; this is the AUTHORITY consult memcmp-compares to reject
// pk_hash collisions. A PK longer than this is enqueued with pk_len=0 -> consult cannot prove
// identity -> MISS (full walk), never a wrong row.
constexpr uint32_t ACCEL_PK_MAX = 256;

// One captured undo event: scalars (D-1b) + full-PK identity bytes + delete-mark + an optional
// full-row image (D-4). Still a trivially-copyable POD so the under-latch publish is an alloc-free
// byte copy. enqueue copies the scalars + the full pk[] + img_len image bytes (NOT the whole
// ACCEL_IMG_MAX) to keep the latched copy small; bytes past img_len are intentionally left stale.
// NOTE: `img` MUST remain the LAST member -- enqueue/dequeue copy exactly offsetof(img)+img_len.
struct UndoRec {
  uint64_t table_id;
  uint64_t pk_hash;
  uint64_t trx_id;
  uint64_t old_trx_id;
  uint64_t space_id;
  uint64_t page_no;
  uint64_t offset;
  uint64_t op_type;
  uint32_t delete_mark;              // D-4 4b-1: REC_INFO_DELETED_FLAG of the captured version (0/1)
  uint32_t pk_len;                   // D-4 4b-1: full-PK byte length (0 = over cap/absent -> MISS)
  unsigned char pk[ACCEL_PK_MAX];    // D-4 4b-1: full clustered-PK identity bytes (length-prefixed)
  uint32_t img_len;                  // 0 = no image captured (row too big / ineligible)
  unsigned char img[ACCEL_IMG_MAX];  // full-row image; only the first img_len bytes are valid. LAST.
};

// D-1b-4 hardening: the under-latch publish must be an allocation-free copy (no ctor/heap work
// while InnoDB holds the page latch). Still trivially-copyable after adding the image (a POD byte
// array), so the prefix memcpy in enqueue/dequeue is well-defined. (The D-1b fixed-size tripwire
// is retired in D-4 -- the slot intentionally grew by the image cap.)
static_assert(std::is_trivially_copyable<UndoRec>::value,
              "UndoRec must be trivially copyable (alloc-free copy into the ring slot)");

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
    // D-4: copy scalars + only the used image bytes (offsetof(img) + img_len), never the whole
    // ACCEL_IMG_MAX -- keeps the under-latch copy small. UndoRec is trivially copyable, so a prefix
    // memcpy is well-defined; bytes past img_len in the slot are left stale (consumer reads img_len).
    std::memcpy(&slot->rec, &r, offsetof(UndoRec, img) + r.img_len);
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
    // Mirror enqueue: copy scalars + img_len bytes only (the publish via seq-release happened-before
    // makes slot->rec.img_len visible here).
    std::memcpy(&out, &slot->rec, offsetof(UndoRec, img) + slot->rec.img_len);
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
