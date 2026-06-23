# D-5 — purge-view GC: re-drive the deadzone GC from InnoDB read-views (design)

> Status: **design locked, 5-0 (code prereq) done; next = 5-1**. Inputs: D-5 adversarial design review
> (`GO_WITH_CONDITIONS`, 59 agents) + cheap-collection research (lineage + over-approximation theorem).
> Background: [design-gc.md](design-gc.md) (standalone deadzone GC), [design-D.md](design-D.md) §9 (deferred
> GC safety), [design-D4b-shadow.md](design-D4b-shadow.md) §13/§14 (serve + payoff).

## 0. Goal
Turn the in-memory cache (per-key version chains + captured row images, D-4) from **GC-off / unbounded**
into a working-set-bounded structure, by running the deadzone GC inside the integrated mysqld. **InnoDB
undo is never touched** — only our in-memory nodes/images are reclaimed. This delivers the paper's "bounded
working-set memory" claim; the read-latency payoff (⑥) is already proven independently.

## 1. Why this is harder than just "turning GC back on"
The standalone GC computes the dead zone from our standalone transaction manager's active list. In the
integration that list is **unfed** (the off-latch drainer does low-level inserts that bypass it), and the GC
clock (`next_trx_id`) never advances, so the GC would never even fire. So ⑤ must:
- drive the GC clock from a **monotonic InnoDB id** (pushed in, see §4), and
- compute the dead zone from **InnoDB's active read-view set + purge floor**, not the standalone manager.

## 2. Safety foundation (what the review confirmed)
Two load-bearing pillars **held** under adversarial attack:
1. **Over-reclaim is PERF-only for the body/non-head case.** The cache is *derived* (source of truth =
   InnoDB undo). If GC frees a version a reader still needs, consult returns MISS → InnoDB walks the undo →
   correct. consult never reads the deadzone; it reads only the version key + the visibility mirror + the
   drainer's contiguity scalars.
2. **EBR closes the serve UAF.** The per-traversal Guard is taken before the first node deref and spans the
   image copy into the caller's stack buffer; retire stamps a fresh higher epoch after unlink, so any node a
   live Guard could reach is not freed. The image shares the node lifetime exactly. No node pointer escapes
   the facade (consult copies bytes by value).

### 2.1 The one dangerous case + how it is closed — the SUPERSET theorem
The single place pillar #1 breaks: **interior over-prune under authoritative serve.** If GC removes a
*strictly-interior* version (because the synthesized active-view set OMITTED a live view), the cache is left
with an older version V1 + head V3, consult picks V1, the contiguity gate (which reads only drainer scalars
GC never updates) passes, and serve returns the **wrong older image with no walk fallback** — escaping both
MISS→walk and the EBR Guard.

This is closed by building the dead zone over a **conservative SUPERSET of the truly-active read-views**:

> **Theorem (superset-safe deadzone).** Let `deadzone(S)` be the prunable set computed from view set `S`.
> Adding a view only *adds a begin-cut*, which subdivides existing holes and pulls each hole's right edge
> down — it never widens a hole or moves a boundary outward. So for `S ⊇ A` (A = truly-active),
> `prunable(S) ⊆ prunable(A)`. The dangerous interior-over-prune requires a *missing* live cut
> (under-approximation); a superset contains every live cut, so no interior-visible version is ever
> enclosed. Therefore a superset is **correctness-safe**; its only cost is under-reclaim (a looser bound).

- **PERMITS** any cheap signal that may *lag* (carry stale already-dead views) or *coarsen* (over-protect
  id-bands), as long as ADD-of-a-live-view is reliable and ordered happens-before the view is usable.
- **FORBIDS** ever omitting a live view / raising a watermark / opening a hole past where an unobserved live
  view could sit (the under-approximation direction).

This is the license to **avoid the hot-mutex enumeration** entirely (§3).

## 3. The hot-mutex problem and the cheap collection (signals A + B)
The in-middle reclaim (the LLT memory advantage) needs every active view's snapshot. In InnoDB the full set
lives only behind `trx_sys->mutex` (the hottest begin/commit lock); a periodic walk of the MVCC view list
regresses exactly the high-concurrency OLTP that needs the bound. We avoid it with a staged combination:

- **A — free tail floor (ship unconditionally).** Read InnoDB's `purge_sys->view` (a clone of the oldest
  active view the purge coordinator already refreshes once per purge batch, off the OLTP path). Its low
  limit is the global-min cut → maps onto deadzone zone 0. Cost: **zero** new acquisition. Alone it gives
  no in-middle holes → collapses to the tail-only baseline (Stage C: ~846k hot-chain vs ~155). Necessary as
  the safe floor, insufficient alone.
- **B — lock-free mirror of read-view open (the in-middle payoff).** When InnoDB opens a read-view it is
  **already holding `trx_sys->mutex`** to splice into its view list; in that same critical section we push
  the view's snapshot (its begin id + id set) into our own leaf-domain lock-free registry. Drop-on-close is
  **lazy/best-effort** (stale closed entries are harmless extras by the superset theorem; reconcile them
  against A's free floor). The BG GC reads the registry wait-free and feeds the existing `generate_dead_zone`
  unchanged. Cost: **zero new global latch** — one constant-time store per `view_open` (statement/txn
  granularity, *not* per row). This is exactly vDriver's per-backend SetSnapshot/ClearSnapshot pattern (our
  ancestry). **Strongest fit** — recovers the full in-middle deadzone at near-zero hot-path cost.
- **C — cooperative reclaim (optional add-on).** Fold the per-version deadzone test into the FG search the
  reader already does (marked-pointer + EBR already present), distributing reclaim cost by access rate. Not
  a collector; needs B's descriptor. Add a BG sweeper backstop for cold chains.
- **D — coarse epoch-bucket flags (fallback).** If B's per-view publish measurably regresses OLTP, quantize
  the id axis into buckets and set a flag per `view_open`; holes open across runs of empty buckets
  (DIVA-style interval coarsening). Looser bound, cheaper bookkeeping.

### 3.1 Signal B payload — each view contributes a PAIR, not just a begin-cut (5-1b finding)
A registry that mirrors only each view's begin-cut (its `low_limit_id`) is **not safe**: building a hole as
`[view_i.begin, view_{i+1}.begin]` over-prunes. A version whose superseding transaction is still **active in
the next view** (in that view's `m_ids`) is one the next view must still see; the standalone GC avoids this by
tightening the hole's right edge with the next view's active id-set (`get_dead_up_limit_id`). Reproducing that
safely does **not** require pushing the full id-set per view — it is enough to push two scalars per view:
`{begin = low_limit_id, up_limit_id}`. Using the next view's `up_limit_id` (its smallest active id) as the
hole's right edge is always **≤** the exact tightened edge, so the hole is a subset of the standalone hole →
conservative (under-reclaim) → safe, and equal to exact in the common case (`begin < up_limit`). The two
scalars must be read as a **consistent pair** (a torn {new begin, stale larger up} would widen a hole →
over-prune), so each registry slot publishes the pair under a tiny per-slot seqlock (single writer = the
leasing thread; the GC is the sole reader). The overflow floor stays a single scalar (it over-protects
`[floor, ∞)` wholesale, no right edge needed). **Revises 5-1a**: the registry slot carries `{begin, up}` via a
seqlock, not a single id.

**Recommendation: A + B**, C optional, D only if 5-1 shows B is too costly. **Do NOT** implement the periodic
view-list walk under `trx_sys->mutex` — the superset theorem is the license to skip it.

## 4. Leaf-domain push hook
accel stays a leaf domain (no InnoDB header / no callback into InnoDB). InnoDB **pushes** to accel:
1. on `view_open` (signal B): one immutable snapshot of the opened view (begin id + id set),
2. periodically / on purge cadence (signal A + clock): the purge floor + a **monotonic InnoDB clock**
   (drives the GC boundary; fixes the dead-clock issue).
The push facade is a **pure producer**: it release-stores one immutable, double-buffered/seqlock snapshot and
returns. ALL derivation + every GC-state mutation stays on the single BG GC actor (consume via acquire-load).
This avoids a second mutator of the non-atomic single-consumer GC state.

## 5. Novelty (paper)
The mechanisms (A/B/C/D) are established lineage techniques — porting them to InnoDB is solid systems work,
not a research contribution. The **novel, paper-worthy claim** is the **over-approximation safety theorem
specialized to a *derived, authoritatively-served* MVCC cache**: prior systems (vDriver/DIVA) *own* their
version store, so a stale/conservative dead zone is trivially fine (reclaim just removes from the source of
truth). AccelerateMVCC shadows InnoDB and *serves* authoritatively, where over-pruning an interior version is
catastrophic (wrong-version serve). The contribution is the precise characterization that the only dangerous
direction is **under-approximation**, that a conservative **superset** structurally excludes the wrong-serve,
and that the derived-cache nature turns the residual over-keep into mere under-reclaim — which is exactly what
licenses dropping the hot-mutex enumeration vDriver/DIVA never had to face.

## 6. Must-fix conditions (from the review)
**Correctness (blocker, before any GC-on / serve):**
- **M1 fixed-size deadzone overflow** — `generate_dead_zone` appended one zone per active txn into a fixed
  `range[2*NUM_DEADZONE]`; >50 active views overran the heap inside the GC actor. **DONE (5-0):** loop
  clamped at `NUM_DEADZONE` (dropping highest-id holes = under-reclaim = safe).
- **M2 interior over-prune → wrong serve** — closed by the **superset/complete** active-view set (§2.1) PLUS
  one of: consult re-verifies writer-link adjacency at walk time, or GC invalidates the key's contiguity on
  interior removal. Gated by a **directed interior-over-prune visibility oracle** (hit_MISMATCH=0 under serve)
  before 5-2b. Until then, serve stays off.
- **M3 head never retired** — head-prepend CAS (1c-5) is **NOT** done (plain store); GC-on is safe **only**
  because GC never prunes the head. **DONE (5-0):** debug assert at the single retire entry that no head
  (superseded_ts==UINT64_MAX) is retired. Head-prune stays disabled (out of ⑤ scope).
- **M4 dead GC clock** — the GC boundary is driven by the standalone manager which the drainer never advances,
  so GC never fires; `start_background_gc()` is never called. Fix in 5-2: drive the boundary off the pushed
  InnoDB clock, actually start the GC thread, and gate a green TSan run on evidence GC actually swept
  (nonzero retire count). (Moved here from the original 5-0 "EPOCH_SIZE rescale" — see §7.)

**Memory / perf (precondition for the bound to hold, not wrong-result):**
- overflow floor is monotone-down / never reset → >MAX_THREADS readers can pin reclaim → unbounded. Fix:
  reset when overflow count hits 0, or size MAX_THREADS > server max_connections.
- cold-key header + Kuku slot never reclaimed → key-set grows O(distinct keys) even with bounded depth. Fix
  later or document residual; needs Kuku erase + a "head-with-live-versions only" skip relaxation.
- `EPOCH_SIZE` vs sparse real DB_TRX_IDs → head-prepend fires per version, defeating batching. Re-scale /
  rank-map driven by the **pushed InnoDB id space** (so deferred to 5-1, not a blind standalone constant).
- push buffer atomic publish must not free under an in-flight GC read (double-buffer/seqlock or route through
  the existing EBR retire); `generate_dead_zone` assumes a sorted/consistent vector (defensively sort/assert).

## 7. Increment plan
- **5-0 (DONE) — code prereq gate.** M1 clamp + M3 head-never-retired assert (this commit). Standalone 32
  green (Release/ASan/TSan). The `EPOCH_SIZE`/epoch-num rescale is **moved to 5-1** because the right value
  needs the InnoDB id space (a blind constant change now would be premature and could perturb standalone).
- **5-1 — push hook + deadzone-from-InnoDB-view, GC still OFF, shadow-verify.** Leaf-domain pure-producer
  facade: signal A (purge floor + monotonic clock) + signal B (lock-free mirror on `view_open`, lazy drop).
  Build the dead zone over the **full active-view (superset) set**. Drive epoch-num off the pushed id space.
  Shadow (no GC, no serve): assert our reconstructed dead zone is a correct superset of InnoDB's true active
  set + monotone, the clock advances and crosses period boundaries, and a **directed interior-over-prune
  negative control** (omit a known-live view → the would-be wrong-HIT is detected). Measure B's publish cost
  vs vanilla OLTP (the open question that picks B vs D).
- **5-2 — GC ON, drainer + consult concurrent (shadow consult).** Actually start the GC thread, drive its
  boundary off the pushed clock, **head-prune OFF**. ASan/TSan with GC genuinely sweeping (assert nonzero
  retire count), drainer at max rate, >MAX_THREADS readers exercising the overflow path; fix the overflow
  reset. consult shadow-only → over-reclaim provably MISS→walk + EBR-safe.
- **5-2b — re-layer authoritative serve + M2 correctness gate.** Re-apply 4d serve on top of GC-on (this is
  where interior over-prune gets teeth). Gate: full-active-view dead zone + consult walk-time adjacency
  re-verification (or GC-side contiguity invalidation on interior removal) + directed interior-over-prune
  visibility oracle under serve → hit_MISMATCH=0, served==hit, construct_BAD=0, ASan/TSan clean. Keep serve
  as copy-out-of-stack-buffer.
- **5-3 — measure memory bound + perf, honest scope.** Add cold-key reclaim or document residual. Run under a
  realistic **write-heavy OLTP + LLT** profile (so writers actually manufacture in-middle holes; a
  reader-light profile collapses to tail-only). Report cache RSS, hot-chain max vs the tail-only ~846k, the
  trx_sys mutex hold time / begin-commit p99 from the snapshot, and consult/serve correctness + perf
  unchanged. If in-middle hole density is too low, make the honest **scope-to-tail-only-and-drop-the-LLT-claim**
  decision here, with data.

## 8. Open questions (5-1 must measure)
- Does B's atomic store inside the existing `view_open` critical section regress OLTP tps at 32/64/128
  threads? How often does `view_open` actually fire vs the reuse fast-path?
- How much does lazy-drop-on-close loosen the in-middle bound vs GC cadence and view churn (10ms/100ms/1s)?
- View-reuse / deferred-close: does ADD-on-open still capture every reuse as a fresh live cut (shadow
  hit_MISMATCH stays 0)?
- Bucket granularity for D (if B too costly): where do holes vanish vs where does bookkeeping approach B?
- Cooperative-only reclaim (C): cold-chain residual vs a BG sweeper backstop?
- Floor-vs-mirror reconciliation: no window where a still-live entry is retired (only when its low limit is
  strictly below the observed floor); stress under ASan/TSan with concurrent purge cadence.
