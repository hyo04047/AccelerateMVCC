#ifndef epoch_table_h
#define epoch_table_h

#include <array>
#include <utility>
#include <vector>
#include <atomic>
#include <cstring>
#include <algorithm>
#include "common.h"
#include "interval_list.h"
#include "trxManager.h"
#include "epoch_reclaimer.h"

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
            // Single shared dummy-overflow head. (Was allocated inside the loop above,
            // so 99 of 100 dummy heads leaked at construction.)
            auto* wrapper_dummy = new epoch_node_wrapper(nullptr);
            first_dummy_node.store(wrapper_dummy);
            last_dummy_node.store(wrapper_dummy);
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
            /* 3. Update other deadzone */
            for (uint64_t i = 1; i < vector.size(); ++i) {
                low_limit_id = vector.at(i - 1).trx_id;
                dead_up_limit_id = get_dead_up_limit_id(low_limit_id, vector.at(i).active_trx_ids,
                                                        vector.at(i).trx_id);

                zone->range[2 * zone->len] = low_limit_id;
                zone->range[2 * zone->len + 1] = dead_up_limit_id;
                zone->len++;
            }
            return zone;
        }

        bool can_pruning(uint64_t v_start, uint64_t v_end , deadzone* zone) {
            bool ret = false;
            bool flag = true;


            /* compare its v_start & v_end to deadzone */
            for (uint64_t i = 0; i < zone->len; ++i) {
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

        // Judge whether an epoch_node's (nominal) interval is fully inside a dead zone.
        // Uses the nominal window [epoch_num*EPOCH_SIZE, +EPOCH_SIZE): an append that
        // lowers the epoch's actual min never widens this window, so the verdict only
        // ever under-prunes (never over-prunes). Used by GC and (stage 1c) FG readers.
        bool can_prune_epoch(epoch_node *en, deadzone *dz) {
            uint64_t epoch_num = en->epoch_num;
            uint64_t v_start = epoch_num * EPOCH_SIZE;
            uint64_t v_end = ((epoch_num + 1) * EPOCH_SIZE) - 1;
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
            {
                //get size of long_live_epochs and operate gc from (size - EPOCH_TABLE_SIZE / 2) to (size - EPOCH_TABLE_SIZE / 4 - 1)
                uint64_t llt_size = long_live_epochs.size();
                if (llt_size < (uint64_t)(EPOCH_TABLE_SIZE / 2)) {   // not enough lag accumulated yet
                    publish_deadzone(deadzone);   // publish even when no sweep ran this cycle
                    return false;
                }
                uint64_t start_index = llt_size - (EPOCH_TABLE_SIZE / 2);
                uint64_t end_index = llt_size - (EPOCH_TABLE_SIZE / 4) - 1;
                std::vector<epoch_table_node *> deleteIndexes;

                int i_start = static_cast<int>(start_index);
                int i_end = static_cast<int>(end_index);
                for(int i = i_start;  i <= i_end; i++){
                    epoch_table_node * table_node = long_live_epochs.at(i);

                    // Prune every epoch wrapper whose interval is fully inside a dead zone.
                    // first_node is a stable dummy head; walk forward keeping prev_node so we can splice.
                    epoch_node_wrapper *prev_node = table_node->first_node.load();
                    for (epoch_node_wrapper *node = prev_node->next.ptr(); node != nullptr; ) {
                        bool prune = can_operate_gc(node, deadzone);
                        if (prune) {
                            // Single-writer 1b: never prune a record's HEAD epoch. header->next is the
                            // only interval-list word insert and GC could write concurrently, and the
                            // newest epoch is normally live. Skipping it makes insert||GC touch disjoint
                            // words (no insert-side hardening). A dead head is reclaimed on a later pass
                            // once a newer epoch is prepended. (Multi-writer hardening = increment 5.)
                            epoch_node *en = node->epoch;
                            if (en != nullptr && en->header != nullptr && en->header->next.ptr() == en) {
                                prune = false;
                            }
                        }
                        if (prune) {
                            epoch_node_wrapper *dead = node;
                            epoch_node_wrapper *wsucc = node->next.ptr();
                            dead->next.set_mark(wsucc);                  // logical splice (Harris mark)
                            // Wrapper list is single-unlinker (BG only; FG never touches it). The
                            // windowed sweep + the 1c-3 backstop run on this one BG actor over
                            // disjoint ranges, so the plain store stays valid (no CAS needed).
                            prev_node->next.store(wsucc, false);
                            node = wsucc;

                            epoch_node *epochNode = dead->epoch;
                            // Version-chain unlink, now multi-unlinker-safe (ahead of FG unlink in
                            // 1c-4): (1) logical mark the forward word; (2) CAS the predecessor's
                            // next past it (Harris), found by forward scan from the header.
                            epoch_node *succ = epochNode->next.ptr();
                            epochNode->next.set_mark(succ);
                            unlink_epoch_from_chain(epochNode->header, epochNode, succ);
                            // Claim CHAIN_DETACHED (the version-chain splicer's role). In 1c-2 BG is
                            // the only splicer; 1c-4 lets an FG reader win this CAS instead.
                            uint8_t expLive = EPOCH_LIVE;
                            if (epochNode->state.compare_exchange_strong(
                                    expLive, EPOCH_CHAIN_DETACHED, std::memory_order_acq_rel))
                                epochs_detached_.fetch_add(1, std::memory_order_relaxed);
                            // Retire through the SINGLE state-gated authority (never on deadness
                            // alone). Exactly-once holds because each node has one swept wrapper
                            // (see retire_epoch_once); FG detach in 1c-4 routes its retire here too.
                            retire_epoch_once(epochNode);
                            reclaimer_.retire([dead] { delete dead; });
                        } else {
                            prev_node = node;                            // advance prev only over kept nodes
                            node = node->next.ptr();
                        }
                    }

                    // No concurrent inserter and list drained to just the dummy head -> reclaim table node.
                    if (table_node->count.load() == 0 &&
                        table_node->first_node.load()->next.ptr() == nullptr) {
                        epoch_node_wrapper *dummy_head = table_node->first_node.load();
                        reclaimer_.retire([dummy_head] { delete dummy_head; });
                        deleteIndexes.push_back(table_node);
                    }
                }

                for(epoch_table_node* node : deleteIndexes){
                    auto it = std::find(long_live_epochs.begin(), long_live_epochs.end(), node);
                    if (it != long_live_epochs.end()) {
                        long_live_epochs.erase(it);
                    }
                    reclaimer_.retire([node] { delete node; });
                }
            }

            publish_deadzone(deadzone);
            return true;
        }

        // EBR used by GC (retire/reclaim) and search readers (Guard). Single
        // producer/reclaimer in stage 1a: only the GC actor retires/reclaims.
        EpochReclaimer& reclaimer() { return reclaimer_; }

        // GC metrics (stage 1c): epoch_nodes detached from the version chain, and retired.
        // At quiescence detached == retired -- valid while each epoch_node has a single swept
        // wrapper (the 1c-2/1c-4 world: LIVE->CHAIN_DETACHED->RETIRED runs once per node). If a
        // retire could ever skip the detach claim (a second swept wrapper, 1c-3), switch the
        // check to the full LIVE + CHAIN_DETACHED + RETIRED conservation.
        uint64_t epochs_detached() const { return epochs_detached_.load(std::memory_order_relaxed); }
        uint64_t epochs_retired()  const { return epochs_retired_.load(std::memory_order_relaxed); }


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
        // Shared deadzone descriptor published by the BG GC actor (stage 1c). The current
        // one leaks at shutdown by design (no next cycle to supersede+retire it), matching
        // the index's existing intended-leak posture; superseded ones are EBR-reclaimed.
        std::atomic<deadzone *> published_deadzone_{nullptr};
        // Stage 1c retire-once conservation counters (see epochs_detached()/epochs_retired()).
        std::atomic<uint64_t> epochs_detached_{0};
        std::atomic<uint64_t> epochs_retired_{0};
        std::atomic<epoch_node_wrapper *> first_dummy_node;
        std::atomic<epoch_node_wrapper *> last_dummy_node;

        void insert_to_dummy(epoch_node* epoch){
            auto *epoch_wrapper = new epoch_node_wrapper(epoch);
            while (true) {
                epoch_node_wrapper *last = last_dummy_node.load();
                epoch_node_wrapper *expected_last = last;
                epoch_wrapper->next.store(expected_last, false);
                if (last_dummy_node.compare_exchange_weak(last, epoch_wrapper)) {
                    return;
                }
                // The compare_exchange_weak failed, retry the operation.
            }
        }
    };

} // namespace mvcc

#endif /* epoch_table_h */