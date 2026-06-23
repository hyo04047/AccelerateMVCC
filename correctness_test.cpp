// Correctness tests for AccelerateMVCC (stage B).
// Unlike google_test.cpp (timing micro-benchmarks), these assert *behavior*:
//   - MVCC search visibility
//   - deadzone construction + pruning decision (GC safety/precision)
//   - end-to-end GC under churn / long-lived reader (memory safety; run under ASAN)
#include <gtest/gtest.h>
#include <vector>
#include <thread>
#include <atomic>
#include <array>
#include <algorithm>
#include "include/accelerateMVCC.h"
#include "include/read_view_mirror.h"
#include "include/active_view_registry.h"

using namespace mvcc;

// ---------------------------------------------------------------------------
// (a0) D-4 (4a): the InnoDB ReadView::changes_visible mirror, tested in isolation.
//   The four branches (read0types.h):
//     (1) id < up_limit_id || id == creator_trx_id           -> visible
//     (2) id >= low_limit_id                                 -> invisible
//     (3) up<=id<low, m_ids empty                            -> visible
//     (4) up<=id<low, m_ids nonempty: !binary_search(m_ids)  -> visible iff not active
//   These are the wrong-result gate for consult: consult must judge a cached version's
//   visibility byte-for-byte the way a real consistent read does.
// ---------------------------------------------------------------------------
TEST(ReadViewMirror, LowAndHighWater) {
    const std::vector<uint64_t> ids = {120, 140, 160, 180};  // sorted active set
    const uint64_t up = 100, low = 200, creator = 150;
    // Branch (1): strictly below the low-water mark -> visible.
    EXPECT_TRUE(changes_visible(50, up, low, creator, ids));
    EXPECT_TRUE(changes_visible(99, up, low, creator, ids));
    // Branch (2): at or above the high-water mark -> invisible (started after the snapshot).
    EXPECT_FALSE(changes_visible(200, up, low, creator, ids));
    EXPECT_FALSE(changes_visible(250, up, low, creator, ids));
}

TEST(ReadViewMirror, CreatorAlwaysVisible) {
    // The viewing trx's own writes are visible even when its id sits inside the active set /
    // between the marks (branch (1) short-circuits before the active-set test).
    const std::vector<uint64_t> ids = {160};
    EXPECT_TRUE(changes_visible(160, /*up*/100, /*low*/200, /*creator*/160, ids));
    // ... but a DIFFERENT id equal to that active member is invisible.
    EXPECT_FALSE(changes_visible(160, /*up*/100, /*low*/200, /*creator*/150, ids));
}

TEST(ReadViewMirror, ActiveSetMembership) {
    const std::vector<uint64_t> ids = {120, 140, 160, 180};
    const uint64_t up = 100, low = 200, creator = 150;
    // Branch (4): between the marks -> visible iff NOT an active RW trx at snapshot time.
    EXPECT_FALSE(changes_visible(140, up, low, creator, ids));  // active -> invisible
    EXPECT_TRUE(changes_visible(130, up, low, creator, ids));   // committed before -> visible
    EXPECT_TRUE(changes_visible(199, up, low, creator, ids));   // just below high-water, not active
    // Branch (3): empty active set, between the marks -> visible.
    EXPECT_TRUE(changes_visible(150, up, low, creator, {}));
}

TEST(ReadViewMirror, Boundaries) {
    const std::vector<uint64_t> ids = {120, 140, 160, 180};
    const uint64_t up = 100, low = 200, creator = 150;
    // id == up_limit: NOT strictly below, but still < low and not active -> visible.
    EXPECT_TRUE(changes_visible(100, up, low, creator, ids));
    // id == low_limit: >= high-water -> invisible (boundary is inclusive on the high side).
    EXPECT_FALSE(changes_visible(200, up, low, creator, ids));
    // id one below an active member -> visible; exactly on it -> invisible.
    EXPECT_TRUE(changes_visible(139, up, low, creator, ids));
    EXPECT_FALSE(changes_visible(140, up, low, creator, ids));
    // Degenerate view (up == low): only ids strictly below are visible; equal -> invisible.
    EXPECT_TRUE(changes_visible(99, 100, 100, 0, {}));
    EXPECT_FALSE(changes_visible(100, 100, 100, 0, {}));
}

// ---------------------------------------------------------------------------
// (a1) D-4 (4b-3): the shadow consult, tested OFFLINE (isolate-then-integrate, like EBR/ring).
//   Verifies the cache picks the same visible version a real consistent read would, and only
//   serves a HIT when it can PROVE contiguity to the live row -- otherwise a safe MISS. This is
//   the wrong-result gate, exercised without a running mysqld.
// ---------------------------------------------------------------------------
using CO = Accelerate_mvcc::ConsultOutcome;
// Insert one cached version: ver = its creator (visibility key), wr = the trx that overwrote it
// (so the NEXT-newer version's creator == wr). Versions for a key must be inserted in version order
// (a row's X-lock serializes its writers, so the cache really does receive them in order).
static void ins_ver(Accelerate_mvcc& m, uint64_t pkh, uint64_t ver, uint64_t wr,
                    const std::vector<unsigned char>& pk, const std::vector<unsigned char>& img) {
    m.insert(1, pkh, ver, ver * 10, ver * 100, ver * 1000,
             img.empty() ? nullptr : img.data(), (uint32_t)img.size(), wr,
             pk.data(), (uint32_t)pk.size(), 0);
}

TEST(Consult, HitNewestVisibleAndImage) {
    Accelerate_mvcc m(0, 10);
    const uint64_t H = 77; std::vector<unsigned char> pk{1, 2, 3, 4};
    ins_ver(m, H, 10, 20, pk, {0xA0});            // v10, overwritten by 20
    ins_ver(m, H, 20, 30, pk, {0xB0, 0xB1});      // v20, overwritten by 30
    ins_ver(m, H, 30, 40, pk, {0xC0, 0xC1, 0xC2});// v30, overwritten by 40 (= live row's writer)
    unsigned char buf[64]; uint32_t blen = 0;
    // reader sees < 35, nothing active, live row last written by 40 -> boundary is v30
    CO o = m.consult(1, H, pk.data(), (uint32_t)pk.size(), /*up*/5, /*low*/35, /*creator*/0,
                     nullptr, 0, /*live*/40, buf, sizeof(buf), &blen);
    EXPECT_EQ(o, CO::HIT);
    ASSERT_EQ(blen, 3u); EXPECT_EQ(buf[0], 0xC0); EXPECT_EQ(buf[2], 0xC2);
    // older snapshot (< 25) -> boundary is v20
    o = m.consult(1, H, pk.data(), (uint32_t)pk.size(), 5, 25, 0, nullptr, 0, 40, buf, sizeof(buf), &blen);
    EXPECT_EQ(o, CO::HIT); ASSERT_EQ(blen, 2u); EXPECT_EQ(buf[0], 0xB0);
}

TEST(Consult, MissDrainerLagHeadNotLive) {
    Accelerate_mvcc m(0, 10);
    const uint64_t H = 1; std::vector<unsigned char> pk{9};
    ins_ver(m, H, 10, 20, pk, {1}); ins_ver(m, H, 20, 30, pk, {2}); ins_ver(m, H, 30, 40, pk, {3});
    // The live row was actually overwritten by 50 (its entry isn't drained yet) -> cache head (40)
    // != live writer (50) -> cannot prove it reaches the head -> MISS.
    CO o = m.consult(1, H, pk.data(), 1, 5, 35, 0, nullptr, 0, /*live*/50, nullptr, 0, nullptr);
    EXPECT_EQ(o, CO::MISS_NONCONTIG);
}

TEST(Consult, MissInteriorDropBelowSuffix) {
    Accelerate_mvcc m(0, 10);
    const uint64_t H = 2; std::vector<unsigned char> pk{9};
    ins_ver(m, H, 10, 20, pk, {1});   // v10 (overwritten by 20)
    // v20 DROPPED (never inserted) -- simulates a ring-full drop
    ins_ver(m, H, 30, 40, pk, {3});   // v30 -> linkage breaks, gap-free run restarts at version 30
    // reader sees < 25: the TRUE boundary is v20 (dropped). cache has v10 (visible) but it is BELOW
    // the gap-free run [30,..] -> must MISS, not return the stale v10.
    CO o = m.consult(1, H, pk.data(), 1, 5, 25, 0, nullptr, 0, /*live*/40, nullptr, 0, nullptr);
    EXPECT_EQ(o, CO::MISS_NONCONTIG);
}

TEST(Consult, MissAbsentAndCollisionFilteredByFullPk) {
    Accelerate_mvcc m(0, 10);
    const uint64_t H = 3; std::vector<unsigned char> pkA{1}, pkB{2};
    ins_ver(m, H, 10, 20, pkA, {1}); ins_ver(m, H, 20, 30, pkA, {2}); ins_ver(m, H, 30, 40, pkA, {3});
    // A different row whose PK collides on the same hash bucket -> the full-PK check rejects it.
    CO o = m.consult(1, H, pkB.data(), 1, 5, 35, 0, nullptr, 0, 40, nullptr, 0, nullptr);
    EXPECT_EQ(o, CO::MISS_ABSENT);
    // a hash bucket not present at all
    o = m.consult(1, 999, pkA.data(), 1, 5, 35, 0, nullptr, 0, 40, nullptr, 0, nullptr);
    EXPECT_EQ(o, CO::MISS_ABSENT);
}

TEST(Consult, MissNoVisibleVersion) {
    Accelerate_mvcc m(0, 10);
    const uint64_t H = 4; std::vector<unsigned char> pk{7};
    ins_ver(m, H, 10, 20, pk, {1}); ins_ver(m, H, 20, 30, pk, {2}); ins_ver(m, H, 30, 40, pk, {3});
    // snapshot below everything (sees < 5) -> no cached version visible
    CO o = m.consult(1, H, pk.data(), 1, 1, 5, 0, nullptr, 0, 40, nullptr, 0, nullptr);
    EXPECT_EQ(o, CO::MISS_NOVISIBLE);
}

TEST(Consult, MissIneligibleWhenImageRequestedButAbsent) {
    Accelerate_mvcc m(0, 10);
    const uint64_t H = 5; std::vector<unsigned char> pk{7};
    ins_ver(m, H, 10, 20, pk, {}); ins_ver(m, H, 20, 30, pk, {}); ins_ver(m, H, 30, 40, pk, {});
    unsigned char buf[8]; uint32_t blen = 0;
    // candidate is visible + contiguous, but has no cached image -> cannot serve bytes -> MISS.
    CO o = m.consult(1, H, pk.data(), 1, 5, 35, 0, nullptr, 0, 40, buf, sizeof(buf), &blen);
    EXPECT_EQ(o, CO::MISS_INELIGIBLE);
    // ... but if no image is requested, the same candidate is a clean (locator-level) HIT.
    o = m.consult(1, H, pk.data(), 1, 5, 35, 0, nullptr, 0, 40, nullptr, 0, nullptr);
    EXPECT_EQ(o, CO::HIT);
}

// NEGATIVE CONTROL (review M6: a control is only meaningful if it actually reaches the byte-compare).
// Bucket H holds ONLY row A's contiguous versions; a query for a DIFFERENT row B that collides on the
// hash bucket must MISS with the full-PK guard ON. With the guard OFF, the SAME query reaches a HIT
// and is served row A's image -- proving (a) full-PK identity is what prevents the cross-row wrong
// result, and (b) this test can actually catch such a bug. (The mysqld hash-mask scenario can't show
// this: there the per-bucket contiguity gate MISSes first, so the control is vacuous -- done here.)
TEST(Consult, NegControlFullPkOffServesCrossRow) {
    Accelerate_mvcc m(0, 10);
    const uint64_t H = 3; std::vector<unsigned char> pkA{1}, pkB{2};
    ins_ver(m, H, 10, 20, pkA, {0xAA}); ins_ver(m, H, 20, 30, pkA, {0xAB}); ins_ver(m, H, 30, 40, pkA, {0xAC});
    unsigned char buf[8]; uint32_t bl = 0;
    // guard ON: pkB is absent in the bucket -> safe MISS (never serves row A's bytes).
    CO on = m.consult(1, H, pkB.data(), 1, 5, 35, 0, nullptr, 0, 40, buf, sizeof(buf), &bl, /*require_full_pk=*/true);
    EXPECT_EQ(on, CO::MISS_ABSENT);
    // guard OFF: identity ignored -> matches row A's entries -> wrong cross-row HIT serving A's v30.
    CO off = m.consult(1, H, pkB.data(), 1, 5, 35, 0, nullptr, 0, 40, buf, sizeof(buf), &bl, /*require_full_pk=*/false);
    EXPECT_EQ(off, CO::HIT);
    EXPECT_EQ(bl, 1u); EXPECT_EQ(buf[0], 0xAC);
}

// D-4 (4b-3c): consult (many reader threads) || insert (one drainer-like thread) on the SAME hot
// key. The point is to exercise the concurrent surface the shadow adds -- the gate is ASan/TSan
// clean + no crash + every HIT returns a non-empty image (no torn/garbage read). Mirrors how EBR /
// ring concurrency was validated standalone before mysqld.
TEST(Consult, ConcurrencyInserterVsConsultors) {
    Accelerate_mvcc m(0, 12);
    const uint64_t H = 42; std::vector<unsigned char> pk{7, 7, 7, 7};
    std::atomic<uint64_t> head_writer{0};
    std::atomic<bool> stop{false};
    std::atomic<bool> bad{false};
    const int NV = 4000;
    std::thread ins([&] {
        for (int v = 1; v <= NV; ++v) {
            std::vector<unsigned char> img(8, (unsigned char)(v & 0xFF));
            m.insert(1, H, (uint64_t)v, v * 10ull, v * 100ull, v * 1000ull,
                     img.data(), (uint32_t)img.size(), (uint64_t)(v + 1),
                     pk.data(), (uint32_t)pk.size(), 0);
            head_writer.store((uint64_t)(v + 1), std::memory_order_release);  // publish AFTER insert
        }
        stop.store(true, std::memory_order_release);
    });
    auto consultor = [&] {
        unsigned char buf[64]; uint32_t bl = 0;
        while (!stop.load(std::memory_order_acquire)) {
            uint64_t lw = head_writer.load(std::memory_order_acquire);
            // read view that sees every committed version (m_ids empty) -> candidate = newest
            CO o = m.consult(1, H, pk.data(), (uint32_t)pk.size(), 0, ~0ull, 0,
                             nullptr, 0, lw, buf, sizeof(buf), &bl);
            if (o == CO::HIT && bl == 0) bad.store(true);  // a HIT must carry a real image
        }
    };
    std::vector<std::thread> cs;
    for (int i = 0; i < 4; ++i) cs.emplace_back(consultor);
    ins.join();
    for (auto& t : cs) t.join();
    EXPECT_FALSE(bad.load());
}

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
    en.min_trx_id = epoch_num * EPOCH_SIZE;                              // nominal window start
    en.superseded_ts.store(epoch_num * EPOCH_SIZE + EPOCH_SIZE - 1);     // nominal window end (xmax)
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

// Stage 1c-4 fix demonstration (tight bounds vs over-pruning). A version superseded BEYOND its
// nominal epoch window must NOT be pruned: it is still the visible-latest for the transaction
// at the dead zone's right edge. Active set {500, 9000} -> dead zone (500, 9000). A non-head
// epoch holds version 8050 whose next-newer version is at 9500 (> 9000), so it is reader@9000's
// visible version and is NOT dead. The nominal window [8000,8099] wrongly classifies it dead;
// the tight bound [min_trx_id=8050, superseded_ts=9500] correctly keeps it.
// FAILS under the old nominal can_operate_gc; PASSES once the check uses min_trx_id/superseded_ts.
TEST(GcDeadzone, TightBoundDoesNotOverPruneNeededVersion) {
    Epoch_table et;
    trx_t a(500);                  // a.active empty -> oldest_low_limit = 500
    trx_t b(9000);                 // b == reader@9000
    std::vector<trx_t> snap; snap.push_back(a); snap.push_back(b);
    auto* zone = et.generate_dead_zone(snap);   // zones [0,500), (500,9000)

    epoch_node en;
    en.epoch_num = 80;             // nominal window [8000,8099] -- the OLD check would prune
    en.min_trx_id = 8050;
    en.superseded_ts.store(9500);  // actually superseded only at 9500 (>= 9000) -> still visible to b
    epoch_node_wrapper w(&en);
    EXPECT_FALSE(et.can_operate_gc(&w, zone))
        << "epoch holds reader@9000's visible version (superseded only at 9500); must not be pruned";
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

// ---------------------------------------------------------------------------
// Stage 1c-1: shared published deadzone descriptor (publish + consume, judge-only).
// ---------------------------------------------------------------------------

// Staleness-safety oracle (the key new correctness property). A reader may judge
// deadness against an OLD published descriptor; safety requires it NEVER over-prunes,
// i.e. anything the OLD descriptor calls prunable is STILL prunable under the CURRENT
// one. Because trx ids are strictly monotonic, the active set only loses its oldest
// (commits) and gains at the top (new txns) -> dead zones only grow -> the prunable
// set only grows. So old-prunable must imply current-prunable.
TEST(GcSharedDescriptor, StaleDescriptorOnlyUnderPrunes) {
    Epoch_table et;

    // D1 (old): active {a=550 (low-limit 500), b=1550 (sees 1000)} -> dead [0,500),(550,1000)
    trx_t a(550);  a.active_trx_ids.push_back(500);
    trx_t b(1550); b.active_trx_ids.push_back(1000);
    std::vector<trx_t> s1; s1.push_back(a); s1.push_back(b);
    auto* d1 = et.generate_dead_zone(s1);

    // D2 (current, later): a committed (gone); b still active, its oldest-seen rose to
    // 1400; a new c=2550 started. Active {b=1550 (low-limit 1400), c=2550 (sees 2000)}.
    trx_t b2(1550); b2.active_trx_ids.push_back(1400);
    trx_t c(2550);  c.active_trx_ids.push_back(2000);
    std::vector<trx_t> s2; s2.push_back(b2); s2.push_back(c);
    auto* d2 = et.generate_dead_zone(s2);

    int d1_pruned = 0;
    for (uint64_t e = 0; e < 30; ++e) {
        bool p1 = epoch_prunable(et, d1, e);   // helper sets nominal [e*SIZE, +SIZE) tight bounds
        bool p2 = epoch_prunable(et, d2, e);
        if (p1) {
            ++d1_pruned;
            EXPECT_TRUE(p2) << "epoch " << e << " prunable under stale D1 but NOT current D2";
        }
    }
    EXPECT_GT(d1_pruned, 0);   // the oracle actually exercised prunable epochs
    delete d1; delete d2;
}

// Concurrent consume + descriptor lifetime: BG GC publishes a fresh descriptor each
// cycle and retires the superseded one under EBR, while readers load it under their
// traversal Guard and judge every epoch. Readers necessarily traverse dead epochs under
// churn, so the consume path must be live (coop_dead_seen > 0); ASan/TSan here cover the
// publish/retire lifetime (a reader holding a descriptor BG just retired must not UAF).
TEST(GcSharedDescriptor, ReadersConsumeDescriptorUnderBgGc) {
    Accelerate_mvcc mvcc(4);
    mvcc.start_background_gc();
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
    for (uint64_t i = 0; i < 100000; i++) mvcc.insert_trx(i % 4);
    done.store(true, std::memory_order_release);
    for (auto& t : readers) t.join();
    mvcc.stop_background_gc();

    EXPECT_GT(reads.load(), 0);
    EXPECT_GT(mvcc.coop_dead_seen(), 0u);   // readers actually loaded+judged the descriptor
}

// ---------------------------------------------------------------------------
// Stage 1c-2: retire-once state machine (LIVE->CHAIN_DETACHED->RETIRED) + version-chain
// all-CAS, still BG-only unlinker. Conservation: every epoch_node detached from the
// version chain is retired EXACTLY once (the state claim gates the sole retire authority);
// a strand (detached, never retired) or a double-retire breaks detached == retired, and
// ASan additionally catches any double-free of an epoch_node or its undo chain.
// ---------------------------------------------------------------------------
TEST(GcRetireOnce, ConservationUnderBgGc) {
    Accelerate_mvcc mvcc(8);
    mvcc.start_background_gc();
    std::atomic<bool> done{false};
    std::atomic<long> reads{0};

    auto reader = [&] {
        while (!done.load(std::memory_order_acquire)) {
            trx_t* rd = mvcc.start_trx();
            uint64_t s = 0, p = 0, o = 0;
            (void) mvcc.search_operation(1, rd->trx_id % 8, rd, s, p, o);
            mvcc.commit_trx(rd);
            reads.fetch_add(1, std::memory_order_relaxed);
        }
    };

    std::vector<std::thread> readers;
    for (int i = 0; i < 4; i++) readers.emplace_back(reader);
    for (uint64_t i = 0; i < 150000; i++) mvcc.insert_trx(i % 8);
    done.store(true, std::memory_order_release);
    for (auto& t : readers) t.join();
    mvcc.stop_background_gc();

    EXPECT_GT(mvcc.epochs_retired(), 0u);                      // GC actually reclaimed epochs
    EXPECT_EQ(mvcc.epochs_detached(), mvcc.epochs_retired());  // each detached node retired once
}

// Single-threaded determinism: run_gc_once detaches+retires with the same conservation.
// We hold ONE active reader so the deadzone is non-empty (everything below its snapshot is
// dead) and GC actually prunes -- with NO active txn the snapshot is empty and our
// conservative deadzone prunes nothing, so nothing would be retired.
TEST(GcRetireOnce, ConservationSingleThread) {
    Accelerate_mvcc mvcc(4);
    for (uint64_t i = 0; i < 20000; i++) mvcc.insert_trx(i % 4);   // build epochs first
    trx_t* rd = mvcc.start_trx();                                  // snapshot above them
    for (uint64_t i = 20000; i < 120000; i++) {
        mvcc.insert_trx(i % 4);
        if (i % 2500 == 0) mvcc.run_gc_once();                     // epochs below rd's snapshot are dead
    }
    mvcc.commit_trx(rd);
    EXPECT_GT(mvcc.epochs_retired(), 0u);
    EXPECT_EQ(mvcc.epochs_detached(), mvcc.epochs_retired());
}

// ---------------------------------------------------------------------------
// Stage 1c-3: full-bucket backstop sweep + dummy-overflow drain (#2). 4 writers race the
// BG bucket-swap (epoch_num != bucket epoch_num) -> orphan wrappers pile into the dummy
// stack; readers keep the deadzone non-empty. The drain must reclaim dead orphans (not leak
// them) and the backstop must revisit cold buckets, all while conservation (detached ==
// retired) holds across the windowed + backstop + drain retire paths, and the dummy stack
// must not grow without bound. Run under ASan (double-free/UAF 0) + TSan (race 0).
// ---------------------------------------------------------------------------
TEST(GcBackstopDrain, DummyOverflowDrainsAndConserves) {
    Accelerate_mvcc mvcc(8);
    mvcc.start_background_gc();
    std::atomic<bool> done{false};
    std::atomic<long> reads{0};

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
        for (int i = 0; i < 40000; i++) mvcc.insert_trx((seed + i) % 8);
    };

    std::vector<std::thread> readers, writers;
    for (int i = 0; i < 2; i++) readers.emplace_back(reader);
    for (int i = 0; i < 4; i++) writers.emplace_back(writer, i * 2);
    for (auto& t : writers) t.join();
    done.store(true, std::memory_order_release);
    for (auto& t : readers) t.join();
    mvcc.stop_background_gc();

    // BG off -> run_gc_once drives final drain/backstop passes. A reader started now snapshots
    // above everything, so all remaining non-head epochs/orphans are dead and get reclaimed.
    trx_t* rd = mvcc.start_trx();
    for (int i = 0; i < 80; i++) mvcc.run_gc_once();
    mvcc.commit_trx(rd);

    EXPECT_GT(mvcc.epochs_retired(), 0u);                       // GC actually reclaimed
    EXPECT_EQ(mvcc.epochs_detached(), mvcc.epochs_retired());   // conservation across all paths
    EXPECT_LT(mvcc.dummy_pending(), 256u);                      // dummy drained (no unbounded leak)
}

// ---------------------------------------------------------------------------
// Stage 1c-4: FG cooperative unlink. Readers now mark + best-effort CAS-splice dead NON-head
// epochs themselves (retire stays BG-only). The version chain becomes genuinely multi-unlinker
// (readers + BG). These assert (a) visibility is NOT corrupted by concurrent cooperative
// unlink, and (b) the hot-record races (reader-vs-reader, reader-vs-BG) are UAF/race-free and
// cooperative unlink keeps the chain bounded. Run under ASan + TSan.
// ---------------------------------------------------------------------------

// Visibility oracle: a registered reader's snapshot protects its visible-latest version (in
// the head epoch, which is never pruned), so its result must stay IDENTICAL across thousands
// of searches while churn readers + BG GC cooperatively unlink the record's dead epochs.
TEST(GcFgUnlink, RegisteredReaderResultStable) {
    Accelerate_mvcc mvcc(4);
    for (int i = 0; i < 2000; i++) mvcc.insert_trx(2);   // many versions on record 2 -> many epochs
    mvcc.start_background_gc();
    std::atomic<bool> done{false};

    auto churn = [&] {
        while (!done.load(std::memory_order_acquire)) {
            trx_t* r = mvcc.start_trx();
            uint64_t s = 0, p = 0, o = 0;
            (void) mvcc.search_operation(1, 2, r, s, p, o);   // FG cooperative unlink on record 2
            mvcc.commit_trx(r);
        }
    };
    std::vector<std::thread> ts;
    for (int i = 0; i < 4; i++) ts.emplace_back(churn);

    trx_t* ref = mvcc.start_trx();                          // snapshot above all 2000 versions
    uint64_t s0 = 0, p0 = 0, o0 = 0;
    bool f0 = mvcc.search_operation(1, 2, ref, s0, p0, o0); // reference: the head version
    bool stable = true;
    for (int i = 0; i < 3000 && stable; i++) {
        uint64_t s = 0, p = 0, o = 0;
        bool f = mvcc.search_operation(1, 2, ref, s, p, o);
        if (f != f0 || s != s0 || p != p0 || o != o0) stable = false;
    }
    mvcc.end_read_trx(ref);
    done.store(true, std::memory_order_release);
    for (auto& t : ts) t.join();
    mvcc.stop_background_gc();

    EXPECT_TRUE(f0);       // ref found a visible version
    EXPECT_TRUE(stable);   // its result never changed despite concurrent cooperative unlink + GC
}

// Hot-record stress: 6 readers cooperatively unlink one record's chain while a writer keeps
// appending new versions and BG GC runs. Exercises reader-vs-reader and reader-vs-BG splice
// races on the SAME chain (the multi-unlinker surface 1c-2's review reasoned about). After a
// final drain, conservation holds and the chain is bounded (cooperative unlink kept up).
TEST(GcFgUnlink, HotRecordCoopUnlinkShrinksChain) {
    Accelerate_mvcc mvcc(4);
    mvcc.start_background_gc();
    std::atomic<bool> done{false};
    std::atomic<long> reads{0};

    auto reader = [&] {
        while (!done.load(std::memory_order_acquire)) {
            trx_t* r = mvcc.start_trx();
            uint64_t s = 0, p = 0, o = 0;
            (void) mvcc.search_operation(1, 0, r, s, p, o);
            mvcc.commit_trx(r);
            reads.fetch_add(1, std::memory_order_relaxed);
        }
    };
    std::vector<std::thread> ts;
    for (int i = 0; i < 6; i++) ts.emplace_back(reader);
    for (int i = 0; i < 60000; i++) mvcc.insert_trx(0);   // hot record 0: chain keeps growing
    done.store(true, std::memory_order_release);
    for (auto& t : ts) t.join();
    mvcc.stop_background_gc();

    // Final drains (BG off) with a dead-making reader so every FG-detached node is retired.
    trx_t* rd = mvcc.start_trx();
    for (int i = 0; i < 80; i++) mvcc.run_gc_once();
    mvcc.commit_trx(rd);

    EXPECT_GT(reads.load(), 0);
    EXPECT_GT(mvcc.coop_dead_seen(), 0u);                      // readers actually unlinked dead epochs
    EXPECT_EQ(mvcc.epochs_detached(), mvcc.epochs_retired());  // conservation (FG unlink + BG retire)
    EXPECT_LT(mvcc.chain_length(1, 0), 256u);                  // cooperative unlink kept it bounded
}

// Stage 1c-5 (#5 cold dead head) is RESOLVED by the 1c-4 tight-bound fix, not a new increment.
// A record's HEAD epoch holds its current value: it is never yet superseded (superseded_ts =
// infinity), so it is NEVER judged dead -- even when its nominal trx-id window sits deep inside
// a dead zone. So GC correctly retains exactly the head and prunes everything older; there is no
// "cold dead head" to reclaim. (That leak was an artifact of the old nominal over-pruning, which
// mis-judged the live head as dead and then needed GC-skips-head + a future head-prune to mop up.
// Tight bounds removes the misjudgment, so the whole head-prune-vs-append concurrency problem in
// design-1c.md s3 dissolves.)
TEST(GcDeadzone, HeadEpochIsNeverPruned) {
    Epoch_table et;
    trx_t a(9000);                              // single active txn at 9000
    std::vector<trx_t> snap; snap.push_back(a);
    auto* zone = et.generate_dead_zone(snap);   // dead zone [0, 9000)

    epoch_node head;
    head.epoch_num = 5;                         // nominal window [500,599] -- deep inside the dead zone
    head.min_trx_id = 500;
    // superseded_ts stays UINT64_MAX (default): this is the head / current value, not superseded.
    epoch_node_wrapper w(&head);
    EXPECT_FALSE(et.can_operate_gc(&w, zone))
        << "a head epoch (current value, not yet superseded) must never be judged prunable";
    delete zone;
}

// ---------------------------------------------------------------------------
// Stage 1c-6: scale + integration. High thread counts on a SKEWED workload (most ops hit a few
// hot records), sustained, validating the full concurrent model end-to-end: UAF/race-free
// (ASan/TSan), conservation across every retire path, hot-record chains bounded, the GC
// bookkeeping vector bounded by compaction (not growing with total inserts), and no hang.
// ---------------------------------------------------------------------------
TEST(GcScale, HighConcurrencySkewedWorkload) {
    Accelerate_mvcc mvcc(16);
    mvcc.start_background_gc();
    std::atomic<bool> done{false};
    std::atomic<long> reads{0}, writes{0};
    auto skew = [](long i) -> uint64_t { return (i % 5 < 4) ? (uint64_t)(i % 2) : (uint64_t)(2 + (i % 14)); };

    auto reader = [&] {
        long i = 0;
        while (!done.load(std::memory_order_acquire)) {
            trx_t* r = mvcc.start_trx();
            uint64_t s = 0, p = 0, o = 0;
            (void) mvcc.search_operation(1, skew(i++), r, s, p, o);
            mvcc.commit_trx(r);
            reads.fetch_add(1, std::memory_order_relaxed);
        }
    };
    auto writer = [&](long seed) {
        for (long i = 0; i < 50000; i++) {
            mvcc.insert_trx(skew(seed + i));
            writes.fetch_add(1, std::memory_order_relaxed);
        }
    };

    std::vector<std::thread> rs, ws;
    for (int i = 0; i < 8; i++) rs.emplace_back(reader);
    for (int i = 0; i < 8; i++) ws.emplace_back(writer, (long)i * 7919);
    for (auto& t : ws) t.join();
    done.store(true, std::memory_order_release);
    for (auto& t : rs) t.join();
    mvcc.stop_background_gc();

    trx_t* rd = mvcc.start_trx();                  // dead-making reader -> final drains retire all
    for (int i = 0; i < 80; i++) mvcc.run_gc_once();
    mvcc.commit_trx(rd);

    EXPECT_EQ(writes.load(), 8L * 50000);
    EXPECT_GT(reads.load(), 0);
    EXPECT_EQ(mvcc.epochs_detached(), mvcc.epochs_retired());   // conservation at scale
    EXPECT_LT(mvcc.chain_length(1, 0), 256u);                   // hot record chain bounded
    EXPECT_LT(mvcc.long_live_size(), 2000u);                    // bookkeeping bounded by compaction
}

// A long-lived reader transaction holds its snapshot across heavy GC + churn while doing many
// SHORT (per-traversal Guard) searches. Its visible version must never disappear (tight bounds
// keeps exactly what it needs), and the short per-traversal Guards must not starve reclaim.
TEST(GcScale, LongLivedReaderConsistentUnderHeavyGc) {
    Accelerate_mvcc mvcc(4);
    for (int i = 0; i < 500; i++) mvcc.insert_trx(0);   // seed record 0
    mvcc.start_background_gc();
    trx_t* llt = mvcc.start_trx();                       // long-lived snapshot
    uint64_t s0 = 0, p0 = 0, o0 = 0;
    bool f0 = mvcc.search_operation(1, 0, llt, s0, p0, o0);  // its visible version

    std::thread w([&] { for (int i = 0; i < 100000; i++) mvcc.insert_trx(i % 4); });

    bool consistent = f0;
    for (int i = 0; i < 30000 && consistent; i++) {
        uint64_t s = 0, p = 0, o = 0;
        bool f = mvcc.search_operation(1, 0, llt, s, p, o);   // a fresh short Guard each search
        if (f != f0 || s != s0) consistent = false;
    }
    w.join();
    mvcc.end_read_trx(llt);
    mvcc.stop_background_gc();

    EXPECT_TRUE(f0);
    EXPECT_TRUE(consistent);                 // LLT's visible version survived all GC (tight bounds)
    EXPECT_GT(mvcc.epochs_retired(), 0u);    // reclaim made progress (not starved by the LLT)
}

// ---------------------------------------------------------------------------
// D-5 (5-1a): ActiveViewRegistry -- the leaf-domain lock-free mirror of InnoDB's active
//   read-views (collection signal B), tested in isolation before any mysqld wiring. The
//   load-bearing property is SUPERSET: a published (open, not-yet-closed) view is ALWAYS
//   observed by a later snapshot, and slot-pool exhaustion lowers a conservative floor
//   rather than dropping a view. Never omitting a live view is the one safe direction
//   (design-D5-gc.md §2.1: omission -> interior over-prune -> wrong authoritative serve).
// ---------------------------------------------------------------------------

// Single producer: publish makes the id visible to a snapshot; unpublish removes it.
TEST(ActiveViewRegistry, PublishThenSnapshotThenUnpublish) {
    ActiveViewRegistry<256> reg;
    std::vector<uint64_t> out; uint64_t floor;
    reg.snapshot(out, floor);
    EXPECT_TRUE(out.empty());
    EXPECT_EQ(floor, ActiveViewRegistry<256>::NO_FLOOR);

    reg.publish(42);
    reg.snapshot(out, floor);
    ASSERT_EQ(out.size(), 1u);
    EXPECT_EQ(out[0], 42u);
    EXPECT_EQ(floor, ActiveViewRegistry<256>::NO_FLOOR);

    reg.unpublish();
    reg.snapshot(out, floor);
    EXPECT_TRUE(out.empty());
}

// Many concurrent producers, each holding a distinct view at a barrier: a snapshot taken
// while all are published must contain EVERY one (superset, sorted), with no overflow at K<pool.
TEST(ActiveViewRegistry, AllConcurrentViewsObserved) {
    constexpr int K = 64;
    ActiveViewRegistry<256> reg;
    std::atomic<int> published{0};
    std::atomic<bool> release{false};
    std::vector<std::thread> ts;
    for (int i = 0; i < K; ++i) {
        ts.emplace_back([&, i] {
            reg.publish(uint64_t(i) + 1);                    // ids 1..K (nonzero)
            published.fetch_add(1);
            while (!release.load()) std::this_thread::yield();
            reg.unpublish();
        });
    }
    while (published.load() < K) std::this_thread::yield();   // all K views open
    std::vector<uint64_t> out; uint64_t floor;
    reg.snapshot(out, floor);
    release.store(true);
    for (auto &t : ts) t.join();
    ASSERT_EQ(out.size(), size_t(K));                         // no live view omitted
    for (int i = 0; i < K; ++i) EXPECT_EQ(out[i], uint64_t(i) + 1);
    EXPECT_EQ(floor, ActiveViewRegistry<256>::NO_FLOOR);
}

// Superset invariant under churn (run under ASAN/TSAN): an id that is live for the whole
// duration of a snapshot MUST appear in it. Writers use strictly-increasing per-writer ids,
// so "same live id before and after the snapshot" means it stayed published throughout.
TEST(ActiveViewRegistry, SupersetUnderChurn) {
    ActiveViewRegistry<256> reg;
    std::atomic<bool> stop{false};
    std::atomic<int> mismatches{0};
    constexpr int W = 8;
    std::array<std::atomic<uint64_t>, W> live{};             // each writer's published id (0=none)
    for (int w = 0; w < W; ++w) live[w].store(0);
    std::vector<std::thread> ws;
    for (int w = 0; w < W; ++w) {
        ws.emplace_back([&, w] {
            uint64_t id = uint64_t(w) * 1000000 + 1;
            while (!stop.load(std::memory_order_relaxed)) {
                reg.publish(id);
                live[w].store(id, std::memory_order_release);
                std::this_thread::yield();
                live[w].store(0, std::memory_order_release);
                reg.unpublish();
                id += W;                                     // distinct, monotonically increasing
            }
        });
    }
    for (int iter = 0; iter < 20000; ++iter) {
        std::array<uint64_t, W> before{};
        for (int w = 0; w < W; ++w) before[w] = live[w].load(std::memory_order_acquire);
        std::vector<uint64_t> out; uint64_t floor;
        reg.snapshot(out, floor);
        std::array<uint64_t, W> after{};
        for (int w = 0; w < W; ++w) after[w] = live[w].load(std::memory_order_acquire);
        for (int w = 0; w < W; ++w) {
            if (before[w] != 0 && before[w] == after[w]) {   // live across the whole snapshot
                if (std::find(out.begin(), out.end(), before[w]) == out.end())
                    mismatches.fetch_add(1);
            }
        }
    }
    stop.store(true);
    for (auto &t : ws) t.join();
    EXPECT_EQ(mismatches.load(), 0);                         // no live view ever missed
}

// Slot-pool exhaustion must NOT drop a view: more concurrent views than slots -> the rest go
// to the conservative floor. SUPERSET: every view id is either in the slot snapshot OR covered
// by the floor (floor <= it). Tiny pool (4) with 12 concurrent views forces the overflow path.
TEST(ActiveViewRegistry, OverflowLowersConservativeFloor) {
    constexpr unsigned N = 4;
    ActiveViewRegistry<N> reg;
    constexpr int K = 12;
    std::atomic<int> published{0};
    std::atomic<bool> release{false};
    std::vector<std::thread> ts;
    for (int i = 0; i < K; ++i) {
        ts.emplace_back([&, i] {
            reg.publish(uint64_t(i) + 10);                   // ids 10..21
            published.fetch_add(1);
            while (!release.load()) std::this_thread::yield();
            reg.unpublish();
        });
    }
    while (published.load() < K) std::this_thread::yield();
    std::vector<uint64_t> out; uint64_t floor;
    reg.snapshot(out, floor);
    release.store(true);
    for (auto &t : ts) t.join();
    for (int i = 0; i < K; ++i) {
        uint64_t id = uint64_t(i) + 10;
        bool in_slots = std::find(out.begin(), out.end(), id) != out.end();
        bool covered = (floor != ActiveViewRegistry<N>::NO_FLOOR && floor <= id);
        EXPECT_TRUE(in_slots || covered) << "view " << id << " neither slotted nor floor-covered";
    }
    EXPECT_LE(out.size(), size_t(N));                        // no more than the pool fit in slots
    EXPECT_NE(floor, ActiveViewRegistry<N>::NO_FLOOR);       // overflow happened (K > N)
}
