// Licensed under the MIT license.
#pragma once

#ifndef accelerateMVCC_h
#define accelerateMVCC_h

#include <cstdint>
#include <iostream>
#include <thread>
#include <atomic>
#include <chrono>
#include "trxManager.h"
#include "kuku/kuku.h"
#include "interval_list.h"
#include "common.h"
#include "epoch_table.h"

namespace mvcc
{
    /**
    The AccelerateMvcc class represents a entire in-memory structure for accelerating MVCC. 
    It includes HashTable, HashResult, EpochList, and TrxManager.
    */
    class Accelerate_mvcc;

    /**
    The TrxManager class represents mimic version of transaction manager in DBMS
    It should mange transaction id and classify which epoch is active or not.
    */
    class Trx_manager;

    /**
    The AccelerateMvcc class represents a entire in-memory structure for accelerating MVCC.
    It includes HashTable, HashResult, EpochList, and TrxManager.
    */
    class Accelerate_mvcc {

    public:
        // kuku_log2 sizes the cuckoo table to (1 << kuku_log2) bins. Default 10 (1024) keeps
        // existing callers/tests unchanged; the InnoDB integration passes 16 (65536) so the
        // dynamic (table_id, pk-hash) key space does not overflow into silent cuckoo failure.
        explicit Accelerate_mvcc(uint64_t record_count, uint32_t kuku_log2 = 10);
        ~Accelerate_mvcc() { stop_background_gc(); }

        // Run one GC pass synchronously (deterministic; for single-threaded tests).
        // Single-unlinker precondition: no-op while the BG GC thread is active, since
        // garbage_collect mutates the non-atomic long_live_epochs vector and table[].
        void run_gc_once() {
            if (gc_started_.load(std::memory_order_acquire)) return;
            uint64_t trx_id = trxManger->get_next_trx_id();
            epoch_table->garbage_collect(get_epoch_num(trx_id), trxManger->get_copy_active_trx_list());
        }

        // D-5 ⑤a-2: run ONE integration GC cycle at the given pushed-InnoDB boundary clock, building the
        // dead zone from the active-view registry cuts + conservative floor (a superset of the truly-active
        // views) instead of the standalone trx manager -- which the off-latch drainer never advances (M4).
        // The SINGLE GC actor is the integration driver thread (accel_hook gc_loop); the standalone BG GC
        // (start_background_gc) stays off, so there is exactly one mutator of the non-atomic GC state.
        bool run_gc_cycle_from_cuts(uint64_t boundary_clock,
                                    const std::vector<ViewCut>& cuts, uint64_t floor) {
            return epoch_table->garbage_collect_from_cuts(epoch_of(boundary_clock), cuts, floor);
        }

        // Dedicated background GC actor (single unlinker). Replaces the old inline
        // trigger so GC no longer runs on transaction threads; lifecycle owned here.
        // It fires at the same trx-id cadence the inline trigger used (every PERIOD trx).
        void start_background_gc() {
            bool expected = false;
            if (!gc_started_.compare_exchange_strong(expected, true)) return;  // already running
            gc_stop_.store(false, std::memory_order_release);
            try {
                gc_thread_ = std::thread([this] {
                    constexpr uint64_t PERIOD = static_cast<uint64_t>(EPOCH_SIZE) * EPOCH_TABLE_SIZE / 4;
                    uint64_t last_boundary = 0;
                    while (!gc_stop_.load(std::memory_order_acquire)) {
                        uint64_t cur = trxManger->get_next_trx_id();
                        uint64_t boundary = (cur / PERIOD) * PERIOD;
                        if (boundary > last_boundary) {
                            // Drain every MISSED boundary one PERIOD at a time (don't jump to the
                            // latest): each garbage_collect must advance the epoch by exactly
                            // EPOCH_TABLE_SIZE/4 so the Phase-1 table swaps stay in their cadence.
                            for (uint64_t b = last_boundary + PERIOD; b <= boundary; b += PERIOD) {
                                // Respond to shutdown promptly: under a pathological backlog (e.g.
                                // the tail-only baseline reclaims almost nothing, so each sweep's
                                // cost grows), draining every missed boundary here could take far
                                // longer than the stop signal -- making stop_background_gc().join()
                                // hang. We are stopping anyway, so abandoning the remaining drain
                                // is safe (no further GC will run on this actor).
                                if (gc_stop_.load(std::memory_order_acquire)) break;
                                epoch_table->garbage_collect(get_epoch_num(b),
                                                             trxManger->get_copy_active_trx_list());
                            }
                            last_boundary = boundary;
                        } else {
                            std::this_thread::sleep_for(std::chrono::microseconds(50));
                        }
                    }
                });
            } catch (...) {
                gc_started_.store(false, std::memory_order_release);  // roll back: no actor is running
                throw;
            }
        }

        void stop_background_gc() {
            if (!gc_started_.load(std::memory_order_acquire)) return;
            gc_stop_.store(true, std::memory_order_release);
            if (gc_thread_.joinable()) gc_thread_.join();
            gc_started_.store(false, std::memory_order_release);
        }

        void insert_trx(uint64_t index){
            // start transaction
            auto *trx = start_write_trx();
            uint64_t trx_id = trx->trx_id;

            // GC is no longer triggered inline here -- it runs on the dedicated
            // background GC thread (start_background_gc) or via run_gc_once().

            // get write lock of the record
            get_mutex(index);

            // insert undo log entry to interval list
            insert(1,index,trx_id,trx_id,trx_id,trx_id);

            // commit transaction
            commit_trx(trx);

            // release write lock
            release_mutex(index);
        }
         void insert_trx_without_gc(uint64_t index){
            // start transaction
            auto *trx = start_write_trx();
            uint64_t trx_id = trx->trx_id;

            // get write lock of the record
            get_mutex(index);

            // insert undo log entry to interval list
            insert(1,index,trx_id,trx_id,trx_id,trx_id);

            // commit transaction
            commit_trx(trx);

            // release write lock
            release_mutex(index);
        }

        void insert_trx_without_trx_manager(uint64_t index) {
            uint64_t trx_id = trxManger->generate_trx_id();
            // get write lock of the record
            get_mutex(index);

            // insert undo log entry to interval list
            insert(1, index, trx_id, trx_id, trx_id, trx_id);

            // release write lock
            release_mutex(index);
        }

        void dummy_read_trx() {
            auto* trx = start_trx();
            commit_trx(trx);
        }

        trx_t* start_read_trx() {
            // GC no longer triggered inline here (see start_background_gc / run_gc_once).
            return start_trx();
        }

        bool search_operation(uint64_t table_id, uint64_t index, trx_t *trx, uint64_t &space_id, uint64_t &page_id, uint64_t &offset) {
            // read-view is already a flat id list -> pass it straight through.
            return search(table_id, index, trx->trx_id, space_id, page_id, offset, trx->active_trx_ids);
        }

        void end_read_trx(trx_t* trx){
            commit_trx(trx);
        }

        // insert undo log entry to interval list
        // D-4 (4b-0): the 3rd arg is the VERSION's creator (= old DB_TRX_ID), the visibility key.
        // writer_trx_id is the overwriter (trx->id at populate); pass 0 (default) to mean "same as
        // version_trx_id" -- the standalone prototype, where each insert IS the version's own writer.
        bool insert(uint64_t table_id, uint64_t index, uint64_t version_trx_id, uint64_t space_id, uint64_t page_id, uint64_t offset,
                    const unsigned char *img = nullptr, uint32_t img_len = 0, uint64_t writer_trx_id = 0,
                    const unsigned char *pk = nullptr, uint32_t pk_len = 0, uint8_t delete_mark = 0,
                    uint32_t extra_len = 0);

        bool search(uint64_t table_id, uint64_t index,
            uint64_t trx_id, uint64_t& space_id, uint64_t& page_id, uint64_t& offset,
            std::vector<uint64_t> active_trx_list
            );

        // D-4 (4b-3): the shadow consult. Given a reader's read view (InnoDB ReadView fields) and the
        // live row's last writer, decide what the cache would serve for (table_id, full PK) and why.
        // Outcome is ALWAYS one of: HIT (the candidate is the provably-correct visible boundary; if a
        // buffer is given its image is copied out under the EBR Guard) or one of the MISS reasons
        // (caller must fall back to InnoDB's full walk -- never a guess). See design-D4b-shadow.md
        // sec 3 / sec 9.
        enum class ConsultOutcome : uint8_t {
            HIT,             // candidate proven = vanilla's visible version; image copied if requested
            MISS_ABSENT,     // key (or this row's PK) not in the cache
            MISS_NOVISIBLE,  // PK present but no cached version is visible to this read view
            MISS_NONCONTIG,  // cache cannot prove contiguity to the live row (drainer lag / ring drop)
            MISS_INELIGIBLE, // candidate has no usable image (locator-only / over-cap)
            MISS_GCRACE      // D-5 C3: a GC retire of this key raced the probe (gc_generation moved) -> distrust
        };
        // require_full_pk=false is a TEST-ONLY negative control: it skips the full-PK identity check
        // so a forced pk_hash collision serves a cross-row image -> the shadow byte-compare must then
        // report mismatches, proving the test can actually catch a wrong selection (and that full-PK
        // is what prevents it). It is IGNORED (forced true) unless set_allow_no_full_pk(true) was called
        // first, so a production slip can never silently disable the firewall (see allow_no_full_pk_).
        ConsultOutcome consult(uint64_t table_id, uint64_t pk_hash,
                               const unsigned char *pk, uint32_t pk_len,
                               uint64_t up_limit_id, uint64_t low_limit_id, uint64_t creator_trx_id,
                               const uint64_t *m_ids, std::size_t m_ids_n,
                               uint64_t live_top_writer,
                               unsigned char *out_img = nullptr, uint32_t out_cap = 0,
                               uint32_t *out_len = nullptr, bool require_full_pk = true,
                               uint64_t live_schema_epoch = 0, uint32_t *out_extra = nullptr,
                               bool enforce_gc_gen = false);

        static uint64_t get_epoch_num(uint64_t trx_id) {
            return trx_id / EPOCH_SIZE;
        }

        // D-5 ⑤a-2 step 3: epoch numbering RELATIVE to a base id. In integration the InnoDB trx-id space
        // starts at a large absolute value, so raw trx_id/EPOCH_SIZE lands every version OUTSIDE the
        // fixed bucket ring -> all reclaim falls to the O(working-set) dummy drain instead of the amortized
        // windowed sweep. Subtracting a base captured at the first insert puts epochs near 0 so they land
        // in the ring and the windowed path engages. STANDALONE leaves the base at 0, so epoch_of is then
        // exactly get_epoch_num (trx_id / EPOCH_SIZE) -- behavior-neutral. Base is set once (integration).
        void set_epoch_base(uint64_t b) {
            if (b == 0) return;
            uint64_t z = 0;
            id_base_.compare_exchange_strong(z, b, std::memory_order_relaxed);
        }
        uint64_t epoch_base() const { return id_base_.load(std::memory_order_relaxed); }
        uint64_t epoch_of(uint64_t trx_id) const {
            uint64_t b = id_base_.load(std::memory_order_relaxed);
            return (trx_id > b ? trx_id - b : 0) / EPOCH_SIZE;
        }

        // Stage 1c metric: count of dead epochs (per the shared published deadzone) that
        // readers TRAVERSED during search -- a proxy for the chain bloat that cooperative
        // unlink (1c-4) will shrink. In 1c-1 readers judge-only and just increment this.
        uint64_t coop_dead_seen() const { return coop_dead_seen_.load(std::memory_order_relaxed); }
        std::atomic<uint64_t> coop_dead_seen_{0};

        // D-5 C3-c diag: split MISS_NONCONTIG into its two causes so the ⑥ collapse can be attributed.
        //   nc_headwriter_ = the contiguity scalar gate fired (cache head writer != live row's last writer:
        //     the cache head does not reach the live row -- drainer lag / ring drop).
        //   nc_chasebreak_ = the lineage chase ran off the end (best==nullptr with a visible version present):
        //     a writer->predecessor link is GONE mid-chain = GC reclaimed an intermediate version the walk
        //     needs to navigate down to the held reader's version. This is the GC chain-sever.
        std::atomic<uint64_t> nc_headwriter_{0};
        std::atomic<uint64_t> nc_chasebreak_{0};
        uint64_t nc_headwriter() const { return nc_headwriter_.load(std::memory_order_relaxed); }
        uint64_t nc_chasebreak() const { return nc_chasebreak_.load(std::memory_order_relaxed); }

        // Stage C-2 experiment toggles (set once before threads start; default = current behavior).
        // fg_unlink_enabled_: when false, search() still help-splices already-marked nodes (needed
        // for correctness) but does NOT INITIATE new cooperative unlinks -> isolates the FG path's
        // contribution (BG-only vs BG+FG) at a fixed reader load.
        std::atomic<bool> fg_unlink_enabled_{true};
        void set_fg_unlink_enabled(bool v) { fg_unlink_enabled_.store(v, std::memory_order_relaxed); }
        // D-5 FG-α (integration FG cooperative reclaim): when true, consult's Pass-1 traversal also helps prune
        // dead non-head epochs it scans (mark + best-effort O(1) CAS-splice, like search()'s 1c-4 cooperative
        // unlink; retire stays BG-only) -- so the integration read path (not just the standalone search) keeps
        // chains short. It adds an epoch's entries to THIS build's map BEFORE marking, so the current consult's
        // own chase keeps every link; the mark only shortens the chain for FUTURE Pass-1 scans + lets BG retire.
        // Default OFF so existing consult oracles are unaffected (FG also needs a published deadzone to act).
        std::atomic<bool> consult_fg_reclaim_{false};
        void set_consult_fg_reclaim(bool v) { consult_fg_reclaim_.store(v, std::memory_order_relaxed); }
        // Forwards to the GC: tail-only (InnoDB-style) pruning baseline vs full deadzone.
        void set_gc_tail_only(bool v) { epoch_table->set_gc_tail_only(v); }
        // D-5 GC-tuning: cap the dummy-drain reclaim per cycle (0 = unlimited) to spread the small-BP storm.
        void set_dummy_drain_cap(uint64_t c) { epoch_table->set_dummy_drain_cap(c); }

        // Stage 1c-2 retire-once conservation: epoch_nodes detached from the version chain
        // vs retired. At quiescence these must be EQUAL (each detached node retired once).
        uint64_t epochs_detached() const { return epoch_table->epochs_detached(); }
        uint64_t epochs_retired()  const { return epoch_table->epochs_retired(); }
        // D-5 ⑤a-2: GC retire counts split by source (windowed bucket sweep vs orphan dummy drain) so
        // the GC-on gate can tell whether the dangerous windowed/unlink path actually ran.
        uint64_t epochs_retired_windowed() const { return epoch_table->epochs_retired_windowed(); }
        uint64_t epochs_retired_dummy()    const { return epoch_table->epochs_retired_dummy(); }
        // ⓠ3: VERSIONS freed (clean live-version count = drained - entries_retired, comparable to HLL).
        uint64_t entries_retired() const { return epoch_table->entries_retired(); }

        // ⓝ9 (cold-key footprint): distinct keys that ever got an interval_list_header (bumped once, the
        // first time a key is seen). Headers + their Kuku slots are NEVER reclaimed (no erase / head-skip),
        // so this == the LIVE header count = the O(distinct-keys-ever-touched) memory that the "memory ∝
        // live-txn window, not dataset" claim does NOT cover. A workload that touches ever-new keys uses this
        // to quantify the cold-key growth (vs live_versions, which GC keeps bounded).
        std::atomic<uint64_t> headers_created_{0};
        uint64_t headers_created() const { return headers_created_.load(std::memory_order_relaxed); }

        // ⓝ9 graceful non-admission: set once a cuckoo insert fails (the Kuku table is full). After that,
        // new keys are skipped cheaply (consult MISS -> vanilla walk, correct) instead of the old unbounded
        // header churn. We do NOT delete a header whose insert failed -- a failed cuckoo path may have
        // already published its pointer into a slot, so a delete would dangle it (UAF). One leaked header
        // (the failing one) is the bounded residual; kuku_full_ then blocks all further attempts.
        std::atomic<bool> kuku_full_{false};
        bool kuku_full() const { return kuku_full_.load(std::memory_order_relaxed); }

        // ⓝ9: versions dropped on non-admission (the key wasn't cached because the table is full). Their
        // undo_entry is freed immediately (NOT via the GC retire path), so they land in `drained` but not in
        // entries_retired -- subtract them to keep live_versions = drained - entries_retired - versions_dropped
        // accurate (else the uncached fallback traffic inflates it). 0 below capacity, so ⓠ3 is unaffected.
        std::atomic<uint64_t> versions_dropped_{0};
        uint64_t versions_dropped() const { return versions_dropped_.load(std::memory_order_relaxed); }
        // Stage 1c-3: orphan wrappers pending in the dummy-overflow stack (test-only).
        size_t dummy_pending() const { return epoch_table->dummy_pending(); }
        // Stage 1c-6: GC long-lived-bucket vector size (test-only; bounded by compaction).
        size_t long_live_size() const { return epoch_table->long_live_size(); }

        // Stage 1c-4 (test-only): count of UNMARKED epochs in a record's version chain. Call
        // only when quiescent (no concurrent GC/readers) -- it walks the chain without a Guard.
        size_t chain_length(uint64_t table_id, uint64_t index) {
            kuku::item_type item = kuku::make_item(table_id, index);
            kuku::QueryResult q = kuku_table->query(item);
            if (!q.found()) return 0;
            uint64_t value = q.in_stash()
                ? kuku::get_value(kuku_table->stash(q.location()))
                : kuku::get_value(kuku_table->table(q.location()));
            auto* header = reinterpret_cast<interval_list_header*>(value);
            size_t n = 0;
            for (epoch_node* e = header->next.ptr(); e != nullptr; ) {
                uintptr_t word = e->next.load();
                if (!MarkedPtr<epoch_node>::mark_of(word)) ++n;
                e = MarkedPtr<epoch_node>::ptr_of(word);
            }
            return n;
        }

        // Stage C (bench): Guard-SAFE live chain-length sampler. Same unmarked-epoch count as
        // chain_length() above, but holds a per-traversal EBR Guard for the walk, so it is safe
        // to call WHILE the BG GC and FG readers concurrently unlink+retire nodes (the Guard
        // pins reclamation for this traversal -- no node we touch can be freed under us). The
        // count is a statistical sample of a live chain (concurrent splices may shift it by a
        // node), which is exactly what the version-chain-length CDF wants. Bench/test-only.
        size_t chain_length_guarded(uint64_t table_id, uint64_t index) {
            kuku::item_type item = kuku::make_item(table_id, index);
            kuku::QueryResult q = kuku_table->query(item);
            if (!q.found()) return 0;
            uint64_t value = q.in_stash()
                ? kuku::get_value(kuku_table->stash(q.location()))
                : kuku::get_value(kuku_table->table(q.location()));
            auto* header = reinterpret_cast<interval_list_header*>(value);
            EpochReclaimer::Guard guard(epoch_table->reclaimer());
            size_t n = 0;
            for (epoch_node* e = header->next.ptr(); e != nullptr; ) {
                uintptr_t word = e->next.load();
                if (!MarkedPtr<epoch_node>::mark_of(word)) ++n;
                e = MarkedPtr<epoch_node>::ptr_of(word);
            }
            return n;
        }

        // ⓠ3 (Phase 2): like chain_length_guarded but STOPS counting at `cap` (returns cap if the chain
        // is at least cap long). Lets a periodic retention reporter sample MANY keys at a bounded cost --
        // a tail-only chain can be 10^5+ long, and an uncapped per-key walk over every key each tick steals
        // enough CPU to throttle the very workload being measured (a measurement confound). The cap reports
        // "this key has >= cap versions" (which is all the headline needs: deadzone chains are short and
        // reported exactly; tail-only ones just saturate). cap=0 means unbounded. Bench/test-only.
        size_t chain_length_guarded_capped(uint64_t table_id, uint64_t index, size_t cap) {
            kuku::item_type item = kuku::make_item(table_id, index);
            kuku::QueryResult q = kuku_table->query(item);
            if (!q.found()) return 0;
            uint64_t value = q.in_stash()
                ? kuku::get_value(kuku_table->stash(q.location()))
                : kuku::get_value(kuku_table->table(q.location()));
            auto* header = reinterpret_cast<interval_list_header*>(value);
            EpochReclaimer::Guard guard(epoch_table->reclaimer());
            size_t n = 0;
            for (epoch_node* e = header->next.ptr(); e != nullptr; ) {
                uintptr_t word = e->next.load();
                if (!MarkedPtr<epoch_node>::mark_of(word)) {
                    ++n;
                    if (cap != 0 && n >= cap) return n;  // saturate (cap=0 = unbounded)
                }
                e = MarkedPtr<epoch_node>::ptr_of(word);
            }
            return n;
        }

        // D-5 C3 (test-only): read a key's GC generation counter (the mode-1 2nd-firewall epoch). Looks the
        // header up like chain_length; treat the value as a sample under concurrency. Lets the gen-gate
        // oracles assert the GC retire path actually bumped it.
        uint64_t gc_generation_of(uint64_t table_id, uint64_t index) {
            kuku::item_type item = kuku::make_item(table_id, index);
            kuku::QueryResult q = kuku_table->query(item);
            if (!q.found()) return 0;
            uint64_t value = q.in_stash()
                ? kuku::get_value(kuku_table->stash(q.location()))
                : kuku::get_value(kuku_table->table(q.location()));
            auto* header = reinterpret_cast<interval_list_header*>(value);
            return header->gc_generation.load(std::memory_order_acquire);
        }

        // D-5 C3 (test-only seam): when set, consult bumps THIS key's gc_generation once, right after it
        // snapshots the value under its Guard -- deterministically simulating a GC retire that RACES the
        // probe. With enforce_gc_gen=true the end-recheck then observes the change -> MISS. The positive/
        // negative control oracle toggles this to prove the gate flips a would-be HIT to MISS. Default off.
        std::atomic<bool> test_bump_gen_mid_consult_{false};
        void set_test_bump_gen_mid_consult(bool v) { test_bump_gen_mid_consult_.store(v, std::memory_order_relaxed); }

        // Production firewall lock: require_full_pk=false (the cross-row negative control) is IGNORED
        // (treated as true) unless this test-only opt-in is set first. So a positional/default slip can
        // never silently disable the full-PK identity firewall in production -- disabling it takes an
        // explicit, greppable set_allow_no_full_pk(true). Default false (firewall always on).
        std::atomic<bool> allow_no_full_pk_{false};
        void set_allow_no_full_pk(bool v) { allow_no_full_pk_.store(v, std::memory_order_relaxed); }

        trx_t* start_trx(){
            return trxManger->startTrx();
        }

        trx_t* start_write_trx(){
            return trxManger->startWriteTrx();
        }

        void commit_trx(trx_t* trx){
            trxManger->commitTrx(trx);
        }

        void get_mutex(uint64_t index){
            trxManger->get_mutex(index);
        }

        void release_mutex(uint64_t index){
            trxManger->release_mutex(index);
        }
        

    private:
        /**
        The kukuTable represents a cuckoo hash table. It includes information about the location functions (hash
        functions) and holds the items inserted into the table.
        */
        kuku::KukuTable* kuku_table;

        // D-5 ⑤a-2 step 3: base trx-id for relative epoch numbering. 0 = standalone/raw (epoch_of ==
        // get_epoch_num, behavior-neutral); integration sets it once to the first inserted version's trx
        // so epochs land in the bucket ring and the amortized windowed sweep engages.
        std::atomic<uint64_t> id_base_{0};

        /**
        The trxManager represents mimic version of transaction manager in DBMS
        It should mange transaction id and classify which epoch is active or not.
        */
        Trx_manager* trxManger;

        Epoch_table* epoch_table;

        // Dedicated background GC actor (single unlinker for stage 1b).
        std::thread gc_thread_;
        std::atomic<bool> gc_stop_{false};
        std::atomic<bool> gc_started_{false};

    };


} // namespace mvcc
#endif /* accelerateMVCC_h */