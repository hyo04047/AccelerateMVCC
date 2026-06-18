// Unit tests for the marked-pointer (Harris) helper. Stage 1b Increment 0:
// the helper is tested in isolation; it is not yet wired into any list.
// Run under ASan to confirm the tag/untag pointer arithmetic is clean.
#include <gtest/gtest.h>
#include <cstdint>
#include "include/marked_ptr.h"

// Real node types, included ONLY to assert their alignment leaves the low bit
// free (the whole scheme is UB otherwise). interval_list.h -> epoch_node,
// epoch_table.h -> epoch_node_wrapper. Both are kuku-free, header-only structs.
#include "include/interval_list.h"
#include "include/epoch_table.h"

using namespace mvcc;

// The load-bearing assumption behind packing a mark into the low bit.
static_assert(alignof(epoch_node) >= 2,
              "epoch_node must be >=2 aligned for the mark bit to be free");
static_assert(alignof(epoch_node_wrapper) >= 2,
              "epoch_node_wrapper must be >=2 aligned for the mark bit to be free");

namespace { struct alignas(8) Dummy { int x; }; }

TEST(MarkedPtr, PackUnpackRoundTrip) {
    Dummy d{};
    uintptr_t unmarked = MarkedPtr<Dummy>::pack(&d, false);
    uintptr_t marked   = MarkedPtr<Dummy>::pack(&d, true);
    EXPECT_EQ(MarkedPtr<Dummy>::ptr_of(unmarked), &d);
    EXPECT_FALSE(MarkedPtr<Dummy>::mark_of(unmarked));
    EXPECT_EQ(MarkedPtr<Dummy>::ptr_of(marked), &d);   // mark does not corrupt the pointer
    EXPECT_TRUE(MarkedPtr<Dummy>::mark_of(marked));
    EXPECT_EQ(MarkedPtr<Dummy>::ptr_of(MarkedPtr<Dummy>::pack(nullptr, true)), nullptr);
}

TEST(MarkedPtr, StoreLoad) {
    Dummy a{}, b{};
    MarkedPtr<Dummy> mp(&a);
    EXPECT_EQ(mp.ptr(), &a);
    EXPECT_FALSE(mp.marked());
    mp.store(&b, true);
    EXPECT_EQ(mp.ptr(), &b);
    EXPECT_TRUE(mp.marked());
}

TEST(MarkedPtr, CasSucceedsThenFailsOnStale) {
    Dummy a{}, b{}, c{};
    MarkedPtr<Dummy> mp(&a);
    uintptr_t expected = mp.load();
    EXPECT_TRUE(mp.cas(expected, MarkedPtr<Dummy>::pack(&b, false)));  // a -> b
    EXPECT_EQ(mp.ptr(), &b);

    uintptr_t stale = MarkedPtr<Dummy>::pack(&a, false);               // now stale
    EXPECT_FALSE(mp.cas(stale, MarkedPtr<Dummy>::pack(&c, false)));    // must fail
    EXPECT_EQ(stale, mp.load());                                      // expected updated to current
    EXPECT_EQ(mp.ptr(), &b);                                          // unchanged
}

TEST(MarkedPtr, SetMarkLogicalDelete) {
    Dummy a{}, b{};
    MarkedPtr<Dummy> mp(&a);
    EXPECT_TRUE(mp.set_mark(&a));      // logical delete succeeds
    EXPECT_TRUE(mp.marked());
    EXPECT_EQ(mp.ptr(), &a);           // pointer preserved, only mark set

    EXPECT_FALSE(mp.set_mark(&a));     // already marked -> fails (expected <a,false> no longer matches)

    MarkedPtr<Dummy> mp2(&a);
    EXPECT_FALSE(mp2.set_mark(&b));    // wrong expected pointer -> fails
    EXPECT_FALSE(mp2.marked());
}
