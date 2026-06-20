// Licensed under the MIT license.

#include "accelerateMVCC.h"

mvcc::Accelerate_mvcc::Accelerate_mvcc(uint64_t record_count, uint32_t kuku_log2) {
    constexpr uint64_t max_value = ~0ULL;
    // Cuckoo table sized to (1 << kuku_log2) bins (default 1024; InnoDB integration uses 65536
    // so the dynamic key space does not overflow into silent cuckoo-insert failure).
    this->kuku_table = new kuku::KukuTable((1u << kuku_log2), (1 << 10), 2, kuku::make_random_item(), 100,
                                           kuku::make_item(max_value, max_value));
    // kukuTable = new kuku::KukuTable((1 << 16), (1 << 10), 2, kuku::make_zero_item(), 100, kuku::make_random_item());
    this->trxManger = new Trx_manager(record_count);

    this->epoch_table = new Epoch_table();

    for (int i = 0; i < record_count; i++) {
        kuku::item_type item = kuku::make_item(1, i);

        // value is header node pointer address for epoch-based interval linked list
        auto *header = new interval_list_header();


        auto value = reinterpret_cast<std::uint64_t>(header);

        // we can get header address from value
        // interval_list_header* header = reinterpret_cast<interval_list_header*>(value);

        kuku::set_value(value, item);
        if (!kuku_table->insert(item)) {
            std::cout << "record number : " << i << "is not inserted" << std::endl;
        }
    }
}


// this will be used when implementing to mysql source code.
bool mvcc::Accelerate_mvcc::insert(uint64_t table_id, uint64_t index,
                                   uint64_t trx_id, uint64_t space_id, uint64_t page_id, uint64_t offset) {
    kuku::item_type item = kuku::make_item(table_id, index);

    auto *undo_entry = new undo_entry_node(trx_id, space_id, page_id, offset);
    uint64_t epoch_num = get_epoch_num(trx_id);

    kuku::QueryResult query = kuku_table->query(item);
    if (query.found()) {
        uint64_t value;
        if (query.in_stash()) {
            item = kuku_table->stash(query.location());
            value = kuku::get_value(item);
        } else {
            item = kuku_table->table(query.location());
            value = kuku::get_value(item);
        }
        auto *header = reinterpret_cast<interval_list_header *>(value);
        if (header->next.ptr() == nullptr) {
            auto* epoch = new epoch_node();
            update_epoch_node(epoch, epoch_num, trx_id, undo_entry, nullptr);
            epoch->header = header;

            header->next_epoch_num = epoch_num;
            header->next.store(epoch, false);

            epoch_table->insert(epoch);
        }
        else if (header->next_epoch_num < epoch_num) {
            // create new epoch and prepend it at the head
            epoch_node *old_head = header->next.ptr();
            auto *epoch = new epoch_node();
            update_epoch_node(epoch, epoch_num, trx_id, undo_entry, old_head);
            epoch->header = header;

            // The previous head is now superseded by this new version: record its tight xmax
            // (stage 1c-4 fix) so the deadzone check no longer over-prunes it. trx_id is a
            // conservative bound for the new epoch's first version (a later smaller append would
            // only supersede it sooner, which keeps v_end larger -> under-prune, never over).
            if (old_head != nullptr)
                old_head->superseded_ts.store(trx_id, std::memory_order_release);

            header->next_epoch_num = epoch_num;
            header->next.store(epoch, false);

            epoch_table->insert(epoch);
        } else {
            // insert undo log entry to existing epoch
            epoch_node *epoch = header->next.ptr();
            epoch->count++;
            undo_entry_node *last_entry = epoch->last_entry.load();
            if (trx_id < epoch->min_trx_id) {
                epoch->min_trx_id = trx_id;
            }
            if (trx_id > epoch->max_trx_id) {
                epoch->max_trx_id = trx_id;
            }
            last_entry->next_entry.store(undo_entry);
            epoch->last_entry.store(undo_entry);
        }
    } else {
        auto *epoch = new epoch_node(epoch_num, trx_id, undo_entry, nullptr);
        auto *header = new interval_list_header();
        epoch->header = header;
        header->next_epoch_num = epoch_num;
        header->next.store(epoch, false);
        auto value = reinterpret_cast<std::uint64_t>(header);

        kuku::set_value(value, item);

        epoch_table->insert(epoch);
        return kuku_table->insert(item);
    }

    return false;
}

bool mvcc::Accelerate_mvcc::search(uint64_t table_id, uint64_t index,
                                   uint64_t trx_id, uint64_t &space_id, uint64_t &page_id, uint64_t &offset,
                                   std::vector<uint64_t> active_trx_list) {
    kuku::item_type item = kuku::make_item(table_id, index);
    uint64_t epoch_num = get_epoch_num(trx_id);
    kuku::QueryResult query = kuku_table->query(item);

    // if there is no undo log of the record, return false
    if (!query.found()) {
        return false;
    }


    /*Phase 1 : get address of header node*/
    uint64_t value;

    if (query.in_stash()) {
        item = kuku_table->stash(query.location());
        value = kuku::get_value(item);
    } else {
        item = kuku_table->table(query.location());
        value = kuku::get_value(item);
    }

    //get address of header node of interval list
    auto *header = reinterpret_cast<interval_list_header *>(value);


    /*Phase 2 : find the LATEST version visible to this read view.
      Visible == undo_entry->trx_id < our trx_id AND not in our active_trx_list.
      Among visible versions we want the greatest trx_id (latest committed). The
      chain is newest-epoch-first but oldest-entry-first within an epoch, so we
      scan all candidates and keep the maximum rather than returning the first. */
    // EBR reservation: from here until return we dereference epoch_node /
    // undo_entry pointers that GC may concurrently unlink+retire. The Guard
    // pins reclamation for this traversal's span so GC cannot free them under us.
    EpochReclaimer::Guard guard(epoch_table->reclaimer());
    // Stage 1c: load the shared published deadzone ONCE for this traversal, under the same
    // Guard that pins epoch_nodes (so the descriptor is pinned too -- BG may retire it while
    // we hold it). 1c-1 JUDGES deadness against it but does NOT act; cooperative unlink
    // lands in 1c-4. nullptr (warm-up / not yet published) -> judge nothing, never block.
    Epoch_table::deadzone *dz = epoch_table->published_deadzone();
    // Stage C-2: when FG cooperative unlink is disabled, we still traverse + help-splice marked
    // nodes below, but do not INITIATE new prunes (isolates the FG path's contribution).
    bool fg_on = fg_unlink_enabled_.load(std::memory_order_relaxed);
    bool found = false;
    uint64_t best_trx_id = 0;
    // pred_next = the forward word of the last KEPT predecessor (header, or the last unmarked
    // non-pruned epoch). It anchors the best-effort O(1) cooperative unlink (1c-4). Starts at
    // the header; pred_next == &header->next means "we are at the head" (never pruned).
    MarkedPtr<epoch_node> *pred_next = &header->next;
    epoch_node *epoch = header->next.ptr();

    while (epoch != nullptr) {
        // Load the forward word once: ptr = successor, mark = "this epoch is dead".
        uintptr_t w = epoch->next.load();
        epoch_node *succ = MarkedPtr<epoch_node>::ptr_of(w);
        if (MarkedPtr<epoch_node>::mark_of(w)) {
            // Already logically deleted: best-effort help-splice it out (Harris helping), then
            // skip its (invisible) versions. CAS only succeeds through an UNMARKED pred still
            // pointing at us, so it is multi-unlinker safe; on failure leave it for the BG
            // backstop. Do NOT advance pred (a marked node is not a valid predecessor).
            uintptr_t exp = MarkedPtr<epoch_node>::pack(epoch, false);
            pred_next->cas(exp, MarkedPtr<epoch_node>::pack(succ, false));
            epoch = succ;
            continue;
        }
        // 1c-4 cooperative unlink: a dead NON-HEAD epoch is pruned just like BG would -- mark it
        // (so every reader skips it henceforth) + best-effort O(1) splice via pred. retire stays
        // BG-only (BG retires it via the descriptor-dead wrapper sweep / backstop). The HEAD is
        // NEVER pruned (head-skip; pred_next == &header->next), so it is always scanned below --
        // a reader's visible-latest version lives in the head and must never be skipped.
        if (fg_on && dz != nullptr && pred_next != &header->next &&
            epoch_table->can_prune_epoch(epoch, dz)) {
            coop_dead_seen_.fetch_add(1, std::memory_order_relaxed);
            epoch->next.set_mark(succ);                  // logical delete (idempotent; may fail if next moved)
            // Re-read epoch->next: once it is MARKED its pointer is frozen, so splice to that
            // re-read successor -- never the pre-mark `succ` (a concurrent unlinker may have
            // changed epoch->next between the load above and here, which would make set_mark fail
            // and the old `succ` stale; splicing it would drop a live node / resurrect a detached
            // one). If set_mark did not take, just advance without splicing.
            uintptr_t mw = epoch->next.load();
            if (MarkedPtr<epoch_node>::mark_of(mw)) {
                epoch_node *msucc = MarkedPtr<epoch_node>::ptr_of(mw);
                uintptr_t exp = MarkedPtr<epoch_node>::pack(epoch, false);
                pred_next->cas(exp, MarkedPtr<epoch_node>::pack(msucc, false));  // best-effort, no retry
                epoch = msucc;
            } else {
                epoch = MarkedPtr<epoch_node>::ptr_of(mw);   // next moved w/o mark -> advance, no splice
            }
            continue;                                    // pruned: skip scan, do NOT advance pred
        }
        // Kept epoch (the head, or a live/not-yet-dead epoch): scan its versions for visibility
        // if it is at or below our snapshot's epoch.
        if (epoch->epoch_num <= epoch_num) {
            for (undo_entry_node *undo_entry = epoch->first_entry;
                 undo_entry != nullptr;
                 undo_entry = undo_entry->next_entry.load()) {
                if (undo_entry->trx_id < trx_id &&
                    std::find(active_trx_list.begin(), active_trx_list.end(), undo_entry->trx_id) ==
                        active_trx_list.end()) {
                    if (!found || undo_entry->trx_id > best_trx_id) {
                        found = true;
                        best_trx_id = undo_entry->trx_id;
                        space_id = undo_entry->space_id;
                        page_id = undo_entry->page_id;
                        offset = undo_entry->offset;
                    }
                }
            }
        }
        pred_next = &epoch->next;   // kept -> advance pred over it
        epoch = succ;
    }

    return found;
}


