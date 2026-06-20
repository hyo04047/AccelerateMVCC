// Licensed under the MIT license.
//
// Standalone stress test for the bounded MPMC ring (integration/innodb/accel_ring.h), the
// lock-free primitive behind the Stage D populate hook. 8 producers + 1 consumer, with a
// torn-read detector (each record's fields encode a relationship the consumer re-checks) and a
// deliberately small ring so the full -> drop path is exercised. Built kuku-free so it runs fast
// under ASan/TSan (isolate-then-integrate, like ebr_test / marked_ptr_test).
//
// PASS iff: every enqueued record was dequeued (enq == deq), accounting holds
// (enq + dropped == producers*per), and no torn read was ever observed.

#include "integration/innodb/accel_ring.h"

#include <atomic>
#include <cstdio>
#include <thread>
#include <vector>

using accel::Ring;
using accel::UndoRec;

static Ring<1024> g_ring;  // small on purpose -> forces drops under 8 producers

static UndoRec make_rec(uint64_t v) {
  // Encode relationships so the consumer can detect a torn (partially-published) read.
  return UndoRec{/*table_id*/ ~v, /*pk_hash*/ v * 2654435761u + 1, /*trx_id*/ v,
                 /*old_trx_id*/ v ^ 0xA5A5A5A5A5A5A5A5ULL, /*space_id*/ v + 7,
                 /*page_no*/ v + 11, /*offset*/ v + 13, /*op_type*/ 2};
}
static bool check_rec(const UndoRec &r) {
  uint64_t v = r.trx_id;
  return r.table_id == ~v && r.pk_hash == v * 2654435761u + 1 &&
         r.old_trx_id == (v ^ 0xA5A5A5A5A5A5A5A5ULL) && r.space_id == v + 7 &&
         r.page_no == v + 11 && r.offset == v + 13 && r.op_type == 2;
}

int main() {
  const int P = 8;
  const long PER = 300000;
  std::atomic<long> enq{0}, dropped{0}, deq{0}, torn{0};
  std::atomic<bool> done{false};

  std::thread consumer([&] {
    UndoRec r;
    auto drain = [&] {
      while (g_ring.dequeue(r)) {
        if (!check_rec(r)) torn.fetch_add(1, std::memory_order_relaxed);
        deq.fetch_add(1, std::memory_order_relaxed);
      }
    };
    while (!done.load(std::memory_order_acquire)) {
      drain();
      std::this_thread::yield();
    }
    drain();  // final drain after producers finished
  });

  std::vector<std::thread> ps;
  for (int p = 0; p < P; ++p) {
    ps.emplace_back([&, p] {
      for (long i = 0; i < PER; ++i) {
        uint64_t v = (uint64_t)p * PER + (uint64_t)i + 1;
        if (g_ring.enqueue(make_rec(v)))
          enq.fetch_add(1, std::memory_order_relaxed);
        else
          dropped.fetch_add(1, std::memory_order_relaxed);
      }
    });
  }
  for (auto &t : ps) t.join();
  done.store(true, std::memory_order_release);
  consumer.join();

  long total = (long)P * PER;
  std::printf("enq=%ld dropped=%ld deq=%ld torn=%ld total=%ld\n", enq.load(), dropped.load(),
              deq.load(), torn.load(), total);
  bool ok = (enq.load() == deq.load()) && (enq.load() + dropped.load() == total) &&
            (torn.load() == 0) && (dropped.load() > 0);  // expect SOME drops with a 1024 ring
  std::printf("%s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
