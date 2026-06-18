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

// Stage 1b: multi-producer retire + try-lock single-consumer reclaim. Many
// threads retire concurrently while several also call reclaim() concurrently
// (the try-lock must serialize consumers so nothing is double-freed), with
// guarded readers running throughout. Under ASan (UAF/leak) and TSan (race) this
// must be clean, and every retired deleter must run EXACTLY once.
TEST(EpochReclaimer, MultiProducerRetireSingleConsumerReclaim) {
    EpochReclaimer r;
    std::atomic<long> retired{0};
    std::atomic<long> freed{0};
    std::atomic<bool> done{false};

    auto reader = [&] {
        while (!done.load(std::memory_order_acquire)) {
            EpochReclaimer::Guard g(r);          // repeated short guarded sections
            std::this_thread::yield();
        }
    };

    const int W = 4, N = 20000;
    auto worker = [&] {
        for (int i = 0; i < N; i++) {
            r.retire([&freed] { freed.fetch_add(1, std::memory_order_relaxed); });
            retired.fetch_add(1, std::memory_order_relaxed);
            if ((i & 31) == 0) r.reclaim();      // concurrent consumers -> exercise try-lock
        }
    };

    std::vector<std::thread> readers, workers;
    for (int i = 0; i < 3; i++) readers.emplace_back(reader);
    for (int i = 0; i < W; i++) workers.emplace_back(worker);

    for (auto& t : workers) t.join();
    done.store(true, std::memory_order_release);
    for (auto& t : readers) t.join();

    while (r.pending() != 0) r.reclaim();        // quiescent -> drain remaining
    EXPECT_EQ(retired.load(), static_cast<long>(W) * N);
    EXPECT_EQ(freed.load(), retired.load());     // each retired deleter ran exactly once
    EXPECT_EQ(r.pending(), 0u);
}
