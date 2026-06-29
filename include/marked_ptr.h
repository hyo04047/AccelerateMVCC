// Licensed under the MIT license.
#pragma once

#include <atomic>
#include <cstdint>

namespace mvcc {

// Lock-free "marked pointer" (Harris linked list): a pointer with a 1-bit
// logical-delete mark packed into the pointer's LOWEST bit. The low bit is free
// because the pointee is at least 2-byte aligned (in practice >=8, since list
// nodes hold uint64_t/atomic members). C++ has no AtomicMarkableReference, so we
// tag the bit in a std::atomic<uintptr_t> and CAS pointer+mark together.
//
// Why this exists (stage 1b): "mark a node for deletion" and "unlink it" must be
// atomic against a concurrent insert-after-that-node. With a plain pointer a
// single CAS cannot prevent inserting behind a node that is being removed (the
// new node is lost). Marking the node's `next` word first makes the would-be
// inserter's CAS fail, so it retries -- no lost node.
//
// CALLER CONTRACT: every type T used as MarkedPtr<T> MUST be >=2 aligned. This is
// asserted at each wiring site (and in marked_ptr_test) rather than here, so that
// a node type may embed MarkedPtr<Self> as its own `next` (alignof(Self) is not
// available inside Self's own definition).
//
// Introduced (stage 1b inc 0) unit-tested in isolation; it is now the backbone of every lock-free list
// in the index -- epoch_node::next, interval_list_header::next, and the epoch_table wrapper list all use
// MarkedPtr for their Harris mark + CAS-unlink.
template <typename T>
class MarkedPtr {
public:
    MarkedPtr() : word_(0) {}
    explicit MarkedPtr(T* p) : word_(pack(p, false)) {}

    MarkedPtr(const MarkedPtr&) = delete;
    MarkedPtr& operator=(const MarkedPtr&) = delete;

    static uintptr_t pack(T* p, bool mark) {
        return reinterpret_cast<uintptr_t>(p) | (mark ? uintptr_t(1) : uintptr_t(0));
    }
    static T*   ptr_of(uintptr_t w)  { return reinterpret_cast<T*>(w & ~uintptr_t(1)); }
    static bool mark_of(uintptr_t w) { return (w & uintptr_t(1)) != 0; }

    // Raw packed word (use ptr_of / mark_of to decode). Forward loads use acquire.
    uintptr_t load(std::memory_order mo = std::memory_order_acquire) const {
        return word_.load(mo);
    }
    T* ptr(std::memory_order mo = std::memory_order_acquire) const {
        return ptr_of(word_.load(mo));
    }
    bool marked(std::memory_order mo = std::memory_order_acquire) const {
        return mark_of(word_.load(mo));
    }
    void store(T* p, bool mark, std::memory_order mo = std::memory_order_release) {
        word_.store(pack(p, mark), mo);
    }

    // CAS the whole word (pointer+mark together). `expected` is updated to the
    // current word on failure, matching std::atomic::compare_exchange_strong.
    bool cas(uintptr_t& expected, uintptr_t desired,
             std::memory_order success = std::memory_order_acq_rel,
             std::memory_order failure = std::memory_order_acquire) {
        return word_.compare_exchange_strong(expected, desired, success, failure);
    }

    // Logical delete: set the mark bit on the node currently pointed to.
    // Fails if the pointer is no longer `expected_ptr` or is already marked.
    bool set_mark(T* expected_ptr,
                  std::memory_order success = std::memory_order_acq_rel,
                  std::memory_order failure = std::memory_order_acquire) {
        uintptr_t expected = pack(expected_ptr, false);
        return word_.compare_exchange_strong(expected, pack(expected_ptr, true),
                                             success, failure);
    }

private:
    std::atomic<uintptr_t> word_;
};

} // namespace mvcc
