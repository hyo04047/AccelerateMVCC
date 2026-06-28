# Phase 2 / ⓠ3 — does the in-middle reclaim headline survive in REAL InnoDB? (2026-06-28)

> **Result: YES.** Under write-heavy OLTP + a held LLT + concurrent HTAP readers, the integrated
> AccelerateMVCC cache stays **bounded** (≈ the active-view working set) while InnoDB's retention
> (History List Length) grows **linearly** with the LLT window. The memory ratio scales with LLT age:
> **~20× / 40× / 63×** at 15 / 30 / 60 s, and keeps growing. The project's central claim — that the
> deadzone's in-middle reclaim beats InnoDB's tail-only purge under a long-lived transaction — **holds in
> real InnoDB**, not just the standalone prototype. The pre-authorized 5-3 retreat is NOT triggered.

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
- The **off-page LOB** case is the subtle safety check: its main clustered record (with a ~20-byte LOB
  pointer) can be < 512 B, so WITHOUT the `rec_offs_any_extern` gate the cache would capture a partial image
  and could serve a row missing its LOB. The gate prevents it — 100% ineligible, construct_BAD=0.
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

## What this closes / what remains
- **Closes ⓠ3** (the central 5-3 retreat worry): the in-middle headline survives in real InnoDB and scales
  with LLT, given the HTAP gap.
- **Closes ⓠ5**: the held reader's coverage is ~complete on small-row OLTP; effective speedup ~34× I/O-bound
  and correct. The MISS worry was a misframing (short readers the cache doesn't target).
- **Closes ⓝ6**: LOB/off-page/virtual/>512B rows are safely excluded (construct_BAD=0); coverage collapses
  on LOB-heavy but degrades gracefully to vanilla. Documented Limitation; cache scope = small-row OLTP.
- **Closes composite-PK / string-PK / secondary-index (part of ⓝ4) + savepoint (ⓝ15)**: all construct_BAD=0;
  the cache generalizes past single-INT-PK and degrades safely on savepoint complexity.
- Remaining Phase 2: full-mysqld ASan/TSan (ⓝ5). Then Phase 3 (paper, incl. the ⓝ6 Limitation).
