// Correctness tests for AccelerateMVCC (stage B).
// Unlike google_test.cpp (timing micro-benchmarks), these assert *behavior*:
//   - MVCC search visibility
//   - deadzone construction + pruning decision (GC safety/precision)
//   - end-to-end GC under churn / long-lived reader (memory safety; run under ASAN)
#include <gtest/gtest.h>
#include <vector>
#include <thread>
#include <atomic>
#include "include/accelerateMVCC.h"

using namespace mvcc;

// ---------------------------------------------------------------------------
// (a) MVCC visibility: search must return the LATEST committed version that is
//     visible to the read view (trx_id < snapshot AND not in active list).
// ---------------------------------------------------------------------------
TEST(MvccVisibility, ReturnsLatestVisibleVersion) {
    Accelerate_mvcc mvcc(10);
    const uint64_t T = 1, K = 5;
    mvcc.insert(T, K, 10, 110, 210, 310);
    mvcc.insert(T, K, 20, 120, 220, 320);
    mvcc.insert(T, K, 30, 130, 230, 330);

    uint64_t s = 0, p = 0, o = 0;
    // snapshot at 25, nothing active -> latest committed < 25 == version 20
    ASSERT_TRUE(mvcc.search(T, K, 25, s, p, o, {}));
    EXPECT_EQ(s, 120u); EXPECT_EQ(p, 220u); EXPECT_EQ(o, 320u);
    // snapshot at 35 -> version 30
    s = 0; ASSERT_TRUE(mvcc.search(T, K, 35, s, p, o, {}));
    EXPECT_EQ(s, 130u);
    // snapshot at 15 -> version 10
    s = 0; ASSERT_TRUE(mvcc.search(T, K, 15, s, p, o, {}));
    EXPECT_EQ(s, 110u);
    // snapshot at 5 -> nothing visible
    s = 0; EXPECT_FALSE(mvcc.search(T, K, 5, s, p, o, {}));
}

TEST(MvccVisibility, ExcludesActiveTransactions) {
    Accelerate_mvcc mvcc(10);
    const uint64_t T = 1, K = 6;
    mvcc.insert(T, K, 10, 110, 210, 310);
    mvcc.insert(T, K, 20, 120, 220, 320);
    mvcc.insert(T, K, 30, 130, 230, 330);

    uint64_t s = 0, p = 0, o = 0;
    // at 35 but trx 30 still active -> latest visible == 20
    ASSERT_TRUE(mvcc.search(T, K, 35, s, p, o, {30}));
    EXPECT_EQ(s, 120u);
    // at 35 but 20 and 30 active -> version 10
    s = 0; ASSERT_TRUE(mvcc.search(T, K, 35, s, p, o, {20, 30}));
    EXPECT_EQ(s, 110u);
}

// ---------------------------------------------------------------------------
// helper: is the epoch with this epoch_num prunable under `zone`?
// ---------------------------------------------------------------------------
static bool epoch_prunable(Epoch_table& et, Epoch_table::deadzone* zone, uint64_t epoch_num) {
    epoch_node en;              // default ctor zeroes fields
    en.epoch_num = epoch_num;
    epoch_node_wrapper w(&en);
    return et.can_operate_gc(&w, zone);
}

// ---------------------------------------------------------------------------
// (c) deadzone construction + pruning decision.
//   Snapshot: oldest active a=550 (its read-view low-limit = 500),
//             younger active b=1550 (its read-view sees 1000 active).
//   => dead ranges: zone0 [0,500), zone1 (550,1000).
// ---------------------------------------------------------------------------
TEST(GcDeadzone, RangesAndPruningDecision) {
    Epoch_table et;
    trx_t a(550);
    a.active_trx_ids.push_back(500);    // a's low-limit id = 500
    trx_t b(1550);
    b.active_trx_ids.push_back(1000);   // b still sees 1000 as active
    std::vector<trx_t> snap;
    snap.push_back(a);
    snap.push_back(b);

    auto* zone = et.generate_dead_zone(snap);
    ASSERT_EQ(zone->len, 2u);
    EXPECT_EQ(zone->oldest_low_limit_id, 500u);
    EXPECT_EQ(zone->range[0], 0u);     EXPECT_EQ(zone->range[1], 500u);   // zone 0 = [0,500)
    EXPECT_EQ(zone->range[2], 550u);   EXPECT_EQ(zone->range[3], 1000u);  // zone 1 = (550,1000)

    // zone 0: epochs whose interval ends below 500 are dead
    EXPECT_TRUE(epoch_prunable(et, zone, 0));    // [0,99]
    EXPECT_TRUE(epoch_prunable(et, zone, 4));    // [400,499]
    // epoch 5 [500,599] holds the oldest active (550) and its low-limit (500) -> keep
    EXPECT_FALSE(epoch_prunable(et, zone, 5));
    // zone 1 hole (550,1000): epochs fully inside are dead
    EXPECT_TRUE(epoch_prunable(et, zone, 6));    // [600,699]
    EXPECT_TRUE(epoch_prunable(et, zone, 9));    // [900,999]
    // epoch 10 [1000,1099] holds 1000 (visible to b) -> keep
    EXPECT_FALSE(epoch_prunable(et, zone, 10));
    // epoch 15 [1500,1599] holds b (1550) -> keep
    EXPECT_FALSE(epoch_prunable(et, zone, 15));
    delete zone;
}

TEST(GcDeadzone, EmptySnapshotPrunesNothing) {
    Epoch_table et;
    auto* zone = et.generate_dead_zone(std::vector<trx_t>{});  // no active txn
    EXPECT_EQ(zone->len, 0u);
    EXPECT_FALSE(epoch_prunable(et, zone, 0));
    EXPECT_FALSE(epoch_prunable(et, zone, 100));
    delete zone;
}

// ---------------------------------------------------------------------------
// (b)/(d) end-to-end: GC under heavy churn must not crash / corrupt (run ASAN),
//         and a long-lived reader started early must not break the structure.
// ---------------------------------------------------------------------------
TEST(GcEndToEnd, HeavyChurnNoCrash) {
    Accelerate_mvcc mvcc(4);
    mvcc.start_background_gc();                   // dedicated BG GC prunes concurrently
    for (uint64_t i = 0; i < 100000; i++) {
        mvcc.insert_trx(i % 4);
    }
    mvcc.stop_background_gc();
    SUCCEED();
}

TEST(GcEndToEnd, LongLivedReaderSurvivesGc) {
    Accelerate_mvcc mvcc(4);
    mvcc.start_background_gc();
    trx_t* llt = mvcc.start_read_trx();          // early, long-lived snapshot
    for (uint64_t i = 0; i < 100000; i++) {
        mvcc.insert_trx(i % 4);
    }
    uint64_t s = 0, p = 0, o = 0;
    // Must not crash with a stale snapshot held open across many concurrent GC cycles.
    (void) mvcc.search_operation(1, 1, llt, s, p, o);
    mvcc.end_read_trx(llt);
    mvcc.stop_background_gc();
    SUCCEED();
}

// ---------------------------------------------------------------------------
// (e) EBR integration (stage 1a-ii): GC retires dead epoch nodes instead of
//     freeing them inline; search traversals are wrapped in an EBR Guard; GC
//     reclaims on each cycle. These assert the integration is memory-safe.
// ---------------------------------------------------------------------------

// Sanity: heavy GC churn with retire/reclaim wired in must not crash, and the
// structure stays searchable afterward. (single-threaded: GC + search never
// overlap, so reclaim drains immediately -- the real value is the concurrent
// test below; this just guards the retire/reclaim plumbing on the GC path.)
TEST(GcEbrIntegration, SingleThread) {
    Accelerate_mvcc mvcc(4);
    for (uint64_t i = 0; i < 100000; i++) {
        mvcc.insert_trx(i % 4);
        if (i % 2500 == 0) mvcc.run_gc_once();   // deterministic single-threaded GC (retire + reclaim)
    }
    uint64_t s = 0, p = 0, o = 0;
    trx_t* rd = mvcc.start_trx();
    (void) mvcc.search_operation(1, 1, rd, s, p, o);
    mvcc.commit_trx(rd);
    SUCCEED();
}

// Core 1b validation (stage 1b increment 4): the dedicated BG GC thread prunes
// concurrently while ONE writer churns the list (head-inserts) and N readers run
// guarded searches. EBR keeps GC-retired nodes alive for each traversal's span;
// the marked-pointer lists + GC-skips-head make BG-GC || insert || read touch
// disjoint words. Run under ASan (use-after-free == 0) and TSan (data race == 0).
//
// Single writer in this stage: multi-writer lock-free insert hardening is
// increment 5. Readers use start_trx()/commit_trx() (no GC side effects).
TEST(GcEbrIntegration, ConcurrentReaders) {
    Accelerate_mvcc mvcc(4);
    mvcc.start_background_gc();              // dedicated BG GC actor (the only unlinker)
    std::atomic<bool> done{false};
    std::atomic<long> reads{0};

    auto reader = [&] {
        while (!done.load(std::memory_order_acquire)) {
            trx_t* rd = mvcc.start_trx();
            uint64_t s = 0, p = 0, o = 0;
            (void) mvcc.search_operation(1, rd->trx_id % 4, rd, s, p, o);
            mvcc.commit_trx(rd);
            reads.fetch_add(1, std::memory_order_relaxed);
        }
    };

    std::vector<std::thread> readers;
    for (int i = 0; i < 4; i++) readers.emplace_back(reader);

    for (uint64_t i = 0; i < 100000; i++) {   // single writer; BG GC prunes concurrently
        mvcc.insert_trx(i % 4);
    }
    done.store(true, std::memory_order_release);
    for (auto& t : readers) t.join();
    mvcc.stop_background_gc();

    EXPECT_GT(reads.load(), 0);
}

// Multi-writer (stage 1b increment 5): several writer threads insert concurrently
// while the BG GC prunes and readers search. Same-record writes serialize on the
// per-record lock (InnoDB-style record write-lock = correct MVCC); different-record
// writes run concurrently (disjoint interval lists; the shared per-epoch wrapper
// bucket is handled by the Treiber head-insert CAS). insert||GC is the per-record
// single-writer||GC case GC-skips-head already covers. This validates the full
// concurrent model end-to-end: ASan (UAF 0) + TSan (race 0) + progress (completes).
TEST(GcEbrIntegration, ConcurrentWritersReadersBgGc) {
    Accelerate_mvcc mvcc(8);
    mvcc.start_background_gc();
    std::atomic<bool> done{false};
    std::atomic<long> reads{0};
    std::atomic<long> writes{0};

    auto reader = [&] {
        while (!done.load(std::memory_order_acquire)) {
            trx_t* rd = mvcc.start_trx();
            uint64_t s = 0, p = 0, o = 0;
            (void) mvcc.search_operation(1, rd->trx_id % 8, rd, s, p, o);
            mvcc.commit_trx(rd);
            reads.fetch_add(1, std::memory_order_relaxed);
        }
    };
    auto writer = [&](int seed) {
        for (int i = 0; i < 30000; i++) {
            mvcc.insert_trx((seed + i) % 8);   // writers overlap on records -> lock contention + cross-record concurrency
            writes.fetch_add(1, std::memory_order_relaxed);
        }
    };

    std::vector<std::thread> readers, writers;
    for (int i = 0; i < 3; i++) readers.emplace_back(reader);
    for (int i = 0; i < 4; i++) writers.emplace_back(writer, i * 3);

    for (auto& t : writers) t.join();          // 4 concurrent writers finish
    done.store(true, std::memory_order_release);
    for (auto& t : readers) t.join();
    mvcc.stop_background_gc();

    EXPECT_EQ(writes.load(), 4L * 30000);
    EXPECT_GT(reads.load(), 0);
}
