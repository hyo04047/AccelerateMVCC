#ifndef epoch_table_h
#define epoch_table_h

#include <array>
#include <utility>
#include <vector>
#include <atomic>
#include <cstring>
#include <algorithm>
#include <cassert>
#include "common.h"
#include "interval_list.h"
#include "trxManager.h"
#include "epoch_reclaimer.h"
#include "active_view_registry.h"   // D-5 5-1c: ViewCut {begin, up} from the active-view registry

#define NUM_DEADZONE (50)

namespace mvcc {

    struct epoch_node_wrapper {
        epoch_node *epoch;
        // Harris marked pointer (low bit = wrapper logically spliced out). The wrapper
        // list is not reader-traversed; the mark guards the insert-head CAS vs a
        // concurrent GC splice (so insert never lands behind a wrapper being removed).
        MarkedPtr<epoch_node_wrapper> next;

        explicit epoch_node_wrapper(epoch_node *epoch)
                : epoch(epoch), next(nullptr) {}
    };

    struct epoch_table_node {
        uint64_t epoch_num;
        std::atomic<epoch_node_wrapper *> first_node;
        std::atomic<epoch_node_wrapper *> last_node;

        // watcher number for this node
        std::atomic<int> count;

        explicit epoch_table_node(uint64_t epoch_num)
                : epoch_num(epoch_num), count(0) {
            // dummy node!
            auto *epoch_wrapper = new epoch_node_wrapper(nullptr);
            first_node.store(epoch_wrapper);
            last_node.store(epoch_wrapper);
        }
    };

    class Epoch_table {
    public:
        explicit Epoch_table() {
            for (int i = 0; i < EPOCH_TABLE_SIZE; i++) {
                table.at(i).store(new epoch_table_node(i));
            }
            // dummy-overflow list is a lock-free Treiber stack (dummy_head_, nullptr = empty),
            // drained by the BG GC actor each cycle (stage 1c-3); no sentinel needed.
        }

        bool insert(epoch_node *epoch) {
            // Pin reclamation for this insert's span: the BG GC's reclaim() must not free a
            // table_node/dummy this inserter has captured. Without it, the load->count++ gap
            // below is a UAF window (the count gate only protects AFTER the increment).
            EpochReclaimer::Guard g(reclaimer_);
            uint64_t epoch_num = epoch->epoch_num;
            uint64_t index = epoch_num % EPOCH_TABLE_SIZE;
            epoch_table_node *table_node = table.at(index).load();
            table_node->count.fetch_add(1);
            if (epoch_num < table_node->epoch_num) { // NOLINT(bugprone-branch-clone)
                // GC is already performed
                table_node->count.fetch_sub(1);
                insert_to_dummy(epoch);
                return false;
            } else if (epoch_num > table_node->epoch_num) {
                // GC is too late …
                table_node->count.fetch_sub(1);
                insert_to_dummy(epoch);
                return false;
            } else {
                auto *epoch_wrapper = new epoch_node_wrapper(epoch);
                // Head-insert right after the stable dummy head (first_node).
                // GC (Phase 2) walks first_node->next forward, so insert on the same side.
                // Marked-pointer CAS: fails (and retries) if the head's next moved or was
                // marked by a concurrent GC splice -> no lost wrapper.
                epoch_node_wrapper *head = table_node->first_node.load();
                while (true) {
                    uintptr_t hw = head->next.load();
                    epoch_node_wrapper *first_real = MarkedPtr<epoch_node_wrapper>::ptr_of(hw);
                    epoch_wrapper->next.store(first_real, false);
                    uintptr_t expected = MarkedPtr<epoch_node_wrapper>::pack(first_real, false);
                    if (head->next.cas(expected, MarkedPtr<epoch_node_wrapper>::pack(epoch_wrapper, false))) {
                        table_node->count.fetch_sub(1);
                        return true;
                    }
                    // CAS failed (head->next moved or marked); retry.
                }
            };
        }

        struct deadzone {
            deadzone(std::vector<uint64_t> oldest_active_trx_ids, uint64_t oldest_low_limit_id)
                : oldest_low_limit_id(oldest_low_limit_id), len(0) {
                memset(range, 0x00, sizeof(uint64_t) * NUM_DEADZONE * 2);
                this->oldest_active_trx_ids = std::move(oldest_active_trx_ids);
            }

            uint64_t range[2 * NUM_DEADZONE]{};
            uint64_t  oldest_low_limit_id;
            uint64_t len;
            std::vector<uint64_t> oldest_active_trx_ids;

        };


        uint64_t get_dead_up_limit_id(uint64_t limit_id, const std::vector<uint64_t> &ids, const uint64_t trx_id) const {

            for (uint64_t i = 0; i < ids.size(); ++i) {
                if (ids.at(i) > limit_id) {
                    return (ids.at(i));
                }
            }

            return trx_id;
        }

        /**
        update dead zone */
        deadzone* generate_dead_zone(const std::vector<trx_t>& vector) {

            if (vector.empty()) {
                // No active transaction -> empty zone (len 0) -> prune nothing (safe default).
                return new deadzone(std::vector<uint64_t>{}, 0);
            }

            uint64_t oldest_low_limit_id;

            if(vector.at(0).active_trx_ids.empty()){
                oldest_low_limit_id = vector.at(0).trx_id;
            }else{
                oldest_low_limit_id = vector.at(0).active_trx_ids.at(0);
            }
            /* 1. Get free deadzone structure */
            auto* zone = new deadzone(vector.at(0).active_trx_ids,oldest_low_limit_id);

            /* 2. Update "zone 1" */
            zone->range[0] = 0;
            zone->range[1] = oldest_low_limit_id;
            zone->len = 1;

            uint64_t low_limit_id;
            uint64_t dead_up_limit_id;
            /* 3. Update other deadzone.
               D-5 5-0: clamp at NUM_DEADZONE so the fixed range[2*NUM_DEADZONE] cannot overflow when a
               real mysqld carries >NUM_DEADZONE active read-views. Stopping early simply drops the
               highest-id in-middle holes -> keeps more versions = UNDER-reclaim, which is memory-safe
               by the superset property (never omits a live cut, so never over-prunes an interior
               version). A tighter coalesce-excess-into-tail is a future memory optimization. */
            for (uint64_t i = 1; i < vector.size() && zone->len < NUM_DEADZONE; ++i) {
                low_limit_id = vector.at(i - 1).trx_id;
                dead_up_limit_id = get_dead_up_limit_id(low_limit_id, vector.at(i).active_trx_ids,
                                                        vector.at(i).trx_id);

                zone->range[2 * zone->len] = low_limit_id;
                zone->range[2 * zone->len + 1] = dead_up_limit_id;
                zone->len++;
            }
            return zone;
        }

        /* D-5 5-1c: build the dead zone from the active-view registry's {begin, up} cuts (collection
           signal B) plus a conservative floor (signal B overflow and/or signal A purge floor). `cuts`
           MUST be sorted ascending by begin (the registry snapshot already is). Each hole's right edge
           uses the NEXT view's up_limit -- always <= the exact active-id-set edge of generate_dead_zone
           above, so the prunable set is a SUBSET of the standalone's (conservative; safe by inheritance).
           zone 0 (tail) is [0, oldest.up], matching the standalone's oldest_low_limit_id = up. A floor
           < NO_FLOOR clamps every right edge so nothing >= floor is pruned (an unobserved view could sit
           there). Clamped at NUM_DEADZONE like generate_dead_zone (excess holes dropped = under-reclaim).
           See docs/design-D5-gc.md §3.1. */
        deadzone* generate_dead_zone_from_cuts(const std::vector<ViewCut>& cuts, uint64_t floor) {
            if (cuts.empty()) {
                return new deadzone(std::vector<uint64_t>{}, 0);   // no active view -> prune nothing here
            }
            auto* zone = new deadzone(std::vector<uint64_t>{}, cuts.at(0).up);
            zone->range[0] = 0;
            zone->range[1] = cuts.at(0).up;     // tail [0, oldest up_limit)
            zone->len = 1;
            for (std::size_t i = 1; i < cuts.size() && zone->len < NUM_DEADZONE; ++i) {
                uint64_t left = cuts.at(i - 1).begin;
                uint64_t right = cuts.at(i).up;     // conservative right edge (<= exact dead_up)
                if (right > left) {                 // non-empty hole only
                    zone->range[2 * zone->len] = left;
                    zone->range[2 * zone->len + 1] = right;
                    zone->len++;
                }
            }
            if (floor != ~uint64_t(0)) {            // conservative floor: keep everything >= floor
                for (uint64_t i = 0; i < zone->len; ++i)
                    if (zone->range[2 * i + 1] > floor) zone->range[2 * i + 1] = floor;
            }
            return zone;
        }

        bool can_pruning(uint64_t v_start, uint64_t v_end , deadzone* zone) {
            bool ret = false;
            bool flag = true;


            /* compare its v_start & v_end to deadzone. In TAIL-ONLY baseline mode (stage C-2) we
               consider only zone 0 (= [0, oldest_low_limit_id], the below-global-min tail) and
               skip the in-middle holes -- this faithfully models InnoDB-style tail purge, which
               an LLT stalls by pinning the global-min. Default (deadzone) uses every zone. */
            uint64_t limit = gc_tail_only_.load(std::memory_order_relaxed)
                                 ? std::min<uint64_t>(zone->len, 1)
                                 : zone->len;
            for (uint64_t i = 0; i < limit; ++i) {
                if (i == 0 && zone->oldest_active_trx_ids.size() != 0) {
                    if (v_end < zone->range[1]) {
                        ret = true;
                        break;
                    }
                    else if (v_end >= zone->oldest_low_limit_id) {
                        continue;
                    }

                    for (int j = 0; j < zone->oldest_active_trx_ids.size(); ++j) {
                        if (zone->oldest_active_trx_ids.at(j) == v_end) {
                            flag = false;
                            break;
                        }
                    }
                    if (flag) {
                        ret = true;
                        break;
                    }
                }
                else {
                    if (zone->range[2 * i] < v_start &&
                        v_end < zone->range[2 * i + 1]) {

                        ret = true;
                        break;
                    }
                }
            }

            return (ret);
        }

        bool can_operate_gc(epoch_node_wrapper *epoch_wrapper, deadzone *deadzone) {
            return can_prune_epoch(epoch_wrapper->epoch, deadzone);
        }

        // Judge whether an epoch_node's versions are all fully inside a dead zone, using TIGHT
        // bounds (stage 1c-4 fix): the epoch's actual visibility interval is [min_trx_id,
        // superseded_ts] -- its oldest version's begin-ts and its newest version's supersede-ts
        // (= the next-newer version's begin; UINT64_MAX while this is still the head, so a head
        // is never dead). The old nominal window [epoch*EPOCH_SIZE, +EPOCH_SIZE) used the epoch
        // boundary as the supersede point, which UNDER-estimates it when the next version lands
        // in a far-away epoch -- over-pruning a version a reader/LLT still needs. Faithful to
        // vDriver SegIsInDeadZone. Used by GC (can_operate_gc) and FG readers (search).
        bool can_prune_epoch(epoch_node *en, deadzone *dz) {
            uint64_t v_start = en->min_trx_id;
            uint64_t v_end = en->superseded_ts.load(std::memory_order_acquire);
            return can_pruning(v_start, v_end, dz);
        }

        // Stage 1c: the shared published deadzone descriptor. BG builds one per cycle,
        // uses it for its own sweep, then publishes it (atomic exchange) and retires the
        // superseded one under EBR grace. A FG reader loads it under its traversal Guard
        // to judge deadness; the same reservation that pins epoch_nodes pins the
        // descriptor (same reclaimer, same grace), so it is never freed under the reader.
        // nullptr (warm-up / not yet published) -> judge nothing (caller skips, never blocks).
        deadzone *published_deadzone() const {
            return published_deadzone_.load(std::memory_order_acquire);
        }

// TODO : when this function is called ?? - every 25(EPOCH_TABLE_SIZE/4) times! 50, 75, 100 …
        //  -> do not start at 25!
        // we need to separate 2 phase of gc processing
        // Phase1 : send epoch_tables nodes to LLT vector
        // <- (epoch_num - epoch_table_size/4)  ~ (epoch_num)
        // Phase2 : processing gc in LLT vector
        bool garbage_collect(uint64_t epoch_num, std::vector<trx_t> vector) {
            // BG reclaim: free anything retired in a previous cycle that no
            // currently-active reader (Guard) can still reach. Safe to run every
            // call, including the warm-up early-returns below.
            reclaimer_.reclaim();
            if (epoch_num == EPOCH_TABLE_SIZE / 4) {
                return false;
            }
            {
                // get index range to move elements from table to long_live_epochs
                uint64_t start_index = (epoch_num - EPOCH_TABLE_SIZE / 2) % EPOCH_TABLE_SIZE;
                uint64_t end_index = ((epoch_num - EPOCH_TABLE_SIZE / 4) - 1) % EPOCH_TABLE_SIZE;

                int i_start = static_cast<int>(start_index);
                int i_end = static_cast<int>(end_index);
                for (int i = i_start; i <= i_end; i++) {
                    epoch_table_node *prev_table_node = table.at(i).load();
                    long_live_epochs.push_back(prev_table_node);
                    auto *new_table_node = new epoch_table_node((prev_table_node->epoch_num) + EPOCH_TABLE_SIZE);
                    table.at(i).store(new_table_node);
                }
            }
            if (epoch_num == EPOCH_TABLE_SIZE / 2) {
                return false;
            }
            deadzone* deadzone = generate_dead_zone(vector);
            ++backstop_counter_;
            {
                uint64_t llt_size = long_live_epochs.size();
                if (llt_size < (uint64_t)(EPOCH_TABLE_SIZE / 2)) {   // not enough lag accumulated yet
                    drain_dummy(deadzone);        // still drain orphans before a window exists
                    publish_deadzone(deadzone);
                    return false;
                }
                // Windowed sweep: only the buckets that have aged into the window. Bounded
                // O(EPOCH_TABLE_SIZE/4) buckets per cycle -> amortized GC work stays bounded.
                int i_start = static_cast<int>(llt_size - (EPOCH_TABLE_SIZE / 2));
                int i_end   = static_cast<int>(llt_size - (EPOCH_TABLE_SIZE / 4) - 1);
                for (int i = i_start; i <= i_end; i++) {
                    epoch_table_node *tn = long_live_epochs.at(i);
                    if (tn == nullptr) continue;                     // tombstoned (already reclaimed)
                    sweep_bucket(tn, deadzone);
                    try_reclaim_bucket(static_cast<size_t>(i));
                }
                // Backstop full-bucket sweep (low cadence): the windowed sweep visits each bucket
                // once, so an epoch that dies AFTER its windowed pass -- or (1c-4) a node an FG
                // reader detached in an already-swept bucket -- would never be retired. The
                // backstop revisits every live bucket so nothing strands. Most buckets are
                // empty/tombstoned (O(1) skip); the cadence bounds the rest.
                if (backstop_counter_ % BACKSTOP_PERIOD == 0) {
                    for (size_t i = 0; i < long_live_epochs.size(); ++i) {
                        epoch_table_node *tn = long_live_epochs.at(i);
                        if (tn == nullptr) continue;
                        sweep_bucket(tn, deadzone);
                        try_reclaim_bucket(i);
                    }
                }
                drain_dummy(deadzone);            // pending #2: reclaim/keep orphan wrappers
                if (backstop_counter_ % BACKSTOP_PERIOD == 0) {
                    // Stage 1c-6: compact away tombstoned (reclaimed) slots so long_live_epochs
                    // tracks LIVE buckets, not all-buckets-ever. Safe: the backstop (which just ran)
                    // sweeps every live bucket regardless of the windowed sweep's size-relative
                    // indices, and retire-once is idempotent under any re-sweep -- so reorganizing
                    // here at most shifts a bucket from the windowed path to the backstop path.
                    long_live_epochs.erase(
                        std::remove(long_live_epochs.begin(), long_live_epochs.end(),
                                    static_cast<epoch_table_node *>(nullptr)),
                        long_live_epochs.end());
                }
            }
            publish_deadzone(deadzone);
            return true;
        }

        // D-5 ⑤a-2: integration GC cycle. SAME orchestration + SAME shared sweep helpers
        // (sweep_bucket / drain_dummy / try_reclaim_bucket) as garbage_collect above -- so the
        // version-chain mutation path (the drainer||GC edge) is the identical code -- but the dead zone
        // is built from the InnoDB active-view registry cuts + a conservative floor (a SUPERSET of the
        // truly-active views, design-D5-gc §2.1/§3) instead of the standalone active list, which the
        // off-latch drainer never advances (M4). Single GC actor (the accel_hook gc_loop thread).
        bool garbage_collect_from_cuts(uint64_t epoch_num, const std::vector<ViewCut>& cuts, uint64_t floor) {
            reclaimer_.reclaim();
            if (epoch_num == EPOCH_TABLE_SIZE / 4) {
                return false;
            }
            {
                uint64_t start_index = (epoch_num - EPOCH_TABLE_SIZE / 2) % EPOCH_TABLE_SIZE;
                uint64_t end_index = ((epoch_num - EPOCH_TABLE_SIZE / 4) - 1) % EPOCH_TABLE_SIZE;
                int i_start = static_cast<int>(start_index);
                int i_end = static_cast<int>(end_index);
                for (int i = i_start; i <= i_end; i++) {
                    epoch_table_node *prev_table_node = table.at(i).load();
                    long_live_epochs.push_back(prev_table_node);
                    auto *new_table_node = new epoch_table_node((prev_table_node->epoch_num) + EPOCH_TABLE_SIZE);
                    table.at(i).store(new_table_node);
                }
            }
            if (epoch_num == EPOCH_TABLE_SIZE / 2) {
                return false;
            }
            deadzone* dz = generate_dead_zone_from_cuts(cuts, floor);
            ++backstop_counter_;
            {
                uint64_t llt_size = long_live_epochs.size();
                if (llt_size < (uint64_t)(EPOCH_TABLE_SIZE / 2)) {
                    drain_dummy(dz);
                    publish_deadzone(dz);
                    return false;
                }
                int i_start = static_cast<int>(llt_size - (EPOCH_TABLE_SIZE / 2));
                int i_end   = static_cast<int>(llt_size - (EPOCH_TABLE_SIZE / 4) - 1);
                for (int i = i_start; i <= i_end; i++) {
                    epoch_table_node *tn = long_live_epochs.at(i);
                    if (tn == nullptr) continue;
                    sweep_bucket(tn, dz);
                    try_reclaim_bucket(static_cast<size_t>(i));
                }
                if (backstop_counter_ % BACKSTOP_PERIOD == 0) {
                    for (size_t i = 0; i < long_live_epochs.size(); ++i) {
                        epoch_table_node *tn = long_live_epochs.at(i);
                        if (tn == nullptr) continue;
                        sweep_bucket(tn, dz);
                        try_reclaim_bucket(i);
                    }
                }
                drain_dummy(dz);
                if (backstop_counter_ % BACKSTOP_PERIOD == 0) {
                    long_live_epochs.erase(
                        std::remove(long_live_epochs.begin(), long_live_epochs.end(),
                                    static_cast<epoch_table_node *>(nullptr)),
                        long_live_epochs.end());
                }
            }
            publish_deadzone(dz);
            return true;
        }

        // EBR used by GC (retire/reclaim) and search readers (Guard). Single
        // producer/reclaimer in stage 1a: only the GC actor retires/reclaims.
        EpochReclaimer& reclaimer() { return reclaimer_; }

        // Stage C-2 baseline toggle: when true, can_pruning considers only the tail (below
        // global-min) dead zone, modeling InnoDB-style tail purge. Set once before the run.
        void set_gc_tail_only(bool v) { gc_tail_only_.store(v, std::memory_order_relaxed); }

        // GC metrics (stage 1c): epoch_nodes detached from the version chain, and retired.
        // At quiescence detached == retired -- valid while each epoch_node has a single swept
        // wrapper (the 1c-2/1c-4 world: LIVE->CHAIN_DETACHED->RETIRED runs once per node). If a
        // retire could ever skip the detach claim (a second swept wrapper, 1c-3), switch the
        // check to the full LIVE + CHAIN_DETACHED + RETIRED conservation.
        uint64_t epochs_detached() const { return epochs_detached_.load(std::memory_order_relaxed); }
        uint64_t epochs_retired()  const { return epochs_retired_.load(std::memory_order_relaxed); }
        // D-5 ⑤a-2: split retire by source so the GC-on gate can tell the dangerous WINDOWED bucket
        // sweep (sweep_bucket -> unlink_epoch_from_chain on aged buckets) from the orphan DUMMY drain.
        // If all retires are dummy (real epoch_nums never matched their seeded buckets), the windowed
        // path is unexercised and a green construct_BAD=0 gate is hollow (review critic M-D-ii).
        uint64_t epochs_retired_windowed() const { return epochs_retired_windowed_.load(std::memory_order_relaxed); }
        uint64_t epochs_retired_dummy()    const { return epochs_retired_dummy_.load(std::memory_order_relaxed); }

        // Stage 1c-3: orphan wrappers currently queued in the dummy-overflow stack (meaningful
        // only when quiescent -- for tests). Trends to a small bound (live un-demoted heads) as
        // drain_dummy retires dead orphans; an unbounded value would mean the #2 leak is back.
        size_t dummy_pending() const {
            size_t n = 0;
            for (epoch_node_wrapper *w = dummy_head_.load(std::memory_order_acquire);
                 w != nullptr; w = w->next.ptr())
                ++n;
            return n;
        }

        // Stage 1c-6 (test-only): size of the GC long-lived-bucket vector. With compaction it
        // tracks LIVE buckets, not all-buckets-ever -- a slow unbounded growth would mean
        // compaction regressed. Meaningful only when quiescent (BG-touched only).
        size_t long_live_size() const { return long_live_epochs.size(); }


    private:
        // Publish dz as the current shared descriptor and retire the superseded one under
        // EBR grace (a reader may still hold the old pointer for its traversal's span).
        // Single producer: only the BG GC actor calls this, from garbage_collect.
        void publish_deadzone(deadzone *dz) {
            deadzone *old = published_deadzone_.exchange(dz, std::memory_order_release);
            if (old) reclaimer_.retire([old] { delete old; });
        }

        // The SOLE epoch_node retire authority (stage 1c-2): every retire goes through here,
        // gated by state.exchange(RETIRED). The gate dereferences en->state, so it is an
        // idempotent no-op ONLY WHILE en is alive -- a second retire attempt that ran AFTER
        // en was EBR-freed would be a use-after-free, NOT a safe skip. Safety therefore rests
        // on each epoch_node having exactly ONE swept wrapper (Accelerate_mvcc::insert wraps
        // each epoch once; the dummy-overflow wrapper is never swept) and on a wrapper being
        // spliced out before its node is retired (so no later sweep re-reaches a retired node).
        // => 1c-3's dummy-overflow drain MUST TRANSFER that single ownership (re-home moves the
        //    wrapper), never create a second swept wrapper for a live node. 1c-4's FG detach
        //    never retires; it only hands the node to this BG-only retire via the state claim.
        void retire_epoch_once(epoch_node *en) {
            if (en->state.exchange(EPOCH_RETIRED, std::memory_order_acq_rel) != EPOCH_RETIRED) {
                epochs_retired_.fetch_add(1, std::memory_order_relaxed);
                reclaimer_.retire([en] {
                    for (undo_entry_node *e = en->first_entry; e != nullptr; ) {
                        undo_entry_node *nx = e->next_entry.load();
                        delete e;
                        e = nx;
                    }
                    delete en;
                });
            }
        }

        // Version-chain detach + single retire of one epoch_node, shared by the windowed
        // sweep, the backstop, and the dummy drain. Logical-mark + CAS-unlink from the record's
        // chain, CAS-claim CHAIN_DETACHED (counts a detach only the FIRST time -- a node an FG
        // reader already detached in 1c-4 falls through without re-counting), then retire via
        // the sole state-gated authority. Idempotent if the node is already marked/unlinked.
        void detach_and_retire_epoch(epoch_node *en) {
            // D-5 5-0: a head epoch (still current, superseded_ts==UINT64_MAX) must NEVER be GC-retired.
            // Head-prune (1c-5) is not enabled and head-prepend is a plain store, so retiring a head
            // would open the two-writer race on header->next. wrapper_prunable already skips heads
            // (epoch_table.h head check); this asserts that invariant at the single retire entry so a
            // future change that re-enables head-prune trips here first.
            assert(en->superseded_ts.load(std::memory_order_acquire) != ~uint64_t(0) &&
                   "GC must never retire a head epoch (superseded_ts == UINT64_MAX)");
            epoch_node *succ = en->next.ptr();
            en->next.set_mark(succ);                        // no-op if already marked
            unlink_epoch_from_chain(en->header, en, succ);  // no-op if already unlinked
            uint8_t expLive = EPOCH_LIVE;
            if (en->state.compare_exchange_strong(expLive, EPOCH_CHAIN_DETACHED,
                                                  std::memory_order_acq_rel))
                epochs_detached_.fetch_add(1, std::memory_order_relaxed);
            // D-5 ⑤b-lite: invalidate this key's memoized consult cache BEFORE retire schedules the node
            // free, so no reader can load a cache that references a node about to be freed -- a reader that
            // loaded a non-null cache did so before this clear, so its EBR Guard pins the referenced nodes.
            if (en->header != nullptr) {
                ConsultCache *oldc = en->header->consult_cache.exchange(nullptr, std::memory_order_acq_rel);
                if (oldc != nullptr) reclaimer_.retire([oldc] { delete oldc; });
            }
            retire_epoch_once(en);
        }

        // Is this wrapper's epoch prunable now? Dead per the descriptor, OR already
        // CHAIN_DETACHED (by an FG reader, 1c-4) -- but NEVER a record's head epoch (head prune
        // is 1c-5; the head's undo chain may still be appended under the record mutex).
        bool wrapper_prunable(epoch_node_wrapper *node, deadzone *dz) {
            epoch_node *en = node->epoch;
            if (en == nullptr) return false;
            bool dead = (dz != nullptr && can_operate_gc(node, dz)) ||
                        en->state.load(std::memory_order_acquire) == EPOCH_CHAIN_DETACHED;
            if (!dead) return false;
            if (en->header != nullptr && en->header->next.ptr() == en) return false;  // head: skip
            return true;
        }

        // Prune every prunable wrapper from one bucket's list. BG-only (the windowed sweep,
        // backstop, and drain all run sequentially on this single actor -> the wrapper list has
        // one unlinker, so the splice is a plain store). Each pruned epoch is detached+retired once.
        void sweep_bucket(epoch_table_node *tn, deadzone *dz) {
            epoch_node_wrapper *prev_node = tn->first_node.load();
            for (epoch_node_wrapper *node = prev_node->next.ptr(); node != nullptr; ) {
                if (wrapper_prunable(node, dz)) {
                    epochs_retired_windowed_.fetch_add(1, std::memory_order_relaxed);  // D-5 ⑤a-2: source split
                    epoch_node_wrapper *dead = node;
                    epoch_node_wrapper *wsucc = node->next.ptr();
                    dead->next.set_mark(wsucc);
                    prev_node->next.store(wsucc, false);
                    node = wsucc;
                    detach_and_retire_epoch(dead->epoch);
                    reclaimer_.retire([dead] { delete dead; });
                } else {
                    prev_node = node;                        // advance prev only over kept nodes
                    node = node->next.ptr();
                }
            }
        }

        // Reclaim a fully-drained bucket (no inserter pinned it AND its list is empty): retire
        // its dummy head + the table_node and TOMBSTONE its slot (nullptr). long_live_epochs is
        // push-only (no erase) so the windowed-sweep index math stays valid; sweeps skip nulls.
        bool try_reclaim_bucket(size_t slot) {
            epoch_table_node *tn = long_live_epochs.at(slot);
            if (tn == nullptr) return false;
            if (tn->count.load() == 0 && tn->first_node.load()->next.ptr() == nullptr) {
                epoch_node_wrapper *dummy_head = tn->first_node.load();
                reclaimer_.retire([dummy_head] { delete dummy_head; });
                long_live_epochs.at(slot) = nullptr;        // tombstone
                reclaimer_.retire([tn] { delete tn; });
                return true;
            }
            return false;
        }

        // Drain the dummy-overflow Treiber stack (stage 1c-3, pending #2). Detach the whole
        // stack, then for each orphan wrapper: if its epoch is dead (or CHAIN_DETACHED) and not
        // a head, detach+retire it and free the wrapper; otherwise re-queue it for a later
        // drain. The dummy wrapper is the epoch's ONLY (never-swept) wrapper, so retiring through
        // it keeps single-ownership -- this TRANSFERS ownership, never makes a second swept
        // wrapper (the constraint retire_epoch_once relies on). BG-only; freed under EBR because
        // a concurrent insert_to_dummy pusher may hold its Guard.
        void drain_dummy(deadzone *dz) {
            epoch_node_wrapper *w = dummy_head_.exchange(nullptr, std::memory_order_acq_rel);
            while (w != nullptr) {
                epoch_node_wrapper *next = w->next.ptr();    // save before we free/re-push w
                epoch_node *en = w->epoch;
                bool dead = en != nullptr &&
                            ((dz != nullptr && can_prune_epoch(en, dz)) ||
                             en->state.load(std::memory_order_acquire) == EPOCH_CHAIN_DETACHED);
                bool is_head = en != nullptr && en->header != nullptr &&
                               en->header->next.ptr() == en;
                if (dead && !is_head) {
                    epochs_retired_dummy_.fetch_add(1, std::memory_order_relaxed);  // D-5 ⑤a-2: source split
                    detach_and_retire_epoch(en);
                    reclaimer_.retire([w] { delete w; });
                } else {
                    epoch_node_wrapper *head = dummy_head_.load(std::memory_order_acquire);
                    while (true) {                            // re-queue onto the (live) stack
                        w->next.store(head, false);
                        if (dummy_head_.compare_exchange_weak(head, w,
                                std::memory_order_release, std::memory_order_acquire))
                            break;
                    }
                }
                w = next;
            }
        }

        // Harris physical unlink of `dead` (its forward word already mark-set) from the
        // record's forward version chain: find the predecessor by scanning from the header
        // and CAS its next past `dead`. Retries on a raced CAS and returns once `dead` is no
        // longer reachable (another unlinker won) -> multi-unlinker-safe for FG unlink (1c-4).
        void unlink_epoch_from_chain(interval_list_header *hdr, epoch_node *dead, epoch_node *succ) {
            if (hdr == nullptr) return;
            const uintptr_t desired = MarkedPtr<epoch_node>::pack(succ, false);
            while (true) {
                uintptr_t hw = hdr->next.load();
                if (MarkedPtr<epoch_node>::ptr_of(hw) == dead) {     // header is the predecessor
                    uintptr_t expected = MarkedPtr<epoch_node>::pack(dead, false);  // cas takes lvalue
                    if (hdr->next.cas(expected, desired))
                        return;
                    continue;                                        // header->next moved; restart
                }
                epoch_node *p = MarkedPtr<epoch_node>::ptr_of(hw);
                bool restart = false;
                while (p != nullptr) {
                    uintptr_t pw = p->next.load();
                    epoch_node *pn = MarkedPtr<epoch_node>::ptr_of(pw);
                    if (pn == dead) {
                        if (MarkedPtr<epoch_node>::mark_of(pw)) { restart = true; break; }  // p dying
                        uintptr_t expected = MarkedPtr<epoch_node>::pack(dead, false);
                        if (p->next.cas(expected, desired))
                            return;
                        restart = true; break;                       // raced; restart from header
                    }
                    p = pn;
                }
                if (!restart) return;   // walked to end without finding dead -> already unlinked
            }
        }

        std::array<std::atomic<epoch_table_node *>, EPOCH_TABLE_SIZE> table{};
        std::vector<epoch_table_node *> long_live_epochs;
        EpochReclaimer reclaimer_;
        // Stage C-2: tail-only (InnoDB-style) GC baseline toggle; default false = full deadzone.
        std::atomic<bool> gc_tail_only_{false};
        // Shared deadzone descriptor published by the BG GC actor (stage 1c). The current
        // one leaks at shutdown by design (no next cycle to supersede+retire it), matching
        // the index's existing intended-leak posture; superseded ones are EBR-reclaimed.
        std::atomic<deadzone *> published_deadzone_{nullptr};
        // Stage 1c retire-once conservation counters (see epochs_detached()/epochs_retired()).
        std::atomic<uint64_t> epochs_detached_{0};
        std::atomic<uint64_t> epochs_retired_{0};
        // D-5 ⑤a-2: retire source split (windowed bucket sweep vs dummy-overflow drain).
        std::atomic<uint64_t> epochs_retired_windowed_{0};
        std::atomic<uint64_t> epochs_retired_dummy_{0};
        // Dummy-overflow list: a lock-free Treiber stack (nullptr = empty). Inserters push
        // orphan wrappers (bucket-swap race); the BG GC drains it (drain_dummy). backstop_counter_
        // paces the low-cadence full-bucket sweep; both are BG-only.
        std::atomic<epoch_node_wrapper *> dummy_head_{nullptr};
        uint64_t backstop_counter_{0};
        static constexpr uint64_t BACKSTOP_PERIOD = 4;   // run the full-bucket backstop every Nth cycle

        // Push an orphan wrapper (its epoch_num did not match its bucket -- a GC bucket-swap
        // race) onto the dummy-overflow Treiber stack. A concurrent BG exchange of dummy_head_
        // just makes this CAS fail and retry onto the new head, so no wrapper is lost.
        void insert_to_dummy(epoch_node* epoch){
            auto *w = new epoch_node_wrapper(epoch);
            epoch_node_wrapper *head = dummy_head_.load(std::memory_order_acquire);
            while (true) {
                w->next.store(head, false);
                if (dummy_head_.compare_exchange_weak(head, w,
                        std::memory_order_release, std::memory_order_acquire))
                    return;
                // head reloaded by the failed CAS; retry.
            }
        }
    };

} // namespace mvcc

#endif /* epoch_table_h */