// Unit tests for the per-traversal Epoch-Based Reclamation primitive.
// Run under ASan (use-after-free) and TSan (data races).
#include <gtest/gtest.h>
#include <atomic>
#include <thread>
#include <vector>
#include "include/epoch_reclaimer.h"

using namespace mvcc;

TEST(EpochReclaimer, FreesWhenNoReaders) {
    EpochReclaimer r;
    std::atomic<int> freed{0};
    for (int i = 0; i < 5; i++) r.retire([&freed] { freed.fetch_add(1); });
    EXPECT_EQ(r.pending(), 5u);
    EXPECT_EQ(r.reclaim(), 5u);   // no active readers -> all freeable
    EXPECT_EQ(freed.load(), 5);
    EXPECT_EQ(r.pending(), 0u);
}

TEST(EpochReclaimer, ActiveReaderDelaysReclaim) {
    EpochReclaimer r;
    std::atomic<int> freed{0};
    {
        EpochReclaimer::Guard g(r);                 // reader reserves current epoch
        r.retire([&freed] { freed.fetch_add(1); }); // retired while reader active
        EXPECT_EQ(r.reclaim(), 0u);                  // must NOT free: reader may hold it
        EXPECT_EQ(freed.load(), 0);
    }                                                // reader exits
    EXPECT_EQ(r.reclaim(), 1u);                      // now safe
    EXPECT_EQ(freed.load(), 1);
}

namespace { struct Node { int payload; }; }

// Concurrent stress: many readers dereference a shared pointer that a single
// producer keeps swapping + retiring. With correct EBR there must be NO
// use-after-free (ASan) and NO data race (TSan).
TEST(EpochReclaimer, ConcurrentReadersNoUseAfterFree) {
    EpochReclaimer r;
    std::atomic<Node*> shared{ new Node{0} };
    std::atomic<bool> done{false};
    std::atomic<long> reads{0};

    auto reader = [&] {
        while (!done.load(std::memory_order_acquire)) {
            EpochReclaimer::Guard g(r);
            Node* p = shared.load(std::memory_order_acquire);
            volatile int x = p->payload;   // dereference the observed node
            (void)x;
            reads.fetch_add(1, std::memory_order_relaxed);
        }
    };

    std::vector<std::thread> readers;
    for (int i = 0; i < 8; i++) readers.emplace_back(reader);

    for (int i = 0; i < 50000; i++) {                          // single producer/reclaimer
        Node* n = new Node{i};
        Node* old = shared.exchange(n, std::memory_order_acq_rel);
        r.retire([old] { delete old; });
        if ((i & 63) == 0) r.reclaim();
    }
    done.store(true, std::memory_order_release);
    for (auto& t : readers) t.join();

    r.reclaim();                                   // no readers left -> drain
    EXPECT_EQ(r.pending(), 0u);
    delete shared.load();
    EXPECT_GT(reads.load(), 0);
}
