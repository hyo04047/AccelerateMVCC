# Phase 3 / ④ — CH-benCHmark / TPC-C evaluation (2026-06-30)

> **Result.** On the standard TPC-C dataset under the real TPC-C transaction mix, the cache (1) serves
> **byte-correctly** (construct_BAD=0), (2) its **coverage follows the D8 capacity-sizing law** (held-scan
> HIT 16% → 64% as `kuku_log2` goes 16 → 21), (3) **excludes wide off-page rows** (customer, D6), and (4)
> gives a **MODEST held-analytic serve speedup (~1.3–1.4×)** — because a large-table analytic scan at small
> BP is **base-table-I/O-bound**, so serve's undo-elimination (the source of the q5 ~29× / ⑥ ~190–290× wins)
> is diluted. This honestly delineates the cache's effective regime: the big wins need *undo* I/O to dominate
> (a hot, BP-resident table / hot subset with deep chains), not a cold large-table scan.

## Why CH-benCHmark / TPC-C
CH-benCHmark = TPC-C (OLTP) + TPC-H-derived analytical queries, the standard HTAP benchmark. It maps onto the
cache's target: the TPC-C transaction mix builds version chains / undo, and a held analytical query reads a
deep consistent snapshot over them — exactly the serve path. We use the **lean** harness (per the design
checkpoint): real TPC-C OLTP churn via **sysbench-tpcc** (Percona; github.com/Percona-Lab/sysbench-tpcc) +
the held analytic query in our proven `setsid` profiling harness, so we directly measure serve-vs-walk
latency, `construct_BAD`, and coverage on the standard dataset — rather than BenchBase's throughput mix,
which does not expose our serve-correctness framing.

## Setup
- **Dataset**: TPC-C scale=2 (~920k rows: stock 200k, order_line 599k, customer 60k, orders 60k, + item /
  history / new_order). Composite PKs throughout (stock=(w_id,i_id), order_line 4-col, customer 3-col).
- **Churn**: full TPC-C mix (NewOrder / Payment / Delivery / OrderStatus / StockLevel), 8 threads.
- **Held analytic query**: a REPEATABLE-READ snapshot doing a deep aggregation over **STOCK** (the
  heavily-updated, in-page-eligible table) while the mix churns (no `wait $CH` — concurrent).
- **Sizing knob**: `kuku_log2` made env-overridable (`ACCEL_KUKU_LOG2`, default 16) — a one-line change in
  `accel_hook.cc` (mirrors the wide-row image cap).
- Scripts: `build_q17_tpcc_smoke.sh [scale]` (correctness + coverage, set `KUKU=`) and
  `build_q17_tpcc_latency.sh [N] [scale] [kuku]` (BP-sweep serve speedup; loads TPC-C once into a pristine
  datadir and restores a fresh copy per run so every run starts identical). Logs + CSV in
  `integration/results/q17_tpcc_*`.

## 1. Correctness — construct_BAD=0 on standard TPC-C
mode-2 verify-serve (walk + byte-compare, then serve only if identical) under the TPC-C mix: **every served
answer is byte-identical to the vanilla walk.** At `kuku_log2=21`: served = 160,713, **construct_BAD = 0**.
The composite PKs all key correctly via full-PK FNV. The no-wrong-serve invariant (design-D7) holds on a
standard benchmark, not just sbtest.

## 2. Coverage = capacity-bounded → the D8 sizing law, on a standard benchmark
The cache covers the **admitted** working set; rows beyond the cuckoo capacity fall back to vanilla
(consult `absent`). TPC-C scale=2 has ~920k rows, far above the default `kuku_log2=16` (~43k-key capacity),
so default coverage is low; sizing the cuckoo to the working set raises it:

| `kuku_log2` | capacity (~keys) | consult HIT | absent | ineligible (customer off-page) | construct_BAD |
|---|---|---|---|---|---|
| 16 (default) | 43 k | 40,586 (**15.7%**) | 214,215 | 2,868 | 0 |
| 21 | 1.4 M | 160,713 (**63.5%**) | 79,879 | 12,387 | 0 |

This is the design-D8 claim — "memory ∝ live-transaction working set, *within configured capacity N*; beyond
N, non-admission → vanilla fallback" — **exercised on a standard benchmark**: coverage is a sizing knob
(`kuku_log2 ≥ ceil(log2(hot keys / load factor))`), and correctness is invariant under sizing
(construct_BAD=0 at both). The per-key memory cost is the D8 (B) term (~72 B/key); at `kuku_log2=21` the
~920k-key working set costs ~66 MB of header floor.

## 3. Wide-row scope (D6) — customer is ineligible
TPC-C's `customer.c_data` is ~400 chars (avg 399.7, max 500 — the spec C_DATA) stored off-page; the
off-page-LOB capture gate (`rec_offs_any_extern`) excludes those rows → `img_len=0` → consult MISS_INELIGIBLE
→ vanilla. At `kuku_log2=21` the customer keys are admitted and reach the eligibility gate, surfacing as
ineligible = 12,387. The design-D6 in-page-row scope limit fires on real TPC-C — honest, and safe
(construct_BAD=0).

## 4. Latency — modest serve speedup (~1.3–1.4×), and WHY
Held STOCK deep read, vanilla walk (mode 0) vs serve (mode 1), `kuku_log2=21` (~64% HIT), GC off, N=3:

| BP | vanilla median | serve median | speedup | phys reads (m0 / m1) |
|---|---|---|---|---|
| 4G (resident) | 0.322 s | 0.253 s | **1.3×** | ~4.3 k / ~4.4 k |
| 64M (small) | 1.272 s | 0.899 s | **1.4×** | ~248 k / ~245 k |

construct_BAD = 0 in all 12 runs. The speedup is far below sbtest (q5 ~29× I/O-bound, ⑥ ~190–290×). **The
physical-reads column shows why:** at 64M, mode-0 and mode-1 have ~the **same** physical reads (~245 k) —
unlike q5, where serve cut undo reads 25 k → 450. On a large TPC-C table, the analytic scan's **base-table
page I/O** (stock 200k rows ≫ 64M BP) dominates; serve eliminates the **undo reconstruction** (CPU + undo I/O)
for the ~64% HIT rows but **cannot remove the base-table I/O floor**. So the gain here is mostly the
version-reconstruction CPU saved — visible even at 4G resident (1.3×, where there is no I/O at all) — not the
undo-I/O-cliff elimination.

**The honest regime delineation (the real finding).** The cache's large wins (q5 ~29×, ⑥ ~190–290×) require
the **undo** reconstruction / undo-I/O to be the bottleneck: a hot, small (BP-resident) table or a hot subset
with deep version chains under a long held snapshot. A **cold, large-table** analytic scan at small BP is
**base-table-I/O-bound**, where the cache gives a modest reconstruction-CPU gain (~1.3–1.4×) while staying
byte-correct. TPC-C's large-table scans land in the latter regime; the project's headline HTAP scenario (a
held analytic reader over a hot working set) lands in the former. This is a scope boundary, not a defect —
and it is exactly the kind of honest delineation that keeps the headline claims credible.

## What ④ adds to the evaluation
- The serve correctness (construct_BAD=0) and the two scope laws (D8 capacity-sizing, D6 wide-row) are now
  demonstrated on a **standard, multi-table, insert/delete-heavy HTAP benchmark**, not only sbtest.
- The latency result bounds the cache's effective regime honestly: it is an *undo-reconstruction* accelerator,
  largest when undo I/O dominates; on base-I/O-bound large-table scans the gain is modest but correct.

## Reproduction
1. `git clone https://github.com/Percona-Lab/sysbench-tpcc ~/sysbench-tpcc` (run sysbench from that dir — its
   `require("tpcc_common")` needs the dir as cwd).
2. `build_q17_tpcc_smoke.sh 2` with `KUKU=16` then `KUKU=21` → correctness (construct_BAD=0) + the coverage
   table. `build_q17_tpcc_latency.sh 3 2 21` → the BP-sweep serve speedup. mysqld must be rebuilt with the
   `ACCEL_KUKU_LOG2` change (incremental: copy `accel_hook.cc` to `storage/innobase/accel/`, rebuild target
   mysqld). Raw logs + CSVs land in `integration/results/q17_tpcc_*`.
