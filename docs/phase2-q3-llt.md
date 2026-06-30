# Phase 2 / ⓠ3 — does the in-middle reclaim headline survive in REAL InnoDB? (2026-06-28)

> **Result: YES.** Under write-heavy OLTP + a held LLT + concurrent HTAP readers, the integrated
> AccelerateMVCC cache stays **bounded** (≈ the active-view working set) while InnoDB's retention
> (History List Length) grows **linearly** with the LLT window. The memory ratio scales with LLT age:
> **~20× / 40× / 63×** at 15 / 30 / 60 s, and keeps growing. The project's central claim — that the
> deadzone's in-middle reclaim beats InnoDB's tail-only purge under a long-lived transaction — **holds in
> real InnoDB**, not just the standalone prototype. The pre-authorized 5-3 retreat is NOT triggered.

## ⚠️ Measurement caveats (read before citing any number — Phase-3 hardens these)
- **Every number below is a SINGLE run — no variance / error bars.** Before any of these enters the paper,
  re-run headline configs N≥3–5 and report median + min/max. This matters most for ⑥ (the held-read latency
  payoff), which is **known non-deterministic** (3/4 hold ~190×, 1/4 degrades to the correct walk under a
  small-BP reclaim storm — design-D5-gc §12.2). The drain-cap "X/N degrade" table already has this discipline;
  the rest does not yet. **[⑥ gate ① DONE 2026-06-30]** ⑥ now HAS multi-run error bars — see the *Phase 3 /
  gate ① — ⑥ multi-run* section at the bottom (64M serve median 0.45 s ≈ 290×, 2/8 degrade to the correct
  walk, construct_BAD=0 in all 18 runs). The ⓠ3 / ⓠ5 numbers in THIS doc are still single-run.
- **Raw run logs were not retained** (overwritten per run; only the ASan log survives). Phase 3 must archive
  the `[accel] retention:`/`consult:` lines into `integration/results/` so each table cell is verifiable.
  **[gate ② — ⑥/q11 DONE]** the q11 multi-run archives every per-run mysqld/scan/churn log + `q11_d6.csv`
  into `integration/results/`; the ⓠ3 retention logs remain to be archived on a re-run.
- **Regime differences between sections are real, not interchangeable:** ⓠ3 is GC-ON retention; ⓠ5 is a
  GC-OFF, cross-boot A/B (mode-0 vs mode-1 are separate server instances) at a different BP. Don't compare the
  ⓠ3 ratios to the ⓠ5 ~34× as if one scale.
- **ASan ran `detect_leaks=0`** — it validates UAF/overflow/SEGV, says nothing about leaks/bounded-memory.
- **"Held reader chain stays flat ~80–92"** is the reporter's sampled epoch-depth (a read-cost PROXY), not a
  measured held-read latency; the actual latency payoff is the separately-measured ⑥. The chain `max` column
  also under-samples ~1/3 of keys (1024 pk buckets vs ~1000 keys collide) — it is a lower bound, and does NOT
  affect the headline ratio (that uses a global counter, bucket-independent).
- **`ACCEL_RETENTION_CAP` default 512** (0 = unbounded) — load-bearing for reproduction: it bounds the
  reporter's per-key chain walk so a tail-only run's huge chains don't steal CPU and confound throughput.

## The question (open-items ⓠ3 / §0)
The headline (standalone Stage C: deadzone hot-chain max 155 vs tail-only 845,977 ≈ 5500× under a 60 s LLT)
was measured in the prototype, where the "tail-only" baseline is **self-modeled inside the cache**
(`set_gc_tail_only`). ⓠ3 asks whether that in-middle advantage survives in REAL InnoDB under a realistic
write-heavy OLTP + LLT profile — or whether the in-middle hole density is too low to matter, collapsing the
cache toward tail-only (the 5-3 pre-authorized retreat: "drop the LLT chain-length claim, fall back to the
⑥ read-latency payoff").

## The mechanism (what we learned)
In-middle reclaim = the GC reclaims version intervals that fall in the **gaps between consecutive active
read-view cuts** (`generate_dead_zone_from_cuts`). The single biggest gap is between an **old LLT** (low
begin id, pins the purge floor) and the **recent readers** (high begin ids). Versions in that gap are dead
(no active view needs them) and reclaimed, even though they are NEWER than the purge floor — which is
exactly what InnoDB's tail-only purge CANNOT touch (it is stalled at the floor by the LLT).

**So the win is gated on the HTAP gap structure: it needs concurrent read-view-holding readers.** A pure
write-churn + LLT workload (no readers) has only one cut (the LLT) → no gap above the floor → the GC
behaves tail-only → no win. This is confirmed by the readers=0 control below (0.9×).

## Instrumentation added (read-only, env-gated, behavior-neutral)
- **Retention reporter** (`accel_hook.cc`, env `ACCEL_RETENTION_MS`): a separate leaf-domain thread that,
  while a held LLT still pins everything, logs `[accel] retention:` — the shutdown dump is post-LLT-release
  (after GC reclaimed it all) and reads ~empty. Samples every occupied pk bucket's representative key
  (unbiased over hot+cold), each chain walk bounded by `ACCEL_RETENTION_CAP` (so a tail-only run's huge
  chains cannot steal CPU and confound the measurement).
- **`entries_retired` counter** (`epoch_table.h`): counts undo_entry_nodes (= VERSIONS) freed, so
  `live_versions = drained − entries_retired` is a clean **version-unit** count directly comparable to
  InnoDB's History List Length. (The earlier `drained − epochs_retired` mixed versions with EPOCH nodes —
  ~100 versions batch into one epoch — which made the cache look like it retained ~0.5× HLL when it was
  actually ~63× smaller. A unit-confusion artifact, now fixed.)
- **`ACCEL_TAIL_ONLY`** toggle (forwards to `set_gc_tail_only`): an in-process tail-only baseline. See the
  confound note below — it is NOT used for the headline.

## Data

### Pinned hot-set (table-size=10, concentrated chains), 256M BP, deadzone GC, 8 writers + 8 readers
| LLT | InnoDB HLL (versions) | cache live_versions | ratio | chain depth (epochs) |
|---|---|---|---|---|
| 15 s | 60,506 | 5,983 | **10.1×** | 87 |
| 30 s | 126,018 | 6,012 | **21.0×** | 88 |
| 60 s | 251,305 | 6,005 | **41.8×** | 91 |

### Realistic full-table (table-size=1000, pareto), 256M BP, deadzone GC, 8 writers + 8 readers
| | InnoDB HLL | cache live_versions | ratio | chain max (epochs) |
|---|---|---|---|---|
| **readers=0 control** | 696,755 | 743,036 | **0.9× (no win)** | ≥2000 (capped) |
| readers=8, 15 s | 130,570 | 6,409 | **20.4×** | 81 |
| readers=8, 30 s | 278,914 | 7,086 | **39.4×** | 81 |
| readers=8, 60 s | 573,483 | 9,043 | **63.4×** | 92 |

**Reading the data:**
- cache `live_versions` is **bounded** (~6–9 k) and roughly flat in LLT; InnoDB HLL grows **linearly**
  (60 k → 251 k pinned; 130 k → 573 k realistic). The ratio therefore grows ~linearly with LLT age. The
  spread workload generates more versions (less single-row lock contention → higher OLTP rate), so its
  ratio is even larger (63× at 60 s).
- The held reader's chain depth in the cache stays flat (~80–92 epochs) — the read-cost side of the win,
  consistent with the previously-measured ⑥ read-latency payoff (~190×).
- **readers=0 control = 0.9×, chain ≥2000** — with no HTAP gap there is no in-middle reclaim and the cache
  tracks InnoDB. The win is entirely the gap.
- This is the ⑤ "memory ∝ live-txn window, not dataset / not retained history" property, now demonstrated
  in integration.

## Magnitude vs the prototype's 5500×
The prototype's 5500× was a 60 s **in-memory microbench** with a very high version-generation rate (no real
InnoDB OLTP overhead). Here the rate is set by real InnoDB OLTP (~4,200 committed versions/s), so 60 s
yields ~573 k retained versions → ~63×. Same mechanism, same linear-in-LLT scaling, same gap requirement —
just an honest real-InnoDB rate. The win is unbounded in LLT duration (cache stays flat).

## Side finding — the in-process tail-only cache mode confounds throughput (do not use as baseline)
Running the cache in `ACCEL_TAIL_ONLY=1` mode makes InnoDB throughput ~5× lower at matched wall-clock
(clock/work 568 k vs 115 k at 30 s), and the effect GROWS over time (3.3× at 15 s → 6.9× at 60 s). Ruled
out as a reporter artifact (reporter on/off gave identical 117 k vs 115 k). Likely the tail-only GC
re-scanning its never-reclaimed (growing) live set each cycle and stealing CPU. Because it changes the
throughput (and thus HLL), the in-process tail-only mode is unsuitable as an apples-to-apples baseline —
**real InnoDB purge IS the honest tail-only baseline** (it runs at full speed, no cache-mode confound), so
all headline ratios above compare deadzone-cache vs real InnoDB HLL in the SAME run.

## Reproduction
- `integration/scripts/build_q3_pinned.sh` — pinned hot-set sweep (table-size=10).
- `integration/scripts/build_q3_realistic.sh` — realistic full-table sweep + readers=0 control.
- Runtime toggles: `ACCEL_GC=1 ACCEL_RETENTION_MS=1000 ACCEL_RETENTION_CAP=<n>` (+ `ACCEL_TAIL_ONLY=1`
  only for the confound demonstration). Read `[accel] retention:` lines from the mysqld log; pair with
  `SHOW ENGINE INNODB STATUS` History List Length sampled near the LLT peak.

---

# Phase 2 / ⓠ5 — the "22% MISS effective speedup" worry (2026-06-28)

> **Result: resolved, positively.** The held analytic reader — the cache's actual target — HITs ~99.8–100%
> even on a write-heavy churn that does delete+reinsert (the MISS-generating pattern). The old "78% HIT /
> 22% MISS" figure was a workload-WIDE consult rate dominated by SHORT readers near the chain head, which
> do not need the cache (already fast; their MISS just means a cheap vanilla read at the head). The
> effective speedup on the deep reader is ~3× resident (CPU-bound) and **~34× I/O-bound (64M BP)**, with
> undo I/O eliminated, and construct_BAD=0 throughout.

## Method
⑥-style held-snapshot deep read, but churn = `oltp_write_only` (fast deep chains -> reaches the I/O-bound
regime, AND its delete+insert produces the cross-generation rows the worry is about). Held reader does the
deep `SUM` over the table; mode 0 = vanilla walk, mode 1 = serve (the MISS rows still walk). GC off (isolate
the MISS effect from the ⑥ chain-sever). `integration/scripts/build_q5_writeonly.sh`.

## Data (oltp_write_only churn, held deep reader, GC off)
| BP | mode-0 vanilla | mode-1 serve | speedup | physical reads (m0→m1) | consult HIT% | construct_BAD |
|---|---|---|---|---|---|---|
| 4G | 0.263 s | 0.089 s | ~2.9× | 0 → 0 (resident) | 99.8% | 0 |
| 256M | 0.288 s | 0.085 s | ~3.4× | 0 → 0 (resident) | 100% | 0 |
| **64M** | **2.673 s** | **0.078 s** | **~34×** | **23,783 → 352** | 99.8% | 0 |

## Reading it
- **The held reader HITs ~100%** because its consistent snapshot predates the churn: it needs each row's
  ORIGINAL version (cached), not the new generations that delete+reinsert creates. The 22% MISS was about
  short readers near the head — a different population the cache isn't for. (Workload-wide oltp_read_write
  HIT is also up to ~94% post the session-8 lineage-walk fixes, from 78%.)
- **Effective speedup**: resident regime ~3× (the cache avoids the version-reconstruction CPU even with no
  I/O); I/O-bound regime (64M) **~34×** with undo page reads cut 23,783 → 352. Smaller than the pure-write
  ⑥ 775× only because oltp_write_only accrues fewer versions in 44 s (HLL ~80k vs millions) — same
  mechanism, a longer LLT deepens it further.
- construct_BAD=0 at every BP — the 22% (now ~0.2%) MISS rows fall back to the correct vanilla walk; never a
  wrong row.

---

# Phase 2 / ⓝ6 — LOB / off-page / virtual / >512B coverage + safety (2026-06-28)

> **Result: coverage collapses to ~0 on these rows, but it is 100% SAFE.** Rows with an off-page (external)
> column, a virtual column, or a physical record over the 512-byte image cap are excluded at capture
> (`img_len=0`) and consult returns `MISS_INELIGIBLE` -> the held reader does the correct vanilla walk.
> construct_BAD=0 in every variant — never a wrong or partial-image serve. This is an honest, scoped
> limitation: the cache targets small-row (INT/CHAR) OLTP — where the ⓠ3/⑥ wins live — and gives no benefit
> on LOB/text-heavy HTAP (but no harm). It is consistent with the compact-cache design (it stores small
> images/metadata, never MB-scale LOB).

## The exclusion gate
At capture (`storage/innobase/trx/trx0rec.cc`):
`accel_img_len = (rec_offs_any_extern(offsets) || index->table->n_v_cols > 0) ? 0 : rec_offs_size(offsets)`,
and the hook drops the image if it exceeds `ACCEL_IMG_MAX = 512`. So off-page LOB, virtual-column, and
oversized rows all land with `img_len=0` -> stored locator-only -> `MISS_INELIGIBLE` -> vanilla walk. Serve
is double-gated on `n_v_cols == 0`.

## Data (64M BP, GC off; mode 1 for big/small, mode 2 verify-serve for lob/virtual)
| variant | consult HIT | MISS_INELIGIBLE | construct_BAD | served | vanilla deep read |
|---|---|---|---|---|---|
| small control (sbtest) | 1000 (100%) | 0 | 0 | 1000 | 0.37 s |
| big in-page (>512B, 1698 B/row) | 0 | 1000 (100%) | 0 | 0 | 82.7 s |
| off-page LOB (LONGTEXT 20 KB) | 0 | 1000 (100%) | 0 | 0 | — |
| virtual column (`AS (k*2) VIRTUAL`) | 0 | 1000 (100%) | 0 | 0 | — |

## Reading it
- **What the safety evidence actually is** (avoid a hollow gate): for the excluded rows, `construct_BAD=0`
  is *vacuous* (served=0 → nothing was checked). The load-bearing evidence is the pair (a) **the exclusion
  fired** — `MISS_INELIGIBLE = 100%` on every excluded variant, so the gate, not luck, kept these out of the
  serve path; and (b) **the small-row control serves correctly** — `HIT 100%, construct_BAD=0` with served>0,
  proving the serve path itself is byte-correct. Together: the gate excludes the unservable rows AND the
  servable rows serve right.
- The **off-page LOB** case is the subtle one: its main clustered record (with a ~20-byte LOB pointer) can be
  < 512 B, so WITHOUT the `rec_offs_any_extern` gate the cache would capture a partial image and could serve a
  row missing its LOB. The gate prevents it — 100% ineligible.
- The irony: the big-row vanilla deep read is 82.7 s (bigger rows -> bigger undo -> more I/O) — exactly where
  a cache would help most — but the 512 B cap excludes it. So LOB-heavy HTAP is the one regime the cache
  cannot accelerate. Honest paper Limitation.
- Future work (optional): a configurable cap, or caching the in-page prefix + a locator for the off-page
  part. Full-LOB caching contradicts the compact-cache design and is not planned.

---

# Phase 2 / correctness breadth — composite PK, string PK, secondary-index, savepoint (2026-06-28)

> **Result: all safe (construct_BAD=0).** The cache was validated only on a single INT PK; here it
> generalizes — a 2-column composite PK, a VARCHAR string PK, and secondary-index-driven reads all HIT 100%
> and serve byte-correct. Savepoint rollback (a partial rollback whose undone version was never committed but
> WAS captured) never produces a false-HIT — consult either finds the correct version or conservatively
> MISSes (noncontig) to the vanilla walk. mode-2 verify-serve, 4G resident, GC off.

## Composite / string PK + secondary-index (light config: correctness, not latency)
| variant | consult HIT | construct_BAD | served |
|---|---|---|---|
| composite PK `(a,b)` + secondary-index read (`FORCE INDEX`) | 2000 (100%) | 0 | 2000 |
| string PK `VARCHAR(40)` | 1000 (100%) | 0 | 1000 |

The cache keys on FNV(full-PK bytes) from the first `n_unique` fields, so multi-column and string PKs are
captured and matched correctly. Secondary-index reads hit the same consult — the MVCC walk happens on the
clustered record regardless of access path. (Repro `integration/scripts/build_q7_keys.sh`.)

## Savepoint rollback (ⓝ15)
Churn = txns that commit a `+1` to one row but `ROLLBACK TO SAVEPOINT` a `+1000` to another. Ground truth
after churn: `MAX(k)=916, rows_with_leak=0` — every `+1000` was rolled back (never committed). Held reader:
snapshot-invariant (`MAX(k)=0 < 1000`, no rolled-back value visible). consult: **construct_BAD=0** (hit=491,
noncontig MISS=509, served=491) — the rolled-back versions, captured before the rollback, are NEVER served:
consult either serves the correct committed version or, where the savepoint structure breaks contiguity,
conservatively MISSes to the vanilla walk. ~50% MISS is a coverage cost on savepoint-heavy txns; correctness
is preserved. (Repro `integration/scripts/build_q8_savepoint.sh`.)

## Methodology note (latency vs correctness configs)
A correctness check (construct_BAD=0) needs neither deep chains nor a small BP — run it RESIDENT (4G) with a
short churn so the held deep read is fast. A composite-PK + secondary-index deep read at 64M with a long
churn is pathologically slow (the FORCE INDEX scan walks every row's deep chain via the secondary index,
×2 under mode-2) and is the wrong tool for a correctness gate. Reserve small-BP / deep-churn for explicit
latency measurements (ⓠ3/ⓠ5/⑥).

---

# Phase 2 / ⓝ5 — full-mysqld AddressSanitizer (2026-06-28)

> **Result: CLEAN.** A mysqld built with `-DWITH_ASAN=ON` (15 min) ran the full integration path —
> hook-under-latch ‖ off-latch drainer ‖ consult ‖ a held analytic reader (serve) ‖ deadzone GC ‖ clean
> teardown — under concurrent oltp_read_write + oltp_read_only churn, and the server log had **zero
> AddressSanitizer reports** (no use-after-free, heap-buffer-overflow, or SEGV). Until now all sanitizer
> evidence was standalone only; this is the gold-standard integration check.

## Method
`integration/scripts/build_q9_asan.sh`: configure + build the ASan mysqld in a separate dir, then boot it
with `ACCEL_GC=1 ACCEL_AUTHORITATIVE=2` (GC on + verify-serve, so consult/serve/walk-compare/drainer/GC are
all live), run an 8-thread oltp_read_write + 4-thread oltp_read_only churn plus a held reader doing repeated
deep reads, then `SHUTDOWN` (exercising teardown vs in-flight consult/GC/drainer). `ASAN_OPTIONS` had
`detect_leaks=0` (the dummy-overflow list leaks by design, docs ⓣ18 — focus ASan on the correctness-critical
UAF / overflow class). The mysql client reused the existing non-ASan build (protocol-compatible).

## Evidence the gate was not hollow
The run did real work under ASan: consult calls=251,150, hit=243,803, **construct_BAD=0** (byte-correct
serves under ASan), served=243,803; GC retired 9,114 (windowed 8,716 + dummy 398), live_buckets bounded;
clean shutdown. So the drainer, consult, serve, GC, and teardown all executed under ASan and the integration
path is memory-clean.

**Both serve modes ASan-clean.** The run above is mode-2 (verify-serve). The actual SHIP path is mode-1
(serve-only, walk-skip) — re-run separately under ASan with `ACCEL_AUTHORITATIVE=1 ACCEL_AUDIT_N=512`: served
183,591, the 1-in-N **walk-audit tripwire fired** (audited=359, bad=0), the gen-gate fired (gcrace=7 →
conservative MISS), construct_BAD=0, **and zero ASan reports**. So the production serve path + its in-run
self-check are both memory-clean, not just the verify-serve diagnostic path.

## TSan
Full-mysqld TSan is a documented residual: the standalone TSan already exercises the accel race surface
(drainer ‖ consult ‖ cuts-GC, the same structure — single-producer enqueue-under-latch, single-consumer
drainer, read-only EBR-guarded consult), and MySQL-under-TSan needs the upstream suppression file and a
5–10× slowdown for low marginal value over the standalone result.

---

# Phase 2 / ⓝ9 — cold-key footprint: measured, and the overflow "blow-up" fixed (2026-06-29)

> **Result: the cache footprint is BOUNDED, and exceeding the cuckoo table's capacity now degrades
> GRACEFULLY (it used to churn/crash).** A per-key `headers_created` counter shows the cold-key footprint =
> the number of distinct keys ever admitted (an `interval_list_header` + Kuku slot per key, ~72 B, never
> freed). Below the cuckoo capacity it plateaus at the touched key set while the GC keeps live VERSIONS
> bounded; above capacity, a new graceful non-admission path caps it cleanly instead of leaking unboundedly.

## What we measured (new `headers` / `dropped` / `versions_dropped` counters)
- **Below capacity (40k-key table, GC on, uniform):** `headers` rises to **40,534 and PLATEAUS** (= distinct
  keys touched, never more); `live_versions` holds at **~42k** (GC-bounded) while `drained` reaches 2.8 M. So
  for a fixed key set the cache is bounded on BOTH axes — versions (GC) and headers (= the key set).
- **The cold-key footprint is small + capacity-bounded:** ~72 B/key × (≤ cuckoo capacity). It is NOT the
  version memory (GC bounds that); it is the per-key header that is never reclaimed.

## The real limit found + fixed: cuckoo capacity + graceful non-admission
The integration sizes Kuku at `kuku_log2 = 16` (65,536 bins, 2 hash funcs). A 200k-key table exceeds it:
- **Before:** a failed cuckoo insert leaked the just-`new`'d header AND re-fired on every later update of that
  key → **unbounded churn** (`headers` → **2.6 M** for a 200k-key table) + corruption. (A naive "free the
  header on insert-failure" fix CRASHED — a failed cuckoo path may have already published the header pointer
  into a slot, so deleting it dangles that slot = UAF.)
- **After (graceful non-admission, `accelerateMVCC.cpp`):** once an insert fails, set `kuku_full_` and admit
  no more keys; skip them cheaply (free only the version node, never the header — UAF-safe) so the uncached
  key falls back to the InnoDB vanilla walk. **Measured (200k-key table):** `headers` plateaus at **43,432**
  (cuckoo effective capacity ≈ 0.66 load), `live_versions` bounded at **~43,800**, `dropped` (uncached
  fallback) grows to **1.75 M** (≈ 77% of updates — keys beyond capacity), **construct_BAD = 0** (admitted
  keys serve correctly; non-admitted MISS → vanilla), **no crash**. (`versions_dropped` is subtracted from
  `live_versions` so the uncached fallback traffic — in `drained` but freed immediately — doesn't inflate it.)
  Standalone 40 green + ASan/TSan (the change is behaviour-neutral below capacity, which standalone never
  exceeds). Repro `integration/scripts/build_q3_realistic.sh`-style with a >`kuku_log2` table + `ACCEL_GC=1`.

## Honest claim + what remains
- **"memory ∝ live working set"** is now defensible *within the cuckoo capacity*: live versions are GC-bounded
  and headers are bounded by the admitted key set (≤ ~0.66 × 2^`kuku_log2`). Size `kuku_log2` ≥ the hot
  working set.
- **Deferred (decided with the user): true cold-key EVICTION.** The cache still has no LRU — once full it
  keeps the first-come keys and falls back the rest (no admission of newer hot keys until restart). Freeing
  cold headers + Kuku slots under lock-free readers is a real concurrency feature (Kuku erase + EBR, UAF
  risk) and is scoped as its own stage. The graceful fix removes the "blow-up"; eviction would let the cache
  track a *shifting* working set within a fixed capacity.

## What this closes / what remains
- **Closes ⓠ3** (the central 5-3 retreat worry): the in-middle headline survives in real InnoDB and scales
  with LLT, given the HTAP gap.
- **Closes ⓠ5**: the held reader's coverage is ~complete on small-row OLTP; effective speedup ~34× I/O-bound
  and correct. The MISS worry was a misframing (short readers the cache doesn't target).
- **Closes ⓝ6**: LOB/off-page/virtual/>512B rows are safely excluded (construct_BAD=0); coverage collapses
  on LOB-heavy but degrades gracefully to vanilla. Documented Limitation; cache scope = small-row OLTP.
- **Closes composite-PK / string-PK / secondary-index (part of ⓝ4) + savepoint (ⓝ15)**: all construct_BAD=0;
  the cache generalizes past single-INT-PK and degrades safely on savepoint complexity.
- **Closes ⓝ5 (ASan)**: full-mysqld integration path is AddressSanitizer-clean; full-mysqld TSan is a
  documented residual (standalone TSan covers the accel race surface).
- **Phase 2 essentially complete.** Next: Phase 3 (paper — Korean + English — incl. the ⓝ6 Limitation and
  the TSan residual; multi-run/error-bars; patch vendoring).

---

# Phase 3 / gate ① — ⑥ held-read serve payoff, MULTI-RUN error bars (2026-06-30)

> **Result: the ⑥ payoff is real but non-deterministic at small BP — now quantified with N runs instead of
> one.** Re-running the SHIP-setting held-read serve (mode-1 serve-only, GC on, `ACCEL_DRAIN_CAP=1000`)
> replaces the single-run "~775×/190×" headline with **median + min/max + a degrade rate**. At 64M the serve
> holds at ~0.45 s in **6/8 runs (~290× over the ~132 s vanilla walk)** and degrades to the correct vanilla
> walk in **2/8 runs** (chain-sever → consult MISS → walk). At 4G (resident) serve is ~0.46 s vs ~1.1 s
> vanilla (**~2.4×**), no degrade. **construct_BAD=0 in all 18 runs** — every degrade is perf-only, never a
> wrong row.

## Setup
`integration/scripts/build_q11_d6_multirun.sh [N]` re-runs the `build_d5_d6_gc.sh` harness fresh-boot N times
at the SHIP setting (mode-1 serve, GC on, drain-cap 1000 = the ⑥ stabilizer, design-D5-gc §13.2). Each run:
fresh-init mysqld → sysbench prepare (1 table × 1000 rows) → a held REPEATABLE-READ snapshot does a warm SUM,
then SLEEP(48) while 8-thread `oltp_update_non_index` churns 44 s, then the measured deep SUM. mode-0 = vanilla
walk baseline; mode-1 = serve. 16 runs total: 64M vanilla×3 + serve×8, 4G vanilla×2 + serve×3. Per-run
mysqld/scan/churn logs + `q11_d6.csv` (one row/run) + `q11_d6_run.log` land in `integration/results/` (gate ②).

## Data (latency s; construct_BAD; physical reads)
| config | median | min – max | n | degrade | physical reads |
|---|---|---|---|---|---|
| 64M vanilla walk | 132.1 | 102.5 – 133.4 | 3 | (baseline) | ~1.1–1.5 M |
| **64M serve (headline)** | **0.454** | 0.379 – 121.2 | 8 | **2/8** | ~4,000 (degrade run: ~1.0–1.4 M) |
| 4G vanilla walk | 1.106 | 1.102 – 1.109 | 2 | 0 | 0 (resident) |
| 4G serve | 0.462 | 0.411 – 0.553 | 3 | 0 | 0 (resident) |

**construct_BAD = 0 in every one of the 18 rows.**

## Reading it
- **Headline (64M, I/O-bound):** when serve holds (6/8) it is ~0.45 s → **~290×** over the ~132 s walk; the
  mechanism is undo-I/O elimination (physical reads ~4,000 vs ~1.4 M). **2/8 runs degrade** to 87–121 s — the
  documented chain-sever events (design-D5-gc §12): the GC reclaims an interior navigation version, the lineage
  chase breaks, consult returns MISS (noncontig), and the held read falls to the **correct** vanilla walk
  (physical reads climb back to ~1.0–1.4 M, served drops to 390–1451). **construct_BAD=0 in both degrade runs.**
  The 2/8 = 25% rate matches the previously-characterized "~1/4 degrade", now sampled at N=8.
- **4G (resident, stability):** serve ~0.46 s vs ~1.1 s vanilla = **~2.4×**, no degrade. A big BP only saves the
  version-reconstruction CPU (no undo I/O to remove), so the win is modest and stable (phys=0 both modes) —
  consistent with the mechanism.
- **The vanilla baseline itself varies** 102–133 s across runs (churn-depth dependent); earlier single-run
  sessions saw 98–123 s. So the *held ratio* sits in a ~190–290× band depending on the baseline — reporting
  median + range is the honest form, not a single "775×".
- **vs the old 0.16 s / 775×:** that was GC-OFF serve-only (back-edge chase, since NO-GO). The SHIP path is
  GC-ON map-walk consult at ~0.45 s (≈ design-D5-gc's 0.45 s first-scan / 0.22 s reuse). The headline is now
  stated at the shippable, GC-on, bounded-memory setting — honest and still ~290×.
- This is the gate-① deliverable: the ⑥ headline stands on median + distribution + a degrade rate. The degrade
  is the honest cost of small-BP serve under a GC reclaim storm; drain-cap 1000 holds it to ~1/4
  (design-D5-gc §13.2) and it is always correct.

## Reproduction
`integration/scripts/build_q11_d6_multirun.sh 8` (mysqld pre-built with current accel sources). Raw logs:
`integration/results/d6_bp{64M,4G}_m{0,1}_cap1000_i*_{mysqld,scan,churn}.log` + `q11_d6.csv` + `q11_d6_run.log`.
**Execution note:** run via WSL (not Git Bash); for unattended / teardown-surviving runs launch the script
under `setsid` (plain `nohup` lets a terminal-close SIGHUP abort the held-snapshot client → NA rows).

---

# Phase 3 / gate ① — ⑥/⑤ under CONCURRENT churn, MULTI-RUN (DoD literal config) (2026-06-30)

> **Result: under live concurrent HTAP (the deep scans run WHILE churn + GC reclaim are active) the serve
> stays CORRECT and still flattens the I/O cliff, with an honest concurrency tax on absolute latency.** N
> runs of the DoD config (deep analytic scans with NO `wait $CH` — churn active underneath; GC on; mode-1
> serve, drain-cap 1000). **construct_BAD=0 in all 17 runs, including the mode-2 verify-serve gate (~9,000
> served, byte-identical under live reclaim).** At 64M, serve holds near-full in 6/8 runs (deep1 0.2–3.4 s vs
> ~50 s vanilla walk = ~15–230×; median 2.84 s ≈ 18×) and degrades to the correct vanilla walk in 2/8
> (chain-sever under live reclaim). At 4G (resident) serve is a clean ~0.27 s, no degrade.

## Setup
`integration/scripts/build_q15_multirun.sh [N]` — same fresh-boot harness as q11, but the held REPEATABLE-READ
snapshot does warm SUM → SLEEP(25) → **three deep SUMs that run WHILE the 8-thread `oltp_update_non_index`
churn (50 s) is STILL active** (no `wait $CH`). So GC reclaim runs continuously during the read — the
chain-sever risk fires live, not as one post-hoc storm. deep1 (fully concurrent for the fast serve path) is
the headline metric (SHOW PROFILES Duration; the physical-read delta is confounded by concurrent churn → not
recorded). 17 runs: 64M vanilla×3 + serve×8 + verify-serve×3 + 4G serve×3. Logs + `q15_concurrent.csv` land
in `integration/results/` (gate ②).

## Data (deep1 latency s; served / 3000; construct_BAD)
| config (concurrent) | median | min – max | n | served (typical) | construct_BAD |
|---|---|---|---|---|---|
| 64M vanilla walk | 50.81 | 48.50 – 51.03 | 3 | — (baseline) | 0 |
| **64M serve (headline)** | **2.84** | 0.22 – 36.66 | 8 | ~2996 (6/8) · ~2200 (2/8 degrade) | 0 |
| 64M verify-serve (gate) | 45.09 | 41.23 – 49.77 | 3 | ~2999–3000 | **0** |
| 4G serve | 0.265 | 0.199 – 0.355 | 3 | ~2996 | 0 |

**construct_BAD = 0 in every one of the 17 rows.**

## Reading it
- **Correctness under live reclaim is the headline gate.** mode-2 verify-serve walks + byte-compares every
  consult while churn + GC run underneath, across 3 runs (~9,000 served): **construct_BAD=0**. The concurrent
  HTAP regime — the one the Stage-D DoD literally asked for — never produces a wrong serve.
- **64M serve, 6/8 runs = near-full serve** (served ~2996/3000, noncontig 2–3): the undo-I/O cliff is still
  flattened — deep1 0.2–3.4 s vs ~50 s vanilla = ~15–230×. But the absolute serve latency is ~3 s, not the
  ~0.45 s of churn-paused q11: **under concurrency the 8 churn threads contend on the small (64M) buffer
  pool's base-table pages**, so even a near-100%-HIT serve pays buffer-pool contention. At **4G (resident)
  that contention vanishes — serve is a clean ~0.27 s** (faster than 64M concurrent), confirming the ~3 s is
  contention, not the serve path.
- **2/8 runs = live chain-sever degrade** (runs 7–8: served drops to 2131–2253, noncontig 745–867, latency
  → ~36 s): the GC reclaims an interior navigation version mid-read, the lineage chase breaks, consult MISSes,
  the held read falls to the **correct** vanilla walk. construct_BAD=0. Live reclaim is rougher than q11's
  post-hoc storm — a degrade can start mid-scan (run 7: deep1 3 s, but deep2/deep3 climb to 11/39 s as reclaim
  catches up).
- **⚠️ the script's `degraded` flag (deep1 > 2 s) over-counts here** — it flags the ~3 s near-full-serve runs
  (which served ~2996 correctly) as "degraded". The TRUE chain-sever degrades are the **served-count drops**
  (2/8: served ≈ 2200). In the concurrent regime read degrade by served / noncontig, not the > 2 s flag.
- **vs q11 (churn-paused):** same ~2/8 ≈ 25% chain-sever rate, same construct_BAD=0. The differences are
  honest concurrency effects — higher absolute serve latency (small-BP contention) and rougher mid-scan
  degrades (live vs post-hoc reclaim). The concurrent headline is ~18× (median), not ~290×, and the win is
  the eliminated I/O cliff (50 s → ~3 s) that survives live reclaim while never serving a wrong row.

## Reproduction
`integration/scripts/build_q15_multirun.sh 8`. Logs: `integration/results/q15_bp{64M,4G}_m{0,1,2}_cap1000_i*_{mysqld,scan,churn}.log` + `q15_concurrent.csv` + `q15_concurrent_run.log`. Run via WSL under `setsid`.
