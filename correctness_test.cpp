// Correctness tests for AccelerateMVCC (stage B).
// Unlike google_test.cpp (timing micro-benchmarks), these assert *behavior*:
//   - MVCC search visibility
//   - deadzone construction + pruning decision (GC safety/precision)
//   - end-to-end GC under churn / long-lived reader (memory safety; run under ASAN)
#include <gtest/gtest.h>
#include <vector>
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
    for (uint64_t i = 0; i < 100000; i++) {
        mvcc.insert_trx(i % 4);   // triggers garbage_collect every 2500 trx
    }
    SUCCEED();
}

TEST(GcEndToEnd, LongLivedReaderSurvivesGc) {
    Accelerate_mvcc mvcc(4);
    trx_t* llt = mvcc.start_read_trx();          // early, long-lived snapshot
    for (uint64_t i = 0; i < 100000; i++) {
        mvcc.insert_trx(i % 4);
    }
    uint64_t s = 0, p = 0, o = 0;
    // Must not crash with a stale snapshot held open across many GC cycles.
    (void) mvcc.search_operation(1, 1, llt, s, p, o);
    mvcc.end_read_trx(llt);
    SUCCEED();
}
